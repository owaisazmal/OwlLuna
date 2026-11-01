import XCTest

/// Scribble to erase and circle and hold to select, on a real canvas. XCUITest can only drag in straight lines, so
/// `-fakePencilGestures` lets a straight stroke stand in for the zigzag and for the loop.
@MainActor
final class PencilGestureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func strokeCount(_ canvas: XCUIElement) -> Int {
        Int(((canvas.value as? String) ?? "").split(separator: " ").first ?? "") ?? 0
    }

    func testAScribbleErasesAndALoopSelects() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "gestures", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput", "-fakePencilGestures", "-freshToolPresets"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        let settings = app.buttons["Settings"].firstMatch
        if !settings.isHittable { app.buttons["ToggleSidebar"].firstMatch.tap() }
        settings.tap()
        let scribble = app.switches["settings.pencil.scribble"]
        for _ in 0..<6 where !scribble.exists || !scribble.isHittable { app.swipeUp() }
        XCTAssertTrue(scribble.waitForExistence(timeout: 5))
        XCTAssertEqual(scribble.value as? String, "0", "scribble erasing starts off")
        scribble.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(scribble.value as? String, "1", "the gesture can be enabled explicitly")
        app.buttons["Done"].firstMatch.tap()
        notebook.tap()
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        let undo = app.buttons["editor.undo"]
        func draw(_ from: CGVector, _ to: CGVector, hold: TimeInterval = 0.05) {
            canvas.coordinate(withNormalizedOffset: from).press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: to), withVelocity: 400, thenHoldForDuration: hold)
        }
        let start = strokeCount(canvas)

        draw(CGVector(dx: 0.25, dy: 0.3), CGVector(dx: 0.7, dy: 0.3))
        draw(CGVector(dx: 0.25, dy: 0.5), CGVector(dx: 0.7, dy: 0.5))
        XCTAssertEqual(strokeCount(canvas), start + 2)

        draw(CGVector(dx: 0.25, dy: 0.3), CGVector(dx: 0.7, dy: 0.3))
        XCTAssertEqual(strokeCount(canvas), start + 1, "a stroke over the first line takes it away, and is not kept itself")
        undo.tap()
        XCTAssertEqual(strokeCount(canvas), start + 2, "one undo brings the line back without the scribble")
        draw(CGVector(dx: 0.25, dy: 0.7), CGVector(dx: 0.7, dy: 0.7))
        XCTAssertEqual(strokeCount(canvas), start + 3, "and writing on doesn't bring the scribble back")

        draw(CGVector(dx: 0.15, dy: 0.45), CGVector(dx: 0.8, dy: 0.55), hold: 1.2)
        let status = app.staticTexts["editor.ink.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "a held loop round ink starts selecting")
        XCTAssertEqual(status.label, "1 stroke. Drag it to move it.")
        XCTAssertEqual(strokeCount(canvas), start + 3, "and the loop is not kept as ink")
        app.buttons["editor.ink.undo"].tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "undo goes back to writing")
        XCTAssertEqual(strokeCount(canvas), start + 4, "with the loop as it was drawn")
        undo.tap()
        XCTAssertEqual(strokeCount(canvas), start + 3)

        draw(CGVector(dx: 0.15, dy: 0.45), CGVector(dx: 0.8, dy: 0.55), hold: 1.2)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        app.buttons["editor.ink.delete"].tap()
        XCTAssertEqual(strokeCount(canvas), start + 2)
        app.buttons["editor.ink.done"].tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertEqual(strokeCount(canvas), start + 3, "undo brings back what was deleted")
        undo.tap()
        XCTAssertEqual(strokeCount(canvas), start + 4, "and then the loop")
        undo.tap()
        XCTAssertEqual(strokeCount(canvas), start + 3, "and then takes it away")
        draw(CGVector(dx: 0.25, dy: 0.8), CGVector(dx: 0.7, dy: 0.8))
        XCTAssertEqual(strokeCount(canvas), start + 4, "writing carries on")
    }
}
