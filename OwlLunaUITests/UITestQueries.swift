import XCTest

@MainActor
extension XCUIApplication {
    /// The element carrying an accessibility identifier, whatever kind of element it is.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The library's search field, emptied and ready for typing.
    @discardableResult
    func openLibrarySearch() -> XCUIElement {
        let field = element("library.search")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "library search")
        field.tap()
        let clear = buttons["library.search.clear"]
        if clear.exists { clear.tap() }
        return field
    }

    /// Opens the editor's More menu and taps `row`, opening the card that holds it first.
    func chooseFromMore(_ row: String, in card: String) {
        buttons["More"].firstMatch.tap()
        let opener = buttons[card].firstMatch
        XCTAssertTrue(opener.waitForExistence(timeout: 5), card)
        opener.tap()
        let button = buttons[row].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), row)
        button.tap()
    }
}

@MainActor
extension XCUIElement {
    /// Typed text reaches the simulator as a hardware keyboard's: the on-screen keyboard hides and comes back, and the sheet moves down and up with it.
    func waitUntilStill(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        var frame = self.frame
        var unmoved = 0
        while unmoved < 3, Date() < deadline {
            usleep(500_000)
            let now = self.frame
            unmoved = now == frame ? unmoved + 1 : 0
            frame = now
        }
    }
}
