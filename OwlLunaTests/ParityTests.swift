import XCTest
import PencilKit
import PDFKit
import SwiftData
import SwiftUI
@testable import OwlLuna

/// Coverage for the features ported from v1 in M6, and the search and keyboard additions from the brief.
@MainActor
final class ParityTests: XCTestCase {
    private var container: ModelContainer?

    private func makeStore() throws -> LibraryStore {
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        self.container = container
        return LibraryStore(root: temporaryRoot(self), context: container.mainContext)
    }

    private func makeNotebook(_ root: StorageRoot, pages: [NotebookPage]) async throws -> NotebookManifest {
        let manifest = NotebookManifest(title: "Biology", defaults: PageDefaults(template: .narrowRuled, paperColor: .white, pageSize: .letter), pages: pages)
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        return manifest
    }

    func testSnippetShowsTheTextAroundTheMatch() {
        let text = "#ink:abc\nThe mitochondria is the powerhouse of the cell, and ribosomes build proteins from amino acids."
        let snippet = PageSearch.snippet(in: text, for: "RIBOSOMES", radius: 12)
        XCTAssertEqual(snippet, "…e cell, and ribosomes build prote…")
        XCTAssertNil(PageSearch.snippet(in: text, for: "chloroplast"))
        XCTAssertNil(PageSearch.snippet(in: text, for: "abc"), "the ink header is never searched")
        XCTAssertEqual(PageSearch.snippet(in: "#ink:none\nCafé notes", for: "cafe"), "Café notes", "diacritic- and case-insensitive")
    }

    func testHighlightedSnippetMarksEveryMatch() {
        let text = PageSearch.highlighted("Café and cafe", query: "cafe")
        XCTAssertEqual(String(text.characters), "Café and cafe", "the characters are unchanged")
        let marked = text.runs.filter { $0[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] != nil }.map { String(text[$0.range].characters) }
        XCTAssertEqual(marked, ["Café", "cafe"])
        XCTAssertEqual(PageSearch.highlighted("no match here", query: "cafe").runs.count, 1)
    }

    func testPageHitsListTheMatchingPagesInOrder() async throws {
        let root = temporaryRoot(self)
        let pages = (0..<4).map { _ in NotebookPage.template(.blank, color: .white, size: .letter) }
        let manifest = try await makeNotebook(root, pages: pages)
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.writeText("#ink:none\nosmosis and diffusion", pageID: pages[1].id)
        try await package.writeText("#ink:none\nactive transport", pageID: pages[2].id)
        try await package.writeText("#ink:none\nosmosis again", pageID: pages[3].id)
        let hits = await PageSearch.hits(for: "osmosis", in: [manifest.id], root: root)
        XCTAssertEqual(hits.pages[manifest.id]?.map(\.index), [1, 3])
        XCTAssertEqual(hits.pages[manifest.id]?.first?.page.id, pages[1].id)
    }

