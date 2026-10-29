import XCTest
import PDFKit
import SwiftData
@testable import OwlLuna

/// Chosen PDFs come in one at a time: one that can't be read doesn't stop the rest, and a locked one opens with its password.
@MainActor
final class PDFImportTests: XCTestCase {
    private var container: ModelContainer?

    private func makeStore() throws -> LibraryStore {
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        self.container = container
        return LibraryStore(root: temporaryRoot(self), context: container.mainContext)
    }

    private func pdf(_ name: String, pages: Int, password: String? = nil) throws -> URL {
        let url = temporaryRoot(self).url.appending(path: "\(name).pdf")
        let format = UIGraphicsPDFRendererFormat()
        if let password { format.documentInfo = [kCGPDFContextUserPassword as String: password, kCGPDFContextOwnerPassword as String: password] }
        try UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: PageSize.letter.points), format: format).writePDF(to: url) { context in
            for index in 0..<pages {
                context.beginPage()
                UIColor.black.setFill()
                context.fill(CGRect(x: 10, y: 10, width: 40 + CGFloat(index) * 10, height: 20))
            }
        }
        return url
    }

    private func importing(_ urls: [URL], into store: LibraryStore) -> PDFImportRun {
        let run = PDFImportRun()
        run.add(urls) { url, password, progress in
            try await store.importPDF(from: url, folder: nil, password: password, progress: progress)
        }
        return run
    }

    /// Answers each password asked for in turn, and gives back what was asked.
    private func answering(_ run: PDFImportRun, with answers: [String?]) -> Task<[PDFImportRun.Asking], Never> {
        Task { @MainActor in
            var asked: [PDFImportRun.Asking] = []
            for answer in answers {
                var tries = 0
                while run.asking == nil, tries < 1000 {
                    tries += 1
                    try? await Task.sleep(for: .milliseconds(10))
                }
                guard let asking = run.asking else { break }
                asked.append(asking)
                run.answer(answer)
            }
            return asked
        }
    }

    func testABatchBringsInEveryPDFItCanAndNamesTheOneItCouldnt() async throws {
        let store = try makeStore()
        let broken = temporaryRoot(self).url.appending(path: "Old Scan.pdf")
        try Data("not a pdf".utf8).write(to: broken)
        let run = importing([try pdf("Week 1", pages: 2), broken, try pdf("Lab Sheet", pages: 3, password: "owl"), try pdf("Week 2", pages: 1)],
                            into: store)
        let answers = answering(run, with: ["cat", "owl"])
        await run.finish()

        let asked = await answers.value
        XCTAssertEqual(asked, [PDFImportRun.Asking(name: "Lab Sheet", wrong: false), PDFImportRun.Asking(name: "Lab Sheet", wrong: true)],
                       "a wrong password asks again")
        XCTAssertNil(run.asking)
        XCTAssertEqual(run.missed.map(\.name), ["Old Scan"])
        XCTAssertEqual(run.missed.first?.reason, "Can't be read")
        XCTAssertTrue(run.hasNews)
        XCTAssertEqual(run.fraction, 1)

        let records = try store.context.fetch(FetchDescriptor<NotebookRecord>())
        XCTAssertEqual(records.map(\.title).sorted(), ["Lab Sheet", "Week 1", "Week 2"], "the PDFs after the broken one still came in")
        let lab = try XCTUnwrap(records.first { $0.title == "Lab Sheet" })
        let package = NotebookPackage(root: store.root, id: lab.id)
        let manifest = try await package.readManifest().manifest
        XCTAssertEqual(manifest.pages.count, 3)
        guard case .pdf(let file, _) = manifest.pages[0].background else { return XCTFail("the pages stand on the PDF") }
        let kept = try XCTUnwrap(CGPDFDocument(package.assetURL(file) as CFURL))
        XCTAssertFalse(kept.isEncrypted, "kept without its lock, so it opens, exports and syncs like any other")
        XCTAssertEqual(kept.numberOfPages, 3)
    }

    func testSkippingALockedPDFBringsNothingInAndIsntNews() async throws {
        let store = try makeStore()
        let run = importing([try pdf("Lab Sheet", pages: 1, password: "owl")], into: store)
        let answers = answering(run, with: [nil])
        await run.finish()

        let asked = await answers.value
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(run.missed.map(\.wasSkipped), [true])
        XCTAssertFalse(run.hasNews, "skipping it was the choice made, so there's nothing to tell")
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<NotebookRecord>()), 0)
        let arriving = (try? FileManager.default.contentsOfDirectory(atPath: store.root.arriving.path(percentEncoded: false))) ?? []
        XCTAssertEqual(arriving, [], "the locked copy doesn't stay behind")
    }

    func testWithNoOneToAskALockedPDFIsRefused() async throws {
        let store = try makeStore()
        do {
            try await store.importPDF(from: try pdf("Lab Sheet", pages: 1, password: "owl"), folder: nil)
            XCTFail("a locked PDF needs its password")
        } catch {
            XCTAssertEqual(error as? ImportError, .locked)
        }
    }

    func testAnUnlockedPDFHasNoLockAndKeepsItsOutlineAndLinks() throws {
        // PDFKit on iOS drops a file's outline and links when it writes it again, so the textbook is made new.
        let pages = try XCTUnwrap(PDFDocument(url: try pdf("Textbook", pages: 3)))
        let textbook = PDFDocument()
        for index in 0..<3 { textbook.insert(try XCTUnwrap(pages.page(at: index)?.copy() as? PDFPage), at: index) }
        let link = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 50, height: 50), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: try XCTUnwrap(textbook.page(at: 2)), at: CGPoint(x: 0, y: 700))
        textbook.page(at: 0)?.addAnnotation(link)
        let outline = PDFOutline()
        for index in 0..<3 {
            let chapter = PDFOutline()
            chapter.label = "Chapter \(index + 1)"
            chapter.destination = PDFDestination(page: try XCTUnwrap(textbook.page(at: index)), at: .zero)
            outline.insertChild(chapter, at: index)
        }
        textbook.outlineRoot = outline
        let url = temporaryRoot(self).url.appending(path: "Locked Textbook.pdf")
        XCTAssertTrue(textbook.write(to: url, withOptions: [.userPasswordOption: "owl", .ownerPasswordOption: "owl"]))
        XCTAssertTrue(try PDFImport.isLocked(url))

        XCTAssertFalse(try PDFImport.unlock(url, with: "cat"))
        XCTAssertTrue(try PDFImport.isLocked(url), "a wrong password leaves it as it was")
        XCTAssertTrue(try PDFImport.unlock(url, with: "owl"))
        XCTAssertFalse(try XCTUnwrap(CGPDFDocument(url as CFURL)).isEncrypted)

        let open = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertFalse(open.isLocked)
        XCTAssertEqual(open.pageCount, 3)
        let chapters = (0..<(open.outlineRoot?.numberOfChildren ?? 0)).compactMap { open.outlineRoot?.child(at: $0) }
        XCTAssertEqual(chapters.map(\.label), ["Chapter 1", "Chapter 2", "Chapter 3"])
        XCTAssertEqual(chapters.last?.destination?.page.map(open.index(for:)), 2)
        let kept = try XCTUnwrap(open.page(at: 0)?.annotations.first)
        XCTAssertEqual(kept.destination?.page.map(open.index(for:)), 2, "the link still goes to the third page")
    }

    func testReadingALongPDFSaysHowFarItHasGot() throws {
        final class Seen: @unchecked Sendable { var values: [Double] = [] }
        let seen = Seen()
        let pages = try PDFImport.pages(at: try pdf("Long", pages: 250), file: "long.pdf") { seen.values.append($0) }
        XCTAssertEqual(pages.count, 250)
        XCTAssertLessThanOrEqual(seen.values.count, 125, "about a hundred steps, not one a page")
        XCTAssertEqual(seen.values, seen.values.sorted())
        XCTAssertEqual(seen.values.last, 1)
    }
}
