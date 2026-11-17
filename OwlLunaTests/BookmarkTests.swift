import XCTest
import PDFKit
@testable import OwlLuna

/// Page bookmarks, the outline a PDF brings with it, and the outline an export carries out.
@MainActor
final class BookmarkTests: XCTestCase {
    private let paper = PageDefaults(template: .narrowRuled, paperColor: .white, pageSize: .letter)

    private func makeDocument(pages: Int = 3) async throws -> NotebookDocument {
        let root = temporaryRoot(self)
        let manifest = NotebookManifest(title: "Biology", defaults: paper, pages: (0..<pages).map { _ in paper.newPage() })
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        return try await NotebookDocument.open(manifest.id, root: root)
    }

    func testABookmarkSurvivesTheManifest() throws {
        var page = paper.newPage()
        XCTAssertNil(page.bookmark)
        page.bookmark = "Mitosis"
        let decoded = try XCTUnwrap(ManifestCodec.decodePage(ManifestCodec.encodePage(page)))
        XCTAssertEqual(decoded.bookmark, "Mitosis")
        XCTAssertEqual(decoded, page)
        XCTAssertNil(page.duplicated().bookmark, "a copy of the page isn't bookmarked too")
        page.bookmark = nil
        XCTAssertNil(page.extra["bookmark"], "removing it leaves nothing behind")
    }

    func testBookmarkNamesFallBackToTheDateThenThePageNumber() {
        var page = paper.newPage()
        page.bookmark = ""
        XCTAssertEqual(page.bookmarkTitle(number: 4), "Page 4")
        page.day = "2026-10-01"
        XCTAssertEqual(page.bookmarkTitle(number: 4), DailyJournal.spokenDay("2026-10-01"))
        page.bookmark = "Lab notes"
        XCTAssertEqual(page.bookmarkTitle(number: 4), "Lab notes")
    }

    func testBookmarkingIsUndoable() async throws {
        let document = try await makeDocument()
        let page = document.pages[1].id
        document.undoManager.groupsByEvent = false
        document.undoManager.beginUndoGrouping()
        document.setBookmark("  Enzymes ", forPage: page)
        document.undoManager.endUndoGrouping()
        XCTAssertEqual(document.pages[1].bookmark, "Enzymes")
        XCTAssertEqual(document.undoManager.undoActionName, "Bookmark")
        document.undoManager.undo()
        XCTAssertNil(document.pages[1].bookmark)
        document.undoManager.redo()
        XCTAssertEqual(document.pages[1].bookmark, "Enzymes")
        let saved = await document.flush()
        XCTAssertTrue(saved)
        let reopened = try await document.package.readManifest().manifest
        XCTAssertEqual(reopened.pages[1].bookmark, "Enzymes")
    }

    func testAnExportCarriesBookmarksAsItsOutline() async throws {
        let document = try await makeDocument()
        document.setBookmark("Enzymes", forPage: document.pages[2].id)
        document.setBookmark("", forPage: document.pages[0].id)
        let url = try await NotebookExporter.export(.init(title: "Biology", pages: document.pages, inMemoryInk: [:], package: document.package)) { _ in }
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        let root = try XCTUnwrap(pdf.outlineRoot)
        XCTAssertEqual(root.numberOfChildren, 2)
        XCTAssertEqual(root.child(at: 0)?.label, "Page 1")
        XCTAssertEqual(root.child(at: 1)?.label, "Enzymes")
        XCTAssertEqual(root.child(at: 1)?.destination?.page.map(pdf.index(for:)), 2)
        XCTAssertNil(NotebookExporter.outline(for: [paper.newPage()]), "no bookmarks, no outline")
    }

    func testAPDFsOutlineMapsOntoTheNotebooksPages() async throws {
        let root = temporaryRoot(self)
        let package = NotebookPackage(root: root, id: UUID())
        let source = FileManager.default.temporaryDirectory.appending(path: "outline-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: source) { context in
            CGPDFContextSetOutline(context.cgContext, [kCGPDFOutlineChildren as String: [
                [kCGPDFOutlineTitle as String: "Cells", kCGPDFOutlineDestination as String: 1,
                 kCGPDFOutlineChildren as String: [[kCGPDFOutlineTitle as String: "Organelles", kCGPDFOutlineDestination as String: 2]]],
                [kCGPDFOutlineTitle as String: "Genetics", kCGPDFOutlineDestination as String: 3],
            ]] as CFDictionary)
            for _ in 0..<3 { context.beginPage() }
        }
        try await package.create(NotebookManifest(id: package.id, title: "Textbook", defaults: paper, pages: [paper.newPage()]))
        let file = try await package.importAsset(from: source, ext: "pdf")
        var pages = [paper.newPage()]
        pages += try PDFImport.pages(at: package.assetURL(file), file: file)
        let entries = PDFOutlineReader.entries(pages: pages, assets: package.assetsDirectory)
        XCTAssertEqual(entries.map(\.title), ["Cells", "Organelles", "Genetics"])
        XCTAssertEqual(entries.map(\.level), [0, 1, 0])
        XCTAssertEqual(entries.map(\.parent), [nil, 0, nil])
        XCTAssertEqual(entries.map(\.pageID), [pages[1].id, pages[2].id, pages[3].id], "the notebook's own first page shifts nothing")
        let orphaned = PDFOutlineReader.entries(pages: [pages[0], pages[2], pages[3]], assets: package.assetsDirectory)
        XCTAssertEqual(orphaned.map(\.title), ["Organelles", "Genetics"])
        XCTAssertEqual(orphaned.map(\.level), [0, 0], "a part whose chapter's page was deleted is listed as a chapter")
        XCTAssertEqual(orphaned.map(\.parent), [nil, nil])
        pages.remove(at: 2)
        XCTAssertEqual(PDFOutlineReader.entries(pages: pages, assets: package.assetsDirectory).map(\.title), ["Cells", "Genetics"],
                       "an entry whose page was deleted is left out")
    }

