import XCTest
import SwiftData
import UniformTypeIdentifiers
@testable import OwlLuna

private struct NoPasscode: Authenticating {
    func isAvailable() -> Bool { false }
    func authenticate(reason: String) async -> Bool { false }
}

/// The library's order, its list, and what can be done to several notebooks at once: Select All, tags, locks and PDFs,
/// a notebook dragged out of the app, and deleting one saved by a newer version.
@MainActor
final class LibraryShelfTests: XCTestCase {
    private var container: ModelContainer?
    private let paper = PageDefaults(template: .narrowRuled, paperColor: .white, pageSize: .letter)

    private func makeStore() throws -> LibraryStore {
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        self.container = container
        return LibraryStore(root: temporaryRoot(self), context: container.mainContext)
    }

    private func makeNotebook(_ title: String, in store: LibraryStore, created: Date = .now, modified: Date? = nil, opened: Date? = nil,
                              folder: FolderRecord? = nil, favorite: Bool = false, tags: [String] = []) async throws -> NotebookRecord {
        var manifest = NotebookManifest(title: title, createdAt: created, defaults: paper, pages: [paper.newPage()])
        manifest.modifiedAt = modified ?? created
        manifest.library.lastOpenedAt = opened
        manifest.library.folderID = folder?.id
        manifest.library.isFavorite = favorite
        manifest.library.tags = tags
        try await NotebookPackage(root: store.root, id: manifest.id).create(manifest)
        store.index(manifest)
        return try XCTUnwrap(store.record(manifest.id))
    }

    private func useAuthenticator(_ authenticator: any Authenticating) {
        let lock = NotebookLock.shared, usual = lock.authenticator
        addTeardownBlock { @MainActor in lock.authenticator = usual }
        lock.authenticator = authenticator
    }

    private func grouped(_ undoManager: UndoManager, _ change: () -> Void) {
        undoManager.beginUndoGrouping()
        change()
        undoManager.endUndoGrouping()
    }

    private func saved(_ id: UUID, in store: LibraryStore) async throws -> NotebookManifest {
        await store.finishWritingNotebooks()
        return try await NotebookPackage(root: store.root, id: id).readManifest().manifest
    }

    // MARK: Sorting

    func testEverySortRunsBothWays() async throws {
        let store = try makeStore()
        let day: TimeInterval = 86_400, start = Date(timeIntervalSince1970: 1_700_000_000)
        let apple = try await makeNotebook("apple", in: store, created: start, modified: start + 5 * day, opened: start + 1 * day)
        let banana = try await makeNotebook("Banana", in: store, created: start + 1 * day, modified: start + 3 * day, opened: start + 6 * day)
        let cherry = try await makeNotebook("cherry 10", in: store, created: start + 2 * day, modified: start + 4 * day, opened: nil)
        let cherry2 = try await makeNotebook("cherry 9", in: store, created: start + 3 * day, modified: start + 2 * day, opened: start + 2 * day)
        let all = [cherry, apple, cherry2, banana]

        func titles(_ order: LibrarySortOrder, reversed: Bool) -> [String] { all.sorted(by: order, reversed: reversed).map(\.title) }

        XCTAssertEqual(titles(.title, reversed: false), ["apple", "Banana", "cherry 9", "cherry 10"], "titles run A to Z, numbers as numbers")
        XCTAssertEqual(titles(.title, reversed: true), ["cherry 10", "cherry 9", "Banana", "apple"])
        XCTAssertEqual(titles(.created, reversed: false), ["cherry 9", "cherry 10", "Banana", "apple"], "newest first")
        XCTAssertEqual(titles(.created, reversed: true), ["apple", "Banana", "cherry 10", "cherry 9"])
        XCTAssertEqual(titles(.modified, reversed: false), ["apple", "cherry 10", "Banana", "cherry 9"])
        XCTAssertEqual(titles(.modified, reversed: true), ["cherry 9", "Banana", "cherry 10", "apple"])
        // Never opened, a notebook counts from when it was last changed.
        XCTAssertEqual(titles(.opened, reversed: false), ["Banana", "cherry 10", "cherry 9", "apple"])
        XCTAssertEqual(titles(.opened, reversed: true), ["apple", "cherry 9", "cherry 10", "Banana"])

        for order in LibrarySortOrder.allCases {
            XCTAssertNotEqual(order.summary(reversed: false), order.summary(reversed: true))
            XCTAssertNotEqual(order.directionName(reversed: false), order.directionName(reversed: true))
        }
    }

