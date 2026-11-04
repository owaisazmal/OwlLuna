import Foundation
import AppleArchive
import System
import UniformTypeIdentifiers
import os

extension UTType {
    static let owlLunaBackup = UTType(exportedAs: "com.owais.owlluna.backup")
    static let legacyBackup = UTType(importedAs: "com.owais.swiftscribe.backup")
}

/// The whole library as one file: every notebook package, the folders, the smart shelves, the writing history and
/// your own stickers and paper, in an Apple Archive. Thumbnails are left out; they are made again when needed.
enum LibraryBackup {
    static let fileExtension = "owllunabackup"
    /// Files providers can report a backup as generic data, including after it was saved by this app.
    /// Let it be selected; restore checks the archive and backup.json before adding anything to the library.
    static let importContentTypes: [UTType] = [.owlLunaBackup, .legacyBackup, .appleArchive, .data]
    static let infoFile = "backup.json"
    static let currentVersion = 1

    struct Summary: Sendable, Equatable {
        /// Notebooks the library didn't have.
        var added = 0
        /// Of those, the ones the backup had in Recently Deleted. They go back there for as long again.
        var trashed = 0
        /// Notebooks the library has in a different state, brought back beside it under a new name.
        var copies = 0
        /// Notebooks the library already has exactly as they are in the backup.
        var unchanged = 0
        /// Notebooks the library has with the same pages, which took cards, answers or deletions from the backup.
        var cardsMerged = 0
        var unreadable = 0
        var folders = 0
        var stickers = 0
        var papers = 0
        var smartShelves = 0
        /// The notebook the backup's library used as its daily journal, if it was restored under its own ID.
        var journal: UUID?

        var isEmpty: Bool { added + copies + cardsMerged + folders + stickers + papers + smartShelves == 0 }
    }

    enum Failure: LocalizedError, Equatable {
        case notABackup, newer, archive, needsPasscode, noRoom, unreadable, unverified
        /// The titles of open notebooks whose latest changes couldn't be saved.
        case unsaved([String])

        var errorDescription: String? {
            switch self {
            case .notABackup: String(localized: "This file isn't an OwlLuna backup.")
            case .newer: String(localized: "This backup was made by a newer version of OwlLuna. Update the app, then restore it.")
            case .archive: String(localized: "The backup couldn't be written.")
            case .needsPasscode: String(localized: "This library has locked notebooks. To back them up, set a passcode on this iPad in Settings first.")
            case .noRoom: String(localized: "There isn't enough free space on this iPad. Free some up in Settings › General › iPad Storage, then try again.")
            case .unreadable: String(localized: "This backup couldn't be read. It may be damaged or not fully downloaded yet.")
            case .unverified: String(localized: "The finished backup didn't match your library when it was checked, so it wasn't kept. Try again.")
            case .unsaved(let titles):
                String(localized: "Your latest changes to \(Self.quoted(titles)) couldn't be saved, so the backup would be missing them. Try again once they're saved.")
            }
        }

        private static func quoted(_ titles: [String]) -> String {
            titles.map { String(localized: "“\($0)”") }.formatted(.list(type: .and))
        }

        /// `.noRoom` for an error that comes down to a full disk, or else the error as it is.
        static func explaining(_ error: Error) -> Error {
            (error as NSError).isOutOfSpace ? Failure.noRoom : error
        }
    }


    static func fileName(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "OwlLuna Backup \(formatter.string(from: now)).\(fileExtension)"
    }

    /// Writes a backup to a temporary file, reads it back, and returns it. Open notebooks should be saved first.
    static func create(root: StorageRoot, journal: UUID? = nil, now: Date = .now,
                       through disk: (ArchiveByteStream) -> ArchiveByteStream? = { $0 }) throws -> URL {
        do {
            return try write(root: root, journal: journal, now: now, through: disk)
        } catch is ArchiveError {
            throw Failure.archive
        } catch {
            throw Failure.explaining(error)
        }
    }

