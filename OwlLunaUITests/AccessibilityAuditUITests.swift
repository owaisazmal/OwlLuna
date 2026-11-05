import XCTest

/// Apple's full accessibility audit on every main screen in light, dark and both with Increase Contrast,
/// then Dynamic Type, clipping and contrast again at a large text size, where the list layouts take over.
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
    private static let colourChecks: XCUIAccessibilityAuditType = .all
    private static let textSizeChecks: XCUIAccessibilityAuditType = [.dynamicType, .textClipped, .contrast]

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testAuditLight() throws { try tour("light", appearance: .light, checks: Self.colourChecks) }
    func testAuditDark() throws { try tour("dark", appearance: .dark, checks: Self.colourChecks) }
    func testAuditLightIncreaseContrast() throws { try tour("light+IC", appearance: .light, checks: Self.colourChecks, extra: ["-increaseContrast"]) }
    func testAuditDarkIncreaseContrast() throws { try tour("dark+IC", appearance: .dark, checks: Self.colourChecks, extra: ["-increaseContrast"]) }
    func testAuditLargeText() throws {
        try tour("AX-L", appearance: .light, checks: Self.textSizeChecks,
                 extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
    }

    private func tour(_ mode: String, appearance: XCUIDevice.Appearance, checks: XCUIAccessibilityAuditType, extra: [String] = []) throws {
        // Portrait: in landscape the iPadOS 27 simulator hands the audit a rotated screenshot, so contrast samples the wrong pixels.
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = appearance
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.appearance = .light
            XCUIDevice.shared.orientation = .portrait
        }
        let empty = XCUIApplication()
        empty.launchArguments = ["-storageRoot", "audit-empty", "-resetStorage"] + extra
        empty.launch()
        XCTAssertTrue(empty.buttons["Import PDF"].firstMatch.waitForExistence(timeout: 30))
        // The iPadOS 27 simulator ignores the switch above, and the app's own Dark setting misleads the contrast audit,
        // so the simulator is set beforehand (CI runs `simctl ui appearance` before each part).
        let wanted = appearance == .dark ? "dark" : "light"
        if isDark(empty.screenshot()) != (appearance == .dark) {
            throw XCTSkip("The simulator isn't \(wanted): run `xcrun simctl ui <device> appearance \(wanted)` first.")
        }
        XCTAssertTrue(empty.staticTexts["Your shelf is ready."].exists)
        try audit(empty, checks, screen: "\(mode) empty library")
        empty.terminate()

        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "audit", "-resetStorage", "-keepUndoVisible", "-seedLibrary", "6", "-seedLongPDF", "-seedJournal", "-indexSeed", "-seedActivity", "-seedReplay", "-seedHandwriting", "-fakeTranscript", "-fakeTranslate", "-fakeCalendar", "-fakeScan", "-fakeUnlockOnce", "-drawingInput", "anyInput"] + extra
        app.launch()
        let textbook = app.buttons["notebook.Textbook"]
        XCTAssertTrue(textbook.waitForExistence(timeout: 90))
        sleep(1)

        var pageText: [String] = []
        func check(_ screen: String, modal: Bool = false, scrolled: Bool = false, formText: [String] = [], sheet: XCUIElement? = nil,
                   popover: Bool = false, overlay: XCUIElement? = nil, bar: XCUIElement? = nil, cutBy list: XCUIElement? = nil) throws {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(mode) \(screen)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try audit(app, checks, screen: "\(mode) \(screen)", modal: modal, scrolled: scrolled, formText: formText, sheet: sheet, popover: popover,
                      largeText: mode == "AX-L", overlay: overlay, bar: bar, pageText: pageText, cutBy: list)
        }

        /// Audits a sheet at the top, then again scrolled to the end, so text below the fold is checked while it's on screen.
        func checkSheet(_ screen: String, scrolling container: XCUIElement, formText: [String] = [], popover: Bool = false,
                        cutBy list: XCUIElement? = nil) throws {
            try check(screen, modal: true, formText: formText, popover: popover, cutBy: list)
            guard container.exists else { return }
            container.swipeUp(velocity: .fast)
            container.swipeUp(velocity: .fast)
            sleep(3)
            try check("\(screen) (end)", modal: true, scrolled: true, formText: formText, popover: popover, cutBy: list)
        }

        func dismissKeyboard() {
            let keyboard = app.keyboards.firstMatch
            guard keyboard.waitForExistence(timeout: 3), keyboard.frame.intersects(app.windows.firstMatch.frame) else { sleep(1); return }
            let hide = app.keyboards.buttons["Hide keyboard"]
            let hittable = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: hide)
            wait(for: [hittable], timeout: 5)
            hide.tap()
            let gone = NSPredicate { _, _ in !keyboard.exists || keyboard.frame.height < 100 || !keyboard.frame.intersects(app.windows.firstMatch.frame) }
            wait(for: [expectation(for: gone, evaluatedWith: nil)], timeout: 5)
            sleep(1)
        }

        try check("library")

        let field = app.openLibrarySearch()
        field.typeText("Chapter 142")
        field.typeText("\n")
        let hit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Textbook, page 142:")).firstMatch
        for _ in 0..<4 where !hit.waitForExistence(timeout: 5) { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.6)).press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.25))) }
        XCTAssertTrue(hit.exists)
        try check("search")
        app.terminate()
        app.launchArguments.removeAll { $0 == "-resetStorage" }
        app.launch()
        XCTAssertTrue(textbook.waitForExistence(timeout: 30))
        sleep(3)

        func sidebar(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        }

        func openNotebookMenu(_ notebook: XCUIElement, item: String) -> Bool {
            // Audits can scroll the library, and a large-text row may only be partly visible.
            let library = app.scrollViews["library.scroll"]
            var isVisible = false
            for _ in 0..<15 {
                let visible = library.frame.intersection(app.windows.firstMatch.frame).insetBy(dx: 0, dy: 30)
                if notebook.exists, notebook.isHittable, visible.contains(notebook.frame) {
                    isVisible = true
                    break
                }
                if notebook.exists, notebook.frame.minY < visible.minY { library.swipeDown() }
                else { library.swipeUp() }
            }
            guard isVisible else {
                XCTFail("Notebook is not visible: \(notebook.identifier)")
                return false
            }
            notebook.waitUntilStill()
            let action = app.buttons[item].firstMatch
            notebook.press(forDuration: 1.2)
            if !action.waitForExistence(timeout: 5) { notebook.press(forDuration: 1.5) }
            guard action.waitForExistence(timeout: 5) else {
                XCTFail("Notebook menu did not open: \(item)")
                return false
            }
            action.tap()
            return true
        }
        sidebar("Recently deleted").tap()
        sleep(1)
        try check("recently deleted")
        sidebar("All notebooks").tap()
        // Returning from another shelf preserves its scroll position. At accessibility
        // sizes the calendar is a lazy ledger row and may not have been created yet.
        let week = app.buttons["writing.week"].firstMatch
        let library = app.scrollViews["library.scroll"]
        for _ in 0..<10 {
            if week.exists, week.isHittable, library.frame.contains(week.frame) { break }
            library.swipeDown(velocity: .fast)
        }
        guard week.waitForExistence(timeout: 10), week.isHittable else {
            XCTFail("Writing calendar row is not visible after returning to All notebooks")
            return
        }
        week.waitUntilStill()
        week.tap()
        XCTAssertTrue(app.navigationBars["Writing Calendar"].waitForExistence(timeout: 10))
        sleep(1)
        try check("writing calendar", modal: true, sheet: app.scrollViews["writing.calendar"])
        let calendarDone = app.navigationBars["Writing Calendar"].buttons["Done"]
        if calendarDone.exists { calendarDone.tap() }
        XCTAssertTrue(app.navigationBars["Writing Calendar"].waitForNonExistence(timeout: 5))

        let biology = app.buttons["notebook.Cell Biology 1"]
        XCTAssertTrue(biology.waitForExistence(timeout: 10))
        guard openNotebookMenu(biology, item: "Delete") else { return }
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5))
        // Pressing the notebook scrolled the library to it, and scrolled, the audit places the header where it stood at the top.
        app.scrollViews["library.scroll"].swipeDown(velocity: .fast)
        app.scrollViews["library.scroll"].swipeDown(velocity: .fast)
        sleep(1)
        try check("library undo slip", overlay: app.buttons["Undo"])
        guard app.buttons["Undo"].exists else {
            XCTFail("Undo must stay visible until the accessibility audit finishes")
            return
        }
        app.buttons["Undo"].tap()
        XCTAssertTrue(biology.waitForExistence(timeout: 5), "Undo puts the notebook back")

        app.buttons["New"].firstMatch.tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 30))
        dismissKeyboard()
        sleep(1)
        try checkSheet("new notebook", scrolling: app.scrollViews.firstMatch)
        app.buttons["Cancel"].firstMatch.tap()

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        sleep(1)
        try checkSheet("settings", scrolling: app.scrollViews.firstMatch,
                       formText: ["Cobalt", "Tomato", "Moss", "Oxblood", "Mustard", "Print",
                                  "Stop Using Daily Journal", "About", "Sync with iCloud", "iCloud isn't available", "Sync Now",
                                  "Back Up Library", "Restore from a Backup", "Straighten Shapes", "Print Today's Events",
                                  "Find Notebooks in Spotlight", "Notebooks can be found", "Touch and hold a notebook", "A backup is one file",
                                  "Report a Problem or Request a Feature", "OwlLuna is free and open source"])
        app.buttons["Done"].firstMatch.tap()

        guard openNotebookMenu(textbook, item: "Change Cover…") else { return }
        XCTAssertTrue(app.navigationBars["Change Cover"].waitForExistence(timeout: 10))
        sleep(1)
        try checkSheet("change cover", scrolling: app.scrollViews.firstMatch)
        app.buttons["Cancel"].firstMatch.tap()

        textbook.tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 20))
        sleep(1)
        try check("editor")
        app.buttons["Add"].firstMatch.tap()
        let choosePaper = app.buttons["Choose Paper…"].firstMatch
        XCTAssertTrue(choosePaper.waitForExistence(timeout: 5))
        choosePaper.tap()
        XCTAssertTrue(app.scrollViews["paper.drawer"].waitForExistence(timeout: 10))
        sleep(1)
        // At AX-L the drawer is a long list, and the audit misreads rows it scrolls back into view, so only its top is audited.
        if mode == "AX-L" {
            try check("paper drawer", modal: true, popover: true)
        } else {
            try checkSheet("paper drawer", scrolling: app.scrollViews["paper.drawer"], popover: true)
        }
        app.buttons["Done"].firstMatch.tap()
        app.buttons["editor.ribbon"].tap()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 10))
        sleep(1)
        try check("page navigator", modal: true)
        app.buttons["Outline"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No Bookmarks Yet"].waitForExistence(timeout: 5))
        try check("page outline", modal: true)
        app.buttons["Done"].firstMatch.tap()

        app.buttons["Add"].firstMatch.tap()
        let stickers = app.buttons["Sticker…"].firstMatch
        XCTAssertTrue(stickers.waitForExistence(timeout: 5))
        stickers.tap()
        XCTAssertTrue(app.navigationBars["Stickers"].waitForExistence(timeout: 10))
        sleep(1)
        try check("sticker drawer", modal: true, cutBy: app.scrollViews["sticker.drawer"])
        app.buttons["sticker.noteYellow"].tap()
        XCTAssertTrue(app.buttons["editor.arrange.done"].waitForExistence(timeout: 5))
        sleep(1)
        try check("sticker selected", bar: app.otherElements["editor.arrange.bar"])
        app.buttons["editor.arrange.done"].tap()

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Text Box"].firstMatch.tap()
        let typing = app.textViews["page.text.editor"]
        XCTAssertTrue(typing.waitForExistence(timeout: 10))
        typing.typeText("Chapter notes")
        pageText = ["Chapter notes", "Text box", "Link to "]
        sleep(1)
        try check("text box", bar: app.otherElements["editor.arrange.bar"])
        app.buttons["editor.arrange.done"].tap()

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Link…"].firstMatch.tap()
        let linkTabs = app.element("link.tabs")
        XCTAssertTrue(linkTabs.waitForExistence(timeout: 10))
        sleep(1)
        try check("link picker", modal: true)
        linkTabs.buttons["Another Notebook"].tap()
        sleep(1)
        let linkList = app.scrollViews.containing(NSPredicate(format: "identifier BEGINSWITH 'link.notebook.'")).firstMatch
        try checkSheet("link notebooks", scrolling: linkList, cutBy: linkList)
        linkTabs.buttons["Web"].tap()
        dismissKeyboard()
        try check("link web address", modal: true)
        linkTabs.buttons["This Notebook"].tap()
        sleep(1)
        if app.buttons["link.page.2"].exists {
            app.buttons["link.page.2"].tap()
            XCTAssertTrue(app.buttons["editor.arrange.done"].waitForExistence(timeout: 5))
            sleep(1)
            try check("link selected", bar: app.otherElements["editor.arrange.bar"])
            app.buttons["editor.arrange.done"].tap()
        } else {
            app.buttons["Cancel"].firstMatch.tap()
        }

        app.buttons["More"].firstMatch.tap()
        app.buttons["Focus Mode"].firstMatch.tap()
        XCTAssertTrue(app.buttons["editor.focus.exit"].waitForExistence(timeout: 5))
        sleep(1)
        try check("focus mode")
        app.buttons["editor.focus.exit"].tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 5))
        app.buttons["More"].firstMatch.tap()
        app.buttons["Presenter Notes…"].firstMatch.tap()
        let notes = app.textViews["presenter.notes.editor"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.typeText("Open with the question")
        dismissKeyboard()
        try check("presenter notes", modal: true)
        app.buttons["presenter.notes.done"].tap()
        XCTAssertTrue(notes.waitForNonExistence(timeout: 5))

        app.buttons["More"].firstMatch.tap()
        app.buttons["Present"].firstMatch.tap()
        XCTAssertTrue(app.buttons["editor.present.done"].waitForExistence(timeout: 5))
        sleep(1)
        try check("presenting", bar: app.otherElements["editor.present.bar"])
        if app.buttons["editor.present.notes"].exists {
            app.buttons["editor.present.notes"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["presenter.panel"].waitForExistence(timeout: 5))
            sleep(1)
            try check("presenter view", bar: app.otherElements["editor.present.bar"])
        }
        app.buttons["editor.present.done"].tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 5))

        app.buttons["More"].firstMatch.tap()
        app.buttons["Select Ink Across Pages"].firstMatch.tap()
        XCTAssertTrue(app.buttons["editor.ink.done"].waitForExistence(timeout: 5))
        sleep(1)
        try check("select ink", bar: app.otherElements["editor.ink.bar"])
        app.buttons["editor.ink.done"].tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 5))

        app.buttons["Recordings"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No Recordings"].firstMatch.waitForExistence(timeout: 5))
        try check("recordings", modal: true)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7)).tap()
        if app.navigationBars["Recordings"].exists, app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        XCTAssertTrue(app.staticTexts["No Recordings"].firstMatch.waitForNonExistence(timeout: 5))

        app.buttons["editor.title"].tap()
        let beside = app.buttons["Open Another Notebook Beside…"].firstMatch
        if beside.waitForExistence(timeout: 5) {
            beside.tap()
            XCTAssertTrue(app.navigationBars["Open Beside"].waitForExistence(timeout: 10))
            sleep(1)
            let besideList = app.scrollViews.containing(NSPredicate(format: "identifier BEGINSWITH 'beside.notebook.'")).firstMatch
            XCTAssertTrue(besideList.exists)
            // Like the link picker, this ledger exposes rows beyond the sheet's edge.
            // Audit them once scrolled into view, rather than sampling the dimmed editor.
            try checkSheet("beside picker", scrolling: besideList, cutBy: besideList)
            // At the top of the list a swipe down pulls the sheet away, so stop once the row is in sight.
            let lectureRow = app.buttons["beside.notebook.Lecture Replay"]
            for _ in 0..<4 where !(lectureRow.exists && lectureRow.isHittable && besideList.frame.contains(lectureRow.frame)) {
                besideList.swipeDown()
            }
            lectureRow.tap()
            XCTAssertTrue(app.buttons["editor.close.pane"].waitForExistence(timeout: 20))
            sleep(2)
            try check("two notebooks")
            app.buttons.matching(identifier: "Recordings").element(boundBy: 1).tap()
            let replay = app.buttons["recording.replay.1"]
            XCTAssertTrue(replay.waitForExistence(timeout: 10))
            sleep(1)
            try check("recordings list", modal: true, formText: ["The pencil replays"])
            replay.tap()
            let play = app.buttons["editor.replay.play"]
            XCTAssertTrue(play.waitForExistence(timeout: 10))
            play.tap()
            sleep(1)
            try check("replay", bar: app.otherElements["editor.replay.bar"])
            app.buttons["editor.replay.done"].tap()
            XCTAssertTrue(app.buttons["editor.close.pane"].waitForExistence(timeout: 5))
            app.buttons["editor.close.pane"].tap()
            XCTAssertTrue(app.buttons["editor.close.pane"].waitForNonExistence(timeout: 10))
        } else {
            // At the largest text sizes the menu is a list; the split view is audited at the default size.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        }
        sleep(1)
        app.buttons["editor.back"].firstMatch.tap()

        // Study tape, handwriting as text and the film of a page.
        let study = app.buttons["notebook.Study Notes"]
        XCTAssertTrue(study.waitForExistence(timeout: 20))
        study.tap()
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        app.buttons["Add"].firstMatch.tap()
        app.buttons["Study Tape"].firstMatch.tap()
        XCTAssertTrue(app.buttons["editor.arrange.done"].waitForExistence(timeout: 5))
        sleep(1)
        try check("tape selected", bar: app.otherElements["editor.arrange.bar"])
        app.buttons["editor.arrange.done"].tap()
        let tape = app.buttons["Study tape"]
        XCTAssertTrue(tape.waitForExistence(timeout: 5))
        tape.tap()
        sleep(1)
        try check("tape lifted")

        app.buttons["More"].firstMatch.tap()
        app.buttons["Select Ink Across Pages"].firstMatch.tap()
        XCTAssertTrue(app.buttons["editor.ink.done"].waitForExistence(timeout: 5))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.14))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.33)), withVelocity: 400, thenHoldForDuration: 0.2)
        let asText = app.buttons["editor.ink.text"]
        XCTAssertTrue(asText.waitForExistence(timeout: 5))
        sleep(1)
        try check("ink selected", bar: app.otherElements["editor.ink.bar"])
        asText.tap()
        XCTAssertTrue(app.textViews["inktext.editor"].waitForExistence(timeout: 20))
        sleep(1)
        try check("handwriting as text", modal: true)
        let translate = app.buttons["inktext.translate"]
        XCTAssertTrue(translate.waitForExistence(timeout: 10))
        translate.tap()
        app.buttons["French"].firstMatch.tap()
        XCTAssertTrue(app.buttons["inktext.original"].waitForExistence(timeout: 10))
        sleep(1)
        try check("handwriting translated", modal: true, formText: ["Translated into French"])
        app.buttons["Cancel"].firstMatch.tap()
        app.buttons["editor.ink.done"].tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 5))

        // Find, the zoom window, today's events and a scanned sheet.
        app.buttons["More"].firstMatch.tap()
        app.buttons["Find in Notebook…"].firstMatch.tap()
        let find = app.element("editor.find.field")
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        find.typeText("hello")
        XCTAssertTrue(app.staticTexts["editor.find.status"].waitForExistence(timeout: 40))
        dismissKeyboard()
        try check("find", bar: app.otherElements["editor.find.bar"])
        app.buttons["editor.find.done"].tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 5))

        app.buttons["More"].firstMatch.tap()
        app.buttons["Zoom Window"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["zoom.canvas"].waitForExistence(timeout: 10))
        sleep(1)
        try check("zoom window")
        app.buttons["zoom.close"].tap()

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Today's Events"].firstMatch.tap()
        XCTAssertTrue(app.buttons["editor.arrange.done"].waitForExistence(timeout: 10))
        pageText += ["All day", Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))]
        sleep(1)
        try check("today's events", bar: app.otherElements["editor.arrange.bar"])
        app.buttons["editor.arrange.done"].tap()

        app.buttons["editor.title"].tap()
        app.buttons["Export"].firstMatch.tap()
        let film = app.buttons["This Page as a Time-lapse Video…"].firstMatch
        XCTAssertTrue(film.waitForExistence(timeout: 5))
        film.tap()
        XCTAssertTrue(app.staticTexts["Your video is ready."].waitForExistence(timeout: 60))
        sleep(1)
        try check("export video", modal: true)
        app.buttons["Done"].firstMatch.tap()

        app.buttons["Add"].firstMatch.tap()
        app.buttons["Scan Documents…"].firstMatch.tap()
        let scanned = expectation(for: NSPredicate(format: "label == 'Page 2 of 4'"), evaluatedWith: app.buttons["editor.ribbon"])
        wait(for: [scanned], timeout: 20)
        sleep(1)
        try check("scanned page")
        app.buttons["editor.back"].firstMatch.tap()

        // A transcript, and the replay it leads.
        let lecture = app.buttons["notebook.Lecture Replay"]
        XCTAssertTrue(lecture.waitForExistence(timeout: 20))
        lecture.tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 20))
        if app.buttons["Recordings"].firstMatch.exists {
            app.buttons["Recordings"].firstMatch.tap()
        } else {
            app.buttons["More"].firstMatch.tap()
            app.buttons["Recordings"].firstMatch.tap()
        }
        let transcript = app.buttons["recording.transcript.1"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        transcript.tap()
        let transcribe = app.buttons["transcript.start"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 5))
        sleep(1)
        try check("transcript offer", modal: true, popover: true)
        transcribe.tap()
        let line = app.buttons["transcript.line.2"]
        XCTAssertTrue(line.waitForExistence(timeout: 15))
        sleep(1)
        try check("transcript", modal: true, formText: ["Tap a line to hear it"], popover: true)
        line.tap()
        let play = app.buttons["editor.replay.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        sleep(1)
        try check("replay with transcript", bar: app.otherElements["editor.replay.bar"])
        app.buttons["editor.replay.done"].tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 5))
        app.buttons["editor.back"].firstMatch.tap()

        // A notebook locked while it is open stays open until the app leaves the screen; back in front, it is behind its lock.
        let recipes = app.buttons["notebook.Recipes 4"]
        // At the large text size the library is a list, and a row further down isn't there until it is scrolled to.
        for _ in 0..<6 where !recipes.waitForExistence(timeout: 5) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.3)))
        }
        XCTAssertTrue(recipes.exists)
        recipes.tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 20))
        app.buttons["editor.title"].tap()
        app.buttons["Lock…"].firstMatch.tap()
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(app.buttons["lock.unlock"].waitForExistence(timeout: 15))
        sleep(2)
        try check("locked notebook")
        app.buttons["lock.close"].tap()
        XCTAssertTrue(recipes.waitForExistence(timeout: 20))
        sleep(1)
        try check("library with a locked notebook")
    }
}
