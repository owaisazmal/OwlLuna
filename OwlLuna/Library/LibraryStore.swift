import UIKit
import PDFKit
import SwiftData
import Observation
import os

enum ImportError: LocalizedError {
    case unreadable, locked, empty

    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "The file couldn't be read.")
        case .locked: String(localized: "This PDF is password protected. Unlock it in Files or Preview, then import it again.")
        case .empty: String(localized: "The file doesn't contain any pages.")
        }
    }
}

/// Library-level changes. Every change is written to the notebook's manifest (through its open document
/// if it's being edited, so the two never race) and mirrored in the SwiftData index, which is saved explicitly.
@MainActor
@Observable
final class LibraryStore {
    let root: StorageRoot
    @ObservationIgnored let context: ModelContext
    private(set) var lastError: String?
    /// Bumped on every index save, so views holding derived results (search) know to refresh them.
    private(set) var indexVersion = 0
    /// Bumped only when something search matches on changes (titles, recognised text, notebooks added), so an
    /// active search isn't redone on every autosave.
    private(set) var searchVersion = 0
    /// The saved filters in `smart-shelves.json`, in the order they were made.
    private(set) var smartShelves: [SmartShelf] = []
    @ObservationIgnored private let log = Logger(category: "library")
    @ObservationIgnored private var manifestWrites: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastUpdate: [UUID: UUID] = [:]
    @ObservationIgnored private var lastRefile: [UUID: UUID] = [:]
    @ObservationIgnored private var folderWrite: Task<Void, Never>?
    @ObservationIgnored private var smartShelfWrite: Task<Void, Never>?
    /// Backup files made while a notebook was locked: they hold it whatever has happened to it since.
    @ObservationIgnored private var backupsHoldingLocked: Set<URL> = []
    /// Called with the notebooks a permanent delete actually removed.
    @ObservationIgnored var onPermanentlyDeleted: (([UUID]) -> Void)?
    /// Called after every change to the index made on this device, so a sync can follow it.
    @ObservationIgnored var onIndexSaved: (() -> Void)?
    /// Called when the words read from a notebook change.
    @ObservationIgnored var onSearchTextChanged: ((UUID) -> Void)?
    /// Called with this device's journal when it gave way to one begun earlier on another device.
    @ObservationIgnored var onJournalSetAside: ((UUID) -> Void)?
    /// Called once a change to the smart shelves is on disk, so a sync can follow it.
    @ObservationIgnored var onShelvesSaved: (() -> Void)?
    /// This device's settings, and which notebook it uses as the daily journal.
    @ObservationIgnored let defaults: UserDefaults

    init(root: StorageRoot, context: ModelContext, defaults: UserDefaults = .standard) {
        self.root = root
        self.context = context
        self.defaults = defaults
    }