    private static func write(root: StorageRoot, journal: UUID?, now: Date, through disk: (ArchiveByteStream) -> ArchiveByteStream?) throws -> URL {
        let fileManager = FileManager.default
        return try ExportFolder.make(.backup) { directory in
            let staging = directory.appending(path: "info", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let ids = Set(root.packageIDs())
            var info: [String: JSONValue] = ["version": .number(Double(currentVersion)), "createdAt": ManifestCodec.encodeDate(now),
                                             "notebooks": .number(Double(ids.count))]
            if let journal { info["journal"] = .string(journal.uuidString) }
            try JSONValue.object(info).serialized().write(to: staging.appending(path: infoFile))

            let destination = directory.appending(path: fileName(now: now))
            // Encoder first, file last. Any still open are closed on the way out.
            var streams: [() throws -> Void] = []
            defer { for close in streams { try? close() } }
            guard let keys = ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD,MTM"),
                  let file = ArchiveByteStream.fileStream(path: FilePath(destination.path(percentEncoded: false)), mode: .writeOnly, options: [.create, .truncate],
                                                          permissions: FilePermissions(rawValue: 0o644)).flatMap(disk) else { throw Failure.archive }
            streams.insert(file.close, at: 0)
            guard let compress = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file) else { throw Failure.archive }
            streams.insert(compress.close, at: 0)
            guard let encode = ArchiveStream.encodeStream(writingTo: compress) else { throw Failure.archive }
            streams.insert(encode.close, at: 0)

            // Thumbnails are a cache, and a half-deleted notebook isn't part of the library.
            let filter: ArchiveHeader.EntryFilter = { message, path, _ in
                guard message == .searchPruneDirectory || message == .searchExclude else { return .ok }
                return path.lastComponent?.string == "thumbs" ? .skip : .ok
            }
            try encode.writeDirectoryContents(archiveFrom: FilePath(staging.path(percentEncoded: false)), keySet: keys)
            for folder in [root.library, root.stickers, root.papers] where fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
                try encode.writeDirectoryContents(archiveFrom: FilePath(folder.deletingLastPathComponent().path(percentEncoded: false)),
                                                  path: FilePath(folder.lastPathComponent), keySet: keys, selectUsing: filter)
            }
            // The last compressed block is written as the streams close.
            while !streams.isEmpty { try streams.removeFirst()() }
            guard (try? notebooks(in: destination)) == ids else { throw Failure.unverified }
            return destination
        }
    }

    /// Opens a backup and hands `work` its decoder; the streams close after it, last opened first.
    private static func reading<T>(_ archive: URL, unopened: Failure, undecodable: Failure, _ work: (ArchiveStream) throws -> T) throws -> T {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path(percentEncoded: false)), mode: .readOnly, options: [],
                                                      permissions: FilePermissions(rawValue: 0o644)) else { throw unopened }
        defer { try? file.close() }
        guard let decompress = ArchiveByteStream.decompressionStream(readingFrom: file) else { throw undecodable }
        defer { try? decompress.close() }
        guard let decode = ArchiveStream.decodeStream(readingFrom: decompress) else { throw undecodable }
        defer { try? decode.close() }
        return try work(decode)
    }

    /// The notebooks a finished backup holds, read through to its end.
    private static func notebooks(in archive: URL) throws -> Set<UUID> {
        try reading(archive, unopened: .unverified, undecodable: .unverified) { decode in
            let census = Census()
            guard let sink = ArchiveStream.customStream(instance: census) else { throw Failure.unverified }
            defer { try? sink.close() }
            _ = try ArchiveStream.process(readingFrom: decode, writingTo: sink)
            return census.notebooks
        }
    }

    private static func extract(_ archive: URL, to directory: URL) throws {
        try reading(archive, unopened: .unreadable, undecodable: .notABackup) { decode in
            // A file that can't be written, on a full disk or otherwise, is only reported here, from another thread.
            let failed = OSAllocatedUnfairLock<Int32?>(initialState: nil)
            let inside: ArchiveHeader.EntryFilter = { message, path, _ in
                if message == .extractFail {
                    let code = errno
                    failed.withLock { $0 = $0 ?? code }
                    return .cancel
                }
                // Nothing is written outside the folder the backup is unpacked into.
                return path.isAbsolute || path.components.contains { $0.string == ".." } ? .skip : .ok
            }
            guard let extract = ArchiveStream.extractStream(extractingTo: FilePath(directory.path(percentEncoded: false)), selectUsing: inside,
                                                            flags: [.ignoreOperationNotPermitted]) else { throw CocoaError(.fileWriteUnknown) }
            var finished = true
            do { _ = try ArchiveStream.process(readingFrom: decode, writingTo: extract) } catch { finished = false }
            do { try extract.close() } catch { finished = false }
            if let code = failed.withLock({ $0 }) { throw code == ENOSPC ? Failure.noRoom : Failure.unreadable }
            // Every backup starts with the compressed stream's mark; one that does and then can't be read is damaged, or not all there.
            guard finished else {
                let start = try? FileHandle(forReadingFrom: archive).read(upToCount: 3)
                throw start == Data("pbz".utf8) ? Failure.unreadable : Failure.notABackup
            }
            let links = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])?
                .compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true } ?? []
            for link in links { try? FileManager.default.removeItem(at: link) }
        }
    }

    /// Adds what the backup holds to the library and never replaces anything: a notebook the library has in a different
    /// state comes back beside it as a copy. `indexed` are the folders the index has, which stand in for a folder list
    /// here that can't be read. The caller refreshes the index afterwards.
    static func restore(from archive: URL, into root: StorageRoot, keepsHistory: Bool = true, now: Date = .now, indexed: [FolderEntry] = [],
                        beforeRewrite: @Sendable (NotebookPackage) async throws -> Void = { _ in }) async throws -> Summary {
        do {
            return try await restoring(from: archive, into: root, keepsHistory: keepsHistory, now: now, indexed: indexed, beforeRewrite: beforeRewrite)
        } catch {
            throw Failure.explaining(error)
        }
    }

    private static func restoring(from archive: URL, into root: StorageRoot, keepsHistory: Bool, now: Date, indexed: [FolderEntry],
                                  beforeRewrite: @Sendable (NotebookPackage) async throws -> Void) async throws -> Summary {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(path: "restore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        try extract(archive, to: directory)

        let info = (try? Data(contentsOf: directory.appending(path: infoFile))).flatMap { try? JSONValue.parse($0) }
        guard let version = info?["version"]?.doubleValue else { throw Failure.notABackup }
        guard Int(version) <= currentVersion else { throw Failure.newer }
        let backup = StorageRoot(url: directory)
        backup.adoptLegacyPackages()
        var summary = Summary()
        try fileManager.createDirectory(at: root.library, withIntermediateDirectories: true)

        var renamed: [UUID: UUID] = [:]
        for id in backup.packageIDs().sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let incoming = try? await NotebookPackage(root: backup, id: id).readManifest().manifest else {
                summary.unreadable += 1
                continue
            }
            let source = backup.package(id)
            let exists = fileManager.fileExists(atPath: root.package(id).path(percentEncoded: false))
            if !exists {
                if incoming.library.deletedAt != nil {
                    // Its days start again. The old stamp stays, so a restore or delete made since on another device still wins.
                    try await LibraryStore.assemble(id, in: root) { package in
                        try FileManager.default.moveItem(at: source, to: package.url)
                        try await beforeRewrite(package)
                        return try await package.updateManifest { $0.library.deletedAt = now }
                    }
                    summary.trashed += 1
                } else {
                    try fileManager.moveItem(at: source, to: root.package(id))
                }
                summary.added += 1
                continue
            }
            let current = try? await NotebookPackage(root: root, id: id).readManifest().manifest
            if let current, current.modifiedAt == incoming.modifiedAt, current.pages.map(\.id) == incoming.pages.map(\.id) {
                if try addCards(from: source, to: root.package(id)) { summary.cardsMerged += 1 } else { summary.unchanged += 1 }
                continue
            }
            let copy = UUID()
            let title = String(localized: "\(incoming.title) (from backup)")
            try await LibraryStore.assemble(copy, in: root) { package in
                try FileManager.default.moveItem(at: source, to: package.url)
                try await beforeRewrite(package)
                let manifest = try await package.updateManifest { manifest in
                    manifest.id = copy
                    manifest.title = title
                    manifest.library.deletedAt = nil
                    manifest.library.isJournal = false
                }
                try CardFiles.renew(in: package.url)
                return manifest
            }
            renamed[id] = copy
            summary.copies += 1
        }

        // A list that can't be read is taken as the index's: the backup's folders alone would have sync delete the rest everywhere.
        var folders: FolderFile
        do { folders = try FolderFile.load(root) ?? FolderFile() } catch { folders = FolderFile(folders: indexed) }
        let known = Set(folders.folders.map(\.id))
        let incoming = FolderFile.read(backup).folders.filter { !known.contains($0.id) }
        if !incoming.isEmpty {
            let offset = (folders.folders.map(\.sortIndex).max() ?? -1) + 1
            folders.folders += incoming.map { entry in
                var entry = entry
                entry.sortIndex += offset
                return entry
            }
            try folders.write(root)
            summary.folders = incoming.count
        }

        var shelves = SmartShelfFile.read(root)
        let saved = Set(shelves.shelves.map(\.id))
        let filters = SmartShelfFile.read(backup).shelves.filter { !saved.contains($0.id) }
        if !filters.isEmpty {
            shelves.shelves += filters
            try shelves.write(root)
            summary.smartShelves = filters.count
        }

        summary.stickers = try addFiles(from: backup.stickers, to: root.stickers)
        summary.papers = try addFiles(from: backup.papers, to: root.papers) { PaperShelf.paper(at: $0) != nil }

        if keepsHistory {
            var log = ActivityFile.read(root)
            let old = ActivityFile.read(backup)
            if !log.isNewerThanSupported, !old.isNewerThanSupported, old.hasPages {
                log.merge(old)
                try? ActivityFile.write(log, to: root)
            }
        }

        if let journal = info?["journal"]?.uuidValue, renamed[journal] == nil,
           fileManager.fileExists(atPath: root.package(journal).path(percentEncoded: false)) {
            summary.journal = journal
        }
        return summary
    }
}

