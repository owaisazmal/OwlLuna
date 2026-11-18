import XCTest

/// Issue 41: a finger held on bare paper opens a card that pastes the copied picture there, or as a page of its own.
@MainActor
final class PicturePasteUITests: XCTestCase {
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
        let value = canvas.value as? String ?? ""
        return Int(value.split(separator: " ").first ?? "") ?? -1
    }

    func testAHeldFingerPastesTheCopiedPictureHereOrAsAPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "paste", "-resetStorage", "-seedLibrary", "3", "-copyPicture", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let first = app.element("page.canvas.1"), ribbon = app.buttons["editor.ribbon"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        first.waitUntilStill()
        let pages = ribbon.label, strokes = strokeCount(first)
        let spot = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let here = app.buttons["editor.picture.paste"], after = app.buttons["editor.picture.pasteAfter"]

        spot.press(forDuration: 1)
        XCTAssertTrue(here.waitForExistence(timeout: 5), "a finger held on bare paper offers the copied picture")
        XCTAssertTrue(app.buttons["editor.picture.pasteBefore"].exists)
        XCTAssertTrue(after.exists)
        attach(app, "picture-paste-card")
        here.tap()
        let picture = app.images["Picture"]
        XCTAssertTrue(picture.waitForExistence(timeout: 20), "the picture is on the page")
        let done = app.buttons["editor.arrange.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "picked up, ready to move")
        sleep(1)
        XCTAssertEqual(picture.frame.midX, spot.screenPoint.x, accuracy: 4, "it lands where the paper was held")
        XCTAssertEqual(picture.frame.midY, spot.screenPoint.y, accuracy: 4)
        attach(app, "picture-pasted-here")
        done.tap()
        XCTAssertEqual(strokeCount(first), strokes, "the hold leaves no dot where fingers draw")

        first.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.1)).press(forDuration: 1)
        XCTAssertTrue(after.waitForExistence(timeout: 5))
        after.tap()
        wait(for: [expectation(for: NSPredicate(format: "label != %@ AND label BEGINSWITH 'Page 2 of '", pages), evaluatedWith: ribbon)], timeout: 20)
        sleep(1)
        attach(app, "picture-pasted-as-page")
        app.buttons["editor.undo"].tap()
        let total = pages.components(separatedBy: " of ").last ?? ""
        wait(for: [expectation(for: NSPredicate(format: "label ENDSWITH %@", " of " + total), evaluatedWith: ribbon)], timeout: 10)
    }
}
