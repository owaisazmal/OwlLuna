import XCTest

/// A text box's size from the strip on its Text Style card: a point at a time, slid along and undone in one step, and
/// from a named size, with the knob on its mark.
@MainActor
final class TextSizeUITests: XCTestCase {
    private let words = "Eggs and milk\nFlour\nButter\nSugar"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The box's size its corner tab says, from "280 by 104 pt".
    private func boxSize(_ tab: XCUIElement) throws -> CGSize {
        let numbers = try XCTUnwrap(tab.value as? String).split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(numbers.count, 2, "\(tab.value ?? "")")
        return CGSize(width: numbers[0], height: numbers[1])
    }

    private func points(_ readOut: XCUIElement) throws -> Double {
        try XCTUnwrap(Double(try XCTUnwrap((readOut.value as? String)?.split(separator: " ").first)), "\(readOut.value ?? "")")
    }

    /// Where the knob's middle stands on the strip at a size, as the strip lays it: 8 to 200 pt along the knob's travel, logarithmically.
    private func knobX(_ strip: XCUIElement, at size: Double) -> CGFloat {
        let knob: CGFloat = 14
        return strip.frame.minX + knob / 2 + (strip.frame.width - knob) * CGFloat(log(size / 8) / log(25))
    }

    /// Whether the screen is mustard at a point: a mark on the strip that the knob isn't standing on.
    private func isMustard(at point: CGPoint) throws -> Bool {
        let image = XCUIScreen.main.screenshot().image
        let cg = try XCTUnwrap(image.cgImage)
        let pixel = try XCTUnwrap(cg.cropping(to: CGRect(x: (point.x * image.scale).rounded(.down), y: (point.y * image.scale).rounded(.down), width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let drawn = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        XCTAssertTrue(drawn)
        let (r, g, b) = (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
        return r > 190 && g > 130 && b < 110 && r - b > 100
    }

    func testTheStripSetsAnySizeAndASlideIsOneUndoStep() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "textsize", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "pencilOnly", "-appearance", "light"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 20))

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Text Box"].firstMatch.tap()
        let editor = app.textViews["page.text.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText(words)
        app.buttons["editor.arrange.done"].tap()
        let box = app.staticTexts[words]
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.tap()
        let tab = app.otherElements["Resize"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        let body = try boxSize(tab)

        let style = app.buttons["editor.arrange.style"]
        style.tap()
        let readOut = app.element("editor.text.size.value"), strip = app.element("editor.text.size.strip")
        let presets = app.element("editor.text.size"), face = app.element("editor.text.face")
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "the card has the size strip")
        XCTAssertEqual(readOut.value as? String, "17 pt")
        XCTAssertTrue(presets.buttons["Body"].isSelected)
        attach("size-body")

        app.buttons["editor.text.size.plus"].tap()
        XCTAssertEqual(readOut.value as? String, "18 pt", "plus is a point larger")
        XCTAssertEqual(strip.value as? String, "18 pt")
        XCTAssertFalse(presets.buttons.allElementsBoundByIndex.contains { $0.isSelected }, "no named size is chosen between them")
        let eighteen = try boxSize(tab)
        XCTAssertGreaterThan(eighteen.height, body.height, "the box on the page is larger")
        attach("size-18")

        let card = face.frame
        let window = app.coordinate(withNormalizedOffset: .zero)
        let from = CGPoint(x: knobX(strip, at: 18), y: strip.frame.midY)
        window.withOffset(CGVector(dx: from.x, dy: from.y))
            .press(forDuration: 0.05, thenDragTo: window.withOffset(CGVector(dx: from.x + 40, dy: from.y + 6)), withVelocity: 300, thenHoldForDuration: 0.2)
        let slid = try points(readOut)
        XCTAssertGreaterThan(slid, 24, "sliding the knob right makes it larger still")
        XCTAssertEqual(slid, slid.rounded(), "on a whole point")
        XCTAssertEqual(face.frame, card, "the slide doesn't scroll the card")
        XCTAssertGreaterThan(try boxSize(tab).height, eighteen.height)
        attach("size-slid")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        XCTAssertTrue(strip.waitForNonExistence(timeout: 5))
        app.buttons["editor.undo"].tap()
        XCTAssertEqual(try boxSize(tab), eighteen, "one undo takes the whole slide back")
        style.tap()
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        XCTAssertEqual(readOut.value as? String, "18 pt")

        presets.buttons["Large"].tap()
        XCTAssertEqual(readOut.value as? String, "24 pt")
        XCTAssertTrue(presets.buttons["Large"].isSelected)
        sleep(1)
        let markY = strip.frame.midY + 9
        XCTAssertFalse(try isMustard(at: CGPoint(x: knobX(strip, at: 24), y: markY)), "the knob stands on Large's mark")
        XCTAssertTrue(try isMustard(at: CGPoint(x: knobX(strip, at: 17), y: markY)), "Body's mark shows beside it")
        attach("size-large")

        // XCUITest on iOS can't send an increment; the strip's is `stepTextSize(by: 1)`, which TextSizeRunTests covers.
        XCTAssertEqual(strip.label, "Size", "knob and track are one element, read as the size")
        XCTAssertEqual(strip.value as? String, "24 pt")
        XCTAssertEqual(strip.children(matching: .any).count, 0)
        XCTAssertEqual(app.buttons["editor.text.size.minus"].label, "Smaller")
        XCTAssertEqual(app.buttons["editor.text.size.plus"].label, "Larger")
        app.buttons["editor.text.size.plus"].press(forDuration: 2.5)
        XCTAssertGreaterThan(try points(readOut), 26, "plus repeats while it is held")
    }
}