    func testQuickNoteUsesTheSettingsDefaultsAndTheCurrentShelf() async throws {
        let store = try makeStore()
        let defaults = UserDefaults.standard
        let saved = [SettingsKey.defaultTemplate, SettingsKey.defaultPaperColor, SettingsKey.defaultPageSize].map { ($0, defaults.object(forKey: $0)) }
        addTeardownBlock { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        defaults.set(PaperTemplate.dotted.rawValue, forKey: SettingsKey.defaultTemplate)
        defaults.set(PaperColor.ivory.rawValue, forKey: SettingsKey.defaultPaperColor)
        defaults.set(PageSize.a5.rawValue, forKey: SettingsKey.defaultPageSize)
        let folder = try XCTUnwrap(store.createFolder(name: "Lab", cloth: .jade))
        let id = try await store.createQuickNote(folder: folder)
        let manifest = try await NotebookPackage(root: store.root, id: id).readManifest().manifest
        XCTAssertEqual(manifest.pages.first?.template, .dotted)
        XCTAssertEqual(manifest.pages.first?.paperColor, .ivory)
        XCTAssertEqual(manifest.pages.first?.size, PageSize.a5.points)
        XCTAssertEqual(manifest.library.folderID, folder.id)
        XCTAssertTrue(manifest.title.hasPrefix("Note "), manifest.title)
        XCTAssertEqual(store.record(id)?.folder?.id, folder.id)
    }

    func testShelvesCanBeReorderedAndSortedByName() async throws {
        let store = try makeStore()
        let c = try XCTUnwrap(store.createFolder(name: "Chemistry", cloth: .jade))
        let a = try XCTUnwrap(store.createFolder(name: "Art", cloth: .rose))
        let b = try XCTUnwrap(store.createFolder(name: "Biology", cloth: .moss))
        store.moveFolders([c, a, b], from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual([b, c, a].map(\.sortIndex), [0, 1, 2])
        store.sortFoldersByName([b, c, a])
        XCTAssertEqual([a, b, c].map(\.sortIndex), [0, 1, 2])
        await store.finishWritingShelves()
        XCTAssertEqual(FolderFile.read(store.root).folders.map(\.name), ["Art", "Biology", "Chemistry"])
    }

    func testANotebookCanBeExportedFromTheLibraryWithoutOpeningIt() async throws {
        let root = temporaryRoot(self)
        let pages = (0..<3).map { _ in NotebookPage.template(.grid, color: .white, size: .letter) }
        let manifest = try await makeNotebook(root, pages: pages)
        _ = try await NotebookPackage(root: root, id: manifest.id).write(SaveSnapshot(manifest: manifest, ink: [pages[1].id: PKDrawing(strokes: [dot(at: CGPoint(x: 80, y: 80))])]))
        let job = try await ExportJob.forNotebook(manifest.id, root: root)
        defer { job.close() }
        let deadline = Date().addingTimeInterval(20)
        while case .running = job.state, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard case .finished(let urls) = job.state, let url = urls.first else { return XCTFail("export ended as \(job.state)") }
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 3)
        XCTAssertEqual(url.lastPathComponent, "Biology.pdf")
    }

    func testRecognitionLeavesExportsAndShelfWritesAbleToFinish() async throws {
        // Vision on a cold CI runner can take most of a minute by itself; a starved export never finishes at all.
        executionTimeAllowance = 180
        let store = try makeStore()
        let page = NotebookPage.template(.grid, color: .white, size: .letter)
        let manifest = try await makeNotebook(store.root, pages: [page])
        let package = NotebookPackage(root: store.root, id: manifest.id)
        let saved = try await package.write(SaveSnapshot(manifest: manifest, ink: [page.id: PKDrawing(strokes: [dot(at: CGPoint(x: 80, y: 80))])]))

        async let indexed = HandwritingIndexer.shared.index(.init(package: package, pages: saved.manifest.pages))
        let job = try await ExportJob.forNotebook(manifest.id, root: store.root)
        defer { job.close() }
        _ = try XCTUnwrap(store.createFolder(name: "Biology", cloth: .moss))
        await store.finishWritingShelves()
        _ = await indexed
        let text = await package.readText(page.id)
        XCTAssertTrue(text?.hasPrefix(HandwritingIndexer.header(for: saved.manifest.pages[0])) == true)
        XCTAssertEqual(FolderFile.read(store.root).folders.map(\.name), ["Biology"])

        let deadline = Date().addingTimeInterval(20)
        while job.state == .running, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard case .finished(let urls) = job.state, let url = urls.first else { return XCTFail("export ended as \(job.state)") }
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 1)
    }

