import XCTest
import SwiftData
import PencilKit
@testable import OwlLuna

/// Paper of the user's own: kept beside the library from a PDF's first page or a picture, and copied into each notebook that uses it.
@MainActor
final class PaperShelfTests: XCTestCase {
    private var containers: [ModelContainer] = []

    private func pdf(_ sizes: [CGSize], password: String? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "Lab Sheet \(UUID().uuidString.prefix(4)).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsPDFRendererFormat()
        if let password { format.documentInfo = [kCGPDFContextUserPassword as String: password, kCGPDFContextOwnerPassword as String: password] }
        try UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: sizes[0]), format: format).writePDF(to: url) { context in
            for (index, size) in sizes.enumerated() {
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                UIColor.black.setFill()
                context.fill(CGRect(x: 10, y: 10, width: 40 + CGFloat(index) * 10, height: 20))
            }
        }
        return url
    }

    private func picture(_ size: CGSize, opaque: Bool = true) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        }
    }

    private func makeStore(defaults: UserDefaults) throws -> LibraryStore {
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        containers.append(container)
        return LibraryStore(root: temporaryRoot(self), context: container.mainContext, defaults: defaults)
    }

    private func ownSettings() throws -> UserDefaults {
        let suite = "owlluna-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func makeDocument(_ root: StorageRoot, pages: [NotebookPage]) async throws -> NotebookDocument {
        let manifest = NotebookManifest(title: "Paper", defaults: PageDefaults(template: .narrowRuled, paperColor: .white, pageSize: .letter), pages: pages)
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let document = try await NotebookDocument.open(manifest.id, root: root)
        document.saveDelay = .milliseconds(20)
        document.undoManager.groupsByEvent = false
        return document
    }

    private func assertSize(_ size: CGSize, _ expected: CGSize, _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(size.width, expected.width, accuracy: 0.01, message, line: line)
        XCTAssertEqual(size.height, expected.height, accuracy: 0.01, message, line: line)
    }

    /// One undo step, as the editor would make it.
    private func step(_ document: NotebookDocument, _ action: () async throws -> Void) async rethrows {
        document.undoManager.beginUndoGrouping()
        defer { document.undoManager.endUndoGrouping() }
        try await action()
    }

    private func assets(of document: NotebookDocument) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: document.package.assetsDirectory.path(percentEncoded: false))) ?? []
    }

    // MARK: The shelf

    func testAPDFGivesItsFirstPageAsPaper() throws {
        let root = temporaryRoot(self)
        let source = try pdf([CGSize(width: 400, height: 300), PageSize.letter.points, PageSize.letter.points])
        let paper = try PaperShelf.add(file: source, to: root)
        XCTAssertTrue(paper.isPDF)
        XCTAssertEqual(paper.name, source.deletingPathExtension().lastPathComponent, "named after the file")
        assertSize(paper.size, CGSize(width: 400, height: 300), "a PDF keeps the size its page was made at")
        XCTAssertEqual(CGPDFDocument(paper.url as CFURL)?.numberOfPages, 1, "only the first page is kept")
        XCTAssertEqual(paper.url.deletingLastPathComponent().standardizedFileURL, root.papers.standardizedFileURL)
        XCTAssertEqual(paper.newPageSize(width: 612), paper.size)
        XCTAssertEqual(PaperShelf.list(root), [paper])
    }

    func testAPictureIsKeptAtMost2400PixelsAndTakesTheWidthItIsGiven() throws {
        let root = temporaryRoot(self)
        let paper = try PaperShelf.add(image: picture(CGSize(width: 3000, height: 1500)), name: "Score", to: root)
        XCTAssertFalse(paper.isPDF)
        XCTAssertEqual(paper.url.pathExtension, "jpg")
        let image = try XCTUnwrap(UIImage(contentsOfFile: paper.url.path(percentEncoded: false)))
        XCTAssertEqual(image.size.width * image.scale, 2400)
        XCTAssertEqual(paper.size, CGSize(width: 612, height: 306))
        XCTAssertEqual(paper.newPageSize(width: PageSize.a5.points.width).height, (PageSize.a5.points.width / 2).rounded())

        let clear = try PaperShelf.add(image: picture(CGSize(width: 200, height: 400), opaque: false), name: "Letterhead", to: root)
        XCTAssertEqual(clear.url.pathExtension, "png", "a picture with transparency keeps it")
    }

    func testPapersAreListedByNameAndKeepTheirIDWhenRenamed() throws {
        let root = temporaryRoot(self)
        let week = try PaperShelf.add(image: picture(CGSize(width: 100, height: 140)), name: "Week", to: root)
        let day = try PaperShelf.add(image: picture(CGSize(width: 100, height: 140)), name: "Day 2", to: root)
        let ten = try PaperShelf.add(image: picture(CGSize(width: 100, height: 140)), name: "Day 10", to: root)
        XCTAssertEqual(PaperShelf.list(root).map(\.name), ["Day 2", "Day 10", "Week"])

        let renamed = try PaperShelf.rename(week, to: " .Month/Plan:Week\n")
        XCTAssertEqual(renamed.id, week.id)
        XCTAssertEqual(renamed.name, "Month-Plan-Week", "slashes, colons and a leading dot can't be part of a file's name")
        XCTAssertEqual(PaperShelf.paper(week.id, in: root)?.name, "Month-Plan-Week")
        XCTAssertEqual(try PaperShelf.rename(day, to: "   ").name, "Paper")

        PaperShelf.remove(ten)
        XCTAssertEqual(PaperShelf.list(root).map(\.id).sorted(), [week.id, day.id].sorted())
    }

    func testFilesThatArentPaperAreRefusedOrLeftOut() throws {
        let root = temporaryRoot(self)
        let fake = FileManager.default.temporaryDirectory.appending(path: "fake-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: fake)
        addTeardownBlock { try? FileManager.default.removeItem(at: fake) }
        XCTAssertThrowsError(try PaperShelf.add(file: fake, to: root)) { XCTAssertEqual($0 as? ImportError, .unreadable) }
        XCTAssertThrowsError(try PaperShelf.add(image: Data([1, 2, 3]), name: "Noise", to: root)) { XCTAssertEqual($0 as? ImportError, .unreadable) }
        XCTAssertThrowsError(try PaperShelf.add(file: pdf([PageSize.letter.points], password: "owl"), to: root)) {
            XCTAssertEqual($0 as? ImportError, .locked)
        }

        try FileManager.default.createDirectory(at: root.papers, withIntermediateDirectories: true)
        try picture(CGSize(width: 10, height: 10)).write(to: root.papers.appending(path: "stray.png"))
        try Data("x".utf8).write(to: root.papers.appending(path: "Notes \(UUID().uuidString).txt"))
        try Data("x".utf8).write(to: root.papers.appending(path: "Broken \(UUID().uuidString).pdf"))
        XCTAssertEqual(PaperShelf.list(root), [], "only whole papers named with an ID are listed")
    }

    func testProtectedPaperAsksAgainAndKeepsAnUnlockedCopy() async throws {
        let root = temporaryRoot(self)
        let source = try pdf([PageSize.letter.points], password: "owl")
        var attempts: [Bool] = []
        let paper = try await PaperShelf.add(file: source, to: root) { wrong in
            attempts.append(wrong)
            return wrong ? "owl" : "wrong"
        }
        XCTAssertEqual(attempts, [false, true])
        XCTAssertFalse(try PDFImport.isLocked(paper.url))
        XCTAssertEqual(paper.size, PageSize.letter.points)
    }

    // MARK: In a notebook

    func testAPageOnYourOwnPaperKeepsOneCopyInTheNotebook() async throws {
        let root = temporaryRoot(self)
        let paper = try PaperShelf.add(file: pdf([PageSize.a4.points, PageSize.letter.points]), to: root)
        let document = try await makeDocument(root, pages: [.template(.narrowRuled, color: .white, size: .letter)])
        let session = EditorSession(document: document)

        try await step(document) { try await session.addPage(after: 0, paper: paper, size: .letter) }
        XCTAssertEqual(document.pages.count, 2)
        XCTAssertEqual(session.currentPage, 1)
        let page = document.pages[1]
        XCTAssertEqual(page.paperID, paper.id)
        XCTAssertNil(page.template)
        assertSize(page.size, PageSize.a4.points, "a PDF paper keeps its own size")
        guard case .pdf(let file, 0) = page.background else { return XCTFail("the page's background is the PDF") }
        XCTAssertEqual(assets(of: document), [file])

        try await step(document) { try await session.addPage(after: 1, paper: paper, size: nil) }
        XCTAssertEqual(document.pages[2].background, page.background, "a second page uses the same copy")
        XCTAssertEqual(assets(of: document), [file])

        let next = document.newPage(after: 2)
        XCTAssertEqual(next.background, page.background, "a new page after one on your own paper continues it")
        XCTAssertEqual(next.paperID, paper.id)
        XCTAssertEqual(next.size, page.size)
        let ruled = document.newPage(after: 2, template: .grid)
        XCTAssertNil(ruled.paperID)
        XCTAssertEqual(ruled.template, .grid)

        PaperShelf.remove(paper)
        await document.flush()
        let reopened = try await NotebookPackage(root: root, id: document.id).readManifest().manifest
        XCTAssertEqual(reopened.pages[1].paperID, paper.id, "the page remembers the paper it came from")
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.package.assetURL(file).path(percentEncoded: false)),
                      "removing the paper leaves the notebook's copy")
    }

    func testChangingAPageToYourOwnPaperKeepsItsWidthAndIsOneUndoStep() async throws {
        let root = temporaryRoot(self)
        let paper = try PaperShelf.add(image: picture(CGSize(width: 1600, height: 800)), name: "Wide", to: root)
        let document = try await makeDocument(root, pages: [.template(.narrowRuled, color: .kraft, size: .a5)])
        let session = EditorSession(document: document)
        let id = document.pages[0].id

        try await step(document) { try await session.setPaper(paper, forPage: id) }
        XCTAssertEqual(document.pages[0].paperID, paper.id)
        XCTAssertEqual(document.pages[0].size, CGSize(width: PageSize.a5.points.width, height: (PageSize.a5.points.width / 2).rounded()))
        XCTAssertEqual(document.pages[0].effectivePaperColor, .white)
        guard case .image = document.pages[0].background else { return XCTFail("the page's background is the picture") }
        XCTAssertEqual(document.undoManager.undoActionName, "Change Paper")

        document.undoManager.undo()
        XCTAssertEqual(document.pages[0].template, .narrowRuled)
        XCTAssertEqual(document.pages[0].paperColor, .kraft)
        XCTAssertEqual(document.pages[0].size, PageSize.a5.points)
        XCTAssertNil(document.pages[0].paperID)
        XCTAssertFalse(document.undoManager.canUndo)
        document.undoManager.redo()

        await step(document) { document.setPaper(template: .grid, color: .sage, forPage: id) }
        XCTAssertEqual(document.pages[0].template, .grid, "a page on your own paper can go back to a template")
        XCTAssertEqual(document.pages[0].paperColor, .sage)
        XCTAssertNil(document.pages[0].paperID)
    }

    func testWhiteboardsAndImportedPagesAreLeftAsTheyAre() async throws {
        let root = temporaryRoot(self)
        let paper = try PaperShelf.add(image: picture(CGSize(width: 100, height: 140)), name: "Plan", to: root)
        let imported = NotebookPage(background: .pdf(file: "book.pdf", index: 3), paperColor: .white, size: PageSize.letter.points)
        let board = NotebookPage.board(template: .dotted, color: .white)
        let document = try await makeDocument(root, pages: [imported, board])
        let session = EditorSession(document: document)
        try await session.setPaper(paper, forPage: imported.id)
        try await session.setPaper(paper, forPage: board.id)
        XCTAssertEqual(document.pages, [imported, board])
        XCTAssertFalse(document.undoManager.canUndo)
    }

    func testYourOwnPaperIsLeftUnreadForSearchAsATemplateIs() {
        var sheet = NotebookPage(background: .pdf(file: "sheet.pdf", index: 0), paperColor: .white, size: PageSize.letter.points)
        var photo = NotebookPage(background: .image(file: "photo.jpg"), paperColor: .white, size: PageSize.letter.points)
        XCTAssertTrue(sheet.hasPDFText && photo.hasPicture, "an imported PDF or photo is read")
        sheet.paperID = UUID().uuidString
        photo.paperID = UUID().uuidString
        XCTAssertFalse(sheet.hasPDFText || photo.hasPicture, "its words are on every page that uses it")
        XCTAssertEqual(HandwritingIndexer.header(for: sheet), "#ink:none\n")
    }

    // MARK: New notebooks

    func testANotebookStartedOnYourOwnPaperMakesItsPagesOnItsCopy() async throws {
        let settings = try ownSettings()
        let store = try makeStore(defaults: settings)
        let paper = try PaperShelf.add(image: picture(CGSize(width: 800, height: 1000)), name: "Planner", to: store.root)
        let id = try await store.createNotebook(title: "Plans", cover: .defaultCloth(for: UUID()),
                                                defaults: PageDefaults(template: .dotted, paperColor: .ivory, pageSize: .a4), folder: nil, paper: paper)
        let manifest = try await NotebookPackage(root: store.root, id: id).readManifest().manifest
        let first = try XCTUnwrap(manifest.pages.first)
        XCTAssertEqual(first.paperID, paper.id)
        XCTAssertEqual(first.size, paper.fitted(width: PageSize.a4.points.width), "a picture takes the width of the size chosen")
        let file = try XCTUnwrap(first.background.assetFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: NotebookPackage(root: store.root, id: id).assetURL(file).path(percentEncoded: false)))
        XCTAssertEqual(manifest.defaults.paper?.background, first.background)
        XCTAssertEqual(manifest.defaults.template, .dotted, "older builds still find a template")

        let document = try await NotebookDocument.open(id, root: store.root)
        let next = document.newPage(after: nil)
        XCTAssertEqual(next.background, first.background, "pages added where nothing comes before them use the notebook's paper too")
        XCTAssertEqual(next.size, first.size)
        let reused = try await document.keepCopy(of: paper)
        XCTAssertEqual(reused.background, first.background)
    }

    func testQuickNoteUsesYourOwnPaperWhileItIsThere() async throws {
        let settings = try ownSettings()
        let store = try makeStore(defaults: settings)
        let paper = try PaperShelf.add(file: pdf([PageSize.a5.points]), to: store.root)
        settings.set(PaperTemplate.grid.rawValue, forKey: SettingsKey.defaultTemplate)
        settings.set(paper.id, forKey: SettingsKey.defaultPaper)
        let onPaper = try await store.createQuickNote(folder: nil)
        let first = try await NotebookPackage(root: store.root, id: onPaper).readManifest().manifest.pages[0]
        XCTAssertEqual(first.paperID, paper.id)
        assertSize(first.size, PageSize.a5.points)

        PaperShelf.remove(paper)
        let plain = try await store.createQuickNote(folder: nil)
        let fallback = try await NotebookPackage(root: store.root, id: plain).readManifest().manifest.pages[0]
        XCTAssertEqual(fallback.template, .grid, "with the paper gone, the template stands in")
    }

    // MARK: Previews

    func testAMiniatureOfYourOwnPaperKeepsItsAspect() async throws {
        let root = temporaryRoot(self)
        let paper = try PaperShelf.add(file: pdf([CGSize(width: 800, height: 400)]), to: root)
        let image = await PaperPreviewCache.image(of: paper, width: 120, scale: 2)
        XCTAssertEqual(image.size.width, 120)
        XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.02)
        XCTAssertTrue(image === PaperPreviewCache.cached(PaperPreviewCache.key(paper: paper, width: 120, scale: 2)))
    }
}
