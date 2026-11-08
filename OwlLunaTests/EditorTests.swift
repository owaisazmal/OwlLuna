import XCTest
import PencilKit
import PDFKit
@testable import OwlLuna

final class PageStackLayoutTests: XCTestCase {
    func testPagesStackVerticallyAndCentre() {
        let pages = [NotebookPage.template(.blank, color: .white, size: .letter), .template(.blank, color: .white, size: .a5),
                     NotebookPage(background: .image(file: "x"), paperColor: .white, size: CGSize(width: 960, height: 540))]
        let layout = PageStackLayout(pages: pages)
        let margin = PageStackLayout.margin
        XCTAssertEqual(layout.size.width, 960 + margin * 2)
        XCTAssertEqual(layout.frames[0].size, PageSize.letter.points)
        XCTAssertEqual(layout.frames[1].minY, layout.frames[0].maxY + margin)
        XCTAssertEqual(layout.frames[0].midX, layout.size.width / 2, accuracy: 1)
        XCTAssertEqual(layout.frames[2].minX, margin)
        XCTAssertEqual(layout.size.height, layout.frames[2].maxY + margin)
    }

    func testPageAtYAndVisibleRange() {
        let layout = PageStackLayout(pages: (0..<5).map { _ in .template(.blank, color: .white, size: .letter) })
        XCTAssertEqual(layout.pageIndex(atY: 0), 0)
        XCTAssertEqual(layout.pageIndex(atY: layout.frames[3].midY), 3)
        XCTAssertEqual(layout.pageIndex(atY: layout.frames[1].maxY + PageStackLayout.margin / 4), 1)
        XCTAssertEqual(layout.pageIndex(atY: 1_000_000), 4)
        XCTAssertEqual(layout.range(from: layout.frames[1].midY, to: layout.frames[2].midY), 1...2)
    }

    func testSingleFlowLaysOnePageOutAloneAndPutsTheOthersAway() {
        let margin = PageStackLayout.margin
        let pages = [NotebookPage.template(.blank, color: .white, size: .letter), .template(.blank, color: .white, size: .a5),
                     .board(template: .dotted, color: .white), .template(.blank, color: .white, size: .letter)]
        let a5 = PageSize.a5.points
        let layout = PageStackLayout(pages: pages, single: 1)
        XCTAssertEqual(layout.single, 1)
        XCTAssertNil(layout.solo)
        XCTAssertEqual(layout.alone, 1)
        XCTAssertEqual(layout.frames.count, 4)
        XCTAssertEqual(layout.frames[1], CGRect(x: margin, y: margin, width: a5.width, height: a5.height), "the page fills the width itself")
        XCTAssertEqual(layout.frames[0], .zero)
        XCTAssertEqual(layout.frames[3], .zero)
        XCTAssertEqual(layout.size, CGSize(width: a5.width + margin * 2, height: a5.height + margin * 2))
        XCTAssertTrue(layout.isLaidOut(1, in: pages))
        XCTAssertFalse(layout.isLaidOut(0, in: pages))
        XCTAssertFalse(layout.isLaidOut(3, in: pages))
        XCTAssertEqual(layout.pageIndex(atY: 0), 1)
        XCTAssertEqual(layout.pageIndex(atY: 10_000), 1)
        XCTAssertEqual(layout.range(from: 0, to: 2000), 1...1)

        let card = PageStackLayout(pages: pages, single: 2)
        XCTAssertEqual(card.frames[2].width, PageSize.letter.points.width, "a whiteboard on its own is a Letter-wide card")
        XCTAssertEqual(card.frames[2].height, 459)
        XCTAssertFalse(card.isLaidOut(2, in: pages), "the card is not the board at its own size")

        XCTAssertNil(PageStackLayout(pages: pages, single: 9).single, "a page that is gone leaves the stack laid out")
        XCTAssertEqual(PageStackLayout(pages: pages, single: 9).frames[3].minY, PageStackLayout(pages: pages).frames[3].minY)
        XCTAssertNil(PageStackLayout(pages: pages, solo: 2, single: 1).single, "an open whiteboard takes the place of the single page")
        XCTAssertEqual(PageStackLayout(pages: pages, solo: 2, single: 1).alone, 2)
        XCTAssertNil(PageStackLayout(pages: [], single: 0).single)
    }
}

@MainActor
final class FitPageTests: XCTestCase {
    private func letter() -> NotebookPage { .template(.blank, color: .white, size: .letter) }

    /// A wide, short page, like a panorama photo or a scanned receipt.
    private func panorama() -> NotebookPage {
        var page = letter()
        page.size = CGSize(width: 612, height: 170)
        return page
    }

    private func open(_ pages: [NotebookPage]) async throws -> (EditorSession, PageStackController) {
        let root = temporaryRoot(self)
        let manifest = NotebookManifest(title: "Fit", defaults: PageDefaults(template: .blank, paperColor: .white, pageSize: .letter), pages: pages)
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let session = EditorSession(document: document)
        let controller = PageStackController(session: session)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        return (session, controller)
    }

