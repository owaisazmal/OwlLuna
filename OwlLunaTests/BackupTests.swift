import XCTest
import SwiftData
import PencilKit
import AppleArchive
import System
@testable import OwlLuna

/// The disk a backup is written to. `filling` lets the first write through, the stream's header, and fails every one after it,
/// as a disk that fills up as the backup starts does. `started` runs at that first write, before any of the library is read.
private final class Disk: ArchiveByteStreamProtocol {
    private let inner: ArchiveByteStream
    private let filling: Bool
    private var started: (() -> Void)?
    private var writes = 0

    init(_ inner: ArchiveByteStream, filling: Bool = false, started: (() -> Void)? = nil) {
        self.inner = inner
        self.filling = filling
        self.started = started
    }

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        writes += 1
        if writes == 1 { started?() }
        if filling && writes > 1 { throw ArchiveError.ioError }
        return try inner.write(from: buffer)
    }

    func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int {
        writes += 1
        if filling && writes > 1 { throw ArchiveError.ioError }
        return try inner.write(from: buffer, atOffset: offset)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { try inner.read(into: buffer) }
    func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int { try inner.read(into: buffer, atOffset: offset) }
    func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 { try inner.seek(toOffset: offset, relativeTo: origin) }
    func cancel() { inner.cancel() }
    func close() throws { try inner.close() }
}

