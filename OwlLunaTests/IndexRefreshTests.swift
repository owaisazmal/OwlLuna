import XCTest
import SwiftData
@testable import OwlLuna

/// Which notebooks the index reads again: one whose manifest isn't the file it last read, and after a sync the ones the
/// sync brought in. Filing a notebook, or editing it, leaves nothing to read at the next launch.
@MainActor
final class IndexRefreshTests: XCTestCase {
    private let paper = PageDefaults(template: .grid, paperColor: .white, pageSize: .letter)

    /// The index kept on disk, opened as a launch opens it.
    private func launch(_ root: StorageRoot) -> LibraryStore {
        let (container, recovered) = LibraryIndex.makeContainer(root: root)
        XCTAssertFalse(recovered)
        addTeardownBlock { _ = container }
        return LibraryStore(root: root, context: container.mainContext)
    }

    private func makeNotebooks(_ titles: [String], in store: LibraryStore) async throws -> [UUID] {
        var ids: [UUID] = []
        for title in titles {
            let id = try await store.createNotebook(title: title, cover: .defaultCloth(for: UUID()), defaults: paper, folder: nil)
            try await NotebookPackage(root: store.root, id: id).writeText("#ink:none\nnotes on \(title)", pageID: UUID())
            ids.append(id)
        }
        // As after any launch that read them, the records hold what the files hold.
        await LibraryIndex.refresh(root: store.root, context: store.context, full: true)
        return ids
    }

