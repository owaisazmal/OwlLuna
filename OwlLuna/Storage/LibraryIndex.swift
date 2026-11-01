import Foundation
import SwiftData
import os

/// The library index: a SwiftData cache of what's in the notebook manifests and `folders.json`,
/// for fast sorting, filtering and search. It can always be rebuilt from those files.
/// Search text has its own table, so the shelf's queries never read it. Folders name the folder they sit inside,
/// and a notebook says whether it is locked, which tags it and its pages carry, whether it is the daily journal, and
/// which manifest it was read from.
enum LibraryIndexSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] { [NotebookRecord.self, FolderRecord.self, NotebookSearchText.self] }

    @Model
    final class NotebookRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var title: String = ""
        var createdAt: Date = Date()
        var modifiedAt: Date = Date()
        var lastOpenedAt: Date?
        var pageCount: Int = 0
        var currentPage: Int = 0
        var isFavorite: Bool = false
        var deletedAt: Date?
        var folder: FolderRecord?
        var coverStyleRaw: String = CoverStyle.cloth.rawValue
        var clothRaw: String = ClothColor.slate.rawValue
        var inksRaw: String = "teal,blue"
        var coverSeed: Int = 0
        var firstPageID: UUID?
        var firstPageInkHash: String?
        var firstPageThumbKey: String?
        var firstPageIsPDF: Bool = false
        var isReadOnly: Bool = false
        var issueCount: Int = 0
        var indexedAt: Date = Date.distantPast
        var isLocked: Bool = false
        /// The notebook's tags, one to a line.
        var tagsRaw: String = ""
        /// Every tag on any of its pages, one to a line.
        var pageTagsRaw: String = ""
        /// The modification date of the manifest file the record was last brought up to date with.
        var manifestDate: Date?
        var isJournal: Bool = false

        init(id: UUID) { self.id = id }
    }

    @Model
    final class FolderRecord {
        @Attribute(.unique) var id: UUID = UUID()
        var name: String = ""
        var clothRaw: String = ClothColor.slate.rawValue
        var createdAt: Date = Date()
        var sortIndex: Int = 0
        var parentID: UUID?
        @Relationship(deleteRule: .nullify, inverse: \LibraryIndexSchemaV6.NotebookRecord.folder)
        var notebooks: [NotebookRecord]? = []

        init(id: UUID) { self.id = id }
    }

    /// Everything recognised, typed or read from PDFs in one notebook. Deliberately not a relationship of the record.
    @Model
    final class NotebookSearchText {
        @Attribute(.unique) var notebookID: UUID = UUID()
        var text: String = ""

        init(notebookID: UUID, text: String) {
            self.notebookID = notebookID
            self.text = text
        }
    }
}

typealias NotebookRecord = LibraryIndexSchemaV6.NotebookRecord
typealias FolderRecord = LibraryIndexSchemaV6.FolderRecord
typealias NotebookSearchText = LibraryIndexSchemaV6.NotebookSearchText

extension NotebookRecord {
    var isTrashed: Bool { deletedAt != nil }
    var coverStyle: CoverStyle { CoverStyle(rawValue: coverStyleRaw) ?? .cloth }
    var cloth: ClothColor { ClothColor(rawValue: clothRaw) ?? .slate }
    var tags: [String] { Tags.split(tagsRaw) }
    var pageTags: [String] { Tags.split(pageTagsRaw) }

    var cover: CoverSpec {
        get {
            CoverSpec(styleRaw: coverStyleRaw, clothRaw: clothRaw, inksRaw: inksRaw.split(separator: ",").map(String.init),
                      seed: UInt32(clamping: coverSeed))
        }
        set {
            coverStyleRaw = newValue.styleRaw
            clothRaw = newValue.clothRaw
            inksRaw = newValue.inksRaw.joined(separator: ",")
            coverSeed = Int(newValue.seed)
        }
    }