extension LibraryBackup {
    /// Moves each file in `source` that `accepts` takes and `target` lacks into `target`, and returns how many it moved.
    fileprivate static func addFiles(from source: URL, to target: URL, accepting accepts: (URL) -> Bool = { _ in true }) throws -> Int {
        let fileManager = FileManager.default
        var added = 0
        for file in (try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] where accepts(file) {
            let destination = target.appending(path: file.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else { continue }
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try fileManager.moveItem(at: file, to: destination)
            added += 1
        }
        return added
    }

    /// The backup's cards go into the library's notebook card by card, as a sync would bring them, with their
    /// clippings. Returns whether the library's cards changed.
    fileprivate static func addCards(from backup: URL, to package: URL) throws -> Bool {
        let fileManager = FileManager.default
        let incoming = CardFiles.read(backup), current = CardFiles.read(package)
        guard !incoming.isReadOnly, !current.isReadOnly else { return false }
        let merged = current.merged(with: incoming)
        guard merged != current else { return false }
        for name in merged.clippings {
            let source = CardFiles.imageURL(name, in: backup), target = CardFiles.imageURL(name, in: package)
            guard !fileManager.fileExists(atPath: target.path(percentEncoded: false)), fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            try fileManager.createDirectory(at: CardFiles.directory(in: package), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: target)
        }
        try CardFiles.write(merged, to: package)
        return true
    }
}

/// Notes which notebooks a backup holds as it is read back, and lets everything else go by.
private final class Census: ArchiveStreamProtocol {
    private(set) var notebooks: Set<UUID> = []

