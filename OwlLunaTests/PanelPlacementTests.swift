import XCTest
import SwiftUI
@testable import OwlLuna

/// A card hangs from where its control is on show: never from a marker that has gone, is in no window or has no size yet.
@MainActor
final class PanelSpotTests: XCTestCase {
    private func window() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        return window
    }

    func testAMarkerInNoWindowGivesNoPlace() throws {
        let spot = PanelSpot()
        XCTAssertNil(spot.frame, "no marker yet")
        let marker = PanelMarker(frame: CGRect(x: 0, y: 0, width: 115, height: 44))
        spot.keep(marker)
        XCTAssertNil(spot.frame, "a marker in no window would put the card in the corner")
        XCTAssertFalse(spot.isInWindow)
        let bar = UIView(frame: CGRect(x: 600, y: 32, width: 200, height: 44))
        try window().addSubview(bar)
        bar.addSubview(marker)
        XCTAssertEqual(spot.frame, CGRect(x: 600, y: 32, width: 115, height: 44))
        XCTAssertTrue(spot.isInWindow)
        marker.removeFromSuperview()
        XCTAssertNil(spot.frame, "and it gives none again once it has left")
    }

    func testAMarkerNotYetLaidOutGivesNoPlace() throws {
        let spot = PanelSpot(), marker = PanelMarker()
        try window().addSubview(marker)
        spot.keep(marker)
        XCTAssertNil(spot.frame, "in a window, but with no size to hang a card from")
        marker.frame = CGRect(x: 40, y: 60, width: 80, height: 44)
        XCTAssertEqual(spot.frame, CGRect(x: 40, y: 60, width: 80, height: 44))
    }

    /// As the library's bar changes width its buttons are made again with what they knew kept, and the marker going out is heard from last.
    func testTheMarkerOnShowIsAskedWhenABarMakesItsButtonsAgain() throws {
        let window = try window(), spot = PanelSpot()
        var old: PanelMarker? = PanelMarker(frame: CGRect(x: 600, y: 32, width: 115, height: 44))
        window.addSubview(try XCTUnwrap(old))
        spot.keep(try XCTUnwrap(old))
        let new = PanelMarker(frame: CGRect(x: 420, y: 32, width: 46, height: 44))
        spot.keep(new)
        XCTAssertEqual(spot.frame, CGRect(x: 600, y: 32, width: 115, height: 44), "the new marker is in no window yet")
        spot.keep(try XCTUnwrap(old))
        window.addSubview(new)
        XCTAssertEqual(spot.frame, CGRect(x: 420, y: 32, width: 46, height: 44), "both on show for a moment: the newer one")
        old?.removeFromSuperview()
        old = nil
        XCTAssertEqual(spot.frame, CGRect(x: 420, y: 32, width: 46, height: 44), "the old marker going doesn't take the place with it")
    }

    func testTheOldMarkerGoingFirstLeavesTheNewOne() throws {
        let window = try window(), spot = PanelSpot()
        var old: PanelMarker? = PanelMarker(frame: CGRect(x: 600, y: 32, width: 115, height: 44))
        window.addSubview(try XCTUnwrap(old))
        spot.keep(try XCTUnwrap(old))
        old?.removeFromSuperview()
        spot.keep(try XCTUnwrap(old))
        old = nil
        XCTAssertNil(spot.frame)
        let new = PanelMarker(frame: CGRect(x: 420, y: 32, width: 46, height: 44))
        spot.keep(new)
        window.addSubview(new)
        XCTAssertEqual(spot.frame, CGRect(x: 420, y: 32, width: 46, height: 44))
    }

    func testAWatchedSpotTellsOfItsControlComingOnShowAndMoving() async throws {
        let window = try window(), spot = PanelSpot(), marker = PanelMarker(frame: CGRect(x: 40, y: 60, width: 80, height: 44))
        var told = 0
        marker.moved = { told += 1 }
        spot.keep(marker)
        spot.watch(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(told, 0, "nothing has changed")
        window.addSubview(marker)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(told, 1, "it came on show")
        marker.frame.origin.x = 300
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(told, 2, "it moved")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(told, 2, "and is told once for each move")
        spot.watch(false)
        marker.frame.origin.x = 500
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(told, 2, "no longer watched")
    }

    func testACardHangsFromTheGivenPartOfItsControl() {
        let frame = CGRect(x: 600, y: 32, width: 115, height: 20)
        XCTAssertNil(PanelSpot.anchor(for: nil, within: nil, least: 0), "a control not on show gives nothing to hang from")
        XCTAssertNil(PanelSpot.anchor(for: nil, within: CGRect(x: 10, y: 56, width: 380, height: 0), least: 44))
        XCTAssertEqual(PanelSpot.anchor(for: frame, within: nil, least: 0), frame)
        XCTAssertEqual(PanelSpot.anchor(for: frame, within: nil, least: 44), CGRect(x: 600, y: 20, width: 115, height: 44), "a short control is taken as tall as the bar's others")
        XCTAssertEqual(PanelSpot.anchor(for: frame, within: CGRect(x: 10, y: 56, width: 380, height: 0), least: 0),
                       CGRect(x: 610, y: 88, width: 380, height: 0), "a part of the control is counted from the control's corner")
    }
}

