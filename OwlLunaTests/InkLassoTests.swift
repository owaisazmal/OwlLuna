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
}
