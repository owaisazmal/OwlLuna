import XCTest
import UIKit
@testable import OwlLuna

/// The pages keep the reader's place when the editor changes size: a new height moves nothing, and a turn or a
/// dragged divider keeps the same point of the page in the same part of the view.
@MainActor
final class PageResizeTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
    private let portrait = CGSize(width: 834, height: 1194)
    private let landscape = CGSize(width: 1194, height: 834)
    private let middle = CGPoint(x: 0.5, y: 0.5)
    private let sheet = PageSize.letter.points

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func makeDocument(items: [PageItem] = []) async throws -> NotebookDocument {
        let root = temporaryRoot(self)
        var pages = (0..<5).map { _ in paper.newPage() }
        pages[2].items = items
        let manifest = NotebookManifest(title: "Resize", defaults: paper, pages: pages)
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        return try await NotebookDocument.open(manifest.id, root: root)
    }

    /// The page stack in a window of its own, `size` or upright, or under a bar of `bar` points, once its first page has loaded.
    private func show(_ document: NotebookDocument, under bar: CGFloat? = nil, size: CGSize? = nil) async throws -> (EditorSession, PageStackController, UIWindow) {
        let session = EditorSession(document: document)
        let controller = PageStackController(session: session)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size ?? portrait)
        if let bar {
            let container = UIViewController()
            container.addChild(controller)
            container.view.addSubview(controller.view)
            controller.view.frame = CGRect(x: 0, y: bar, width: portrait.width, height: portrait.height - bar)
            controller.didMove(toParent: container)
            window.rootViewController = container
        } else {
            window.rootViewController = controller
        }
        window.makeKeyAndVisible()
        // The container takes the window's size only once shown; on an iPhone, whose screen is smaller, it would stretch the stack with it.
        if let bar { controller.view.frame = CGRect(x: 0, y: bar, width: portrait.width, height: portrait.height - bar) }
        window.overrideUserInterfaceStyle = .light
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where controller.canvas(forPage: 0)?.isLoaded != true { await pause(0.05) }
        await pause(0.2)
        return (session, controller, window)
    }

    private func scrollView(of controller: PageStackController) throws -> UIScrollView {
        try XCTUnwrap(controller.view.subviews.lazy.compactMap { $0 as? UIScrollView }.first)
    }

    /// Where a point of a page is in the window.
    private func place(of point: CGPoint, onPage index: Int, _ controller: PageStackController) throws -> CGPoint {
        let slot = try XCTUnwrap(controller.canvas(forPage: index)?.superview, "page \(index + 1) is live")
        let scale = slot.bounds.width / sheet.width
        return slot.convert(CGPoint(x: point.x * scale, y: point.y * scale), to: nil)
    }

    /// The same as a share of the page stack's view.
    private func share(of point: CGPoint, onPage index: Int, _ controller: PageStackController) throws -> CGPoint {
        let local = controller.view.convert(try place(of: point, onPage: index, controller), from: nil)
        return CGPoint(x: local.x / controller.view.bounds.width, y: local.y / controller.view.bounds.height)
    }

    /// Scrolls so a point of page 3 is at `share` of the view. At fit width only the height can be chosen.
    private func bring(_ point: CGPoint, to share: CGPoint, _ controller: PageStackController) throws {
        let scroll = try scrollView(of: controller), view = try XCTUnwrap(controller.view)
        let at = view.convert(try place(of: point, onPage: 2, controller), from: nil)
        let wanted = CGPoint(x: share.x * view.bounds.width, y: share.y * view.bounds.height)
        let sideways = controller.zoom > 1.01 ? at.x - wanted.x : 0
        scroll.contentOffset = CGPoint(x: scroll.contentOffset.x + sideways, y: scroll.contentOffset.y + at.y - wanted.y)
        XCTAssertGreaterThan(point.y, sheet.height / 2, "the point is in the lower half of the page")
    }

    /// Resizes the window, as turning the iPad or Stage Manager does. Unless `dragging`, it waits long enough for the
    /// next change not to be taken for a divider being dragged.
    private func resize(_ window: UIWindow, _ controller: PageStackController, to size: CGSize, dragging: Bool = false) async {
        window.frame = CGRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        if !dragging { await pause(0.4) }
    }

    private func assertNear(_ shown: CGPoint, _ expected: CGPoint, _ accuracy: CGFloat, _ message: String, line: UInt = #line) {
        XCTAssertEqual(shown.x, expected.x, accuracy: accuracy, message, line: line)
        XCTAssertEqual(shown.y, expected.y, accuracy: accuracy, message, line: line)
    }

    // MARK: Height

    func testANewHeightMovesNothingAndLaysNothingOutAgain() async throws {
        let (_, controller, window) = try await show(try await makeDocument())
        let point = CGPoint(x: 400, y: 600)
        for zoom: CGFloat in [1, 5] {
            controller.scrollToPage(2)
            controller.setZoom(zoom)
            try bring(point, to: CGPoint(x: 0.5, y: 0.6), controller)
            let before = try place(of: point, onPage: 2, controller), bakes = controller.bakeCount
            for height: CGFloat in [1150, 1194, 900, 1194] {
                await resize(window, controller, to: CGSize(width: portrait.width, height: height))
                assertNear(try place(of: point, onPage: 2, controller), before, 1, "at \(zoom)×, \(height) points tall")
            }
            XCTAssertEqual(controller.bakeCount, bakes, "at \(zoom)×, a new height lays nothing out again")
            XCTAssertEqual(controller.zoom, zoom, accuracy: 0.001)
        }
    }

    func testWhenTheTabsAboveGoThePagesStayStillOnTheScreen() async throws {
        let (_, controller, _) = try await show(try await makeDocument(), under: 50)
        let point = CGPoint(x: 306, y: 600)
        controller.scrollToPage(2)
        try bring(point, to: middle, controller)
        let before = try place(of: point, onPage: 2, controller), bakes = controller.bakeCount
        for frame in [CGRect(origin: .zero, size: portrait), CGRect(x: 0, y: 50, width: portrait.width, height: portrait.height - 50)] {
            controller.view.frame = frame
            controller.view.layoutIfNeeded()
            assertNear(try place(of: point, onPage: 2, controller), before, 1, "the ink stays under the same spot of the screen as the bar goes and comes back")
        }
        XCTAssertEqual(controller.bakeCount, bakes)
    }

    // MARK: Width

    func testTurningKeepsTheMiddleInTheMiddleAndTurningBackPutsItWhereItWas() async throws {
        let (_, controller, window) = try await show(try await makeDocument())
        for zoom: CGFloat in [1, 5] {
            let point = zoom == 1 ? CGPoint(x: 306, y: 560) : CGPoint(x: 370, y: 560)
            controller.scrollToPage(2)
            controller.setZoom(zoom)
            try bring(point, to: middle, controller)
            let before = try place(of: point, onPage: 2, controller)

            await resize(window, controller, to: landscape)
            assertNear(try place(of: point, onPage: 2, controller), CGPoint(x: landscape.width / 2, y: landscape.height / 2), 2,
                       "at \(zoom)×, the point that was in the middle is in the middle of the wider view")
            XCTAssertEqual(controller.zoom, zoom, accuracy: 0.001, "the zoom is kept")
            let canvas = try XCTUnwrap(controller.canvas(forPage: 2))
            XCTAssertEqual(canvas.zoomScale, zoom * landscape.width / (sheet.width + PageStackLayout.margin * 2), accuracy: 0.001,
                           "the ink is drawn at the new width")

            await resize(window, controller, to: portrait)
            assertNear(try place(of: point, onPage: 2, controller), before, 2, "at \(zoom)×, turning back puts it where it was")
        }
    }

    func testAPageGoneToKeepsItsTopAtTheTopWhenTurning() async throws {
        let (session, controller, window) = try await show(try await makeDocument())
        // Where Go to Page puts a page's top: under the safe area, past half the gap above the page.
        func underTheBar() throws -> CGFloat {
            let slot = try XCTUnwrap(controller.canvas(forPage: 2)?.superview)
            return controller.view.safeAreaInsets.top + PageStackLayout.margin / 2 * slot.bounds.width / sheet.width
        }
        session.go(to: 2, animated: false)
        XCTAssertEqual(try place(of: .zero, onPage: 2, controller).y, try underTheBar(), accuracy: 1)
        for size in [landscape, portrait] {
            await resize(window, controller, to: size)
            XCTAssertEqual(try place(of: .zero, onPage: 2, controller).y, try underTheBar(), accuracy: 1, "the page's top stays under the bar")
        }
        XCTAssertEqual(session.currentPage, 2)
    }

    func testDraggingADividerMagnifiesThePagesUntilTheWidthRests() async throws {
        let (_, controller, window) = try await show(try await makeDocument())
        let point = CGPoint(x: 306, y: 560)
        controller.scrollToPage(2)
        try bring(point, to: middle, controller)
        let bakes = controller.bakeCount
        for width in stride(from: CGFloat(828), through: 620, by: -8) {
            await resize(window, controller, to: CGSize(width: width, height: portrait.height), dragging: true)
            assertNear(try place(of: point, onPage: 2, controller), CGPoint(x: width / 2, y: portrait.height / 2), 2,
                       "\(width) points wide, the point stays in the middle")
        }
        XCTAssertLessThanOrEqual(controller.bakeCount - bakes, 1, "only the drag's first step lays the pages out again")
        let scroll = try scrollView(of: controller)
        XCTAssertNotEqual(scroll.zoomScale, 1, accuracy: 0.01, "in between, what was laid out is magnified")

        for _ in 0..<60 where scroll.zoomScale != 1 { await pause(0.05) }
        XCTAssertEqual(controller.bakeCount - bakes, 2, "once the width rests the pages are laid out again, once")
        XCTAssertEqual(scroll.zoomScale, 1)
        assertNear(try place(of: point, onPage: 2, controller), CGPoint(x: 310, y: portrait.height / 2), 2, "and nothing moves as they are")
        let canvas = try XCTUnwrap(controller.canvas(forPage: 2))
        XCTAssertEqual(canvas.zoomScale, 620 / (sheet.width + PageStackLayout.margin * 2), accuracy: 0.001)
    }

    // MARK: What is being worked on

    func testATextBoxBeingTypedInKeepsItsPlaceInTheViewWhenTurning() async throws {
        let box = TextBox(string: "Lower half", fontSize: 24)
        let item = PageItem(content: .text(box), center: CGPoint(x: 430, y: 640), size: CGSize(width: 200, height: box.height(width: 200)))
        let document = try await makeDocument(items: [item])
        // An iPhone's keyboard is its screen's, so there the window is the screen, upright and then on its side.
        let screen = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first).screen.bounds.size
        let upright = Device.isPhone ? screen : portrait, turned = CGSize(width: upright.height, height: upright.width)
        let (_, controller, window) = try await show(document, size: upright)
        controller.scrollToPage(2)
        // High enough that the keyboard, which UIKit keeps the box clear of, can't cover it in either shape.
        try bring(item.center, to: CGPoint(x: 0.5, y: 0.4), controller)
        controller.select(ItemSelection(pageID: document.pages[2].id, itemID: item.id))
        controller.editText()
        let textView = try XCTUnwrap(window.descendants(UITextView.self).first { $0.accessibilityIdentifier == "page.text.editor" })
        await pause(0.5)
        let before = try share(of: item.center, onPage: 2, controller)

        await resize(window, controller, to: turned)
        assertNear(try share(of: item.center, onPage: 2, controller), before, 0.01, "the box being typed in keeps its place in the view")
        XCTAssertTrue(controller.view.bounds.contains(controller.view.convert(textView.frame, from: textView.superview)))
        XCTAssertTrue(textView.isFirstResponder, "and typing goes on")
        controller.select(nil)
    }

    func testFindsMatchAndTheZoomWindowKeepTheirPlaceWhenTurning() async throws {
        let document = try await makeDocument()
        let (session, controller, window) = try await show(document)
        let rect = CGRect(x: 420, y: 620, width: 80, height: 20)
        controller.scrollToPage(2)
        try bring(CGPoint(x: rect.midX, y: rect.midY), to: CGPoint(x: 0.5, y: 0.75), controller)
        controller.setFinding(true)
        let match = FindMatch(pageID: document.pages[2].id, page: 2, rect: rect)
        controller.showFind([match], current: match)
        let before = try share(of: CGPoint(x: rect.midX, y: rect.midY), onPage: 2, controller)
        await resize(window, controller, to: landscape)
        assertNear(try share(of: CGPoint(x: rect.midX, y: rect.midY), onPage: 2, controller), before, 0.01, "Find's match keeps its place in the view")
        controller.setFinding(false)

        session.setZoomWindow(true)
        await pause(0.5)
        let shown = try XCTUnwrap(controller.zoomWindowRect)
        let target = try XCTUnwrap(window.descendants(ZoomTargetView.self).first)
        await resize(window, controller, to: portrait)
        XCTAssertEqual(try XCTUnwrap(controller.zoomWindowRect).origin, shown.origin, "the zoom window keeps its corner on the page")
        XCTAssertTrue(controller.view.bounds.contains(controller.view.convert(target.frame, from: target.superview)), "and its outline stays in view")
        session.setZoomWindow(false)
    }
}

private extension UIView {
    func descendants<View: UIView>(_ type: View.Type) -> [View] {
        subviews.flatMap { ($0 as? View).map { [$0] } ?? [] + $0.descendants(type) }
    }
}
