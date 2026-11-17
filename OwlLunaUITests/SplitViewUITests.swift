import XCTest

/// Two notebooks in one window.
@MainActor
final class SplitViewUITests: XCTestCase {
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

    private func draw(on canvas: XCUIElement) {
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)), withVelocity: 300, thenHoldForDuration: 0.1)
    }

    func testNarrowPanesKeepEveryControlWithinReach() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "split", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput", "-splitSideBySide"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let titles = app.buttons.matching(identifier: "editor.title")
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Recordings"].firstMatch.waitForExistence(timeout: 10), "with the window to itself the bar has everything")
        titles.firstMatch.tap()
        app.buttons["Open Another Notebook Beside…"].firstMatch.tap()
        let other = app.buttons["beside.notebook.Studio Notes 2"]
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()
        XCTAssertTrue(app.buttons["editor.close.pane"].waitForExistence(timeout: 20))
        sleep(1)
        attach(app, "split-narrow")
        XCTAssertFalse(app.buttons["Recordings"].exists, "a narrow pane keeps its bar short")
        app.buttons.matching(identifier: "More").element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Recordings"].waitForExistence(timeout: 5), "and offers the rest from More")
        XCTAssertTrue(app.buttons["Record Audio"].exists)
        XCTAssertTrue(app.buttons["editor.export"].exists, "Export too, which has its own button in a wide bar")
        attach(app, "split-narrow-more")
        app.buttons["Recordings"].tap()
        XCTAssertTrue(app.navigationBars["Recordings"].waitForExistence(timeout: 5))
    }

    func testTwoNotebooksAreWrittenInSideBySide() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "split", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let titles = app.buttons.matching(identifier: "editor.title")
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 20))
        let canvases = app.descendants(matching: .any).matching(identifier: "page.canvas.1")
        XCTAssertTrue(canvases.firstMatch.waitForExistence(timeout: 20))

        titles.firstMatch.tap()
        app.buttons["Open Another Notebook Beside…"].firstMatch.tap()
        let other = app.buttons["beside.notebook.Studio Notes 2"]
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["beside.notebook.Physics II 3"].exists, "a notebook isn't opened beside itself")
        attach(app, "split-picker")
        other.tap()
        let closePane = app.buttons["editor.close.pane"]
        XCTAssertTrue(closePane.waitForExistence(timeout: 20), "the second notebook has its own Close")
        XCTAssertEqual(titles.count, 2)
        let grown = NSPredicate(format: "count == 2")
        wait(for: [expectation(for: grown, evaluatedWith: canvases)], timeout: 20)
        sleep(1)
        attach(app, "split-open")

        let first = canvases.element(boundBy: 0), second = canvases.element(boundBy: 1)
        draw(on: second)
        XCTAssertEqual(strokeCount(second), 1)
        XCTAssertEqual(strokeCount(first), 0, "writing in one notebook leaves the other alone")
        draw(on: first)
        draw(on: first)
        XCTAssertEqual(strokeCount(first), 2)
        sleep(1)
        attach(app, "split-written")

        let undo = app.buttons.matching(identifier: "editor.undo")
        undo.element(boundBy: 0).tap()
        XCTAssertEqual(strokeCount(first), 1, "each notebook has its own undo")
        XCTAssertEqual(strokeCount(second), 1)

        closePane.tap()
        XCTAssertTrue(closePane.waitForNonExistence(timeout: 20))
        XCTAssertEqual(titles.count, 1, "closing the second notebook gives the first the window back")
        XCTAssertEqual(strokeCount(canvases.firstMatch), 1)

        titles.firstMatch.tap()
        app.buttons["Open Another Notebook Beside…"].firstMatch.tap()
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()
        XCTAssertTrue(closePane.waitForExistence(timeout: 20))
        wait(for: [expectation(for: grown, evaluatedWith: canvases)], timeout: 20)
        XCTAssertEqual(strokeCount(canvases.element(boundBy: 1)), 1, "what was written beside was saved when its pane closed")
        app.buttons["editor.back"].tap()
        XCTAssertTrue(notebook.waitForExistence(timeout: 30), "going back to the library closes both")
        XCTAssertFalse(closePane.exists)
    }

    func testTheKeyboardGoesToThePaneLastTouched() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "split", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let titles = app.buttons.matching(identifier: "editor.title")
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 20))
        let canvases = app.descendants(matching: .any).matching(identifier: "page.canvas.1")
        XCTAssertTrue(canvases.firstMatch.waitForExistence(timeout: 20))
        // The simulator drops the first key after launch; nothing is written yet for it to undo.
        app.typeKey("z", modifierFlags: .command)
        titles.firstMatch.tap()
        app.buttons["Open Another Notebook Beside…"].firstMatch.tap()
        let other = app.buttons["beside.notebook.Studio Notes 2"]
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()
        wait(for: [expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: canvases)], timeout: 20)
        sleep(1)

        let first = canvases.element(boundBy: 0), second = canvases.element(boundBy: 1)
        draw(on: second)
        draw(on: first)
        XCTAssertEqual(strokeCount(first), 1)
        XCTAssertEqual(strokeCount(second), 1)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(strokeCount(first), 0, "the notebook the window had first is worked in again once it is touched")
        XCTAssertEqual(strokeCount(second), 1)
        draw(on: second)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(strokeCount(second), 1, "and the one beside it once that is touched")
        XCTAssertEqual(strokeCount(first), 0)
    }
}
