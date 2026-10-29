import XCTest
import PDFKit
import PencilKit
@testable import OwlLuna

/// Find in a notebook: where the words are in typed text, PDF text and handwriting, and the order matches are shown in.
@MainActor
final class FindTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)

    private func textBox(_ string: String, at center: CGPoint) -> PageItem {
        PageItem(content: .text(TextBox(string: string)), center: center, size: CGSize(width: 200, height: 40))
    }

    private func makeDocument(_ pages: [NotebookPage], ink: [UUID: PKDrawing] = [:]) async throws -> NotebookDocument {
        let root = temporaryRoot(self)
        let manifest = NotebookManifest(title: "Find", defaults: paper, pages: pages)
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        if !ink.isEmpty { _ = try await package.write(SaveSnapshot(manifest: manifest, ink: ink)) }
        return try await NotebookDocument.open(manifest.id, root: root)
    }

    private func finish(_ finder: NotebookFinder) async {
        for _ in 0..<400 where finder.isSearching { try? await Task.sleep(for: .milliseconds(25)) }
    }

    /// A letter sheet with each line printed 30 pt under the one before, in 14 pt type.
    private func sheet(_ lines: [String]) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: PageSize.letter.points)).pdfData { context in
            context.beginPage()
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 72, y: 100 + CGFloat(index) * 30), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
        }
    }

    private func makeDocument(printing lines: [String], items: [PageItem] = []) async throws -> NotebookDocument {
        let root = temporaryRoot(self), id = UUID()
        let package = NotebookPackage(root: root, id: id)
        let file = try await package.writeAsset(sheet(lines), ext: "pdf")
        var page = NotebookPage(background: .pdf(file: file, index: 0), paperColor: .white, size: PageSize.letter.points)
        page.items = items
        try await package.create(NotebookManifest(id: id, title: "Find", defaults: paper, pages: [page]))
        return try await NotebookDocument.open(id, root: root)
    }

    /// Each line in 64 pt type, 240 px under the one before, on a white picture 1,200 px wide.
    private func picture(_ lines: [String]) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 600), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 120 + CGFloat(index) * 240),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 64), .foregroundColor: UIColor.black])
            }
        }
    }

    func testATextBoxHoldingTheWordsIsMarkedWhole() {
        var page = paper.newPage()
        page.items = [textBox("Mitochondria make ATP", at: CGPoint(x: 200, y: 100)), textBox("Ribosomes", at: CGPoint(x: 200, y: 300))]
        XCTAssertEqual(NotebookFind.typed(SearchQuery("atp"), on: page).rects, [CGRect(x: 100, y: 80, width: 200, height: 40)])
        XCTAssertEqual(NotebookFind.typed(SearchQuery("RIBO"), on: page).rects.count, 1, "whatever the case")
        XCTAssertTrue(NotebookFind.typed(SearchQuery("golgi"), on: page).rects.isEmpty)
        var turned = page
        turned.items[0].rotation = .pi / 2
        XCTAssertEqual(NotebookFind.typed(SearchQuery("atp"), on: turned).rects[0].integral, CGRect(x: 180, y: 0, width: 40, height: 200),
                       "a turned box is marked by the room it takes")
    }

    func testWordsInAPDFAreFoundWhereTheyArePrinted() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "find-\(UUID().uuidString).pdf")
        let bounds = CGRect(origin: .zero, size: PageSize.letter.points)
        try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: url) { context in
            context.beginPage()
            ("Chapter Seven" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 28)])
            ("The seven sisters and seven seas" as NSString).draw(at: CGPoint(x: 72, y: 400), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let rects = NotebookFind.inReadingOrder(NotebookFind.pdfRects(for: SearchQuery("seven"), on: page, pageSize: bounds.size).rects)
        XCTAssertEqual(rects.count, 3)
        XCTAssertEqual(rects[0].midY, 89, accuracy: 12, "the heading, measured from the top of the page")
        XCTAssertGreaterThan(rects[0].minX, 150)
        XCTAssertEqual(rects[1].midY, 408, accuracy: 10)
        XCTAssertLessThan(rects[1].minX, rects[2].minX, "matches on a line run left to right")
        XCTAssertTrue(NotebookFind.pdfRects(for: SearchQuery("eight"), on: page, pageSize: bounds.size).rects.isEmpty)
    }

    func testHandwritingIsFoundWhereItWasWritten() async throws {
        let page = paper.newPage()
        let ink = PKDrawing(strokes: BlockLetters.strokes("HELLO", origin: CGPoint(x: 150, y: 160)))
        let reader = FindReader()
        let rects = await reader.inkRects(for: SearchQuery("hello"), page: page, ink: ink, assets: FileManager.default.temporaryDirectory).rects
        try XCTSkipIf(rects.isEmpty, "text recognition isn't available on this simulator")
        XCTAssertEqual(rects.count, 1)
        XCTAssertTrue(rects[0].intersects(ink.bounds), "\(rects[0]) should lie over \(ink.bounds)")
        XCTAssertEqual(rects[0].midY, ink.bounds.midY, accuracy: 30)
        let none = await reader.inkRects(for: SearchQuery("goodbye"), page: page, ink: ink, assets: FileManager.default.temporaryDirectory).rects
        XCTAssertTrue(none.isEmpty)
    }

    func testMatchesStartFromThePageBeingReadAndComeRound() async throws {
        var pages = [paper.newPage(), paper.newPage(), paper.newPage()]
        pages[0].items = [textBox("enzyme kinetics", at: CGPoint(x: 200, y: 100))]
        pages[2].items = [textBox("an enzyme", at: CGPoint(x: 200, y: 500)), textBox("Enzyme again", at: CGPoint(x: 200, y: 100))]
        let document = try await makeDocument(pages)
        let finder = NotebookFinder(document: document)
        finder.delay = .zero
        finder.startPage = { 1 }
        var changes = 0
        finder.onChange = { changes += 1 }

        finder.search("enzyme")
        await finish(finder)
        XCTAssertEqual(finder.matches.map(\.page), [0, 2, 2], "in page order")
        XCTAssertEqual(finder.matches.map(\.rect.midY), [100, 100, 500], "and down each page")
        XCTAssertEqual(finder.position, 1, "the first one shown is the nearest ahead of the page being read")
        XCTAssertGreaterThan(changes, 0)

        finder.step(1)
        XCTAssertEqual(finder.position, 2)
        finder.step(1)
        XCTAssertEqual(finder.position, 0, "past the last match it comes round to the first")
        finder.step(-1)
        XCTAssertEqual(finder.position, 2)

        finder.search("ribosome")
        await finish(finder)
        XCTAssertTrue(finder.matches.isEmpty)
        XCTAssertNil(finder.current)
        finder.search("  ")
        XCTAssertFalse(finder.isSearching, "nothing to look for")
        finder.clear()
        XCTAssertEqual(finder.query, "")
    }

    func testAPageReadAsNotHoldingTheWordsIsNotReadAgain() async throws {
        let page = paper.newPage()
        let ink = PKDrawing(strokes: BlockLetters.strokes("HELLO", origin: CGPoint(x: 150, y: 160)))
        let document = try await makeDocument([page], ink: [page.id: ink])
        let saved = try XCTUnwrap(document.pages.first)
        XCTAssertNotNil(saved.inkHash)
        // The search index says this page reads "goodbye": the finder trusts it while the ink hasn't changed.
        try await document.package.writeText(HandwritingIndexer.header(for: saved) + "goodbye", pageID: saved.id)
        let finder = NotebookFinder(document: document)
        finder.delay = .zero
        finder.search("hello")
        await finish(finder)
        XCTAssertTrue(finder.matches.isEmpty)

        try await document.package.writeText("#ink:stale\ngoodbye", pageID: saved.id)
        finder.search("hello ")
        await finish(finder)
        try XCTSkipIf(finder.matches.isEmpty, "text recognition isn't available on this simulator")
        XCTAssertEqual(finder.matches.count, 1, "an out-of-date reading is not trusted")
    }

    func testEachWordIsMarkedInAnyOrderAndAPhraseAsOne() throws {
        let page = try XCTUnwrap(PDFDocument(data: sheet(["Mitochondria make ATP for the cell", "while ribosomes make proteins"]))?.page(at: 0))
        let size = PageSize.letter.points
        let words = NotebookFind.inReadingOrder(NotebookFind.pdfRects(for: SearchQuery("atp mitochondria"), on: page, pageSize: size).rects)
        XCTAssertEqual(words.count, 2)
        XCTAssertLessThan(words[0].maxX, words[1].minX, "each word where it is")
        XCTAssertEqual(words[1].midY, 108, accuracy: 8)

        let phrase = NotebookFind.inReadingOrder(NotebookFind.pdfRects(for: SearchQuery("Make proteins"), on: page, pageSize: size).rects)
        XCTAssertEqual(phrase.count, 2, "make on its own, then make proteins as one mark")
        XCTAssertEqual(phrase[1].midY, 138, accuracy: 8)
        XCTAssertGreaterThan(phrase[1].width, phrase[0].width * 2)
        let inside = NotebookFind.pdfRects(for: SearchQuery("tochondria"), on: page, pageSize: size).rects
        XCTAssertEqual(inside.count, 1, "a word begun nowhere is marked where it is")
    }

    func testATermThatBeginsNoWordIsMarkedInsideEveryWordThatHasIt() throws {
        let page = try XCTUnwrap(PDFDocument(data: sheet(["Photosynthesis and biosynthesis by the bell tower shell"]))?.page(at: 0))
        let size = PageSize.letter.points
        let found = NotebookFind.pdfRects(for: SearchQuery("synthesis photosynthesis"), on: page, pageSize: size)
        let synthesis = NotebookFind.inReadingOrder(found.rects)
        XCTAssertEqual(synthesis.count, 2, "photosynthesis whole, and the end of biosynthesis")
        XCTAssertGreaterThan(synthesis.first?.width ?? 0, synthesis.last?.width ?? 0)
        let bell = NotebookFind.inReadingOrder(NotebookFind.pdfRects(for: SearchQuery("ell bell"), on: page, pageSize: size).rects)
        XCTAssertEqual(bell.count, 2, "bell, and the end of shell")
    }

    func testWordsSpreadOverATextBoxAndPrintedTextAreFound() async throws {
        let document = try await makeDocument(printing: ["Photosynthesis turns light into sugar in the leaf", "of every green plant in spring"],
                                              items: [textBox("Chlorophyll is green", at: CGPoint(x: 300, y: 600))])
        let finder = NotebookFinder(document: document)
        finder.delay = .zero
        finder.search("chlorophyll photosynthesis")
        await finish(finder)
        XCTAssertEqual(finder.matches.count, 2)
        XCTAssertEqual(finder.matches.first?.rect.midY ?? 0, 108, accuracy: 8, "the printed word first, down the page")
        XCTAssertEqual(finder.matches.last?.rect.midY, 600)
    }

    func testAPageWithOnlySomeOfTheWordsGetsNoMarks() async throws {
        var pages = [paper.newPage(), paper.newPage()]
        pages[0].items = [textBox("an enzyme", at: CGPoint(x: 200, y: 100))]
        pages[1].items = [textBox("kinetics", at: CGPoint(x: 200, y: 500)), textBox("Enzyme again", at: CGPoint(x: 200, y: 100))]
        let document = try await makeDocument(pages)
        let finder = NotebookFinder(document: document)
        finder.delay = .zero
        finder.search("kinetics enzyme")
        await finish(finder)
        XCTAssertEqual(finder.matches.map(\.page), [1, 1])
        XCTAssertEqual(finder.matches.map(\.rect.midY), [100, 500])

        let printed = try await makeDocument(printing: ["Photosynthesis turns light into sugar in the leaf"],
                                             items: [textBox("Chlorophyll is green", at: CGPoint(x: 300, y: 600))])
        let other = NotebookFinder(document: printed)
        other.delay = .zero
        other.search("chlorophyll glucose")
        await finish(other)
        XCTAssertTrue(other.matches.isEmpty)
    }

    func testAQuotedPhraseOverALineBreakIsMarkedOnBothLines() throws {
        let page = try XCTUnwrap(PDFDocument(data: sheet(["The leaf turns light into stored", "sugar for the plant to use later"]))?.page(at: 0))
        let size = PageSize.letter.points
        for query in ["\"stored sugar\"", "“stored sugar”", "„stored sugar“", "«stored sugar»"] {
            let found = NotebookFind.pdfRects(for: SearchQuery(query), on: page, pageSize: size)
            XCTAssertTrue(found.holds(SearchQuery(query)), query)
            let rects = NotebookFind.inReadingOrder(found.rects)
            XCTAssertEqual(rects.count, 2, query)
            guard rects.count == 2 else { continue }
            XCTAssertEqual(rects[0].midY, 108, accuracy: 8, "the end of the first line")
            XCTAssertGreaterThan(rects[0].minX, 150)
            XCTAssertEqual(rects[1].midY, 138, accuracy: 8, "the start of the next")
            XCTAssertEqual(rects[1].minX, 72, accuracy: 6)
        }
        let reversed = SearchQuery("“sugar stored”")
        XCTAssertFalse(NotebookFind.pdfRects(for: reversed, on: page, pageSize: size).holds(reversed))
    }

    func testAPhraseOverTwoReadLinesIsMarkedOnBoth() throws {
        guard let lines = NotebookFind.read(picture(["Plants turn the light", "into sugar each day"])), lines.count >= 2 else {
            throw XCTSkip("text recognition isn't available on this simulator")
        }
        let found = NotebookFind.rects(for: SearchQuery("“light into”"), in: lines, pageSize: CGSize(width: 600, height: 300))
        let rects = NotebookFind.inReadingOrder(found.rects)
        XCTAssertEqual(rects.count, 2, "read as \(lines.map(\.text.string))")
        guard rects.count == 2 else { return }
        XCTAssertLessThan(rects[0].midY, 150)
        XCTAssertGreaterThan(rects[0].minX, 200, "the end of the first line")
        XCTAssertGreaterThan(rects[1].midY, 150)
        XCTAssertLessThan(rects[1].minX, 100, "the start of the next")
    }

    func testAReadWordIsMarkedOnceThoughTheTermIsInItTwice() throws {
        guard let lines = NotebookFind.read(picture(["We assess the banana"])), !lines.isEmpty else {
            throw XCTSkip("text recognition isn't available on this simulator")
        }
        let rects = NotebookFind.rects(for: SearchQuery("ss"), in: lines, pageSize: CGSize(width: 600, height: 300)).rects
        XCTAssertEqual(rects.count, 1, "read as \(lines.map(\.text.string))")
    }

    func testAReadingWithThePhraseOverALineBreakIsNotPassedOver() async throws {
        let document = try await makeDocument(printing: ["The leaf turns light into stored", "sugar for the plant to use later"])
        let page = try XCTUnwrap(document.pages.first)
        let header = HandwritingIndexer.header(for: page)
        try await document.package.writeText(header + "The leaf turns light into stored\nsugar for the plant to use later", pageID: page.id)
        let finder = NotebookFinder(document: document)
        finder.delay = .zero
        finder.search("“stored sugar”")
        await finish(finder)
        XCTAssertEqual(finder.matches.count, 2)

        try await document.package.writeText(header + "The leaf turns light", pageID: page.id)
        finder.search("“stored sugar”")
        await finish(finder)
        XCTAssertTrue(finder.matches.isEmpty, "the reading is trusted while it is current")
    }

    func testPresenterNotesCountTowardThePageButAreNotMarked() async throws {
        var page = paper.newPage()
        page.items = [textBox("enzyme", at: CGPoint(x: 200, y: 100))]
        page.notes = "Kinetics"
        let typed = NotebookFind.typed(SearchQuery("enzyme kinetics"), on: page)
        XCTAssertTrue(typed.holds(SearchQuery("enzyme kinetics")))
        XCTAssertEqual(typed.rects, [CGRect(x: 100, y: 80, width: 200, height: 40)])

        let document = try await makeDocument([page])
        let finder = NotebookFinder(document: document)
        finder.delay = .zero
        finder.search("enzyme kinetics")
        await finish(finder)
        XCTAssertEqual(finder.matches.map(\.rect.midY), [100], "the box is marked though the notes hold the other word")
    }
}
