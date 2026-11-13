import XCTest
import SwiftData
@testable import OwlLuna

/// Folders inside folders: the tree, the store's changes, `folders.json`, and an index coming over from the flat schema.
@MainActor
final class FolderTests: XCTestCase {
    private var container: ModelContainer?
    private let paper = PageDefaults(template: .grid, paperColor: .white, pageSize: .letter)

    private func makeStore() throws -> LibraryStore {
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        self.container = container
        return LibraryStore(root: temporaryRoot(self), context: container.mainContext)
    }

    private func makeNotebook(_ title: String, in store: LibraryStore, folder: FolderRecord?) async throws -> NotebookRecord {
        var manifest = NotebookManifest(title: title, defaults: paper, pages: [paper.newPage()])
        manifest.library.folderID = folder?.id
        try await NotebookPackage(root: store.root, id: manifest.id).create(manifest)
        store.index(manifest)
        return try XCTUnwrap(store.record(manifest.id))
    }

    private func node(_ name: String, _ index: Int, in parent: FolderTree.Node? = nil) -> FolderTree.Node {
        FolderTree.Node(id: UUID(), parent: parent?.id, name: name, sortIndex: index)
    }

    func testTheTreeListsParentsBeforeTheirChildren() {
        let science = node("Science", 1), art = node("Art", 0)
        let physics = node("Physics", 5, in: science), biology = node("Biology", 2, in: science), labs = node("Labs", 0, in: physics)
        let tree = FolderTree([labs, physics, science, biology, art])
        XCTAssertEqual(tree.rows().map { tree.name(of: $0.id) }, ["Art", "Science", "Biology", "Physics", "Labs"])
        XCTAssertEqual(tree.rows().map(\.depth), [0, 0, 1, 1, 2])
        XCTAssertEqual(tree.rows().map(\.hasChildren), [false, true, false, true, false])
        XCTAssertEqual(tree.rows(collapsed: [science.id]).map { tree.name(of: $0.id) }, ["Art", "Science"], "a folded folder keeps its folders out of sight")
        XCTAssertEqual(tree.subtree(science.id), [science.id, physics.id, biology.id, labs.id])
        XCTAssertEqual(tree.path(of: labs.id), "Science › Physics › Labs")
        XCTAssertEqual(tree.path(of: labs.id, from: science.id), "Physics › Labs")
        XCTAssertEqual(tree.ancestors(of: labs.id), [physics.id, science.id])
        XCTAssertEqual(tree.height(of: science.id), 2)
    }

    func testAFolderCannotGoInsideItself() {
        let science = node("Science", 0), physics = node("Physics", 0, in: science), labs = node("Labs", 0, in: physics), art = node("Art", 1)
        let tree = FolderTree([science, physics, labs, art])
        XCTAssertFalse(tree.canMove(science.id, into: science.id))
        XCTAssertFalse(tree.canMove(science.id, into: labs.id), "nor inside a folder it holds")
        XCTAssertTrue(tree.canMove(labs.id, into: art.id))
        XCTAssertTrue(tree.canMove(labs.id, into: nil))
        XCTAssertFalse(tree.canMove(labs.id, into: UUID()))

        var chain = [node("0", 0)]
        for level in 1...FolderTree.maximumDepth { chain.append(node("\(level)", 0, in: chain[level - 1])) }
        let deep = FolderTree(chain + [science, physics, labs])
        XCTAssertFalse(deep.canAddFolder(inside: chain.last?.id), "the sidebar stops at five levels")
        XCTAssertTrue(deep.canAddFolder(inside: chain[FolderTree.maximumDepth - 1].id))
        XCTAssertFalse(deep.canMove(science.id, into: chain[FolderTree.maximumDepth - 2].id), "a folder's own folders count towards the limit")
        XCTAssertTrue(deep.canMove(labs.id, into: chain[FolderTree.maximumDepth - 1].id))
    }

    func testADamagedTreeStillShowsEveryFolder() {
        var a = node("A", 0), b = node("B", 1)
        a.parent = b.id
        b.parent = a.id
        let orphan = FolderTree.Node(id: UUID(), parent: UUID(), name: "Orphan", sortIndex: 2)
        let tree = FolderTree([a, b, orphan])
        XCTAssertEqual(Set(tree.rows().map(\.id)), [a.id, b.id, orphan.id], "folders that loop, or whose parent is gone, sit at the top level")
        XCTAssertTrue(tree.rows().allSatisfy { $0.depth == 0 })
    }

    func testNamesakesAtTheSamePlaceKeepTheirOrder() {
        let one = node("Test", 0), two = node("Test", 0), child = node("Inside", 1, in: one)
        let trees = (0..<40).map { FolderTree($0.isMultiple(of: 2) ? [one, two, child] : [two, child, one]) }
        XCTAssertEqual(Set(trees.map { $0.rows().map(\.id) }).count, 1, "the sidebar doesn't swap them as it redraws")
    }