    /// Copies the indexed fields, assigning only those that differ so unchanged records don't invalidate
    /// the library's queries. Returns whether anything changed.
    @discardableResult
    func apply(_ manifest: NotebookManifest, issues: Int) -> Bool {
        let first = manifest.pages.first
        var changed = false
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<NotebookRecord, T>, _ value: T) {
            guard self[keyPath: keyPath] != value else { return }
            self[keyPath: keyPath] = value
            changed = true
        }
        set(\.title, manifest.title)
        set(\.createdAt, manifest.createdAt)
        set(\.modifiedAt, manifest.modifiedAt)
        set(\.lastOpenedAt, manifest.library.lastOpenedAt)
        set(\.pageCount, manifest.pages.count)
        set(\.currentPage, min(manifest.library.currentPage, max(manifest.pages.count - 1, 0)))
        set(\.isFavorite, manifest.library.isFavorite)
        set(\.deletedAt, manifest.library.deletedAt)
        set(\.isLocked, manifest.library.isLocked)
        set(\.isJournal, manifest.library.isJournal)
        set(\.tagsRaw, Tags.joined(manifest.library.tags))
        set(\.pageTagsRaw, Tags.joined(manifest.pageTags))
        set(\.coverStyleRaw, manifest.cover.styleRaw)
        set(\.clothRaw, manifest.cover.clothRaw)
        set(\.inksRaw, manifest.cover.inksRaw.joined(separator: ","))
        set(\.coverSeed, Int(manifest.cover.seed))
        set(\.firstPageID, first?.id)
        set(\.firstPageInkHash, first?.inkHash)
        set(\.firstPageThumbKey, first?.thumbnailKey)
        let firstIsPDF: Bool = if case .pdf = first?.background { true } else { false }
        set(\.firstPageIsPDF, firstIsPDF)
        set(\.isReadOnly, manifest.isNewerThanSupported)
        set(\.issueCount, issues)
        if changed { indexedAt = .now }
        return changed
    }
}

extension FolderRecord {
    var cloth: ClothColor { ClothColor(rawValue: clothRaw) ?? .slate }

    func apply(_ entry: FolderEntry) {
        name = entry.name
        clothRaw = entry.clothRaw
        createdAt = entry.createdAt
        sortIndex = entry.sortIndex
        parentID = entry.parentID
    }

    var entry: FolderEntry {
        FolderEntry(id: id, name: name, clothRaw: clothRaw, createdAt: createdAt, sortIndex: sortIndex, parentID: parentID)
    }

    var node: FolderTree.Node { FolderTree.Node(id: id, parent: parentID, name: name, sortIndex: sortIndex) }
}

extension FolderTree {
    @MainActor
    init(folders: [FolderRecord]) { self.init(folders.map(\.node)) }
}

@MainActor
enum LibraryIndex {
    private static let log = Logger(category: "index")
    static let schemaNumber = 8

    /// Opens the index. A store that can't be opened is set aside (never deleted) and a fresh one is rebuilt
    /// from the manifests; if even that fails, the app runs on an in-memory index for this launch.
    static var schema: Schema { Schema(versionedSchema: LibraryIndexSchemaV6.self) }

    static func makeContainer(root: StorageRoot) -> (container: ModelContainer, recovered: Bool) {
        let schema = schema
        try? FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        // Left to itself SwiftData mirrors the store to CloudKit once the build has an iCloud container.
        let configuration = ModelConfiguration(schema: schema, url: root.indexStore, cloudKitDatabase: .none)
        do {
            return (try ModelContainer(for: schema, migrationPlan: LibraryIndexMigrationPlan.self, configurations: configuration), false)
        } catch {
            log.error("index store unreadable, setting it aside: \(error.localizedDescription)")
            setAside(root.indexStore)
            if let container = try? ModelContainer(for: schema, migrationPlan: LibraryIndexMigrationPlan.self, configurations: configuration) {
                return (container, true)
            }
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            // An in-memory container with a known-good schema cannot fail.
            return (try! ModelContainer(for: schema, configurations: memory), true)
        }
    }

    private static func setAside(_ store: URL) {
        let fileManager = FileManager.default
        let stamp = Int(Date.now.timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let file = store.deletingLastPathComponent().appending(path: store.lastPathComponent + suffix)
            guard fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
            try? fileManager.moveItem(at: file, to: file.deletingLastPathComponent().appending(path: "\(store.lastPathComponent).unreadable-\(stamp)\(suffix)"))
        }
    }

