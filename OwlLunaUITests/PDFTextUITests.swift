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

    /// The darkest of the screen's pixels in a part of the canvas, from 0 for black to 1, and how many of them are the highlighter's yellow.
    private func tones(on canvas: XCUIElement, from start: CGVector, to end: CGVector, in app: XCUIApplication) throws -> (darkest: CGFloat, yellow: Int) {
        let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage), frame = canvas.frame
        let scale = CGFloat(image.width) / app.frame.width
        let rect = CGRect(x: (frame.minX + start.dx * frame.width) * scale, y: (frame.minY + start.dy * frame.height) * scale,
                          width: (end.dx - start.dx) * frame.width * scale, height: (end.dy - start.dy) * frame.height * scale).integral
        let width = Int(rect.width), height = Int(rect.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try XCTUnwrap(image.cropping(to: rect)), in: CGRect(x: 0, y: 0, width: width, height: height))
        var darkest: CGFloat = 1, yellow = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = CGFloat(pixels[index]) / 255, green = CGFloat(pixels[index + 1]) / 255, blue = CGFloat(pixels[index + 2]) / 255
            darkest = min(darkest, 0.2126 * red + 0.7152 * green + 0.0722 * blue)
            if red > 0.8, green > 0.6, blue < 0.7 { yellow += 1 }
        }
        return (darkest, yellow)
    }

    /// Issue #38: the highlighter is multiplied into the page, so print under it stays as dark as it was, and the
    /// eraser can be kept to the highlighter, so a pen's line through a highlight stays.
    func testPrintStaysDarkUnderTheHighlighterAndTheEraserCanKeepToIt() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "pdfmarker", "-resetStorage", "-seedLongPDF", "-drawingInput", "anyInput", "-freshToolPresets", "-appearance", "light"]
        app.launch()
        let notebook = app.buttons["notebook.Textbook"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 60))
        notebook.tap()
        let canvas = app.element("page.canvas.1")
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        let eraser = app.buttons["editor.tools.eraser"], only = app.switches["editor.tools.eraser.highlighter"]
        let words = (from: CGVector(dx: 76.0 / 612, dy: 211.0 / 792), to: CGVector(dx: 180.0 / 612, dy: 222.0 / 792))
        var bare = try tones(on: canvas, from: words.from, to: words.to, in: app)
        for _ in 0..<30 where bare.darkest > 0.1 {
            usleep(500_000)
            bare = try tones(on: canvas, from: words.from, to: words.to, in: app)
        }
        XCTAssertLessThan(bare.darkest, 0.1, "the print is black")
        XCTAssertEqual(bare.yellow, 0)

        // A pen's line down through the fifth line of print, then the highlighter along that line.
        drag(on: canvas, from: line(4, x: 200), to: line(6, x: 200))
        wait(for: [expectation(for: NSPredicate(format: "value == '1 stroke'"), evaluatedWith: canvas)], timeout: 5)
        app.buttons["editor.tools.4"].tap()
        drag(on: canvas, from: line(5, x: 74), to: line(5, x: 260))
        wait(for: [expectation(for: NSPredicate(format: "value == '2 strokes'"), evaluatedWith: canvas)], timeout: 5)
        sleep(2)
        attach(app, "highlighted-print")
        let marked = try tones(on: canvas, from: words.from, to: words.to, in: app)
        XCTAssertGreaterThan(marked.yellow, 200, "the highlight is over the words")
        XCTAssertLessThan(marked.darkest, 0.1, "and the print under it is as black as it was")

        // Kept to the highlighter, the eraser takes the highlight and leaves the pen's line that crosses it.
        eraser.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: eraser)], timeout: 5)
        XCTAssertLessThan(try tones(on: canvas, from: words.from, to: words.to, in: app).darkest, 0.1, "with the eraser in hand too")
        eraser.tap()
        XCTAssertTrue(only.waitForExistence(timeout: 5))
        XCTAssertEqual(only.value as? String, "0")
        only.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        attach(app, "eraser-highlighter-only")
        try audit(app, screen: "eraser highlighter only", popover: true)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2)).tap()
        XCTAssertTrue(only.waitForNonExistence(timeout: 5))
        XCTAssertEqual(eraser.value as? String, "Whole Strokes, Highlighter Only")
        drag(on: canvas, from: line(5, x: 150), to: line(5, x: 250))
        wait(for: [expectation(for: NSPredicate(format: "value == '1 stroke'"), evaluatedWith: canvas)], timeout: 5)
        XCTAssertEqual(try tones(on: canvas, from: words.from, to: words.to, in: app).yellow, 0, "the highlight is gone")
        let crossing = (from: CGVector(dx: 190.0 / 612, dy: 221.0 / 792), to: CGVector(dx: 210.0 / 612, dy: 228.0 / 792))
        XCTAssertLessThan(try tones(on: canvas, from: crossing.from, to: crossing.to, in: app).darkest, 0.3, "the pen's line is still there")

        // Undo brings the highlight back, and with the switch off the eraser takes both.
        app.buttons["editor.undo"].tap()
        wait(for: [expectation(for: NSPredicate(format: "value == '2 strokes'"), evaluatedWith: canvas)], timeout: 5)
        eraser.tap()
        XCTAssertTrue(only.waitForExistence(timeout: 5))
        XCTAssertEqual(only.value as? String, "1")
        only.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2)).tap()
        XCTAssertTrue(only.waitForNonExistence(timeout: 5))
        XCTAssertEqual(eraser.value as? String, "Whole Strokes")
        drag(on: canvas, from: line(5, x: 150), to: line(5, x: 250))
        wait(for: [expectation(for: NSPredicate(format: "value == 'Empty'"), evaluatedWith: canvas)], timeout: 5)
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
