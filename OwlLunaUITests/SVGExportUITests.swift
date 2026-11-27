import XCTest

/// Exporting SVGs from the editor's Export menu and from the library: the choices sheet, then the files made.
@MainActor
final class SVGExportUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func contextMenu(_ element: XCUIElement, choose item: String, in app: XCUIApplication) {
        element.press(forDuration: 1.2)
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(item) in the context menu")
        button.tap()
    }

    private func chooseFromExportMenu(_ row: String, in app: XCUIApplication) {
        app.buttons["editor.export"].tap()
        let button = app.buttons[row].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), row)
        button.tap()
        XCTAssertTrue(app.buttons["export.start"].waitForExistence(timeout: 10), "the pages are chosen first")
    }

    func testSVGsAreExportedFromTheEditorAndTheLibrary() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "svgexport", "-resetStorage", "-seedLibrary", "3", "-appearance", "light"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 20))

        chooseFromExportMenu("Every Page as an SVG…", in: app)
        XCTAssertEqual(app.staticTexts["export.pages"].label, "All 3 pages")
        XCTAssertTrue(app.buttons["export.paper.first"].exists, "the paper can be left out")
        XCTAssertFalse(app.buttons["export.quality.first"].exists, "there is no quality to choose")
        XCTAssertFalse(app.switches["export.searchable"].exists)
        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Each stroke is a shape of its own")).firstMatch
        XCTAssertTrue(note.exists, "the sheet says what an SVG gives")
        attach(app, "svg-choices")
        app.buttons["export.start"].tap()
        XCTAssertTrue(app.staticTexts["Your 3 SVGs are ready."].waitForExistence(timeout: 30), "a file for each of the notebook's three pages")
        XCTAssertTrue(app.buttons["export.share"].isEnabled)
        XCTAssertFalse(app.buttons["Print"].exists, "an SVG can't be printed")
        attach(app, "svg-ready")
        app.buttons["Done"].firstMatch.tap()

        chooseFromExportMenu("This Page as an SVG…", in: app)
        XCTAssertEqual(app.staticTexts["export.pages"].label, "Page 1 of 3", "the page on show is chosen")
        XCTAssertEqual(app.buttons["export.start"].label, "Export Page 1")
        app.buttons["export.start"].tap()
        XCTAssertTrue(app.staticTexts["Your SVG is ready."].waitForExistence(timeout: 30), "one file for the one page")
        app.buttons["Done"].firstMatch.tap()
        app.buttons["editor.back"].tap()

        XCTAssertTrue(notebook.waitForExistence(timeout: 10))
        contextMenu(notebook, choose: "Export as SVG", in: app)
        XCTAssertTrue(app.buttons["export.start"].waitForExistence(timeout: 10), "the library asks which pages first")
        XCTAssertEqual(app.staticTexts["export.pages"].label, "All 3 pages")
        app.buttons["export.start"].tap()
        XCTAssertTrue(app.staticTexts["Your 3 SVGs are ready."].waitForExistence(timeout: 30), "export from the library")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(notebook.waitForExistence(timeout: 10))
    }
}
