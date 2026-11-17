import XCTest

/// Tagging a notebook and a page, and the tag's shelf in the sidebar.
@MainActor
final class TagUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testATagGathersItsNotebooksAndPages() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "tags", "-resetStorage", "-seedLibrary", "3"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        XCTAssertFalse(notebook.label.contains("tagged"))

        notebook.tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 20))
        app.buttons["editor.title"].tap()
        app.buttons["Tags…"].firstMatch.tap()
        let field = app.textFields["tags.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let add = app.buttons["tags.add"]
        XCTAssertFalse(add.isEnabled, "nothing to add yet")
        field.tap()
        field.typeText("#Exam ")
        add.waitUntilStill()
        XCTAssertTrue(add.isEnabled, "a name in the field can be added")
        add.tap()
        let chip = app.buttons["tags.chip.Exam"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the tag is on the notebook, without its #")
        attach(app, "tags-sheet")
        app.buttons["tags.done"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        app.buttons["editor.back"].tap()
        XCTAssertTrue(notebook.waitForExistence(timeout: 15))
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS 'tagged Exam'"), evaluatedWith: notebook)], timeout: 10)

        let tag = app.descendants(matching: .any)["tag.Exam"]
        if !tag.exists || !tag.isHittable { app.buttons["ToggleSidebar"].firstMatch.tap() }
        XCTAssertTrue(tag.waitForExistence(timeout: 10), "the sidebar lists the tag once something carries it")
        XCTAssertTrue(tag.label.contains("1 notebook"), tag.label)
        attach(app, "tags-sidebar")
        tag.tap()
        if !notebook.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertTrue(notebook.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["notebook.Cell Biology 1"].waitForNonExistence(timeout: 5), "only what is tagged stands on the tag's shelf")
        XCTAssertFalse(app.buttons["notebook.Studio Notes 2"].exists)
        let page = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Physics II 3, page 1, tagged")).firstMatch
        XCTAssertFalse(page.exists, "no page is tagged yet")

        notebook.tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 20))
        app.chooseFromMore("Tag Page…", in: "Page")
        let suggestion = app.buttons["tags.suggestion.Exam"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "the library's tags are offered")
        suggestion.tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        app.buttons["tags.done"].tap()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled, "tagging a page is a step to undo")

        app.buttons["editor.ribbon"].tap()
        let bookmarks = app.buttons["Bookmarks"].firstMatch
        XCTAssertTrue(bookmarks.waitForExistence(timeout: 10))
        let thumbnail = app.buttons["Page 1 of 3, current"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
        XCTAssertEqual(thumbnail.value as? String, "tagged Exam")
        attach(app, "tags-navigator")
        bookmarks.tap()
        let row = app.buttons["Exam, page 1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the tagged page is listed under the bookmarks")
        attach(app, "tags-bookmarks")
        row.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10))
        app.buttons["editor.back"].tap()

        XCTAssertTrue(page.waitForExistence(timeout: 15), "the tagged page is listed under the notebooks")
        XCTAssertEqual(page.label, "Physics II 3, page 1, tagged Exam")
        XCTAssertTrue(app.staticTexts["Pages"].exists)
        attach(app, "tags-shelf")

        let newShelf = app.buttons["sidebar.newSmartShelf"]
        if !newShelf.exists || !newShelf.isHittable { app.buttons["ToggleSidebar"].firstMatch.tap() }
        XCTAssertTrue(newShelf.waitForExistence(timeout: 10))
        newShelf.tap()
        let save = app.buttons["smart.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertFalse(save.isEnabled, "a smart shelf needs a tag to look for")
        attach(app, "tags-smart-editor")
        app.buttons["smart.tag.Exam"].tap()
        XCTAssertTrue(app.buttons["smart.tag.Exam"].isSelected)
        save.tap()
        let shelf = app.descendants(matching: .any)["smart.Exam"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10), "left unnamed, the shelf is called after its tag")
        if !page.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertTrue(notebook.waitForExistence(timeout: 10), "and shows what the tag's own shelf shows")
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        attach(app, "tags-smart-shelf")
        page.tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 20), "and opens its notebook")
        XCTAssertTrue(app.buttons["editor.ribbon"].label.hasPrefix("Page 1 of"), app.buttons["editor.ribbon"].label)
    }
}
