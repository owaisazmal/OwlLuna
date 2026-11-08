import XCTest

/// Focus mode and presenting: what each hides, and that the laser leaves no ink.
@MainActor
final class EditorModesUITests: XCTestCase {
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

    private func drag(on canvas: XCUIElement, y: Double) {
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: y))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: y + 0.05)), withVelocity: 300, thenHoldForDuration: 0.2)
    }

    func testFocusModeAndPresenting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "modes", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let ribbon = app.buttons["editor.ribbon"]
        XCTAssertTrue(ribbon.waitForExistence(timeout: 20))
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let before = strokeCount(canvas)

        app.buttons["More"].firstMatch.tap()
        app.buttons["Focus Mode"].firstMatch.tap()
        let exitFocus = app.buttons["editor.focus.exit"]
        XCTAssertTrue(exitFocus.waitForExistence(timeout: 5))
        XCTAssertTrue(ribbon.waitForNonExistence(timeout: 5), "the ribbon and the bar are put away")
        XCTAssertFalse(app.buttons["editor.back"].exists)
        drag(on: canvas, y: 0.3)
        XCTAssertEqual(strokeCount(canvas), before + 1, "writing carries on in focus mode")
        attach(app, "focus-mode")
        exitFocus.tap()
        XCTAssertTrue(ribbon.waitForExistence(timeout: 5))

        app.buttons["More"].firstMatch.tap()
        app.buttons["Present"].firstMatch.tap()
        let done = app.buttons["editor.present.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Page 1 of 3"].waitForExistence(timeout: 5))
        drag(on: canvas, y: 0.5)
        XCTAssertEqual(strokeCount(canvas), before + 1, "the laser leaves no ink")
        attach(app, "presenting")
        app.buttons["editor.present.next"].tap()
        XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(ribbon.waitForExistence(timeout: 5))
        XCTAssertEqual(ribbon.label, "Page 2 of 3")
        XCTAssertTrue(app.buttons["editor.back"].exists)
    }

    func testOnePageAtATimeTurnsWithASwipe() throws {
        let app = XCUIApplication()
        let first = openNotebook(app, input: "anyInput")
        let second = app.descendants(matching: .any)["page.canvas.2"]
        let ribbon = app.buttons["editor.ribbon"]
        XCTAssertTrue(second.waitForExistence(timeout: 10), "the stack starts continuous, with the next page under the first")

        app.buttons["More"].firstMatch.tap()
        app.buttons["Pages"].firstMatch.tap()
        let single = app.buttons["One Page at a Time"]
        XCTAssertTrue(single.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Continuous"].isSelected, "the stack is marked as the choice in force")
        single.tap()
        XCTAssertTrue(second.waitForNonExistence(timeout: 5), "only the page on show is laid out")
        XCTAssertTrue(first.exists)
        XCTAssertEqual(ribbon.label, "Page 1 of 3")
        attach(app, "one-page-at-a-time")

        first.swipeLeft()
        XCTAssertTrue(second.waitForExistence(timeout: 5), "a swipe turns to the next page")
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertEqual(ribbon.label, "Page 2 of 3")
        let before = strokeCount(second)
        drag(on: second, y: 0.3)
        XCTAssertEqual(strokeCount(second), before + 1, "writing carries on one page at a time")

        second.swipeRight()
        XCTAssertTrue(first.waitForExistence(timeout: 5), "a swipe back turns to the page before")
        XCTAssertEqual(ribbon.label, "Page 1 of 3")

        app.buttons["More"].firstMatch.tap()
        app.buttons["Pages"].firstMatch.tap()
        XCTAssertTrue(single.waitForExistence(timeout: 5))
        XCTAssertTrue(single.isSelected, "the picker marks the choice in force")
        app.buttons["Continuous"].tap()
        XCTAssertTrue(second.waitForExistence(timeout: 5), "the pages are stacked again")
        XCTAssertTrue(first.exists)
    }

    func testABookmarkedPageIsListedInTheOutline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "modes", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let bookmark = app.buttons["editor.bookmark"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 20))
        XCTAssertEqual(bookmark.label, "Bookmark Page")
        bookmark.tap()
        XCTAssertEqual(bookmark.label, "Remove Bookmark")
        attach(app, "bookmarked")

        app.buttons["editor.ribbon"].tap()
        let outline = app.buttons["Outline"].firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 10))
        attach(app, "navigator-pages")
        outline.tap()
        let row = app.buttons["Page 1, page 1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the bookmark is listed under its page")
        attach(app, "navigator-outline")
        row.tap()
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        app.buttons["editor.undo"].tap()
        XCTAssertEqual(bookmark.label, "Bookmark Page", "bookmarking is one undo step")
    }

    func testAStickerCanBePlacedMovedAndRemoved() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "modes", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))

        func add(_ sticker: String) {
            app.buttons["Add"].firstMatch.tap()
            app.buttons["Sticker…"].firstMatch.tap()
            let tile = app.buttons["sticker.\(sticker)"]
            let drawer = app.scrollViews["sticker.drawer"]
            // The drawer opens half way up, where a swipe doesn't move it: a long drag raises it, the next scrolls down to the marks and tags.
            for _ in 0..<4 where !tile.waitForExistence(timeout: 3) {
                drawer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
                    .press(forDuration: 0.05, thenDragTo: drawer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)), withVelocity: 600, thenHoldForDuration: 0.2)
            }
            XCTAssertTrue(tile.waitForExistence(timeout: 10))
            if sticker == "noteYellow" { attach(app, "sticker-drawer") }
            tile.tap()
        }
        add("noteYellow")
        let note = app.images["Sticker, Yellow Sticky Note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        let done = app.buttons["editor.arrange.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "a new sticker arrives selected")
        let start = note.frame
        note.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25)), withVelocity: 300, thenHoldForDuration: 0.1)
        XCTAssertLessThan(note.frame.midY, start.midY - 40, "dragging the selected sticker moves it")
        XCTAssertEqual(strokeCount(canvas), 0, "and draws nothing")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))

        drag(on: canvas, y: 0.22)
        XCTAssertEqual(strokeCount(canvas), 1, "ink goes over the sticker once it's put down")
        add("rainbow")
        add("stampImportant")
        app.buttons["Done"].firstMatch.tap()
        attach(app, "stickers-on-page")

        note.press(forDuration: 0.8)
        XCTAssertTrue(done.waitForExistence(timeout: 5), "touch and hold picks it up again")
        XCTAssertEqual(strokeCount(canvas), 1, "the hold leaves no dot")
        attach(app, "sticker-selected")
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 5))
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5), "deleting is one undo step")
    }

    func testWidgetLinksOpenTheRightNotebook() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "modes", "-resetStorage", "-seedLibrary", "3", "-seedJournal", "-drawingInput", "anyInput"]
        app.launch()
        XCTAssertTrue(app.buttons["notebook.Physics II 3"].waitForExistence(timeout: 30))

        XCUIDevice.shared.system.open(URL(string: "owlluna://quicknote")!)
        let title = app.buttons["editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "a quick note opens straight into the editor")
        XCTAssertTrue(title.label.hasPrefix("Note "), title.label)
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        drag(on: canvas, y: 0.3)
        XCTAssertEqual(strokeCount(canvas), 1)

        XCUIDevice.shared.system.open(URL(string: "owlluna://today")!)
        let journal = NSPredicate(format: "label BEGINSWITH %@", "Journal")
        wait(for: [expectation(for: journal, evaluatedWith: title)], timeout: 30)
        XCTAssertEqual(app.buttons.matching(identifier: "editor.title").count, 1, "the note's editor has closed, not moved beside the journal")
        XCTAssertFalse(app.buttons["tabs.add"].exists, "nor behind a tab")
        let ribbon = app.buttons["editor.ribbon"]
        XCTAssertEqual(ribbon.label, "Page 4 of 4", "the note is put away and the journal opens on today's new page")

        ribbon.tap()
        let goTo = app.element("navigator.goto")
        XCTAssertTrue(goTo.waitForExistence(timeout: 10))
        goTo.tap()
        goTo.typeText("1")
        app.buttons["navigator.go"].firstMatch.tap()
        wait(for: [expectation(for: NSPredicate(format: "label == %@", "Page 1 of 4"), evaluatedWith: ribbon)], timeout: 10)
        XCUIDevice.shared.system.open(URL(string: "owlluna://today")!)
        let today = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Page 4 of 4"), object: ribbon)
        XCTAssertEqual(XCTWaiter.wait(for: [today], timeout: 10), .completed, "asking again turns back to today's page and adds nothing: \(ribbon.label)")

        app.buttons["editor.back"].tap()
        let note = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "notebook.Note ")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20), "the note is on the shelf")
        note.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertTrue(title.label.hasPrefix("Note "), title.label)
        let written = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "1 "), object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 20), .completed, "the note was saved with what was written in it")
    }

    func testAPictureFromPhotosLandsOnThePage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "modes", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 20))
        app.buttons["Add"].firstMatch.tap()
        app.buttons["Picture on This Page…"].firstMatch.tap()
        // The pens in the tool tray are images in a scroll view too: the photo picker's are the ones called photos.
        let photo = app.scrollViews.images.matching(NSPredicate(format: "label CONTAINS[c] %@", "photo")).firstMatch
        try XCTSkipUnless(photo.waitForExistence(timeout: 15), "this simulator's photo library is empty")
        photo.tap()
        let picture = app.images["Picture"]
        if !picture.waitForExistence(timeout: 20), photo.exists { photo.tap() }
        XCTAssertTrue(picture.waitForExistence(timeout: 30), "the photo is placed on the current page")
        XCTAssertTrue(app.buttons["editor.arrange.done"].waitForExistence(timeout: 5), "selected, ready to move")
        XCTAssertEqual(app.buttons["editor.ribbon"].label, "Page 1 of 3", "and no page was added")
        sleep(1)
        attach(app, "picture-on-page")
    }

    private func openNotebook(_ app: XCUIApplication, input: String) -> XCUIElement {
        app.launchArguments = ["-storageRoot", "modes", "-resetStorage", "-seedLibrary", "3", "-drawingInput", input]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        return canvas
    }

    func testATextBoxCanBeTypedStyledAndEdited() throws {
        let app = XCUIApplication()
        let canvas = openNotebook(app, input: "anyInput")
        let strokes = strokeCount(canvas)

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Text Box"].firstMatch.tap()
        let editor = app.textViews["page.text.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "a new text box opens ready to type in")
        editor.typeText("Molar mass")
        attach(app, "text-typing")
        let done = app.buttons["editor.arrange.done"]
        done.tap()
        let text = app.staticTexts["Molar mass"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "what was typed stays on the page")
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertEqual(strokeCount(canvas), strokes, "typing draws nothing")

        text.press(forDuration: 0.8)
        XCTAssertTrue(done.waitForExistence(timeout: 5), "touch and hold picks the box up")
        let before = text.frame
        app.buttons["editor.arrange.style"].tap()
        let title = app.buttons["Title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "a tap beside the card puts it away")
        XCTAssertGreaterThan(text.frame.height, before.height * 1.5, "a larger size makes a taller box")
        attach(app, "text-selected")

        app.buttons["editor.arrange.edit"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText(" of water")
        done.tap()
        XCTAssertTrue(app.staticTexts["Molar mass of water"].waitForExistence(timeout: 5))
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5), "an edit is one undo step")
        sleep(1)
        attach(app, "text-on-page")

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Text Box"].firstMatch.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "")).count, 0, "a box left empty isn't kept")
        XCTAssertTrue(text.exists)
    }

    func testALinkOpensItsPageAndComesBack() throws {
        let app = XCUIApplication()
        _ = openNotebook(app, input: "pencilOnly")
        let ribbon = app.buttons["editor.ribbon"]

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Link…"].firstMatch.tap()
        let target = app.buttons["link.page.3"]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["link.page.1"].isEnabled, "a page can't link to itself")
        attach(app, "link-picker")
        target.tap()
        let link = app.links["Link to Page 3"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        let done = app.buttons["editor.arrange.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "a new link arrives selected")
        attach(app, "link-selected")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))

        link.tap()
        let label = NSPredicate(format: "label == %@", "Page 3 of 3")
        wait(for: [expectation(for: label, evaluatedWith: ribbon)], timeout: 10)
        let back = app.buttons["editor.link.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the way back is offered")
        attach(app, "link-followed")
        back.tap()
        wait(for: [expectation(for: NSPredicate(format: "label == %@", "Page 1 of 3"), evaluatedWith: ribbon)], timeout: 10)
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        sleep(1)
        attach(app, "link-on-page")
    }

    func testALinkOpensAnotherNotebookAndComesBack() throws {
        let app = XCUIApplication()
        _ = openNotebook(app, input: "pencilOnly")
        let title = app.buttons["editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Link…"].firstMatch.tap()
        let tabs = app.element("link.tabs")
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        tabs.buttons["Web"].tap()
        let address = app.textFields["link.web.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["link.web.add"].isEnabled, "nothing to add until there is an address")
        address.tap()
        address.typeText("www.swift.org/documentation")
        attach(app, "link-web")
        app.buttons["link.web.add"].tap()
        let web = app.links["Web link, swift.org/documentation"]
        XCTAssertTrue(web.waitForExistence(timeout: 5), "the link is named after its address")
        let done = app.buttons["editor.arrange.done"]
        done.tap()

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Link…"].firstMatch.tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        tabs.buttons["Another Notebook"].tap()
        let other = app.buttons["link.notebook.Studio Notes 2"]
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["link.notebook.Physics II 3"].exists, "a notebook doesn't link to itself here")
        attach(app, "link-notebooks")
        other.tap()
        let page = app.buttons["link.notebook.page.2"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        attach(app, "link-notebook-pages")
        page.tap()
        let link = app.links["Link to the notebook Studio Notes 2"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        attach(app, "link-notebook-selected")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))

        link.tap()
        wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Studio Notes 2"), evaluatedWith: title)], timeout: 30)
        let ribbon = app.buttons["editor.ribbon"]
        XCTAssertTrue(ribbon.waitForExistence(timeout: 10))
        XCTAssertTrue(ribbon.label.hasPrefix("Page 2 of"), "the other notebook opens at the linked page: \(ribbon.label)")
        let back = app.buttons["editor.link.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the way back is offered")
        XCTAssertEqual(back.label, "Back to Physics II 3")
        attach(app, "link-notebook-followed")
        back.tap()
        wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Physics II 3"), evaluatedWith: title)], timeout: 30)
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        sleep(1)
        attach(app, "links-on-page")
    }

    func testARecordingReplaysWithItsInk() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "modes", "-resetStorage", "-seedLibrary", "3", "-seedReplay", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Lecture Replay"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        XCTAssertEqual(strokeCount(canvas), 4)

        app.buttons["Recordings"].firstMatch.tap()
        let replay = app.buttons["recording.replay.1"]
        XCTAssertTrue(replay.waitForExistence(timeout: 10))
        attach(app, "recordings-list")
        replay.tap()
        let bar = app.descendants(matching: .any)["editor.replay.bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["editor.back"].waitForNonExistence(timeout: 5), "the toolbar is put away")
        let play = app.buttons["editor.replay.play"]
        play.tap()
        XCTAssertEqual(play.label, "Play", "paused")
        sleep(1)
        attach(app, "replay-start")
        XCTAssertTrue((bar.value as? String ?? "").hasSuffix("of 5 strokes written"), "\(String(describing: bar.value))")

        drag(on: canvas, y: 0.6)
        XCTAssertTrue(bar.exists, "a sideways drag doesn't pull the editor shut")
        XCTAssertEqual(strokeCount(canvas), 4, "and nothing can be written while replaying")

        let position = app.sliders["editor.replay.position"]
        position.adjust(toNormalizedSliderPosition: 0.55)
        sleep(1)
        attach(app, "replay-middle")
        let middle = bar.value as? String ?? ""
        XCTAssertTrue(["2 of 5 strokes written", "3 of 5 strokes written"].contains(middle), middle)
        position.adjust(toNormalizedSliderPosition: 1)
        sleep(2)
        attach(app, "replay-end")
        XCTAssertEqual(bar.value as? String, "5 of 5 strokes written")
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.2"].waitForExistence(timeout: 5), "the replay turned to the second page")

        app.buttons["editor.replay.done"].tap()
        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 5))
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
    }

    func testInkIsSelectedAndMovedAcrossPages() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "modes", "-resetStorage", "-seedLibrary", "3", "-seedReplay", "-drawingInput", "anyInput"]
        app.launch()
        let notebook = app.buttons["notebook.Lecture Replay"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let first = app.descendants(matching: .any)["page.canvas.1"], second = app.descendants(matching: .any)["page.canvas.2"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        XCTAssertEqual(strokeCount(first), 4)

        app.buttons["More"].firstMatch.tap()
        app.buttons["Select Ink Across Pages"].firstMatch.tap()
        let status = app.staticTexts["editor.ink.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Draw round ink on any page")
        func drag(_ from: CGVector, _ to: CGVector) {
            first.coordinate(withNormalizedOffset: from).press(forDuration: 0.1, thenDragTo: first.coordinate(withNormalizedOffset: to), withVelocity: 400, thenHoldForDuration: 0.2)
        }

        drag(CGVector(dx: 0.1, dy: 0.43), CGVector(dx: 0.9, dy: 0.53))
        XCTAssertEqual(status.label, "1 stroke. Drag it to move it.", "a drag across the last line of writing catches it")
        XCTAssertEqual(strokeCount(first), 4, "and draws nothing")
        attach(app, "ink-selected")

        drag(CGVector(dx: 0.4, dy: 0.48), CGVector(dx: 0.4, dy: 1.07))
        XCTAssertEqual(strokeCount(first), 3, "dragged past the foot of the page, the line leaves it")
        XCTAssertEqual(strokeCount(second), 3, "and joins the next page")
        sleep(1)
        attach(app, "ink-moved")
        app.buttons["editor.ink.undo"].tap()
        XCTAssertEqual(strokeCount(first), 4, "one undo puts both pages back")
        XCTAssertEqual(strokeCount(second), 2)

        drag(CGVector(dx: 0.1, dy: 0.13), CGVector(dx: 0.9, dy: 0.32))
        XCTAssertEqual(status.label, "2 strokes. Drag them to move them.")
        app.buttons["editor.ink.duplicate"].tap()
        XCTAssertEqual(strokeCount(first), 6)
        app.buttons["editor.ink.delete"].tap()
        XCTAssertEqual(strokeCount(first), 4, "the copies were what was selected")
        app.buttons["editor.ink.done"].tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 5))
        drag(CGVector(dx: 0.2, dy: 0.7), CGVector(dx: 0.7, dy: 0.72))
        XCTAssertEqual(strokeCount(first), 5, "writing carries on afterwards")
    }

    func testDrawAndHoldStraightensAStroke() throws {
        let app = XCUIApplication()
        let canvas = openNotebook(app, input: "anyInput")
        let undo = app.buttons["editor.undo"]
        func draw(hold: TimeInterval, y: Double) {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: y))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: y + 0.12)), withVelocity: 400, thenHoldForDuration: hold)
        }

        draw(hold: 0.1, y: 0.2)
        XCTAssertEqual(strokeCount(canvas), 1)
        undo.tap()
        XCTAssertEqual(strokeCount(canvas), 0, "a stroke lifted straight away is left as drawn: one undo removes it")

        draw(hold: 1.2, y: 0.4)
        XCTAssertEqual(strokeCount(canvas), 1)
        sleep(1)
        attach(app, "shape-straightened")
        undo.tap()
        XCTAssertEqual(strokeCount(canvas), 1, "after a hold the stroke was straightened: the first undo gives the hand-drawn one back")
        undo.tap()
        XCTAssertEqual(strokeCount(canvas), 0, "and the second removes it")
    }

    func testAFingerThatCannotDrawIsToldHowItCan() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "modes", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "pencilOnly", "-freshToolPresets",
                               "-freshFingerDrawHint"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let canvas = app.element("page.canvas.1")
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        let letFingersDraw = app.buttons["Let Fingers Draw"]
        XCTAssertFalse(letFingersDraw.exists)

        drag(on: canvas, y: 0.3)
        XCTAssertTrue(letFingersDraw.waitForExistence(timeout: 5), "a finger that drew nothing is told why")
        XCTAssertEqual(strokeCount(canvas), 0)
        let notice = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Only Apple Pencil draws right now.")).firstMatch
        XCTAssertTrue(notice.exists)
        attach(app, "only-pencil-draws")

        letFingersDraw.tap()
        XCTAssertTrue(letFingersDraw.waitForNonExistence(timeout: 5), "the notice goes")
        XCTAssertFalse(notice.exists)
        drag(on: canvas, y: 0.5)
        XCTAssertEqual(strokeCount(canvas), 1, "and now a finger draws")
    }

    func testPresenterNotesSitBesideThePage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "modes", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput", "-secondScreenInset"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 20))

        app.buttons["More"].firstMatch.tap()
        app.buttons["Presenter Notes…"].firstMatch.tap()
        let editor = app.textViews["presenter.notes.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("Start with the question")
        let notesDone = app.buttons["presenter.notes.done"]
        notesDone.waitUntilStill()
        attach(app, "presenter-notes-sheet")
        notesDone.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))

        app.buttons["More"].firstMatch.tap()
        app.buttons["Present"].firstMatch.tap()
        let panel = app.descendants(matching: .any)["presenter.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "with a second screen showing the page, the iPad keeps the notes beside it")
        XCTAssertTrue(app.staticTexts["Start with the question"].waitForExistence(timeout: 5))
        let stage = app.images["presentation.stage.page"]
        XCTAssertTrue(stage.waitForExistence(timeout: 10))
        XCTAssertEqual(stage.frame.height, 270, accuracy: 2, "the audience still sees the whole page")
        sleep(1)
        attach(app, "presenter-view")

        let next = app.buttons["presenter.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 5), "tapping the next page shows it")
        XCTAssertTrue(app.staticTexts["presenter.notes.empty"].waitForExistence(timeout: 5))
        app.buttons["editor.present.next"].tap()
        XCTAssertTrue(app.staticTexts["presenter.last"].waitForExistence(timeout: 5))

        app.buttons["editor.present.notes"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "the panel can be put away")
        app.buttons["editor.present.done"].tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 5))
    }

    func testPagesExportAsImagesAndTheLibraryBacksUp() throws {
        let app = XCUIApplication()
        _ = openNotebook(app, input: "anyInput")
        app.buttons["editor.title"].tap()
        app.buttons["Export"].firstMatch.tap()
        app.buttons["Every Page as an Image…"].firstMatch.tap()
        let start = app.buttons["export.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "the pages are chosen first")
        start.tap()
        let ready = app.staticTexts["Your 3 images are ready."]
        XCTAssertTrue(ready.waitForExistence(timeout: 30), "one image for each of the notebook's three pages")
        attach(app, "export-images")
        app.buttons["Done"].firstMatch.tap()
        app.buttons["editor.back"].tap()

        let settings = app.buttons["Settings"].firstMatch
        if !settings.waitForExistence(timeout: 10) || !settings.isHittable { app.buttons["ToggleSidebar"].firstMatch.tap() }
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let backUp = app.buttons["settings.backup.create"]
        // Far enough up that the row a finished backup adds under it is on screen too.
        let foot = app.windows.firstMatch.frame.maxY - 160
        for _ in 0..<6 where !backUp.exists || !backUp.isHittable || backUp.frame.maxY > foot { app.swipeUp() }
        XCTAssertTrue(backUp.waitForExistence(timeout: 5))
        attach(app, "settings-backup")
        backUp.tap()
        XCTAssertTrue(app.buttons["settings.backup.share"].waitForExistence(timeout: 30), "the backup is written and offered to share")
    }

    func testAStickerOfYourOwnIsMadeFromAPhoto() throws {
        let app = XCUIApplication()
        _ = openNotebook(app, input: "anyInput")
        app.buttons["Add"].firstMatch.tap()
        app.buttons["Sticker…"].firstMatch.tap()
        let new = app.buttons["sticker.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        attach(app, "sticker-drawer-own-empty")
        new.tap()
        let photo = app.scrollViews.images.matching(NSPredicate(format: "label CONTAINS[c] %@", "photo")).firstMatch
        try XCTSkipUnless(photo.waitForExistence(timeout: 15), "this simulator's photo library is empty")
        photo.tap()
        let mine = app.buttons["sticker.mine.1"]
        let whole = app.buttons["Use Whole Photo"]
        if !mine.waitForExistence(timeout: 20), !whole.exists, photo.exists { photo.tap() }
        if !mine.waitForExistence(timeout: 20) {
            XCTAssertTrue(whole.waitForExistence(timeout: 20), "with no subject to lift, the whole photo is offered")
            whole.tap()
        }
        XCTAssertTrue(mine.waitForExistence(timeout: 20), "the new sticker is kept in the drawer")
        sleep(1)
        attach(app, "sticker-drawer-own")
        mine.tap()
        let placed = app.images["Sticker"]
        XCTAssertTrue(placed.waitForExistence(timeout: 20), "and lands on the page")
        XCTAssertTrue(app.buttons["editor.arrange.done"].waitForExistence(timeout: 5))
        sleep(1)
        let before = placed.frame
        let handle = app.otherElements["Resize and rotate"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        // Points on the window: one taken from the handle is looked up again at every step of the drag, as the handle moves.
        let grip = handle.frame, window = app.coordinate(withNormalizedOffset: .zero)
        window.withOffset(CGVector(dx: grip.midX, dy: grip.midY))
            .press(forDuration: 0.1, thenDragTo: window.withOffset(CGVector(dx: grip.midX + grip.width * 2, dy: grip.midY + grip.height * 1.7)),
                   withVelocity: 200, thenHoldForDuration: 0.2)
        XCTAssertGreaterThan(placed.frame.width, before.width * 1.2, "the handle makes it larger")
        sleep(1)
        attach(app, "sticker-own-on-page")
    }

    func testPresentingTakesOverASecondScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "modes", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput", "-secondScreenInset"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        let stage = app.images["presentation.stage.page"]
        XCTAssertFalse(stage.exists, "nothing is put on the second screen until presenting starts")

        app.buttons["More"].firstMatch.tap()
        app.buttons["Present"].firstMatch.tap()
        let done = app.buttons["editor.present.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["editor.present.screen"].waitForExistence(timeout: 5), "the bar says the second screen is in use")
        XCTAssertTrue(stage.waitForExistence(timeout: 10), "the page goes up on the second screen")
        // With the notes put away the page has the whole iPad, so a pinch zooms past the height of the screen.
        app.buttons["editor.present.notes"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["presenter.panel"].waitForNonExistence(timeout: 5))
        sleep(1)
        let whole = stage.frame
        XCTAssertEqual(whole.height, 270, accuracy: 2, "the whole page, as tall as the screen")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)), withVelocity: 600, thenHoldForDuration: 0.2)
        attach(app, "second-screen")

        canvas.pinch(withScale: 3, velocity: 1.5)
        sleep(1)
        attach(app, "second-screen-zoomed")
        XCTAssertGreaterThan(stage.frame.height, whole.height * 1.08, "zooming in on the iPad zooms the second screen")

        app.buttons["editor.present.next"].tap()
        XCTAssertTrue(app.staticTexts["Page 2 of 3"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertEqual(stage.frame.height, 270, accuracy: 2, "the next page is shown whole again")
        done.tap()
        XCTAssertTrue(stage.waitForNonExistence(timeout: 5), "the second screen is handed back when presenting ends")
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 5))
    }
}
