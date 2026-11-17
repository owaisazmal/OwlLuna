import XCTest

/// The zoom window: what is written in the strip lands on the page, and the window moves along as the line is written.
@MainActor
final class ZoomWindowUITests: XCTestCase {
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

    private func draw(in canvas: XCUIElement, from start: CGVector, to end: CGVector) {
        canvas.coordinate(withNormalizedOffset: start)
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: end), withVelocity: 300, thenHoldForDuration: 0.05)
    }

    func testWritingInTheStripLandsOnThePageAndMovesAlong() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "zoom", "-resetStorage", "-seedLibrary", "2", "-seedHandwriting", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Study Notes"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let page = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(page.waitForExistence(timeout: 20))
        XCTAssertEqual(strokeCount(page), 8)

        app.chooseFromMore("Zoom Window", in: "View")
        let strip = app.descendants(matching: .any)["zoom.canvas"]
        XCTAssertTrue(strip.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["zoom.title"].label, "Zoom Window · Page 1")
        XCTAssertEqual(strokeCount(strip), 8, "the strip shows the page's own ink")
        let target = app.descendants(matching: .any)["zoom.target"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        let start = target.frame.minX
        sleep(1)
        attach(app, "zoom-open")

        draw(in: strip, from: CGVector(dx: 0.15, dy: 0.4), to: CGVector(dx: 0.35, dy: 0.6))
        XCTAssertEqual(strokeCount(page), 9, "what is written in the strip is written on the page")
        sleep(2)
        XCTAssertEqual(target.frame.minX, start, accuracy: 1, "writing on the left leaves the window where it is")

        draw(in: strip, from: CGVector(dx: 0.74, dy: 0.4), to: CGVector(dx: 0.9, dy: 0.6))
        XCTAssertEqual(strokeCount(page), 10)
        sleep(2)
        XCTAssertGreaterThan(target.frame.minX, start + 20, "writing that reaches the band on the right moves it along")
        attach(app, "zoom-advanced")

        app.buttons["zoom.back"].tap()
        XCTAssertEqual(target.frame.minX, start, accuracy: 2)
        app.buttons["editor.undo"].tap()
        XCTAssertEqual(strokeCount(page), 9)
        XCTAssertEqual(strokeCount(strip), 9, "undo reaches the strip too")

        let top = target.frame.minY
        app.buttons["zoom.newline"].tap()
        XCTAssertGreaterThan(target.frame.minY, top, "the next line is further down the page")
        app.buttons["zoom.closer"].tap()
        XCTAssertFalse(app.buttons["zoom.closer"].isEnabled, "three levels of zoom")
        attach(app, "zoom-closer")

        app.buttons["zoom.close"].tap()
        XCTAssertTrue(strip.waitForNonExistence(timeout: 5))
        app.buttons["More"].firstMatch.tap()
        app.buttons["View"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Zoom Window"].firstMatch.waitForExistence(timeout: 5))
    }
}
