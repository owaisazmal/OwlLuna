import XCTest

/// Paper of your own, from the paper drawer and New Notebook.
@MainActor
final class OwnPaperUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testYourOwnPaperMakesPagesAndNotebooks() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "ownpaper", "-resetStorage", "-seedLibrary", "3", "-seedPaper"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let ribbon = app.buttons["editor.ribbon"]
        XCTAssertTrue(ribbon.waitForExistence(timeout: 20))
        let pages = try XCTUnwrap(Int(ribbon.label.split(separator: " ").last ?? ""), ribbon.label)

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Choose Paper…"].firstMatch.tap()
        let drawer = app.scrollViews["paper.drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 10))
        XCTAssertTrue(app.element("paper.add").exists, "Add Paper… leads the drawer")
        let sheet = app.buttons["paper.mine.Lab Sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the paper on the shelf has a miniature")
        sleep(1)
        attach(app, "paper-drawer-mine")
        sheet.tap()
        XCTAssertFalse(drawer.waitForExistence(timeout: 2), "picking it adds the page and closes the drawer")
        XCTAssertEqual(ribbon.label, "Page 2 of \(pages + 1)")
        sleep(1)
        attach(app, "page-on-own-paper")

        app.chooseFromMore("Change Paper…", in: "Page")
        XCTAssertTrue(drawer.waitForExistence(timeout: 10), "a page on your own paper can change its paper")
        let chosen = app.buttons["paper.mine.Lab Sheet"]
        XCTAssertTrue(chosen.waitForExistence(timeout: 10))
        XCTAssertTrue(chosen.isSelected, "the drawer marks the paper the page is on")
        XCTAssertTrue(app.staticTexts["Your own paper keeps its own colours."].exists)
        let grid = drawer.buttons["Grid"]
        grid.tap()
        XCTAssertTrue(grid.isSelected, "and it can go back to a template")
        XCTAssertFalse(chosen.isSelected)

        chosen.press(forDuration: 1.2)
        XCTAssertTrue(grid.isSelected, "holding a paper opens its menu without picking it")
        app.buttons["Rename…"].firstMatch.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(" 2")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.buttons["paper.mine.Lab Sheet 2"].waitForExistence(timeout: 5), "a paper can be renamed")
        app.buttons["Done"].firstMatch.tap()

        app.buttons["editor.back"].tap()
        let new = app.buttons["New"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 20))
        new.tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 20))
        let mine = app.buttons["paper.mine.Lab Sheet 2"]
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "New Notebook lists your paper too")
        mine.tap()
        XCTAssertTrue(mine.isSelected)
        sleep(1)
        attach(app, "new-notebook-own-paper")
        app.buttons["Create"].firstMatch.tap()
        XCTAssertTrue(ribbon.waitForExistence(timeout: 20))
        XCTAssertEqual(ribbon.label, "Page 1 of 1")

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Choose Paper…"].firstMatch.tap()
        let renamed = app.buttons["paper.mine.Lab Sheet 2"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 10))
        XCTAssertTrue(renamed.isSelected, "a page after one on your paper would carry on with it")
        sleep(1)
        renamed.press(forDuration: 1.2)
        app.buttons["Delete Paper"].firstMatch.tap()
        XCTAssertFalse(renamed.waitForExistence(timeout: 3), "a paper can be deleted")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertEqual(ribbon.label, "Page 1 of 1")
        sleep(1)
        attach(app, "page-after-its-paper-is-deleted")
    }
}
