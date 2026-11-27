import XCTest
import PencilKit
@testable import OwlLuna

/// The colour and the line of caught ink, as the page stack puts them on its pages and into the document.
@MainActor
final class InkRestyleCanvasTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
    private let everything = [CGPoint(x: -5000, y: -5000), CGPoint(x: 5000, y: -5000), CGPoint(x: 5000, y: 5000), CGPoint(x: -5000, y: 5000)]
    /// The first page stands 16 points into the stack: this box holds the lines at 100 and 200 and not one further down.
    private let upperTwo = [CGPoint(x: 96, y: 96), CGPoint(x: 336, y: 96), CGPoint(x: 336, y: 236), CGPoint(x: 96, y: 236)]
    private let black: UInt32 = 0x0000_00FF, red: UInt32 = 0xD031_2DFF, blue: UInt32 = 0x2A5C_AAFF

    @MainActor
    private struct Editor {
        let session: EditorSession, controller: PageStackController, toolbox: Toolbox
        var document: NotebookDocument { session.document }
        func page(_ index: Int) -> UUID { document.pages[index].id }
        /// Where the first two pages stand in the stack.
        var frames: [UUID: CGRect] {
            [page(0): CGRect(x: 16, y: 16, width: 612, height: 792), page(1): CGRect(x: 16, y: 824, width: 612, height: 792)]
        }
    }

    private func line(y: CGFloat, width: CGFloat = 4) -> PKStroke {
        stroke(from: CGPoint(x: 100, y: y), to: CGPoint(x: 300, y: y), width: width)
    }

    /// An editor in a window, on `count` pages of `paper` with `ink` on them from the first on, and the lasso in hand.
    /// A notebook from the `future` opens read-only.
    private func openEditor(ink: [PKDrawing], pages count: Int = 2, paper: PageDefaults? = nil, future: Bool = false) async throws -> Editor {
        let flow = UserDefaults.standard.object(forKey: SettingsKey.pageFlow)
        UserDefaults.standard.set(PageFlow.continuous.rawValue, forKey: SettingsKey.pageFlow)
        addTeardownBlock { UserDefaults.standard.set(flow, forKey: SettingsKey.pageFlow) }
        let paper = paper ?? self.paper, root = temporaryRoot(self)
        var manifest = NotebookManifest(title: "Notes", defaults: paper, pages: (0..<count).map { _ in paper.newPage() })
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: Dictionary(uniqueKeysWithValues: ink.enumerated().map { (manifest.pages[$0.offset].id, $0.element) })))
        if future {
            manifest = try await package.readManifest().manifest
            manifest.schemaVersion = 99
            try ManifestCodec.encode(manifest).write(to: package.manifestURL)
        }
        let session = EditorSession(document: try await NotebookDocument.open(manifest.id, root: root))
        let toolbox = Toolbox(defaults: nil)
        let controller = PageStackController(session: session, toolbox: toolbox)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        for index in ink.indices {
            for _ in 0..<200 where controller.canvas(forPage: index)?.isLoaded != true { try? await Task.sleep(for: .seconds(0.05)) }
        }
        session.document.undoManager.groupsByEvent = false
        if !future { toolbox.take(.lasso) }
        return Editor(session: session, controller: controller, toolbox: toolbox)
    }

    /// What is done in `change` is one undo step. What should take none on is done outside one: an undo manager
    /// keeps even an empty group as a step.
    private func step(_ editor: Editor, _ change: () throws -> Void) rethrows {
        editor.document.undoManager.beginUndoGrouping()
        defer { editor.document.undoManager.endUndoGrouping() }
        try change()
    }

    private func wait(_ seconds: Double = 30, until done: () -> Bool) async {
        let start = ContinuousClock.now
        while !done(), ContinuousClock.now - start < .seconds(seconds) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func find<View: UIView>(_ type: View.Type, in root: UIView, where matches: (View) -> Bool = { _ in true }) -> View? {
        var views = [root]
        while !views.isEmpty {
            let view = views.removeFirst()
            if let found = view as? View, matches(found) { return found }
            views += view.subviews
        }
        return nil
    }

    private func box(in editor: Editor) throws -> InkBox {
        try XCTUnwrap(find(InkLassoOverlay.self, in: editor.controller.view)?.selectionBox, "nothing has a box round it")
    }

    private func grip(_ handle: InkHandle, in editor: Editor) throws -> InkGrip {
        try XCTUnwrap(find(InkGrip.self, in: editor.controller.view) { $0.handle == handle }, "the lasso's box has no \(handle) handle")
    }

    private func tints(_ drawing: PKDrawing?) -> [UInt32] { (drawing?.strokes ?? []).map { ToolPreset.bytes(of: $0.ink.color) } }

    private func widths(_ drawing: PKDrawing?) -> [Double] { (drawing?.strokes ?? []).map { InkRestyle.width(of: $0) } }

    /// The lines of one drawing are as broad as those of another, stroke for stroke.
    private func assertLines(_ shown: PKDrawing?, _ expected: PKDrawing?, _ message: String = "", within accuracy: Double = 1e-6, line: UInt = #line) {
        let found = widths(shown), wanted = widths(expected)
        XCTAssertEqual(found.count, wanted.count, message, line: line)
        XCTAssertFalse(wanted.isEmpty, message, line: line)
        for (one, other) in zip(found, wanted) { XCTAssertEqual(one, other, accuracy: accuracy, message, line: line) }
    }

    private func linesMatch(_ shown: PKDrawing?, _ expected: PKDrawing?) -> Bool {
        let found = widths(shown), wanted = widths(expected)
        return found.count == wanted.count && zip(found, wanted).allSatisfy { abs($0 - $1) < 1e-6 }
    }

    private func assertBox(_ box: InkBox, _ expected: InkBox?, _ message: String = "", line: UInt = #line) {
        guard let expected else { return XCTFail("no box to compare with. " + message, line: line) }
        XCTAssertEqual(box.center.x, expected.center.x, accuracy: 0.01, message, line: line)
        XCTAssertEqual(box.center.y, expected.center.y, accuracy: 0.01, message, line: line)
        XCTAssertEqual(box.size.width, expected.size.width, accuracy: 0.01, message, line: line)
        XCTAssertEqual(box.size.height, expected.size.height, accuracy: 0.01, message, line: line)
        XCTAssertEqual(box.turn, expected.turn, accuracy: 1e-6, message, line: line)
    }

    // MARK: Colour

    func testATintIsOneUndoStepAndTheInkStaysCaughtInItsBox() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200), line(y: 500)])])
        let document = editor.document, controller = editor.controller, session = editor.session, first = editor.page(0)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0))
        XCTAssertNil(session.inkLook, "with nothing caught there is no look to show")
        controller.catchInk(inside: upperTwo)
        XCTAssertEqual(session.inkSelectionCount, 2)
        XCTAssertEqual(session.inkLook?.tints, [black])
        try step(editor) { try grip(.knob, in: editor).accessibilityIncrement() }
        let turned = try box(in: editor)
        XCTAssertEqual(turned.turnedDegrees, 15)

        let taken = document.undoManager.registrations
        step(editor) { controller.tintInkSelection(red) }
        XCTAssertEqual(tints(document.loadedInk(first)), [red, red, black], "only what is caught takes the colour")
        XCTAssertEqual(document.undoManager.registrations, taken + 1, "as one undo step")
        XCTAssertEqual(document.undoManager.undoActionName, "Change Ink Colour")
        XCTAssertEqual(tints(canvas.ink), [red, red, black], "and the page shows it")
        XCTAssertEqual(session.inkSelectionCount, 2, "it stays caught")
        XCTAssertEqual(session.inkLook?.tints, [red])
        assertBox(try box(in: editor), turned, "in its box, turned as it was")
        XCTAssertEqual(try grip(.knob, in: editor).accessibilityValue, "Turned 15° right")

        controller.tintInkSelection(red)
        XCTAssertEqual(document.undoManager.registrations, taken + 1, "the colour it has already is no step")

        document.undoManager.undo()
        XCTAssertEqual(tints(document.loadedInk(first)), [black, black, black])
        XCTAssertEqual(tints(canvas.ink), [black, black, black])
        XCTAssertEqual(session.inkSelectionCount, 2, "undoing a colour leaves the ink caught")
        XCTAssertEqual(session.inkLook?.tints, [black])
        assertBox(try box(in: editor), turned)
        document.undoManager.redo()
        XCTAssertEqual(tints(document.loadedInk(first)), [red, red, black])
        XCTAssertEqual(session.inkSelectionCount, 2, "and so does redoing it")
        XCTAssertEqual(session.inkLook?.tints, [red])
        step(editor) { controller.tintInkSelection(blue) }
        XCTAssertEqual(tints(document.loadedInk(first)), [blue, blue, black], "so another colour can be tried at once")

        document.undoManager.undo()
        document.undoManager.undo()
        XCTAssertEqual(session.inkSelectionCount, 2)
        document.undoManager.undo()
        XCTAssertEqual(document.undoManager.redoActionName, "Rotate Ink")
        XCTAssertEqual(session.inkSelectionCount, 0, "an undo that turns the strokes back lets them go")
        XCTAssertNil(session.inkLook)
    }

    /// A canvas keeps what it has drawn for a stroke it knows, so a stroke given another colour is one made anew.
    func testATintedStrokeIsDrawnInItsNewColour() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [stroke(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 400, y: 300), width: 12)])])
        let controller = editor.controller
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), slot = try XCTUnwrap(canvas.superview), window = try XCTUnwrap(controller.view.window)
        func colour() -> (red: Int, green: Int, blue: Int) {
            let point = slot.convert(CGPoint(x: 250 * canvas.zoomScale, y: 300 * canvas.zoomScale), to: window)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1), format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            if let picture = image.cgImage { context?.draw(picture, in: CGRect(x: 0, y: 0, width: 1, height: 1)) }
            return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
        }
        await wait { colour().red < 60 }
        XCTAssertLessThan(colour().red, 60, "the line is drawn black")
        controller.catchInk(inside: everything)
        step(editor) { controller.tintInkSelection(red) }
        await wait { colour().red > 150 }
        XCTAssertGreaterThan(colour().red, 150, "the page shows the line red")
        XCTAssertLessThan(colour().green, 110)
        editor.document.undoManager.undo()
        await wait { colour().red < 60 }
        XCTAssertLessThan(colour().red, 60, "and black again once that is undone")

        // Each colour tried is drawn too, and the saved one again when the trial is let go.
        controller.tryInkTint(blue)
        await wait { colour().blue > 130 && colour().red < 90 }
        XCTAssertGreaterThan(colour().blue, 130, "a tried colour shows")
        controller.tryInkTint(red)
        await wait { colour().red > 150 }
        XCTAssertGreaterThan(colour().red, 150, "and so does the next one tried")
        controller.viewWillDisappear(false)
        await wait { colour().red < 60 && colour().blue < 60 }
        XCTAssertLessThan(colour().red, 60, "let go, the line is black as the document has it")
    }

    func testTintedInkOnDarkPaperIsAPensInk() async throws {
        let saved = [SettingsKey.appearance, SettingsKey.darkPaper].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        addTeardownBlock { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set(true, forKey: SettingsKey.darkPaper)
        let pen = try XCTUnwrap(ToolPreset(ink: .pen, color: red & 0xFFFF_FF80, width: 4).tool, "a half-strength red pen")
        let faint = PKStroke(ink: PKInk(.pen, color: UIColor.black.withAlphaComponent(128 / 255)), path: line(y: 200).path)
        for chalkboard in [true, false] {
            let stock = PageDefaults(template: .blank, paperColor: chalkboard ? .chalkboard : .white, pageSize: .letter)
            let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), faint])], paper: stock)
            let controller = editor.controller, first = editor.page(0)
            if !chalkboard {
                // Light paper that Dark Mode shows dark.
                UserDefaults.standard.set(AppAppearance.dark.rawValue, forKey: SettingsKey.appearance)
                controller.view.window?.overrideUserInterfaceStyle = .dark
                controller.view.window?.updateTraitsIfNeeded()
                controller.updateTraitsIfNeeded()
                for _ in 0..<200 where controller.canvas(forPage: 0)?.isLoaded != true { try? await Task.sleep(for: .seconds(0.05)) }
            }
            XCTAssertEqual(controller.canvas(forPage: 0)?.overrideUserInterfaceStyle, .dark, "ink is drawn for dark paper there")
            controller.catchInk(inside: everything)
            XCTAssertEqual(editor.session.inkSelectionCount, 2)
            step(editor) { controller.tintInkSelection(red) }
            // PencilKit keeps a stroke's colour as it is on light paper and lightens it where the canvas is dark, so
            // tinted ink is a pen's ink when it holds the colour that pen holds.
            let inks = try XCTUnwrap(editor.document.loadedInk(first)).strokes.map(\.ink)
            XCTAssertEqual(inks.map { ToolPreset.bytes(of: $0.color) }, [red, red & 0xFFFF_FF80])
            XCTAssertEqual(ToolPreset.bytes(of: inks[1].color), ToolPreset.bytes(of: pen.color), "as faint as it was, in the pen's colour")
            XCTAssertEqual(editor.session.inkLook?.tints, [red], "and the look names the colour as the palette lists it")
            controller.view.window?.isHidden = true
        }
    }

    func testATriedColourShowsOnThePagesAndIsSettledAsOneUndoStep() async throws {
        let faint = PKStroke(ink: PKInk(.pen, color: UIColor.black.withAlphaComponent(128 / 255)), path: line(y: 200).path)
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), faint, line(y: 500)])])
        let document = editor.document, controller = editor.controller, session = editor.session, first = editor.page(0)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), half: UInt32 = 0xFFFF_FF80
        controller.catchInk(inside: upperTwo)
        try step(editor) { try grip(.knob, in: editor).accessibilityIncrement() }
        let look = try XCTUnwrap(session.inkLook), turned = try box(in: editor), taken = document.undoManager.registrations
        let before = tints(document.loadedInk(first))
        XCTAssertEqual(before, [black, black & half, black])

        controller.settleInkTint()
        XCTAssertEqual(document.undoManager.registrations, taken, "with no colour tried there is nothing to settle")
        controller.tryInkTint(red)
        XCTAssertEqual(tints(canvas.ink), [red, red & half, black], "the page shows the caught ink in the colour, each stroke as faint as it was")
        XCTAssertEqual(tints(document.loadedInk(first)), before, "while the document keeps its colours")
        XCTAssertEqual(document.undoManager.registrations, taken, "and takes on no undo step")
        XCTAssertEqual(session.inkLook, look, "the look stays as it was when the trying began")
        assertBox(try box(in: editor), turned)

        controller.tryInkTint(blue)
        controller.tryInkTint(red & 0xFFFF_FF00)
        controller.tryInkTint(blue)
        await wait { tints(canvas.ink) == [blue, blue & half, black] }
        XCTAssertEqual(tints(canvas.ink), [blue, blue & half, black], "the newest colour is the one shown, on the ink as it was")
        controller.settleInkLine()
        XCTAssertEqual(document.undoManager.registrations, taken, "settling a line leaves a colour that is being tried alone")
        XCTAssertEqual(tints(canvas.ink), [blue, blue & half, black])

        step(editor) { controller.settleInkTint() }
        XCTAssertEqual(tints(document.loadedInk(first)), [blue, blue & half, black], "the colour last tried is put down")
        XCTAssertEqual(document.undoManager.registrations, taken + 1, "as one undo step for the whole slide")
        XCTAssertEqual(document.undoManager.undoActionName, "Change Ink Colour")
        XCTAssertEqual(tints(canvas.ink), [blue, blue & half, black])
        XCTAssertEqual(session.inkSelectionCount, 2, "the ink stays caught")
        XCTAssertEqual(session.inkLook, InkLook(tints: [blue], widths: look.widths))
        assertBox(try box(in: editor), turned, "in its box, turned as it was")
        controller.settleInkTint()
        controller.tryInkTint(blue)
        controller.settleInkTint()
        XCTAssertEqual(document.undoManager.registrations, taken + 1, "settled once, or tried in the colour it has, it is no further step")

        document.undoManager.undo()
        XCTAssertEqual(tints(document.loadedInk(first)), before)
        XCTAssertEqual(tints(canvas.ink), before)
        XCTAssertEqual(session.inkSelectionCount, 2, "undoing it leaves the ink caught")
        XCTAssertEqual(session.inkLook, look)
        document.undoManager.redo()
        XCTAssertEqual(tints(document.loadedInk(first)), [blue, blue & half, black])
        XCTAssertEqual(session.inkSelectionCount, 2)

        // A tap on a blot while a colour is still being tried: the tried colour is settled, then the blot's is put down.
        controller.tryInkTint(red)
        step(editor) { controller.tintInkSelection(black) }
        XCTAssertEqual(tints(document.loadedInk(first)), [black, black & half, black])
        XCTAssertEqual(tints(canvas.ink), [black, black & half, black])
        XCTAssertEqual(session.inkLook?.tints, [black])
    }

    func testALineAndAColourAreNotTriedTogether() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200)])])
        let document = editor.document, controller = editor.controller, first = editor.page(0)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), before = try XCTUnwrap(document.loadedInk(first))
        let caught: InkSelection = [first: [0, 1]], broad = InkRestyle.lined(caught, .times(2), in: [first: before])[first]
        controller.catchInk(inside: everything)
        let taken = document.undoManager.registrations

        controller.tryInkLine(.times(2))
        step(editor) { controller.tryInkTint(red) }
        assertLines(document.loadedInk(first), broad, "a colour tried while a line is showing settles the line")
        XCTAssertEqual(document.undoManager.registrations, taken + 1)
        XCTAssertEqual(document.undoManager.undoActionName, "Change Ink Width")
        XCTAssertEqual(tints(document.loadedInk(first)), [black, black], "and is itself only tried")
        XCTAssertEqual(tints(canvas.ink), [red, red])
        assertLines(canvas.ink, broad)

        step(editor) { controller.tryInkLine(.times(1.5)) }
        XCTAssertEqual(tints(document.loadedInk(first)), [red, red], "a line tried while a colour is showing settles the colour")
        XCTAssertEqual(document.undoManager.undoActionName, "Change Ink Colour")
        assertLines(document.loadedInk(first), broad)
        let broader = InkRestyle.lined(caught, .times(1.5), in: [first: try XCTUnwrap(document.loadedInk(first))])[first]
        assertLines(canvas.ink, broader)
        XCTAssertEqual(tints(canvas.ink), [red, red])
        controller.settleInkTint()
        XCTAssertEqual(document.undoManager.registrations, taken + 2, "and settling a colour leaves a line that is being tried alone")
        step(editor) { controller.settleInkLine() }
        assertLines(document.loadedInk(first), broader)
        XCTAssertEqual(document.undoManager.registrations, taken + 3)
    }

    func testAColourTrialEndsAsALineTrialDoes() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200)])], pages: 6)
        let document = editor.document, controller = editor.controller, session = editor.session, first = editor.page(0)
        controller.catchInk(inside: everything)
        func shown() -> [UInt32] { tints(controller.canvas(forPage: 0)?.ink) }
        func saved() -> [UInt32] { tints(document.loadedInk(first)) }

        // A canvas made while a colour is tried shows it, and the zoom window shows what is saved.
        controller.tryInkTint(red)
        session.go(to: 5, animated: false)
        XCTAssertNil(controller.canvas(forPage: 0))
        session.go(to: 0, animated: false)
        for _ in 0..<200 where controller.canvas(forPage: 0)?.isLoaded != true { try? await Task.sleep(for: .seconds(0.05)) }
        XCTAssertEqual(shown(), [red, red], "the canvas made for the page when it comes back shows the tried colour")
        XCTAssertEqual(saved(), [black, black])
        session.setZoomWindow(true)
        let strip = try XCTUnwrap(find(PageCanvasView.self, in: controller.view) { $0.accessibilityIdentifier == "zoom.canvas" })
        for _ in 0..<200 where !strip.isLoaded { try? await Task.sleep(for: .seconds(0.05)) }
        XCTAssertEqual(tints(strip.ink), [black, black], "a colour only tried is not the strip's to show")
        XCTAssertEqual(session.inkSelectionCount, 2)

        // Done keeps the colour that was showing.
        step(editor) { controller.clearInkSelection() }
        XCTAssertEqual(saved(), [red, red])
        XCTAssertEqual(shown(), [red, red])
        XCTAssertEqual(tints(strip.ink), [red, red], "settled, it is")
        XCTAssertEqual(document.undoManager.undoActionName, "Change Ink Colour")
        session.setZoomWindow(false)

        // An undo arriving lets a tried colour go; so does the editor's view on its way out.
        controller.catchInk(inside: everything)
        let taken = document.undoManager.registrations
        controller.tryInkTint(blue)
        XCTAssertEqual(shown(), [blue, blue])
        document.undoManager.undo()
        XCTAssertEqual(saved(), [black, black])
        XCTAssertEqual(shown(), [black, black], "the page shows what the document holds")
        XCTAssertEqual(session.inkSelectionCount, 2)
        XCTAssertEqual(document.undoManager.registrations, taken + 1, "with only the undo's own step taken on")
        controller.tryInkTint(blue)
        controller.viewWillDisappear(false)
        XCTAssertEqual(shown(), [black, black])
        XCTAssertEqual(saved(), [black, black])

        // The scene going inactive keeps it.
        controller.tryInkTint(blue)
        step(editor) { NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: nil) }
        XCTAssertEqual(saved(), [blue, blue])
        XCTAssertEqual(session.inkLook?.tints, [blue])

        // A large catch has its colour worked out off the main thread: the newest is shown, and a stale one never is.
        controller.inkTrialAtOnce = 0
        controller.tryInkTint(red)
        controller.tryInkTint(black)
        controller.tryInkTint(red)
        XCTAssertEqual(saved(), [blue, blue])
        await wait { shown() == [red, red] }
        XCTAssertEqual(shown(), [red, red])
        controller.tryInkTint(black)
        step(editor) { controller.settleInkTint() }
        XCTAssertEqual(saved(), [black, black], "settled before the page has got to it, the colour is put down all the same")
        try? await Task.sleep(for: .seconds(0.6))
        XCTAssertEqual(shown(), [black, black])
    }

    /// For whoever can't tap the ink itself: the card opens on it as a tap would open it.
    func testTheCardOpensOnCaughtInkWithoutATap() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200)])], pages: 6)
        let controller = editor.controller, session = editor.session
        controller.showInkMenu()
        XCTAssertNil(session.inkMenu, "with nothing caught there is nothing to open it on")

        controller.catchInk(inside: everything)
        controller.showInkMenu()
        let menu = try XCTUnwrap(session.inkMenu), view = try XCTUnwrap(controller.view)
        let overlay = try XCTUnwrap(find(InkLassoOverlay.self, in: view)), scale = try XCTUnwrap(controller.canvas(forPage: 0)).zoomScale
        let around = overlay.convert(try XCTUnwrap(overlay.selectionBounds).scaled(by: scale), to: view).insetBy(dx: -8, dy: -8).intersection(view.bounds)
        XCTAssertNil(menu.pastePoint, "it is the card for caught ink, not for pasting")
        XCTAssertEqual(menu.rect.minX, around.minX, accuracy: 0.01, "it opens beside the ink's box")
        XCTAssertEqual(menu.rect.minY, around.minY, accuracy: 0.01)
        XCTAssertEqual(menu.rect.width, around.width, accuracy: 0.01)
        XCTAssertEqual(menu.rect.height, around.height, accuracy: 0.01)
        XCTAssertEqual(session.inkSelectionCount, 2, "and the ink stays caught")

        session.inkMenu = nil
        session.go(to: 5, animated: false)
        controller.showInkMenu()
        let away = try XCTUnwrap(session.inkMenu, "with the ink scrolled out of sight the card still opens")
        XCTAssertEqual(away.rect.size, .zero)
        XCTAssertTrue(view.bounds.contains(away.rect.origin), "in the middle of the pages")

        session.inkMenu = nil
        controller.clearInkSelection()
        controller.showInkMenu()
        XCTAssertNil(session.inkMenu)
    }

    // MARK: Line

    func testATriedLineShowsOnThePagesAndSavesNothing() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200, width: 6), line(y: 500)])])
        let document = editor.document, controller = editor.controller, session = editor.session, first = editor.page(0)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), before = try XCTUnwrap(document.loadedInk(first))
        let caught: InkSelection = [first: [0, 1]]
        controller.catchInk(inside: upperTwo)
        let look = try XCTUnwrap(session.inkLook), snug = try box(in: editor), taken = document.undoManager.registrations
        func tried(_ line: InkLine) -> PKDrawing? { InkRestyle.lined(caught, line, in: [first: before])[first] }
        XCTAssertNotEqual(widths(tried(.times(2))), widths(before), "the model does broaden these lines")

        controller.tryInkLine(.times(2))
        assertLines(canvas.ink, tried(.times(2)), "the page shows the caught lines twice as broad, and the others as they were")
        assertLines(document.loadedInk(first), before, "while the document keeps them as they are")
        XCTAssertEqual(document.undoManager.registrations, taken, "and takes on no undo step")
        XCTAssertFalse(document.hasUnsavedInk(first))
        XCTAssertEqual(session.inkLook, look, "the look stays as it was when the trying began")
        assertBox(try box(in: editor), InkLasso.box(of: caught, drawings: [first: try XCTUnwrap(tried(.times(2)))], frames: editor.frames), "the box goes round the broader lines")
        XCTAssertGreaterThan(try box(in: editor).size.height, snug.size.height)

        controller.tryInkLine(.times(2))
        try? await Task.sleep(for: .seconds(0.4))
        assertLines(canvas.ink, tried(.times(2)), "tried again, twice as broad is still twice as broad as it was")
        controller.tryInkLine(.times(3))
        controller.tryInkLine(.times(0.5))
        controller.tryInkLine(.width(5))
        await wait { linesMatch(canvas.ink, tried(.width(5))) }
        assertLines(canvas.ink, tried(.width(5)), "the newest line is the one shown, reckoned from the lines as they were")
        assertLines(document.loadedInk(first), before)
        XCTAssertEqual(document.undoManager.registrations, taken)
        XCTAssertEqual(session.inkSelectionCount, 2)
    }

    func testASettledLineIsOneUndoStepAndTheBoxFitsIt() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200, width: 6), line(y: 500)])])
        let document = editor.document, controller = editor.controller, session = editor.session, first = editor.page(0)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), caught: InkSelection = [first: [0, 1]]
        controller.catchInk(inside: upperTwo)
        try step(editor) { try grip(.knob, in: editor).accessibilityIncrement() }
        let before = try XCTUnwrap(document.loadedInk(first)), look = try XCTUnwrap(session.inkLook), turned = try box(in: editor)
        let broad = try XCTUnwrap(InkRestyle.lined(caught, .times(2), in: [first: before])[first])
        let taken = document.undoManager.registrations

        controller.settleInkLine()
        XCTAssertEqual(document.undoManager.registrations, taken, "with nothing tried there is nothing to settle")
        controller.tryInkLine(.times(3))
        controller.tryInkLine(.times(2))
        step(editor) { controller.settleInkLine() }
        assertLines(document.loadedInk(first), broad, "the line last tried is put down, whether or not the page had got to it")
        XCTAssertEqual(document.undoManager.registrations, taken + 1, "as one undo step")
        XCTAssertEqual(document.undoManager.undoActionName, "Change Ink Width")
        assertLines(canvas.ink, broad)
        XCTAssertEqual(session.inkSelectionCount, 2, "the ink stays caught")
        let fitted = try box(in: editor)
        assertBox(fitted, InkLasso.box(of: caught, turn: turned.turn, drawings: [first: broad], frames: editor.frames), "in a box drawn round the broader lines, turned as it was")
        XCTAssertEqual(fitted.turnedDegrees, 15)
        XCTAssertGreaterThan(fitted.size.height, turned.size.height)
        XCTAssertEqual(session.inkLook, InkRestyle.look(of: Array(broad.strokes[0...1])))
        XCTAssertNotEqual(session.inkLook, look)
        controller.settleInkLine()
        XCTAssertEqual(document.undoManager.registrations, taken + 1, "settled once, it is not settled again")

        document.undoManager.undo()
        assertLines(document.loadedInk(first), before)
        assertLines(canvas.ink, before)
        XCTAssertEqual(session.inkSelectionCount, 2, "undoing a line leaves the ink caught")
        XCTAssertEqual(session.inkLook, look)
        assertBox(try box(in: editor), turned, "in the box it had")
        document.undoManager.redo()
        assertLines(document.loadedInk(first), broad)
        XCTAssertEqual(session.inkSelectionCount, 2)
        assertBox(try box(in: editor), fitted)

        controller.tryInkLine(.times(2))
        step(editor) { controller.settleInkLine() }
        assertLines(document.loadedInk(first), InkRestyle.lined(caught, .times(2), in: [first: broad])[first], "a new trial starts from the lines as they now are")
    }

    func testNothingToDoTakesOnNoUndoStep() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200)])])
        let document = editor.document, controller = editor.controller, first = editor.page(0)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), before = try XCTUnwrap(document.loadedInk(first))
        let taken = document.undoManager.registrations
        controller.tintInkSelection(red)
        controller.tryInkLine(.times(2))
        controller.settleInkLine()
        XCTAssertEqual(tints(document.loadedInk(first)), [black, black], "with nothing caught, nothing is changed")
        assertLines(canvas.ink, before)

        controller.catchInk(inside: everything)
        XCTAssertEqual(editor.session.inkSelectionCount, 2)
        controller.tintInkSelection(black)
        controller.tintInkSelection(black & 0xFFFF_FF00)
        controller.tryInkLine(.times(1))
        controller.settleInkLine()
        controller.tryInkLine(.width(InkRestyle.width(of: before.strokes[0])))
        controller.settleInkLine()
        XCTAssertEqual(document.undoManager.registrations, taken, "nor by the colour and the line the ink already has")
        XCTAssertFalse(document.undoManager.canUndo)
        XCTAssertFalse(document.hasUnsavedInk(first))

        controller.tryInkLine(.times(2))
        controller.tryInkLine(.times(1))
        controller.settleInkLine()
        XCTAssertEqual(document.undoManager.registrations, taken, "a trial brought back to where it began is no step")
        assertLines(canvas.ink, before, "and the page shows the lines as they are")
        XCTAssertEqual(editor.session.inkSelectionCount, 2)
    }

    func testATintGoesOnUnderALineBeingTried() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200)])])
        let document = editor.document, controller = editor.controller, first = editor.page(0)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), before = try XCTUnwrap(document.loadedInk(first))
        let caught: InkSelection = [first: [0, 1]], broad = InkRestyle.lined(caught, .times(2), in: [first: before])[first]
        controller.catchInk(inside: everything)
        let look = try XCTUnwrap(editor.session.inkLook)
        controller.tryInkLine(.times(2))
        step(editor) { controller.tintInkSelection(red) }
        XCTAssertEqual(tints(document.loadedInk(first)), [red, red])
        assertLines(document.loadedInk(first), before, "the colour is saved, the line still only tried")
        await wait { linesMatch(canvas.ink, broad) && tints(canvas.ink) == [red, red] }
        assertLines(canvas.ink, broad, "and the page shows both")
        XCTAssertEqual(tints(canvas.ink), [red, red])
        XCTAssertEqual(editor.session.inkLook, InkLook(tints: [red], widths: look.widths))
        step(editor) { controller.settleInkLine() }
        assertLines(document.loadedInk(first), broad)
        XCTAssertEqual(tints(document.loadedInk(first)), [red, red])
        document.undoManager.undo()
        assertLines(document.loadedInk(first), before, "the line and the colour are a step each")
        XCTAssertEqual(tints(document.loadedInk(first)), [red, red])
        document.undoManager.undo()
        XCTAssertEqual(tints(document.loadedInk(first)), [black, black])
        XCTAssertEqual(editor.session.inkSelectionCount, 2)
    }

    /// The highlighter's ink lies on a canvas of its own under the page's: each shows the line tried on its strokes.
    func testATriedLineShowsOnTheHighlightersCanvasToo() async throws {
        let mark = PKStroke(ink: PKInk(.marker, color: .yellow), path: line(y: 200, width: 14).path)
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), mark, line(y: 300)])])
        let document = editor.document, controller = editor.controller, first = editor.page(0)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), under = try XCTUnwrap(canvas.ground)
        let before = try XCTUnwrap(document.loadedInk(first)), caught: InkSelection = [first: [0, 1, 2]]
        func tried(_ line: InkLine) -> PKDrawing? { InkRestyle.lined(caught, line, in: [first: before])[first] }
        controller.catchInk(inside: everything)
        XCTAssertEqual(editor.session.inkSelectionCount, 3)
        XCTAssertEqual(under.drawing.strokes.count, 1, "the highlighter's stroke is on the canvas underneath")

        controller.tryInkLine(.times(1.5))
        assertLines(canvas.ink, tried(.times(1.5)))
        assertLines(under.drawing, PKDrawing(strokes: [try XCTUnwrap(tried(.times(1.5))).strokes[1]]), "and is shown there as broad as it is tried")
        controller.tryInkLine(.times(2))
        controller.tryInkLine(.times(0.8))
        await wait { linesMatch(canvas.ink, tried(.times(0.8))) }
        assertLines(canvas.ink, tried(.times(0.8)), "the next line waits for both canvases and then is shown on both")
        assertLines(under.drawing, PKDrawing(strokes: [try XCTUnwrap(tried(.times(0.8))).strokes[1]]))
        assertLines(document.loadedInk(first), before)
        step(editor) { controller.settleInkLine() }
        assertLines(document.loadedInk(first), tried(.times(0.8)))
        XCTAssertEqual(tints(document.loadedInk(first)), tints(before), "a line changes no colour")
        step(editor) { controller.tintInkSelection(red) }
        XCTAssertEqual(tints(under.drawing), [red & 0xFFFF_FF00 | ToolPreset.bytes(of: mark.ink.color) & 0xFF], "tinted, the highlighter stays as sheer as it was")
        XCTAssertEqual(editor.session.inkLook?.tints, [red])
    }

    /// Above `inkTrialAtOnce` strokes a line is worked out off the main thread, and only for the trial that asked.
    func testALargeCatchIsTriedOffTheMainThread() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200), line(y: 300)])])
        let document = editor.document, controller = editor.controller, first = editor.page(0)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), before = try XCTUnwrap(document.loadedInk(first))
        let caught: InkSelection = [first: [0, 1, 2]]
        func tried(_ line: InkLine) -> PKDrawing? { InkRestyle.lined(caught, line, in: [first: before])[first] }
        controller.inkTrialAtOnce = 0
        controller.catchInk(inside: everything)
        let taken = document.undoManager.registrations

        controller.tryInkLine(.times(1.5))
        controller.tryInkLine(.times(2))
        controller.tryInkLine(.times(3))
        assertLines(document.loadedInk(first), before)
        await wait { linesMatch(canvas.ink, tried(.times(3))) }
        assertLines(canvas.ink, tried(.times(3)), "the page comes to the newest line")
        assertBox(try box(in: editor), InkLasso.box(of: caught, drawings: [first: try XCTUnwrap(tried(.times(3)))], frames: editor.frames))
        XCTAssertEqual(document.undoManager.registrations, taken)

        // Settled before the page has got to it, the line is put down all the same, and what was still being worked out is not shown.
        controller.tryInkLine(.times(1.2))
        step(editor) { controller.settleInkLine() }
        assertLines(document.loadedInk(first), tried(.times(1.2)))
        assertLines(canvas.ink, tried(.times(1.2)))
        try? await Task.sleep(for: .seconds(0.6))
        assertLines(canvas.ink, document.loadedInk(first))

        // Undone while a line is being worked out, the trial is let go.
        controller.tryInkLine(.times(4))
        document.undoManager.undo()
        assertLines(document.loadedInk(first), before)
        try? await Task.sleep(for: .seconds(0.6))
        assertLines(canvas.ink, before, "the page shows what the document holds")
        XCTAssertEqual(editor.session.inkSelectionCount, 3)
        assertBox(try box(in: editor), InkLasso.box(of: caught, drawings: [first: before], frames: editor.frames))
    }

    // MARK: Ways out of a trial

    func testATrialIsSettledWhenItsInkIsLetGoOrWorkedOn() async throws {
        let board = UIPasteboard.withUniqueName()
        InkClipboard.pasteboard = board
        addTeardownBlock { @MainActor in
            InkClipboard.pasteboard = .general
            UIPasteboard.remove(withName: board.name)
        }
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200)])])
        let document = editor.document, controller = editor.controller, session = editor.session, toolbox = editor.toolbox, first = editor.page(0)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), caught: InkSelection = [first: [0, 1]]
        /// Catches the two lines, tries them half as broad again, and gives back how the page should end up.
        func trial() throws -> PKDrawing {
            controller.catchInk(inside: everything)
            XCTAssertEqual(session.inkSelectionCount, 2)
            let broad = try XCTUnwrap(InkRestyle.lined(caught, .times(1.5), in: [first: try XCTUnwrap(document.loadedInk(first))])[first])
            controller.tryInkLine(.times(1.5))
            assertLines(canvas.ink, broad)
            return broad
        }
        func assertSettled(_ broad: PKDrawing, _ message: String, line: UInt = #line) {
            assertLines(document.loadedInk(first), broad, message, line: line)
            assertLines(canvas.ink, document.loadedInk(first), "the page shows what the document holds. " + message, line: line)
        }

        var broad = try trial(), taken = document.undoManager.registrations
        step(editor) { controller.clearInkSelection() }
        assertSettled(broad, "Done, or a tap away, keeps the line that was showing")
        XCTAssertEqual(document.undoManager.registrations, taken + 1)
        XCTAssertEqual(document.undoManager.undoActionName, "Change Ink Width")
        XCTAssertEqual(session.inkSelectionCount, 0)
        XCTAssertNil(session.inkLook)

        broad = try trial()
        try step(editor) { toolbox.take(.pen(try XCTUnwrap(toolbox.shelf.usable.first).id)) }
        assertSettled(broad, "so does taking a pen from the tray")
        XCTAssertEqual(session.inkSelectionCount, 0)
        toolbox.take(.lasso)

        broad = try trial()
        step(editor) { controller.catchInk(inside: upperTwo) }
        assertSettled(broad, "and a new lasso")

        broad = try trial()
        taken = document.undoManager.registrations
        try step(editor) { try grip(.bottomRight, in: editor).accessibilityIncrement() }
        XCTAssertEqual(document.undoManager.registrations, taken + 2, "a handle settles the line and then shapes the ink")
        XCTAssertEqual(document.undoManager.undoActionName, "Resize Ink")
        XCTAssertEqual(session.inkSelectionCount, 2)
        for (shaped, tried) in zip(widths(document.loadedInk(first)), widths(broad)) {
            XCTAssertEqual(shaped, tried * 1.1, accuracy: 1e-6, "a tenth larger, the lines are a tenth broader than they were showing")
        }
        assertLines(canvas.ink, document.loadedInk(first))

        broad = try trial()
        step(editor) { controller.copyInkSelection() }
        assertSettled(broad, "copied, the ink is as it was showing")
        assertLines(InkClipboard.ink(), PKDrawing(strokes: Array(broad.strokes[0...1])), "on the clipboard too", within: 0.05)
        XCTAssertEqual(session.inkSelectionCount, 2)

        broad = try trial()
        step(editor) { controller.duplicateInkSelection() }
        XCTAssertEqual(document.loadedInk(first)?.strokes.count, 4)
        assertLines(document.loadedInk(first), PKDrawing(strokes: broad.strokes + broad.strokes), "its copies are as broad as it was showing")
        assertLines(canvas.ink, document.loadedInk(first))
    }

    func testLeavingTheEditorSettlesATrialAndItsViewGoingAwayDropsOne() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200)])])
        let document = editor.document, controller = editor.controller, first = editor.page(0)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), caught: InkSelection = [first: [0, 1]]
        controller.catchInk(inside: everything)
        for name in [UIScene.willDeactivateNotification, Notification.Name.owlLunaCloseEditor] {
            let broad = InkRestyle.lined(caught, .times(1.5), in: [first: try XCTUnwrap(document.loadedInk(first))])[first]
            controller.tryInkLine(.times(1.5))
            step(editor) { NotificationCenter.default.post(name: name, object: nil) }
            assertLines(document.loadedInk(first), broad, "\(name.rawValue) keeps the line that was showing")
            assertLines(canvas.ink, broad)
            XCTAssertEqual(document.undoManager.undoActionName, "Change Ink Width")
            XCTAssertEqual(editor.session.inkSelectionCount, 2)
        }

        let saved = try XCTUnwrap(document.loadedInk(first)), taken = document.undoManager.registrations
        controller.tryInkLine(.times(1.5))
        XCTAssertFalse(linesMatch(canvas.ink, saved))
        controller.viewWillDisappear(false)
        assertLines(document.loadedInk(first), saved, "nothing is written once the editor's view is on its way out")
        assertLines(canvas.ink, saved, "and the page shows what was saved")
        XCTAssertEqual(document.undoManager.registrations, taken)
    }

    func testLeavingSelectModeSettlesATrial() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200)])])
        let document = editor.document, controller = editor.controller, session = editor.session, first = editor.page(0)
        let pen = try XCTUnwrap(editor.toolbox.shelf.usable.first)
        editor.toolbox.take(.pen(pen.id))
        session.enter(.selecting)
        controller.catchInk(inside: everything)
        XCTAssertEqual(session.inkSelectionCount, 2)
        let broad = InkRestyle.lined([first: [0, 1]], .width(9), in: [first: try XCTUnwrap(document.loadedInk(first))])[first]
        controller.tryInkLine(.width(9))
        step(editor) { session.enter(.writing) }
        assertLines(document.loadedInk(first), broad)
        assertLines(controller.canvas(forPage: 0)?.ink, broad)
        XCTAssertEqual(session.inkSelectionCount, 0)
    }

    func testAnUndoOrAPageRemovedDropsATrial() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200)]), PKDrawing(strokes: [line(y: 300)])], pages: 3)
        let document = editor.document, controller = editor.controller, session = editor.session, first = editor.page(0), second = editor.page(1)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), before = try XCTUnwrap(document.loadedInk(first))
        controller.catchInk(inside: upperTwo)
        XCTAssertEqual(session.inkSelectionCount, 2)
        step(editor) { controller.tintInkSelection(red) }
        let snug = try box(in: editor), taken = document.undoManager.registrations

        controller.tryInkLine(.times(2))
        XCTAssertFalse(linesMatch(canvas.ink, before))
        document.undoManager.undo()
        XCTAssertEqual(tints(document.loadedInk(first)), [black, black])
        assertLines(document.loadedInk(first), before, "an undo arriving lets the tried line go: it was never the document's")
        assertLines(canvas.ink, before)
        XCTAssertEqual(tints(canvas.ink), [black, black])
        XCTAssertEqual(session.inkSelectionCount, 2, "the ink stays caught, as the undo only took its colour back")
        assertBox(try box(in: editor), snug, "in a box round the lines as they are")
        controller.settleInkLine()
        XCTAssertEqual(document.undoManager.registrations, taken + 1, "nothing is left to settle, and only the undo's own step was taken on")

        controller.tryInkLine(.times(2))
        document.undoManager.redo()
        XCTAssertEqual(tints(canvas.ink), [red, red])
        assertLines(canvas.ink, before, "a redo does the same")

        controller.tryInkLine(.times(2))
        XCTAssertFalse(linesMatch(canvas.ink, before))
        let steps = document.undoManager.registrations
        step(editor) { document.removePages([editor.page(2)]) }
        assertLines(document.loadedInk(first), before, "a page removed lets the tried line go")
        assertLines(controller.canvas(forPage: 0)?.ink, before)
        XCTAssertEqual(document.undoManager.registrations, steps + 1, "with only the removal as a step")
        XCTAssertEqual(session.inkSelectionCount, 2, "what is caught on the pages that are left stays caught")

        controller.tryInkLine(.times(2))
        step(editor) { document.removePages([first]) }
        XCTAssertEqual(session.inkSelectionCount, 0, "and goes with its page")
        XCTAssertNil(session.inkLook)
        document.undoManager.undo()
        assertLines(document.loadedInk(first), before, "the page comes back with its lines as they were")
        for _ in 0..<200 where controller.canvas(forPage: 0)?.isLoaded != true { try? await Task.sleep(for: .seconds(0.05)) }
        assertLines(controller.canvas(forPage: 0)?.ink, before)
        XCTAssertEqual(document.loadedInk(second)?.strokes.count, 1)
    }

    func testATrialOutlastsAZoomAndACanvasMadeMeanwhileShowsIt() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200)])], pages: 6)
        let document = editor.document, controller = editor.controller, session = editor.session, first = editor.page(0)
        let before = try XCTUnwrap(document.loadedInk(first)), caught: InkSelection = [first: [0, 1]]
        let broad = InkRestyle.lined(caught, .times(2), in: [first: before])[first], taken = document.undoManager.registrations
        controller.catchInk(inside: everything)
        controller.tryInkLine(.times(2))

        controller.setZoom(2)
        let scroll = try XCTUnwrap(controller.view.subviews.lazy.compactMap { $0 as? UIScrollView }.first)
        scroll.zoomScale = 0.7
        controller.scrollViewDidEndZooming(scroll, with: nil, atScale: 0.7)
        assertLines(controller.canvas(forPage: 0)?.ink, broad, "a pinch and the pages drawn again at the new zoom leave the tried line showing")
        assertLines(document.loadedInk(first), before)
        controller.setZoom(1)

        session.go(to: 5, animated: false)
        XCTAssertNil(controller.canvas(forPage: 0), "scrolled far off, the page has no canvas")
        session.go(to: 0, animated: false)
        for _ in 0..<200 where controller.canvas(forPage: 0)?.isLoaded != true { try? await Task.sleep(for: .seconds(0.05)) }
        assertLines(controller.canvas(forPage: 0)?.ink, broad, "the canvas made for it when it comes back shows the tried line")
        assertLines(document.loadedInk(first), before)
        XCTAssertEqual(document.undoManager.registrations, taken)

        session.go(to: 5, animated: false)
        step(editor) { controller.settleInkLine() }
        assertLines(document.loadedInk(first), broad, "and the line is settled from wherever the pages have scrolled to")
        document.undoManager.undo()
        session.go(to: 0, animated: false)
        for _ in 0..<200 where controller.canvas(forPage: 0)?.isLoaded != true { try? await Task.sleep(for: .seconds(0.05)) }
        assertLines(controller.canvas(forPage: 0)?.ink, before)
        XCTAssertEqual(session.inkSelectionCount, 2)
    }

    // MARK: Two pages, the zoom window and a notebook that can't be changed

    func testInkCaughtOnTwoPagesIsRestyledAsOneStep() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 700)]), PKDrawing(strokes: [line(y: 80, width: 6)])])
        let document = editor.document, controller = editor.controller, session = editor.session, first = editor.page(0), second = editor.page(1)
        let before = [first: try XCTUnwrap(document.loadedInk(first)), second: try XCTUnwrap(document.loadedInk(second))]
        // From the lower line of the first page to the line on the second.
        controller.catchInk(inside: [CGPoint(x: 96, y: 680), CGPoint(x: 336, y: 680), CGPoint(x: 336, y: 960), CGPoint(x: 96, y: 960)])
        let caught: InkSelection = [first: [1], second: [0]]
        XCTAssertEqual(session.inkSelectionCount, 2)
        XCTAssertEqual(session.inkLook, InkRestyle.look(of: [before[first]!.strokes[1], before[second]!.strokes[0]]))
        let taken = document.undoManager.registrations

        step(editor) { controller.tintInkSelection(red) }
        XCTAssertEqual(tints(document.loadedInk(first)), [black, red])
        XCTAssertEqual(tints(document.loadedInk(second)), [red])
        XCTAssertEqual(tints(controller.canvas(forPage: 1)?.ink), [red])
        XCTAssertEqual(document.undoManager.registrations, taken + 1, "both pages in one undo step")

        let broad = InkRestyle.lined(caught, .width(8), in: before)
        controller.tryInkLine(.width(8))
        assertLines(controller.canvas(forPage: 0)?.ink, broad[first])
        assertLines(controller.canvas(forPage: 1)?.ink, broad[second])
        assertLines(document.loadedInk(second), before[second])
        step(editor) { controller.settleInkLine() }
        assertLines(document.loadedInk(first), broad[first])
        assertLines(document.loadedInk(second), broad[second])
        XCTAssertEqual(document.undoManager.registrations, taken + 2)
        XCTAssertEqual(session.inkSelectionCount, 2)
        assertBox(try box(in: editor), InkLasso.box(of: caught, drawings: broad, frames: editor.frames))

        document.undoManager.undo()
        assertLines(document.loadedInk(first), before[first], "one undo takes the line back on both pages")
        assertLines(document.loadedInk(second), before[second])
        XCTAssertEqual(session.inkSelectionCount, 2, "and leaves both caught")
        document.undoManager.undo()
        XCTAssertEqual(tints(document.loadedInk(first)) + tints(document.loadedInk(second)), [black, black, black])
        XCTAssertEqual(session.inkSelectionCount, 2)
        XCTAssertEqual(session.inkLook?.tints, [black])

        // An undo that changes which strokes a caught page holds lets the ink go.
        step(editor) { controller.duplicateInkSelection() }
        XCTAssertEqual(session.inkSelectionCount, 2)
        document.undoManager.undo()
        XCTAssertEqual(session.inkSelectionCount, 0)
    }

    func testTheZoomWindowFollowsATintAndASettledLine() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200)])])
        let document = editor.document, controller = editor.controller, session = editor.session, first = editor.page(0)
        let before = try XCTUnwrap(document.loadedInk(first)), caught: InkSelection = [first: [0, 1]]
        session.setZoomWindow(true)
        XCTAssertTrue(session.isZoomWindowOpen)
        let strip = try XCTUnwrap(find(PageCanvasView.self, in: controller.view) { $0.accessibilityIdentifier == "zoom.canvas" })
        for _ in 0..<200 where !strip.isLoaded { try? await Task.sleep(for: .seconds(0.05)) }
        controller.catchInk(inside: everything)
        XCTAssertEqual(session.inkSelectionCount, 2)

        step(editor) { controller.tintInkSelection(red) }
        XCTAssertEqual(tints(strip.ink), [red, red], "the strip shows the page's new colour")
        let broad = InkRestyle.lined(caught, .times(2), in: [first: before])[first]
        controller.tryInkLine(.times(2))
        assertLines(controller.canvas(forPage: 0)?.ink, broad)
        assertLines(strip.ink, before, "a line only tried is not the strip's to show: what is written there is saved from it")
        step(editor) { controller.settleInkLine() }
        assertLines(strip.ink, broad, "settled, it is")

        // Ink written in the strip while a line is being tried goes to the page as it is, and the trial is let go.
        controller.tryInkLine(.times(0.5))
        let written = line(y: 400)
        document.undoManager.beginUndoGrouping()
        strip.drawing = PKDrawing(strokes: strip.ink.strokes + [written])
        await wait { document.loadedInk(first)?.strokes.count == 3 }
        document.undoManager.endUndoGrouping()
        XCTAssertEqual(document.loadedInk(first)?.strokes.count, 3)
        assertLines(document.loadedInk(first), PKDrawing(strokes: (broad?.strokes ?? []) + [written]))
        assertLines(controller.canvas(forPage: 0)?.ink, document.loadedInk(first), "the page shows what the document holds")
        XCTAssertEqual(session.inkSelectionCount, 0)
    }

    func testAReadOnlyNotebookIsLeftAsItIs() async throws {
        let editor = try await openEditor(ink: [PKDrawing(strokes: [line(y: 100), line(y: 200)])], future: true)
        let document = editor.document, controller = editor.controller, first = editor.page(0)
        XCTAssertTrue(document.isReadOnly)
        let before = try XCTUnwrap(document.loadedInk(first))
        controller.setSelectingInk(true)
        controller.catchInk(inside: everything)
        XCTAssertEqual(editor.session.inkSelectionCount, 2, "its ink can be caught, to be copied")
        XCTAssertNotNil(editor.session.inkLook)
        let taken = document.undoManager.registrations
        controller.tintInkSelection(red)
        controller.tryInkLine(.times(2))
        controller.settleInkLine()
        XCTAssertEqual(tints(document.loadedInk(first)), [black, black])
        assertLines(document.loadedInk(first), before)
        assertLines(controller.canvas(forPage: 0)?.ink, before, "not even a trial is shown")
        XCTAssertEqual(document.undoManager.registrations, taken)
        XCTAssertFalse(document.undoManager.canUndo)
    }
}
