import XCTest

/// Holding something with a menu of its own opens the menu, and letting go doesn't also tap it.
@MainActor
final class HeldMenuUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHoldingADeskCardOpensItsMenuWithoutOpeningIt() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "heldmenu", "-resetStorage", "-seedLibrary", "2"]
        app.launch()
        let start = app.buttons["Start a daily journal"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.press(forDuration: 1.2)
        XCTAssertFalse(app.buttons["editor.ribbon"].waitForExistence(timeout: 3), "holding the card doesn't start the journal")
        let hide = app.buttons["Don't Show Again"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "it opens the card's menu")
        hide.tap()
        XCTAssertTrue(start.waitForNonExistence(timeout: 5))
    }

    func testTheChevronBesideNewOpensItsCardWithoutStartingANotebook() {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "heldmenu", "-resetStorage", "-seedLibrary", "2"]
        app.launch()
        let chevron = app.buttons["New Menu"].firstMatch
        XCTAssertTrue(chevron.waitForExistence(timeout: 30), "the chevron stands beside New once the library has notebooks")
        chevron.tap()
        let importPDF = app.buttons["Import PDF…"].firstMatch
        XCTAssertTrue(importPDF.waitForExistence(timeout: 5), "a tap on the chevron opens the New card")
        XCTAssertFalse(app.textFields["Title"].exists, "the chevron doesn't start a notebook")
        app.buttons["New Notebook"].firstMatch.tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 10), "the card's rows still work")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.textFields["Title"].waitForNonExistence(timeout: 5))
        app.buttons["New"].firstMatch.press(forDuration: 1)
        XCTAssertTrue(importPDF.waitForExistence(timeout: 5), "holding New still opens the card")
        XCTAssertFalse(app.textFields["Title"].exists, "letting go of a held New doesn't start a notebook")
    }

    func testHoldingYourOwnStickerOpensItsMenuWithoutPlacingIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "heldmenu", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 20))
        app.buttons["Add"].firstMatch.tap()
        app.buttons["Sticker…"].firstMatch.tap()
        let new = app.buttons["sticker.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        let photo = app.scrollViews.images.matching(NSPredicate(format: "label CONTAINS[c] %@", "photo")).firstMatch
        try XCTSkipUnless(photo.waitForExistence(timeout: 15), "this simulator's photo library is empty")
        sleep(1)
        photo.tap()
        let mine = app.buttons["sticker.mine.1"]
        let whole = app.buttons["Use Whole Photo"]
        let deadline = Date().addingTimeInterval(40)
        while !mine.exists, !whole.exists, Date() < deadline { usleep(500_000) }
        if whole.exists { whole.tap() }
        XCTAssertTrue(mine.waitForExistence(timeout: 20))
        sleep(1)
        mine.press(forDuration: 1.2)
        XCTAssertFalse(app.images["Sticker"].waitForExistence(timeout: 3), "holding your sticker doesn't put it on the page")
        let delete = app.buttons["Delete Sticker"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "it opens the sticker's menu")
        delete.tap()
        XCTAssertTrue(mine.waitForNonExistence(timeout: 5))
        XCTAssertTrue(new.exists, "the drawer stays open")
    }
}