    func testFoldersNestMoveAndAreDeletedWithoutLosingAnything() async throws {
        let store = try makeStore()
        let science = try XCTUnwrap(store.createFolder(name: "Science", cloth: .jade))
        let physics = try XCTUnwrap(store.createFolder(name: "Physics", cloth: .moss, parent: science))
        let labs = try XCTUnwrap(store.createFolder(name: "Labs", cloth: .rose, parent: physics))
        let art = try XCTUnwrap(store.createFolder(name: "Art", cloth: .slate))
        XCTAssertEqual([science, physics, labs, art].map(\.sortIndex), [0, 1, 2, 3], "numbered in sidebar order")
        let notes = try await makeNotebook("Mechanics", in: store, folder: physics)
        let report = try await makeNotebook("Pendulum", in: store, folder: labs)

        XCTAssertFalse(store.moveFolder(science, into: labs))
        XCTAssertTrue(store.moveFolder(labs, into: art))
        XCTAssertEqual(store.folderTree().path(of: labs.id), "Art › Labs")
        XCTAssertEqual(report.folder?.id, labs.id, "a folder takes its notebooks with it")

        store.moveFolder(art, into: physics)
        XCTAssertEqual(store.folderTree().rows().map { store.folderTree().name(of: $0.id) }, ["Science", "Physics", "Art", "Labs"])
        store.deleteFolder(physics)
        let tree = store.folderTree()
        XCTAssertEqual(tree.rows().map { tree.name(of: $0.id) }, ["Science", "Art", "Labs"])
        XCTAssertEqual(tree.parent(of: art.id), science.id, "the folders it held move up to where it sat")
        await waitForFolder(of: notes, toBe: science.id)
        XCTAssertEqual(notes.folder?.id, science.id, "and so do its notebooks")

        await store.finishWritingShelves()
        let file = FolderFile.read(store.root)
        XCTAssertEqual(file.folders.map(\.name), ["Science", "Art", "Labs"])
        XCTAssertEqual(file.folders.map(\.parentID), [nil, science.id, art.id])
    }

    private func waitForFolder(of record: NotebookRecord, toBe id: UUID) async {
        let deadline = Date().addingTimeInterval(5)
        while record.folder?.id != id, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testEveryLevelSortsByName() throws {
        let store = try makeStore()
        let zoo = try XCTUnwrap(store.createFolder(name: "Zoology", cloth: .jade))
        let art = try XCTUnwrap(store.createFolder(name: "Art", cloth: .jade))
        let reptiles = try XCTUnwrap(store.createFolder(name: "Reptiles", cloth: .jade, parent: zoo))
        let birds = try XCTUnwrap(store.createFolder(name: "Birds", cloth: .jade, parent: zoo))
        store.sortFoldersByName([zoo, art, reptiles, birds])
        let tree = store.folderTree()
        XCTAssertEqual(tree.rows().map { tree.name(of: $0.id) }, ["Art", "Zoology", "Birds", "Reptiles"])

        store.moveFolders([art, zoo, birds, reptiles], from: IndexSet(integer: 3), to: 2)
        let moved = store.folderTree()
        XCTAssertEqual(moved.rows().map { moved.name(of: $0.id) }, ["Art", "Zoology", "Reptiles", "Birds"], "dragging reorders a folder among its own siblings")
        store.moveFolders([art, zoo, reptiles, birds], from: IndexSet(integer: 3), to: 0)
        let kept = store.folderTree()
        XCTAssertEqual(kept.parent(of: birds.id), zoo.id, "and never takes it out of its folder")
        XCTAssertEqual(kept.rows().map { kept.name(of: $0.id) }, ["Art", "Zoology", "Birds", "Reptiles"])
    }

    func testAnIndexFromTheFlatSchemaMigratesAndLearnsItsParents() async throws {
        let root = temporaryRoot(self)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        let science = UUID(), physics = UUID()
        var file = FolderFile()
        file.folders = [FolderEntry(id: science, name: "Science", clothRaw: "jade", createdAt: .now, sortIndex: 0),
                        FolderEntry(id: physics, name: "Physics", clothRaw: "moss", createdAt: .now, sortIndex: 1, parentID: science)]
        try file.write(root)
        XCTAssertEqual(FolderFile.read(root).folders.map(\.parentID), [nil, science])
        XCTAssertNil(FolderFile.read(root).folders[1].extra["parent"], "the parent is read, not carried along as an unknown key")

        var manifest = NotebookManifest(title: "Mechanics", defaults: paper, pages: [paper.newPage()])
        manifest.library.folderID = physics
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)

        try autoreleasepool {
            let old = Schema(versionedSchema: LibraryIndexSchemaV2.self)
            let container = try ModelContainer(for: old, configurations: ModelConfiguration(schema: old, url: root.indexStore, cloudKitDatabase: .none))
            let folder = LibraryIndexSchemaV2.FolderRecord(id: physics)
            folder.name = "Physics"
            let record = LibraryIndexSchemaV2.NotebookRecord(id: manifest.id)
            record.title = "Mechanics"
            record.folder = folder
            record.indexedAt = .distantFuture
            container.mainContext.insert(folder)
            container.mainContext.insert(record)
            container.mainContext.insert(LibraryIndexSchemaV2.NotebookSearchText(notebookID: manifest.id, text: "momentum"))
            try container.mainContext.save()
        }

        let (container, recovered) = LibraryIndex.makeContainer(root: root)
        XCTAssertFalse(recovered, "the old index is migrated, not set aside")
        let context = container.mainContext
        XCTAssertEqual(try context.fetch(FetchDescriptor<FolderRecord>()).map(\.name), ["Physics"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<NotebookRecord>()).first?.folder?.id, physics)
        XCTAssertEqual(LibraryIndex.notebookIDs(matching: "momentum", in: ModelContext(container)), [manifest.id], "search text comes across")

        await LibraryIndex.refresh(root: root, context: context)
        let folders = try context.fetch(FetchDescriptor<FolderRecord>(sortBy: [SortDescriptor(\.sortIndex)]))
        XCTAssertEqual(folders.map(\.name), ["Science", "Physics"])
        XCTAssertEqual(folders.map(\.parentID), [nil, science], "the refresh reads each folder's parent from folders.json")
    }