    func testInsertedPagesMatchThePageTheyFollowAndDuplicatesReportWhereTheyWent() async throws {
        let root = temporaryRoot(self)
        var styled = NotebookPage.template(.grid, color: .yellow, size: .a5)
        styled.paperColor = .yellow
        let pdf = NotebookPage(background: .pdf(file: "x.pdf", index: 0), paperColor: .white, size: CGSize(width: 800, height: 600))
        let manifest = try await makeNotebook(root, pages: [styled, pdf])
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let afterStyled = document.newPage(after: 0)
        XCTAssertEqual(afterStyled.template, .grid)
        XCTAssertEqual(afterStyled.paperColor, .yellow)
        XCTAssertEqual(afterStyled.size, PageSize.a5.points)
        let afterPDF = document.newPage(after: 1)
        XCTAssertEqual(afterPDF.template, .narrowRuled, "a PDF page's background isn't copied; the notebook defaults are used")
        XCTAssertEqual(afterPDF.size, PageSize.letter.points)
        XCTAssertEqual(document.newPage(after: 0, template: .music).template, .music)
        let position = await document.duplicatePage(at: 0)
        XCTAssertEqual(position, 1)
        XCTAssertEqual(document.pages[1].template, .grid)
    }

    func testEditorKeyboardCommands() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root, pages: [.template(.blank, color: .white, size: .letter)])
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let controller = PageStackController(session: EditorSession(document: document))
        let commands = Set((controller.keyCommands ?? []).map { "\($0.modifierFlags.rawValue)|\($0.input ?? "")" })
        let expected: [(String, UIKeyModifierFlags)] = [
            (UIKeyCommand.inputUpArrow, []), (UIKeyCommand.inputDownArrow, []), (" ", []), (" ", .shift),
            (UIKeyCommand.inputUpArrow, .command), (UIKeyCommand.inputDownArrow, .command),
            (UIKeyCommand.inputPageUp, []), (UIKeyCommand.inputPageDown, []), (UIKeyCommand.inputHome, []), (UIKeyCommand.inputEnd, []),
        ]
        for (input, flags) in expected {
            XCTAssertTrue(commands.contains("\(flags.rawValue)|\(input)"), "missing \(input) with \(flags)")
        }
    }

    func testNewShelvesGoAfterTheLastOne() async throws {
        let store = try makeStore()
        let a = try XCTUnwrap(store.createFolder(name: "A", cloth: .jade))
        let b = try XCTUnwrap(store.createFolder(name: "B", cloth: .moss))
        store.deleteFolder(a)
        let c = try XCTUnwrap(store.createFolder(name: "C", cloth: .rose))
        XCTAssertGreaterThan(c.sortIndex, b.sortIndex, "a deleted shelf's index is never reused")
    }

    func testSearchIsOnlyRedoneWhenSearchableDataChanges() async throws {
        let store = try makeStore()
        let manifest = try await makeNotebook(store.root, pages: [.template(.blank, color: .white, size: .letter)])
        store.index(manifest)
        let afterCreate = store.searchVersion
        var edited = manifest
        edited.modifiedAt = .now.addingTimeInterval(60)
        edited.library.currentPage = 0
        store.index(edited)
        XCTAssertEqual(store.searchVersion, afterCreate, "an autosave that only dates the notebook doesn't redo search")
        edited.title = "Biology II"
        store.index(edited)
        XCTAssertGreaterThan(store.searchVersion, afterCreate)
        let afterTitle = store.searchVersion
        store.updateSearchText("mitochondria", for: manifest.id)
        XCTAssertGreaterThan(store.searchVersion, afterTitle)
    }

    func testPageHitsAreCapped() async throws {
        let root = temporaryRoot(self)
        let pages = (0..<30).map { _ in NotebookPage.template(.blank, color: .white, size: .letter) }
        var ids: [UUID] = []
        for _ in 0..<3 {
            let manifest = try await makeNotebook(root, pages: pages.map { $0.duplicated() })
            for page in manifest.pages { try await NotebookPackage(root: root, id: manifest.id).writeText("#ink:none\nosmosis", pageID: page.id) }
            ids.append(manifest.id)
        }
        let hits = await PageSearch.hits(for: "osmosis", in: ids, root: root, limitPerNotebook: 8, limit: 20)
        XCTAssertEqual(hits.pages.values.map(\.count).reduce(0, +), 20)
        XCTAssertEqual(hits.pages[ids[0]]?.count, 8)
    }

    func testEditorKeysAreOffWhileASheetIsUp() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root, pages: [.template(.blank, color: .white, size: .letter)])
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let controller = PageStackController(session: EditorSession(document: document))
        XCTAssertFalse(controller.keyCommands?.isEmpty ?? true)
        controller.setModalShowing(true)
        XCTAssertEqual(controller.keyCommands?.count, 0, "arrows and space belong to the sheet, not the page behind it")
    }

    func testTheDocumentKnowsItsRecorder() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root, pages: [.template(.blank, color: .white, size: .letter)])
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let recorder = NotebookRecorder(document: document)
        XCTAssertTrue(document.recorder === recorder, "the window-close path can find the recorder to stop it")
    }

    func testFitWidthAndFitPageEnlargeASmallerPage() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root, pages: [.template(.blank, color: .white, size: .letter), .template(.blank, color: .white, size: .a5)])
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
        session.showsTools = false
        controller.toolTrayDidChange()
        session.go(to: 1, animated: false)

        func a5OnScreen() throws -> CGRect {
            let slot = try XCTUnwrap(controller.canvas(forPage: 1)?.superview)
            return slot.convert(slot.bounds, to: controller.view)
        }
        let before = try a5OnScreen()
        XCTAssertLessThan(before.width, 700, "true size: A5 is narrower than the Letter page above it")

        controller.fit(.width)
        let wide = try a5OnScreen()
        XCTAssertGreaterThan(wide.width, before.width * 1.2)
        XCTAssertEqual(wide.midX, controller.view.bounds.midX, accuracy: 1)
        XCTAssertEqual(controller.view.bounds.width - wide.width, 2 * PageStackLayout.margin * wide.width / PageSize.a5.points.width, accuracy: 1)
        XCTAssertEqual(session.currentPage, 1)

        controller.fit(.page)
        let whole = try a5OnScreen()
        let readable = controller.view.bounds.inset(by: UIEdgeInsets(top: controller.view.safeAreaInsets.top, left: 0, bottom: 0, right: 0))
        XCTAssertTrue(readable.insetBy(dx: -1, dy: -1).contains(whole), "\(whole) fits in \(readable)")
        XCTAssertTrue(abs(whole.height - (readable.height - 2 * PageStackLayout.margin * whole.height / PageSize.a5.points.height)) < 1
                      || abs(whole.width - wide.width) < 1, "Fit Page is limited by the height or the width")
        XCTAssertEqual(session.currentPage, 1)

        session.showsTools = true
        controller.toolTrayDidChange()
        controller.fit(.page)
        XCTAssertLessThanOrEqual(try a5OnScreen().maxY, controller.view.bounds.maxY - ToolTray.height - ToolTray.gap + 1,
                                 "with the tools out, the whole page is above the tray")
        session.showsTools = false
        controller.toolTrayDidChange()

        let wideManifest = try await makeNotebook(root, pages: [.template(.blank, color: .white, size: .letter), .template(.blank, color: .white, size: .widescreen),
                                                                .template(.blank, color: .white, size: .letter), .template(.blank, color: .white, size: .letter)])
        let wideDocument = try await NotebookDocument.open(wideManifest.id, root: root)
        let wideSession = EditorSession(document: wideDocument)
        let wideController = PageStackController(session: wideSession)
        wideSession.canvas = wideController
        window.rootViewController = wideController
        wideController.view.layoutIfNeeded()
        wideSession.go(to: 1, animated: false)
        XCTAssertEqual(wideController.currentPage, 1)
        wideController.fit(.page)
        XCTAssertEqual(wideSession.currentPage, 1, "a short page centred by Fit Page stays current")
        let commands = Set((controller.keyCommands ?? []).map { "\($0.modifierFlags.rawValue)|\($0.input ?? "")" })
        XCTAssertTrue(commands.isSuperset(of: ["\(UIKeyModifierFlags.command.rawValue)|0", "\(UIKeyModifierFlags.command.rawValue)|9"]))
    }
}
