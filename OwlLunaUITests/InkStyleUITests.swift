import XCTest

/// Issue 56: caught ink takes another colour and a broader or narrower line from its card, and Undo puts each back.
@MainActor
final class InkStyleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-storageRoot", "inkstyle", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput", "-freshToolPresets"] + extra
        app.launch()
        let notebook = app.buttons["notebook.Studio Notes 2"]
        // At the largest text sizes the notebooks start below the fold, where XCUITest doesn't see them.
        for _ in 0..<5 where !notebook.waitForExistence(timeout: 12) { app.swipeUp() }
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))
        canvas.waitUntilStill()
    }

    private var canvas: XCUIElement { app.element("page.canvas.1") }
    private var window: XCUIElement { app.windows.firstMatch }
    /// The ink bar's Done is there while the tray's lasso holds ink; its words are left out at the largest text sizes.
    private var caught: XCUIElement { app.buttons["editor.ink.done"] }
    private var colourRow: XCUIElement { app.buttons["editor.ink.colour"] }
    private var widthRow: XCUIElement { app.buttons["editor.ink.width"] }
    private var lasso: XCUIElement { app.buttons["editor.tools.lasso"] }

    /// A point in the window, in its own points.
    private func point(_ at: CGPoint) -> XCUICoordinate {
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: at.x, dy: at.y))
    }

    private func waitUntilSelected(_ element: XCUIElement) {
        wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: element)], timeout: 5)
    }

    private func waitForValue(_ value: String, of element: XCUIElement, _ message: String) {
        let done = expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
        if XCTWaiter().wait(for: [done], timeout: 8) != .completed {
            XCTFail("\(message): wanted \(value), found \(element.value as? String ?? "nothing")")
        }
    }

    /// A line 120 points long, centred on `centre`, with the pen in hand.
    private func drawLine(at centre: CGPoint) {
        point(CGPoint(x: centre.x - 60, y: centre.y))
            .press(forDuration: 0.05, thenDragTo: point(CGPoint(x: centre.x + 60, y: centre.y + 4)), withVelocity: 300, thenHoldForDuration: 0.1)
    }

    /// With the lasso in hand, a straight drag across the line catches it.
    private func catchLine(at centre: CGPoint) {
        if caught.exists { return }
        point(CGPoint(x: centre.x - 90, y: centre.y - 22))
            .press(forDuration: 0.1, thenDragTo: point(CGPoint(x: centre.x + 90, y: centre.y + 26)), withVelocity: 400, thenHoldForDuration: 0.2)
        XCTAssertTrue(caught.waitForExistence(timeout: 8), "the lasso caught the line")
    }

    /// Catches the line if it was let go, and opens its card with a tap on it.
    private func openCard(at centre: CGPoint) {
        catchLine(at: centre)
        point(CGPoint(x: centre.x, y: centre.y + 2)).tap()
        XCTAssertTrue(colourRow.waitForExistence(timeout: 8), "a tap on the caught line opens its card with Colour on it")
        XCTAssertTrue(widthRow.waitForExistence(timeout: 2))
    }

    /// A tap clear of every card closes them all; it doesn't reach the page, so the line stays caught.
    private func closeCards(clearOf given: [CGRect]) {
        let bounds = window.frame
        let parts = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'editor.ink.colour' OR identifier BEGINSWITH 'editor.ink.width'"))
        let frames = given + parts.allElementsBoundByIndex.map(\.frame) + app.sliders.allElementsBoundByIndex.map(\.frame)
        let spots = [0.2, 0.35, 0.5, 0.65, 0.8].flatMap { y in [0.5, 0.1, 0.9, 0.3, 0.7].map { CGPoint(x: bounds.width * $0, y: bounds.height * y) } }
        let spot = spots.first { spot in !frames.contains { $0.insetBy(dx: -56, dy: -56).contains(spot) } } ?? CGPoint(x: bounds.midX, y: bounds.height * 0.9)
        // The mixing strips close on their own first, as a pen's do; a drawer closes the card with it.
        for _ in 0..<3 where colourRow.exists {
            point(spot).tap()
            _ = colourRow.waitForNonExistence(timeout: 3)
        }
        XCTAssertTrue(colourRow.waitForNonExistence(timeout: 5), "the cards closed")
    }

    private func points(_ element: XCUIElement) -> [Double] {
        (element.value as? String ?? "").split { !$0.isNumber && $0 != "." }.compactMap { Double($0) }
    }

    private var cardFrame: CGRect { colourRow.frame.union(app.buttons["editor.ink.delete"].frame) }

    private func expectHittable(_ element: XCUIElement, _ name: String) {
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, "\(name) is at least 44 points wide")
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) is at least 44 points tall")
    }

    // MARK: Colour, width and Undo

    func testCaughtInkTakesAColourAndAWidthAndUndoPutsThemBack() throws {
        launch(["-appearance", "light"])
        let line = CGPoint(x: window.frame.width * 0.5, y: window.frame.height * 0.32)
        drawLine(at: line)
        lasso.tap()
        waitUntilSelected(lasso)
        openCard(at: line)
        let black = colourRow.value as? String, first = widthRow.value as? String
        XCTAssertEqual(black, "Black", "the Colour row names the line's colour")
        let start = points(widthRow)
        XCTAssertEqual(start.count, 1, "one line has one width: \(first ?? "")")
        XCTAssertTrue(first?.hasSuffix(" pt") == true)
        XCTAssertLessThan(colourRow.frame.maxY, app.buttons["editor.ink.cut"].frame.minY, "Colour and Width come before Cut")
        attach("card-light")

        // Colour: a tap gives the ink that colour and leaves both cards open, so another can be tried.
        colourRow.tap()
        let red = app.buttons["editor.ink.colour.C9452F"], ink = app.buttons["editor.ink.colour.1B2230"]
        XCTAssertTrue(red.waitForExistence(timeout: 8), "the colours open beside the card")
        XCTAssertTrue(ink.isSelected, "the ink's colour is ringed")
        XCTAssertEqual(red.label, "Red")
        attach("colour-drawer-light")
        red.tap()
        waitForValue("Red", of: colourRow, "the Colour row follows")
        waitUntilSelected(red)
        XCTAssertFalse(ink.isSelected)
        XCTAssertTrue(red.isHittable, "the colours are still open")

        // Custom Colour opens the mixing strips; a step of the hue strip is one colour.
        let custom = app.buttons["editor.ink.colour.custom"]
        custom.tap()
        let hue = app.sliders["Hue"]
        XCTAssertTrue(hue.waitForExistence(timeout: 8), "the mixing strips open")
        attach("mixing-strips-light")
        // The ink follows the hue strip while it slides.
        hue.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: hue.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)), withVelocity: 150, thenHoldForDuration: 0.2)
        let mixed = expectation(for: NSPredicate(format: "value != 'Red'"), evaluatedWith: colourRow)
        wait(for: [mixed], timeout: 8)
        let third = colourRow.value as? String ?? ""
        XCTAssertTrue(custom.isSelected, "a mixed colour rings Custom Colour")
        closeCards(clearOf: [cardFrame, hue.frame, red.frame, custom.frame])

        // Width: the knob slides from as the ink was towards broader, and the line follows it.
        openCard(at: line)
        waitForValue(third, of: colourRow, "the mixed colour stayed")
        widthRow.tap()
        let strip = app.element("editor.ink.width.strip"), readout = app.staticTexts["editor.ink.width.value"]
        let plus = app.buttons["editor.ink.width.plus"], minus = app.buttons["editor.ink.width.minus"]
        XCTAssertTrue(strip.waitForExistence(timeout: 8), "the strip opens beside the card")
        XCTAssertEqual(readout.value as? String, first, "the readout starts at the ink's width")
        attach("width-drawer-light")
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.39, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5)), withVelocity: 200, thenHoldForDuration: 0.2)
        let slid = points(readout)
        XCTAssertGreaterThan(slid.first ?? 0, (start.first ?? 0) * 1.3, "sliding towards broader makes the line broader")
        waitForValue(readout.value as? String ?? "", of: widthRow, "the Width row follows the strip")
        attach("width-slid-light")

        // A plate is a tenth at a time; held, it repeats.
        let slidName = readout.value as? String ?? ""
        plus.tap()
        let stepped = points(readout).first ?? 0, steppedName = readout.value as? String ?? ""
        XCTAssertEqual(stepped, (slid.first ?? 0) * 1.1, accuracy: 0.15, "one tap of plus is a tenth broader")
        plus.press(forDuration: 1.6)
        let held = points(readout).first ?? 0
        XCTAssertGreaterThan(held, stepped * 1.15, "holding plus repeats")
        XCTAssertTrue(minus.isEnabled)
        let heldName = readout.value as? String ?? ""
        waitForValue(heldName, of: widthRow, "the Width row follows the hold once it is let go")
        closeCards(clearOf: [cardFrame, strip.frame, plus.frame])

        // Undo, a step at a time: the hold, the tap, the slide, the mixed colour, then red.
        let undo = app.buttons["editor.ink.undo"]
        func undoOnce() {
            catchLine(at: line)
            XCTAssertTrue(undo.waitForExistence(timeout: 5))
            undo.tap()
        }
        func look() -> (colour: String, width: String) {
            openCard(at: line)
            let found = (colourRow.value as? String ?? "", widthRow.value as? String ?? "")
            closeCards(clearOf: [cardFrame])
            return found
        }
        undoOnce()
        XCTAssertEqual(look().width, steppedName, "the whole hold was one undo step")
        undoOnce()
        XCTAssertEqual(look().width, slidName, "the tap was one undo step")
        undoOnce()
        let afterSlide = look()
        XCTAssertEqual(afterSlide.width, first, "the whole slide was one undo step")
        XCTAssertEqual(afterSlide.colour, third)
        undoOnce()
        XCTAssertEqual(look().colour, "Red", "the whole slide of the hue strip was one undo step")
        undoOnce()
        let last = look()
        XCTAssertEqual(last.colour, "Black", "and the first colour came back")
        XCTAssertEqual(last.width, first)
        attach("undone-light")
    }

    /// The figure as the card writes it, to a tenth.
    private static func name(_ width: Double) -> String {
        width.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_GB"))) + " pt"
    }

    // MARK: Night, Chalkboard and accessibility

    func testTheCardAndItsDrawersAtNightAndOnChalkboard() throws {
        launch(["-appearance", "dark"])
        let line = CGPoint(x: window.frame.width * 0.5, y: window.frame.height * 0.32)
        drawLine(at: line)
        lasso.tap()
        waitUntilSelected(lasso)
        openCard(at: line)
        attach("card-dark")
        expectHittable(colourRow, "the Colour row")
        expectHittable(widthRow, "the Width row")

        colourRow.tap()
        let ink = app.buttons["editor.ink.colour.1B2230"], custom = app.buttons["editor.ink.colour.custom"]
        XCTAssertTrue(ink.waitForExistence(timeout: 8))
        attach("colour-drawer-dark")
        let blots = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'editor.ink.colour.'")).allElementsBoundByIndex
        XCTAssertEqual(blots.count, 17, "twelve inks, four highlighter tints and Custom Colour")
        for blot in blots {
            XCTAssertFalse(blot.label.isEmpty, "\(blot.identifier) has its colour's name")
            expectHittable(blot, blot.identifier)
            XCTAssertTrue(window.frame.contains(blot.frame), "\(blot.identifier) is on screen")
        }
        XCTAssertEqual(blots.filter(\.isSelected).map(\.identifier), ["editor.ink.colour.1B2230"], "only the ink's colour is selected")
        custom.tap()
        XCTAssertTrue(app.sliders["Hue"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.sliders["Shade"].exists)
        attach("mixing-strips-dark")
        closeCards(clearOf: [cardFrame, app.sliders["Hue"].frame, ink.frame, custom.frame])

        openCard(at: line)
        widthRow.tap()
        let strip = app.element("editor.ink.width.strip"), plus = app.buttons["editor.ink.width.plus"], minus = app.buttons["editor.ink.width.minus"]
        XCTAssertTrue(strip.waitForExistence(timeout: 8))
        attach("width-drawer-dark")
        XCTAssertEqual(strip.label, "Width")
        expectHittable(plus, "plus")
        expectHittable(minus, "minus")
        XCTAssertGreaterThanOrEqual(strip.frame.height, 44)
        XCTAssertEqual(plus.label, "Broader")
        XCTAssertEqual(minus.label, "Thinner")
        // XCUITest on iOS can't send an increment. The strip's is the plate's step put down at once, as a tap of plus is.
        XCTAssertEqual(strip.children(matching: .any).count, 0, "knob and well are one element")
        XCTAssertEqual(strip.value as? String, widthRow.value as? String, "it reads out the width")
        let before = points(widthRow).first ?? 0
        plus.tap()
        let after = expectation(for: NSPredicate(format: "value != %@", InkStyleUITests.name(before)), evaluatedWith: widthRow)
        wait(for: [after], timeout: 8)
        XCTAssertEqual(points(widthRow).first ?? 0, before * 1.1, accuracy: 0.15, "a step is a tenth broader")
        closeCards(clearOf: [cardFrame, strip.frame, plus.frame])
        app.buttons["editor.ink.done"].tap()
        XCTAssertTrue(caught.waitForNonExistence(timeout: 5))

        // On Chalkboard the ink is light, and so are its blots.
        app.chooseFromMore("Change Paper…", in: "Page")
        let chalkboard = app.buttons["Chalkboard"].firstMatch
        XCTAssertTrue(chalkboard.waitForExistence(timeout: 10))
        chalkboard.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(chalkboard.waitForNonExistence(timeout: 10))
        canvas.waitUntilStill()
        openCard(at: line)
        colourRow.tap()
        XCTAssertTrue(app.buttons["editor.ink.colour.custom"].waitForExistence(timeout: 8))
        attach("colour-drawer-chalkboard-dark")
    }

    func testTheCardAndItsDrawersAtTheLargestTextWithIncreaseContrast() throws {
        launch(["-appearance", "light", "-increaseContrast", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let line = CGPoint(x: window.frame.width * 0.5, y: window.frame.height * 0.3)
        drawLine(at: line)
        lasso.tap()
        waitUntilSelected(lasso)
        openCard(at: line)
        attach("card-largest-text")
        for row in [colourRow, widthRow] {
            XCTAssertTrue(window.frame.contains(row.frame), "\(row.identifier) is on screen")
            expectHittable(row, row.identifier)
        }
        XCTAssertEqual(colourRow.value as? String, "Black")

        colourRow.tap()
        let custom = app.buttons["editor.ink.colour.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 8))
        XCTAssertTrue(window.frame.contains(custom.frame))
        attach("colour-drawer-largest-text")
        closeCards(clearOf: [cardFrame, custom.frame, app.buttons["editor.ink.colour.1B2230"].frame])

        openCard(at: line)
        widthRow.tap()
        let strip = app.element("editor.ink.width.strip"), readout = app.staticTexts["editor.ink.width.value"]
        XCTAssertTrue(strip.waitForExistence(timeout: 8))
        XCTAssertTrue(window.frame.contains(readout.frame), "the readout is on screen")
        XCTAssertTrue(window.frame.contains(app.buttons["editor.ink.width.plus"].frame))
        attach("width-drawer-largest-text")
    }

    /// Right to left the strip runs the way the card's rows do: broader is on the left. Ink in two colours says so.
    func testRightToLeftTheWidthStripRunsTheWayTheRowsDo() throws {
        launch(["-appearance", "light", "-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"])
        let line = CGPoint(x: window.frame.width * 0.5, y: window.frame.height * 0.3)
        drawLine(at: line)
        let blue = app.buttons["editor.tools.2"]
        blue.tap()
        waitUntilSelected(blue)
        drawLine(at: CGPoint(x: line.x, y: line.y + 14))
        lasso.tap()
        waitUntilSelected(lasso)
        openCard(at: line)
        XCTAssertEqual(colourRow.value as? String, "Several colours")
        attach("card-several-colours-right-to-left")
        let first = points(widthRow).first ?? 0
        widthRow.tap()
        let strip = app.element("editor.ink.width.strip"), plus = app.buttons["editor.ink.width.plus"], minus = app.buttons["editor.ink.width.minus"]
        XCTAssertTrue(strip.waitForExistence(timeout: 8))
        XCTAssertLessThan(plus.frame.midX, minus.frame.midX, "Broader is on the left")
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.61, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.5)), withVelocity: 200, thenHoldForDuration: 0.2)
        let slid = expectation(for: NSPredicate(format: "value != %@", InkStyleUITests.name(first)), evaluatedWith: widthRow)
        wait(for: [slid], timeout: 8)
        XCTAssertGreaterThan(points(widthRow).first ?? 0, first * 1.3, "sliding left makes the line broader")
        attach("width-drawer-right-to-left")
        closeCards(clearOf: [cardFrame, strip.frame])
        openCard(at: line)
        colourRow.tap()
        XCTAssertTrue(app.buttons["editor.ink.colour.custom"].waitForExistence(timeout: 8))
        let chosen = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'editor.ink.colour.' AND selected == YES"))
        XCTAssertEqual(chosen.count, 0, "with several colours no blot is ringed")
        attach("colour-drawer-right-to-left")
        app.buttons["editor.ink.colour.C9452F"].tap()
        waitForValue("Red", of: colourRow, "a blot gives every caught line its colour")
    }

    // MARK: Fit

    func testTheCardsStayOnScreenNearEachEdgeUpright() throws { try fit(.portrait) }

    func testTheCardsStayOnScreenNearEachEdgeOnItsSide() throws { try fit(.landscapeLeft) }

    private func fit(_ orientation: UIDeviceOrientation) throws {
        XCUIDevice.shared.orientation = orientation
        launch(["-appearance", "light"])
        let pen = app.buttons["editor.tools.1"]
        let size = window.frame.size, name = orientation == .portrait ? "upright" : "on-its-side"
        let spots = [("top-left", CGPoint(x: 0.14, y: 0.16)), ("top-right", CGPoint(x: 0.86, y: 0.16)),
                     ("bottom-left", CGPoint(x: 0.14, y: 0.82)), ("bottom-right", CGPoint(x: 0.86, y: 0.82))]
            .map { ($0.0, CGPoint(x: size.width * $0.1.x, y: size.height * $0.1.y)) }
        for (corner, line) in spots {
            // Tapped while in hand a pen opens its options, so it is only tapped to take it up.
            if !pen.isSelected {
                pen.tap()
                waitUntilSelected(pen)
            }
            drawLine(at: line)
            lasso.tap()
            waitUntilSelected(lasso)
            let ink = CGRect(x: line.x - 60, y: line.y - 4, width: 120, height: 12)
            for drawer in ["colour", "width"] {
                openCard(at: line)
                let card = cardFrame
                XCTAssertTrue(window.frame.contains(card), "\(name) \(corner): the card is on screen")
                (drawer == "colour" ? colourRow : widthRow).tap()
                XCTAssertTrue((drawer == "colour" ? app.buttons["editor.ink.colour.custom"] : app.buttons["editor.ink.width.plus"]).waitForExistence(timeout: 8))
                let shown = drawer == "colour"
                    ? app.buttons["editor.ink.colour.1B2230"].frame.union(app.buttons["editor.ink.colour.custom"].frame)
                    : app.element("editor.ink.width.strip").frame.union(app.buttons["editor.ink.width.minus"].frame).union(app.buttons["editor.ink.width.plus"].frame)
                XCTAssertTrue(window.frame.contains(shown), "\(name) \(corner): the \(drawer) drawer is on screen")
                let covers = [card.intersects(ink) ? "card" : nil, shown.intersects(ink) ? "\(drawer) drawer" : nil].compactMap { $0 }
                print("FIT \(name) \(corner) \(drawer): card \(card.integral) drawer \(shown.integral) ink \(ink.integral) covers: \(covers.isEmpty ? "nothing" : covers.joined(separator: ", "))")
                if !covers.isEmpty || drawer == "colour" { attach("fit-\(name)-\(corner)-\(drawer)") }
                closeCards(clearOf: [card, shown, ink])
            }
            app.buttons["editor.ink.done"].tap()
            XCTAssertTrue(caught.waitForNonExistence(timeout: 5))
        }
    }
}
