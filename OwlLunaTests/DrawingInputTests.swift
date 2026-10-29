import XCTest
@testable import OwlLuna

/// What draws at first, and the notice for a finger that drags where only the Pencil draws.
final class DrawingInputTests: XCTestCase {
    private func ownSettings() throws -> UserDefaults {
        let suite = "owlluna-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    @MainActor
    func testAMacAndAnIPhoneStartWithFingersDrawing() {
        XCTAssertEqual(DrawingInput.initial(isMac: false), .pencilOnly)
        XCTAssertEqual(DrawingInput.initial(isMac: true), .anyInput, "a Mac has no Pencil")
        XCTAssertEqual(DrawingInput.initial(isMac: false, isPhone: true), .anyInput, "nor has an iPhone at first")
        XCTAssertEqual(DrawingInput.initial(isMac: false, isPhone: true, pencilSeen: true), .pencilOnly, "until a Pencil touches it")
        XCTAssertEqual(DrawingInput.initial, DrawingInput.initial(isMac: ProcessInfo.processInfo.isiOSAppOnMac, isPhone: Device.isPhone,
                                                                  pencilSeen: UserDefaults.standard.bool(forKey: SettingsKey.pencilSeen)))
    }

    func testTheFirstPencilTouchIsToldOnce() throws {
        let defaults = try ownSettings()
        let told = expectation(forNotification: .owlLunaPencilSeen, object: nil)
        told.assertForOverFulfill = true
        FingerDrawHint.pencilTouched(defaults: defaults)
        FingerDrawHint.pencilTouched(defaults: defaults)
        wait(for: [told], timeout: 1)
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.pencilSeen))
    }

    func testTheNoticeIsShownOncePerInstall() throws {
        let defaults = try ownSettings()
        XCTAssertTrue(FingerDrawHint.isAllowed, "only UI tests keep it off")
        XCTAssertFalse(FingerDrawHint.take(input: .anyInput, penInHand: true, defaults: defaults), "fingers already draw")
        XCTAssertFalse(FingerDrawHint.take(input: .system, penInHand: true, defaults: defaults), "the iPad's own setting was chosen")
        XCTAssertFalse(FingerDrawHint.take(input: .pencilOnly, penInHand: false, defaults: defaults), "the eraser or the lasso is in hand")
        XCTAssertTrue(FingerDrawHint.take(input: .pencilOnly, penInHand: true, defaults: defaults))
        XCTAssertFalse(FingerDrawHint.take(input: .pencilOnly, penInHand: true, defaults: defaults), "once")
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.fingerDrawHintSeen))
    }

    func testThePencilTouchingThePagesMakesTheNoticeNeedless() throws {
        let defaults = try ownSettings()
        FingerDrawHint.pencilTouched(defaults: defaults)
        XCTAssertFalse(FingerDrawHint.take(input: .pencilOnly, penInHand: true, defaults: defaults))
    }

    func testOnlyOneFingerDraggedAloneCounts() {
        func lifted(_ moves: (inout FingerDrag) -> Void) -> Bool {
            var drag = FingerDrag()
            moves(&drag)
            return drag.lifted()
        }
        XCTAssertTrue(lifted { $0.began(isPencil: false, at: .zero); $0.moved(to: CGPoint(x: 0, y: 60)) })
        XCTAssertFalse(lifted { $0.began(isPencil: false, at: .zero); $0.moved(to: CGPoint(x: 8, y: 8)) }, "a tap")
        XCTAssertFalse(lifted { $0.began(isPencil: true, at: .zero); $0.moved(to: CGPoint(x: 0, y: 60)) }, "the Pencil")
        XCTAssertFalse(lifted {
            $0.began(isPencil: false, at: .zero)
            $0.moved(to: CGPoint(x: 0, y: 60))
            $0.began(isPencil: false, at: CGPoint(x: 80, y: 0))
        }, "two fingers scroll or pinch")
        XCTAssertFalse(lifted { $0.began(isPencil: false, at: .zero); $0.moved(to: CGPoint(x: 0, y: 60)); $0.cancelled() }, "cancelled")

        var drag = FingerDrag()
        drag.began(isPencil: false, at: .zero)
        drag.began(isPencil: false, at: CGPoint(x: 80, y: 0))
        XCTAssertFalse(drag.lifted())
        drag.began(isPencil: false, at: .zero)
        drag.moved(to: CGPoint(x: 60, y: 0))
        XCTAssertTrue(drag.lifted(), "each time the pages are let go of it starts afresh")
    }
}
