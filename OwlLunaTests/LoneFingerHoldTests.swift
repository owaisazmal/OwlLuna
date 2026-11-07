import XCTest
import PencilKit
@testable import OwlLuna

/// PencilKit's touch and hold on handwriting opens for one fingertip alone, never for a resting palm.
final class LoneFingerHoldTests: XCTestCase {
    func testOneFingertipAloneMayHold() {
        var hold = LoneFingerHold()
        hold.began("finger", isPencil: false, radius: 11)
        XCTAssertTrue(hold.isLoneFinger)
        hold.moved("finger", radius: 12)
        XCTAssertTrue(hold.isLoneFinger)
        hold.ended("finger")
        XCTAssertFalse(hold.isTouching)
    }

    func testAPalmASecondFingerOrThePencilsHandMayNot() {
        var hold = LoneFingerHold()
        hold.began("palm", isPencil: false, radius: 30)
        XCTAssertFalse(hold.isLoneFinger, "a wide touch is the side of a hand")

        hold = LoneFingerHold()
        hold.began("finger", isPencil: false, radius: 11)
        hold.began("thumb", isPencil: false, radius: 12)
        XCTAssertFalse(hold.isLoneFinger)
        hold.ended("thumb")
        XCTAssertFalse(hold.isLoneFinger, "and the touches stay crowded until every one has lifted")

        hold = LoneFingerHold()
        hold.began("pencil", isPencil: true, radius: 1)
        hold.began("finger", isPencil: false, radius: 11)
        XCTAssertFalse(hold.isLoneFinger, "a finger beside the Pencil is the hand holding it")

        hold = LoneFingerHold()
        hold.began("finger", isPencil: false, radius: 11)
        hold.moved("finger", radius: 28)
        XCTAssertFalse(hold.isLoneFinger, "a touch that widens is a hand settling")
    }

    @MainActor
    func testEveryHandwritingHoldOnACanvasWaitsForTheGuard() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        let canvas = PageCanvasView(frame: window.bounds)
        let controller = UIViewController()
        controller.view.addSubview(canvas)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        XCTAssertTrue(canvas.gestureRecognizers?.contains { $0 is LoneFingerHoldGuard } == true)
        guard #available(iOS 27, *) else { return }
        XCTAssertEqual(canvas.guardedHolds, LoneFingerHoldGuard.guardedNames.count, "PencilKit's handwriting holds are found by name")
    }
}