    func testAPDFsContentsFoldUnderTheirChapters() {
        let pages = (0..<6).map { _ in UUID() }
        let entries = [
            OutlineEntry(id: 0, title: "Cells", level: 0, pageID: pages[0]),
            OutlineEntry(id: 1, title: "Organelles", level: 1, pageID: pages[1], parent: 0),
            OutlineEntry(id: 2, title: "Mitochondria", level: 2, pageID: pages[2], parent: 1),
            OutlineEntry(id: 3, title: "Genetics", level: 0, pageID: pages[4]),
            OutlineEntry(id: 4, title: "Heredity", level: 1, pageID: pages[4], parent: 3),
        ]
        var folds = OutlineFolds(entries)
        XCTAssertEqual(folds.shown.map(\.title), ["Cells", "Genetics"], "chapters start folded")
        XCTAssertTrue(folds.hasParts(entries[0]))
        XCTAssertFalse(folds.hasParts(entries[2]))
        folds.toggle(entries[0])
        XCTAssertEqual(folds.shown.map(\.title), ["Cells", "Organelles", "Genetics"], "a part's own parts stay folded")
        folds.toggle(entries[2])
        XCTAssertEqual(folds.shown.count, 3, "an entry with nothing under it doesn't fold")
        folds.toggle(entries[0])
        XCTAssertEqual(folds.shown.map(\.title), ["Cells", "Genetics"])
        folds.open(to: entries[1])
        XCTAssertEqual(folds.shown.map(\.title), ["Cells", "Organelles", "Mitochondria", "Genetics"], "opening to an entry opens it and what it is under")

        let places = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.element, $0.offset) })
        XCTAssertEqual(folds.entry(holding: 0, places: places)?.title, "Cells")
        XCTAssertEqual(folds.entry(holding: 3, places: places)?.title, "Mitochondria", "a page belongs to the last entry begun before it")
        XCTAssertEqual(folds.entry(holding: 5, places: places)?.title, "Heredity", "of two that begin on one page, the one under the other")
        XCTAssertNil(OutlineFolds(Array(entries.dropFirst(3))).entry(holding: 2, places: places), "nothing holds a page before the first entry")

        XCTAssertEqual(folds.mark(for: 3, places: places)?.title, "Mitochondria", "an entry on show is marked itself")
        XCTAssertEqual(folds.mark(for: 5, places: places)?.title, "Genetics", "one that is folded away is marked by what it is folded into")
        folds.toggle(entries[0])
        XCTAssertEqual(folds.mark(for: 3, places: places)?.title, "Cells", "by the outermost of them, since that is the one on show")
    }

    func testAPDFsContentsAreReadOnceForTheOpenNotebook() async throws {
        let document = try await makeDocument()
        let session = EditorSession(document: document)
        await session.readContents()
        XCTAssertTrue(session.contents.isEmpty, "a notebook with no PDF pages has no contents")

        let source = FileManager.default.temporaryDirectory.appending(path: "contents-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).writePDF(to: source) { context in
            CGPDFContextSetOutline(context.cgContext, [kCGPDFOutlineChildren as String: [
                [kCGPDFOutlineTitle as String: "Cells", kCGPDFOutlineDestination as String: 1],
                [kCGPDFOutlineTitle as String: "Genetics", kCGPDFOutlineDestination as String: 2],
            ]] as CFDictionary)
            for _ in 0..<2 { context.beginPage() }
        }
        let file = try await document.package.importAsset(from: source, ext: "pdf")
        let pages = try PDFImport.pages(at: document.package.assetURL(file), file: file)
        session.insert(pages, at: 1, actionName: "Insert PDF")
        await session.readContents()
        XCTAssertEqual(session.contents.map(\.title), ["Cells", "Genetics"], "the PDF's pages came in, so its contents are read")
        XCTAssertEqual(session.contents.map(\.pageID), pages.map(\.id))

        document.removePages([pages[0].id])
        await session.readContents()
        XCTAssertEqual(session.contents.map(\.title), ["Genetics"], "and read again once one of its pages has gone")
    }
}