    struct Scanned: Sendable {
        var load: ManifestLoad
        /// Nil when it is the text the index already has.
        var searchText: String?
        var issues: Int
        var manifestDate: Date?
    }

    /// Brings the index up to date with the packages on disk. Reads a notebook only when its manifest isn't the file
    /// its record was read from, or it is one of `rescanning`; reads every one when `full` is set. Returns those it read.
    @discardableResult
    static func refresh(root: StorageRoot, context: ModelContext, full: Bool = false, rescanning: Set<UUID> = []) async -> Set<UUID> {
        let stamps = await Task.detached(priority: .userInitiated) { manifestStamps(root: root) }.value
        let records = (try? context.fetch(FetchDescriptor<NotebookRecord>())) ?? []
        var byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = stamps.filter { id, stamp in
            let record = byID[id]
            return full || rescanning.contains(id) || record?.manifestDate != stamp
                || (record?.firstPageIsPDF == true && record?.firstPageThumbKey?.hasPrefix(NotebookPage.pdfThumbnailPrefix) != true)
        }.map(\.key)
        let container = context.container
        let scanned = await Task.detached(priority: .userInitiated) { await scan(root: root, ids: stale, comparingWith: container) }.value

        let folderFile = await Task.detached(priority: .userInitiated) { Result { try FolderFile.load(root) ?? FolderFile() } }.value
        var folders = Dictionary(((try? context.fetch(FetchDescriptor<FolderRecord>())) ?? []).map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        var arrived: Set<UUID> = []
        switch folderFile {
        case .success(let file):
            for entry in file.folders {
                let record = folders[entry.id] ?? FolderRecord(id: entry.id)
                if folders[entry.id] == nil { context.insert(record); folders[entry.id] = record; arrived.insert(entry.id) }
                record.apply(entry)
            }
            for (id, record) in folders where !file.folders.contains(where: { $0.id == id }) {
                context.delete(record)
                folders[id] = nil
            }
        case .failure(let error):
            // A list that is there and can't be read keeps the folders the index has. A damaged one is written again from them.
            log.error("folders can't be read: \(error.localizedDescription)")
            if error is FolderFile.Damaged, !folders.isEmpty {
                let entries = folders.values.sorted { $0.sortIndex < $1.sortIndex }.map(\.entry)
                await Task.detached(priority: .userInitiated) { try? FolderFile(folders: entries).write(root) }.value
            }
        }

        for (id, item) in scanned {
            let record = byID[id] ?? NotebookRecord(id: id)
            if byID[id] == nil { context.insert(record); byID[id] = record }
            record.apply(item.load.manifest, issues: item.issues)
            record.manifestDate = item.manifestDate
            if let text = item.searchText { setSearchText(text, for: id, in: context) }
            record.folder = item.load.manifest.library.folderID.flatMap { folders[$0] }
        }
        for (id, record) in byID where stamps[id] == nil {
            context.delete(record)
            byID[id] = nil
        }

        // A notebook that came before its folder (a sync, a restore) was left unfiled; the folder's arrival files it.
        let unfiled = arrived.isEmpty ? [] : byID.filter { scanned[$0.key] == nil && $0.value.folder == nil }.map(\.key)
        if !unfiled.isEmpty {
            let filed = await Task.detached(priority: .userInitiated) {
                unfiled.compactMap { id in LibrarySync.filing(ofPackage: root.package(id))?.folderID.map { (id, $0) } }
            }.value
            for (id, folderID) in filed where arrived.contains(folderID) { byID[id]?.folder = folders[folderID] }
        }

        // Notebooks with no search row yet (a migrated or rebuilt index) get theirs from the text already on disk.
        var listing = FetchDescriptor<NotebookSearchText>()
        listing.propertiesToFetch = [\.notebookID]
        let rows = (try? context.fetch(listing)) ?? []
        let have = Set(rows.map(\.notebookID))
        for row in rows where stamps[row.notebookID] == nil { context.delete(row) }
        let missing = stamps.keys.filter { !have.contains($0) && scanned[$0] == nil }
        if !missing.isEmpty {
            let texts = await Task.detached(priority: .userInitiated) { () -> [UUID: String] in
                var result: [UUID: String] = [:]
                for id in missing { result[id] = searchText(in: NotebookPackage(root: root, id: id).textDirectory) }
                return result
            }.value
            for (id, text) in texts { setSearchText(text, for: id, in: context) }
        }
        do { try context.save() } catch { log.error("index save failed: \(error.localizedDescription)") }
        return Set(scanned.keys)
    }

    nonisolated static func searchRow(for id: UUID, in context: ModelContext) -> NotebookSearchText? {
        var descriptor = FetchDescriptor<NotebookSearchText>(predicate: #Predicate { $0.notebookID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Returns whether anything changed.
    @discardableResult
    static func setSearchText(_ text: String, for id: UUID, in context: ModelContext) -> Bool {
        if let row = searchRow(for: id, in: context) {
            guard row.text != text else { return false }
            row.text = text
        } else {
            context.insert(NotebookSearchText(notebookID: id, text: text))
        }
        return true
    }

    /// The notebooks with every term of `query` somewhere in their title, tags or text. Only IDs are read, so PDF text stays on disk.
    nonisolated static func notebookIDs(matching query: String, in context: ModelContext) -> Set<UUID> {
        var found: Set<UUID>?
        // The longest term first, as it matches the fewest; each term after it looks only among the notebooks still in.
        for term in SearchQuery(query).terms.sorted(by: { $0.count > $1.count }) {
            let tag = Tags.normalized(term) ?? term
            let anywhere = found == nil, among = Array(found ?? [])
            var titles = FetchDescriptor<NotebookRecord>(predicate: #Predicate {
                (anywhere || among.contains($0.id))
                    && ($0.title.localizedStandardContains(term) || $0.tagsRaw.localizedStandardContains(tag) || $0.pageTagsRaw.localizedStandardContains(tag))
            })
            titles.propertiesToFetch = [\.id]
            var texts = FetchDescriptor<NotebookSearchText>(predicate: #Predicate {
                (anywhere || among.contains($0.notebookID)) && $0.text.localizedStandardContains(term)
            })
            texts.propertiesToFetch = [\.notebookID]
            let byTitle = ((try? context.fetch(titles)) ?? []).map(\.id)
            let byText = ((try? context.fetch(texts)) ?? []).map(\.notebookID)
            found = Set(byTitle).union(byText)
            if found?.isEmpty == true { break }
        }
        return found ?? []
    }

    nonisolated static func manifestDate(ofPackage url: URL) -> Date? {
        url.appending(path: NotebookPackage.manifestFile).contentModificationDate
    }

    nonisolated static func manifestStamps(root: StorageRoot) -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for id in root.packageIDs() {
            result[id] = manifestDate(ofPackage: root.package(id)) ?? .distantFuture
        }
        return result
    }