    /// Waits until each notebook's change is on disk and its record has caught up with the file.
    private func settled(_ ids: [UUID], in store: LibraryStore, when done: (LibraryState) -> Bool) async throws {
        for id in ids {
            for _ in 0..<200 {
                let filed = LibrarySync.filing(ofPackage: store.root.package(id)).map(done) ?? false
                if filed, store.record(id)?.manifestDate == LibraryIndex.manifestDate(ofPackage: store.root.package(id)) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// A text file only a reread would find. The manifest is left alone.
    private func plant(_ word: String, in ids: [UUID], root: StorageRoot) throws {
        for id in ids {
            try Data("#ink:none\n\(word)".utf8).write(to: NotebookPackage(root: root, id: id).textDirectory.appending(path: "\(UUID().uuidString).txt"))
        }
    }

    func testFilingAClosedNotebookLeavesNothingToReadAtTheNextLaunch() async throws {
        let root = temporaryRoot(self)
        let store = launch(root)
        let ids = try await makeNotebooks(["Physics", "Diary", "Biology", "Recipes"], in: store)
        let folder = try XCTUnwrap(store.createFolder(name: "Classes", cloth: .jade))
        let records = ids.compactMap(store.record)
        store.move([records[0]], to: folder)
        store.setFavorite(true, for: [records[1]])
        store.setLocked(true, for: [records[1]])
        store.setTags(["exam"], for: [records[2]])
        try await settled([ids[0]], in: store) { $0.folderID == folder.id }
        try await settled([ids[1]], in: store) { $0.isFavorite && $0.isLocked }
        try await settled([ids[2]], in: store) { $0.tags == ["exam"] }
        await store.finishWritingShelves()

        let relaunched = launch(root)
        let read = await LibraryIndex.refresh(root: root, context: relaunched.context)
        XCTAssertEqual(read, [], "no manifest or text is read again")
        XCTAssertEqual(relaunched.record(ids[0])?.folder?.id, folder.id, "and the index still has each change")
        XCTAssertEqual(relaunched.record(ids[1])?.isFavorite, true)
        XCTAssertEqual(relaunched.record(ids[1])?.isLocked, true)
        XCTAssertEqual(relaunched.record(ids[2])?.tags, ["exam"])
        let again = await LibraryIndex.refresh(root: root, context: relaunched.context)
        XCTAssertEqual(again, [])
    }

    func testANotebookEditedAndClosedIsNotReadAgain() async throws {
        let root = temporaryRoot(self)
        let store = launch(root)
        let id = try await makeNotebooks(["Physics"], in: store)[0]
        let package = NotebookPackage(root: root, id: id)
        let document = NotebookDocument(package: package, load: try await package.readManifest())
        document.onSaved = { store.index($0) }
        document.rename("Mechanics")
        let flushed = await document.flush()
        XCTAssertTrue(flushed)
        store.index(document.manifest)

        let read = await LibraryIndex.refresh(root: root, context: launch(root).context)
        XCTAssertEqual(read, [])
    }

    func testOldPDFCoverKeysAreRefreshedOnceWithoutManifestChanges() async throws {
        let root = temporaryRoot(self), store = launch(root)
        let ids = try await makeNotebooks(["PDF", "Other"], in: store)
        let package = NotebookPackage(root: root, id: ids[0])
        _ = try await package.updateManifest { $0.pages[0].background = .pdf(file: "sheet.pdf", index: 0) }
        await LibraryIndex.refresh(root: root, context: store.context)
        let record = try XCTUnwrap(store.record(ids[0]))
        let currentKey = try XCTUnwrap(record.firstPageThumbKey)
        record.firstPageThumbKey = "blank-oldkey"
        let read = await LibraryIndex.refresh(root: root, context: store.context)
        XCTAssertEqual(read, [ids[0]])
        XCTAssertEqual(record.firstPageThumbKey, currentKey)
        let again = await LibraryIndex.refresh(root: root, context: store.context)
        XCTAssertEqual(again, [])
    }

    func testANotebookChangedOnDiskIsReadAgain() async throws {
        let root = temporaryRoot(self)
        let store = launch(root)
        let ids = try await makeNotebooks(["Physics", "Diary", "Biology"], in: store)
        let earlier = try Data(contentsOf: NotebookPackage(root: root, id: ids[1]).manifestURL)

        // Written in by an older build, or by hand.
        _ = try await NotebookPackage(root: root, id: ids[0]).updateManifest { $0.title = "Mechanics" }
        let written = await LibraryIndex.refresh(root: root, context: store.context)
        XCTAssertEqual(written, [ids[0]])
        XCTAssertEqual(store.record(ids[0])?.title, "Mechanics")

        // Put back from a backup: an earlier manifest, in a file older than the one it replaces.
        _ = try await NotebookPackage(root: root, id: ids[1]).updateManifest { $0.title = "Journal" }
        await LibraryIndex.refresh(root: root, context: store.context)
        XCTAssertEqual(store.record(ids[1])?.title, "Journal")
        let manifest = NotebookPackage(root: root, id: ids[1]).manifestURL
        try earlier.write(to: manifest)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: manifest.path(percentEncoded: false))
        try plant("momentum", in: ids, root: root)

        let restored = await LibraryIndex.refresh(root: root, context: store.context)
        XCTAssertEqual(restored, [ids[1]])
        XCTAssertEqual(store.record(ids[1])?.title, "Diary", "an older file is read as surely as a newer one")
        XCTAssertTrue(store.searchText(for: ids[1]).contains("momentum"), "with its text")
        XCTAssertFalse(store.searchText(for: ids[2]).contains("momentum"), "and the notebook nobody changed isn't read")
    }

    func testASyncReadsOnlyTheNotebooksItBroughtIn() async throws {
        let root = temporaryRoot(self), other = temporaryRoot(self)
        let cloud = CloudFolder(url: temporaryRoot(self).url)
        let store = launch(root)
        let ids = try await makeNotebooks(["Physics", "Diary", "Biology"], in: store)
        _ = try await LibrarySync.run(root: root, cloud: cloud)
        _ = try await LibrarySync.run(root: other, cloud: cloud)

        // On the other device one notebook is written in, one is made a favourite, and a folder is made.
        _ = try await NotebookPackage(root: other, id: ids[0]).updateManifest {
            $0.title = "Mechanics"
            $0.modifiedAt = $0.modifiedAt.addingTimeInterval(60)
        }
        _ = try await NotebookPackage(root: other, id: ids[1]).updateManifest {
            $0.library.isFavorite = true
            $0.library.setChangedAt(.now, for: .favorite)
        }
        let folder = UUID()
        var file = FolderFile.read(other)
        file.folders = [FolderEntry(id: folder, name: "Classes", clothRaw: "jade", createdAt: .now, sortIndex: 0)]
        try file.write(other)
        _ = try await LibrarySync.run(root: other, cloud: cloud)

        try plant("momentum", in: ids, root: root)
        let report = try await LibrarySync.run(root: root, cloud: cloud)
        XCTAssertEqual(report.pulled, [ids[0]])
        XCTAssertEqual(report.stateReceived, [ids[1]])
        XCTAssertTrue(report.foldersChanged)
        await store.reloadFromDisk(after: report)

        XCTAssertEqual(store.record(ids[0])?.title, "Mechanics", "what the sync brought in is read")
        XCTAssertEqual(store.record(ids[1])?.isFavorite, true)
        XCTAssertTrue(store.searchText(for: ids[1]).contains("momentum"))
        XCTAssertEqual(store.folderTree().ordered, [folder], "and so are the folders")
        XCTAssertFalse(store.searchText(for: ids[2]).contains("momentum"), "the notebook it didn't touch isn't read")
        let read = await LibraryIndex.refresh(root: root, context: store.context)
        XCTAssertEqual(read, [], "and nothing is left to read at the next launch")
    }

    func testANotebookThatCameBeforeItsFolderIsFiledWhenTheFolderArrives() async throws {
        let root = temporaryRoot(self)
        let store = launch(root)
        let folder = UUID()
        var manifest = NotebookManifest(title: "Mechanics", defaults: paper, pages: [paper.newPage()])
        manifest.library.folderID = folder
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        await LibraryIndex.refresh(root: root, context: store.context)
        XCTAssertNil(store.record(manifest.id)?.folder)

        var file = FolderFile()
        file.folders = [FolderEntry(id: folder, name: "Physics", clothRaw: "moss", createdAt: .now, sortIndex: 0)]
        try file.write(root)
        let read = await LibraryIndex.refresh(root: root, context: store.context)
        XCTAssertEqual(read, [])
        XCTAssertEqual(store.record(manifest.id)?.folder?.id, folder)
    }

    func testAnIndexFromBeforeManifestDatesIsMigratedAndReadOnce() async throws {
        let root = temporaryRoot(self)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        var manifest = NotebookManifest(title: "Biology", defaults: paper, pages: [paper.newPage()])
        manifest.library.isFavorite = true
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        try await package.writeText("#ink:none\nprophase", pageID: manifest.pages[0].id)

        try autoreleasepool {
            let old = Schema(versionedSchema: LibraryIndexSchemaV5.self)
            let container = try ModelContainer(for: old, configurations: ModelConfiguration(schema: old, url: root.indexStore, cloudKitDatabase: .none))
            let record = LibraryIndexSchemaV5.NotebookRecord(id: manifest.id)
            record.title = "Biology"
            record.isFavorite = true
            record.tagsRaw = "exam"
            record.indexedAt = .distantFuture
            container.mainContext.insert(record)
            container.mainContext.insert(LibraryIndexSchemaV5.NotebookSearchText(notebookID: manifest.id, text: "prophase"))
            try container.mainContext.save()
        }

        let store = launch(root)
        let record = try XCTUnwrap(store.record(manifest.id))
        XCTAssertEqual([record.title, record.tagsRaw], ["Biology", "exam"], "what the record knew comes across")
        XCTAssertNil(record.manifestDate)
        XCTAssertEqual(LibraryIndex.notebookIDs(matching: "prophase", in: ModelContext(store.context.container)), [manifest.id])
        XCTAssertGreaterThanOrEqual(LibraryIndex.schemaNumber, 7, "so the launch after the update reads every manifest once")

        let first = await LibraryIndex.refresh(root: root, context: store.context)
        XCTAssertEqual(first, [manifest.id], "a record without the date is read, whatever it was stamped with")
        XCTAssertEqual(record.manifestDate, LibraryIndex.manifestDate(ofPackage: root.package(manifest.id)))
        let second = await LibraryIndex.refresh(root: root, context: store.context)
        XCTAssertEqual(second, [])
    }
}