/// Backing up the whole library into one file, restoring it without replacing anything, and exporting pages as images.
@MainActor
final class BackupTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private let paper = PageDefaults(template: .grid, paperColor: .white, pageSize: .letter)

    private func makeStore(defaults: UserDefaults = .standard) throws -> LibraryStore {
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        containers.append(container)
        return LibraryStore(root: temporaryRoot(self), context: container.mainContext, defaults: defaults)
    }

    /// Settings of a library's own, so which notebook is its journal is its own too.
    private func ownSettings() throws -> UserDefaults {
        let suite = "owlluna-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func isJournal(_ id: UUID, in store: LibraryStore) async throws -> Bool {
        await store.finishWritingNotebooks()
        return try await NotebookPackage(root: store.root, id: id).readManifest().manifest.library.isJournal
    }

    private func makeNotebook(_ title: String, in store: LibraryStore, folder: FolderRecord? = nil, pages: Int = 2) async throws -> NotebookManifest {
        var manifest = NotebookManifest(title: title, defaults: paper, pages: (0..<pages).map { _ in paper.newPage() })
        manifest.library.folderID = folder?.id
        let package = NotebookPackage(root: store.root, id: manifest.id)
        try await package.create(manifest)
        let ink = PKDrawing(strokes: [stroke(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 200, y: 90))])
        let receipt = try await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[0].id: ink]))
        try await package.writeText("#ink:none\nmomentum", pageID: manifest.pages[0].id)
        try await package.writeThumbnail(Data([1, 2, 3]), pageID: manifest.pages[0].id, key: "cache")
        store.index(receipt.manifest)
        return receipt.manifest
    }

    func testABackupBringsTheWholeLibraryBack() async throws {
        let store = try makeStore()
        let science = try XCTUnwrap(store.createFolder(name: "Science", cloth: .jade))
        let physics = try XCTUnwrap(store.createFolder(name: "Physics", cloth: .moss, parent: science))
        let notes = try await makeNotebook("Mechanics", in: store, folder: physics)
        let loose = try await makeNotebook("Recipes", in: store)
        await store.finishWritingShelves()
        try FileManager.default.createDirectory(at: store.root.stickers, withIntermediateDirectories: true)
        try Data([9, 9]).write(to: store.root.stickers.appending(path: "mine.png"))
        let planner = try PaperShelf.add(image: UIGraphicsImageRenderer(size: CGSize(width: 50, height: 70)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 20, height: 70)) },
                                         name: "Planner", to: store.root)

        let backup = try await store.makeBackup()
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
        XCTAssertEqual(backup.pathExtension, LibraryBackup.fileExtension)
        XCTAssertGreaterThan(try XCTUnwrap(try backup.resourceValues(forKeys: [.fileSizeKey]).fileSize), 0)

        let fresh = try makeStore()
        let summary = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.folders, 2)
        XCTAssertEqual(summary.stickers, 1)
        XCTAssertEqual(summary.papers, 1)
        XCTAssertEqual(summary.copies + summary.unchanged + summary.unreadable, 0)

        let restored = try XCTUnwrap(fresh.record(notes.id))
        XCTAssertEqual(restored.title, "Mechanics")
        XCTAssertEqual(restored.folder?.id, physics.id, "a notebook goes back on its shelf")
        XCTAssertEqual(fresh.folderTree().path(of: physics.id), "Science › Physics", "and the shelf back inside its folder")
        XCTAssertNotNil(fresh.record(loose.id))
        let package = NotebookPackage(root: fresh.root, id: notes.id)
        guard case .ink(let ink, _) = await package.readInk(notes.pages[0].id) else { return XCTFail("the ink didn't come back") }
        XCTAssertEqual(ink.strokes.count, 1)
        XCTAssertEqual(LibraryIndex.notebookIDs(matching: "momentum", in: fresh.context).contains(notes.id), true, "recognised text is restored and searchable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.thumbURL(notes.pages[0].id, key: "cache").path(percentEncoded: false)),
                       "thumbnails are left out of a backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.root.stickers.appending(path: "mine.png").path(percentEncoded: false)))
        XCTAssertEqual(PaperShelf.list(fresh.root).map(\.id), [planner.id], "your own paper comes back too")

        let again = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(again.unchanged, 2, "restoring the same backup twice adds nothing")
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(try fresh.context.fetchCount(FetchDescriptor<NotebookRecord>()), 2)
    }

    func testARestoreOverADamagedFolderListKeepsTheFoldersTheIndexHas() async throws {
        let store = try makeStore()
        let science = try XCTUnwrap(store.createFolder(name: "Science", cloth: .jade))
        _ = try await makeNotebook("Mechanics", in: store, folder: science)
        await store.finishWritingShelves()
        let backup = try await store.makeBackup()
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }

        let other = try makeStore()
        other.createFolder(name: "Art", cloth: .rose)
        await other.finishWritingShelves()
        try Data("damaged".utf8).write(to: other.root.foldersFile)

        let summary = try await other.restoreBackup(from: backup)
        XCTAssertEqual(summary.folders, 1)
        XCTAssertEqual(FolderFile.read(other.root).folders.map(\.name).sorted(), ["Art", "Science"],
                       "the list is written with the folders the index had, so a sync doesn't take them as deleted")
        let tree = other.folderTree()
        XCTAssertEqual(tree.ordered.map { tree.name(of: $0) }.sorted(), ["Art", "Science"])
        XCTAssertEqual(try String(contentsOf: other.root.foldersFile.appendingPathExtension("corrupt"), encoding: .utf8), "damaged",
                       "and the damaged list is kept aside")
    }

    func testARestoreKeepsTheJournalAndAgreesWithItsMark() async throws {
        let store = try makeStore(defaults: ownSettings())
        let journal = try await store.createDailyJournal()
        _ = try await makeNotebook("Recipes", in: store)
        let backup = try await store.makeBackup()
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }

        let fresh = try makeStore(defaults: ownSettings())
        let summary = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(summary.journal, journal)
        XCTAssertEqual(fresh.dailyJournal?.id, journal, "a library without a journal takes the backup's")
        let marked = try await isJournal(journal, in: fresh)
        XCTAssertTrue(marked)

        let other = try makeStore(defaults: ownSettings())
        let own = try await other.createDailyJournal()
        _ = try await other.restoreBackup(from: backup)
        XCTAssertEqual(other.dailyJournal?.id, own, "a library with a journal keeps it")
        let ownMarked = try await isJournal(own, in: other), backupsMarked = try await isJournal(journal, in: other)
        XCTAssertTrue(ownMarked)
        XCTAssertFalse(backupsMarked, "and the backup's comes back as an ordinary notebook, so sync carries one journal")
        XCTAssertEqual(other.notebooks().filter(\.isJournal).map(\.id), [own])
    }

    func testABackupFromBeforeJournalsWereMarkedStillNamesTheJournal() async throws {
        let store = try makeStore(defaults: ownSettings())
        let journal = try await makeNotebook("Journal", in: store)
        store.defaults.set(journal.id.uuidString, forKey: SettingsKey.dailyJournalID)
        let backup = try await store.makeBackup()
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }

        let fresh = try makeStore(defaults: ownSettings())
        let summary = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(summary.journal, journal.id, "backup.json still names it")
        XCTAssertEqual(fresh.dailyJournal?.id, journal.id)
        let marked = try await isJournal(journal.id, in: fresh)
        XCTAssertTrue(marked, "and it is marked now, so other devices hear of it")
    }

    func testACopyFromABackupIsNeverTheJournal() async throws {
        let store = try makeStore(defaults: ownSettings())
        let journal = try await store.createDailyJournal()
        let backup = try await store.makeBackup()
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
        let changed = try await NotebookPackage(root: store.root, id: journal).updateManifest { manifest in
            manifest.modifiedAt = manifest.modifiedAt.addingTimeInterval(120)
            manifest.pages.append(manifest.defaults.newPage())
        }
        store.index(changed)

        let summary = try await store.restoreBackup(from: backup)
        XCTAssertEqual(summary.copies, 1)
        XCTAssertEqual(store.dailyJournal?.id, journal)
        let copy = try XCTUnwrap(store.notebooks().first { $0.id != journal })
        XCTAssertFalse(copy.isJournal)
        let copyMarked = try await isJournal(copy.id, in: store)
        XCTAssertFalse(copyMarked, "the copy kept beside the journal is an ordinary notebook")
    }

    func testRestoringNeverReplacesANotebook() async throws {
        let store = try makeStore()
        let notes = try await makeNotebook("Mechanics", in: store)
        let backup = try await store.makeBackup()
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }

        let changed = try await NotebookPackage(root: store.root, id: notes.id).updateManifest { manifest in
            manifest.title = "Mechanics, revised"
            manifest.modifiedAt = manifest.modifiedAt.addingTimeInterval(120)
            manifest.pages.append(manifest.defaults.newPage())
        }
        store.index(changed)

        let summary = try await store.restoreBackup(from: backup)
        XCTAssertEqual(summary.copies, 1)
        XCTAssertEqual(summary.added, 0)
        let records = try store.context.fetch(FetchDescriptor<NotebookRecord>(sortBy: [SortDescriptor(\.title)]))
        XCTAssertEqual(records.map(\.title), ["Mechanics (from backup)", "Mechanics, revised"])
        XCTAssertEqual(store.record(notes.id)?.pageCount, 3, "the notebook in the library is untouched")
        let copy = try XCTUnwrap(records.first)
        XCTAssertNotEqual(copy.id, notes.id)
        XCTAssertEqual(copy.pageCount, 2)
        let manifest = try await NotebookPackage(root: store.root, id: copy.id).readManifest().manifest
        XCTAssertEqual(manifest.id, copy.id, "the copy is a notebook of its own")
        XCTAssertTrue(summary.message.contains("copy"), summary.message)
    }

    func testABackupThatOnlyDiffersInItsCardsBringsThemIn() async throws {
        let store = try makeStore(), fresh = try makeStore()
        let notes = try await makeNotebook("Mechanics", in: store)
        try FileManager.default.createDirectory(at: fresh.root.library, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: store.root.package(notes.id), to: fresh.root.package(notes.id))
        // Cards made and answered after the other library had the notebook, then backed up.
        let cards = FlashcardLibrary(root: store.root)
        await cards.load()
        let clipped = try await cards.saveClipping(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }, in: notes.id)
        let momentum = Flashcard(front: CardSide(text: "Momentum?"), back: CardSide(image: clipped))
        cards.add([momentum, Flashcard(front: CardSide(text: "Inertia?"), back: CardSide(text: "Mass"))], to: notes.id)
        cards.grade(momentum.id, in: notes.id, .good)
        await cards.flush()
        let backup = try LibraryBackup.create(root: store.root)
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
        let mine = FlashcardLibrary(root: fresh.root)
        await mine.load()
        mine.add([Flashcard(front: CardSide(text: "Force?"), back: CardSide(text: "ma"))], to: notes.id)
        await mine.flush()

        let summary = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(summary.cardsMerged, 1)
        XCTAssertEqual(summary.unchanged + summary.copies + summary.added, 0, "the pages are the same, so it is neither already here nor copied")
        XCTAssertTrue(summary.message.contains("flashcards"), summary.message)
        let merged = CardFiles.read(fresh.root.package(notes.id)).cards
        XCTAssertEqual(merged.map(\.front.text).sorted(), ["Force?", "Inertia?", "Momentum?"], "the library's own card stays beside the backup's")
        XCTAssertEqual(merged.first { $0.id == momentum.id }?.reviews, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: CardFiles.imageURL(clipped, in: fresh.root.package(notes.id)).path(percentEncoded: false)))
        XCTAssertEqual(fresh.root.packageIDs(), [notes.id])

        let again = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(again.unchanged, 1, "once they're in, the notebook is already here")
        XCTAssertEqual(again.cardsMerged, 0)
    }

    func testACopyFromABackupHasCardsOfItsOwn() async throws {
        let store = try makeStore()
        let notes = try await makeNotebook("Mechanics", in: store)
        let cards = FlashcardLibrary(root: store.root)
        await cards.load()
        cards.add([Flashcard(front: CardSide(text: "Momentum?"), back: CardSide(text: "mv"))], to: notes.id)
        await cards.flush()
        let backup = try LibraryBackup.create(root: store.root)
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
        _ = try await NotebookPackage(root: store.root, id: notes.id).updateManifest { manifest in
            manifest.modifiedAt = manifest.modifiedAt.addingTimeInterval(120)
            manifest.pages.append(manifest.defaults.newPage())
        }

        let summary = try await store.restoreBackup(from: backup)
        XCTAssertEqual(summary.copies, 1)
        let copy = try XCTUnwrap(store.root.packageIDs().first { $0 != notes.id })
        let original = CardFiles.read(store.root.package(notes.id)).cards, copied = CardFiles.read(store.root.package(copy)).cards
        XCTAssertEqual(copied.map(\.front.text), ["Momentum?"])
        XCTAssertNotEqual(copied.map(\.id), original.map(\.id), "the copy's cards aren't taken for the library's")
    }

    func testANotebookTheBackupHadInRecentlyDeletedGetsAnother30DaysThere() async throws {
        let store = try makeStore()
        let binned = try await makeNotebook("Old Lab", in: store)
        let kept = try await makeNotebook("Mechanics", in: store)
        let binnedAt = Date.now.addingTimeInterval(-100 * 86_400)
        let stamped = try await NotebookPackage(root: store.root, id: binned.id).updateManifest { manifest in
            manifest.library.deletedAt = binnedAt
            manifest.library.setChangedAt(binnedAt, for: .deleted)
        }
        store.index(stamped)
        let backup = try LibraryBackup.create(root: store.root)
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }

        let fresh = try makeStore()
        let summary = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.trashed, 1)
        XCTAssertTrue(summary.message.contains("Recently Deleted"), summary.message)
        let restored = try XCTUnwrap(fresh.record(binned.id))
        XCTAssertTrue(restored.isTrashed, "it goes back to Recently Deleted")
        XCTAssertGreaterThan(try XCTUnwrap(restored.deletedAt), Date.now.addingTimeInterval(-60), "dated from the restore")
        XCTAssertNil(fresh.record(kept.id)?.deletedAt)
        await fresh.purgeExpiredTrash()
        XCTAssertNotNil(fresh.record(binned.id), "so the next launch doesn't delete it for good")

        let library = try await NotebookPackage(root: fresh.root, id: binned.id).readManifest().manifest.library
        XCTAssertEqual(try XCTUnwrap(library.changedAt(.deleted)).timeIntervalSince(binnedAt), 0, accuracy: 0.002, "the old stamp stays")
        var stale = library
        stale.deletedAt = binnedAt
        XCTAssertEqual(LibraryState.settled(here: library, there: stale, now: .now)?.deletedAt, library.deletedAt, "a copy with the old date gives way")
        var restoredElsewhere = library
        restoredElsewhere.deletedAt = nil
        restoredElsewhere.setChangedAt(binnedAt.addingTimeInterval(30 * 86_400), for: .deleted)
        XCTAssertNil(try XCTUnwrap(LibraryState.settled(here: library, there: restoredElsewhere, now: .now)).deletedAt,
                     "a restore made since on another device still wins")
    }

    func testARestoreEndedPartWayNeverLeavesANotebookUnderTheWrongID() async throws {
        let store = try makeStore()
        let notes = try await makeNotebook("Mechanics", in: store)
        let binned = try await makeNotebook("Old Lab", in: store)
        _ = try await NotebookPackage(root: store.root, id: binned.id).updateManifest { $0.library.deletedAt = Date.now.addingTimeInterval(-100 * 86_400) }
        let backup = try LibraryBackup.create(root: store.root)
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
        _ = try await NotebookPackage(root: store.root, id: notes.id).updateManifest { manifest in
            manifest.modifiedAt = manifest.modifiedAt.addingTimeInterval(120)
            manifest.pages.append(manifest.defaults.newPage())
        }
        try FileManager.default.removeItem(at: store.root.package(binned.id))

        let root = store.root, quits = temporaryRoot(self).url
        let summary = try await LibraryBackup.restore(from: backup, into: root, beforeRewrite: { package in
            // The app is ended here, with a notebook out of the backup and its manifest not yet rewritten: this is what the next launch finds.
            XCTAssertFalse(package.url.path(percentEncoded: false).hasPrefix(root.library.path(percentEncoded: false)))
            try FileManager.default.copyItem(at: root.url, to: quits.appending(path: UUID().uuidString, directoryHint: .isDirectory))
        })
        XCTAssertEqual(summary.copies, 1)
        XCTAssertEqual(summary.trashed, 1)
        XCTAssertEqual(root.packageIDs().count, 3)

        let snapshots = try FileManager.default.contentsOfDirectory(at: quits, includingPropertiesForKeys: nil)
        XCTAssertEqual(snapshots.count, 2, "one for the copy and one for the notebook going back to Recently Deleted")
        for snapshot in snapshots.map({ StorageRoot(url: $0) }) {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshot.arriving.path(percentEncoded: false)).count, 1,
                           "the notebook waits in Arriving")
            LibrarySync.sweepArriving(root: snapshot, untouchedSince: .now)
            LibraryStore.sweepUnfinished(root: snapshot, untouchedSince: .now)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: snapshot.arriving.path(percentEncoded: false)), [])
            XCTAssertTrue(snapshot.packageIDs().contains(notes.id))
            for id in snapshot.packageIDs() {
                let manifest = try await NotebookPackage(root: snapshot, id: id).readManifest().manifest
                XCTAssertEqual(manifest.id, id, "no notebook in the library carries another one's ID")
                XCTAssertGreaterThan(manifest.library.deletedAt ?? .now, Date.now.addingTimeInterval(-30 * 86_400), "or 30 days that are already over")
            }
        }
    }

    func testABackupFromTheOldAppRestoresUnderTheNewName() async throws {
        let store = try makeStore()
        let notes = try await makeNotebook("Mechanics", in: store)
        let package = store.root.package(notes.id)
        try FileManager.default.moveItem(at: package, to: package.deletingPathExtension().appendingPathExtension(StorageRoot.legacyPackageExtension))
        let backup = try LibraryBackup.create(root: store.root)
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }

        let fresh = try makeStore()
        let summary = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.copies + summary.unchanged + summary.unreadable, 0)
        XCTAssertEqual(fresh.root.packageIDs(), [notes.id])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fresh.root.library.path(percentEncoded: false)).filter { $0.hasSuffix(".\(StorageRoot.legacyPackageExtension)") }, [],
                       "nothing keeps the old name")
        XCTAssertEqual(fresh.record(notes.id)?.title, "Mechanics")
        let restored = NotebookPackage(root: fresh.root, id: notes.id)
        guard case .ink(let ink, _) = await restored.readInk(notes.pages[0].id) else { return XCTFail("the ink didn't come back") }
        XCTAssertEqual(ink.strokes.count, 1)
        XCTAssertTrue(LibraryIndex.notebookIDs(matching: "momentum", in: fresh.context).contains(notes.id), "recognised text is restored and searchable")

        let again = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(again.unchanged, 1, "restoring the same backup twice adds nothing")
    }

    func testAFileThatIsNotABackupChangesNothing() async throws {
        let store = try makeStore()
        _ = try await makeNotebook("Mechanics", in: store)
        let junk = FileManager.default.temporaryDirectory.appending(path: "junk-\(UUID().uuidString).owllunabackup")
        try Data("not an archive".utf8).write(to: junk)
        addTeardownBlock { try? FileManager.default.removeItem(at: junk) }
        do {
            _ = try await store.restoreBackup(from: junk)
            XCTFail("a file that isn't a backup was accepted")
        } catch {
            XCTAssertEqual(error.localizedDescription, LibraryBackup.Failure.notABackup.localizedDescription)
        }
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<NotebookRecord>()), 1)
    }

    private func backupFolders() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path(percentEncoded: false))
            .filter { $0.hasPrefix("\(ExportFolder.Kind.backup.rawValue)-") })
    }

    func testABackupWhoseLastBlockFailsToWriteIsNotHandedOver() async throws {
        let store = try makeStore()
        _ = try await makeNotebook("Mechanics", in: store)
        let before = try backupFolders()
        // A small library fits in one compressed block, which only goes to the disk as the archive closes.
        XCTAssertThrowsError(try LibraryBackup.create(root: store.root, through: { ArchiveByteStream.customStream(instance: Disk($0, filling: true)) })) { error in
            XCTAssertEqual(error.localizedDescription, "The backup couldn't be written.")
        }
        XCTAssertEqual(try backupFolders(), before, "the part-written file goes with its folder")
    }

    func testABackupThatDoesNotReadBackAsTheLibraryIsNotHandedOver() async throws {
        let store = try makeStore()
        let notes = try await makeNotebook("Mechanics", in: store)
        let lost = try await makeNotebook("Recipes", in: store)
        let root = store.root, before = try backupFolders()
        // Counted, then deleted before it is archived: the backup would say two notebooks and hold one.
        let deleting: () -> Void = { try? FileManager.default.removeItem(at: root.package(lost.id)) }
        XCTAssertThrowsError(try LibraryBackup.create(root: root, through: { ArchiveByteStream.customStream(instance: Disk($0, started: deleting)) })) { error in
            XCTAssertEqual(error.localizedDescription, "The finished backup didn't match your library when it was checked, so it wasn't kept. Try again.")
        }
        XCTAssertEqual(try backupFolders(), before)

        let backup = try LibraryBackup.create(root: root, through: { ArchiveByteStream.customStream(instance: Disk($0)) })
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
        let fresh = try makeStore()
        let summary = try await fresh.restoreBackup(from: backup)
        XCTAssertEqual(summary.added, 1, "one that reads back whole is handed over")
        XCTAssertEqual(fresh.root.packageIDs(), [notes.id])
    }

    func testABackupWaitsUntilEveryOpenNotebookIsSaved() async throws {
        let store = try makeStore()
        let notes = try await makeNotebook("Mechanics", in: store)
        let document = try await DocumentRegistry.shared.open(notes.id, root: store.root, scene: nil) { _ in }
        addTeardownBlock { @MainActor in DocumentRegistry.shared.unregister(notes.id, document: document) }
        document.retryBase = .seconds(60)
        let page = notes.pages[0].id
        _ = await document.ink(page)
        let blocker = document.package.inkDirectory
        try FileManager.default.removeItem(at: blocker)
        try Data("blocker".utf8).write(to: blocker)
        let latest = PKDrawing(strokes: [stroke(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 200, y: 90)),
                                         stroke(from: CGPoint(x: 40, y: 140), to: CGPoint(x: 200, y: 190))])
        document.canvasDidChangeInk(page, to: latest)

        let before = try backupFolders()
        do {
            let backup = try await store.makeBackup()
            ExportFolder.discard([backup])
            XCTFail("a backup was made without the notebook's latest changes")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "Your latest changes to “Mechanics” couldn't be saved, so the backup would be missing them. Try again once they're saved.")
        }
        XCTAssertEqual(try backupFolders(), before)

        try FileManager.default.removeItem(at: blocker)
        let backup = try await store.makeBackup()
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
        let fresh = try makeStore()
        _ = try await fresh.restoreBackup(from: backup)
        guard case .ink(let ink, _) = await NotebookPackage(root: fresh.root, id: notes.id).readInk(page) else { return XCTFail("the ink didn't come back") }
        XCTAssertEqual(ink.strokes.count, 2, "once it saves, the backup has the latest changes")
    }

    func testARestoreThatRunsOutOfRoomSaysSoRatherThanThatItIsNoBackup() async throws {
        let store = try makeStore()
        let notes = try await makeNotebook("Mechanics", in: store)
        let backup = try LibraryBackup.create(root: store.root)
        addTeardownBlock { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
        _ = try await NotebookPackage(root: store.root, id: notes.id).updateManifest { manifest in
            manifest.modifiedAt = manifest.modifiedAt.addingTimeInterval(120)
            manifest.pages.append(manifest.defaults.newPage())
        }

        let full: [any Error] = [CocoaError(.fileWriteOutOfSpace), POSIXError(.ENOSPC),
                                 CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC)])]
        for error in full {
            do {
                _ = try await LibraryBackup.restore(from: backup, into: store.root, beforeRewrite: { _ in throw error })
                XCTFail("the restore carried on with no room left")
            } catch {
                XCTAssertEqual(error.localizedDescription, Device.isPhone
                               ? "There isn't enough free space on this iPhone. Free some up in Settings › General › iPhone Storage, then try again."
                               : "There isn't enough free space on this iPad. Free some up in Settings › General › iPad Storage, then try again.")
            }
        }
        XCTAssertEqual(store.root.packageIDs(), [notes.id], "nothing half-restored is left in the library")

        do {
            _ = try await LibraryBackup.restore(from: backup, into: store.root, beforeRewrite: { _ in throw CocoaError(.fileWriteNoPermission) })
            XCTFail("the restore carried on after a write failed")
        } catch {
            XCTAssertEqual(error.localizedDescription, CocoaError(.fileWriteNoPermission).localizedDescription, "any other error is passed on as it is")
        }
    }

    func testABackupThatCannotBeUnpackedStopsTheRestore() async throws {
        let store = try makeStore()
        _ = try await makeNotebook("Mechanics", in: store)
        let made = try LibraryBackup.create(root: store.root)
        addTeardownBlock { try? FileManager.default.removeItem(at: made.deletingLastPathComponent()) }
        let backup = made.deletingLastPathComponent().appending(path: "unpackable.\(LibraryBackup.fileExtension)")

        // The whole backup, then a sticker whose name is too long for the disk: it fails to unpack as a file does on a full disk.
        let source = try XCTUnwrap(ArchiveByteStream.fileStream(path: FilePath(made.path(percentEncoded: false)), mode: .readOnly, options: [],
                                                                permissions: FilePermissions(rawValue: 0o644)))
        let decompress = try XCTUnwrap(ArchiveByteStream.decompressionStream(readingFrom: source))
        let decode = try XCTUnwrap(ArchiveStream.decodeStream(readingFrom: decompress))
        let file = try XCTUnwrap(ArchiveByteStream.fileStream(path: FilePath(backup.path(percentEncoded: false)), mode: .writeOnly,
                                                              options: [.create, .truncate], permissions: FilePermissions(rawValue: 0o644)))
        let compress = try XCTUnwrap(ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file))
        let encode = try XCTUnwrap(ArchiveStream.encodeStream(writingTo: compress))
        _ = try ArchiveStream.process(readingFrom: decode, writingTo: encode)
        let header = ArchiveHeader()
        header.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
        header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: "Stickers/\(String(repeating: "a", count: 300)).png"))
        header.append(.blob(key: ArchiveHeader.FieldKey("DAT"), size: 3))
        try encode.writeHeader(header)
        try [UInt8]([1, 2, 3]).withUnsafeBytes { try encode.writeBlob(key: ArchiveHeader.FieldKey("DAT"), from: $0) }
        for stream in [encode.close, compress.close, file.close, decode.close, decompress.close, source.close] { try stream() }

        let fresh = try makeStore()
        do {
            _ = try await fresh.restoreBackup(from: backup)
            XCTFail("a backup that didn't unpack was restored")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This backup couldn't be read. It may be damaged or not fully downloaded yet.")
        }
        XCTAssertEqual(fresh.root.packageIDs(), [], "nothing from it is added")
    }

    func testABackupCutShortIsDamagedAndNotSomeOtherFile() async throws {
        let store = try makeStore()
        _ = try await makeNotebook("Mechanics", in: store)
        _ = try await makeNotebook("Recipes", in: store)
        let made = try LibraryBackup.create(root: store.root)
        addTeardownBlock { try? FileManager.default.removeItem(at: made.deletingLastPathComponent()) }
        let data = try Data(contentsOf: made)
        let half = made.deletingLastPathComponent().appending(path: "half.\(LibraryBackup.fileExtension)")
        try data.prefix(data.count / 2).write(to: half)

        let fresh = try makeStore()
        do {
            _ = try await fresh.restoreBackup(from: half)
            XCTFail("half a backup was restored")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This backup couldn't be read. It may be damaged or not fully downloaded yet.")
        }
        XCTAssertEqual(fresh.root.packageIDs(), [])

        do {
            _ = try await fresh.restoreBackup(from: made.deletingLastPathComponent().appending(path: "gone.\(LibraryBackup.fileExtension)"))
            XCTFail("a file that isn't there was restored")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This backup couldn't be read. It may be damaged or not fully downloaded yet.")
        }
        XCTAssertEqual(LibraryBackup.Failure.notABackup.localizedDescription, "This file isn't an OwlLuna backup.")
    }

    func testTheBackupMessagesReadInEveryLanguage() throws {
        let messages: [String.LocalizationValue] = [
            "There isn't enough free space on this iPad. Free some up in Settings › General › iPad Storage, then try again.",
            "This backup couldn't be read. It may be damaged or not fully downloaded yet.",
            "The finished backup didn't match your library when it was checked, so it wasn't kept. Try again.",
            "Your latest changes to \("„Physik“") couldn't be saved, so the backup would be missing them. Try again once they're saved.",
            "\(2) notebooks were already here, and took in flashcards and reviews from the backup.",
            "Flashcards couldn't be saved: \("Disk full")",
        ]
        for code in ["de", "es", "fr"] {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)))
            for message in messages {
                let english = String(localized: message, bundle: .main, locale: Locale(identifier: "en"))
                XCTAssertNotEqual(String(localized: message, bundle: bundle, locale: Locale(identifier: code)), english, "\(code): \(english)")
            }
        }
        let german = try XCTUnwrap(Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(String(localized: "“\("Physik")”", bundle: german, locale: Locale(identifier: "de")), "„Physik“")
        XCTAssertEqual(LibraryBackup.Failure.unsaved(["Mechanics", "Recipes"]).localizedDescription,
                       "Your latest changes to “Mechanics” and “Recipes” couldn't be saved, so the backup would be missing them. Try again once they're saved.")
    }

    func testPagesExportAsImages() async throws {
        let store = try makeStore()
        let manifest = try await makeNotebook("Lab: 1/2", in: store, pages: 3)
        let job = try await ExportJob.forNotebook(manifest.id, root: store.root, format: .images)
        let deadline = Date().addingTimeInterval(30)
        while case .running = job.state, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard case .finished(let urls) = job.state else { return XCTFail("export ended as \(job.state)") }
        addTeardownBlock { if let first = urls.first { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) } }
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Lab- 1-2 1.png", "Lab- 1-2 2.png", "Lab- 1-2 3.png"])
        let image = try XCTUnwrap(UIImage(contentsOfFile: urls[0].path(percentEncoded: false)))
        XCTAssertEqual(image.cgImage?.width, 1224, "twice the page's 612 points")
        XCTAssertEqual(image.cgImage?.height, 1584)
        XCTAssertEqual(job.progress, 1)
    }
}
