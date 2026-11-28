import XCTest

/// The tool tray at the foot of the editor: a pen is taken up with one tap and opened with a second, the eraser and
/// the lasso stand beside the pens, and the shortcuts are chosen from the tray's own menu.
@MainActor
final class ToolTrayUITests: XCTestCase {
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

    private func waitUntilSelected(_ element: XCUIElement) {
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: element)], timeout: 5)
    }

    /// The tray and what opens from it, at night and at an accessibility text size.
    func testTheTrayAndItsOptionsAtNightAndInLargeText() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        let modes: [(name: String, appearance: XCUIDevice.Appearance, size: String?, checks: XCUIAccessibilityAuditType)] = [
            ("dark", .dark, nil, .all),
            ("large", .light, "UICTContentSizeCategoryAccessibilityL", [.dynamicType, .textClipped, .contrast]),
            ("largest", .light, "UICTContentSizeCategoryAccessibilityXXXL", [.dynamicType, .textClipped])]
        for mode in modes {
            XCUIDevice.shared.appearance = mode.appearance
            let app = XCUIApplication()
            app.launchArguments = ["-storageRoot", "tools", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput", "-freshToolPresets",
                                   "-fakePencilSqueeze", "-appearance", mode.appearance == .dark ? "dark" : "light"]
                + (mode.size.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
            app.launch()
            let notebook = app.buttons["notebook.Studio Notes 2"]
            // At the largest size the notebooks start below the fold, where XCUITest doesn't see them.
            for _ in 0..<5 where !notebook.waitForExistence(timeout: 8) { app.swipeUp() }
            XCTAssertTrue(notebook.waitForExistence(timeout: 30))
            notebook.tap()
            let black = app.buttons["editor.tools.1"], eraser = app.buttons["editor.tools.eraser"]
            XCTAssertTrue(black.waitForExistence(timeout: 20))
            let canvas = app.element("page.canvas.1"), tray = app.element("editor.tools.tray"), large = mode.size != nil
            func close(_ element: XCUIElement) {
                canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()
                XCTAssertTrue(element.waitForNonExistence(timeout: 5))
            }
            // An element's own swipe finds no visible frame in a popover on a screen on its side; the window's points do.
            let window = app.windows.firstMatch
            func scrollUp(from element: XCUIElement) {
                let x = element.frame.midX / window.frame.width
                window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: element.frame.midY / window.frame.height))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.04)))
            }
            // Options that don't fit scroll; they are dragged from the roll, then from the switch, never from a bar.
            func reachEnd(of last: XCUIElement) -> Bool {
                for _ in 0..<4 where last.exists && !last.isHittable {
                    if app.element("editor.tools.pen.kind").isHittable { scrollUp(from: app.element("editor.tools.pen.kind")) }
                    else if app.switches["editor.tools.pen.even"].isHittable { scrollUp(from: app.switches["editor.tools.pen.even"]) }
                    else { break }
                    sleep(1)
                }
                return last.isHittable
            }
            attach(app, "\(mode.name)-tray")
            // The iPadOS 27 simulator can ignore the switch; the app's own setting holds, and this says so if it ever doesn't.
            XCTAssertEqual(isDark(app.screenshot()), mode.appearance == .dark, "the desk is \(mode.name == "dark" ? "dark" : "light")")
            try audit(app, mode.checks, screen: "\(mode.name) tool tray", largeText: large, bar: tray)

            black.tap()
            let remove = app.buttons["editor.tools.pen.remove"]
            XCTAssertTrue(remove.waitForExistence(timeout: 5))
            XCTAssertTrue(remove.isHittable, "the options fit on the screen")
            app.buttons["Fountain Pen"].tap()
            attach(app, "\(mode.name)-pen-options")
            try audit(app, mode.checks, screen: "\(mode.name) pen options", popover: true, largeText: large)
            // The highlighter's options are the tallest: they hold the Even Colour switch as well.
            app.buttons["Highlighter"].tap()
            XCTAssertTrue(app.switches["editor.tools.pen.even"].waitForExistence(timeout: 5))
            XCTAssertTrue(reachEnd(of: remove), "the highlighter's options reach their last row")
            attach(app, "\(mode.name)-highlighter-options")
            try audit(app, mode.checks, screen: "\(mode.name) highlighter options", popover: true, largeText: large)
            close(remove)

            eraser.tap()
            eraser.tap()
            let part = app.buttons["Part of a Stroke"]
            XCTAssertTrue(part.waitForExistence(timeout: 5))
            part.tap()
            XCTAssertTrue(app.sliders["editor.tools.eraser.width"].waitForExistence(timeout: 5))
            attach(app, "\(mode.name)-eraser-options")
            try audit(app, mode.checks, screen: "\(mode.name) eraser options", popover: true, largeText: large)
            close(part)

            app.buttons["editor.tools.customise"].tap()
            let zoom = app.buttons["editor.tools.shortcut.zoomWindow"]
            XCTAssertTrue(zoom.waitForExistence(timeout: 5))
            XCTAssertTrue(zoom.isHittable, "every tag fits on the screen")
            attach(app, "\(mode.name)-shortcut-tags")
            try audit(app, mode.checks, screen: "\(mode.name) shortcut tags", popover: true, largeText: large)
            close(zoom)

            canvas.twoFingerTap()
            let dish = app.element("editor.dish")
            XCTAssertTrue(dish.waitForExistence(timeout: 5))
            sleep(1)
            attach(app, "\(mode.name)-dish")
            try audit(app, mode.checks, screen: "\(mode.name) ink dish", largeText: large)
            app.buttons["editor.dish.eraser"].tap()
            XCTAssertTrue(dish.waitForNonExistence(timeout: 5))

            // On its side the screen is at its shortest: what doesn't fit scrolls, and nothing is cut short.
            if mode.name == "largest" {
                XCUIDevice.shared.orientation = .landscapeLeft
                defer { XCUIDevice.shared.orientation = .portrait }
                wait(for: [expectation(for: NSPredicate { _, _ in window.frame.width > window.frame.height }, evaluatedWith: nil)], timeout: 10)
                sleep(2)
                black.tap()
                black.tap()
                XCTAssertTrue(remove.waitForExistence(timeout: 5))
                sleep(2)
                XCTAssertTrue(reachEnd(of: remove), "the end of the options is reached on a screen on its side")
                try audit(app, mode.checks, screen: "largest pen options on its side", popover: true, largeText: true)
                close(remove)
                app.buttons["editor.tools.customise"].tap()
                XCTAssertTrue(app.buttons["editor.tools.shortcut.picture"].waitForExistence(timeout: 5))
                sleep(2)
                try audit(app, mode.checks, screen: "largest shortcut tags on its side", popover: true, largeText: true)
                if !zoom.isHittable { scrollUp(from: app.buttons["editor.tools.shortcut.sticker"]) }
                sleep(2)
                XCTAssertTrue(zoom.isHittable, "the last tag is reached on a screen on its side")
                close(zoom)
            }
            app.terminate()
        }
    }

    /// A pen is made faint from its options, and with Handwriting to Text on, what is written is set as type.
    func testAPenIsMadeFaintAndHandwritingIsSetAsType() throws {
        XCUIDevice.shared.orientation = .portrait
        // The pen's rest, long enough for a slow runner to get from one stroke to the next.
        let rest = 8
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "tools", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput", "-freshToolPresets",
                               "-scriptedInkText", "Hello", "-inkTypingPause", "\(rest)"]
        app.launch()
        let notebook = app.buttons["notebook.Studio Notes 2"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let black = app.buttons["editor.tools.1"], canvas = app.element("page.canvas.1")
        XCTAssertTrue(black.waitForExistence(timeout: 20))
        func close(_ element: XCUIElement) {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()
            XCTAssertTrue(element.waitForNonExistence(timeout: 5))
        }

        // The pen in hand opens; its opacity is a bar of its own under the width.
        XCTAssertEqual(black.value as? String, "Width 2.7")
        black.tap()
        let opacity = app.sliders["editor.tools.pen.opacity"]
        XCTAssertTrue(opacity.waitForExistence(timeout: 5))
        XCTAssertEqual(opacity.value as? String, "100%")
        opacity.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: opacity.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)))
        let faint = try XCTUnwrap(opacity.value as? String)
        XCTAssertNotEqual(faint, "100%", "the knob slides along the wash")
        XCTAssertTrue(faint.hasSuffix("0%") || faint.hasSuffix("5%"), "in steps of a twentieth: \(faint)")
        XCTAssertEqual(black.value as? String, "Width 2.7, opacity \(faint)")
        attach(app, "pen-opacity")
        try audit(app, screen: "pen options with opacity", popover: true)
        // Another colour is as faint as the last, and is still told as the chosen one.
        app.buttons["Blue"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label == 'Pen, Blue'"), evaluatedWith: black)], timeout: 5)
        XCTAssertEqual(opacity.value as? String, faint)
        XCTAssertTrue(app.buttons["Blue"].isSelected)
        close(opacity)

        // Handwriting to Text is tied on from the tags, and turned on where it then stands.
        app.buttons["editor.tools.customise"].tap()
        let tag = app.buttons["editor.tools.shortcut.typing"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        tag.tap()
        XCTAssertTrue(tag.isSelected)
        close(tag)
        let typing = app.buttons["editor.tools.extra.typing"]
        XCTAssertTrue(typing.waitForExistence(timeout: 5))
        XCTAssertFalse(typing.isSelected)

        // Points on the window: one taken from the canvas is looked up again before and during each stroke.
        let page = canvas.frame, window = app.coordinate(withNormalizedOffset: .zero)
        func draw(atHeight y: CGFloat) {
            let point = { (x: CGFloat) in window.withOffset(CGVector(dx: page.minX + page.width * x, dy: page.minY + page.height * y)) }
            point(0.2).press(forDuration: 0.05, thenDragTo: point(0.5), withVelocity: 600, thenHoldForDuration: 0.05)
        }

        // Off, writing stays ink.
        draw(atHeight: 0.6)
        XCTAssertEqual(strokeCount(canvas), 1)
        typing.tap()
        waitUntilSelected(typing)
        let writing = Date.now
        draw(atHeight: 0.3)
        draw(atHeight: 0.34)
        let wrote = Date.now.timeIntervalSince(writing).formatted(.number.precision(.fractionLength(1)))
        XCTAssertEqual(strokeCount(canvas), 3, "nothing is read while the writing goes on (both strokes took \(wrote) s)")
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Hello'")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: TimeInterval(rest + 20)), "the handwriting is set as type once the pen has rested")
        XCTAssertEqual(strokeCount(canvas), 1, "it takes the handwriting's place; ink from before is left")
        XCTAssertEqual(text.frame.minY, canvas.frame.minY + canvas.frame.height * 0.3, accuracy: 60, "where the handwriting was")
        attach(app, "handwriting-as-type")

        // One undo gives the handwriting back, and it stays ink.
        app.buttons.matching(identifier: "editor.undo").firstMatch.tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 5))
        XCTAssertEqual(strokeCount(canvas), 3)
        sleep(UInt32(rest + 2))
        XCTAssertEqual(strokeCount(canvas), 3, "what Undo gave back is not read again")
        typing.tap()
        XCTAssertFalse(typing.isSelected)
    }

    /// The highlighter's options hold one switch, Even Colour, for every highlighter; no other pen's options show it.
    func testTheHighlightersOptionsHoldTheEvenColourSwitch() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "tools", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput", "-freshToolPresets"]
        app.launch()
        let notebook = app.buttons["notebook.Studio Notes 2"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let black = app.buttons["editor.tools.1"], highlighter = app.buttons["editor.tools.4"]
        XCTAssertTrue(highlighter.waitForExistence(timeout: 20))
        let canvas = app.element("page.canvas.1"), even = app.switches["editor.tools.pen.even"], remove = app.buttons["editor.tools.pen.remove"]
        func close(_ element: XCUIElement) {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()
            XCTAssertTrue(element.waitForNonExistence(timeout: 5))
        }

        highlighter.tap()
        waitUntilSelected(highlighter)
        highlighter.tap()
        XCTAssertTrue(even.waitForExistence(timeout: 5), "the highlighter's options hold the switch")
        XCTAssertTrue(even.label.hasPrefix("Even Colour"), even.label)
        XCTAssertEqual(even.value as? String, "0", "it starts off")
        XCTAssertTrue(remove.isHittable, "and the last row is still within reach")
        even.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(even.value as? String, "1")
        attach(app, "highlighter-even-colour")
        try audit(app, screen: "highlighter options", popover: true)

        // It is one setting, not the highlighter's own: it stays on when the options are closed and opened again.
        close(even)
        highlighter.tap()
        XCTAssertTrue(even.waitForExistence(timeout: 5))
        XCTAssertEqual(even.value as? String, "1")

        // It comes and goes with the kind chosen on the roll, and keeps its place.
        app.buttons["Pen"].tap()
        XCTAssertTrue(even.waitForNonExistence(timeout: 5), "a pen's options have no such switch")
        app.buttons["Highlighter"].tap()
        XCTAssertTrue(even.waitForExistence(timeout: 5))
        XCTAssertEqual(even.value as? String, "1")
        close(even)

        black.tap()
        waitUntilSelected(black)
        black.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertFalse(even.exists, "a pen's options have no such switch")
    }

    /// A squeeze of the Pencil brings the ink dish to its tip; a UI test taps with two fingers instead.
    func testASqueezeBringsTheInkDishToThePencilsTip() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "tools", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "pencilOnly", "-freshToolPresets",
                               "-fakePencilSqueeze"]
        app.launch()
        let notebook = app.buttons["notebook.Studio Notes 2"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let black = app.buttons["editor.tools.1"], cobalt = app.buttons["editor.tools.2"], eraser = app.buttons["editor.tools.eraser"]
        XCTAssertTrue(black.waitForExistence(timeout: 20))
        let canvas = app.element("page.canvas.1"), window = app.windows.firstMatch, dish = app.element("editor.dish")
        XCTAssertFalse(dish.exists)

        canvas.twoFingerTap()
        XCTAssertTrue(dish.waitForExistence(timeout: 5), "the dish comes out")
        sleep(1)
        XCTAssertTrue(window.frame.contains(dish.frame), "all of it is on the screen")
        XCTAssertEqual(dish.frame.midX, canvas.frame.midX, accuracy: 30, "where the Pencil was")
        XCTAssertTrue(app.buttons["editor.dish.1"].isSelected, "the pen in hand is marked")
        XCTAssertEqual(app.buttons["editor.dish.2"].label, "Pen, Blue")
        XCTAssertTrue(app.buttons["editor.dish.4"].exists)
        XCTAssertFalse(app.buttons["editor.dish.5"].exists, "a well for each pen on the shelf")
        XCTAssertFalse(app.buttons["editor.dish.undo"].isEnabled, "nothing to undo yet")
        attach(app, "dish")
        try audit(app, screen: "ink dish")

        // A well takes its pen up and puts the dish away.
        app.buttons["editor.dish.2"].tap()
        XCTAssertTrue(dish.waitForNonExistence(timeout: 5))
        waitUntilSelected(cobalt)
        canvas.twoFingerTap()
        XCTAssertTrue(dish.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editor.dish.2"].isSelected)
        app.buttons["editor.dish.eraser"].tap()
        XCTAssertTrue(dish.waitForNonExistence(timeout: 5))
        waitUntilSelected(eraser)

        // A tap off it puts it away with nothing changed; so does a second squeeze.
        canvas.twoFingerTap()
        XCTAssertTrue(dish.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editor.dish.eraser"].isSelected)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(dish.waitForNonExistence(timeout: 5))
        XCTAssertTrue(eraser.isSelected)

        // It comes out with the tray put away too.
        app.buttons["Hide Tools"].firstMatch.tap()
        XCTAssertTrue(app.element("editor.tools.tray").waitForNonExistence(timeout: 5))
        canvas.twoFingerTap()
        XCTAssertTrue(dish.waitForExistence(timeout: 5))
        app.buttons["editor.dish.1"].tap()
        XCTAssertTrue(dish.waitForNonExistence(timeout: 5))
        app.buttons["Show Tools"].firstMatch.tap()
        XCTAssertTrue(black.waitForExistence(timeout: 5))
        XCTAssertTrue(black.isSelected)
    }

    func testThePensTheEraserAndTheShortcutsStandInTheTray() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "tools", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput", "-freshToolPresets"]
        app.launch()
        let notebook = app.buttons["notebook.Studio Notes 2"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(app.buttons["editor.ribbon"].waitForExistence(timeout: 20))

        // The tray starts with the app's own four inks, the first of them in hand.
        let black = app.buttons["editor.tools.1"], cobalt = app.buttons["editor.tools.2"], highlighter = app.buttons["editor.tools.4"]
        let eraser = app.buttons["editor.tools.eraser"], lasso = app.buttons["editor.tools.lasso"], add = app.buttons["editor.tools.add"]
        XCTAssertTrue(cobalt.waitForExistence(timeout: 10), "the pens are in the tray")
        XCTAssertTrue(black.isSelected)
        XCTAssertEqual(cobalt.label, "Pen, Blue")
        XCTAssertEqual(highlighter.label, "Highlighter, Mustard")
        XCTAssertFalse(app.buttons["editor.tools.5"].exists)
        // It takes nothing from the page's width, and is one slim board at the foot of the window.
        let canvas = app.element("page.canvas.1"), window = app.windows.firstMatch, tray = app.element("editor.tools.tray")
        XCTAssertEqual(canvas.frame.midX, window.frame.midX, accuracy: 1)
        XCTAssertEqual(tray.frame.midX, window.frame.midX, accuracy: 1)
        XCTAssertLessThanOrEqual(tray.frame.height, 50)
        XCTAssertGreaterThan(tray.frame.minY, window.frame.maxY - 90)
        XCTAssertTrue(app.buttons["editor.tools.extra.picture"].isHittable, "a picture is one tap away")
        XCTAssertTrue(app.buttons["editor.tools.extra.text"].isHittable)
        attach(app, "tray")

        cobalt.tap()
        waitUntilSelected(cobalt)
        XCTAssertFalse(black.isSelected)
        highlighter.tap()
        waitUntilSelected(highlighter)
        try audit(app, screen: "tool tray", bar: tray)

        // Writing with it works, and the eraser takes the stroke off again.
        let left = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)), right = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3))
        left.press(forDuration: 0.05, thenDragTo: right, withVelocity: 400, thenHoldForDuration: 0.05)
        XCTAssertEqual(strokeCount(canvas), 1)
        eraser.tap()
        waitUntilSelected(eraser)
        XCTAssertEqual(eraser.value as? String, "Whole Strokes")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)), withVelocity: 400, thenHoldForDuration: 0.05)
        wait(for: [expectation(for: NSPredicate(format: "value == 'Empty'"), evaluatedWith: canvas)], timeout: 5)

        // Tapped again, the eraser opens: it can take part of a stroke, as wide as it is set.
        eraser.tap()
        let part = app.buttons["Part of a Stroke"]
        XCTAssertTrue(part.waitForExistence(timeout: 5))
        part.tap()
        XCTAssertTrue(app.sliders["editor.tools.eraser.width"].waitForExistence(timeout: 5))
        attach(app, "eraser-options")
        try audit(app, screen: "eraser options", popover: true)
        app.buttons["Whole Strokes"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2)).tap()
        XCTAssertTrue(part.waitForNonExistence(timeout: 5))
        lasso.tap()
        waitUntilSelected(lasso)

        // Touch and hold takes a pen up and opens it in one go.
        let remove = app.buttons["editor.tools.pen.remove"]
        black.press(forDuration: 0.8)
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "a held pen opens")
        XCTAssertTrue(black.isSelected)
        XCTAssertFalse(app.buttons["editor.tools.pen.left"].isEnabled, "the first pen has nowhere to go on the left")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2)).tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))

        // Tapped while in hand, a pen opens: its colour and its width are changed where it stands.
        cobalt.tap()
        waitUntilSelected(cobalt)
        cobalt.tap()
        let green = app.buttons["Green"]
        XCTAssertTrue(green.waitForExistence(timeout: 5), "the pen's options")
        XCTAssertTrue(app.buttons["Blue"].isSelected)
        green.tap()
        wait(for: [expectation(for: NSPredicate(format: "label == 'Pen, Green'"), evaluatedWith: cobalt)], timeout: 5)
        // Its kind is chosen from the tools standing in the roll.
        let pencil = app.buttons["Pencil"], plain = app.buttons["Pen"]
        XCTAssertTrue(plain.isSelected)
        pencil.tap()
        wait(for: [expectation(for: NSPredicate(format: "label == 'Pencil, Green'"), evaluatedWith: cobalt)], timeout: 5)
        XCTAssertTrue(pencil.isSelected)
        attach(app, "pen-kind")
        plain.tap()
        wait(for: [expectation(for: NSPredicate(format: "label == 'Pen, Green'"), evaluatedWith: cobalt)], timeout: 5)
        let width = app.sliders["editor.tools.pen.width"]
        let thin = width.value as? String
        width.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: width.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertNotEqual(width.value as? String, thin, "the knob slides along the strip")
        attach(app, "pen-options")
        try audit(app, screen: "pen options", popover: true)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2)).tap()
        XCTAssertTrue(green.waitForNonExistence(timeout: 5))
        XCTAssertEqual(strokeCount(canvas), 0, "the tap that closed the options left no mark")

        // A new pen is like the one in hand, in a colour of its own, and opens so that can be changed. It can be taken off again.
        add.tap()
        let fifth = app.buttons["editor.tools.5"]
        XCTAssertTrue(fifth.waitForExistence(timeout: 5))
        XCTAssertEqual(fifth.label, "Pen, Grey")
        XCTAssertTrue(fifth.isSelected)
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "the new pen opens")
        // From its options it is moved along the tray, and taken off it.
        XCTAssertFalse(app.buttons["editor.tools.pen.right"].isEnabled, "the last pen has nowhere to go on the right")
        app.buttons["editor.tools.pen.left"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label == 'Pen, Grey'"), evaluatedWith: highlighter)], timeout: 5)
        attach(app, "pen-moved")
        app.buttons["editor.tools.pen.right"].tap()
        wait(for: [expectation(for: NSPredicate(format: "label == 'Pen, Grey'"), evaluatedWith: fifth)], timeout: 5)
        remove.tap()
        XCTAssertTrue(fifth.waitForNonExistence(timeout: 5))
        waitUntilSelected(highlighter)

        // The shortcuts beside the tools are tags, tied on and taken off from the end of the tray.
        XCTAssertFalse(app.buttons["editor.tools.extra.ruler"].exists)
        app.buttons["editor.tools.customise"].tap()
        let ruler = app.buttons["editor.tools.shortcut.ruler"], text = app.buttons["editor.tools.shortcut.text"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 5))
        XCTAssertFalse(ruler.isSelected)
        XCTAssertTrue(text.isSelected)
        // The tags stay open, so more than one can be changed.
        ruler.tap()
        text.tap()
        XCTAssertTrue(ruler.isSelected)
        attach(app, "customise")
        try audit(app, screen: "shortcut tags", popover: true)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2)).tap()
        XCTAssertTrue(ruler.waitForNonExistence(timeout: 5))
        let rulerButton = app.buttons["editor.tools.extra.ruler"]
        XCTAssertTrue(rulerButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.tools.extra.text"].exists)
        rulerButton.tap()
        waitUntilSelected(rulerButton)
        rulerButton.tap()
        attach(app, "tray-customised")

        // The tools are put away from the bar, and brought back.
        app.buttons["Hide Tools"].firstMatch.tap()
        XCTAssertTrue(tray.waitForNonExistence(timeout: 5))
        attach(app, "tray-hidden")
        app.buttons["Show Tools"].firstMatch.tap()
        XCTAssertTrue(cobalt.waitForExistence(timeout: 5))
    }
}
