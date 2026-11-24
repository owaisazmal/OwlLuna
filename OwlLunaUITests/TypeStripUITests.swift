import XCTest

/// The strip of type controls that stands on the keyboard while a text box is typed in.
@MainActor
final class TypeStripUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens a seeded notebook, adds a text box and hands back its editor, being typed in.
    private func typeInANewBox(_ app: XCUIApplication, storage: String) -> XCUIElement {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-storageRoot", storage, "-resetStorage", "-seedLibrary", "3", "-drawingInput", "pencilOnly", "-appearance", "light"]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(app.descendants(matching: .any)["page.canvas.1"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.element("editor.tools.tray").waitForExistence(timeout: 10))
        app.buttons["Add"].firstMatch.tap()
        app.buttons["Text Box"].firstMatch.tap()
        let editor = app.textViews["page.text.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        return editor
    }

    /// Types where the caret is. It fails if the box has lost the keyboard.
    private func type(_ text: String, in editor: XCUIElement, expecting whole: String, _ why: String) {
        editor.typeText(text)
        XCTAssertEqual(editor.value as? String, whole, why)
    }

    func testTheStripStylesABoxWhileItIsTypedIn() throws {
        let app = XCUIApplication()
        let editor = typeInANewBox(app, storage: "typestrip")
        let strip = app.element("editor.type.strip"), tray = app.element("editor.tools.tray")
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "typing in a box brings the strip")
        XCTAssertTrue(tray.waitForNonExistence(timeout: 5), "where the tool tray was")
        type("Oats", in: editor, expecting: "Oats", "the box is typed in")
        strip.waitUntilStill()
        XCTAssertLessThanOrEqual(editor.frame.maxY, strip.frame.minY, "the words stay clear of the strip")
        XCTAssertLessThan(strip.frame.height, 60, "which is one row of controls")
        XCTAssertEqual(strip.frame.maxY, app.keyboards.firstMatch.frame.minY, accuracy: 70, "standing on the keyboard")
        XCTAssertEqual(strip.frame.width, app.windows.firstMatch.frame.width, accuracy: 20, "from one side of the pane to the other")
        attach(app, "type-strip")

        let size = app.element("editor.type.size"), plus = app.buttons["editor.type.size.plus"]
        XCTAssertEqual(size.value as? String, "17 pt")
        plus.tap()
        XCTAssertEqual(size.value as? String, "18 pt", "plus makes the type a point larger")
        type("a", in: editor, expecting: "Oatsa", "a step in size leaves the keyboard with the box")

        let bold = app.buttons["editor.type.bold"]
        XCTAssertFalse(bold.isSelected)
        bold.tap()
        XCTAssertTrue(bold.isSelected, "Bold shows as on")
        type("b", in: editor, expecting: "Oatsab", "and so does Bold")
        let undo = app.buttons["editor.undo"]
        XCTAssertTrue(undo.isEnabled, "a change of style from the strip can be undone from the bar")
        undo.tap()
        XCTAssertFalse(bold.isSelected)
        XCTAssertEqual(size.value as? String, "18 pt", "one step at a time")
        type("c", in: editor, expecting: "Oatsabc", "undoing the style keeps what was typed")

        strip.waitUntilStill()
        let place = strip.frame
        app.buttons["editor.type.face"].tap()
        let serif = app.buttons["Serif"].firstMatch
        XCTAssertTrue(serif.waitForExistence(timeout: 5), "the typeface opens a card of the faces")
        XCTAssertEqual(strip.frame, place, "the strip keeps its place while its card is open")
        attach(app, "type-strip-typeface")
        serif.tap()
        XCTAssertTrue(serif.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["editor.type.face"].value as? String, "Serif")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard comes back when the card has gone")
        type("d", in: editor, expecting: "Oatsabcd", "a card leaves the box being typed in")

        app.buttons["editor.type.more"].tap()
        let card = app.element("editor.text.list")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "More opens the Text Style card")
        XCTAssertTrue(app.element("editor.text.face").children(matching: .button)["Serif"].isSelected, "which agrees with the strip")
        attach(app, "type-strip-more")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.2)).tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        type("e", in: editor, expecting: "Oatsabcde", "and so does the whole card")

        app.buttons["editor.arrange.done"].tap()
        XCTAssertTrue(strip.waitForNonExistence(timeout: 5), "Done puts the strip away")
        XCTAssertTrue(tray.waitForExistence(timeout: 5), "and the tools come back")
        XCTAssertTrue(app.staticTexts["Oatsabcde"].waitForExistence(timeout: 5), "with the box as it was typed")
    }

    func testABoxAtTheFootOfAPageIsTypedInClearOfTheStrip() throws {
        let app = XCUIApplication()
        let editor = typeInANewBox(app, storage: "typestrip-foot")
        editor.typeText("Eggs")
        app.buttons["editor.arrange.done"].tap()
        let box = app.staticTexts["Eggs"], canvas = app.element("page.canvas.1"), strip = app.element("editor.type.strip")
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.tap()
        XCTAssertTrue(app.buttons["editor.arrange.done"].waitForExistence(timeout: 5))
        let window = app.coordinate(withNormalizedOffset: .zero), from = box.frame
        window.withOffset(CGVector(dx: from.midX, dy: from.midY))
            .press(forDuration: 0.1, thenDragTo: window.withOffset(CGVector(dx: from.midX, dy: canvas.frame.maxY - 140)), withVelocity: 200, thenHoldForDuration: 0.3)
        XCTAssertGreaterThan(box.frame.midY, app.windows.firstMatch.frame.height * 0.75, "the box is near the foot of the page, where the keyboard will come up")

        box.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "a tap on the selected box types in it")
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        strip.waitUntilStill()
        XCTAssertLessThanOrEqual(editor.frame.maxY, strip.frame.minY, "the page brings the box above the strip")
        attach(app, "type-strip-foot")
        editor.typeText("\nFlour\nMilk\nOats")
        strip.waitUntilStill()
        XCTAssertEqual(editor.value as? String, "Eggs\nFlour\nMilk\nOats")
        XCTAssertLessThanOrEqual(editor.frame.maxY, strip.frame.minY, "and keeps it there as lines are added")
        attach(app, "type-strip-foot-grown")
    }

    /// The strip through Apple's accessibility audit, light and at the default text size.
    func testTheStripPassesTheAccessibilityAudit() throws {
        let app = XCUIApplication()
        let editor = typeInANewBox(app, storage: "typestrip-audit")
        let strip = app.element("editor.type.strip")
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        editor.typeText("Oats")
        strip.waitUntilStill()
        for identifier in ["face", "size.minus", "size.plus", "bold", "italic", "underline", "list", "colour", "more"] {
            let control = app.buttons["editor.type.\(identifier)"]
            XCTAssertTrue(control.exists, identifier)
            XCTAssertFalse(control.label.isEmpty, "\(identifier) is named")
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, identifier)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, identifier)
        }
        attach(app, "type-strip-audit")
        continueAfterFailure = true
        try audit(app, screen: "type strip", bar: app.otherElements["editor.arrange.bar"], pageText: ["Oats", "Text box"])
    }
}