    func record(_ id: UUID) -> NotebookRecord? {
        try? context.fetch(FetchDescriptor<NotebookRecord>(predicate: #Predicate { $0.id == id })).first
    }

    func saveIndex() {
        do { try context.save() } catch { log.error("index save failed: \(error.localizedDescription)") }
        indexVersion &+= 1
        onIndexSaved?()
    }

    func clearError() { lastError = nil }

    // MARK: Creating

    @discardableResult
    func createNotebook(id: UUID = UUID(), title: String, cover: CoverSpec, defaults: PageDefaults, folder: FolderRecord?,
                        startsWithBoard: Bool = false, paper: CustomPaper? = nil) async throws -> UUID {
        let folderID = folder?.id
        let manifest = try await assemble(id) { package in
            var defaults = defaults
            if let paper, !startsWithBoard {
                // The notebook keeps its own copy, so it stays whole when it is backed up, synced or shared.
                let file = try await package.importAsset(from: paper.url, ext: paper.url.pathExtension)
                defaults.paper = NotebookPaper(id: paper.id, background: paper.background(file: file), size: paper.newPageSize(width: defaults.pageSize.points.width))
            }
            let first = startsWithBoard ? NotebookPage.board(template: defaults.template, color: defaults.paperColor) : defaults.newPage()
            var manifest = NotebookManifest(id: id, title: title, cover: cover, defaults: defaults, pages: [first])
            manifest.library.folderID = folderID
            manifest.library.lastOpenedAt = .now
            try await package.create(manifest)
            return manifest
        }
        index(manifest)
        return manifest.id
    }

    /// Puts a new notebook together in `Arriving/` and renames it into the library once its manifest is written.
    @discardableResult
    func assemble(_ id: UUID, _ build: (NotebookPackage) async throws -> NotebookManifest) async throws -> NotebookManifest {
        try await Self.assemble(id, in: root, build)
    }

    /// The same for any library, on whichever actor calls it.
    @discardableResult
    nonisolated(nonsending) static func assemble(_ id: UUID, in root: StorageRoot,
                                                 _ build: (NotebookPackage) async throws -> NotebookManifest) async throws -> NotebookManifest {
        let fileManager = FileManager.default
        let staging = StorageRoot(url: root.staging(id))
        defer { try? fileManager.removeItem(at: staging.url) }
        try fileManager.createDirectory(at: staging.library, withIntermediateDirectories: true)
        let package = NotebookPackage(root: staging, id: id)
        let manifest = try await build(package)
        guard fileManager.fileExists(atPath: package.manifestURL.path(percentEncoded: false)) else { throw PackageError.missing }
        try fileManager.createDirectory(at: root.library, withIntermediateDirectories: true)
        try fileManager.moveItem(at: package.url, to: root.package(id))
        return manifest
    }

    /// A notebook with the default paper from Settings, dated rather than named, created without the sheet.
    func createQuickNote(folder: FolderRecord?) async throws -> UUID {
        let template = defaults.defaultTemplate
        let color = defaults.defaultPaperColor
        let size = defaults.defaultPageSize
        let paper = defaults.string(forKey: SettingsKey.defaultPaper).flatMap { PaperShelf.paper($0, in: root) }
        let id = UUID()
        return try await createNotebook(id: id, title: String(localized: "Note \(Date.now.formatted(date: .abbreviated, time: .shortened))"),
                                        cover: .defaultCloth(for: id), defaults: PageDefaults(template: template, paperColor: color, pageSize: size),
                                        folder: folder, paper: paper)
    }

    /// A notebook that opens on a whiteboard, created without the sheet.
    func createWhiteboard(folder: FolderRecord?) async throws -> UUID {
        let starter = NotebookStarter.whiteboard, id = UUID()
        let size = defaults.defaultPageSize
        return try await createNotebook(id: id, title: starter.notebookTitle, cover: starter.spec(for: id),
                                        defaults: PageDefaults(template: starter.template, paperColor: starter.paperColor, pageSize: size),
                                        folder: folder, startsWithBoard: true)
    }

    /// A notebook of a PDF's pages. A locked PDF is opened with what `password` gives and kept without its lock.
    @discardableResult
    func importPDF(from url: URL, folder: FolderRecord?, password: PDFImport.Password? = nil,
                   progress: PDFImport.Progress? = nil) async throws -> UUID {
        try await importPages(folder: folder) { package in
            let file = try await package.importAsset(from: url, ext: "pdf")
            let pages = try await PDFImport.pages(in: package, file: file, password: password, progress: progress)
            return (url.deletingPathExtension().lastPathComponent, pages)
        }
    }

    /// A new notebook whose pages are sheets scanned with the camera.
    @discardableResult
    func importScan(_ images: [UIImage], folder: FolderRecord?) async throws -> UUID {
        try await importPages(folder: folder) { package in
            let pages = try await DocumentScan.pages(from: images, in: package)
            return (String(localized: "Scan \(Date.now.formatted(date: .abbreviated, time: .shortened))"), pages)
        }
    }

    /// A notebook of the pages `bring` puts in its package, on blank paper with the first on the cover, read for search once it is in.
    private func importPages(folder: FolderRecord?,
                             _ bring: @MainActor (NotebookPackage) async throws -> (title: String, pages: [NotebookPage])) async throws -> UUID {
        let folderID = folder?.id
        let id = UUID()
        let manifest = try await assemble(id) { package in
            let brought = try await bring(package)
            var cover = CoverSpec.defaultCloth(for: id)
            cover.style = .firstPage
            var manifest = NotebookManifest(id: id, title: brought.title, cover: cover,
                                            defaults: PageDefaults(template: .blank, paperColor: .white, pageSize: .letter), pages: brought.pages)
            manifest.library.folderID = folderID
            try await package.create(manifest)
            return manifest
        }
        index(manifest)
        indexHandwriting(package: NotebookPackage(root: root, id: id), pages: manifest.pages)
        return id
    }

    @discardableResult
    func duplicate(_ record: NotebookRecord) async throws -> UUID {
        let sourceID = record.id, searchText = searchText(for: record.id)
        if let open = DocumentRegistry.shared.document(for: sourceID) { await open.flush() }
        let newID = UUID()
        let source = root.package(sourceID)
        let copy = try await assemble(newID) { package in
            let destination = package.url
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: source, to: destination)
                try CardFiles.renew(in: destination)
            }.value
            return try await package.updateManifest { manifest in
                manifest.id = newID
                manifest.title = String(localized: "\(manifest.title) Copy")
                manifest.createdAt = .now
                manifest.modifiedAt = .now
                manifest.library.isFavorite = false
                manifest.library.isJournal = false
                manifest.library.lastOpenedAt = nil
            }
        }
        index(copy)
        updateSearchText(searchText, for: newID)
        return newID
    }

    // MARK: Changing

    func rename(_ record: NotebookRecord, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.isReadOnly, !trimmed.isEmpty, trimmed != record.title else { return }
        record.title = trimmed
        searchVersion &+= 1
        saveIndex()
        if let document = DocumentRegistry.shared.document(for: record.id) {
            document.rename(trimmed)
        } else {
            update(record.id) { $0.title = trimmed; $0.modifiedAt = .now }
        }
    }

    func setCover(_ cover: CoverSpec, for record: NotebookRecord) {
        guard !record.isReadOnly else { return }
        record.cover = cover
        saveIndex()
        if let document = DocumentRegistry.shared.document(for: record.id) {
            document.updateCover(cover)
        } else {
            update(record.id) { $0.cover = cover; $0.modifiedAt = .now }
        }
    }

    func setFavorite(_ favorite: Bool, for records: [NotebookRecord]) {
        changeLibraryState(records, index: { $0.isFavorite = favorite }) { $0.isFavorite = favorite }
    }

    func setLocked(_ locked: Bool, for records: [NotebookRecord]) {
        changeLibraryState(records, index: { $0.isLocked = locked }) { $0.isLocked = locked }
        searchVersion &+= 1
    }

    func setTags(_ tags: [String], for records: [NotebookRecord]) {
        let tags = Tags.merged(tags), raw = Tags.joined(tags)
        changeLibraryState(records, index: { $0.tagsRaw = raw }) { $0.tags = tags }
        searchVersion &+= 1
    }

    /// Adds and takes off tags across notebooks, each keeping the other tags it has.
    func editTags(_ edit: TagEdit, for records: [NotebookRecord]) {
        guard !edit.isEmpty else { return }
        changeLibraryState(records, index: { $0.tagsRaw = Tags.joined(edit.applied(to: $0.tags)) }) { $0.tags = edit.applied(to: $0.tags) }
        searchVersion &+= 1
    }

    /// A notebook saved by a newer version goes in and out of Recently Deleted too, with only its filing written.
    func moveToTrash(_ records: [NotebookRecord]) {
        let now = Date.now
        changeLibraryState(records, includingReadOnly: true, index: { $0.deletedAt = now }) { $0.deletedAt = now }
    }

