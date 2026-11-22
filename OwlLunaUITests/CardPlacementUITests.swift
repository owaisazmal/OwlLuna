import XCTest

/// New's card stands under New, however the library's bar has been made again since it was last opened.
@MainActor
final class CardPlacementUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "an iPhone's library has no bar that changes width")
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ orientation: UIDeviceOrientation) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "cardplacement", "-resetStorage", "-seedLibrary", "3"]
        app.launch()
        XCTAssertTrue(app.buttons["notebook.Physics II 3"].waitForExistence(timeout: 30))
        return app
    }

    /// New with its chevron, where the bar has room for one.
    private func newButton(_ app: XCUIApplication) -> CGRect {
        let new = app.buttons["New"].firstMatch, chevron = app.buttons["New Menu"].firstMatch
        return chevron.exists ? new.frame.union(chevron.frame) : new.frame
    }

    /// The card lines up with one of the button's sides, and its first row is just under the button, with only the card's band between.
    private func checkCard(_ app: XCUIApplication, _ step: String, line: UInt = #line) {
        let row = app.buttons["New Notebook"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "New's card, \(step)", line: line)
        let button = newButton(app), card = row.frame
        XCTAssertTrue(abs(card.minX - button.minX) <= 2 || abs(card.maxX - button.maxX) <= 2,
                      "the card's row \(card) lines up with New \(button), \(step)", line: line)
        XCTAssertTrue((20...48).contains(card.minY - button.maxY), "the card's first row \(card) is just under New \(button), \(step)", line: line)
    }

    /// Opens the card by the chevron, or by holding New where the bar is too narrow for one, checks it and closes it.
    private func openNew(_ app: XCUIApplication, _ step: String, line: UInt = #line) {
        let chevron = app.buttons["New Menu"].firstMatch, new = app.buttons["New"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10), "New, \(step)", line: line)
        if chevron.exists { chevron.tap() } else { new.press(forDuration: 1) }
        checkCard(app, step, line: line)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(app.buttons["New Notebook"].firstMatch.waitForNonExistence(timeout: 5), "the card closes, \(step)", line: line)
    }

    private func toggleSidebar(_ app: XCUIApplication, line: UInt = #line) {
        let button = app.buttons.matching(identifier: "ToggleSidebar").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(button, "the sidebar's button", line: line)
        button?.tap()
        sleep(2)
    }

    func testTheNewCardStandsUnderNewAfterTheIPadIsTurned() {
        let app = launch(.landscapeLeft)
        openNew(app, "at launch")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        openNew(app, "turned upright")
        openNew(app, "upright, a second time")
        XCUIDevice.shared.orientation = .landscapeRight
        sleep(2)
        openNew(app, "turned on its side again")
    }

    func testTheNewCardStandsUnderNewAsTheSidebarHidesAndShows() {
        let app = launch(.portrait)
        openNew(app, "at launch")
        toggleSidebar(app)
        openNew(app, "sidebar hidden")
        toggleSidebar(app)
        openNew(app, "sidebar shown again")
        app.buttons["library.layout.list"].firstMatch.tap()
        openNew(app, "in a list")
        app.buttons["Select"].firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        openNew(app, "after selecting")
        app.openLibrarySearch()
        openNew(app, "with the search field in use")
    }

    func testAnOpenCardGoesWithNewWhenTheIPadIsTurned() {
        let app = launch(.portrait)
        let new = app.buttons["New"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.press(forDuration: 1)
        checkCard(app, "upright")
        let upright = newButton(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        XCTAssertNotEqual(newButton(app).minX, upright.minX, accuracy: 20, "New has moved along the bar")
        checkCard(app, "turned on its side with the card open")
    }
}
