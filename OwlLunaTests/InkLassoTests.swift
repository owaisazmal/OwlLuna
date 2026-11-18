import XCTest
import PencilKit
import UniformTypeIdentifiers
@testable import OwlLuna

/// Selecting ink across pages and moving it between them.
@MainActor
final class InkLassoTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)

    private func line(y: CGFloat) -> PKStroke {
        stroke(from: CGPoint(x: 100, y: y), to: CGPoint(x: 300, y: y))
    }

    func testALoopCatchesTheInkInsideItAndAStraightDragIsABox() {
        let drawing = PKDrawing(strokes: [line(y: 100), line(y: 200), line(y: 400)])
        let loop = [CGPoint(x: 60, y: 60), CGPoint(x: 340, y: 60), CGPoint(x: 360, y: 250), CGPoint(x: 50, y: 240)]
        XCTAssertEqual(InkLasso.strokes(in: drawing, inside: loop), [0, 1])
        XCTAssertTrue(InkLasso.contains(loop, CGPoint(x: 200, y: 150)))
        XCTAssertFalse(InkLasso.contains(loop, CGPoint(x: 200, y: 300)))

        let half = [CGPoint(x: 60, y: 60), CGPoint(x: 180, y: 60), CGPoint(x: 180, y: 250), CGPoint(x: 60, y: 250)]
        XCTAssertEqual(InkLasso.strokes(in: drawing, inside: half), [], "a stroke only partly inside is left out")

        let drag = (0...20).map { CGPoint(x: 60 + CGFloat($0) * 14, y: 380 + CGFloat($0) * 2) }
        let box = InkLasso.outline(from: drag)
        XCTAssertEqual(box.count, 4, "a straight drag is the diagonal of a box")
        XCTAssertEqual(InkLasso.strokes(in: drawing, inside: box), [2])
        XCTAssertEqual(InkLasso.outline(from: loop + [loop[0]]).count, 5, "a loop is used as drawn")
        XCTAssertTrue(InkLasso.outline(from: [CGPoint(x: 1, y: 1)]).isEmpty)
    }

    func testInkMovesToThePageItLandsOn() throws {
        let first = UUID(), second = UUID(), far = UUID()
        let frames = [first: CGRect(x: 16, y: 16, width: 612, height: 792), second: CGRect(x: 16, y: 824, width: 612, height: 792),
                      far: CGRect(x: 16, y: 1632, width: 612, height: 792)]
        let drawings = [first: PKDrawing(strokes: [line(y: 100), line(y: 700), line(y: 750)]), second: PKDrawing(strokes: [line(y: 50)])]
        let selection: InkSelection = [first: [1, 2]]
        XCTAssertEqual(InkLasso.bounds(of: selection, drawings: drawings, frames: frames)?.midX ?? 0, 216, accuracy: 4)

        let nudged = InkLasso.moved(selection, by: CGSize(width: 30, height: -40), drawings: drawings, frames: frames)
        XCTAssertEqual(nudged.drawings.keys.sorted { $0.uuidString < $1.uuidString }, [first], "a move within a page touches only that page")
        XCTAssertEqual(nudged.selection, [first: [1, 2]])
        XCTAssertEqual(try XCTUnwrap(nudged.drawings[first]).strokes[1].renderBounds.midY, 660, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(nudged.drawings[first]).strokes[0].renderBounds.midY, 100, accuracy: 2, "ink that wasn't selected stays put")

        let carried = InkLasso.moved(selection, by: CGSize(width: 0, height: 150), drawings: drawings, frames: frames)
        let onFirst = try XCTUnwrap(carried.drawings[first]), onSecond = try XCTUnwrap(carried.drawings[second])
        XCTAssertEqual(onFirst.strokes.count, 1)
        XCTAssertEqual(onSecond.strokes.count, 3, "ink dragged onto the next page becomes that page's ink")
        XCTAssertEqual(carried.selection, [second: [1, 2]])
        XCTAssertEqual(onSecond.strokes[1].renderBounds.midY, 700 + 150 - 808, accuracy: 2, "at the place on that page it was dropped")
        XCTAssertEqual(onSecond.strokes[0].renderBounds.midY, 50, accuracy: 2)

        let gap = InkLasso.moved([first: [2]], by: CGSize(width: 0, height: 46), drawings: drawings, frames: frames)
        XCTAssertNil(gap.drawings[second], "dropped in the gap between pages, ink stays on the nearer page")
        let unloaded = InkLasso.moved([second: [0]], by: CGSize(width: 0, height: 900), drawings: drawings, frames: frames)
        XCTAssertEqual(unloaded.selection, [second: [0]], "a page whose ink isn't in memory isn't written to")

        let copied = InkLasso.moved(selection, by: CGSize(width: 18, height: 18), copying: true, drawings: drawings, frames: frames)
        XCTAssertEqual(copied.drawings[first]?.strokes.count, 5)
        XCTAssertEqual(copied.selection, [first: [3, 4]], "the copies are what is selected afterwards")
        XCTAssertEqual(InkLasso.removing(selection, from: drawings)[first]?.strokes.count, 1)
    }

    func testAMoveAcrossPagesIsOneUndoStep() async throws {
        let root = temporaryRoot(self)
        let manifest = NotebookManifest(title: "Notes", defaults: paper, pages: [paper.newPage(), paper.newPage()])
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        let first = manifest.pages[0].id, second = manifest.pages[1].id
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: [first: PKDrawing(strokes: [line(y: 100), line(y: 700)])]))
        let document = try await NotebookDocument.open(manifest.id, root: root)
        document.undoManager.groupsByEvent = false
        let before = await document.ink(first)
        XCTAssertFalse(document.updateInk([second: PKDrawing()], actionName: "Move Ink"), "a page whose ink isn't loaded leaves the change undone")
        _ = await document.ink(second)

        let frames = [first: CGRect(x: 16, y: 16, width: 612, height: 792), second: CGRect(x: 16, y: 824, width: 612, height: 792)]
        let moved = InkLasso.moved([first: [1]], by: CGSize(width: 0, height: 200), drawings: [first: before, second: PKDrawing()], frames: frames)
        document.undoManager.beginUndoGrouping()
        XCTAssertTrue(document.updateInk(moved.drawings, actionName: "Move Ink"))
        document.undoManager.endUndoGrouping()
        XCTAssertEqual(document.loadedInk(first)?.strokes.count, 1)
        XCTAssertEqual(document.loadedInk(second)?.strokes.count, 1)
        XCTAssertEqual(document.undoManager.undoActionName, "Move Ink")
        XCTAssertTrue(document.hasUnsavedInk(first) && document.hasUnsavedInk(second))

        document.undoManager.undo()
        XCTAssertEqual(document.loadedInk(first)?.strokes.count, 2, "one undo puts both pages back")
        XCTAssertEqual(document.loadedInk(second)?.strokes.count, 0)
        document.undoManager.redo()
        XCTAssertEqual(document.loadedInk(second)?.strokes.count, 1)
        let saved = await document.flush()
        XCTAssertTrue(saved)
        guard case .ink(let reread, _) = await package.readInk(second) else { return XCTFail("the moved ink wasn't saved on its new page") }
        XCTAssertEqual(reread.strokes.count, 1)
    }

    // MARK: The tray's lasso

    private let everything = [CGPoint(x: -5000, y: -5000), CGPoint(x: 5000, y: -5000), CGPoint(x: 5000, y: 5000), CGPoint(x: -5000, y: 5000)]

    /// An editor in a window, on blank pages with `ink` on the first, with a toolbox of its own.
    private func openEditor(pages count: Int, ink: PKDrawing, toolbox: Toolbox) async throws -> (session: EditorSession, controller: PageStackController) {
        let flow = UserDefaults.standard.object(forKey: SettingsKey.pageFlow)
        UserDefaults.standard.set(PageFlow.continuous.rawValue, forKey: SettingsKey.pageFlow)
        addTeardownBlock { UserDefaults.standard.set(flow, forKey: SettingsKey.pageFlow) }
        let root = temporaryRoot(self)
        let manifest = NotebookManifest(title: "Notes", defaults: paper, pages: (0..<count).map { _ in paper.newPage() })
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[0].id: ink]))
        let session = EditorSession(document: try await NotebookDocument.open(manifest.id, root: root))
        let controller = PageStackController(session: session, toolbox: toolbox)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where controller.canvas(forPage: 0)?.isLoaded != true { try? await Task.sleep(for: .seconds(0.05)) }
        return (session, controller)
    }

    /// Issue 39: PencilKit's lasso lost what it had caught whenever a page was drawn again at a new zoom.
    func testTheTraysLassoKeepsItsInkThroughAZoomAndLocksNothing() async throws {
        let toolbox = Toolbox(defaults: nil)
        let (session, controller) = try await openEditor(pages: 2, ink: PKDrawing(strokes: [line(y: 100), line(y: 200)]), toolbox: toolbox)
        let document = session.document, first = document.pages[0].id
        controller.catchInk(inside: everything)
        XCTAssertEqual(session.inkSelectionCount, 0, "a pen in hand catches nothing")

        toolbox.take(.lasso)
        controller.catchInk(inside: everything)
        XCTAssertEqual(session.inkSelectionCount, 2)
        XCTAssertEqual(session.mode, .writing, "the lasso is a tool in hand, not a mode")
        XCTAssertTrue(session.showsToolTray)
        session.setZoomWindow(true)
        XCTAssertTrue(session.isZoomWindowOpen, "and the pages stay unlocked: the zoom window still opens")
        session.setZoomWindow(false)
        XCTAssertEqual(session.inkSelectionCount, 2)

        controller.setZoom(2)
        XCTAssertEqual(session.inkSelectionCount, 2, "a new zoom keeps what was caught")
        let scroll = try XCTUnwrap(controller.view.subviews.lazy.compactMap { $0 as? UIScrollView }.first)
        scroll.zoomScale = 0.7
        controller.scrollViewDidEndZooming(scroll, with: nil, atScale: 0.7)
        XCTAssertEqual(controller.zoom, 1.4, accuracy: 0.01)
        XCTAssertEqual(session.inkSelectionCount, 2, "and so does a pinch")
        controller.duplicateInkSelection()
        XCTAssertEqual(document.loadedInk(first)?.strokes.count, 4, "it can still be worked on")
        XCTAssertEqual(session.inkSelectionCount, 2)

        session.enter(.presenting)
        XCTAssertEqual(session.inkSelectionCount, 0, "presenting lets it go")
        controller.catchInk(inside: everything)
        XCTAssertEqual(session.inkSelectionCount, 0, "and nothing is caught while the pages are locked")
        session.enter(.writing)
        controller.catchInk(inside: everything)
        XCTAssertEqual(session.inkSelectionCount, 4, "the lasso is back in hand afterwards")
        toolbox.take(.pen(try XCTUnwrap(toolbox.shelf.usable.first).id))
        XCTAssertEqual(session.inkSelectionCount, 0, "taking a pen up lets it go")
    }

    /// Only the pages on show and the ones beside them have a canvas, so ink carried further has to outlast its page's.
    func testInkTheLassoCaughtOutlastsItsPagesCanvas() async throws {
        let toolbox = Toolbox(defaults: nil)
        toolbox.take(.lasso)
        let (session, controller) = try await openEditor(pages: 6, ink: PKDrawing(strokes: [line(y: 100), line(y: 200)]), toolbox: toolbox)
        let document = session.document, first = document.pages[0].id
        // The lasso was in hand before the notebook opened: it is ready once the pages have appeared.
        for _ in 0..<40 where session.inkSelectionCount == 0 {
            controller.catchInk(inside: everything)
            try? await Task.sleep(for: .seconds(0.05))
        }
        XCTAssertEqual(session.inkSelectionCount, 2)

        session.go(to: 5, animated: false)
        XCTAssertNil(controller.canvas(forPage: 0), "scrolled far off, the page has no canvas")
        XCTAssertEqual(session.inkSelectionCount, 2, "what was caught on it is still caught")
        document.releaseCleanInk()
        XCTAssertNotNil(document.loadedInk(first), "and its ink stays in memory meanwhile")
        controller.deleteInkSelection()
        XCTAssertEqual(document.loadedInk(first)?.strokes.count, 0, "so it can still be changed from there")
        XCTAssertEqual(session.inkSelectionCount, 0)
    }

    // MARK: Ink on the clipboard

    func testCaughtInkIsCopiedCutAndPastedAsInk() async throws {
        let board = UIPasteboard.withUniqueName()
        InkClipboard.pasteboard = board
        addTeardownBlock { @MainActor in
            InkClipboard.pasteboard = .general
            UIPasteboard.remove(withName: board.name)
        }
        let toolbox = Toolbox(defaults: nil)
        let pen = toolbox.choice
        let (session, controller) = try await openEditor(pages: 2, ink: PKDrawing(strokes: [line(y: 100), line(y: 200)]), toolbox: toolbox)
        let document = session.document, first = document.pages[0].id, second = document.pages[1].id
        for _ in 0..<100 where controller.canvas(forPage: 1)?.isLoaded != true { try? await Task.sleep(for: .seconds(0.05)) }
        XCTAssertFalse(controller.canPasteInk, "nothing is on the clipboard yet")

        // The first page stands 16 points into the stack: this box holds its upper line only.
        toolbox.take(.lasso)
        controller.catchInk(inside: [CGPoint(x: 96, y: 96), CGPoint(x: 336, y: 96), CGPoint(x: 336, y: 136), CGPoint(x: 96, y: 136)])
        XCTAssertEqual(session.inkSelectionCount, 1)
        controller.copyInkSelection()
        XCTAssertEqual(InkClipboard.ink()?.strokes.count, 1)
        XCTAssertTrue(board.contains(pasteboardTypes: [UTType.png.identifier]), "a picture of it goes along for other apps")
        XCTAssertEqual(document.loadedInk(first)?.strokes.count, 2, "copying leaves the page as it was")
        XCTAssertTrue(controller.canPasteInk)

        toolbox.take(pen)
        XCTAssertTrue(controller.pasteInk())
        XCTAssertEqual(document.loadedInk(first)?.strokes.count, 3)
        XCTAssertEqual(document.undoManager.undoActionName, "Paste Ink")
        XCTAssertEqual(toolbox.choice, .lasso, "pasted ink is caught, so the lasso is taken up")
        XCTAssertEqual(session.inkSelectionCount, 1)
        let shown = try XCTUnwrap(controller.visibleCenter(ofPage: 0)), pasted = try XCTUnwrap(document.loadedInk(first)?.strokes.last)
        XCTAssertEqual(pasted.renderBounds.midX, shown.x, accuracy: 2, "it lands in the middle of what shows of the page")
        XCTAssertEqual(pasted.renderBounds.midY, shown.y, accuracy: 2)

        controller.cutInkSelection()
        XCTAssertEqual(document.loadedInk(first)?.strokes.count, 2, "cutting takes the copy off again")
        XCTAssertEqual(document.undoManager.undoActionName, "Cut Ink")
        XCTAssertEqual(session.inkSelectionCount, 0)
        XCTAssertEqual(InkClipboard.ink()?.strokes.count, 1, "and leaves it on the clipboard")

        XCTAssertTrue(controller.pasteInk(at: CGPoint(x: 16 + 300, y: 824 + 400)))
        let landed = try XCTUnwrap(document.loadedInk(second)?.strokes.last)
        XCTAssertEqual(document.loadedInk(second)?.strokes.count, 1, "pasted at a point, it goes on the page under that point")
        XCTAssertEqual(landed.renderBounds.midX, 300, accuracy: 2)
        XCTAssertEqual(landed.renderBounds.midY, 400, accuracy: 2)
        XCTAssertEqual(session.inkSelectionCount, 1)

        let action = try XCTUnwrap(controller.canvas(forPage: 0)?.accessibilityCustomActions?.first { $0.name == "Paste" }, "VoiceOver pastes from the page itself")
        XCTAssertTrue(action.actionHandler?(action) ?? false)
        XCTAssertEqual(document.loadedInk(first)?.strokes.count, 3)

        session.enter(.presenting)
        XCTAssertFalse(controller.canPasteInk, "nothing is pasted while the pages are locked")
        XCTAssertFalse(controller.pasteInk())
    }

    /// Issue 41: a picture copied elsewhere goes where the paper was held, or becomes a page before or after that one.
    func testACopiedPictureIsPastedOnThePageOrAsAPageBesideIt() async throws {
        let board = UIPasteboard.withUniqueName()
        InkClipboard.pasteboard = board
        addTeardownBlock { @MainActor in
            InkClipboard.pasteboard = .general
            UIPasteboard.remove(withName: board.name)
        }
        let (session, controller) = try await openEditor(pages: 2, ink: PKDrawing(), toolbox: Toolbox(defaults: nil))
        let document = session.document, first = document.pages[0].id, second = document.pages[1].id
        let held = CGPoint(x: 16 + 300, y: 16 + 400)
        func pasteAction() -> UIAccessibilityCustomAction? {
            controller.canvas(forPage: 0)?.accessibilityCustomActions?.first { $0.name == "Paste Picture" }
        }
        XCTAssertFalse(controller.pastePicture(at: held), "nothing is on the clipboard yet")
        XCTAssertNil(pasteAction())

        board.image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        XCTAssertTrue(controller.pastePicture(at: held))
        await document.finishPendingWork()
        let placed = try XCTUnwrap(document.pages[0].items.first)
        XCTAssertNotNil(placed.assetFile)
        XCTAssertEqual(placed.center.x, 300, accuracy: 1, "it lands where the paper was held")
        XCTAssertEqual(placed.center.y, 400, accuracy: 1)
        XCTAssertEqual(placed.size.width / placed.size.height, 2, accuracy: 0.05)
        XCTAssertEqual(session.selection, ItemSelection(pageID: first, itemID: placed.id), "picked up, ready to move")

        XCTAssertTrue(controller.pastePicture(at: held, placing: .pageAfter))
        await document.finishPendingWork()
        XCTAssertEqual(document.pages.map(\.id).filter { $0 == first || $0 == second }, [first, second])
        XCTAssertEqual(document.pages.count, 3)
        XCTAssertEqual(document.pages[2].id, second, "the new page stands between the two")
        guard case .image = document.pages[1].background else { return XCTFail("the picture is the new page's paper") }
        XCTAssertEqual(document.pages[1].size, CGSize(width: 612, height: 306), "as wide as a letter page, in the picture's shape")
        XCTAssertEqual(document.undoManager.undoActionName, "Paste Picture")
        XCTAssertEqual(session.currentPage, 1)

        XCTAssertTrue(controller.pastePicture(at: held, placing: .pageBefore))
        await document.finishPendingWork()
        XCTAssertEqual(document.pages.count, 4)
        XCTAssertEqual(document.pages[1].id, first, "pasted before the page that was held")
        document.undoManager.undo()
        XCTAssertEqual(document.pages.count, 3, "one Undo takes the page away")

        session.go(to: 0, animated: false)
        let action = try XCTUnwrap(pasteAction(), "VoiceOver pastes from the page itself")
        XCTAssertTrue(action.actionHandler?(action) ?? false)
        await document.finishPendingWork()
        XCTAssertEqual(document.pages[0].items.count, 2)

        session.enter(.presenting)
        XCTAssertFalse(controller.pastePicture(at: held), "nothing is pasted while the pages are locked")
        XCTAssertNil(pasteAction())
    }

    func testPastedInkIsKeptOnThePage() {
        let size = CGSize(width: 612, height: 792), ink = PKDrawing(strokes: [line(y: 100), line(y: 140)])
        let corner = PKDrawing(strokes: InkClipboard.placed(ink, at: CGPoint(x: 5, y: 790), onPageOf: size))
        XCTAssertEqual(corner.strokes.count, 2)
        XCTAssertGreaterThanOrEqual(corner.bounds.minX, -0.5, "ink pasted by an edge is moved in from it")
        XCTAssertLessThanOrEqual(corner.bounds.maxY, 792.5)
        XCTAssertEqual(corner.bounds.height, ink.bounds.height, accuracy: 0.5, "and keeps its shape")
        let wide = PKDrawing(strokes: [stroke(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 900, y: 50))])
        let centred = PKDrawing(strokes: InkClipboard.placed(wide, at: CGPoint(x: 100, y: 300), onPageOf: size))
        XCTAssertEqual(centred.bounds.midX, 306, accuracy: 1, "ink wider than the page is centred on it")
    }

    // MARK: The box and its handles

    private func assertBox(_ box: InkBox, center: CGPoint, size: CGSize, turn: CGFloat = 0, _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(box.center.x, center.x, accuracy: 0.01, message, line: line)
        XCTAssertEqual(box.center.y, center.y, accuracy: 0.01, message, line: line)
        XCTAssertEqual(box.size.width, size.width, accuracy: 0.01, message, line: line)
        XCTAssertEqual(box.size.height, size.height, accuracy: 0.01, message, line: line)
        XCTAssertEqual(box.turn, turn, accuracy: 1e-6, message, line: line)
    }

    func testAHandleResizesStretchesOrTurnsFromTheFarSide() {
        let box = InkBox(center: CGPoint(x: 200, y: 150), size: CGSize(width: 200, height: 100))
        XCTAssertEqual(box.point(CGPoint(x: 1, y: 1)), CGPoint(x: 300, y: 200))
        XCTAssertTrue(box.contains(CGPoint(x: 105, y: 195)) && !box.contains(CGPoint(x: 95, y: 150)))
        XCTAssertTrue(box.contains(CGPoint(x: 95, y: 150), margin: 10))

        let larger = box.change(dragging: .bottomRight, from: CGPoint(x: 300, y: 200), to: CGPoint(x: 400, y: 250), most: 2000)
        XCTAssertTrue(larger.isEven, "a tab resizes the ink evenly")
        assertBox(box.applying(larger), center: CGPoint(x: 250, y: 175), size: CGSize(width: 300, height: 150), "from the opposite corner")
        let wider = box.change(dragging: .right, from: CGPoint(x: 300, y: 150), to: CGPoint(x: 400, y: 170), most: 2000)
        XCTAssertFalse(wider.isEven)
        assertBox(box.applying(wider), center: CGPoint(x: 250, y: 150), size: CGSize(width: 300, height: 100), "a bar stretches one way from the opposite side")
        let taller = box.change(dragging: .top, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 200, y: 50), most: 2000)
        assertBox(box.applying(taller), center: CGPoint(x: 200, y: 125), size: CGSize(width: 200, height: 150))

        let quarter = box.change(dragging: .knob, from: CGPoint(x: 200, y: 60), to: CGPoint(x: 290, y: 150), most: 2000)
        assertBox(box.applying(quarter), center: box.center, size: box.size, turn: .pi / 2, "the knob turns the ink about its middle")
        let nearly = box.change(dragging: .knob, from: CGPoint(x: 200, y: 60), to: CGPoint(x: 290, y: 147), most: 2000)
        XCTAssertEqual(box.applying(nearly).turn, .pi / 2, accuracy: 1e-9, "within three degrees of a quarter turn it settles on it")
        let sixth = box.change(dragging: .knob, from: CGPoint(x: 200, y: 60), to: CGPoint(x: 200 + 90 * sin(CGFloat.pi / 6), y: 150 - 90 * cos(CGFloat.pi / 6)), most: 2000)
        XCTAssertEqual(box.applying(sixth).turn, .pi / 6, accuracy: 1e-6)
        XCTAssertEqual(box.applying(sixth).turnedDegrees, 30)

        // A turned box is stretched along its own sides: its width now runs down the page.
        let turned = box.applying(quarter)
        XCTAssertEqual(turned.point(CGPoint(x: 1, y: 0.5)).y, 250, accuracy: 0.01)
        XCTAssertEqual(turned.bounds.width, 100, accuracy: 0.01)
        let longer = turned.change(dragging: .right, from: CGPoint(x: 200, y: 250), to: CGPoint(x: 200, y: 350), most: 2000)
        assertBox(turned.applying(longer), center: CGPoint(x: 200, y: 200), size: CGSize(width: 300, height: 100), turn: .pi / 2)

        let least = box.change(dragging: .bottomRight, from: CGPoint(x: 300, y: 200), to: .zero, most: 2000)
        XCTAssertEqual(box.applying(least).size.width, InkBox.leastSide, accuracy: 0.01, "dragged past the far corner, it stops at the least a box can be")
        let most = box.change(dragging: .bottomRight, from: CGPoint(x: 300, y: 200), to: CGPoint(x: 900, y: 500), most: 250)
        XCTAssertEqual(box.applying(most).size.width, 250, accuracy: 0.01, "and it grows no longer than it is allowed")
        XCTAssertTrue(box.isLeftAlone(by: box.change(dragging: .bottomRight, from: CGPoint(x: 300, y: 200), to: CGPoint(x: 300.2, y: 200.1), most: 2000)))
        XCTAssertFalse(box.isLeftAlone(by: larger))

        // The steps an assistive technology takes.
        assertBox(box.applying(box.change(stepping: .bottomRight, up: true, most: 2000)), center: box.center, size: CGSize(width: 220, height: 110))
        assertBox(box.applying(box.change(stepping: .right, up: false, most: 2000)), center: CGPoint(x: 100 + 100 / 1.1, y: 150), size: CGSize(width: 200 / 1.1, height: 100))
        XCTAssertEqual(box.applying(box.change(stepping: .knob, up: true, most: 2000)).turnedDegrees, 15)
        XCTAssertEqual(turned.applying(turned.change(stepping: .knob, up: false, most: 2000)).turnedDegrees, 75)
    }

    func testHandlesAreTakenFromOutsideABoxNoSmallerThanAFingertip() {
        let room = CGRect(x: 0, y: 0, width: 800, height: 1000)
        let layout = InkBoxLayout(InkBox(center: CGPoint(x: 100, y: 100), size: CGSize(width: 20, height: 10)), scale: 1, in: room)
        XCTAssertEqual(layout.box.size, CGSize(width: 44, height: 44), "a scrap of ink still has a box a finger can move it by")
        XCTAssertEqual(layout.center(of: .bottomRight), CGPoint(x: 130, y: 130))
        XCTAssertNil(layout.handle(at: CGPoint(x: 100, y: 100)), "inside the box the ink is moved")
        XCTAssertNil(layout.handle(at: CGPoint(x: 121, y: 121)))
        XCTAssertEqual(layout.handle(at: CGPoint(x: 131, y: 131)), .bottomRight)
        XCTAssertEqual(layout.handle(at: CGPoint(x: 112, y: 134)), .bottom, "between two handles the nearer one is taken")
        XCTAssertEqual(layout.handle(at: CGPoint(x: 118, y: 134)), .bottomRight)
        XCTAssertFalse(layout.knobBelow)
        XCTAssertEqual(layout.center(of: .knob), CGPoint(x: 100, y: 40))
        XCTAssertEqual(layout.handle(at: CGPoint(x: 100, y: 52)), .knob)
        XCTAssertEqual(layout.handle(at: CGPoint(x: 100, y: 58)), .top)
        XCTAssertNil(layout.handle(at: CGPoint(x: 200, y: 200)))

        let high = InkBoxLayout(InkBox(center: CGPoint(x: 100, y: 40), size: CGSize(width: 100, height: 40)), scale: 1, in: room)
        XCTAssertTrue(high.knobBelow, "with no room above, the knob stands under the box")
        XCTAssertEqual(high.center(of: .knob).y, 100, accuracy: 0.01)
        XCTAssertEqual(high.stalkFoot.y, 70, accuracy: 0.01)

        let zoomed = InkBoxLayout(InkBox(center: CGPoint(x: 50, y: 50), size: CGSize(width: 30, height: 30)), scale: 2, in: room)
        XCTAssertEqual(zoomed.center(of: .bottomRight), CGPoint(x: 138, y: 138), "the handles stand a fixed way off on the screen at any zoom")
        let turned = InkBoxLayout(InkBox(center: CGPoint(x: 300, y: 300), size: CGSize(width: 200, height: 100), turn: .pi / 2), scale: 1, in: room)
        XCTAssertEqual(turned.center(of: .knob).x, 388, accuracy: 0.01, "the knob turns with the box")
        XCTAssertEqual(turned.handle(at: CGPoint(x: 300, y: 410)), .right)
    }

    func testInkIsResizedTurnedAndStretchedWithItsLineKeptEven() throws {
        let page = UUID(), next = UUID()
        let frames = [page: CGRect(x: 16, y: 16, width: 612, height: 792), next: CGRect(x: 16, y: 824, width: 612, height: 792)]
        let flat = line(y: 100), post = stroke(from: CGPoint(x: 200, y: 400), to: CGPoint(x: 200, y: 600), width: 6)
        let drawings = [page: PKDrawing(strokes: [flat, post]), next: PKDrawing()], both: InkSelection = [page: [0, 1]]
        let thick = post.renderBounds.width
        let box = try XCTUnwrap(InkLasso.box(of: both, drawings: drawings, frames: frames))
        XCTAssertEqual(box.center.x, 216, accuracy: 4)
        XCTAssertEqual(box.turn, 0)
        XCTAssertEqual(box.bounds, InkLasso.bounds(of: both, drawings: drawings, frames: frames))
        let left = box.bounds.minX - 16

        let doubled = InkLasso.changed(both, by: box.stretching(by: CGSize(width: 2, height: 2), holding: box.point(.zero)), drawings: drawings, frames: frames)
        let large = try XCTUnwrap(doubled.drawings[page]).strokes
        XCTAssertEqual(large.count, 1, "ink resized past the foot of its page goes on to the next")
        XCTAssertEqual(doubled.selection, [page: [0], next: [0]])
        // PencilKit gives a stroke's bounds in whole points, so sizes are compared to within a point or two.
        XCTAssertEqual(large[0].renderBounds.minX, flat.renderBounds.minX, accuracy: 1.5, "the corner it was resized from stays put")
        XCTAssertEqual(large[0].renderBounds.width, 400 + 6, accuracy: 2)
        XCTAssertEqual(large[0].renderBounds.height, 6, accuracy: 1, "resized evenly, a line grows with its ink")
        XCTAssertEqual(large[0].path.count, flat.path.count)
        XCTAssertEqual(large[0].transform.a, 2, accuracy: 1e-9, "its path is left as it was drawn")
        let carried = try XCTUnwrap(doubled.drawings[next]?.strokes.first)
        XCTAssertEqual(carried.renderBounds.width, thick * 2, accuracy: 2)
        XCTAssertEqual(carried.renderBounds.height, post.renderBounds.height * 2, accuracy: 2)
        XCTAssertEqual(carried.renderBounds.midY, 98 + 2 * (500 - 98) + 16 - 824, accuracy: 2, "at its place on that page")

        let stretch = box.stretching(by: CGSize(width: 2, height: 1), holding: box.point(CGPoint(x: 0, y: 0.5)))
        let wide = try XCTUnwrap(InkLasso.changed(both, by: stretch, drawings: drawings, frames: frames).drawings[page]).strokes
        XCTAssertEqual(wide[1].renderBounds.width, thick, accuracy: 0.5, "stretched one way, a line stays as thick as it was")
        XCTAssertEqual(wide[1].renderBounds.midX, left + 2 * (200 - left), accuracy: 1, "and is carried twice as far from the side that was held")
        XCTAssertEqual(wide[1].renderBounds.height, post.renderBounds.height, accuracy: 0.5)
        XCTAssertEqual(wide[0].renderBounds.height, flat.renderBounds.height, accuracy: 0.5)
        XCTAssertEqual(wide[0].renderBounds.width, flat.renderBounds.width + 200, accuracy: 2, "while its path is twice as long")
        XCTAssertEqual(wide[1].path.creationDate, post.path.creationDate, "it is still the stroke it was")
        XCTAssertEqual(wide[1].transform, post.transform)
        XCTAssertEqual(wide[1].path.count, post.path.count)

        let turn = InkBox.turning(by: .pi / 2, about: CGPoint(x: 216, y: 116))
        let turned = InkLasso.changed([page: [0]], by: turn, drawings: drawings, frames: frames)
        let upright = try XCTUnwrap(turned.drawings[page]).strokes[0]
        XCTAssertEqual(upright.renderBounds.height, flat.renderBounds.width, accuracy: 1, "turned a quarter, a line lying flat stands up")
        XCTAssertEqual(upright.renderBounds.midX, 200, accuracy: 1)
        XCTAssertEqual(upright.renderBounds.midY, 100, accuracy: 1)
        let tilted = try XCTUnwrap(InkLasso.box(of: [page: [0]], turn: .pi / 2, drawings: turned.drawings, frames: frames))
        XCTAssertEqual(tilted.size.width, flat.renderBounds.width, accuracy: 1, "its box stands turned with it, as close round it as before")
        XCTAssertEqual(tilted.size.height, flat.renderBounds.height, accuracy: 1)
        XCTAssertEqual(tilted.center.x, 216, accuracy: 1)
        XCTAssertEqual(tilted.center.y, 116, accuracy: 1)

        let slant = InkLasso.changed([page: [0]], by: InkBox.turning(by: .pi / 6, about: CGPoint(x: 216, y: 116)), drawings: drawings, frames: frames)
        let close = try XCTUnwrap(InkLasso.box(of: [page: [0]], turn: .pi / 6, drawings: slant.drawings, frames: frames))
        let loose = try XCTUnwrap(InkLasso.box(of: [page: [0]], drawings: slant.drawings, frames: frames))
        XCTAssertEqual(close.size.height, flat.renderBounds.height, accuracy: 1)
        XCTAssertGreaterThan(loose.size.height, 90, "caught again, slanted ink gets an upright box")
    }

    private func grip(_ handle: InkHandle, in controller: PageStackController) throws -> InkGrip {
        var views: [UIView] = [controller.view], found: InkGrip?
        while found == nil, !views.isEmpty {
            let view = views.removeFirst()
            found = (view as? InkGrip).flatMap { $0.handle == handle ? $0 : nil }
            views += view.subviews
        }
        return try XCTUnwrap(found, "the lasso's box has no \(handle) handle")
    }

    func testCaughtInkIsShapedByItsHandlesOneUndoStepEach() async throws {
        let toolbox = Toolbox(defaults: nil)
        let (session, controller) = try await openEditor(pages: 2, ink: PKDrawing(strokes: [line(y: 100), line(y: 200)]), toolbox: toolbox)
        let document = session.document, first = document.pages[0].id
        document.undoManager.groupsByEvent = false
        func step(_ change: () -> Void) {
            document.undoManager.beginUndoGrouping()
            change()
            document.undoManager.endUndoGrouping()
        }
        func ink() throws -> CGRect { try XCTUnwrap(document.loadedInk(first)).bounds }
        /// The whole numbers in what a handle says.
        func sizes(_ grip: InkGrip) -> [CGFloat] { (grip.accessibilityValue ?? "").split { !$0.isNumber }.compactMap { Double($0) }.map { CGFloat($0) } }
        let before = try ink()
        toolbox.take(.lasso)
        let resize = try grip(.bottomRight, in: controller), knob = try grip(.knob, in: controller), width = try grip(.right, in: controller)
        XCTAssertTrue(resize.isHidden, "with nothing caught there is no box to have handles")

        controller.catchInk(inside: everything)
        XCTAssertEqual(session.inkSelectionCount, 2)
        XCTAssertFalse(resize.isHidden || knob.isHidden || width.isHidden)
        XCTAssertTrue(resize.isAccessibilityElement && knob.isAccessibilityElement && width.isAccessibilityElement)
        XCTAssertFalse(try grip(.topLeft, in: controller).isAccessibilityElement, "one tab speaks for the four")
        XCTAssertEqual(knob.accessibilityValue, "Upright")
        XCTAssertEqual(resize.accessibilityValue, "\(Int(before.width.rounded())) by \(Int(before.height.rounded())) pt")

        step { resize.accessibilityIncrement() }
        XCTAssertEqual(document.undoManager.undoActionName, "Resize Ink")
        XCTAssertEqual(try ink().width, before.width * 1.1, accuracy: 0.5, "a step on the tab makes the ink a tenth larger")
        XCTAssertEqual(try ink().midX, before.midX, accuracy: 0.5, "about its middle")
        XCTAssertEqual(session.inkSelectionCount, 2, "and it stays caught")

        step { knob.accessibilityIncrement() }
        XCTAssertEqual(document.undoManager.undoActionName, "Rotate Ink")
        XCTAssertEqual(knob.accessibilityValue, "Turned 15° right")
        XCTAssertEqual(sizes(resize)[0], before.width * 1.1, accuracy: 1.5, "the box stays turned with its ink")
        XCTAssertEqual(sizes(resize)[1], before.height * 1.1, accuracy: 1.5)
        let slanted = try ink()
        XCTAssertGreaterThan(slanted.height, before.height * 1.1 + 20)

        step { width.accessibilityIncrement() }
        XCTAssertEqual(document.undoManager.undoActionName, "Resize Ink")
        XCTAssertEqual(sizes(width)[0], before.width * 1.21, accuracy: 2, "a step on a bar stretches the ink along its own turned side")
        XCTAssertEqual(sizes(resize)[1], before.height * 1.1, accuracy: 1.5)
        XCTAssertEqual(knob.accessibilityValue, "Turned 15° right")
        XCTAssertEqual(session.inkSelectionCount, 2)

        document.undoManager.undo()
        XCTAssertEqual(try ink().width, slanted.width, accuracy: 0.5, "each step is undone on its own")
        XCTAssertEqual(session.inkSelectionCount, 0)
        document.undoManager.undo()
        document.undoManager.undo()
        XCTAssertEqual(try ink().width, before.width, accuracy: 0.5)
        XCTAssertEqual(try ink().height, before.height, accuracy: 0.5)
        XCTAssertTrue(resize.isHidden)

        controller.catchInk(inside: everything)
        XCTAssertEqual(knob.accessibilityValue, "Upright", "ink caught afresh has an upright box")
        session.enter(.presenting)
        XCTAssertTrue(resize.superview == nil || resize.isHidden, "nothing is shaped while the pages are locked")
    }

    /// Whether the screen shows ink at a point of the first page, by how far it is from the colour of bare paper.
    private func showsInk(at place: CGPoint, in controller: PageStackController) throws -> Bool {
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), slot = try XCTUnwrap(canvas.superview), window = try XCTUnwrap(controller.view.window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let picture = try XCTUnwrap(image.cgImage), width = picture.width, height = picture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        func luminance(_ place: CGPoint) -> CGFloat {
            let point = slot.convert(CGPoint(x: place.x * canvas.zoomScale, y: place.y * canvas.zoomScale), to: window)
            let i = (min(max(Int(point.y), 0), height - 1) * width + min(max(Int(point.x), 0), width - 1)) * 4
            return (0.2126 * CGFloat(pixels[i]) + 0.7152 * CGFloat(pixels[i + 1]) + 0.0722 * CGFloat(pixels[i + 2])) / 255
        }
        return abs(luminance(place) - luminance(CGPoint(x: 400, y: 600))) > 0.25
    }

    /// A stretch changes a stroke's path where it stands, and a canvas keeps what it has drawn for a stroke it knows.
    func testAStrokeStretchedOnItsCanvasIsDrawnAfresh() async throws {
        let toolbox = Toolbox(defaults: nil)
        toolbox.take(.lasso)
        let line = stroke(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 250, y: 300), width: 8)
        let (session, controller) = try await openEditor(pages: 1, ink: PKDrawing(strokes: [line]), toolbox: toolbox)
        for _ in 0..<40 where session.inkSelectionCount == 0 {
            controller.catchInk(inside: everything)
            try? await Task.sleep(for: .seconds(0.05))
        }
        XCTAssertEqual(session.inkSelectionCount, 1)
        let onLine = CGPoint(x: 175, y: 300), pastIt = CGPoint(x: 330, y: 300)
        for _ in 0..<100 where try !showsInk(at: onLine, in: controller) { try? await Task.sleep(for: .seconds(0.1)) }
        XCTAssertTrue(try showsInk(at: onLine, in: controller))
        XCTAssertFalse(try showsInk(at: pastIt, in: controller))

        // Six steps on the bar make the line 1.1⁶ as long from its left end, with nothing lifted off the canvas meanwhile.
        let wider = try grip(.right, in: controller)
        for _ in 0..<6 { wider.accessibilityIncrement() }
        let longer = try XCTUnwrap(session.document.loadedInk(session.document.pages[0].id)).bounds.width
        XCTAssertEqual(longer, 150 * pow(1.1, 6) + line.renderBounds.width - 150, accuracy: 3, "its path is longer and its line no thicker")
        for _ in 0..<50 where try !showsInk(at: pastIt, in: controller) { try? await Task.sleep(for: .seconds(0.1)) }
        XCTAssertTrue(try showsInk(at: pastIt, in: controller), "the canvas shows the line as long as it now is")
    }
}