    func writeHeader(_ header: ArchiveHeader) throws {
        guard case .string(_, let path) = header.field(forKey: ArchiveHeader.FieldKey("PAT")) else { return }
        let parts = FilePath(path).components
        guard parts.first?.string == "Library", let package = parts.dropFirst().first, package.extension == StorageRoot.packageExtension,
              let id = UUID(uuidString: package.stem) else { return }
        notebooks.insert(id)
    }

    func writeBlob(key: ArchiveHeader.FieldKey, from buffer: UnsafeRawBufferPointer) throws {}
    func readHeader() throws -> ArchiveHeader? { nil }
    func readBlob(key: ArchiveHeader.FieldKey, into buffer: UnsafeMutableRawBufferPointer) throws { throw ArchiveError.invalidValue }
    func cancel() {}
    func close() throws {}
}

extension LibraryBackup.Summary {
    /// "Restored 12 notebooks. 3 came back as copies because the library has newer versions."
    var message: String {
        var parts: [String] = []
        if added > 0 { parts.append(String(localized: "Restored \(added) notebooks.")) }
        if trashed > 0 {
            parts.append(String(localized: "\(trashed) notebooks were in Recently Deleted in the backup, and are back there for another \(TrashLength.current().days) days."))
        }
        if copies > 0 { parts.append(String(localized: "\(copies) notebooks differ from the ones in your library, so they came back beside them as copies.")) }
        if unchanged > 0 { parts.append(String(localized: "\(unchanged) notebooks were already here.")) }
        if cardsMerged > 0 { parts.append(String(localized: "\(cardsMerged) notebooks were already here, and took in flashcards and reviews from the backup.")) }
        if folders > 0 { parts.append(String(localized: "\(folders) folders were added.")) }
        if stickers > 0 { parts.append(String(localized: "\(stickers) stickers were added.")) }
        if papers > 0 { parts.append(String(localized: "\(papers) papers were added.")) }
        if smartShelves > 0 { parts.append(String(localized: "\(smartShelves) smart shelves were added.")) }
        if unreadable > 0 { parts.append(String(localized: "\(unreadable) notebooks in the backup couldn't be read and were left out.")) }
        return parts.isEmpty ? String(localized: "The backup had nothing in it.") : parts.joined(separator: " ")
    }
}
