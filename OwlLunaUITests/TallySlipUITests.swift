import XCTest

/// The slip that ends a flashcard sitting: the cards studied, how many were known first time, and this week's study days.
@MainActor
final class TallySlipUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ app: XCUIApplication, extra: [String] = []) {
        app.launchArguments = ["-storageRoot", "tally", "-resetStorage", "-seedLibrary", "2", "-seedStudy"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["notebook.Biology"].waitForExistence(timeout: 30))
    }

    private func answer(_ app: XCUIApplication, _ button: String) {
        XCTAssertTrue(app.buttons["review.show"].waitForExistence(timeout: 5))
        app.buttons["review.show"].tap()
        XCTAssertTrue(app.buttons[button].waitForExistence(timeout: 5))
        app.buttons[button].tap()
    }

    func testASittingEndsWithItsTallyAndACountOfThisWeeksStudyDays() throws {
        let app = XCUIApplication()
        launch(app)
        let desk = app.element("desk.study")
        XCTAssertTrue(desk.waitForExistence(timeout: 10))
        desk.tap()

        answer(app, "review.again")
        answer(app, "review.easy")
        answer(app, "review.good")

        XCTAssertTrue(app.staticTexts["review.done.title"].waitForExistence(timeout: 5))
        let slip = app.element("review.tally")
        XCTAssertTrue(slip.waitForExistence(timeout: 5))
        XCTAssertEqual(slip.label, "2 cards studied. 1 remembered first time. 1 came round again. Studied on 1 day this week, including today.")
        XCTAssertLessThan(app.staticTexts["review.done.title"].frame.maxY, slip.frame.minY, "the slip is under the heading")
        XCTAssertLessThan(slip.frame.maxY, app.buttons["review.done"].frame.minY, "and above the buttons")
        attach(app, "tally")

        app.buttons["review.all"].tap()
        answer(app, "review.good")
        answer(app, "review.good")
        answer(app, "review.good")
        XCTAssertTrue(slip.waitForExistence(timeout: 5))
        XCTAssertEqual(slip.label, "3 cards studied. 3 remembered first time. Studied on 1 day this week, including today.",
                       "another sitting counts afresh, and the day is still one day")
        app.buttons["review.done"].tap()
        XCTAssertTrue(desk.waitForExistence(timeout: 5))
    }

    func testTheSlipHasNoWeekWhenWritingHistoryIsOff() throws {
        let app = XCUIApplication()
        launch(app)
        let settings = app.buttons["Settings"].firstMatch
        if !settings.isHittable { app.buttons["ToggleSidebar"].firstMatch.tap() }
        settings.tap()
        let keeps = app.switches["Keep Writing History"]
        for _ in 0..<8 where !keeps.exists || !keeps.isHittable { app.swipeUp() }
        XCTAssertTrue(keeps.waitForExistence(timeout: 5))
        XCTAssertEqual(keeps.value as? String, "1")
        keeps.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(keeps.value as? String, "0")
        app.buttons["Done"].firstMatch.tap()

        let desk = app.element("desk.study")
        XCTAssertTrue(desk.waitForExistence(timeout: 10))
        desk.tap()
        answer(app, "review.good")
        answer(app, "review.good")

        let slip = app.element("review.tally")
        XCTAssertTrue(slip.waitForExistence(timeout: 5))
        XCTAssertEqual(slip.label, "2 cards studied. 2 remembered first time.")
        attach(app, "tally-without-week")
    }
}
