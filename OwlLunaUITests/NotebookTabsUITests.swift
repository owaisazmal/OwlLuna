import XCTest

/// Several notebooks open in one window as tabs: opened from the title menu and the bar, switched between with their
/// undo history kept, closed one by one, and still there after a visit to the library and after the app is stopped.
@MainActor
final class NotebookTabsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "tabs", "-drawingInput", "anyInput"] + extra
        app.launch()
        return app
    }

    private func pick(_ title: String, in app: XCUIApplication) {
        let row = app.buttons["beside.notebook.\(title)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the picker offers \(title)")
        row.tap()
    }

    private func title(_ app: XCUIApplication) -> String { app.buttons["editor.title"].label }

    /// Holds a tab until its menu is up, and chooses from it.
    private func choose(_ item: String, for tab: XCUIElement, in app: XCUIApplication) {
        tab.press(forDuration: 1.2)
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "a tab's menu offers \(item)")
        button.tap()
    }

    /// Waits for one tab to stand before another on the bar.
    private func expect(_ first: XCUIElement, before second: XCUIElement, _ message: String) {
        let ordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in first.frame.minX < second.frame.minX }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ordered], timeout: 5), .completed, message)
    }

    func testNotebooksOpenInTabsAndStayOpenBehindTheBar() throws {
        var app = launch(["-resetStorage", "-seedLibrary", "4"])
        let studio = app.buttons["notebook.Studio Notes 2"]
        XCTAssertTrue(studio.waitForExistence(timeout: 30))
        studio.tap()
        let ribbon = app.buttons["editor.ribbon"]
        XCTAssertTrue(ribbon.waitForExistence(timeout: 20))
        let add = app.buttons["tabs.add"]
        XCTAssertFalse(add.exists, "a notebook on its own has no tab bar")

        // The title menu opens a second notebook in a tab, and the bar appears.
        app.buttons["editor.title"].tap()
        app.buttons["Open Another Notebook in a Tab…"].firstMatch.tap()
        XCTAssertFalse(app.buttons["beside.notebook.Studio Notes 2"].waitForExistence(timeout: 2), "the notebook already open isn't offered")
        pick("Physics II 3", in: app)
        let studioTab = app.buttons["tabs.tab.Studio Notes 2"], physicsTab = app.buttons["tabs.tab.Physics II 3"]
        XCTAssertTrue(physicsTab.waitForExistence(timeout: 10))
        XCTAssertTrue(physicsTab.isSelected)
        XCTAssertFalse(studioTab.isSelected)
        wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'Physics II 3'"), evaluatedWith: app.buttons["editor.title"])], timeout: 10)
        attach(app, "two-tabs")

        // Written in one tab, then away and back: the ink is there and so is its undo.
        let canvas = app.element("page.canvas.1")
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)), withVelocity: 400, thenHoldForDuration: 0.05)
        wait(for: [expectation(for: NSPredicate(format: "value == '1 stroke'"), evaluatedWith: canvas)], timeout: 5)
        studioTab.tap()
        wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'Studio Notes 2'"), evaluatedWith: app.buttons["editor.title"])], timeout: 10)
        XCTAssertTrue(studioTab.isSelected)
        wait(for: [expectation(for: NSPredicate(format: "value == 'Empty'"), evaluatedWith: app.element("page.canvas.1"))], timeout: 10)
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled, "each notebook has its own undo")
        physicsTab.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == '1 stroke'"), evaluatedWith: app.element("page.canvas.1"))], timeout: 10)
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled, "the tab comes back with its undo history")
        app.buttons["editor.undo"].tap()
        wait(for: [expectation(for: NSPredicate(format: "value == 'Empty'"), evaluatedWith: app.element("page.canvas.1"))], timeout: 5)

        // A third from the bar's own button.
        add.tap()
        XCTAssertFalse(app.buttons["beside.notebook.Physics II 3"].waitForExistence(timeout: 2), "nor is one that already has a tab")
        pick("Recipes 4", in: app)
        let recipesTab = app.buttons["tabs.tab.Recipes 4"]
        XCTAssertTrue(recipesTab.waitForExistence(timeout: 10))
        XCTAssertTrue(recipesTab.isSelected)
        attach(app, "three-tabs")
        try audit(app, screen: "tabs")

        // Closing the tab on show shows its neighbour; closing one behind the bar leaves the one on show alone.
        app.buttons["tabs.close.Recipes 4"].tap()
        XCTAssertTrue(recipesTab.waitForNonExistence(timeout: 10))
        XCTAssertTrue(physicsTab.isSelected)
        wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'Physics II 3'"), evaluatedWith: app.buttons["editor.title"])], timeout: 10)
        app.buttons["tabs.close.Studio Notes 2"].tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 10), "one notebook left: the bar goes")
        XCTAssertTrue(title(app).hasPrefix("Physics II 3"))
        XCTAssertTrue(ribbon.exists)

        // Two tabs wait in the library, and a notebook opened from the shelf joins them.
        app.buttons["editor.title"].tap()
        app.buttons["Open Another Notebook in a Tab…"].firstMatch.tap()
        pick("Studio Notes 2", in: app)
        XCTAssertTrue(studioTab.waitForExistence(timeout: 10))
        app.buttons["editor.back"].tap()
        let biology = app.buttons["notebook.Cell Biology 1"]
        XCTAssertTrue(biology.waitForExistence(timeout: 15), "back in the library")
        sleep(1)
        biology.tap()
        let biologyTab = app.buttons["tabs.tab.Cell Biology 1"]
        XCTAssertTrue(biologyTab.waitForExistence(timeout: 15), "the tabs are still there, with the notebook just opened among them")
        XCTAssertTrue(biologyTab.isSelected)
        XCTAssertTrue(physicsTab.exists)
        XCTAssertTrue(studioTab.exists)
        attach(app, "tabs-after-library")

        // Stopped and opened again, the window comes back with its tabs.
        physicsTab.tap()
        wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'Physics II 3'"), evaluatedWith: app.buttons["editor.title"])], timeout: 10)
        XCUIDevice.shared.press(.home)
        app.terminate()
        app = launch([])
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 30), "the notebook reopens")
        XCTAssertTrue(app.buttons["tabs.tab.Physics II 3"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["tabs.tab.Physics II 3"].isSelected)
        XCTAssertTrue(app.buttons["tabs.tab.Cell Biology 1"].exists)
        XCTAssertTrue(app.buttons["tabs.tab.Studio Notes 2"].exists)
        XCTAssertTrue(title(app).hasPrefix("Physics II 3"))

        // In focus mode the bar goes with the rest of the chrome, and comes back with it.
        app.chooseFromMore("Focus Mode", in: "View")
        XCTAssertTrue(app.buttons["tabs.add"].waitForNonExistence(timeout: 5))
        attach(app, "tabs-focus")
        app.buttons["editor.focus.exit"].tap()
        XCTAssertTrue(app.buttons["tabs.add"].waitForExistence(timeout: 5))
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["notebook.Cell Biology 1"].waitForExistence(timeout: 15))
    }

    func testTabsAreMovedAlongTheBarOpenedBesideAndClosedTogether() throws {
        XCUIDevice.shared.orientation = .portrait
        var app = launch(["-resetStorage", "-seedLibrary", "4"])
        let studio = app.buttons["notebook.Studio Notes 2"]
        XCTAssertTrue(studio.waitForExistence(timeout: 30))
        studio.tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 20))
        app.buttons["editor.title"].tap()
        app.buttons["Open Another Notebook in a Tab…"].firstMatch.tap()
        pick("Physics II 3", in: app)
        XCTAssertTrue(app.buttons["tabs.add"].waitForExistence(timeout: 10))
        app.buttons["tabs.add"].tap()
        pick("Recipes 4", in: app)
        var studioTab = app.buttons["tabs.tab.Studio Notes 2"], physicsTab = app.buttons["tabs.tab.Physics II 3"], recipesTab = app.buttons["tabs.tab.Recipes 4"]
        XCTAssertTrue(recipesTab.waitForExistence(timeout: 10))
        expect(studioTab, before: physicsTab, "tabs stand in the order they were opened")
        expect(physicsTab, before: recipesTab, "tabs stand in the order they were opened")

        // Held, a tab offers the ways it can go; the first has nowhere to its left.
        studioTab.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Move Right"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Move Left"].exists, "the first tab has nowhere to its left")
        XCTAssertTrue(app.buttons["Close Other Tabs"].exists)
        XCTAssertTrue(app.buttons["Open Beside"].exists)
        attach(app, "tab-menu")
        app.buttons["Move Right"].tap()
        expect(physicsTab, before: studioTab, "Move Right changes places with the tab to the right")
        expect(studioTab, before: recipesTab, "and with no other")
        XCTAssertTrue(recipesTab.isSelected, "moving a tab leaves the one on show alone")

        // Dragged onto an earlier tab, a tab lands before it.
        recipesTab.press(forDuration: 1.0, thenDragTo: physicsTab, withVelocity: 200, thenHoldForDuration: 0.5)
        expect(recipesTab, before: physicsTab, "a tab dragged onto the first one takes its place")
        expect(physicsTab, before: studioTab, "and the rest make room in their order")
        XCTAssertTrue(recipesTab.isSelected)
        attach(app, "tabs-reordered")

        // Stopped and opened again, the tabs are in the order they were left in.
        XCUIDevice.shared.press(.home)
        app.terminate()
        app = launch([])
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 30), "the notebook reopens")
        studioTab = app.buttons["tabs.tab.Studio Notes 2"]
        physicsTab = app.buttons["tabs.tab.Physics II 3"]
        recipesTab = app.buttons["tabs.tab.Recipes 4"]
        XCTAssertTrue(recipesTab.waitForExistence(timeout: 10))
        expect(recipesTab, before: physicsTab, "the order of the tabs is remembered")
        expect(physicsTab, before: studioTab, "the order of the tabs is remembered")
        XCTAssertTrue(recipesTab.isSelected)

        // The tab on show moves beside with what was written in it, and its undo history.
        let canvases = app.descendants(matching: .any).matching(identifier: "page.canvas.1")
        XCTAssertTrue(canvases.firstMatch.waitForExistence(timeout: 10))
        canvases.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: canvases.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)), withVelocity: 400, thenHoldForDuration: 0.05)
        wait(for: [expectation(for: NSPredicate(format: "value == '1 stroke'"), evaluatedWith: canvases.firstMatch)], timeout: 5)
        choose("Open Beside", for: recipesTab, in: app)
        let closePane = app.buttons["editor.close.pane"]
        XCTAssertTrue(closePane.waitForExistence(timeout: 20), "the notebook has a pane of its own")
        XCTAssertTrue(recipesTab.waitForNonExistence(timeout: 5), "and has left the bar")
        XCTAssertTrue(physicsTab.isSelected, "the tab that took its place is on show")
        let titles = app.buttons.matching(identifier: "editor.title")
        wait(for: [expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: titles)], timeout: 10)
        wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'Physics II 3'"), evaluatedWith: titles.element(boundBy: 0))], timeout: 10)
        wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'Recipes 4'"), evaluatedWith: titles.element(boundBy: 1))], timeout: 10)
        wait(for: [expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: canvases)], timeout: 20)
        wait(for: [expectation(for: NSPredicate(format: "value == '1 stroke'"), evaluatedWith: canvases.element(boundBy: 1))], timeout: 10)
        let undo = app.buttons.matching(identifier: "editor.undo")
        XCTAssertTrue(undo.element(boundBy: 1).isEnabled, "it brings its undo history with it")
        undo.element(boundBy: 1).tap()
        wait(for: [expectation(for: NSPredicate(format: "value == 'Empty'"), evaluatedWith: canvases.element(boundBy: 1))], timeout: 5)
        sleep(1)
        attach(app, "tab-beside")

        // With a notebook beside already, a tab has nowhere beside to go.
        studioTab.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Close Other Tabs"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Open Beside"].exists, "one notebook beside is all a window has room for")
        XCTAssertFalse(app.buttons["Move Right"].exists, "the last tab has nowhere to its right")

        // Close Other Tabs from a tab behind the bar: the one on show closes too, and the bar goes.
        app.buttons["Close Other Tabs"].tap()
        XCTAssertTrue(app.buttons["tabs.add"].waitForNonExistence(timeout: 10), "one notebook left: the bar goes")
        wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'Studio Notes 2'"), evaluatedWith: titles.element(boundBy: 0))], timeout: 10)
        XCTAssertTrue(closePane.exists, "the notebook beside isn't a tab, and stays")
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["notebook.Studio Notes 2"].waitForExistence(timeout: 30), "going back to the library closes everything")
    }
}
