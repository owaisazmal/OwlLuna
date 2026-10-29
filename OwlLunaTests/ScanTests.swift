import XCTest
import PDFKit
import SwiftData
@testable import OwlLuna

/// Scanned sheets become pages, and what is printed on them is read for search, as it is on a PDF of scanned pages.
@MainActor
final class ScanTests: XCTestCase {
    private var container: ModelContainer?
    /// As tall as a sample sheet is for a letter page's width.
    private let sheetSize = CGSize(width: 612, height: 866)

    private func makeStore() throws -> LibraryStore {
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        self.container = container
        return LibraryStore(root: temporaryRoot(self), context: container.mainContext)
    }

    /// Recognition runs at utility priority. Asked for from a test, which runs above that, it is a priority inversion;
    /// awaiting the task's value would only raise it to the test's priority, so it answers a continuation.
    private func index(_ job: HandwritingIndexer.Job) async -> String {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) { continuation.resume(returning: await HandwritingIndexer.shared.index(job)) }
        }
    }

    private func makePDF(size: CGSize, _ draw: (CGRect) -> Void) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "scanned-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).writePDF(to: url) { context in
            context.beginPage()
            draw(context.pdfContextBounds)
        }
        return url
    }

    /// A page that is only the picture of a printed sheet, as in a scanned book.
    private func scannedPDF() throws -> URL {
        let sheet = DocumentScan.samples()[0]
        return try makePDF(size: sheetSize) { sheet.draw(in: $0) }
    }

    func testAScanIsShrunkAndFillsItsPage() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 4000), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 4000))
        }
        let picture = try DocumentScan.picture(sheet)
        XCTAssertEqual(picture.size, CGSize(width: 1800, height: 2400), "no more than 2,400 px on the long side")
        XCTAssertNotNil(UIImage(data: picture.data))
        let page = DocumentScan.page(file: "sheet.jpg", pictureSize: picture.size)
        XCTAssertEqual(page.background, .image(file: "sheet.jpg"))
        XCTAssertEqual(page.size, CGSize(width: 612, height: 816), "as wide as a letter page, as tall as the paper was")
        XCTAssertThrowsError(try DocumentScan.picture(UIImage()))
    }

    func testScannedSheetsBecomeANotebook() async throws {
        let store = try makeStore()
        let id = try await store.importScan(DocumentScan.samples(), folder: nil)
        let record = try XCTUnwrap(store.record(id))
        XCTAssertEqual(record.pageCount, 2)
        XCTAssertEqual(record.coverStyle, .firstPage, "its first sheet is its cover")
        XCTAssertTrue(record.title.hasPrefix("Scan "))
        let package = NotebookPackage(root: store.root, id: id)
        let manifest = try await package.readManifest().manifest
        for page in manifest.pages {
            let file = try XCTUnwrap(page.background.assetFile)
            XCTAssertTrue(FileManager.default.fileExists(atPath: package.assetURL(file).path(percentEncoded: false)))
        }
        do {
            _ = try await store.importScan([], folder: nil)
            XCTFail("a scan with no sheets makes no notebook")
        } catch {
            XCTAssertEqual(store.notebooks().count, 1)
        }
    }

    func testWhatIsPrintedOnAScanIsSearchable() async throws {
        let root = temporaryRoot(self)
        let package = NotebookPackage(root: root, id: UUID())
        let pages = try await DocumentScan.pages(from: DocumentScan.samples(), in: package)
        let manifest = NotebookManifest(id: package.id, title: "Scan", defaults: PageDefaults(template: .blank, paperColor: .white, pageSize: .letter), pages: pages)
        try await package.create(manifest)
        XCTAssertEqual(HandwritingIndexer.header(for: pages[0]), "#ink:none+img\n")

        // A page stamped before pictures were read is read again.
        try await package.writeText("#ink:none\n", pageID: pages[0].id)
        let text = await index(HandwritingIndexer.Job(package: package, pages: pages))
        try XCTSkipIf(text.isEmpty, "text recognition isn't available on this simulator")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("quarterly report"), "read as \(text)")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("agenda"))
        let first = await package.readText(pages[0].id)
        XCTAssertEqual(first?.hasPrefix("#ink:none+img\n"), true)
    }

    func testAPDFPageWithNextToNoTextIsAPicture() throws {
        XCTAssertTrue(PDFText.isPicture(withText: nil))
        XCTAssertTrue(PDFText.isPicture(withText: "  \n Page 12 of 300 \n"), "a page number or a scanner's name isn't text of its own")
        XCTAssertFalse(PDFText.isPicture(withText: "Photosynthesis turns light, water and carbon dioxide into sugar."))
        let page = try XCTUnwrap(PDFDocument(url: scannedPDF())?.page(at: 0))
        XCTAssertTrue(PDFText.isPicture(withText: page.string))
        let picture = try XCTUnwrap(PDFText.picture(of: page))
        XCTAssertEqual(picture.size.height, 2400, "as large as a scan")
        XCTAssertEqual(picture.size.width, 2400 * 612 / 866, accuracy: 1)
    }

    func testWhatIsPrintedOnAScannedPDFIsSearchable() async throws {
        let package = NotebookPackage(root: temporaryRoot(self), id: UUID())
        let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
        try await package.create(NotebookManifest(id: package.id, title: "Textbook", defaults: paper, pages: [paper.newPage()]))
        let scanned = try await package.importAsset(from: scannedPDF(), ext: "pdf")
        let printed = try await package.importAsset(from: makePDF(size: PageSize.letter.points) { _ in
            ("Photosynthesis turns light, water and carbon dioxide into sugar." as NSString)
                .draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }, ext: "pdf")
        let pages = try PDFImport.pages(at: package.assetURL(scanned), file: scanned) + PDFImport.pages(at: package.assetURL(printed), file: printed)
        XCTAssertEqual(HandwritingIndexer.header(for: pages[0]), "#ink:none+pdf\n")

        // Both were stamped before PDF pages were marked. The printed one was read right then, so it is only stamped anew.
        try await package.writeText("#ink:none\n", pageID: pages[0].id)
        try await package.writeText("#ink:none\nas read before", pageID: pages[1].id)
        _ = await index(HandwritingIndexer.Job(package: package, pages: pages))
        let second = await package.readText(pages[1].id)
        XCTAssertEqual(second, "#ink:none+pdf\nas read before")

        let first = await package.readText(pages[0].id) ?? ""
        try XCTSkipIf(StudyGuide.body(ofPageText: first).isEmpty, "text recognition isn't available on this simulator")
        XCTAssertTrue(first.hasPrefix("#ink:none+pdf\n"))
        XCTAssertTrue(first.localizedCaseInsensitiveContains("quarterly report"), "read as \(first)")
        XCTAssertTrue(first.localizedCaseInsensitiveContains("revenue grew"))

        // Read afresh, a printed page is read from its own text.
        try await package.writeText("#ink:stale\n", pageID: pages[1].id)
        _ = await index(HandwritingIndexer.Job(package: package, pages: [pages[1]]))
        let reread = await package.readText(pages[1].id)
        XCTAssertEqual(reread?.hasPrefix("#ink:none+pdf\nPhotosynthesis turns light"), true, "read as \(reread ?? "nothing")")
    }

    func testWordsOnAScannedPDFAreFoundWhereTheyArePrinted() async throws {
        let url = try scannedPDF()
        let reader = FindReader()
        let rects = await reader.pdfRects(for: SearchQuery("revenue"), file: url, index: 0, pageSize: sheetSize).rects
        try XCTSkipIf(rects.isEmpty, "text recognition isn't available on this simulator")
        XCTAssertEqual(rects.count, 1)
        // On the sheet the line starts 120 px in and 340 px down, in 56 pt type, on a sheet 1,240 px wide.
        XCTAssertEqual(rects[0].minX, 120 * sheetSize.width / 1240, accuracy: 12)
        XCTAssertEqual(rects[0].midY, 374 * sheetSize.width / 1240, accuracy: 16)
        let none = await reader.pdfRects(for: SearchQuery("goodbye"), file: url, index: 0, pageSize: sheetSize).rects
        XCTAssertTrue(none.isEmpty)
    }
}
