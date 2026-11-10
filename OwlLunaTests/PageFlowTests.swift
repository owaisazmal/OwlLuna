import XCTest
import PencilKit
@testable import OwlLuna

/// Single flow shows one page at a time, turned with a swipe past its side, and every way to a page still lands on it.
@MainActor
final class PageFlowTests: XCTestCase {
    private let portrait = CGSize(width: 834, height: 1194)

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    override func setUp() async throws {
        let saved = UserDefaults.standard.object(forKey: SettingsKey.pageFlow)
        addTeardownBlock { UserDefaults.standard.set(saved, forKey: SettingsKey.pageFlow) }
    }

    private func letter() -> NotebookPage { .template(.narrowRuled, color: .white, size: .letter) }

    private func open(_ pages: [NotebookPage], flow: PageFlow = .single, at page: Int = 0) async throws -> (EditorSession, PageStackController, UIWindow) {
        UserDefaults.standard.set(flow.rawValue, forKey: SettingsKey.pageFlow)
        let root = temporaryRoot(self)
        let manifest = NotebookManifest(title: "Flow", defaults: PageDefaults(template: .narrowRuled, paperColor: .white, pageSize: .letter), pages: pages)
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let session = EditorSession(document: document, initialPageID: pages.indices.contains(page) ? pages[page].id : nil)
        XCTAssertEqual(session.pageFlow, flow)
        let controller = PageStackController(session: session)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: portrait)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where controller.canvas(forPage: page)?.isLoaded != true { await pause(0.05) }
        return (session, controller, window)
    }

    private func scrollView(of controller: PageStackController) throws -> UIScrollView {
        try XCTUnwrap(controller.view.subviews.lazy.compactMap { $0 as? UIScrollView }.first)
    }

    /// A finger swipe that ended `distance` points past a side of the page, as the scroll view reports it. `from`
    /// is where the drag began; by default the side it ends past.
    private func swipe(_ controller: PageStackController, past distance: CGFloat, from start: CGFloat? = nil) throws {
        let scroll = try scrollView(of: controller)
        let inset = scroll.contentInset
        let minX = -inset.left, maxX = max(minX, scroll.contentSize.width + inset.right - scroll.bounds.width)
        scroll.contentOffset.x = start ?? (distance > 0 ? maxX : minX)
        controller.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.x = distance > 0 ? maxX + distance : minX + distance
        controller.scrollViewDidEndDragging(scroll, willDecelerate: true)
    }

    func testOnlyTheShownPageIsLaidOutAndASwipeTurnsIt() async throws {
        let (session, controller, _) = try await open((0..<5).map { _ in letter() })
        let scroll = try scrollView(of: controller)
        XCTAssertEqual(controller.liveCanvasCount, 1)
        XCTAssertNotNil(controller.canvas(forPage: 0))
        XCTAssertNil(controller.canvas(forPage: 1))
        XCTAssertEqual(controller.currentPage, 0)
        XCTAssertEqual(scroll.contentSize.width, portrait.width, accuracy: 1, "the page fits the width")
        let alone = PageStackLayout(pages: [letter()])
        XCTAssertEqual(scroll.contentSize.height / scroll.contentSize.width, alone.size.height / alone.size.width, accuracy: 0.01, "and nothing but it is laid out")
        XCTAssertTrue(scroll.alwaysBounceHorizontal)
        XCTAssertNotNil(controller.visibleRect(ofPage: 0))
        XCTAssertNil(controller.visibleRect(ofPage: 1), "the other pages are put away")

        try swipe(controller, past: 80)
        XCTAssertEqual(session.currentPage, 1)
        XCTAssertEqual(controller.currentPage, 1)
        XCTAssertNotNil(controller.canvas(forPage: 1))
        XCTAssertNil(controller.canvas(forPage: 0))
        XCTAssertEqual(controller.liveCanvasCount, 1)
        XCTAssertEqual(scroll.contentOffset.x, -scroll.contentInset.left, accuracy: 0.5, "the new page sits where a page starts")

        try swipe(controller, past: -80)
        XCTAssertEqual(session.currentPage, 0)
        XCTAssertNotNil(controller.canvas(forPage: 0))

        try swipe(controller, past: -80)
        XCTAssertEqual(session.currentPage, 0, "the first page only bounces")
        try swipe(controller, past: 20)
        XCTAssertEqual(session.currentPage, 0, "a short pull with no flick turns nothing")

        session.go(to: 4, animated: false)
        try swipe(controller, past: 80)
        XCTAssertEqual(session.currentPage, 4, "the last page only bounces")
    }

    func testInkDrawnOnTheShownPageLandsInTheDocument() async throws {
        let (session, controller, _) = try await open([letter(), letter(), letter()])
        session.go(to: 1, animated: false)
        let canvas = try XCTUnwrap(controller.canvas(forPage: 1))
        for _ in 0..<100 where !canvas.isLoaded { await pause(0.05) }
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled, "the page is written on, not locked")
        canvas.drawing = PKDrawing(strokes: [dot(at: CGPoint(x: 100, y: 120))])
        controller.canvasViewDrawingDidChange(canvas)
        await pause(0.1)
        let page = session.document.pages[1].id
        XCTAssertEqual(session.document.loadedInk(page)?.strokes.count, 1)
        XCTAssertNil(session.document.loadedInk(session.document.pages[0].id)?.strokes.first, "and only there")
    }

    func testEveryWayToAPageLandsOnItAndTheStackComesBackAtThatPage() async throws {
        let (session, controller, _) = try await open((0..<6).map { _ in letter() })
        let scroll = try scrollView(of: controller)

        session.go(to: 4)
        XCTAssertEqual(session.currentPage, 4)
        XCTAssertEqual(controller.currentPage, 4)
        XCTAssertNotNil(controller.canvas(forPage: 4))
        XCTAssertEqual(controller.liveCanvasCount, 1, "a far page shows alone, nothing in between is built")

        session.step(-1)
        XCTAssertEqual(session.currentPage, 3)
        XCTAssertEqual(controller.currentPage, 3)
        session.step(1)
        XCTAssertEqual(controller.currentPage, 4)

        // Zoomed in, a tall page scrolls within itself and the zoom carries over to the next page.
        controller.setZoom(2)
        XCTAssertEqual(controller.zoom, 2, accuracy: 0.001)
        XCTAssertGreaterThan(scroll.contentSize.width, portrait.width)
        let before = scroll.contentOffset
        controller.scrollBy(viewportFraction: 0.5)
        XCTAssertGreaterThan(scroll.contentOffset.y, before.y)
        XCTAssertEqual(controller.currentPage, 4, "scrolling within the page turns nothing")
        try swipe(controller, past: 80, from: 100)
        XCTAssertEqual(session.currentPage, 4, "a drag that pans to the side and on past it turns nothing either")
        try swipe(controller, past: 80)
        XCTAssertEqual(session.currentPage, 5, "a swipe begun at the side turns")
        XCTAssertEqual(controller.zoom, 2, accuracy: 0.001)
        controller.fit(.width)
        XCTAssertEqual(controller.zoom, 1, accuracy: 0.001)

        session.pageFlow = .continuous
        XCTAssertEqual(controller.currentPage, 5, "the stack comes back at the page shown")
        XCTAssertEqual(session.currentPage, 5)
        XCTAssertNotNil(controller.canvas(forPage: 5))
        XCTAssertNotNil(controller.canvas(forPage: 4), "with its neighbours live again")
        XCTAssertFalse(scroll.alwaysBounceHorizontal)
        let stack = PageStackLayout(pages: session.document.pages)
        XCTAssertEqual(scroll.contentSize.height / scroll.contentSize.width, stack.size.height / stack.size.width, accuracy: 0.01, "every page is laid out")
        for _ in 0..<100 where controller.canvas(forPage: 4)?.isLoaded != true { await pause(0.05) }

        session.pageFlow = .single
        XCTAssertEqual(controller.currentPage, 5)
        XCTAssertEqual(controller.liveCanvasCount, 1)
        XCTAssertNotNil(controller.canvas(forPage: 5))
    }

    func testPresentingAndSelectingInkWorkFromSingleFlowAndComeBackToIt() async throws {
        let (session, controller, _) = try await open((0..<4).map { _ in letter() }, at: 1)
        XCTAssertEqual(controller.currentPage, 1, "the notebook opens on its page")
        XCTAssertEqual(controller.liveCanvasCount, 1)
        let scroll = try scrollView(of: controller)

        session.enter(.presenting)
        XCTAssertEqual(controller.currentPage, 1)
        XCTAssertEqual(controller.liveCanvasCount, 1)
        session.step(1)
        XCTAssertEqual(session.currentPage, 2)
        XCTAssertNotNil(controller.canvas(forPage: 2))
        try swipe(controller, past: 80)
        XCTAssertEqual(session.currentPage, 3, "a swipe turns the presented page")
        session.enter(.writing)
        XCTAssertEqual(controller.currentPage, 3)
        XCTAssertEqual(controller.zoom, 1, accuracy: 0.001)
        XCTAssertEqual(controller.liveCanvasCount, 1)

        session.enter(.selecting)
        XCTAssertGreaterThan(controller.liveCanvasCount, 1, "selecting ink across pages lays the stack out")
        XCTAssertEqual(controller.currentPage, 3)
        XCTAssertFalse(scroll.alwaysBounceHorizontal)
        session.enter(.writing)
        XCTAssertEqual(controller.liveCanvasCount, 1)
        XCTAssertEqual(controller.currentPage, 3)
        XCTAssertTrue(scroll.alwaysBounceHorizontal)
    }

    func testPagesComeAndGoAroundTheShownPageAndABoardOpensFromIt() async throws {
        let board = NotebookPage.board(template: .dotted, color: .white)
        let pages = [letter(), letter(), board, letter()]
        let (session, controller, window) = try await open(pages, at: 1)
        let document = session.document
        let shown = pages[1].id

        document.insertPages([letter()], at: 0)
        XCTAssertEqual(session.currentPage, 2)
        XCTAssertEqual(document.pages[controller.currentPage].id, shown, "the shown page keeps its place when one goes in before it")
        XCTAssertEqual(controller.liveCanvasCount, 1)
        document.removePages([document.pages[0].id])
        XCTAssertEqual(document.pages[controller.currentPage].id, shown)

        try swipe(controller, past: 80)
        XCTAssertEqual(session.currentPage, 2)
        XCTAssertNil(controller.openBoardID, "a whiteboard turned to is a card on its own")
        XCTAssertNil(controller.canvas(forPage: 2))
        try swipe(controller, past: 80)
        XCTAssertEqual(session.currentPage, 3, "and turning past it goes on to the next page")
        session.go(to: 2)
        XCTAssertEqual(controller.openBoardID, board.id, "going to the board opens it, as in the stack")
        XCTAssertEqual(controller.currentPage, 2)
        session.leaveBoard()
        XCTAssertNil(controller.openBoardID)
        XCTAssertEqual(controller.currentPage, 3)
        XCTAssertEqual(controller.liveCanvasCount, 1, "the page is on its own again")

        document.removePages([document.pages[3].id])
        XCTAssertEqual(controller.currentPage, 2, "deleting the shown page shows the one that takes its place")
        XCTAssertEqual(session.currentPage, 2)

        session.go(to: 0, animated: false)
        window.frame = CGRect(origin: .zero, size: CGSize(width: 1194, height: 834))
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.currentPage, 0, "a turn of the device keeps the page")
        XCTAssertEqual(controller.liveCanvasCount, 1)
    }
}
