import XCTest
import PDFKit
import PencilKit
import SwiftData
@testable import OwlLuna

/// A PDF goes into a notebook already in the library: after its last page, through its document when it is open, and
/// not at all when the PDF can't be read or the notebook can't take it.
@MainActor
final class PDFIntoNotebookTests: XCTestCase {
    private var container: ModelContainer?

    private func makeStore() throws -> LibraryStore {
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        self.container = container
        return LibraryStore(root: temporaryRoot(self), context: container.mainContext)
    }

    /// Two ruled pages with ink on the first, saved and in the index.
    private func makeNotebook(in store: LibraryStore) async throws -> NotebookManifest {
        let manifest = NotebookManifest(title: "Physics", defaults: PageDefaults(template: .narrowRuled, paperColor: .white, pageSize: .letter),
                                        pages: (0..<2).map { _ in .template(.narrowRuled, color: .white, size: .letter) })
        let package = NotebookPackage(root: store.root, id: manifest.id)
        try await package.create(manifest)
        let ink = PKDrawing(strokes: [dot(at: CGPoint(x: 80, y: 80))])
        let saved = try await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[0].id: ink])).manifest
        store.index(saved)
        return saved
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

    private func file(_ name: String, holding data: Data) throws -> URL {
        let url = temporaryRoot(self).url.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// A PDF written out object by object, for one no renderer would make.
    private func pdf(_ name: String, objects: [String]) throws -> URL {
        var contents = "%PDF-1.4\n", offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(contents.utf8.count)
            contents += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = contents.utf8.count
        contents += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { contents += String(format: "%010d 00000 n \n", offset) }
        contents += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return try file("\(name).pdf", holding: Data(contents.utf8))
    }

    /// Every file in a notebook's package, with what it holds.
    private func files(of id: UUID, in store: LibraryStore) throws -> [String: Data] {
        let package = store.root.package(id)
        var files: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: package.path(percentEncoded: false)) {
            let url = package.appending(path: path)
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            files[path] = try Data(contentsOf: url)
        }
        return files
    }

    private func arriving(_ store: LibraryStore) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.root.arriving.path(percentEncoded: false))) ?? []
    }

    /// Opens a notebook as an editor does, with its saves going to the index.
    private func open(_ id: UUID, in store: LibraryStore) async throws -> NotebookDocument {
        try await DocumentRegistry.shared.open(id, root: store.root, scene: nil) { [weak store] document in
            document.onSaved = { store?.index($0) }
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func assertRefused<Failure: Error & Equatable>(_ expected: Failure, _ work: @MainActor () async throws -> [UUID],
                                                           file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await work()
            XCTFail("the pages must not go in", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? Failure, expected, file: file, line: line)
        }
    }

    func testAPDFsPagesGoAfterTheLastPageOfAClosedNotebook() async throws {
        let store = try makeStore()
        let notebook = try await makeNotebook(in: store)
        let before = try files(of: notebook.id, in: store)
        let source = try pdf("Handout", pages: 3)
        var indexSaves = 0
        store.onIndexSaved = { indexSaves += 1 }

        let added = try await store.addPDF(from: source, to: notebook.id)

        let package = NotebookPackage(root: store.root, id: notebook.id)
        let manifest = try await package.readManifest().manifest
        XCTAssertEqual(Array(manifest.pages.prefix(2)), notebook.pages, "the pages it had are as they were")
        XCTAssertEqual(manifest.pages.dropFirst(2).map(\.id), added, "the PDF's follow them, in its order")
        let kept = try XCTUnwrap(manifest.pages.last?.background.assetFile)
        XCTAssertEqual(manifest.pages.dropFirst(2).map(\.background), (0..<3).map { PageBackground.pdf(file: kept, index: $0) })
        XCTAssertEqual(CGPDFDocument(package.assetURL(kept) as CFURL)?.numberOfPages, 3)
        let after = try files(of: notebook.id, in: store)
        XCTAssertEqual(after.keys.filter { $0.hasPrefix("assets/") }, ["assets/\(kept)"], "one copy of the PDF, and nothing else, is added")
        let ink = "ink/\(notebook.pages[0].id.uuidString).pkdrawing"
        XCTAssertNotNil(before[ink])
        XCTAssertEqual(after[ink], before[ink], "its ink isn't touched")
        XCTAssertGreaterThan(manifest.modifiedAt, notebook.modifiedAt)

        let record = try XCTUnwrap(store.record(notebook.id))
        XCTAssertEqual(record.pageCount, 5)
        XCTAssertGreaterThan(record.modifiedAt, notebook.modifiedAt)
        XCTAssertEqual(record.manifestDate, LibraryIndex.manifestDate(ofPackage: package.url), "the record has read the file as it now is")
        XCTAssertGreaterThan(indexSaves, 0, "which is what a sync follows")
        XCTAssertNil(DocumentRegistry.shared.document(for: notebook.id), "nothing was opened to do it")
        XCTAssertEqual(arriving(store), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)), "the copy it was given is the caller's to discard")
        XCTAssertNil(store.lastError)
    }

    func testAnOpenNotebookTakesThePagesThroughItsDocument() async throws {
        let store = try makeStore()
        let notebook = try await makeNotebook(in: store)
        let document = try await open(notebook.id, in: store)
        defer { DocumentRegistry.shared.unregister(notebook.id, document: document) }
        var sent = 0
        document.onWritten = { sent += 1 }
        // Ink that isn't saved yet, as when the PDF arrives while the notebook is being written in.
        document.canvasDidChangeInk(notebook.pages[1].id, to: PKDrawing(strokes: [dot(at: CGPoint(x: 120, y: 200))]))

        let added = try await store.addPDF(from: try pdf("Handout", pages: 3), to: notebook.id)

        XCTAssertEqual(document.pages.map(\.id), notebook.pages.map(\.id) + added, "its editor has them, after the last page")
        XCTAssertEqual(document.loadedInk(notebook.pages[1].id)?.strokes.count, 1)
        XCTAssertEqual(document.undoManager.undoActionName, "Insert PDF")
        XCTAssertFalse(document.hasUnsavedChanges, "and it is the document that saved them")
        XCTAssertGreaterThan(sent, 0, "which is what a sync follows")
        let saved = try await document.package.readManifest().manifest
        XCTAssertEqual(saved.pages.map(\.id), notebook.pages.map(\.id) + added)
        XCTAssertEqual(saved.pages[0], notebook.pages[0])
        XCTAssertNotNil(saved.pages[1].inkHash, "the ink being written was saved with them")
        let kept = try XCTUnwrap(saved.pages.last?.background.assetFile)
        XCTAssertEqual(CGPDFDocument(document.package.assetURL(kept) as CFURL)?.numberOfPages, 3)
        XCTAssertEqual(store.record(notebook.id)?.pageCount, 5)
        XCTAssertTrue(DocumentRegistry.shared.document(for: notebook.id) === document)
        XCTAssertEqual(arriving(store), [])

        document.undoManager.undo()
        XCTAssertEqual(document.pages.map(\.id), notebook.pages.map(\.id), "undo in its editor takes them out again")
        await document.flush()
    }

    func testANotebookStillSavingAfterItClosedTakesThePagesInTheDocumentKeptForIt() async throws {
        let store = try makeStore()
        let notebook = try await makeNotebook(in: store)
        let document = try await open(notebook.id, in: store)
        document.retryBase = .milliseconds(50)
        // Its saves fail, so closing it leaves the document with the registry, retrying.
        let ink = document.package.inkDirectory, aside = document.package.url.appending(path: "ink-aside")
        try FileManager.default.moveItem(at: ink, to: aside)
        try Data("blocker".utf8).write(to: ink)
        document.rename("Physics II")
        let flushed = await document.flush(attempts: 1)
        XCTAssertFalse(flushed)
        var released = false
        DocumentRegistry.shared.keepUntilSaved(document, retryEvery: .milliseconds(50)) { released = true }
        XCTAssertTrue(DocumentRegistry.shared.document(for: notebook.id) === document)

        let added = try await store.addPDF(from: try pdf("Handout", pages: 2), to: notebook.id)

        XCTAssertEqual(document.pages.map(\.id), notebook.pages.map(\.id) + added, "they wait in the document with what it couldn't save")
        var saved = try await document.package.readManifest().manifest
        XCTAssertEqual(saved.pages, notebook.pages, "nothing is written behind it")
        XCTAssertEqual(store.record(notebook.id)?.pageCount, 2, "and the record waits for the save")

        try FileManager.default.removeItem(at: ink)
        try FileManager.default.moveItem(at: aside, to: ink)
        await waitUntil { released }
        XCTAssertTrue(released)
        saved = try await document.package.readManifest().manifest
        XCTAssertEqual(saved.title, "Physics II")
        XCTAssertEqual(saved.pages.map(\.id), notebook.pages.map(\.id) + added)
        XCTAssertEqual(store.record(notebook.id)?.pageCount, 4)
        let kept = try XCTUnwrap(saved.pages.last?.background.assetFile)
        XCTAssertEqual(CGPDFDocument(document.package.assetURL(kept) as CFURL)?.numberOfPages, 2)
    }

    func testANotebookStillOpeningTakesThePagesInItsDocument() async throws {
        let store = try makeStore()
        let notebook = try await makeNotebook(in: store)
        let registry = DocumentRegistry.shared, root = store.root
        // A write under way holds the open back, so the PDF arrives while the notebook is opening.
        XCTAssertTrue(registry.startWriting(notebook.id))
        var held = true
        defer { if held { registry.doneWriting(notebook.id) } }
        let opening = Task { try await registry.open(notebook.id, root: root, scene: nil) { _ in } }
        defer { opening.cancel() }
        await waitUntil { registry.isOpening(notebook.id) }
        guard registry.isOpening(notebook.id) else { return XCTFail("The notebook did not begin opening") }
        let source = try pdf("Handout", pages: 2)
        let adding = Task { try await store.addPDF(from: source, to: notebook.id) }
        try await Task.sleep(for: .milliseconds(300))
        let untouched = try await NotebookPackage(root: root, id: notebook.id).readManifest().manifest
        XCTAssertEqual(untouched.pages, notebook.pages, "nothing is written under the open")
        registry.doneWriting(notebook.id)
        held = false

        let document = try await opening.value
        defer { registry.unregister(notebook.id, document: document) }
        let added = try await adding.value
        XCTAssertEqual(document.pages.map(\.id), notebook.pages.map(\.id) + added)
        let saved = try await document.package.readManifest().manifest
        XCTAssertEqual(saved.pages.map(\.id), notebook.pages.map(\.id) + added)
    }

    func testASyncWithTheNotebookInHandFinishesFirstAndAChangeMadeMeanwhileLandsToo() async throws {
        let store = try makeStore()
        let notebook = try await makeNotebook(in: store)
        let record = try XCTUnwrap(store.record(notebook.id))
        let registry = DocumentRegistry.shared
        XCTAssertTrue(registry.take(notebook.id), "a sync is copying the notebook")
        var inHand = true
        defer { if inHand { registry.release(notebook.id) } }
        let before = try files(of: notebook.id, in: store)
        let source = try pdf("Handout", pages: 2)
        let adding = Task { try await store.addPDF(from: source, to: notebook.id) }
        // Once the PDF is ready the store says a change is coming, and a sync asking again is told to leave the notebook.
        await waitUntil { !registry.take(notebook.id) }
        store.setTags(["Exam"], for: [record])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try files(of: notebook.id, in: store), before, "nothing is written while the sync has it")
        registry.release(notebook.id)
        inHand = false

        let added = try await adding.value
        XCTAssertEqual(record.pageCount, 4, "the record is current as soon as the pages are in")
        let manifest = try await NotebookPackage(root: store.root, id: notebook.id).readManifest().manifest
        XCTAssertEqual(manifest.pages.map(\.id), notebook.pages.map(\.id) + added)
        XCTAssertEqual(manifest.library.tags, ["Exam"], "the change queued behind the pages kept them")
        XCTAssertEqual(record.tags, ["Exam"])
        XCTAssertTrue(registry.take(notebook.id), "and the notebook is a sync's to take again")
        registry.release(notebook.id)
    }

    func testALockedPDFGoesInWithItsPasswordAndNotAtAllWhenSkipped() async throws {
        let store = try makeStore()
        let notebook = try await makeNotebook(in: store)
        let source = try pdf("Lab Sheet", pages: 2, password: "owl")
        let original = try Data(contentsOf: source)
        let before = try files(of: notebook.id, in: store)

        let skipping = Prompt([nil])
        await assertRefused(ImportError.locked) { try await store.addPDF(from: source, to: notebook.id, password: skipping.answer) }
        XCTAssertEqual(skipping.asked, [false])
        await assertRefused(ImportError.locked) { try await store.addPDF(from: source, to: notebook.id) }
        XCTAssertEqual(try files(of: notebook.id, in: store), before, "skipped, or with no one to ask, it leaves nothing in the notebook")
        XCTAssertEqual(store.record(notebook.id)?.pageCount, 2)
        XCTAssertEqual(arriving(store), [], "and the locked copy doesn't stay behind")

        let retrying = Prompt(["cat", "owl"])
        let first = try await store.addPDF(from: source, to: notebook.id, password: retrying.answer)
        XCTAssertEqual(retrying.asked, [false, true], "a wrong password asks again")
        let knowing = Prompt(["owl"])
        let second = try await store.addPDF(from: source, to: notebook.id, password: knowing.answer)
        XCTAssertEqual(knowing.asked, [false])

        let package = NotebookPackage(root: store.root, id: notebook.id)
        let manifest = try await package.readManifest().manifest
        XCTAssertEqual(manifest.pages.map(\.id), notebook.pages.map(\.id) + first + second)
        for page in manifest.pages.dropFirst(2) {
            let kept = try XCTUnwrap(CGPDFDocument(package.assetURL(try XCTUnwrap(page.background.assetFile)) as CFURL))
            XCTAssertFalse(kept.isEncrypted, "kept without its lock, like an imported one")
            XCTAssertEqual(kept.numberOfPages, 2)
        }
        XCTAssertEqual(store.record(notebook.id)?.pageCount, 6)
        XCTAssertEqual(try Data(contentsOf: source), original, "the source keeps its lock")
        XCTAssertEqual(arriving(store), [])
    }

    func testAPDFThatCantBeReadLeavesAClosedNotebookAsItWas() async throws {
        let store = try makeStore()
        let notebook = try await makeNotebook(in: store)
        let record = try XCTUnwrap(store.record(notebook.id))
        let before = try files(of: notebook.id, in: store), indexed = record.indexedAt
        // Core Graphics refuses a PDF with no pages before the importer can count them.
        let unreadable = [try file("Old Scan.pdf", holding: Data("not a pdf".utf8)), try file("Nothing.pdf", holding: Data()),
                          try pdf("Empty", objects: ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>"])]
        for source in unreadable {
            XCTAssertNil(CGPDFDocument(source as CFURL))
            await assertRefused(ImportError.invalidPDF) { try await store.addPDF(from: source, to: notebook.id) }
            XCTAssertEqual(try files(of: notebook.id, in: store), before, "no page and no copy of the PDF is left in it")
            XCTAssertEqual(arriving(store), [])
        }
        do {
            try await store.addPDF(from: temporaryRoot(self).url.appending(path: "Moved.pdf"), to: notebook.id)
            XCTFail("a file that isn't there can't be copied")
        } catch {
            XCTAssertNil(error as? ImportError, "a file access failure keeps its own error")
        }
        XCTAssertEqual(try files(of: notebook.id, in: store), before)
        XCTAssertEqual(arriving(store), [])
        XCTAssertEqual(record.pageCount, 2)
        XCTAssertEqual(record.indexedAt, indexed, "and its record isn't touched")
        XCTAssertNil(store.lastError, "the failure is thrown, not left for the shelf to report as well")
    }

    func testAPDFThatCantBeReadLeavesAnOpenNotebookAsItWas() async throws {
        let store = try makeStore()
        let notebook = try await makeNotebook(in: store)
        let document = try await open(notebook.id, in: store)
        defer { DocumentRegistry.shared.unregister(notebook.id, document: document) }
        let before = try files(of: notebook.id, in: store)
        let locked = try pdf("Lab Sheet", pages: 1, password: "owl")

        await assertRefused(ImportError.invalidPDF) {
            try await store.addPDF(from: try self.file("Old Scan.pdf", holding: Data("not a pdf".utf8)), to: notebook.id)
        }
        await assertRefused(ImportError.locked) { try await store.addPDF(from: locked, to: notebook.id, password: Prompt([nil]).answer) }

        XCTAssertEqual(document.pages, notebook.pages)
        XCTAssertFalse(document.undoManager.canUndo, "there is nothing for its editor to undo")
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertEqual(try files(of: notebook.id, in: store), before)
        XCTAssertEqual(arriving(store), [])
    }

    func testANotebookThatIsGoneBinnedOrFromANewerVersionTakesNothing() async throws {
        let store = try makeStore()
        // Locked, so a notebook that is refused only after the PDF was made ready would have asked for its password.
        let source = try pdf("Lab Sheet", pages: 1, password: "owl")
        let prompt = Prompt(["owl", "owl", "owl"])

        await assertRefused(AddPagesError.notebookGone) { try await store.addPDF(from: source, to: UUID(), password: prompt.answer) }
        XCTAssertEqual(store.root.packageIDs(), [], "nothing is made for a notebook the library doesn't have")
        XCTAssertEqual(AddPagesError.notebookGone.localizedDescription, "This notebook is no longer in your library.")

        let binned = try await makeNotebook(in: store)
        let record = try XCTUnwrap(store.record(binned.id))
        XCTAssertTrue(store.takesPages(record))
        store.moveToTrash([record])
        await store.finishWritingNotebooks()
        XCTAssertFalse(store.takesPages(record))
        var before = try files(of: binned.id, in: store)
        await assertRefused(AddPagesError.notebookGone) { try await store.addPDF(from: source, to: binned.id, password: prompt.answer) }
        XCTAssertEqual(try files(of: binned.id, in: store), before)

        var newer = NotebookManifest(title: "Chemistry", defaults: PageDefaults(template: .grid, paperColor: .white, pageSize: .letter),
                                     pages: [.template(.grid, color: .white, size: .letter)])
        newer.schemaVersion = NotebookManifest.currentSchemaVersion + 7
        let package = NotebookPackage(root: store.root, id: newer.id)
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: true)
        try ManifestCodec.encode(newer).write(to: package.manifestURL)
        store.index(newer)
        XCTAssertFalse(store.takesPages(try XCTUnwrap(store.record(newer.id))))
        before = try files(of: newer.id, in: store)
        await assertRefused(PackageError.readOnly) { try await store.addPDF(from: source, to: newer.id, password: prompt.answer) }
        XCTAssertEqual(try files(of: newer.id, in: store), before, "one this version mustn't save whole isn't written")

        XCTAssertEqual(prompt.asked, [], "and none of them asks for the PDF's password first")
        XCTAssertEqual(arriving(store), [])
    }

    func testANotebookBinnedWhileThePasswordIsAskedForTakesNothing() async throws {
        let store = try makeStore()
        let notebook = try await makeNotebook(in: store)
        let record = try XCTUnwrap(store.record(notebook.id))
        let source = try pdf("Lab Sheet", pages: 2, password: "owl")

        await assertRefused(AddPagesError.notebookGone) {
            try await store.addPDF(from: source, to: notebook.id, password: { _ in
                store.moveToTrash([record])
                return "owl"
            })
        }
        await store.finishWritingNotebooks()
        let manifest = try await NotebookPackage(root: store.root, id: notebook.id).readManifest().manifest
        XCTAssertEqual(manifest.pages, notebook.pages)
        XCTAssertNotNil(manifest.library.deletedAt)
        XCTAssertEqual(try files(of: notebook.id, in: store).keys.filter { $0.hasPrefix("assets/") }, [], "the PDF made ready for it isn't left in it")
        XCTAssertEqual(record.pageCount, 2)
        XCTAssertEqual(arriving(store), [])
    }

    func testALockedNotebookTakesPagesAndStaysLocked() async throws {
        let store = try makeStore()
        let notebook = try await makeNotebook(in: store)
        let record = try XCTUnwrap(store.record(notebook.id))
        store.setLocked(true, for: [record])
        XCTAssertTrue(store.takesPages(record), "the lock covers what is in it, not what is added to it")

        let added = try await store.addPDF(from: try pdf("Handout", pages: 1), to: notebook.id)

        let manifest = try await NotebookPackage(root: store.root, id: notebook.id).readManifest().manifest
        XCTAssertEqual(manifest.pages.map(\.id), notebook.pages.map(\.id) + added)
        XCTAssertTrue(manifest.library.isLocked, "the lock written just before the pages is kept")
        XCTAssertTrue(record.isLocked)
        XCTAssertEqual(record.pageCount, 3)
    }
}

/// A locked PDF's password prompt: what it was asked, and what it answers in turn.
@MainActor
private final class Prompt {
    private(set) var asked: [Bool] = []
    private var answers: [String?]

    init(_ answers: [String?]) { self.answers = answers }

    func answer(_ wrong: Bool) -> String? {
        asked.append(wrong)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}