    /// Scrolls the page under the line that picks the current page and fits it: centred, it sits below that line.
    private func fitPage(_ index: Int, _ session: EditorSession, _ controller: PageStackController) {
        session.go(to: index, animated: false)
        for _ in 0..<40 where controller.currentPage != index { controller.scrollBy(viewportFraction: controller.currentPage > index ? -0.05 : 0.05) }
        XCTAssertEqual(session.currentPage, index)
        controller.fit(.page)
        XCTAssertEqual(session.currentPage, index, "a short page centred by Fit Page stays current")
        XCTAssertNotEqual(controller.currentPage, index, "though the line that picks the current page is on the page above")
    }

    private func currentID(_ session: EditorSession) -> UUID? {
        session.document.pages.indices.contains(session.currentPage) ? session.document.pages[session.currentPage].id : nil
    }

    func testDeletingAShortPageLeftCurrentByFitPageMovesToAPageThatExists() async throws {
        let short = panorama()
        let (session, controller) = try await open([letter(), letter(), short, letter()])
        let document = session.document
        fitPage(2, session, controller)

        document.removePages([document.pages[0].id])
        XCTAssertEqual(currentID(session), short.id, "it stays current when a page before it goes")
        document.removePages([document.pages[2].id])
        XCTAssertEqual(session.currentPage, 1)
        XCTAssertEqual(currentID(session), short.id, "and when the page after it goes, leaving it last")

        document.removePages([short.id])
        XCTAssertEqual(session.currentPage, 0, "the ribbon and the page menus move to a page that exists")
        controller.fit(.page)
        controller.fit(.width)
        XCTAssertEqual(session.currentPage, 0)
        XCTAssertEqual(controller.currentPage, 0)
    }

    func testUndoingTheInsertionOfAShortPageLeftCurrentByFitPageMovesToAPageThatExists() async throws {
        let (session, controller) = try await open([letter(), letter()])
        let document = session.document
        document.undoManager.groupsByEvent = false
        document.undoManager.beginUndoGrouping()
        document.insertPages([panorama(), letter()], at: 2)
        document.undoManager.endUndoGrouping()
        fitPage(2, session, controller)

        document.undoManager.undo()
        XCTAssertEqual(document.pages.count, 2)
        XCTAssertNotNil(currentID(session), "the ribbon and the page menus are on a page that exists")
        XCTAssertEqual(session.currentPage, controller.currentPage)
        controller.fit(.page)
        controller.fit(.width)
        XCTAssertNotNil(currentID(session))
        XCTAssertEqual(session.currentPage, controller.currentPage)
    }
}

/// Replaces the stroke-masking test: masking at stroke end is gone, and ink past the edge is kept but never shown.
@MainActor
final class InkStaysOnItsPageTests: XCTestCase {
    func testInkPastTheEdgeIsKeptButOnlyThePagePartIsDrawn() throws {
        let page = NotebookPage.template(.blank, color: .white, size: .letter)
        let size = page.size
        let crossing = stroke(from: CGPoint(x: size.width - 120, y: 300), to: CGPoint(x: size.width + 200, y: 300), width: 8)
        let drawing = PKDrawing(strokes: [crossing])
        let image = PageRenderer.image(of: page, ink: drawing, assets: temporaryRoot(self).url, width: size.width, scale: 1)
        XCTAssertEqual(image.size, size, "renders exactly the page rectangle")
        XCTAssertLessThan(try luminance(of: image, at: CGPoint(x: size.width - 40, y: 300)), 0.5, "the part on the page is drawn")
        XCTAssertGreaterThan(try luminance(of: image, at: CGPoint(x: 100, y: 300)), 0.9)
        XCTAssertEqual(drawing.strokes.first?.mask, nil, "the stroke itself is left whole")
        XCTAssertTrue(PageSlotView(page: page).clipsToBounds, "on screen, the page slot clips its canvas")
    }

