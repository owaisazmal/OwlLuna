import XCTest

/// A card opened with the pointer leaves no highlight on its control, and the control is still drawn in its place
/// after the app has been left and come back to.
@MainActor
final class PointerHighlightUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(XCUIDevice.shared.supportsPointerInteraction, "no pointer on this device")
    }

    private func attach(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pixels(_ shot: XCUIScreenshot) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let image = shot.image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (bytes, image.width, image.height)
    }

    /// The share of a control's pixels that are not as they were in `before`.
    private func change(in element: XCUIElement, since before: XCUIScreenshot) -> Double {
        guard let old = pixels(before), let new = pixels(element.screenshot()), old.width == new.width, old.height == new.height else { return 1 }
        var changed = 0
        for pixel in 0..<(old.width * old.height) where (0..<3).contains(where: { abs(Int(old.bytes[pixel * 4 + $0]) - Int(new.bytes[pixel * 4 + $0])) > 24 }) {
            changed += 1
        }
        return Double(changed) / Double(old.width * old.height)
    }

    private func openEditor() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "pointer", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput", "-freshToolPresets"]
        app.launch()
        let notebook = app.buttons["notebook.Studio Notes 2"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(app.buttons["editor.tools.3"].waitForExistence(timeout: 20))
        return app
    }

    /// Takes `tool` up, clicks it so its options open, closes them, then leaves the app and comes back. The tool and the
    /// pens are to look after each step as they did before the click.
    private func check(_ tool: XCUIElement, named name: String, opens card: XCUIElement, in app: XCUIApplication) {
        let pens = (1...4).map { app.buttons["editor.tools.\($0)"] }, tray = app.element("editor.tools.tray")
        tool.tap()
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: tool)], timeout: 5)
        sleep(1)
        let toolBefore = tool.screenshot(), pensBefore = pens.map { $0.screenshot() }
        attach(tray, "\(name)-before")

        tool.click()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "a click on the \(name) in hand opens its options")
        app.element("page.canvas.1").coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        // A highlight that is going to leave has left by now.
        sleep(2)
        attach(tray, "\(name)-after-options")
        XCTAssertLessThan(change(in: tool, since: toolBefore), 0.02, "no highlight is left on the \(name)")

        // Leaving the app is what sent a highlight that had stayed up, and the tool it held, to the corner of what they stand in.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(tool.waitForExistence(timeout: 10))
        sleep(2)
        attach(tray, "\(name)-after-returning")
        XCTAssertLessThan(change(in: tool, since: toolBefore), 0.02, "the \(name) is drawn in its place after returning")
        for (index, pen) in pens.enumerated() {
            XCTAssertLessThan(change(in: pen, since: pensBefore[index]), 0.02, "pen \(index + 1) is drawn in its slot after returning")
        }
    }

    /// A pen stands in the row that scrolls.
    func testPenOptionsOpenedWithThePointerLeaveThePenAsItWas() throws {
        let app = openEditor()
        check(app.buttons["editor.tools.3"], named: "pen", opens: app.buttons["editor.tools.pen.remove"], in: app)
    }

    /// The eraser stands in the tray itself, so what holds its highlight is the whole screen.
    func testEraserOptionsOpenedWithThePointerLeaveTheEraserAsItWas() throws {
        let app = openEditor()
        check(app.buttons["editor.tools.eraser"], named: "eraser", opens: app.buttons["Part of a Stroke"], in: app)
    }
}
