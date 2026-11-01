import Foundation
import PencilKit
import CryptoKit

enum PackageError: LocalizedError, Equatable {
    case missing
    case unreadable
    case readOnly

    var errorDescription: String? {
        switch self {
        case .missing: String(localized: "The notebook's files couldn't be found.")
        case .unreadable: String(localized: "The notebook's files couldn't be read.")
        case .readOnly: String(localized: "This notebook was saved by a newer version of OwlLuna and can't be changed here.")
        }
    }
}

enum InkLoad: Sendable {
    case empty
    case ink(PKDrawing, hash: String)
    case quarantined(file: String)
    case cancelled
}

struct ManifestLoad: Sendable {
    var manifest: NotebookManifest
    var warnings: [String] = []
    var quarantined: [String] = []
    var recoveredPageIDs: [UUID] = []
    /// Recordings cut off before Stop that were found on opening and joined the list.
    var adoptedRecordings: [RecordingEntry] = []
    /// True when the loaded manifest differs from what's on disk and should be saved.
    var needsSave = false
    var isReadOnly: Bool { manifest.isNewerThanSupported }
}

struct SaveSnapshot: Sendable {
    var manifest: NotebookManifest
    var ink: [UUID: PKDrawing]
}

struct SaveReceipt: Sendable {
    var manifest: NotebookManifest
    var inkHashes: [UUID: String?]
    var inkBytes: [UUID: Int] = [:]
}

