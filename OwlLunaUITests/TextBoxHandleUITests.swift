import XCTest

/// A text box's handles under real drags: the tab resizes and never tilts, the knob turns and never resizes, and
/// both stay on the page when the box hangs off it.
@MainActor
final class TextBoxHandleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The width a handle says, from "280 by 21 pt".
    private func width(_ handle: XCUIElement) throws -> Int {
        try XCTUnwrap(Int(try XCTUnwrap((handle.value as? String)?.split(separator: " ").first)))
    }

    func testTheTabResizesTheKnobTurnsAndBothStayOnThePage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "texthandles", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "pencilOnly", "-appearance", "light"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Text Box"].firstMatch.tap()
        let editor = app.textViews["page.text.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("Eggs and milk")
        app.buttons["editor.arrange.done"].tap()
        let box = app.staticTexts["Eggs and milk"]
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.tap()

        let tab = app.otherElements["Resize"].firstMatch, knob = app.element("page.knob"), grip = app.element("page.grip.right")
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "a selected text box has a tab on its corner")
        XCTAssertTrue(knob.exists && grip.exists, "a knob on a stalk and its width grip")
        XCTAssertFalse(app.otherElements["Resize and rotate"].exists)
        XCTAssertLessThan(knob.frame.midY, box.frame.minY, "the knob stands over the box")
        attach(app, "text-box-handles")
        knob.tap()
        XCTAssertFalse(editor.waitForExistence(timeout: 1), "a tap on the knob is not a tap on the words")
        XCTAssertTrue(tab.exists)
        // Points on the window: one taken from a handle is looked up again at every step of the drag, as the handle moves.
        let window = app.coordinate(withNormalizedOffset: .zero)
        func drag(_ handle: XCUIElement, by offset: CGVector) {
            let from = handle.frame
            window.withOffset(CGVector(dx: from.midX, dy: from.midY))
                .press(forDuration: 0.1, thenDragTo: window.withOffset(CGVector(dx: from.midX + offset.dx, dy: from.midY + offset.dy)),
                       withVelocity: 200, thenHoldForDuration: 0.3)
        }

        let first = try width(tab)
        drag(tab, by: CGVector(dx: 0, dy: 70))
        XCTAssertEqual(knob.value as? String, "Upright", "a drag straight down on the tab never tilts the box")
        XCTAssertEqual(Double(try width(tab)), Double(first), accuracy: Double(first) * 0.1, "and changes its size only a little")
        drag(tab, by: CGVector(dx: -60, dy: 8))
        let larger = try width(tab)
        XCTAssertGreaterThan(larger, first + 40, "a drag away from the box's middle makes it larger")
        XCTAssertEqual(knob.value as? String, "Upright")

        drag(knob, by: CGVector(dx: 60, dy: 10))
        XCTAssertTrue((knob.value as? String)?.hasSuffix("right") ?? false, "the knob turns the box: \(knob.value ?? "")")
        XCTAssertEqual(try width(tab), larger, "and never resizes it")
        attach(app, "text-box-turned")
        app.buttons["editor.undo"].tap()
        XCTAssertEqual(knob.value as? String, "Upright", "a turn is one undo step")

        let middle = box.frame
        window.withOffset(CGVector(dx: middle.midX, dy: middle.midY))
            .press(forDuration: 0.1, thenDragTo: window.withOffset(CGVector(dx: canvas.frame.minX + 10, dy: middle.midY)), withVelocity: 200, thenHoldForDuration: 0.3)
        XCTAssertLessThan(box.frame.minX, canvas.frame.minX - 40, "half the box hangs off the page")
        for handle in [tab, knob, grip] {
            XCTAssertGreaterThan(handle.frame.midX, canvas.frame.minX + 8, "every handle stays on the page")
            XCTAssertLessThan(handle.frame.midX, canvas.frame.maxX - 8)
        }
        attach(app, "text-box-off-the-edge")
        let hanging = try width(tab)
        drag(tab, by: CGVector(dx: 40, dy: 0))
        XCTAssertLessThan(try width(tab), hanging - 20, "the tab still resizes the box from the page's edge")
        XCTAssertGreaterThan(try width(tab), hanging / 2, "and no quicker than from its corner")
    }
}