    /// Each manifest's date is taken before it is read, so a write in between leaves the notebook to be read again.
    /// With `container`, text the index already has comes back as nil.
    nonisolated static func scan(root: StorageRoot, ids: [UUID], comparingWith container: ModelContainer? = nil) async -> [UUID: Scanned] {
        var result: [UUID: Scanned] = [:]
        for id in ids {
            let package = NotebookPackage(root: root, id: id)
            var date = manifestDate(ofPackage: package.url)
            guard var load = try? await package.readManifest() else { continue }
            if load.needsSave, !load.isReadOnly, let written = try? await package.writeManifest(load.manifest) {
                load.manifest = written
                date = manifestDate(ofPackage: package.url)
            }
            let issues = await package.quarantinedFiles().count + load.manifest.opaquePages.count
            let text = searchText(in: package.textDirectory)
            let unchanged = container.map { searchRow(for: id, in: ModelContext($0))?.text == text } ?? false
            result[id] = Scanned(load: load, searchText: unchanged ? nil : text, issues: issues, manifestDate: date)
        }
        return result
    }

    /// One line for each page and transcript, so a phrase is found across the lines it was written on but not across pages.
    nonisolated static func searchText(in directory: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map(SearchQuery.searchable)
            .joined(separator: "\n")
    }
}
