import XCTest

/// Flashcards studied from the library and made in a notebook, and a study guide written from its pages.
@MainActor
final class FlashcardUITests: XCTestCase {
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
        app.launchArguments = ["-storageRoot", "cards", "-resetStorage", "-seedLibrary", "2", "-seedStudy"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["notebook.Biology"].waitForExistence(timeout: 30))
    }

    private func openMore(_ app: XCUIApplication, _ item: String) {
        app.buttons["notebook.Biology"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 20))
        app.buttons["More"].firstMatch.tap()
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), item)
        button.tap()
    }

    func testDueCardsAreStudiedFromTheLibrary() throws {
        let app = XCUIApplication()
        launch(app)
        let desk = app.element("desk.study")
        XCTAssertTrue(desk.waitForExistence(timeout: 10))
        XCTAssertEqual(desk.label, "Flashcards: 2 cards to review")
        attach(app, "desk")
        desk.tap()

        let card = app.element("review.card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(card.label, "Question. What makes ATP?")
        XCTAssertEqual(app.element("review.progress").label, "Card 1 of 2")
        attach(app, "question")
        app.buttons["review.show"].tap()
        XCTAssertTrue(app.buttons["review.good"].waitForExistence(timeout: 5))
        XCTAssertEqual(card.label, "Answer. Mitochondria")
        XCTAssertEqual(app.buttons["review.good"].value as? String, "Comes back: Tomorrow")
        attach(app, "answer")
        app.buttons["review.again"].tap()

        XCTAssertTrue(app.buttons["review.show"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.element("review.card").label, "Question. What do ribosomes build?")
        app.buttons["review.show"].tap()
        app.buttons["review.easy"].tap()

        XCTAssertTrue(app.buttons["review.show"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.element("review.card").label, "Question. What makes ATP?", "the forgotten card comes round again")
        app.buttons["review.show"].tap()
        app.buttons["review.good"].tap()

        let done = app.staticTexts["review.done.title"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.label, "All caught up.")
        attach(app, "caught-up")
        app.buttons["review.done"].tap()
        XCTAssertTrue(desk.waitForExistence(timeout: 5))
        XCTAssertTrue(desk.label.hasPrefix("Flashcards: all caught up."), desk.label)
    }

    func testCardsAreWrittenAndMadeFromStudyTapeInANotebook() throws {
        let app = XCUIApplication()
        launch(app)
        openMore(app, "Flashcards…")
        let summary = app.element("deck.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.hasPrefix("3 cards"), summary.label)
        attach(app, "deck")

        app.buttons["deck.tape"].tap()
        let made = NSPredicate(format: "label BEGINSWITH %@", "4 cards")
        expectation(for: made, evaluatedWith: summary)
        // Making both clippings and recognizing their text can exceed ten seconds on a cold CI simulator.
        waitForExpectations(timeout: 60)
        XCTAssertFalse(app.buttons["deck.tape"].exists, "every strip has its card now")

        app.buttons["deck.new"].tap()
        let front = app.element("composer.front")
        XCTAssertTrue(front.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["composer.save"].isEnabled)
        front.waitUntilStill()
        front.tap()
        front.typeText("What do chloroplasts do?")
        let back = app.element("composer.back")
        back.waitUntilStill()
        back.tap()
        back.typeText("Turn light into sugar")
        attach(app, "composer")
        app.buttons["composer.save"].tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "5 cards"), evaluatedWith: summary)
        waitForExpectations(timeout: 10)
        attach(app, "deck-after")

        app.buttons["deck.study"].tap()
        XCTAssertTrue(app.element("review.card").waitForExistence(timeout: 5))
        XCTAssertEqual(app.element("review.progress").label, "Card 1 of 4", "the two that were due and the two just made")
        app.buttons["review.close"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
    }

    func testAStudyGuideIsWrittenAndItsQuestionsBecomeCards() throws {
        let app = XCUIApplication()
        launch(app, extra: ["-fakeModel"])
        openMore(app, "Study Guide…")
        let point = app.element("guide.point.1")
        XCTAssertTrue(point.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Mitochondria make ATP, the cell's energy."].exists)
        attach(app, "summary")

        app.buttons["Practice Questions"].firstMatch.tap()
        let show = app.buttons["guide.show.1"]
        XCTAssertTrue(show.waitForExistence(timeout: 20))
        XCTAssertFalse(app.element("guide.answer.1").exists, "answers start face down")
        show.tap()
        XCTAssertTrue(app.element("guide.answer.1").waitForExistence(timeout: 5))
        attach(app, "questions")
        let save = app.buttons["guide.save"]
        XCTAssertEqual(save.label, "Save 6 as Flashcards")
        save.tap()
        expectation(for: NSPredicate(format: "label == %@", "Saved to Flashcards"), evaluatedWith: save)
        waitForExpectations(timeout: 5)

        app.buttons["Summary"].firstMatch.tap()
        app.buttons["guide.add"].tap()
        XCTAssertTrue(app.element("editor.arrange.bar").waitForExistence(timeout: 5), "the summary is on the page as a text box, selected")
        attach(app, "summary-on-page")
        app.buttons["editor.arrange.done"].tap()

        app.buttons["More"].firstMatch.tap()
        app.buttons["Flashcards…"].firstMatch.tap()
        let summary = app.element("deck.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.hasPrefix("9 cards"), summary.label)
    }

    func testWithoutAModelTheStudyGuideSaysWhy() throws {
        let app = XCUIApplication()
        launch(app, extra: ["-noModel"])
        openMore(app, "Study Guide…")
        XCTAssertTrue(app.element("guide.unavailable").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Not on This iPad Yet"].exists)
        attach(app, "unavailable")
        app.buttons["guide.done"].tap()
    }
}