    func testTheDirectionIsKeptBesideTheSortKey() {
        XCTAssertEqual(SettingsKey.librarySortReversed, "\(SettingsKey.librarySort)Reversed")
        let defaults = UserDefaults(suiteName: "sort-\(UUID().uuidString)")!
        defaults.set(LibrarySortOrder.title.rawValue, forKey: SettingsKey.librarySort)
        defaults.set(true, forKey: SettingsKey.librarySortReversed)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.librarySort).flatMap(LibrarySortOrder.init(rawValue:)), .title)
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.librarySortReversed))
    }

    // MARK: Select All

    func testSelectAllTakesOnlyWhatTheShelfShows() async throws {
        let store = try makeStore()
        let physics = try XCTUnwrap(store.createFolder(name: "Physics", cloth: .navy))
        let labs = try XCTUnwrap(store.createFolder(name: "Labs", cloth: .moss, parent: physics))
        let history = try XCTUnwrap(store.createFolder(name: "History", cloth: .oxblood))
        let optics = try await makeNotebook("Optics", in: store, folder: physics, favorite: true, tags: ["exam"])
        let lab = try await makeNotebook("Lab Book", in: store, folder: labs, tags: ["exam", "week 3"])
        let rome = try await makeNotebook("Rome", in: store, folder: history, tags: ["week 3"])
        let loose = try await makeNotebook("Loose Notes", in: store)
        let gone = try await makeNotebook("Old Physics", in: store, folder: physics, tags: ["exam"])
        store.moveToTrash([gone])
        let records = try XCTUnwrap(container?.mainContext.fetch(FetchDescriptor<NotebookRecord>()))
        let tree = store.folderTree()

        func selectAll(_ scope: LibraryScope, rule: TagRule? = nil, matches: Set<UUID>? = nil) -> Set<UUID> {
            ShelfFilter(scope: scope, tree: tree, rule: rule, matches: matches, sort: .title).selectingAll(records)
        }

        XCTAssertEqual(selectAll(.all), [optics.id, lab.id, rome.id, loose.id], "Recently Deleted stays out of everything else")
        XCTAssertEqual(selectAll(.folder(physics.id)), [optics.id, lab.id], "a folder takes in the folders inside it")
        XCTAssertEqual(selectAll(.folder(labs.id)), [lab.id])
        XCTAssertEqual(selectAll(.favorites), [optics.id])
        XCTAssertEqual(selectAll(.trash), [gone.id])
        XCTAssertEqual(selectAll(.tag("exam"), rule: TagRule(tags: ["exam"])), [optics.id, lab.id])
        XCTAssertEqual(selectAll(.smart(UUID()), rule: TagRule(tags: ["exam", "week 3"], match: .all)), [lab.id], "a smart shelf's rule")
        XCTAssertEqual(selectAll(.all, matches: [rome.id, loose.id, gone.id]), [rome.id, loose.id], "a search narrows it")
        XCTAssertEqual(selectAll(.folder(physics.id), matches: [lab.id, rome.id]), [lab.id])
        XCTAssertEqual(selectAll(.folder(history.id), matches: []), [], "nothing found, nothing chosen")
        await store.finishWritingNotebooks()
    }

    // MARK: Favourites first

    func testFavouritesStandFirstExceptInFavouritesAndRecentlyDeleted() async throws {
        let store = try makeStore()
        let optics = try await makeNotebook("Optics", in: store)
        let waves = try await makeNotebook("Waves", in: store, favorite: true)
        let atoms = try await makeNotebook("Atoms", in: store)
        let lenses = try await makeNotebook("Lenses", in: store, favorite: true)
        let shown = [optics, waves, atoms, lenses]

        func split(_ scope: LibraryScope) -> [[String]] {
            let shelves = ShelfGrouping.favouritesFirst(shown, in: scope)
            return [shelves.favourites.map(\.title), shelves.rest.map(\.title)]
        }

        for scope in [LibraryScope.all, .folder(UUID()), .tag("exam"), .smart(UUID())] {
            XCTAssertEqual(split(scope), [["Waves", "Lenses"], ["Optics", "Atoms"]], "each keeps the order it was shown in, \(scope)")
        }
        for scope in [LibraryScope.favorites, .trash] {
            XCTAssertEqual(split(scope), [[], ["Optics", "Waves", "Atoms", "Lenses"]], "\(scope)")
        }
        XCTAssertTrue(ShelfGrouping.favouritesFirst([optics, atoms], in: .all).favourites.isEmpty)
        await store.finishWritingNotebooks()
    }

    // MARK: Tags

    func testTagsAreAddedAndTakenOffAcrossNotebooksEachKeepingItsOthers() async throws {
        let store = try makeStore()
        let changes = LibraryChangeCenter(), undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let optics = try await makeNotebook("Optics", in: store, tags: ["exam", "week 3"])
        let waves = try await makeNotebook("Waves", in: store, tags: ["Exam", "lab"])
        let rome = try await makeNotebook("Rome", in: store, tags: ["history"])

        let before = TagEdit.shared([optics.tags, waves.tags])
        XCTAssertEqual(before.common, ["exam"], "a tag spelled two ways is one tag")
        XCTAssertEqual(before.mixed, ["lab", "week 3"], "tags only some of them have are mixed")

        // Physics is added to both, week 3 taken off, lab left where it was.
        let edit = TagEdit(before: before, tags: ["exam", "physics"], stillMixed: ["lab"])
        XCTAssertEqual(edit, TagEdit(adding: ["physics"], removing: ["week 3"]))
        grouped(undoManager) { changes.editTags(edit, for: [optics, waves], in: store, undoManager: undoManager) }
        XCTAssertEqual(optics.tags, ["exam", "physics"])
        XCTAssertEqual(waves.tags, ["Exam", "lab", "physics"], "each keeps its own spelling and the tags it alone has")
        XCTAssertEqual(rome.tags, ["history"])
        let savedOptics = try await saved(optics.id, in: store)
        XCTAssertEqual(savedOptics.library.tags, ["exam", "physics"])
        XCTAssertNotNil(savedOptics.library.changedAt(.tags), "stamped, so the change syncs")
        let savedWaves = try await saved(waves.id, in: store)
        XCTAssertEqual(savedWaves.library.tags, ["Exam", "lab", "physics"])

        // A mixed tag made common goes on every one; one taken off everywhere goes from every one.
        let next = TagEdit.shared([optics.tags, waves.tags])
        grouped(undoManager) {
            changes.editTags(TagEdit(before: next, tags: ["exam", "lab", "physics"], stillMixed: []), for: [optics, waves], in: store, undoManager: undoManager)
        }
        XCTAssertEqual(optics.tags, ["exam", "lab", "physics"])
        let common = TagEdit.shared([optics.tags, waves.tags])
        grouped(undoManager) {
            changes.editTags(TagEdit(before: common, tags: ["lab"], stillMixed: []), for: [optics, waves], in: store, undoManager: undoManager)
        }
        XCTAssertEqual(optics.tags, ["lab"])
        XCTAssertEqual(waves.tags, ["lab"])
        let onlyLab = try await saved(waves.id, in: store)
        XCTAssertEqual(onlyLab.library.tags, ["lab"])

        undoManager.undo()
        XCTAssertEqual(optics.tags, ["exam", "lab", "physics"], "undo gives each notebook the tags it had")
        undoManager.undo()
        XCTAssertEqual(optics.tags, ["exam", "physics"])
        undoManager.undo()
        XCTAssertEqual(optics.tags, ["exam", "week 3"])
        XCTAssertEqual(waves.tags, ["Exam", "lab"])
        let undone = try await saved(optics.id, in: store)
        XCTAssertEqual(undone.library.tags, ["exam", "week 3"])
        XCTAssertTrue(TagEdit(before: before, tags: ["exam"], stillMixed: ["lab", "week 3"]).isEmpty, "a visit that changes nothing is no change")
    }

    // MARK: Locks

    func testLockingSeveralAsksOnceAndLocksEveryOne() async throws {
        let store = try makeStore()
        let diary = try await makeNotebook("Diary", in: store)
        let letters = try await makeNotebook("Letters", in: store)
        let already = try await makeNotebook("Secrets", in: store)
        store.setLocked(true, for: [already])
        let counter = CountingAuthenticator(passes: true)
        useAuthenticator(counter)

        let failure = await store.lock([diary, letters, already])
        XCTAssertNil(failure)
        XCTAssertEqual(counter.asked, 1, "one question for all of them")
        XCTAssertTrue(diary.isLocked)
        XCTAssertTrue(letters.isLocked)
        let savedDiary = try await saved(diary.id, in: store)
        XCTAssertTrue(savedDiary.library.isLocked)
        XCTAssertNotNil(savedDiary.library.changedAt(.locked))
        let savedLetters = try await saved(letters.id, in: store)
        XCTAssertTrue(savedLetters.library.isLocked)

        let again = await store.lock([diary, already])
        XCTAssertNil(again, "nothing left to lock asks nothing")
        XCTAssertEqual(counter.asked, 1)
    }

    func testLockingSeveralFollowsTheLockRules() async throws {
        let store = try makeStore()
        let diary = try await makeNotebook("Diary", in: store)
        let letters = try await makeNotebook("Letters", in: store)

        useAuthenticator(CountingAuthenticator(passes: false))
        let refused = await store.lock([diary, letters])
        XCTAssertNil(refused)
        XCTAssertFalse(diary.isLocked, "nothing is locked unless whoever holds the iPad shows it is theirs")
        XCTAssertFalse(letters.isLocked)

        useAuthenticator(NoPasscode())
        let unavailable = await store.lock([diary, letters])
        XCTAssertEqual(unavailable, NotebookLock.unavailableMessage, "an iPad without a passcode can't lock")
        XCTAssertFalse(diary.isLocked)
    }

    // MARK: PDFs

    func testExportingSeveralWritesAPDFOfEachAndLeavesOutLockedOnesNobodyUnlocked() async throws {
        let store = try makeStore()
        let optics = try await makeNotebook("Optics", in: store)
        let waves = try await makeNotebook("Waves", in: store)
        let diary = try await makeNotebook("Diary", in: store)
        store.setLocked(true, for: [diary])
        await store.finishWritingNotebooks()

        useAuthenticator(CountingAuthenticator(passes: false))
        let refused = try await ExportJob.pdfs(of: [optics, diary, waves], root: store.root)
        let written = try await finished(refused)
        addTeardownBlock { @MainActor in ExportFolder.discard(written) }
        XCTAssertEqual(written.map(\.lastPathComponent), ["Optics.pdf", "Waves.pdf"])
        XCTAssertEqual(refused.skipped, 1, "the sheet says what was left out")
        XCTAssertTrue(refused.isSeveral)
        XCTAssertEqual(Set(written.map { $0.deletingLastPathComponent() }).count, 2, "each in an export folder of its own")
        for url in written { XCTAssertEqual(CGPDFDocument(url as CFURL)?.numberOfPages, 1) }

        useAuthenticator(CountingAuthenticator(passes: true))
        let unlocked = try await ExportJob.pdfs(of: [optics, diary], root: store.root)
        let all = try await finished(unlocked)
        addTeardownBlock { @MainActor in ExportFolder.discard(all) }
        XCTAssertEqual(all.map(\.lastPathComponent), ["Optics.pdf", "Diary.pdf"])
        XCTAssertEqual(unlocked.skipped, 0)
    }

    private func finished(_ job: ExportJob) async throws -> [URL] {
        for _ in 0..<300 {
            if case .finished(let urls) = job.state { return urls }
            if case .failed(let message) = job.state { XCTFail(message); return [] }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("the export didn't finish")
        return []
    }

    // MARK: Dragging out

    func testADraggedNotebookOffersAPDFOnlyWhenItShould() async throws {
        let store = try makeStore()
        let optics = try await makeNotebook("Optics", in: store)
        let diary = try await makeNotebook("Diary", in: store)
        let old = try await makeNotebook("Old", in: store)
        store.setLocked(true, for: [diary])
        store.moveToTrash([old])
        await store.finishWritingNotebooks()
        let reference = UTType.notebookReference.identifier, pdf = UTType.pdf.identifier

        let open = NotebookDrag.provider(for: optics, root: store.root)
        XCTAssertEqual(Set(open.registeredTypeIdentifiers), [reference, pdf])
        XCTAssertEqual(NotebookDrag.provider(for: diary, root: store.root).registeredTypeIdentifiers, [reference],
                       "a locked notebook never leaves the app unencrypted")
        XCTAssertEqual(NotebookDrag.provider(for: old, root: store.root).registeredTypeIdentifiers, [reference])

        let carried: NotebookReference = try await withCheckedThrowingContinuation { continuation in
            _ = open.loadTransferable(type: NotebookReference.self) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(carried.id, optics.id, "the sidebar's folders still take the reference")

        let (name, pages): (String, Int) = try await withCheckedThrowingContinuation { continuation in
            _ = open.loadFileRepresentation(forTypeIdentifier: pdf) { url, error in
                guard let url else { return continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile)) }
                continuation.resume(returning: (url.lastPathComponent, CGPDFDocument(url as CFURL)?.numberOfPages ?? 0))
            }
        }
        XCTAssertEqual(name, "Optics.pdf")
        XCTAssertEqual(pages, 1, "written when the drop asked for it")
    }

    // MARK: Read-only notebooks

    func testDeletingANotebookFromANewerVersionKeepsWhatThisOneCantRead() async throws {
        let store = try makeStore()
        let id = UUID(), pageID = UUID()
        let original: JSONValue = .object([
            "schemaVersion": .number(99),
            "id": .string(id.uuidString),
            "title": .string("From Later"),
            "createdAt": .string("2026-01-02T03:04:05.000Z"),
            "modifiedAt": .string("2026-01-03T03:04:05.000Z"),
            "cover": .object(["style": .string("hologram"), "cloth": .string("navy"), "inks": .array([]), "seed": .number(7), "shimmer": .bool(true)]),
            "defaults": .object(["template": .string("dotted"), "paperColor": .string("white"), "pageSize": .string("a4")]),
            "pages": .array([.object(["id": .string(pageID.uuidString), "background": .object(["kind": .string("layered"), "layers": .array([.number(1)])]),
                                      "paperColor": .string("white"), "size": .object(["width": .number(612), "height": .number(792)]),
                                      "ink": .null, "inkHash": .null, "futurePageKey": .string("kept")])]),
            "recordings": .array([]),
            "library": .object(["favorite": .bool(false), "currentPage": .number(0), "tags": .array([.string("later")]),
                                "futureLibraryKey": .object(["kept": .bool(true)])]),
            "futureTopLevel": .array([.string("a"), .number(2)]),
        ])
        let package = NotebookPackage(root: store.root, id: id)
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: true)
        try original.serialized().write(to: package.manifestURL)
        let manifest = try await package.readManifest().manifest
        store.index(manifest)
        let record = try XCTUnwrap(store.record(id))
        XCTAssertTrue(record.isReadOnly)

        let changes = LibraryChangeCenter()
        changes.moveToTrash([record], in: store, undoManager: nil)
        XCTAssertTrue(record.isTrashed, "Delete moves it to Recently Deleted as with any notebook")
        await store.finishWritingNotebooks()
        var written = try JSONValue.parse(Data(contentsOf: package.manifestURL))
        for key in ["schemaVersion", "id", "title", "createdAt", "modifiedAt", "cover", "defaults", "pages", "recordings", "futureTopLevel"] {
            XCTAssertEqual(written[key], original[key], "\(key) is left as the newer version wrote it")
        }
        XCTAssertEqual(written.objectValue?.keys.sorted(), original.objectValue?.keys.sorted())
        let library = try XCTUnwrap(written["library"]?.objectValue)
        XCTAssertNotNil(library["deletedAt"]?.stringValue)
        XCTAssertEqual(library["futureLibraryKey"], .object(["kept": .bool(true)]), "the library's own unknown keys are kept")
        XCTAssertEqual(library["tags"], .array([.string("later")]))
        XCTAssertNotNil(library["changedAt"]?["deleted"], "stamped, so the delete syncs")
        XCTAssertNotNil(LibrarySync.filing(ofPackage: package.url)?.deletedAt, "the purge after the set days finds it")

        changes.restore([record], in: store, undoManager: nil)
        XCTAssertFalse(record.isTrashed, "and it comes back")
        await store.finishWritingNotebooks()
        written = try JSONValue.parse(Data(contentsOf: package.manifestURL))
        XCTAssertEqual(written["library"]?["deletedAt"], .null)
        XCTAssertEqual(written["pages"], original["pages"])
        XCTAssertEqual(written["schemaVersion"], .number(99))
        XCTAssertTrue(try XCTUnwrap(store.record(id)).isReadOnly)
    }

    // MARK: The list

    func testTheListPutsFolderAndTagsBesideTheTitleOnlyWhereThereIsRoom() {
        XCTAssertTrue(NotebookCatalogueRow.showsSide(width: 826, scale: 1, isAccessibilitySize: false), "on its side beside the sidebar")
        XCTAssertFalse(NotebookCatalogueRow.showsSide(width: 450, scale: 1, isAccessibilitySize: false), "upright beside the sidebar")
        XCTAssertTrue(NotebookCatalogueRow.showsSide(width: 700, scale: 1, isAccessibilitySize: false))
        XCTAssertFalse(NotebookCatalogueRow.showsSide(width: 700, scale: 1.35, isAccessibilitySize: false), "larger text needs more room")
        XCTAssertFalse(NotebookCatalogueRow.showsSide(width: 2000, scale: 1, isAccessibilitySize: true), "at the accessibility sizes they go under the title")
        var shown = true
        for width in stride(from: 1200, through: 300, by: -20) {
            let side = NotebookCatalogueRow.showsSide(width: CGFloat(width), scale: 1, isAccessibilitySize: false)
            XCTAssertTrue(shown || !side, "a narrower pane never gains the column")
            shown = side
        }
    }

    func testEveryOrderHasATab() {
        let names = LibrarySortOrder.allCases.map(\.shortName)
        XCTAssertEqual(Set(names).count, LibrarySortOrder.allCases.count)
        XCTAssertFalse(names.contains(""))
    }
}

/// Answers every question one way, and counts them.
private final class CountingAuthenticator: Authenticating, @unchecked Sendable {
    private let lock = NSLock()
    private let passes: Bool
    private var count = 0

    init(passes: Bool) { self.passes = passes }

    var asked: Int { lock.withLock { count } }

    func isAvailable() -> Bool { true }

    func authenticate(reason: String) async -> Bool {
        lock.withLock { count += 1 }
        return passes
    }
}
