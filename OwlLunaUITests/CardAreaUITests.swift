import XCTest

/// Changing the part of its page a flashcard made from study tape shows, from the card's editor.
@MainActor
final class CardAreaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// How wide the question's clipping is drawn for its height.
    private func shape(of app: XCUIApplication) -> CGFloat {
        let clipping = app.images["Clipping from the page"].firstMatch
        XCTAssertTrue(clipping.waitForExistence(timeout: 10))
        let frame = clipping.frame
        return frame.width / max(frame.height, 1)
    }

    private func openTapeCard(_ app: XCUIApplication) -> XCUIElement {
        let card = app.buttons.matching(identifier: "deck.card").matching(NSPredicate(format: "label BEGINSWITH %@", "Study tape on page 1")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        let change = app.buttons["composer.area"]
        XCTAssertTrue(change.waitForExistence(timeout: 5), "a tape card whose tape is still on its page offers Change Area")
        return change
    }

    /// Opens the crop and drags its right edge in by `distance` points.
    private func dragRightEdgeIn(_ app: XCUIApplication, by distance: CGFloat) {
        let right = app.element("page.crop.right")
        XCTAssertTrue(right.waitForExistence(timeout: 10))
        let before = right.value as? String
        let grip = right.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.1, thenDragTo: grip.withOffset(CGVector(dx: -distance, dy: 0)), withVelocity: 400, thenHoldForDuration: 0.1)
        XCTAssertNotEqual(right.value as? String, before, "the right edge came in")
    }

    func testATapeCardsAreaIsChangedFromItsEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "cardarea", "-resetStorage", "-seedLibrary", "2", "-seedStudy", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["notebook.Biology"].waitForExistence(timeout: 30))
        app.buttons["notebook.Biology"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 20))
        app.chooseFromMore("Flashcards…", in: "Study")
        let summary = app.element("deck.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        app.buttons["deck.tape"].tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH %@", "4 cards"), evaluatedWith: summary)
        // The recogniser's first reading can stall for over a minute on a cold simulator.
        waitForExpectations(timeout: 150)

        var change = openTapeCard(app)
        let made = shape(of: app)
        attach(app, "composer")
        change.tap()
        let done = app.buttons["area.done"], reset = app.buttons["area.reset"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(app.element("page.crop.right").waitForExistence(timeout: 10))
        XCTAssertFalse(reset.isEnabled, "a new card is at the area it started with")
        dragRightEdgeIn(app, by: 90)
        XCTAssertTrue(reset.isEnabled)
        attach(app, "changing")
        app.buttons["area.cancel"].tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        XCTAssertEqual(shape(of: app), made, accuracy: 0.02, "Cancel leaves the card's clippings as they were")

        change.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        dragRightEdgeIn(app, by: 90)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 30), "both sides are cut again, and the editor is back")
        let narrower = shape(of: app)
        XCTAssertLessThan(narrower, made - 0.1, "the clipping shows less of the page's width")
        attach(app, "changed")
        app.buttons["composer.save"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 10))

        change = openTapeCard(app)
        XCTAssertEqual(shape(of: app), narrower, accuracy: 0.02, "the card was saved with its new area")
        change.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(app.element("page.crop.right").waitForExistence(timeout: 10))
        XCTAssertTrue(reset.isEnabled, "and can be sent back to the area it started with")
        app.buttons["area.cancel"].tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    }
}
