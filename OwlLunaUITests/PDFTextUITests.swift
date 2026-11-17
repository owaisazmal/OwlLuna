import XCTest

/// A PDF's own text: selected by dragging across it, highlighted, and a highlighter drawn along a line snapping to it.
@MainActor
final class PDFTextUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func strokeCount(_ canvas: XCUIElement) -> Int {
        Int(((canvas.value as? String) ?? "").split(separator: " ").first ?? "") ?? 0
    }

    private func drag(on canvas: XCUIElement, from start: CGVector, to end: CGVector) {
        canvas.coordinate(withNormalizedOffset: start)
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: end), withVelocity: 300, thenHoldForDuration: 0.1)
    }

    /// The seeded textbook's pages are Letter: a heading, then body lines 20 pt apart from 130 pt down, 72 pt in.
    private func line(_ number: Int, x: CGFloat) -> CGVector {
        CGVector(dx: x / 612, dy: (136.5 + CGFloat(number - 1) * 20) / 792)
    }

    func testTextIsSelectedCopiedAndHighlightedAndAHighlighterSnapsToItsLine() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "pdftext", "-resetStorage", "-seedLongPDF", "-drawingInput", "anyInput", "-freshToolPresets"]
        app.launch()
        let notebook = app.buttons["notebook.Textbook"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 60))
        notebook.tap()
        let ribbon = app.buttons["editor.ribbon"]
        XCTAssertTrue(ribbon.waitForExistence(timeout: 20))
        let canvas = app.element("page.canvas.1")
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        app.chooseFromMore("Select PDF Text", in: "Select")
        XCTAssertTrue(app.staticTexts["editor.text.status"].waitForExistence(timeout: 5), "the bar says what to do")
        XCTAssertFalse(ribbon.exists, "the chrome is put away while text is selected")
        let copy = app.buttons["editor.text.copy"], highlight = app.buttons["editor.text.highlight"]
        XCTAssertFalse(copy.exists, "nothing is selected yet")

        // A drag along the third line, from its start to past its end, selects that line.
        drag(on: canvas, from: line(3, x: 74), to: line(3, x: 420))
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "a drag across the text selects it")
        XCTAssertEqual(copy.value as? String, "7 words", "“Body text line 3 on page 1.”")
        attach(app, "text-line")

        // Down the page it takes in the lines between.
        drag(on: canvas, from: line(5, x: 74), to: line(7, x: 150))
        wait(for: [expectation(for: NSPredicate(format: "value BEGINSWITH '1' OR value BEGINSWITH '2'"), evaluatedWith: copy)], timeout: 5)
        attach(app, "text-lines")
        try audit(app, screen: "select text", bar: app.otherElements["editor.text.bar"])
        copy.tap()

        highlight.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == '3 strokes'"), evaluatedWith: canvas)], timeout: 10)
        XCTAssertFalse(copy.exists, "highlighted, the selection is let go")
        attach(app, "text-highlighted")

        // Every word on the page, without a drag.
        app.buttons["editor.text.all"].tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let all = Int((copy.value as? String ?? "").split(separator: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(all, 200, "thirty lines of seven words and the heading")
        attach(app, "text-all")
        app.buttons["editor.text.done"].tap()
        XCTAssertTrue(ribbon.waitForExistence(timeout: 5), "back to writing")
        XCTAssertEqual(strokeCount(canvas), 3, "the highlight stays, as ink")

        // One undo takes the whole highlight off.
        app.buttons["editor.undo"].tap()
        wait(for: [expectation(for: NSPredicate(format: "value == 'Empty'"), evaluatedWith: canvas)], timeout: 5)

        // The highlighter from the tool tray, drawn roughly along a line, is laid over that line as a
        // second undo step: the first undo gives the hand-drawn stroke back, the second takes it away.
        app.buttons["editor.tools.4"].tap()
        drag(on: canvas, from: line(9, x: 80), to: line(9, x: 200))
        wait(for: [expectation(for: NSPredicate(format: "value == '1 stroke'"), evaluatedWith: canvas)], timeout: 5)
        sleep(2)
        attach(app, "highlighter-snapped")
        app.buttons["editor.undo"].tap()
        sleep(1)
        XCTAssertEqual(strokeCount(canvas), 1, "the first undo gives back the stroke as it was drawn")
        attach(app, "highlighter-drawn")
        app.buttons["editor.undo"].tap()
        wait(for: [expectation(for: NSPredicate(format: "value == 'Empty'"), evaluatedWith: canvas)], timeout: 5)

        // Off the text, a highlighter stroke is left as drawn: one undo removes it.
        drag(on: canvas, from: CGVector(dx: 0.6, dy: 0.5), to: CGVector(dx: 0.9, dy: 0.5))
        wait(for: [expectation(for: NSPredicate(format: "value == '1 stroke'"), evaluatedWith: canvas)], timeout: 5)
        sleep(2)
        app.buttons["editor.undo"].tap()
        wait(for: [expectation(for: NSPredicate(format: "value == 'Empty'"), evaluatedWith: canvas)], timeout: 5)
    }
}