/// All file IO for one `<uuid>.owlluna` package. Ink files are written before the manifest,
/// every write is atomic, and nothing that fails to decode is ever overwritten.
actor NotebookPackage {
    nonisolated let id: UUID
    nonisolated let url: URL
    nonisolated let root: StorageRoot

    init(root: StorageRoot, id: UUID) {
        self.id = id
        self.url = root.package(id)
        self.root = root
    }

    static let manifestFile = "manifest.json"

    nonisolated var manifestURL: URL { url.appending(path: Self.manifestFile) }
    nonisolated var previousManifestURL: URL { url.appending(path: "manifest.prev.json") }
    nonisolated var inkDirectory: URL { url.appending(path: "ink", directoryHint: .isDirectory) }
    nonisolated var assetsDirectory: URL { url.appending(path: "assets", directoryHint: .isDirectory) }
    nonisolated var thumbsDirectory: URL { url.appending(path: "thumbs", directoryHint: .isDirectory) }
    nonisolated var textDirectory: URL { url.appending(path: "text", directoryHint: .isDirectory) }

    nonisolated func inkURL(_ pageID: UUID) -> URL { inkDirectory.appending(path: "\(pageID.uuidString).pkdrawing") }
    nonisolated func assetURL(_ file: String) -> URL { assetsDirectory.appending(path: file) }
    nonisolated func textURL(_ pageID: UUID) -> URL { textDirectory.appending(path: "\(pageID.uuidString).txt") }
    nonisolated func pictureTextURL(_ pageID: UUID) -> URL { textDirectory.appending(path: "\(pageID.uuidString).pictures.json") }
    nonisolated func thumbURL(_ pageID: UUID, key: String) -> URL {
        thumbsDirectory.appending(path: "\(pageID.uuidString)-\(key).png")
    }

    // MARK: Create

    func create(_ manifest: NotebookManifest) throws {
        try makeDirectories()
        guard !FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) else { return }
        try ManifestCodec.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    private func makeDirectories() throws {
        for directory in [url, inkDirectory, assetsDirectory, thumbsDirectory, textDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: Read

    func readManifest() throws -> ManifestLoad {
        var quarantined: [String] = []
        var loaded: (manifest: NotebookManifest, warnings: [String])?
        var source: URL?

        for candidate in [manifestURL, previousManifestURL] {
            guard let data = try? Data(contentsOf: candidate) else { continue }
            do {
                loaded = try ManifestCodec.decode(data, fallbackID: id, fallbackDate: creationDate(of: candidate))
                source = candidate
                break
            } catch {
                let moved = try Quarantine.move(candidate)
                quarantined.append(moved.lastPathComponent)
            }
        }

        var load: ManifestLoad
        if let loaded, let source {
            load = ManifestLoad(manifest: loaded.manifest, warnings: loaded.warnings)
            if source == previousManifestURL {
                load.warnings.append("the latest manifest was unreadable; opened the previous version")
                load.needsSave = true
            }
            load.quarantined = quarantined
            recoverOrphans(into: &load, manifestDate: source.contentModificationDate ?? .distantPast)
        } else if !quarantined.isEmpty || !inkFiles().isEmpty {
            load = ManifestLoad(manifest: rebuiltManifest(), warnings: ["the manifest was missing or unreadable; rebuilt from ink files"])
            load.quarantined = quarantined
            load.needsSave = true
        } else {
            throw quarantined.isEmpty ? PackageError.missing : PackageError.unreadable
        }
        return load
    }

    /// Ink files the manifest doesn't list but that are newer than it were written just before a crash.
    private func recoverOrphans(into load: inout ManifestLoad, manifestDate: Date) {
        var known = Set(load.manifest.pages.map(\.id))
        for opaque in load.manifest.opaquePages {
            if let id = opaque.raw["id"]?.uuidValue { known.insert(id) }
        }
        let orphans = inkFiles().compactMap { file -> (UUID, Date)? in
            guard let pageID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !known.contains(pageID),
                  let date = file.contentModificationDate, date > manifestDate else { return nil }
            return (pageID, date)
        }.sorted { $0.1 < $1.1 }
        guard !orphans.isEmpty else { return }
        for (pageID, _) in orphans {
            var page = load.manifest.defaults.newPage()
            page.id = pageID
            page.inkHash = (try? Data(contentsOf: inkURL(pageID))).map(Self.hash)
            load.manifest.pages.append(page)
            load.recoveredPageIDs.append(pageID)
        }
        load.warnings.append("recovered \(orphans.count) page(s) written just before the app last quit")
        load.needsSave = true
    }

    private func inkFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inkDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "pkdrawing" }
    }

    private func rebuiltManifest() -> NotebookManifest {
        let pages = inkFiles()
            .compactMap { file -> (UUID, Date)? in
                UUID(uuidString: file.deletingPathExtension().lastPathComponent).map { ($0, file.contentModificationDate ?? .distantPast) }
            }
            .sorted { $0.1 < $1.1 }
            .map { pageID, _ -> NotebookPage in
                var page = NotebookPage.template(.blank, color: .white, size: .letter)
                page.id = pageID
                page.inkHash = (try? Data(contentsOf: inkURL(pageID))).map(Self.hash)
                return page
            }
        var manifest = NotebookManifest(id: id, title: "Recovered Notebook",
                                        defaults: PageDefaults(template: .blank, paperColor: .white, pageSize: .letter),
                                        pages: pages.isEmpty ? [.template(.blank, color: .white, size: .letter)] : pages)
        manifest.createdAt = creationDate(of: url)
        manifest.extra[Self.rebuiltKey] = .bool(true)
        return manifest
    }

    /// Marks a manifest rebuilt from ink alone, whose assets may still be listed only in a quarantined copy.
    static let rebuiltKey = "rebuiltFromInk"

    /// Reads and decodes off the actor, so page loads run in parallel at their task's priority instead of
    /// queueing behind each other and behind saves. Only setting a damaged file aside goes through the actor.
    nonisolated func readInk(_ pageID: UUID) async -> InkLoad {
        if Task.isCancelled { return .cancelled }
        guard let data = try? Data(contentsOf: inkURL(pageID)) else { return .empty }
        if let drawing = try? Self.decodeInk(data) { return .ink(drawing, hash: Self.hash(data)) }
        return await quarantineInk(pageID)
    }

    private func quarantineInk(_ pageID: UUID) -> InkLoad {
        let file = inkURL(pageID)
        guard let data = try? Data(contentsOf: file) else { return .empty }
        if let drawing = try? Self.decodeInk(data) { return .ink(drawing, hash: Self.hash(data)) }
        guard let moved = try? Quarantine.move(file) else { return .quarantined(file: file.lastPathComponent) }
        return .quarantined(file: "ink/\(moved.lastPathComponent)")
    }

    func readText(_ pageID: UUID) -> String? {
        try? String(contentsOf: textURL(pageID), encoding: .utf8)
    }

    /// What each picture placed on a page showed when it was read, by `PageItem.readingKey`.
    func readPictureText(_ pageID: UUID) -> [String: [String]] {
        Self.pictureText(at: pictureTextURL(pageID))
    }

    /// The same, read from the file off the actor.
    static func pictureText(at url: URL) -> [String: [String]] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    // MARK: Write

    /// Writes the given pages' ink, each atomically, then the manifest last. Throws on the first failure;
    /// callers keep those pages dirty and retry.
    func write(_ snapshot: SaveSnapshot) throws -> SaveReceipt {
        guard !snapshot.manifest.isNewerThanSupported else { throw PackageError.readOnly }
        try makeDirectories()
        var manifest = snapshot.manifest
        var hashes: [UUID: String?] = [:]
        var bytes: [UUID: Int] = [:]
        for (pageID, drawing) in snapshot.ink {
            let file = inkURL(pageID)
            if drawing.strokes.isEmpty {
                if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: file)
                }
                hashes[pageID] = .some(nil)
            } else {
                let data = drawing.dataRepresentation()
                try data.write(to: file, options: .atomic)
                hashes[pageID] = Self.hash(data)
                bytes[pageID] = data.count
            }
        }
        for index in manifest.pages.indices {
            if let hash = hashes[manifest.pages[index].id] { manifest.pages[index].inkHash = hash }
        }
        manifest = try writeManifest(manifest)
        return SaveReceipt(manifest: manifest, inkHashes: hashes, inkBytes: bytes)
    }

    /// Filing the file has stamped later than `manifest` is kept, so a manifest read before a library change was
    /// written never undoes it. Returns what was written.
    @discardableResult
    func writeManifest(_ manifest: NotebookManifest) throws -> NotebookManifest {
        var manifest = manifest
        if let filed = LibrarySync.filing(ofPackage: url) { manifest.library.takeLaterChanges(from: filed) }
        try replaceManifest(with: manifest)
        return manifest
    }

    private func replaceManifest(with manifest: NotebookManifest) throws {
        guard !manifest.isNewerThanSupported else { throw PackageError.readOnly }
        try makeDirectories()
        let data = try ManifestCodec.encode(manifest)
        if FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) { backUpManifest() }
        try data.write(to: manifestURL, options: .atomic)
    }

    /// Keeps the manifest as it is in `manifest.prev.json`, which a damaged one is read from instead.
    private func backUpManifest() {
        try? FileManager.default.removeItem(at: previousManifestURL)
        try? FileManager.default.copyItem(at: manifestURL, to: previousManifestURL)
    }

    /// Read-modify-write of the manifest for library changes to a notebook that isn't open.
    func updateManifest(_ change: @Sendable (inout NotebookManifest) -> Void) throws -> NotebookManifest {
        var manifest = try readManifest().manifest
        change(&manifest)
        try replaceManifest(with: manifest)
        return manifest
    }

    /// Rewrites how the notebook is filed and leaves every other key as it was, so a manifest saved by a newer
    /// version can go in and out of Recently Deleted without this one writing what it can't read.
    func updateLibraryState(_ change: @Sendable (inout LibraryState) -> Void) throws -> NotebookManifest {
        let data: Data
        do { data = try Data(contentsOf: manifestURL) } catch { throw PackageError.missing }
        guard var object = (try? JSONValue.parse(data))?.objectValue else { throw PackageError.unreadable }
        let raw = object["library"] ?? .null
        guard raw == .null || raw.objectValue != nil else { throw PackageError.readOnly }
        var state = ManifestCodec.decodeLibrary(raw.objectValue ?? [:])
        change(&state)
        object["library"] = ManifestCodec.encodeLibrary(state)
        let written = try JSONValue.object(object).serialized()
        backUpManifest()
        try written.write(to: manifestURL, options: .atomic)
        return try ManifestCodec.decode(written, fallbackID: id).manifest
    }

    func writeText(_ text: String, pageID: UUID) throws {
        try makeDirectoryInExistingPackage(textDirectory)
        try Data(text.utf8).write(to: textURL(pageID), options: .atomic)
    }

    func writePictureText(_ lines: [String: [String]], pageID: UUID) throws {
        try makeDirectoryInExistingPackage(textDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(lines).write(to: pictureTextURL(pageID), options: .atomic)
    }

    func writeThumbnail(_ png: Data, pageID: UUID, key: String) throws {
        try makeDirectoryInExistingPackage(thumbsDirectory)
        try png.write(to: thumbURL(pageID, key: key), options: .atomic)
    }

    /// Background jobs (OCR, thumbnails) must never bring back a package that was deleted while they ran.
    private func makeDirectoryInExistingPackage(_ directory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: manifestURL.path(percentEncoded: false)) else { throw PackageError.missing }
        guard !fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    // MARK: Assets

    func importAsset(from source: URL, ext: String) throws -> String {
        try makeDirectories()
        let name = "\(UUID().uuidString).\(ext)"
        let destination = assetURL(name)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        // File providers may need to download or finish writing the selection before it can be copied.
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { granted in
            do { try FileManager.default.copyItem(at: granted, to: destination) }
            catch { copyError = error }
        }
        if let error = (coordinationError as Error?) ?? copyError {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return name
    }

    func writeAsset(_ data: Data, ext: String) throws -> String {
        try makeDirectories()
        let name = "\(UUID().uuidString).\(ext)"
        try data.write(to: assetURL(name), options: .atomic)
        return name
    }

    // MARK: Transcripts

    nonisolated func transcriptTextURL(_ recordingID: UUID) -> URL { textDirectory.appending(path: "\(recordingID.uuidString).txt") }

    /// A transcript is kept with the assets under a name the recording's entry holds; its words are also kept as
    /// plain text beside the pages' recognised text, so search finds them.
    func writeTranscript(_ transcript: Transcript, recordingID: UUID) throws -> String {
        let file = try writeAsset(JSONEncoder().encode(transcript), ext: "json")
        try writeTranscriptText(transcript, recordingID: recordingID)
        return file
    }

    /// Puts a recording's words back into search from the transcript its entry names, for a recording that comes back.
    func restoreTranscriptText(_ recordingID: UUID, from file: String) throws {
        guard let transcript = readTranscript(file) else { return }
        try writeTranscriptText(transcript, recordingID: recordingID)
    }

    private func writeTranscriptText(_ transcript: Transcript, recordingID: UUID) throws {
        try makeDirectoryInExistingPackage(textDirectory)
        try Data(transcript.text.utf8).write(to: transcriptTextURL(recordingID), options: .atomic)
    }

    nonisolated func readTranscript(_ file: String) -> Transcript? {
        (try? Data(contentsOf: assetURL(file))).flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
    }

    func removeTranscriptText(_ recordingID: UUID) {
        try? FileManager.default.removeItem(at: transcriptTextURL(recordingID))
    }

    // MARK: Recordings

    /// The entry timed from its finished audio, or nil and the file removed when nothing playable was written, unless `keepingUnreadable` and something was.
    @concurrent
    nonisolated func finishRecording(_ entry: RecordingEntry, keepingUnreadable: Bool = false) async -> RecordingEntry? {
        let url = assetURL(entry.file)
        var finished = entry
        finished.device = nil
        if let done = RecordingFile.finish(url) {
            finished.file = done.url.lastPathComponent
            finished.duration = done.duration
            return finished
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if keepingUnreadable, size > 0 { return finished }
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    /// This device's cut-off recordings join the list, dated so the change syncs; another device's are left alone, as it may still be recording.
    @concurrent
    nonisolated func adoptUnfinishedRecordings(_ load: ManifestLoad) async -> ManifestLoad {
        guard !load.manifest.unfinishedRecordings.isEmpty, !load.isReadOnly else { return load }
        let device = root.deviceID
        let (mine, others) = (load.manifest.unfinishedRecordings.filter { $0.device == device }, load.manifest.unfinishedRecordings.filter { $0.device != device })
        guard !mine.isEmpty else { return load }
        var load = load
        for entry in mine {
            guard var adopted = await finishRecording(entry) else { continue }
            adopted.createdAt = adopted.startedAt.addingTimeInterval(adopted.duration)
            load.manifest.recordings.append(adopted)
            load.adoptedRecordings.append(adopted)
        }
        load.manifest.unfinishedRecordings = others
        load.manifest.modifiedAt = .now
        load.needsSave = true
        return load
    }

    // MARK: Maintenance

    /// Runs `work` with nothing written to the package meanwhile, as a sync copies an open notebook.
    func hold<T: Sendable>(_ work: @Sendable () throws -> T) throws -> T { try work() }

    /// Removes ink, text, thumbnails and assets that the saved manifest no longer references.
    /// Only call once the manifest is on disk and no undo history can bring those pages back.
    /// Nothing but stale thumbnails is removed while a damaged manifest is set aside or the manifest was
    /// rebuilt, since the files may be all that's left of what the damaged copy listed.
    func collectGarbage(keeping manifest: NotebookManifest) {
        let fileManager = FileManager.default
        let currentThumbs = Set(manifest.pages.flatMap { page in
            [page.thumbnailKey, page.thumbnailKey + PageThumbnailer.nightSuffix].map { thumbURL(page.id, key: $0).lastPathComponent }
        })
        for file in (try? fileManager.contentsOfDirectory(at: thumbsDirectory, includingPropertiesForKeys: nil)) ?? []
        where !currentThumbs.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
        guard manifest.extra[Self.rebuiltKey] == nil, !hasQuarantinedManifest() else { return }

        let manifestDate = manifestURL.contentModificationDate ?? .distantPast
        var keep = Set(manifest.pages.map(\.id.uuidString))
        for opaque in manifest.opaquePages { if let id = opaque.raw["id"]?.stringValue { keep.insert(id.uppercased()) } }
        for recording in manifest.recordings where recording.transcriptFile != nil { keep.insert(recording.id.uuidString) }
        for directory in [inkDirectory, textDirectory] {
            for file in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                guard !file.lastPathComponent.contains(".corrupt") else { continue }
                let pageID = String(file.deletingPathExtension().lastPathComponent.prefix(36)).uppercased()
                guard UUID(uuidString: pageID) != nil, !keep.contains(pageID),
                      (file.contentModificationDate ?? .distantFuture) <= manifestDate else { continue }
                try? fileManager.removeItem(at: file)
            }
        }
        let referenced = Self.strings(in: ManifestCodec.encodeValue(manifest))
        for file in (try? fileManager.contentsOfDirectory(at: assetsDirectory, includingPropertiesForKeys: nil)) ?? [] {
            let name = file.lastPathComponent
            guard !referenced.contains(name), !referenced.contains("assets/\(name)"),
                  (file.contentModificationDate ?? .distantFuture) <= manifestDate else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    private func hasQuarantinedManifest() -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        return files.contains { $0.hasPrefix("manifest") && $0.contains(".corrupt") }
    }

    /// Every string anywhere in the manifest, so an asset named by a field this version can't read is still kept.
    private static func strings(in value: JSONValue) -> Set<String> {
        switch value {
        case .string(let string): [string]
        case .array(let values): values.reduce(into: []) { $0.formUnion(strings(in: $1)) }
        case .object(let object): object.values.reduce(into: []) { $0.formUnion(strings(in: $1)) }
        case .null, .bool, .number: []
        }
    }

    func quarantinedFiles() -> [String] {
        let fileManager = FileManager.default
        return [url, inkDirectory].flatMap { directory in
            ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.contains(".corrupt") }
                .map { $0.path(percentEncoded: false).replacingOccurrences(of: url.path(percentEncoded: false), with: "") }
        }
    }

    // MARK: Helpers

    /// PencilKit decodes data without its format header as an empty drawing instead of failing, so an
    /// empty result only counts when the header is there and the file is small enough to be an empty drawing.
    static func decodeInk(_ data: Data) throws -> PKDrawing {
        let drawing = try PKDrawing(data: data)
        if drawing.strokes.isEmpty, !data.starts(with: [0x77, 0x72, 0x64]) || data.count > 1024 {
            throw CocoaError(.fileReadCorruptFile)
        }
        return drawing
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).hex
    }

    private nonisolated func creationDate(of file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
    }
}

extension Sequence<UInt8> {
    /// The bytes in lowercase hex, two digits each.
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