    private func luminance(of image: UIImage, at point: CGPoint) throws -> CGFloat {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let scale = CGFloat(cgImage.width) / image.size.width
        context.draw(cgImage, in: CGRect(x: -point.x * scale, y: -(CGFloat(cgImage.height) - point.y * scale - 1),
                                         width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return (0.2126 * CGFloat(pixel[0]) + 0.7152 * CGFloat(pixel[1]) + 0.0722 * CGFloat(pixel[2])) / 255
    }
}

@MainActor
final class DocumentRegistryTests: XCTestCase {
    func testOneDocumentPerNotebookAndOnlyItsOwnerCanRelease() async throws {
        let root = temporaryRoot(self)
        let manifest = NotebookManifest(title: "Shared", defaults: PageDefaults(template: .blank, paperColor: .white, pageSize: .letter),
                                        pages: [.template(.blank, color: .white, size: .letter)])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let first = try await NotebookDocument.open(manifest.id, root: root)
        let other = try await NotebookDocument.open(manifest.id, root: root)
        let registry = DocumentRegistry.shared
        registry.register(first, scene: "scene-a")
        XCTAssertTrue(registry.document(for: manifest.id) === first)
        XCTAssertEqual(registry.sceneIdentifier(for: manifest.id), "scene-a")
        XCTAssertFalse(registry.activateExistingEditor(for: manifest.id, from: "scene-a"), "the owning window just keeps its editor")
        registry.unregister(manifest.id, document: other)
        XCTAssertTrue(registry.document(for: manifest.id) === first, "a different instance can't release the owner's registration")
        registry.unregister(manifest.id, document: first)
        XCTAssertNil(registry.document(for: manifest.id))
    }

    func testANotebookOpenInAnotherWindowIsThatWindows() async throws {
        let root = temporaryRoot(self)
        let manifest = NotebookManifest(title: "Elsewhere", defaults: PageDefaults(template: .blank, paperColor: .white, pageSize: .letter),
                                        pages: [.template(.blank, color: .white, size: .letter)])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let registry = DocumentRegistry.shared
        let session = try XCTUnwrap(UIApplication.shared.connectedScenes.first { $0 is UIWindowScene }, "the tests run inside the app, which has a window").session
        XCTAssertNil(registry.otherWindow(with: manifest.id, than: "scene-b"), "a notebook no window has open is nobody's")

        registry.register(document, scene: session.persistentIdentifier)
        XCTAssertTrue(registry.otherWindow(with: manifest.id, than: "scene-b") === session)
        XCTAssertNil(registry.otherWindow(with: manifest.id, than: session.persistentIdentifier), "the window that has it open is not another window")

        registry.register(document, scene: "scene-a")
        XCTAssertNil(registry.otherWindow(with: manifest.id, than: "scene-b"), "a window that has gone holds no notebook back")
        XCTAssertFalse(registry.activateExistingEditor(for: manifest.id, from: "scene-b"))

        registry.unregister(manifest.id, document: document)
        XCTAssertNil(registry.otherWindow(with: manifest.id, than: "scene-b"))
    }
}

final class PDFRoundTripV2Tests: XCTestCase {
    private func makePDF(pageSizes: [CGSize]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSizes[0])).writePDF(to: url) { context in
            for size in pageSizes {
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                ("Mitochondria" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
        return url
    }

    func testImportCreatesOnePagePerPDFPage() async throws {
        let root = temporaryRoot(self)
        let package = NotebookPackage(root: root, id: UUID())
        let file = try await package.importAsset(from: makePDF(pageSizes: [CGSize(width: 612, height: 792), CGSize(width: 792, height: 612)]), ext: "pdf")
        let pages = try PDFImport.pages(at: package.assetURL(file), file: file)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[1].size, CGSize(width: 792, height: 612))
        XCTAssertEqual(pages[1].background, .pdf(file: file, index: 1))
    }

    func testExportKeepsPageCountSizesTextAndInk() async throws {
        let root = temporaryRoot(self)
        let id = UUID()
        let package = NotebookPackage(root: root, id: id)
        let file = try await package.importAsset(from: makePDF(pageSizes: [CGSize(width: 612, height: 792)]), ext: "pdf")
        var pages = try PDFImport.pages(at: package.assetURL(file), file: file)
        pages.append(.template(.dotted, color: .ivory, size: .a4))
        let manifest = NotebookManifest(id: id, title: "Bio: Cells", defaults: PageDefaults(template: .dotted, paperColor: .ivory, pageSize: .a4), pages: pages)
        try await package.create(manifest)
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: [pages[1].id: PKDrawing(strokes: [stroke(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 300, y: 60))])]))
        // This checks the original PDF text and saved ink, not OCR of the synthetic line.
        // Handwriting recognition has its own coverage in PDFExportTests.
        var options = NotebookExporter.Options()
        options.searchable = false
        let url = try await NotebookExporter.export(.init(title: "Bio: Cells", pages: pages, inMemoryInk: [:], package: package), options: options) { _ in }
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(url.lastPathComponent, "Bio- Cells.pdf")
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 1)?.bounds(for: .mediaBox).size.width ?? 0, 595.28, accuracy: 0.1)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Mitochondria") ?? false, "the original PDF text stays selectable")

        let inkPage = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: 2))
        var pixel: [UInt8] = [255]
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
            // Sample the middle of the saved stroke, in the PDF's bottom-left coordinates.
            context.translateBy(x: -175, y: -(inkPage.getBoxRect(.mediaBox).height - 55))
            context.drawPDFPage(inkPage)
        }
        XCTAssertLessThan(pixel[0], 100, "the saved ink is visible on the exported page")
    }

    func testExportCanBeCancelled() async throws {
        let root = temporaryRoot(self)
        let id = UUID()
        let package = NotebookPackage(root: root, id: id)
        let pages = (0..<40).map { _ in NotebookPage.template(.grid, color: .white, size: .letter) }
        try await package.create(NotebookManifest(id: id, title: "Long", defaults: PageDefaults(template: .grid, paperColor: .white, pageSize: .letter), pages: pages))
        let task = Task { try await NotebookExporter.export(.init(title: "Long", pages: pages, inMemoryInk: [:], package: package)) { _ in } }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled export must not produce a file")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