@MainActor @Observable
private final class Stand {
    var isOpen = false
    var x: CGFloat = 300
    @ObservationIgnored weak var card: UIView?

    var cardFrame: CGRect? { card.flatMap { $0.window == nil ? nil : $0.convert($0.bounds, to: nil) } }
}

private struct CardReader: UIViewRepresentable {
    let stand: Stand

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        stand.card = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { stand.card = view }
}

/// A control 80 by 40 at (x, 200), whose card is 200 by 100.
private struct StandView: View {
    let stand: Stand

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            Color.red.frame(width: 80, height: 40)
                .modifier(PanelPresenter(isPresented: Binding(get: { stand.isOpen }, set: { stand.isOpen = $0 })) {
                    CardReader(stand: stand).frame(width: 200, height: 100)
                })
                .padding(.leading, stand.x)
                .padding(.top, 200)
        }
        .ignoresSafeArea()
    }
}

/// The presenter itself, in a window: where the card lands when its control is off show, just made, or moves.
@MainActor
final class PanelPlacementTests: XCTestCase {
    private func show(_ stand: Stand, inWindow: Bool = true) throws -> (UIWindow, UIHostingController<StandView>) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIHostingController(rootView: StandView(stand: stand))
        if inWindow {
            window.rootViewController = host
            window.makeKeyAndVisible()
        }
        addTeardownBlock { @MainActor in
            host.dismiss(animated: false)
            window.isHidden = true
        }
        return (window, host)
    }

    /// Where the card stands once it is up and has stopped moving.
    private func card(_ stand: Stand, at place: CGPoint? = nil) async -> CGRect? {
        let end = Date().addingTimeInterval(4)
        while stand.cardFrame == nil || (place != nil && stand.cardFrame?.origin != place), Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(200))
        return stand.cardFrame
    }

    /// Under the control's left edge, 2 points below it.
    private func under(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 242, width: 200, height: 100) }

    func testACardOpensUnderItsControl() async throws {
        let stand = Stand()
        _ = try show(stand)
        try await Task.sleep(for: .milliseconds(300))
        stand.isOpen = true
        let frame = await card(stand)
        XCTAssertEqual(frame, under(300))
    }

    func testACardAskedForBeforeItsControlIsOnShowOpensUnderIt() async throws {
        let stand = Stand()
        stand.isOpen = true
        let (window, host) = try show(stand, inWindow: false)
        try await Task.sleep(for: .milliseconds(200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let frame = await card(stand)
        XCTAssertEqual(frame, under(300))
    }

    func testACardAskedForWhileItsControlIsInNoWindowWaitsForIt() async throws {
        let stand = Stand()
        let (window, host) = try show(stand)
        try await Task.sleep(for: .milliseconds(300))
        let holder = host.view.superview
        host.view.removeFromSuperview()
        stand.isOpen = true
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(stand.cardFrame, "nothing to hang it from yet")
        (holder ?? window).addSubview(host.view)
        let frame = await card(stand)
        XCTAssertEqual(frame, under(300), "under its control, not in the corner")
    }

    func testAnOpenCardFollowsItsControl() async throws {
        let stand = Stand()
        _ = try show(stand)
        try await Task.sleep(for: .milliseconds(300))
        stand.isOpen = true
        let first = await card(stand)
        XCTAssertEqual(first, under(300))
        stand.x = 500
        let moved = await card(stand, at: under(500).origin)
        XCTAssertEqual(moved, under(500), "the card goes with its control")
    }

    func testACardOpenedAsItsControlMovesStandsWhereTheControlEndsUp() async throws {
        let stand = Stand()
        _ = try show(stand)
        try await Task.sleep(for: .milliseconds(300))
        stand.x = 500
        stand.isOpen = true
        let frame = await card(stand, at: under(500).origin)
        XCTAssertEqual(frame, under(500), "not where the control was before this layout")
    }
}
