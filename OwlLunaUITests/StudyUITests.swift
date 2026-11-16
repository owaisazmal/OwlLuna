import XCTest

/// Study tape over the page, and handwriting turned into typed text.
@MainActor
final class StudyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func strokeCount(_ canvas: XCUIElement) -> Int {
        Int(((canvas.value as? String) ?? "").split(separator: " ").first ?? "") ?? 0
    }

    private func openStudyNotes(_ app: XCUIApplication, extra: [String] = []) -> XCUIElement {
        app.launchArguments = ["-storageRoot", "study", "-resetStorage", "-seedLibrary", "2", "-seedHandwriting", "-drawingInput", "anyInput"] + extra
        app.launch()
        let notebook = app.buttons["notebook.Study Notes"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        XCTAssertEqual(strokeCount(canvas), 8)
        return canvas
    }

    func testStudyTapeCoversThePageAndLiftsOnATap() throws {
        let app = XCUIApplication()
        let canvas = openStudyNotes(app)
        app.buttons["Add"].firstMatch.tap()
        app.buttons["Study Tape"].firstMatch.tap()
        let bar = app.descendants(matching: .any)["editor.arrange.bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "new tape is selected, ready to be moved over an answer")
        let tape = app.buttons["Study tape"]
        XCTAssertTrue(tape.waitForExistence(timeout: 5))
        XCTAssertEqual(tape.value as? String, "Covering")
        attach(app, "tape-selected")

        app.buttons["editor.arrange.tape"].tap()
        app.buttons["Sage"].firstMatch.tap()
        app.buttons["editor.arrange.done"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))

        tape.tap()
        XCTAssertEqual(tape.value as? String, "Lifted", "a tap lifts it")
        XCTAssertEqual(strokeCount(canvas), 8, "and writes nothing, though fingers draw")
        attach(app, "tape-lifted")
        tape.tap()
        XCTAssertEqual(tape.value as? String, "Covering")

        tape.tap()
        app.buttons["More"].firstMatch.tap()
        app.buttons["Put All Tape Back"].firstMatch.tap()
        XCTAssertEqual(tape.value as? String, "Covering")

        tape.press(forDuration: 0.8)
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "touch and hold picks it up")
        XCTAssertEqual(tape.value as? String, "Covering", "without lifting it")
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(tape.waitForNonExistence(timeout: 5))
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(tape.waitForExistence(timeout: 5))
    }

    func testAPageIsFilmedBeingWritten() throws {
        let app = XCUIApplication()
        _ = openStudyNotes(app)
        app.buttons["editor.title"].tap()
        app.buttons["Export"].firstMatch.tap()
        app.buttons["This Page as a Time-lapse Video…"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Your video is ready."].waitForExistence(timeout: 60))
        XCTAssertTrue(app.descendants(matching: .any)["export.preview"].waitForExistence(timeout: 5), "the film plays in the sheet")
        XCTAssertTrue(app.buttons["Share"].firstMatch.exists)
        sleep(2)
        attach(app, "timelapse-ready")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 5))
    }

    func testSelectedHandwritingIsTranslated() throws {
        let app = XCUIApplication()
        let canvas = openStudyNotes(app, extra: ["-fakeTranslate"])
        app.buttons["More"].firstMatch.tap()
        app.buttons["Select Ink Across Pages"].firstMatch.tap()
        let status = app.staticTexts["editor.ink.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.14))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.33)), withVelocity: 400, thenHoldForDuration: 0.2)
        app.buttons["editor.ink.text"].tap()
        let editor = app.textViews["inktext.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20))

        let translate = app.buttons["inktext.translate"]
        XCTAssertTrue(translate.waitForExistence(timeout: 10), "the languages the iPad can translate into are offered")
        translate.tap()
        app.buttons["French"].firstMatch.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == 'BONJOUR'"), evaluatedWith: editor)], timeout: 10)
        XCTAssertTrue(app.staticTexts["Translated into French on this iPad."].exists)
        attach(app, "ink-translated")

        app.buttons["inktext.original"].tap()
        wait(for: [expectation(for: NSPredicate(format: "value CONTAINS[c] 'hello'"), evaluatedWith: editor)], timeout: 5)
        XCTAssertFalse(app.buttons["inktext.original"].exists)

        translate.tap()
        app.buttons["Spanish"].firstMatch.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == 'HOLA'"), evaluatedWith: editor)], timeout: 10)
        app.buttons["inktext.replace"].tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 5))
        XCTAssertEqual(strokeCount(canvas), 0)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'HOLA'")).firstMatch.waitForExistence(timeout: 5),
                      "the translation is typed where the handwriting was")
    }

    func testSelectedHandwritingBecomesTypedText() throws {
        let app = XCUIApplication()
        let canvas = openStudyNotes(app)
        app.buttons["More"].firstMatch.tap()
        app.buttons["Select Ink Across Pages"].firstMatch.tap()
        let status = app.staticTexts["editor.ink.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.14))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.33)), withVelocity: 400, thenHoldForDuration: 0.2)
        XCTAssertEqual(status.label, "8 strokes. Drag to move, tap for more.")

        app.buttons["editor.ink.text"].tap()
        let editor = app.textViews["inktext.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "the handwriting is read on the device")
        XCTAssertTrue(((editor.value as? String) ?? "").uppercased().contains("HELLO"), "read as \(String(describing: editor.value))")
        attach(app, "ink-as-text")
        app.buttons["inktext.copy"].tap()
        app.buttons["inktext.replace"].tap()

        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 5), "back to writing")
        XCTAssertEqual(strokeCount(canvas), 0, "the handwriting is gone")
        let typed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'hello'")).firstMatch
        XCTAssertTrue(typed.waitForExistence(timeout: 5), "and a text box says the same thing")
        XCTAssertTrue(app.descendants(matching: .any)["editor.arrange.bar"].waitForExistence(timeout: 5), "selected, so it can be moved or restyled")
        attach(app, "ink-replaced")

        app.buttons["editor.undo"].tap()
        XCTAssertEqual(strokeCount(canvas), 8, "one undo brings the handwriting back")
        XCTAssertTrue(typed.waitForNonExistence(timeout: 5))
    }
}