    func testAFolderListFromBeforeChangesWereDatedStillReads() async throws {
        let store = try makeStore()
        let id = UUID()
        let raw = """
        {"folders": [{"id": "\(id.uuidString)", "name": "Bio", "cloth": "moss", "createdAt": "2026-01-01T00:00:00.000Z", "sortIndex": 0}]}
        """
        try FileManager.default.createDirectory(at: store.root.library, withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: store.root.foldersFile)
        let old = try XCTUnwrap(try FolderFile.load(store.root)?.folders.first)
        XCTAssertEqual([old.name, old.clothRaw], ["Bio", "moss"])
        XCTAssertTrue(FolderEntry.Field.allCases.allSatisfy { old.changedAt($0) == nil }, "a list from before dates has none, and needs none")

        await LibraryIndex.refresh(root: store.root, context: store.context)
        let folder = try XCTUnwrap(try store.context.fetch(FetchDescriptor<FolderRecord>()).first)
        store.renameFolder(folder, to: "Biology")
        await store.finishWritingShelves()
        let renamed = try XCTUnwrap(FolderFile.read(store.root).folders.first)
        XCTAssertEqual(renamed.name, "Biology")
        XCTAssertNotNil(renamed.changedAt(.name), "a change made here is dated")
        XCTAssertNil(renamed.changedAt(.cloth), "and only what changed")
    }

    func testAFolderListKeepsItsNameAndKeysThisVersionDoesNotKnow() throws {
        let raw = """
        {"folders": [{"id": "\(UUID().uuidString)", "name": "Bio"}], "listID": "one", "later": {"kept": true}}
        """
        var file = try XCTUnwrap(FolderFile(Data(raw.utf8)))
        XCTAssertEqual(file.listID, "one")
        file.folders[0].name = "Biology"
        let again = try XCTUnwrap(FolderFile(file.encoded()))
        XCTAssertEqual(again.folders.map(\.name), ["Biology"])
        XCTAssertEqual(again.listID, "one")
        XCTAssertEqual(again.extra["later"], JSONValue.object(["kept": .bool(true)]))
        let unnamed = try JSONValue.parse(FolderFile(folders: again.folders).encoded())
        XCTAssertNil(unnamed["listID"], "a list without a name is written without one")
        XCTAssertNil(FolderFile(Data(#"["folders"]"#.utf8)), "and one that isn't an object isn't a list")
    }

    func testAFolderOnTwoDevicesIsSettledOneFieldAtATime() throws {
        let earlier = Date(timeIntervalSinceReferenceDate: 800_000_000), later = earlier.addingTimeInterval(60)
        let base = FolderEntry(id: UUID(), name: "Science", clothRaw: "jade", createdAt: earlier, sortIndex: 0)
        var here = base, there = base
        here.name = "Physics"
        here.setChangedAt(later, for: .name)
        there.clothRaw = "rose"
        there.setChangedAt(later, for: .cloth)
        there.sortIndex = 4
        let settled = FolderEntry.settled(newer: there, older: here)
        XCTAssertEqual(settled.name, "Physics", "a dated change in the older list stands over the newer list's undated name")
        XCTAssertEqual(settled.clothRaw, "rose")
        XCTAssertEqual(settled.sortIndex, 4, "with neither dated, the newer list's goes")
        XCTAssertEqual(try XCTUnwrap(settled.changedAt(.name)).timeIntervalSince(later), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(settled.changedAt(.cloth)).timeIntervalSince(later), 0, accuracy: 0.001)

        var renamedAgain = there
        renamedAgain.name = "Chemistry"
        renamedAgain.setChangedAt(later.addingTimeInterval(60), for: .name)
        XCTAssertEqual(FolderEntry.settled(newer: here, older: renamedAgain).name, "Chemistry", "the later change wins, whichever list it is in")
    }
}
