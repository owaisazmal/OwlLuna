import XCTest

/// Taps of fingers on the pages run the actions chosen in Settings: two fingers undo and three redo until changed.
@MainActor
final class FingerTapUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func strokeCount(_ canvas: XCUIElement) -> Int {
        Int(((canvas.value as? String) ?? "").split(separator: " ").first ?? "") ?? 0
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "fingers", "-resetStorage", "-seedLibrary", "3", "-freshToolPresets"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["notebook.Physics II 3"].waitForExistence(timeout: 30))
        return app
    }

    private func openNotebook(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["notebook.Physics II 3"].tap()
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        return canvas
    }

    func testTwoFingersUndoAndThreeFingersRedo() {
        let app = launch(["-drawingInput", "anyInput", "-fingerDoubleTap", "toggleTools"])
        let canvas = openNotebook(app)
        func draw(atHeight y: CGFloat) {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: y))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: y)), withVelocity: 400, thenHoldForDuration: 0.05)
        }
        let start = strokeCount(canvas)
        draw(atHeight: 0.3)
        draw(atHeight: 0.5)
        XCTAssertEqual(strokeCount(canvas), start + 2)

        canvas.twoFingerTap()
        XCTAssertEqual(strokeCount(canvas), start + 1, "two fingers undo the last stroke, and draw nothing")
        canvas.twoFingerTap()
        XCTAssertEqual(strokeCount(canvas), start)
        canvas.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertEqual(strokeCount(canvas), start + 1, "three fingers redo")
        attach(app, "after-three-finger-tap")
        canvas.tap(withNumberOfTaps: 1, numberOfTouches: 3)
        XCTAssertEqual(strokeCount(canvas), start + 2)

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).doubleTap()
        sleep(1)
        XCTAssertTrue(app.element("editor.tools.tray").exists, "where a finger draws, a double-tap only draws")
    }

    func testTheTapsAreChosenInSettingsAndOneFingerDoubleTapsOnBarePaper() {
        let app = launch(["-drawingInput", "pencilOnly"])
        let settings = app.buttons["Settings"].firstMatch
        if !settings.isHittable { app.buttons["ToggleSidebar"].firstMatch.tap() }
        settings.tap()
        let doubleTap = app.buttons["settings.fingers.doubleTap"], two = app.buttons["settings.fingers.twoFingerTap"]
        let three = app.buttons["settings.fingers.threeFingerTap"]
        for _ in 0..<8 where !three.exists || !three.isHittable { app.swipeUp() }
        XCTAssertTrue(three.waitForExistence(timeout: 5))
        XCTAssertEqual(doubleTap.value as? String, "Off")
        XCTAssertEqual(two.value as? String, "Undo")
        XCTAssertEqual(three.value as? String, "Redo")
        attach(app, "settings")

        let systemSettings = app.buttons.matching(identifier: "System Setting").count
        doubleTap.tap()
        XCTAssertTrue(app.buttons["Show or Hide Tools"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "System Setting").count, systemSettings, "fingers have no system setting to follow")
        app.buttons["Show or Hide Tools"].tap()
        XCTAssertEqual(doubleTap.value as? String, "Show or Hide Tools")
        app.buttons["Done"].firstMatch.tap()

        let canvas = openNotebook(app)
        let tray = app.element("editor.tools.tray")
        XCTAssertTrue(tray.waitForExistence(timeout: 5))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).doubleTap()
        XCTAssertTrue(tray.waitForNonExistence(timeout: 5), "one finger's double-tap puts the tools away")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).doubleTap()
        XCTAssertTrue(tray.waitForExistence(timeout: 5), "and brings them back")
    }
}
