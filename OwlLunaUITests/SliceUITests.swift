import XCTest

/// The vertical slice: launch, library, new notebook, write, autosave, back, relaunch, and a seeded notebook.
@MainActor
final class SliceUITests: XCTestCase {
    private let root = "slice"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(reset: Bool, seed: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", root, "-drawingInput", "anyInput"] + (reset ? ["-resetStorage"] : []) + (seed ? ["-seedLibrary", "3"] : []) + extra
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The heading, or on a folded iPhone Duo, which has no bar title once the heading scrolls away, the thumb index's chosen tab.
    private func waitForLibrary(_ app: XCUIApplication) {
        let shown = NSPredicate(format: "(elementType == %lu AND label == %@) OR (identifier == %@ AND selected == YES)",
                                XCUIElement.ElementType.staticText.rawValue, "All notebooks", "index.All notebooks")
        XCTAssertTrue(app.descendants(matching: .any).matching(shown).firstMatch.waitForExistence(timeout: 30), "library heading")
    }

    private func write(_ strokes: Int, on canvas: XCUIElement) {
        for index in 0..<strokes {
            let y = 0.18 + Double(index) * 0.06
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: y))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: y + 0.01)),
                       withVelocity: 400, thenHoldForDuration: 0.05)
        }
    }

    private func strokeCount(_ canvas: XCUIElement) -> Int {
        let value = (canvas.value as? String) ?? ""
        return Int(value.split(separator: " ").first ?? "") ?? 0
    }

    func testVerticalSlice() throws {
        var app = launch(reset: true, seed: true)
        waitForLibrary(app)
        let seeded = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(seeded.waitForExistence(timeout: 10), "the seeded notebooks are on the shelf")
        attach(app, "library-light")
        try audit(app, [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription], screen: "library")

        app.buttons["New"].firstMatch.tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("Slice Test")
        app.buttons["Print"].firstMatch.tap()
        attach(app, "new-notebook-print")
        app.buttons["Create"].firstMatch.tap()

        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15), "the editor opens on page 1")
        write(3, on: canvas)
        XCTAssertEqual(strokeCount(canvas), 3)
        attach(app, "editor-written")
        try audit(app, [.contrast, .elementDetection, .sufficientElementDescription], screen: "editor")
        sleep(3)

        app.buttons["editor.back"].tap()
        waitForLibrary(app)
        let created = app.buttons["notebook.Slice Test"]
        XCTAssertTrue(created.waitForExistence(timeout: 10))
        XCTAssertTrue(created.label.contains("1 page"), created.label)
        let spread = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Continue writing Slice Test")).firstMatch
        XCTAssertTrue(spread.waitForExistence(timeout: 10), "the notebook just closed lies open at the top")
        spread.tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 15), "Continue writing opens at the page")
        app.buttons["editor.back"].tap()
        waitForLibrary(app)

        app.terminate()
        app = launch(reset: false)
        waitForLibrary(app)
        XCTAssertTrue(app.buttons["notebook.Slice Test"].waitForExistence(timeout: 10), "the notebook survives a relaunch")
        app.buttons["notebook.Slice Test"].tap()
        let reopened = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(5)
        while strokeCount(reopened) < 3, Date() < deadline { usleep(200_000) }
        XCTAssertEqual(strokeCount(reopened), 3, "the ink survives a relaunch")
        app.buttons["editor.back"].tap()
        waitForLibrary(app)

        app.buttons["notebook.Physics II 3"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["editor.ribbon"].label.contains("of 3"), app.buttons["editor.ribbon"].label)
        attach(app, "seeded-notebook")
    }

    /// Runs only on an iPhone destination: every cover swatch in New Notebook must be on screen, not clipped off a narrow sheet.
    func testUndoneInkStaysGoneWhenWritingAgain() throws {
        let app = launch(reset: true, seed: true)
        waitForLibrary(app)
        app.buttons["notebook.Physics II 3"].tap()
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let before = strokeCount(canvas)
        write(2, on: canvas)
        XCTAssertEqual(strokeCount(canvas), before + 2)
        app.buttons["editor.undo"].tap()
        XCTAssertEqual(strokeCount(canvas), before + 1)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.52)), withVelocity: 400, thenHoldForDuration: 0.05)
        XCTAssertEqual(strokeCount(canvas), before + 2, "the undone stroke doesn't come back with the next one")
        app.buttons["editor.undo"].tap()
        app.buttons["editor.undo"].tap()
        XCTAssertEqual(strokeCount(canvas), before)
        app.buttons["editor.redo"].tap()
        XCTAssertEqual(strokeCount(canvas), before + 1)
    }

    func testInkUndoneWhileItsPageIsOffScreenStaysGone() throws {
        let app = launch(reset: true, extra: ["-seedLongPDF"])
        let textbook = app.buttons["notebook.Textbook"]
        XCTAssertTrue(textbook.waitForExistence(timeout: 90))
        textbook.tap()
        let canvas = app.descendants(matching: .any)["page.canvas.1"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        write(2, on: canvas)
        XCTAssertEqual(strokeCount(canvas), 2)

        func open(page: Int) {
            app.buttons["editor.ribbon"].tap()
            let thumbnail = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Page \(page) of 300")).firstMatch
            XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
            thumbnail.tap()
            if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        }
        open(page: 9)
        XCTAssertTrue(canvas.waitForNonExistence(timeout: 10), "page 1 has given up its canvas")
        app.buttons["editor.undo"].tap()
        if !canvas.waitForExistence(timeout: 3) { open(page: 1) }
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertEqual(strokeCount(canvas), 1)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.52)), withVelocity: 400, thenHoldForDuration: 0.05)
        XCTAssertEqual(strokeCount(canvas), 2, "the undone stroke doesn't come back with the next one")
    }

    func testNewNotebookSwatchesFitOnIPhone() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone layout check")
        let app = launch(reset: true)
        let new = app.buttons["New"].firstMatch
        if !new.waitForExistence(timeout: 10) { app.cells.firstMatch.tap() }
        XCTAssertTrue(new.waitForExistence(timeout: 10), "the shelf and its New button")
        new.tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 10))
        if app.buttons["Continue"].waitForExistence(timeout: 2) { app.buttons["Continue"].tap() }
        app.buttons["Cloth"].firstMatch.tap()
        let screen = app.windows.firstMatch.frame
        for name in ["Oxblood", "Tomato", "Mustard", "Moss", "Jade", "Cobalt", "Navy", "Plum", "Slate", "Rose", "Oat"] {
            let swatch = app.buttons[name].firstMatch
            XCTAssertTrue(swatch.exists, name)
            XCTAssertTrue(screen.contains(swatch.frame), "\(name) at \(swatch.frame) is outside \(screen)")
        }
        attach(app, "new-notebook-iphone")
    }

    func testDarkModeAndLargestTextScreenshots() throws {
        XCUIDevice.shared.appearance = .dark
        defer { XCUIDevice.shared.appearance = .light }
        var app = launch(reset: true, seed: true, extra: ["-appearance", "dark"])
        waitForLibrary(app)
        _ = app.buttons["notebook.Physics II 3"].waitForExistence(timeout: 10)
        attach(app, "library-dark")
        app.buttons["notebook.Physics II 3"].tap()
        _ = app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 15)
        sleep(1)
        attach(app, "editor-dark")
        app.buttons["editor.back"].tap()
        waitForLibrary(app)
        app.terminate()

        XCUIDevice.shared.appearance = .light
        app = launch(reset: false, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let notebook = app.buttons["notebook.Cell Biology 1"]
        // The notebooks start below the fold, where XCUITest doesn't see them.
        for _ in 0..<5 where !notebook.waitForExistence(timeout: 8) { app.swipeUp() }
        XCTAssertTrue(notebook.waitForExistence(timeout: 30), "the list layout shows the seeded notebooks")
        attach(app, "library-largest-text")
        try audit(app, [.dynamicType, .textClipped], screen: "largest text")
    }
}
