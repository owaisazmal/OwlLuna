import XCTest

/// A card made from study tape answers in place: the tape lifts off the clipping instead of the card turning over.
@MainActor
final class TapeLiftUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTheTapeLiftsOffATapeCardAndGoesBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "tapelift", "-resetStorage", "-seedLibrary", "2", "-seedStudy", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["notebook.Biology"].waitForExistence(timeout: 30))
        app.buttons["notebook.Biology"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 20))
        app.chooseFromMore("Flashcards…", in: "Study")
        let summary = app.element("deck.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        app.buttons["deck.tape"].tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "4 cards"), evaluatedWith: summary)
        // Reading the clippings' words can stall Vision for a minute or more on a cold simulator.
        waitForExpectations(timeout: 120)

        app.buttons["deck.study"].tap()
        let card = app.element("review.card")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        for _ in 0..<2 {
            XCTAssertTrue(app.buttons["review.show"].waitForExistence(timeout: 5))
            app.buttons["review.show"].tap()
            XCTAssertTrue(app.buttons["review.good"].waitForExistence(timeout: 5))
            app.buttons["review.good"].tap()
        }
        XCTAssertTrue(app.buttons["review.show"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.element("review.progress").label, "Card 3 of 3", "the tape card was made last")
        XCTAssertTrue(card.label.hasPrefix("Question."), card.label)
        attach(app, "question")

        // The seeded strip sits in the middle of its clipping, a little below the middle of the card.
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 26)).tap()
        XCTAssertTrue(app.buttons["review.good"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["review.show"].exists)
        XCTAssertTrue(card.label.hasPrefix("Answer."), card.label)
        attach(app, "lifted")

        card.tap()
        XCTAssertTrue(app.buttons["review.show"].waitForExistence(timeout: 5), "a second tap puts the tape back")
        XCTAssertTrue(card.label.hasPrefix("Question."), card.label)

        app.buttons["review.show"].tap()
        XCTAssertTrue(app.buttons["review.good"].waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.hasPrefix("Answer."), card.label)
        app.buttons["review.good"].tap()
        let done = app.staticTexts["review.done.title"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.label, "All caught up.")
    }
}
