import XCTest

/// Even Colour: highlights that cross keep one strength, print under them stays dark, and what an eraser rubs out
/// is seen to go.
@MainActor
final class EvenHighlightsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func drag(on canvas: XCUIElement, from start: CGVector, to end: CGVector) {
        canvas.coordinate(withNormalizedOffset: start)
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: end), withVelocity: 300, thenHoldForDuration: 0.1)
    }

    /// A point of the seeded textbook's Letter page: its body lines are 20 pt apart from 130 pt down.
    private func at(_ x: CGFloat, line: CGFloat) -> CGVector {
        CGVector(dx: x / 612, dy: (136.5 + (line - 1) * 20) / 792)
    }

    /// What the screen shows in a part of the canvas: the colour most of it has, how dark its darkest pixel is, from 0
    /// for black to 1, and how many of its pixels are the highlighter's yellow.
    private func look(on canvas: XCUIElement, from start: CGVector, to end: CGVector, in app: XCUIApplication) throws -> (most: [Int], darkest: CGFloat, yellow: Int) {
        let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage), frame = canvas.frame
        let scale = CGFloat(image.width) / app.frame.width
        let rect = CGRect(x: (frame.minX + start.dx * frame.width) * scale, y: (frame.minY + start.dy * frame.height) * scale,
                          width: (end.dx - start.dx) * frame.width * scale, height: (end.dy - start.dy) * frame.height * scale).integral
        let width = Int(rect.width), height = Int(rect.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try XCTUnwrap(image.cropping(to: rect)), in: CGRect(x: 0, y: 0, width: width, height: height))
        var darkest: CGFloat = 1, yellow = 0, counts: [Int: Int] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
            darkest = min(darkest, (0.2126 * CGFloat(red) + 0.7152 * CGFloat(green) + 0.0722 * CGFloat(blue)) / 255)
            if red > 204, green > 153, blue < 178 { yellow += 1 }
            counts[red << 16 | green << 8 | blue, default: 0] += 1
        }
        let most = counts.max { $0.value < $1.value }?.key ?? 0
        return ([most >> 16, most >> 8 & 0xFF, most & 0xFF], darkest, yellow)
    }

    func testCrossingHighlightsKeepOneStrengthAndAreSeenToBeRubbedOut() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "even", "-resetStorage", "-seedLongPDF", "-drawingInput", "anyInput", "-freshToolPresets", "-appearance", "light"]
        app.launch()
        let notebook = app.buttons["notebook.Textbook"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 60))
        notebook.tap()
        let canvas = app.element("page.canvas.1")
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        let highlighter = app.buttons["editor.tools.4"], eraser = app.buttons["editor.tools.eraser"], even = app.switches["editor.tools.pen.even"]
        func strokes(_ count: Int) {
            wait(for: [expectation(for: NSPredicate(format: "value == '\(count) strokes'"), evaluatedWith: canvas)], timeout: 5)
        }
        func closeOptions(_ element: XCUIElement) {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2)).tap()
            XCTAssertTrue(element.waitForNonExistence(timeout: 5))
        }
        // Parts of the page: the level highlight clear of the others, where an upright one crosses it, that upright
        // one clear of it, and words of print under the level one.
        let alone = (from: at(96, line: 4.75), to: at(136, line: 5.25)), crossing = (from: at(157, line: 4.75), to: at(163, line: 5.25))
        let upright = (from: at(157, line: 6.35), to: at(163, line: 6.65)), words = (from: at(76, line: 4.7), to: at(136, line: 5.3))
        var bare = try look(on: canvas, from: words.from, to: words.to, in: app)
        for _ in 0..<30 where bare.darkest > 0.1 {
            usleep(500_000)
            bare = try look(on: canvas, from: words.from, to: words.to, in: app)
        }
        XCTAssertLessThan(bare.darkest, 0.1, "the print is black")

        // A pen's line, a highlight along a line of print and one down across both. PencilKit's own get darker where they cross.
        drag(on: canvas, from: at(72, line: 6), to: at(300, line: 6))
        wait(for: [expectation(for: NSPredicate(format: "value == '1 stroke'"), evaluatedWith: canvas)], timeout: 5)
        highlighter.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: highlighter)], timeout: 5)
        drag(on: canvas, from: at(74, line: 5), to: at(260, line: 5))
        strokes(2)
        drag(on: canvas, from: at(160, line: 3), to: at(160, line: 7.5))
        strokes(3)
        sleep(2)
        attach(app, "even-colour-off")
        var across = try look(on: canvas, from: crossing.from, to: crossing.to, in: app), down = try look(on: canvas, from: upright.from, to: upright.to, in: app)
        XCTAssertLessThan(across.most[2], down.most[2] - 10, "off, the crossing is darker than the line: \(across.most) and \(down.most)")

        // Even Colour changes the open page over: the crossing is the colour of the highlight on top.
        highlighter.tap()
        XCTAssertTrue(even.waitForExistence(timeout: 5))
        XCTAssertEqual(even.value as? String, "0")
        even.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(even.value as? String, "1")
        closeOptions(even)
        sleep(2)
        attach(app, "even-colour-on")
        func assertEven(_ message: String) throws {
            across = try look(on: canvas, from: crossing.from, to: crossing.to, in: app)
            down = try look(on: canvas, from: upright.from, to: upright.to, in: app)
            let level = try look(on: canvas, from: alone.from, to: alone.to, in: app)
            for channel in 0..<3 {
                XCTAssertEqual(across.most[channel], down.most[channel], accuracy: 2, "\(message): the crossing \(across.most) is the upright's colour \(down.most)")
                XCTAssertEqual(level.most[channel], down.most[channel], accuracy: 12, "\(message): and the level one \(level.most) is of a strength with it")
            }
            XCTAssertGreaterThan(level.yellow, 200, message)
            XCTAssertLessThan(try look(on: canvas, from: words.from, to: words.to, in: app).darkest, 0.1, "\(message): print under the highlight is as black as it was")
        }
        try assertEven("switched on")
        XCTAssertEqual(canvas.value as? String, "3 strokes", "the switch is no change to the page")

        // A highlight drawn now lands flat, and picking a tool up changes nothing.
        drag(on: canvas, from: at(200, line: 3), to: at(200, line: 7.5))
        strokes(4)
        sleep(1)
        let second = (cross: (from: at(197, line: 4.75), to: at(203, line: 5.25)), down: (from: at(197, line: 6.35), to: at(203, line: 6.65)))
        let landed = try look(on: canvas, from: second.cross.from, to: second.cross.to, in: app), below = try look(on: canvas, from: second.down.from, to: second.down.to, in: app)
        for channel in 0..<3 { XCTAssertEqual(landed.most[channel], below.most[channel], accuracy: 2, "a highlight drawn with it on: \(landed.most) and \(below.most)") }
        eraser.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: eraser)], timeout: 5)
        sleep(1)
        try assertEven("with the eraser in hand")
        attach(app, "even-colour-eraser-in-hand")

        // The eraser takes part of the level highlight, and the pen's line stays.
        eraser.tap()
        let part = app.buttons["Part of a Stroke"]
        XCTAssertTrue(part.waitForExistence(timeout: 5))
        part.tap()
        closeOptions(part)
        drag(on: canvas, from: at(110, line: 4.3), to: at(110, line: 5.3))
        strokes(5)
        sleep(1)
        attach(app, "even-colour-part-rubbed-out")
        XCTAssertEqual(try look(on: canvas, from: at(107, line: 4.75), to: at(113, line: 5.25), in: app).yellow, 0, "what was rubbed is gone")
        XCTAssertGreaterThan(try look(on: canvas, from: at(128, line: 4.75), to: at(148, line: 5.25), in: app).yellow, 100, "and the rest of the highlight is there")

        // Whole strokes: the first upright highlight goes, and Undo brings it back as it was.
        eraser.tap()
        let whole = app.buttons["Whole Strokes"]
        XCTAssertTrue(whole.waitForExistence(timeout: 5))
        whole.tap()
        closeOptions(whole)
        drag(on: canvas, from: at(150, line: 3.5), to: at(170, line: 3.5))
        strokes(4)
        sleep(1)
        XCTAssertEqual(try look(on: canvas, from: upright.from, to: upright.to, in: app).yellow, 0, "the highlight the eraser touched is gone")
        app.buttons["editor.undo"].tap()
        strokes(5)
        sleep(1)
        XCTAssertGreaterThan(try look(on: canvas, from: upright.from, to: upright.to, in: app).yellow, 20, "undone")
        try assertEven("after undo")
        attach(app, "even-colour-undone")
    }
}