    func restore(_ records: [NotebookRecord]) {
        let journal = records.contains(where: \.isJournal)
        changeLibraryState(records, includingReadOnly: true, index: { $0.deletedAt = nil }) { $0.deletedAt = nil }
        if journal { Task { await settleJournal() } }
    }

    func move(_ records: [NotebookRecord], to folder: FolderRecord?) {
        let folderID = folder?.id
        changeLibraryState(records, index: { $0.folder = folder }) { $0.folderID = folderID }
    }

    /// Permanently removes notebooks from the library. Only offered for notebooks already in Recently Deleted.
    /// Each package is renamed into `Deleting/` (one cheap move on the main thread) and removed in the background;
    /// anything left there is swept at the next launch. `expiring` is this device's Recently Deleted running out.
    func deletePermanently(_ records: [NotebookRecord], expiring: Bool = false) {
        guard noteExpiry(of: records, expiring: expiring) else { return }
        let registry = DocumentRegistry.shared
        var moved: [URL] = []
        var deleted: [UUID] = []
        for record in records where record.isTrashed && registry.document(for: record.id) == nil && !registry.isOpening(record.id) {
            do {
                let tombstone = try root.moveToDeleting(record.id)
                moved.append(tombstone)
                deleted.append(record.id)
                if let row = LibraryIndex.searchRow(for: record.id, in: context) { context.delete(row) }
                context.delete(record)
            } catch {
                lastError = String(localized: "“\(record.title)” couldn't be deleted: \(error.localizedDescription)")
            }
        }
        saveIndex()
        guard !moved.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in moved { try? FileManager.default.removeItem(at: url) }
        }
        onPermanentlyDeleted?(deleted)
    }

    /// A delete for good made here goes to every device. One that is only this device's Recently Deleted running out is
    /// noted first, so a sync leaves the copy to a device that may keep it longer; if it can't be noted, nothing goes.
    private func noteExpiry(of records: [NotebookRecord], expiring: Bool) -> Bool {
        var expired = ExpiredTrash.read(root)
        let before = expired
        if expiring {
            expired.note(Dictionary(records.map { ($0.id, $0.deletedAt ?? .now) }, uniquingKeysWith: { $1 }))
        } else {
            for record in records { expired.notebooks[record.id] = nil }
        }
        guard expired != before else { return true }
        do {
            try expired.write(root)
            return true
        } catch {
            log.error("expired notebooks couldn't be noted: \(error.localizedDescription)")
            return !expiring
        }
    }

    /// Finishes deletes interrupted by the app quitting.
    nonisolated static func sweepDeleted(root: StorageRoot) {
        try? FileManager.default.removeItem(at: root.deleting)
    }

    /// Clears away packages untouched since `cutoff` that a quit left with neither a manifest nor ink, which nothing lists or opens.
    nonisolated static func sweepUnfinished(root: StorageRoot, untouchedSince cutoff: Date) {
        for id in root.packageIDs() where isUnfinished(root.package(id), untouchedSince: cutoff) { try? root.removePackage(id) }
    }

    /// Anything that may be a manifest (damaged, previous or still downloading), or ink to rebuild one from, keeps a package.
    private nonisolated static func isUnfinished(_ package: URL, untouchedSince cutoff: Date) -> Bool {
        let fileManager = FileManager.default
        guard let values = try? package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .attributeModificationDateKey]),
              values.isDirectory == true, values.isSymbolicLink != true, let touched = values.attributeModificationDate, touched < cutoff,
              let names = try? fileManager.contentsOfDirectory(atPath: package.path(percentEncoded: false)),
              !names.contains(where: { $0.hasPrefix("manifest") || $0.hasSuffix(".icloud") }) else { return false }
        for name in names {
            var isDirectory: ObjCBool = false
            let url = package.appending(path: name)
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            guard let inside = try? fileManager.contentsOfDirectory(atPath: url.path(percentEncoded: false)),
                  !inside.contains(where: { $0.hasSuffix(".icloud") }), name != "ink" || inside.isEmpty else { return false }
        }
        return true
    }

    /// The index may be behind the files (a sync that stopped part-way), so each notebook's own manifest has the last
    /// word. `waiting` are notebooks a sync couldn't settle, which may have been restored on another device.
    func purgeExpiredTrash(olderThan days: Int = TrashLength.initial.days, skipping waiting: Set<UUID> = []) async {
        let cutoff = TrashLength.cutoff(days)
        let candidates = ((try? context.fetch(FetchDescriptor<NotebookRecord>(predicate: #Predicate { $0.deletedAt != nil }))) ?? [])
            .filter { ($0.deletedAt ?? .now) < cutoff && !waiting.contains($0.id) }.map(\.id)
        guard !candidates.isEmpty else { return }
        for write in candidates.compactMap({ manifestWrites[$0] }) { await write.value }
        let root = root
        let expired = await Task.detached(priority: .utility) {
            candidates.filter { id in LibrarySync.filing(ofPackage: root.package(id))?.deletedAt.map { $0 < cutoff } ?? false }
        }.value
        let records = expired.compactMap(record).filter { ($0.deletedAt ?? .now) < cutoff }
        if !records.isEmpty { deletePermanently(records, expiring: true) }
    }

    /// Each change is stamped, which is what carries it to other devices without dating the notebook.
    private func changeLibraryState(_ records: [NotebookRecord], includingReadOnly: Bool = false, index: (NotebookRecord) -> Void,
                                    manifest change: @escaping @Sendable (inout LibraryState) -> Void) {
        let now = Date.now
        for record in records where includingReadOnly || !record.isReadOnly {
            index(record)
            if record.isReadOnly {
                refile(record.id) {
                    let before = $0
                    change(&$0)
                    $0.stamp(changesSince: before, at: now)
                }
            } else if let document = DocumentRegistry.shared.document(for: record.id) {
                document.updateLibraryState(change)
            } else {
                update(record.id) {
                    let before = $0.library
                    change(&$0.library)
                    $0.library.stamp(changesSince: before, at: now)
                }
            }
        }
        saveIndex()
    }

    /// Writes only a notebook's filing, in turn with its other writes, for one this version mustn't save whole.
    @discardableResult
    private func refile(_ id: UUID, _ change: @escaping @Sendable (inout LibraryState) -> Void) -> Task<Void, Never> {
        let package = NotebookPackage(root: root, id: id), registry = DocumentRegistry.shared
        let previous = manifestWrites[id], token = UUID()
        lastRefile[id] = token
        registry.willChange(id)
        let write = Task {
            await previous?.value
            await registry.whenReleased(id)
            do {
                let written = try await package.updateLibraryState(change)
                if lastRefile[id] == token, record(id) != nil { index(written) }
            } catch {
                await writeFailed(error, "filing", package: package)
            }
            registry.didChange(id)
            if lastRefile[id] == token { lastRefile[id] = nil }
        }
        manifestWrites[id] = write
        return write
    }

    /// Read-modify-write of a closed notebook's manifest. One that starts opening first takes the change in its
    /// document instead, and opening waits for a write under way. If the write fails, the index is re-read from the file.
    /// Writes to one notebook are chained, so two changes made back to back both land.
    @discardableResult
    func update(_ id: UUID, _ change: @escaping @Sendable (inout NotebookManifest) -> Void) -> Task<Void, Never> {
        let package = NotebookPackage(root: root, id: id), registry = DocumentRegistry.shared
        let previous = manifestWrites[id], token = UUID()
        lastUpdate[id] = token
        // From here until it is written a sync leaves the notebook alone, and one that has it in hand finishes first.
        registry.willChange(id)
        let write = Task {
            await previous?.value
            await registry.whenReleased(id)
            var document: NotebookDocument?
            while document == nil, !registry.startWriting(id) { document = await registry.opened(id) }
            var written: NotebookManifest?
            if let document {
                document.applyLibraryChange(change)
            } else {
                do {
                    written = try await package.updateManifest(change)
                } catch {
                    await writeFailed(error, "manifest", package: package)
                }
                registry.doneWriting(id)
            }
            registry.didChange(id)
            guard lastUpdate[id] == token else { return }
            lastUpdate[id] = nil
            manifestWrites[id] = nil
            // The last write holds every change: the record takes it and its date, so the next launch doesn't read it again.
            if let written, record(id) != nil, registry.document(for: id) == nil, !registry.isOpening(id) { index(written) }
        }
        manifestWrites[id] = write
        return write
    }

    /// A write to a closed notebook failed: it is reported, and the index goes back to what the file holds.
    private func writeFailed(_ error: any Error, _ what: String, package: NotebookPackage) async {
        lastError = String(localized: "A change couldn't be saved: \(error.localizedDescription)")
        log.error("\(what, privacy: .public) update failed for \(package.id): \(error.localizedDescription)")
        if let manifest = try? await package.readManifest().manifest { index(manifest) }
    }

    // MARK: Folders

    private func allFolders() -> [FolderRecord] {
        (try? context.fetch(FetchDescriptor<FolderRecord>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
    }

    private func folderEntries() -> [FolderEntry] {
        allFolders().map(\.entry)
    }

    func folderTree() -> FolderTree { FolderTree(folders: allFolders()) }

    /// Numbers every folder in sidebar order, parents before their children, so a plain sort by index gives that order.
    private func renumberFolders(_ folders: [FolderRecord], tree: FolderTree) {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, id) in tree.ordered.enumerated() where byID[id]?.sortIndex != index { byID[id]?.sortIndex = index }
    }

    private func saveFolders(since before: [FolderEntry]) {
        let folders = allFolders()
        renumberFolders(folders, tree: FolderTree(folders: folders))
        saveIndex()
        writeFolders(since: before)
    }

    @discardableResult
    func createFolder(name: String, cloth: ClothColor, parent: FolderRecord? = nil) -> FolderRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folders = allFolders(), before = folderEntries()
        guard !trimmed.isEmpty, FolderTree(folders: folders).canAddFolder(inside: parent?.id) else { return nil }
        let entry = FolderEntry(id: UUID(), name: trimmed, clothRaw: cloth.rawValue, createdAt: .now,
                                sortIndex: (folders.map(\.sortIndex).max() ?? -1) + 1, parentID: parent?.id)
        let record = FolderRecord(id: entry.id)
        record.apply(entry)
        context.insert(record)
        saveFolders(since: before)
        return record
    }

    func renameFolder(_ folder: FolderRecord, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let before = folderEntries()
        folder.name = trimmed
        saveIndex()
        writeFolders(since: before)
    }

    func setCloth(_ cloth: ClothColor, for folder: FolderRecord) {
        let before = folderEntries()
        folder.clothRaw = cloth.rawValue
        saveIndex()
        writeFolders(since: before)
    }

    /// Puts a folder inside another, or back at the top level, after the folders already there.
    @discardableResult
    func moveFolder(_ folder: FolderRecord, into parent: FolderRecord?) -> Bool {
        let folders = allFolders()
        guard folder.parentID != parent?.id, FolderTree(folders: folders).canMove(folder.id, into: parent?.id) else { return false }
        let before = folderEntries()
        folder.parentID = parent?.id
        folder.sortIndex = (folders.map(\.sortIndex).max() ?? -1) + 1
        saveFolders(since: before)
        return true
    }

    /// Reorders the sidebar's rows. A folder keeps its parent: it takes the place among its own siblings that the drop gives it.
    func moveFolders(_ rows: [FolderRecord], from source: IndexSet, to destination: Int) {
        let before = folderEntries()
        var ordered = rows
        ordered.move(fromOffsets: source, toOffset: destination)
        let moved = Set(source.map { rows[$0].id })
        var tree = FolderTree(folders: allFolders())
        for group in Set(rows.filter { moved.contains($0.id) }.map { tree.parent(of: $0.id) }) {
            let siblings = ordered.filter { tree.parent(of: $0.id) == group }
            for (index, sibling) in siblings.enumerated() { sibling.sortIndex = index }
            tree = FolderTree(folders: allFolders())
        }
        saveFolders(since: before)
    }

    /// Sorts every level by name.
    func sortFoldersByName(_ folders: [FolderRecord]) {
        let before = folderEntries()
        let tree = FolderTree(folders: folders)
        for group in Set(folders.map { tree.parent(of: $0.id) }) {
            let siblings = folders.filter { tree.parent(of: $0.id) == group }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for (index, sibling) in siblings.enumerated() { sibling.sortIndex = index }
        }
        saveFolders(since: before)
    }

    /// A deleted folder as it was, and what it held, so it can be put back.
    struct DeletedFolder {
        let entry: FolderEntry
        let notebooks: [UUID]
        let folders: [UUID]
    }

    /// Deleting a folder keeps what was in it: its notebooks and its folders move up to the folder it sat in.
    @discardableResult
    func deleteFolder(_ folder: FolderRecord) -> DeletedFolder {
        let folders = allFolders(), before = folderEntries()
        let parent = folders.first { $0.id == folder.parentID }
        let notebooks = folder.notebooks ?? [], children = folders.filter { $0.parentID == folder.id }
        let deleted = DeletedFolder(entry: folder.entry, notebooks: notebooks.map(\.id), folders: children.map(\.id))
        move(notebooks, to: parent)
        for child in children { child.parentID = parent?.id }
        context.delete(folder)
        saveFolders(since: before)
        return deleted
    }

    /// Puts a deleted folder back in its place, under the same ID so a sync takes it as the same folder, with what it held.
    /// One whose parent has gone since goes to the top level, and a folder that can no longer go inside it stays where it is.
    @discardableResult
    func restoreFolder(_ deleted: DeletedFolder) -> FolderRecord? {
        let folders = allFolders(), before = folderEntries()
        guard !folders.contains(where: { $0.id == deleted.entry.id }) else { return nil }
        var entry = deleted.entry
        if !FolderTree(folders: folders).canAddFolder(inside: entry.parentID) { entry.parentID = nil }
        for folder in folders where folder.sortIndex >= entry.sortIndex { folder.sortIndex += 1 }
        let restored = FolderRecord(id: entry.id)
        restored.apply(entry)
        context.insert(restored)
        for id in deleted.folders {
            guard let child = folders.first(where: { $0.id == id }), FolderTree(folders: allFolders()).canMove(id, into: restored.id) else { continue }
            child.parentID = restored.id
        }
        saveFolders(since: before)
        let notebooks = deleted.notebooks.compactMap(record)
        // A notebook saved by a newer version was never moved out: its file still names this folder.
        for notebook in notebooks where notebook.isReadOnly { notebook.folder = restored }
        move(notebooks, to: restored)
        return restored
    }

    /// Writes are chained so they land in order, with a sync's folder pass among them. Each takes only what changed
    /// since `before`, stamped, into the file as it is, so keys this version doesn't know about and folders a sync
    /// brought in survive. A file that is missing or damaged is written afresh from the index.
    private func writeFolders(since before: [FolderEntry]) {
        let after = folderEntries(), now = Date.now
        let root = root, previous = folderWrite
        folderWrite = Task { [weak self] in
            await previous?.value
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do {
                    let loaded: FolderFile?
                    do { loaded = try FolderFile.load(root) } catch is FolderFile.Damaged { loaded = nil }
                    var file = loaded ?? FolderFile(folders: after)
                    file.apply(from: before, to: after, at: now)
                    try file.write(root)
                } catch {
                    return error.localizedDescription
                }
                return nil
            }.value
            if let failure { self?.lastError = String(localized: "Folders couldn't be saved: \(failure)") }
        }
    }

    /// Runs `work` in turn with the folder writes, so neither reads the file while the other is changing it.
    func holdingFolders<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await chain(work, on: &folderWrite).value.get()
    }

    /// Runs `work` once the writes chained on `queue` are done, and chains the next write after it.
    private func chain<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value, on queue: inout Task<Void, Never>?) -> Task<Result<Value, any Error>, Never> {
        let previous = queue
        let turn = Task.detached(priority: .utility) { () -> Result<Value, any Error> in
            await previous?.value
            return Result { try work() }
        }
        queue = Task { _ = await turn.value }
        return turn
    }

    // MARK: Smart shelves

    /// Reads the saved filters. Called at launch, and after a sync or a restore changed the library on disk.
    func loadSmartShelves() async {
        await smartShelfWrite?.value
        let root = root
        smartShelves = await Task.detached(priority: .userInitiated) { SmartShelfFile.read(root).shelves }.value
    }

    /// Replaces the saved filters. Writes are chained so they land in order, with a sync's shelf pass among them, and
    /// each takes only the shelves that changed, stamped, into the file as it is, keeping what this version can't read
    /// and what a sync brought in meanwhile.
    func saveSmartShelves(_ shelves: [SmartShelf]) {
        guard shelves != smartShelves else { return }
        let before = smartShelves, now = Date.now
        smartShelves = shelves
        let root = root, previous = smartShelfWrite
        smartShelfWrite = Task { [weak self] in
            await previous?.value
            let failure = await Task.detached(priority: .utility) { () -> String? in
                var file = SmartShelfFile.read(root)
                file.apply(from: before, to: shelves, at: now)
                do { try file.write(root) } catch { return error.localizedDescription }
                return nil
            }.value
            if let failure { self?.lastError = String(localized: "Smart shelves couldn't be saved: \(failure)") }
            self?.onShelvesSaved?()
        }
    }

    /// Runs `work` in turn with the smart shelf writes, so neither reads the file while the other is changing it.
    func holdingShelves<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await chain(work, on: &smartShelfWrite).value.get()
    }

    /// A tag was renamed or removed across the library: searches are redone now, and a tag shelf lists its pages
    /// again once the closed notebooks' files have caught up.
    func tagsChanged(awaiting writes: [Task<Void, Never>]) {
        searchVersion &+= 1
        saveIndex()
        guard !writes.isEmpty else { return }
        Task {
            for write in writes { await write.value }
            indexVersion &+= 1
        }
    }

    // MARK: Index

    /// Mirrors a manifest just written to disk into the index, saving only when something the library shows changed.
    /// The record keeps the file's date, so a refresh knows it has already read it.
    func index(_ manifest: NotebookManifest) {
        let existing = self.record(manifest.id)
        let record = existing ?? {
            let new = NotebookRecord(id: manifest.id)
            context.insert(new)
            return new
        }()
        let oldTitle = record.title, oldTags = [record.tagsRaw, record.pageTagsRaw]
        var changed = record.apply(manifest, issues: record.issueCount) || existing == nil
        if existing == nil || record.title != oldTitle || [record.tagsRaw, record.pageTagsRaw] != oldTags { searchVersion &+= 1 }
        let folderID = manifest.library.folderID
        if record.folder?.id != folderID {
            record.folder = folderID.flatMap { id in try? context.fetch(FetchDescriptor<FolderRecord>(predicate: #Predicate { $0.id == id })).first }
            changed = true
        }
        let date = LibraryIndex.manifestDate(ofPackage: root.package(manifest.id))
        let redated = record.manifestDate != date
        if redated { record.manifestDate = date }
        if changed {
            saveIndex()
        } else if redated {
            do { try context.save() } catch { log.error("index save failed: \(error.localizedDescription)") }
        }
    }

    /// Recognises handwriting and PDF text for pages whose text is out of date, in the background.
    func indexHandwriting(package: NotebookPackage, pages: [NotebookPage]) {
        let id = package.id
        Task(priority: .utility) { [weak self] in
            let text = await HandwritingIndexer.shared.index(HandwritingIndexer.Job(package: package, pages: pages))
            self?.updateSearchText(text, for: id)
        }
    }

    func updateSearchText(_ text: String, for id: UUID) {
        guard record(id) != nil, LibraryIndex.setSearchText(text, for: id, in: context) else { return }
        searchVersion &+= 1
        onSearchTextChanged?(id)
        saveIndex()
    }

    func searchText(for id: UUID) -> String {
        LibraryIndex.searchRow(for: id, in: context)?.text ?? ""
    }

    // MARK: Daily journal

    /// Which notebook is the journal is marked in its manifest, which every device that syncs goes by; `settleJournal`
    /// keeps this device's own note of it in step. Nil once the journal has been deleted or moved to the bin.
    var dailyJournal: NotebookRecord? {
        guard let id = defaults.string(forKey: SettingsKey.dailyJournalID).flatMap(UUID.init(uuidString:)),
              let journal = record(id), !journal.isTrashed else { return nil }
        return journal
    }

    /// What ⌘T, the Today widget, the Control Center button and Siri open: the journal, started first if there isn't one.
    func journalForToday() async throws -> UUID {
        if let journal = dailyJournal { return journal.id }
        return try await createDailyJournal()
    }

    @discardableResult
    func createDailyJournal(id: UUID = UUID(), now: Date = .now, calendar: Calendar = .current) async throws -> UUID {
        let size = defaults.defaultPageSize
        let paper = PageDefaults(template: NotebookStarter.journal.template, paperColor: NotebookStarter.journal.paperColor, pageSize: size)
        var page = paper.newPage()
        page.day = DailyJournal.dayKey(for: now, calendar: calendar)
        DailyJournal.print(await Agenda.forJournal(now: now, calendar: calendar), on: &page)
        var manifest = NotebookManifest(id: id, title: NotebookStarter.journal.title, createdAt: now,
                                        cover: NotebookStarter.journal.spec(for: id), defaults: paper, pages: [page])
        manifest.library.lastOpenedAt = now
        manifest.library.isJournal = true
        manifest.library.stampChange(.journal, at: now)
        try await assemble(id) { package in
            try await package.create(manifest)
            return manifest
        }
        index(manifest)
        setDailyJournal(id)
        return id
    }

    /// Makes a notebook the daily journal on every device that syncs, or stops using one: the mark goes in its
    /// manifest and comes off any other.
    func setDailyJournal(_ id: UUID?) {
        let others = journalMarks().filter { $0.id != id }
        if !others.isEmpty { changeLibraryState(others, index: { $0.isJournal = false }) { $0.isJournal = false } }
        if let record = id.flatMap(record), !record.isJournal {
            changeLibraryState([record], index: { $0.isJournal = true }) { $0.isJournal = true }
        }
        if let id { defaults.set(id.uuidString, forKey: SettingsKey.dailyJournalID) } else { defaults.removeObject(forKey: SettingsKey.dailyJournalID) }
    }

    private func journalMarks() -> [NotebookRecord] {
        (try? context.fetch(FetchDescriptor<NotebookRecord>(predicate: #Predicate { $0.isJournal == true }))) ?? []
    }

    /// Brings this device's journal into step with the marks a sync or a restore brought in. A device without one takes
    /// the one marked. Where two are marked, as when two devices each started one before they synced, the one begun
    /// first is the journal everywhere and the other stays as an ordinary notebook: nothing is merged or deleted. Returns
    /// this device's own journal when it was the one that gave way; it is renamed if it shares the other's title.
    @discardableResult
    func settleJournal() async -> UUID? {
        let chosenID = defaults.string(forKey: SettingsKey.dailyJournalID).flatMap(UUID.init(uuidString:))
        var givenUp = false
        if let chosenID, let chosen = record(chosenID), !chosen.isJournal, !chosen.isReadOnly {
            let package = root.package(chosenID)
            let filing = await Task.detached(priority: .userInitiated) { LibrarySync.filing(ofPackage: package) }.value
            if let filing, !filing.isJournal, let chosen = record(chosenID), !chosen.isJournal {
                // Never stamped, it was chosen before journals were marked: marked now, so the other devices hear of it.
                // Stamped, the mark was taken off on another device.
                if filing.changedAt(.journal) == nil {
                    changeLibraryState([chosen], index: { $0.isJournal = true }) { $0.isJournal = true }
                } else {
                    givenUp = true
                }
            }
        }
        let chosen = chosenID.flatMap(record)
        let marked = journalMarks()
        guard let journal = marked.filter({ !$0.isTrashed }).min(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) else {
            if givenUp { defaults.removeObject(forKey: SettingsKey.dailyJournalID) }
            return nil
        }
        var setAside: UUID?
        if let chosen, chosen.id != journal.id, chosen.isJournal, !chosen.isTrashed {
            if chosen.title.localizedCaseInsensitiveCompare(journal.title) == .orderedSame {
                rename(chosen, to: String(localized: "\(chosen.title) (started \(chosen.createdAt.formatted(date: .abbreviated, time: .omitted)))"))
            }
            setAside = chosen.id
        }
        let others = marked.filter { $0.id != journal.id }
        if !others.isEmpty { changeLibraryState(others, index: { $0.isJournal = false }) { $0.isJournal = false } }
        if chosenID != journal.id { defaults.set(journal.id.uuidString, forKey: SettingsKey.dailyJournalID) }
        if let setAside { onJournalSetAside?(setAside) }
        return setAside
    }

    /// Nil for read-only notebooks and ones still opening, which then open at their saved page.
    func prepareTodayPage(_ id: UUID, now: Date = .now, calendar: Calendar = .current) async -> UUID? {
        guard let journal = record(id), !journal.isReadOnly else { return nil }
        let key = DailyJournal.dayKey(for: now, calendar: calendar)
        if let document = DocumentRegistry.shared.document(for: id) {
            if let page = document.pages.last(where: { $0.day == key }) { return page.id }
            let agenda = await Agenda.forJournal(now: now, calendar: calendar)
            return DailyJournal.ensureTodayPage(in: document, now: now, calendar: calendar, agenda: agenda)
        }
        guard !DocumentRegistry.shared.isOpening(id) else { return nil }
        let package = NotebookPackage(root: root, id: id), registry = DocumentRegistry.shared
        let pageID = UUID()
        registry.willChange(id)
        defer { registry.didChange(id) }
        // A sync that has the journal in hand finishes first, so the page is added to what it brought in.
        await registry.whenReleased(id)
        do {
            if let page = try await package.readManifest().manifest.pages.last(where: { $0.day == key }) { return page.id }
            // The calendar is only read on a day that has no page yet.
            let agenda = await Agenda.forJournal(now: now, calendar: calendar)
            guard registry.startWriting(id) else { return nil }
            defer { registry.doneWriting(id) }
            let manifest = try await package.updateManifest { DailyJournal.dateToday(key, newPageID: pageID, agenda: agenda, in: &$0) }
            index(manifest)
            return manifest.pages.last { $0.day == key }?.id
        } catch {
            log.error("today's page failed for \(id): \(error.localizedDescription)")
            return nil
        }
    }
}

extension LibraryStore {
    /// Waits for folder and smart shelf changes still being written to disk.
    func finishWritingShelves() async {
        await folderWrite?.value
        await smartShelfWrite?.value
    }

    /// Waits for changes to closed notebooks still being written to their manifests.
    func finishWritingNotebooks() async {
        for write in Array(manifestWrites.values) { await write.value }
    }

    /// Saves what is open, then writes the whole library into one file. Refused while an open notebook can't be saved.
    func makeBackup() async throws -> URL {
        var unsaved: [String] = []
        for document in DocumentRegistry.shared.openDocuments where !(await document.flush()) { unsaved.append(document.title) }
        guard unsaved.isEmpty else { throw LibraryBackup.Failure.unsaved(unsaved) }
        await finishWritingShelves()
        let root = root, journal = dailyJournal?.id, holdsLocked = hasLockedNotebooks
        let url = try await Task.detached(priority: .userInitiated) { try LibraryBackup.create(root: root, journal: journal) }.value
        if holdsLocked || hasLockedNotebooks { backupsHoldingLocked.insert(url) }
        return url
    }

    /// The backup file to hand to the share sheet: `made` if one was already written, or else a new one. It holds
    /// locked notebooks in full, so with any in the library, or in `made` when it was written, this first asks what
    /// opening one would. Nil when refused.
    func backupToShare(_ made: URL? = nil) async throws -> URL? {
        if hasLockedNotebooks || made.map(backupsHoldingLocked.contains) == true {
            guard NotebookLock.shared.isAvailable else { throw LibraryBackup.Failure.needsPasscode }
            guard await NotebookLock.shared.confirm(String(localized: "Back up your library, including locked notebooks")) else { return nil }
        }
        if let made { return made }
        return try await makeBackup()
    }

    /// Notebooks, folders or stickers were changed on disk by something other than this store (a sync): read them again.
    /// The notebooks `report` brought in are read whatever their dates say; any other only if its manifest changed.
    func reloadFromDisk(after report: SyncReport? = nil) async {
        await folderWrite?.value
        // A change still waiting to be written goes in first, or the index would take the file from before it.
        await finishWritingNotebooks()
        let named = report.map { Set($0.pulled + $0.stateReceived + $0.conflictCopies) } ?? []
        await readAgain(rescanning: named)
        await settleJournal()
    }

    /// Brings the index and the smart shelves up to date with the library on disk, and has what shows them look again.
    private func readAgain(rescanning: Set<UUID> = []) async {
        await LibraryIndex.refresh(root: root, context: context, rescanning: rescanning)
        await loadSmartShelves()
        searchVersion &+= 1
        indexVersion &+= 1
    }

    /// Adds a backup's notebooks, folders and stickers to the library, then brings the index up to date.
    func restoreBackup(from url: URL) async throws -> LibraryBackup.Summary {
        await finishWritingShelves()
        let root = root, keepsHistory = defaults.bool(forKey: SettingsKey.keepsWritingHistory, default: true), indexed = folderEntries()
        let summary = try await Task.detached(priority: .userInitiated) {
            try await LibraryBackup.restore(from: url, into: root, keepsHistory: keepsHistory, indexed: indexed)
        }.value
        await readAgain()
        // The library keeps the journal it has, or else takes the backup's, and only that one stays marked.
        if let journal = dailyJournal?.id ?? summary.journal.flatMap({ record($0) == nil ? nil : $0 }) { setDailyJournal(journal) }
        await settleJournal()
        return summary
    }
}

enum PDFImport {
    /// Asked for a locked PDF's password, told whether the last one tried was wrong; nil skips the PDF.
    typealias Password = @MainActor (_ wrong: Bool) async -> String?
    /// How far through one PDF, from 0 to 1.
    typealias Progress = @Sendable (Double) -> Void

    /// One page per PDF page, sized to its displayed crop box. Refuses locked and empty PDFs.
    static func pages(at url: URL, file: String, progress: Progress? = nil) throws -> [NotebookPage] {
        guard let document = CGPDFDocument(url as CFURL) else { throw ImportError.unreadable }
        if isLocked(document) { throw ImportError.locked }
        let count = document.numberOfPages
        let pages = (0..<count).compactMap { index -> NotebookPage? in
            report(index, of: count, to: progress)
            guard let page = document.page(at: index + 1) else { return nil }
            return NotebookPage(background: .pdf(file: file, index: index), paperColor: .white, size: PageRenderer.displaySize(of: page))
        }
        guard !pages.isEmpty else { throw ImportError.empty }
        return pages
    }

    /// The pages of the PDF kept as `file`. A locked one is asked for its password until it opens, then kept without
    /// its lock; skipped, or with no one to ask, it is refused.
    static func pages(in package: NotebookPackage, file: String, password: Password?, progress: Progress?) async throws -> [NotebookPage] {
        let url = package.assetURL(file)
        var unlocked = false
        if try await Task.detached(priority: .userInitiated, operation: { try isLocked(url) }).value {
            guard let password else { throw ImportError.locked }
            var wrong = false
            repeat {
                guard let typed = await password(wrong) else { throw ImportError.locked }
                let opening = part(of: progress, from: 0, to: 0.5)
                wrong = try await Task.detached(priority: .userInitiated) { try !unlock(url, with: typed, progress: opening) }.value
            } while wrong
            unlocked = true
        }
        let reading = part(of: progress, from: unlocked ? 0.5 : 0, to: 1)
        return try await Task.detached(priority: .userInitiated) { try pages(at: url, file: file, progress: reading) }.value
    }

    static func isLocked(_ url: URL) throws -> Bool {
        guard let document = CGPDFDocument(url as CFURL) else { throw ImportError.unreadable }
        return isLocked(document)
    }

    private static func isLocked(_ document: CGPDFDocument) -> Bool {
        document.isEncrypted && !document.isUnlocked && !document.unlockWithPassword("")
    }

    /// Opens a locked PDF with `password` and writes it again in its place with no lock, keeping its outline and links.
    /// False when the password doesn't open it.
    static func unlock(_ url: URL, with password: String, progress: Progress? = nil) throws -> Bool {
        guard let locked = PDFDocument(url: url) else { throw ImportError.unreadable }
        guard locked.unlock(withPassword: password) else { return false }
        // PDFKit writes an unlocked document locked again; a new document of its pages has no lock.
        let open = PDFDocument()
        for index in 0..<locked.pageCount {
            report(index, of: locked.pageCount, to: progress)
            guard let page = locked.page(at: index)?.copy() as? PDFPage else { throw ImportError.unreadable }
            open.insert(page, at: index)
        }
        for index in 0..<open.pageCount {
            guard let page = open.page(at: index), let originals = locked.page(at: index)?.annotations else { continue }
            for (original, copied) in zip(originals, page.annotations) {
                guard let destination = moved(original.destination, from: locked, to: open), let link = copied.copy() as? PDFAnnotation else { continue }
                page.removeAnnotation(copied)
                link.destination = destination
                page.addAnnotation(link)
            }
        }
        open.documentAttributes = locked.documentAttributes
        if let outline = locked.outlineRoot { open.outlineRoot = copy(outline, from: locked, to: open) }
        let written = url.deletingLastPathComponent().appending(path: "\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: written) }
        guard open.write(to: written), let check = CGPDFDocument(written as CFURL), !check.isEncrypted else { throw ImportError.unreadable }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: written)
        return true
    }

    /// The same place in `target`, for a destination in `source`, whose pages it has in the same order.
    private static func moved(_ destination: PDFDestination?, from source: PDFDocument, to target: PDFDocument) -> PDFDestination? {
        guard let destination, let page = destination.page, page.document === source,
              let to = target.page(at: source.index(for: page)) else { return nil }
        let moved = PDFDestination(page: to, at: destination.point)
        moved.zoom = destination.zoom
        return moved
    }

    private static func copy(_ outline: PDFOutline, from source: PDFDocument, to target: PDFDocument) -> PDFOutline {
        let copied = PDFOutline()
        copied.label = outline.label
        copied.isOpen = outline.isOpen
        if let destination = moved(outline.destination, from: source, to: target) {
            copied.destination = destination
        } else if !(outline.action is PDFActionGoTo) {
            copied.action = outline.action
        }
        for index in 0..<outline.numberOfChildren {
            if let child = outline.child(at: index) { copied.insertChild(copy(child, from: source, to: target), at: copied.numberOfChildren) }
        }
        return copied
    }

    /// About a hundred calls over `count` steps, not one a step.
    private static func report(_ index: Int, of count: Int, to progress: Progress?) {
        guard let progress, (index + 1) % max(count / 100, 1) == 0 else { return }
        progress(Double(index + 1) / Double(count))
    }

    private static func part(of progress: Progress?, from start: Double, to end: Double) -> Progress? {
        guard let progress else { return nil }
        return { @Sendable value in progress(start + value * (end - start)) }
    }
}
