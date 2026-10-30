import Foundation
import PencilKit
import Observation
import os

/// Tells the canvas layer when the model replaced a page's ink (undo, redo, duplicate), so a live canvas can show it.
@MainActor
protocol InkObserver: AnyObject {
    func document(_ document: NotebookDocument, didReplaceInkOf pageID: UUID)
}

struct DocumentNotice: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case quarantined, recovered, readOnly, unreadablePages, saveFailed, newerVersion, keptCopy, recordingStopped, onlyPencilDraws, twoFingersScroll }
    let id = UUID()
    let kind: Kind
    let message: String
}

enum SaveState: Equatable, Sendable {
    case saved
    case pending
    case saving
    case failed(String, retryIn: Duration)
}

@MainActor
@Observable
final class NotebookDocument {
    let id: UUID
    let package: NotebookPackage
    private(set) var manifest: NotebookManifest
    private(set) var saveState: SaveState = .saved
    private(set) var notices: [DocumentNotice] = []
    private(set) var damagedPages: Set<UUID> = []
    let isReadOnly: Bool
    /// A sync swapped newer files in under it: it writes nothing more, and its editor opens the notebook again.
    private(set) var isSetAside = false

    @ObservationIgnored let undoManager = DocumentUndoManager()
    @ObservationIgnored private var heaviestEditedPage = 0
    @ObservationIgnored weak var inkObserver: InkObserver?
    /// The editor's recorder, so closing a window can stop a recording before the last save.
    @ObservationIgnored weak var recorder: NotebookRecorder?
    /// Called after any change to the page list or a page's appearance, including undo and redo.
    @ObservationIgnored var onStructureChange: (() -> Void)?
    /// Called after a save that changed what the library shows while the notebook is open (title, pages,
    /// cover, favourite, trash, folder, tags). Ink-only saves skip it; closing the editor indexes everything.
    @ObservationIgnored var onSaved: ((NotebookManifest) -> Void)?
    /// Called after a save that wrote ink, with the pages left holding ink and when they were written.
    @ObservationIgnored var onInkSaved: (([UUID], Date) -> Void)?
    /// Called after every save that wrote something, so a sync can send the notebook while it is open.
    @ObservationIgnored var onWritten: (() -> Void)?
    @ObservationIgnored var retryBase: Duration = .seconds(1)
    @ObservationIgnored var saveDelay: Duration = .seconds(1.2)
    /// However often edits push the debounce back, a pending save starts within this long.
    @ObservationIgnored var maxSaveLatency: Duration = .seconds(5)

    @ObservationIgnored private var inks: [UUID: Ink] = [:]
    @ObservationIgnored private var loading: [UUID: Load] = [:]
    @ObservationIgnored private var recentlyUsed: [UUID] = []
    @ObservationIgnored private var pinned: Set<UUID> = []
    @ObservationIgnored private var editedSinceOpen: Set<UUID> = []
    @ObservationIgnored private var inkModifiedAt: Date?
    @ObservationIgnored private var manifestVersion = 0
    @ObservationIgnored private var savedManifestVersion = 0
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var pendingDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var pendingSince: ContinuousClock.Instant?
    @ObservationIgnored private var activeSave: Task<Bool, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var indexedSignature: IndexSignature
    @ObservationIgnored private var pendingWork: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let signposter = OSSignposter(category: "document")

    /// How many clean, loaded pages are kept in memory before the least recently used are released.
    /// Pages with a live canvas and pages with unsaved ink are never released.
    @ObservationIgnored var inkCacheLimit = 24

    private struct Ink {
        var drawing: PKDrawing
        var version = 0
        var savedVersion = 0
        var isDirty: Bool { version != savedVersion }
    }

    private struct Load {
        let token: UUID
        let task: Task<PKDrawing?, Never>
        var isRequired: Bool
    }

    /// The manifest fields the library shows while the notebook is open.
    private struct IndexSignature: Equatable {
        let title: String
        let pageCount: Int
        let cover: CoverSpec
        let isFavorite: Bool
        let deletedAt: Date?
        let folderID: UUID?
        let firstPage: String?
        let tags: [String]
        let pageTags: [String]

        init(_ manifest: NotebookManifest) {
            title = manifest.title
            pageCount = manifest.pages.count
            cover = manifest.cover
            isFavorite = manifest.library.isFavorite
            deletedAt = manifest.library.deletedAt
            folderID = manifest.library.folderID
            firstPage = manifest.pages.first.map { "\($0.id.uuidString)-\($0.appearanceKey)" }
            tags = manifest.library.tags
            pageTags = manifest.pages.compactMap { page in
                let tags = page.tags
                return tags.isEmpty ? nil : "\(page.id.uuidString) \(Tags.joined(tags))"
            }
        }
    }

    init(package: NotebookPackage, load: ManifestLoad) {
        id = package.id
        self.package = package
        manifest = load.manifest
        isReadOnly = load.isReadOnly
        indexedSignature = IndexSignature(load.manifest)
        undoManager.levelsOfUndo = UndoBudget.levels.upperBound
        if manifest.pages.isEmpty, !isReadOnly {
            manifest.pages = [manifest.defaults.newPage()]
            manifestVersion += 1
        }
        if load.needsSave, !isReadOnly { manifestVersion += 1 }
        for file in load.quarantined {
            notices.append(DocumentNotice(kind: .quarantined, message: String(localized: "A damaged file (\(file)) was set aside and kept. The notebook opened from its last good copy.")))
        }
        if !load.recoveredPageIDs.isEmpty {
            notices.append(DocumentNotice(kind: .recovered, message: String(localized: "Recovered \(load.recoveredPageIDs.count) pages written just before the app last quit. They're at the end.")))
        }
        if !manifest.opaquePages.isEmpty {
            notices.append(DocumentNotice(kind: .unreadablePages, message: String(localized: "\(manifest.opaquePages.count) pages were made by a newer version of OwlLuna and are hidden here. They're kept unchanged.")))
        }
        if isReadOnly {
            notices.append(DocumentNotice(kind: .readOnly, message: String(localized: "This notebook was saved by a newer version of OwlLuna, so it opens read-only.")))
        }
        for recording in load.adoptedRecordings {
            notices.append(DocumentNotice(kind: .recordingStopped, message: RecordingStop.quit.message(at: recording.duration)))
        }
        if manifestVersion != savedManifestVersion { scheduleSave(after: .zero) }
    }

    static func open(_ id: UUID, root: StorageRoot) async throws -> NotebookDocument {
        let package = NotebookPackage(root: root, id: id)
        let read = try await package.readManifest()
        let load = await package.adoptUnfinishedRecordings(read)
        return NotebookDocument(package: package, load: load)
    }

    var pages: [NotebookPage] { manifest.pages }
    var title: String { manifest.title }

    /// Ink left behind by a removed page doesn't count: it's kept in memory for redo and saved if the page comes back.
    var hasUnsavedChanges: Bool {
        manifestVersion != savedManifestVersion || inkModifiedAt != nil
            || inks.contains { $0.value.isDirty && index(of: $0.key) != nil }
    }

    var saveFailureReason: String? {
        if case .failed(let reason, _) = saveState { return reason }
        return nil
    }

    func index(of pageID: UUID) -> Int? { manifest.pages.firstIndex { $0.id == pageID } }

    // MARK: Ink

    func hasUnsavedInk(_ pageID: UUID) -> Bool { inks[pageID]?.isDirty ?? false }

    /// The page's ink if it's in memory.
    func loadedInk(_ pageID: UUID) -> PKDrawing? {
        inks[pageID]?.drawing
    }

    /// Loads a page's ink off the main thread. Damaged files are quarantined and the page starts empty.
    func ink(_ pageID: UUID) async -> PKDrawing {
        while true {
            if let ink = inks[pageID] {
                touch(pageID)
                return ink.drawing
            }
            var load = loading[pageID] ?? startLoad(pageID, required: true)
            if !load.isRequired {
                load.isRequired = true
                loading[pageID] = load
            }
            if let drawing = await load.task.value { return drawing }
        }
    }

    /// Loads pages near the viewport ahead of time and drops queued prefetches the viewport has moved away from.
    /// A load someone is waiting for is never cancelled.
    func prefetchInk(_ ids: [UUID]) {
        let wanted = Set(ids)
        for (pageID, load) in loading where !load.isRequired && !wanted.contains(pageID) {
            load.task.cancel()
            loading[pageID] = nil
        }
        for pageID in ids where inks[pageID] == nil && loading[pageID] == nil {
            _ = startLoad(pageID, required: false)
        }
    }

    /// Pages with a live canvas. Their ink stays in memory so a stroke's undo always has the page it replaced.
    func pinInk(_ ids: Set<UUID>) {
        pinned = ids
    }

    /// Lets go of every page's ink that is saved and has no live canvas, for when memory runs short.
    func releaseCleanInk() {
        for (pageID, ink) in inks where !ink.isDirty && !pinned.contains(pageID) {
            inks[pageID] = nil
            recentlyUsed.removeAll { $0 == pageID }
        }
    }

    private func startLoad(_ pageID: UUID, required: Bool) -> Load {
        let token = UUID()
        let package = package
        let task = Task(priority: required ? .userInitiated : .utility) { [weak self] () -> PKDrawing? in
            let result = await package.readInk(pageID)
            return self?.finishLoading(pageID, token: token, result)
        }
        let load = Load(token: token, task: task, isRequired: required)
        loading[pageID] = load
        return load
    }

    private func finishLoading(_ pageID: UUID, token: UUID, _ result: InkLoad) -> PKDrawing? {
        if loading[pageID]?.token == token { loading[pageID] = nil }
        if let existing = inks[pageID] { return existing.drawing }
        var drawing = PKDrawing()
        switch result {
        case .cancelled:
            return nil
        case .empty:
            break
        case .ink(let loaded, let hash):
            drawing = loaded
            if let index = index(of: pageID), manifest.pages[index].inkHash != hash {
                manifest.pages[index].inkHash = hash
                manifestVersion += 1
                scheduleSave()
            }
        case .quarantined(let file):
            damagedPages.insert(pageID)
            let message = index(of: pageID).map { String(localized: "The ink on page \($0 + 1) couldn't be read. The original file was kept as \(file), and the page starts empty.") }
                ?? String(localized: "The ink on a page couldn't be read. The original file was kept as \(file), and the page starts empty.")
            notices.append(DocumentNotice(kind: .quarantined, message: message))
            if let index = index(of: pageID) {
                manifest.pages[index].inkHash = nil
                manifestVersion += 1
            }
        }
        inks[pageID] = Ink(drawing: drawing)
        touch(pageID)
        return drawing
    }

    private func touch(_ pageID: UUID) {
        if let position = recentlyUsed.lastIndex(of: pageID) { recentlyUsed.remove(at: position) }
        recentlyUsed.append(pageID)
        guard recentlyUsed.count > inkCacheLimit else { return }
        for candidate in recentlyUsed.prefix(recentlyUsed.count - inkCacheLimit)
        where inks[candidate]?.isDirty == false && !pinned.contains(candidate) {
            inks[candidate] = nil
            recentlyUsed.removeAll { $0 == candidate }
        }
    }

    /// The stroke-end path: record the new drawing, register undo against the document, debounce a save.
    func canvasDidChangeInk(_ pageID: UUID, to drawing: PKDrawing) {
        guard !isReadOnly else { return }
        let before = inks[pageID]?.drawing
        setInk(pageID, drawing)
        if let before { registerInkUndo(pageID, restoring: before, then: drawing) }
        inkChanged()
        recorder?.noteInk(onPage: pageID)
        if editedSinceOpen.insert(pageID).inserted {
            Task.detached(priority: .utility) { await HandwritingIndexer.shared.cancel(page: pageID) }
        }
    }

    private func setInk(_ pageID: UUID, _ drawing: PKDrawing) {
        var ink = inks[pageID] ?? Ink(drawing: drawing)
        ink.drawing = drawing
        ink.version &+= 1
        inks[pageID] = ink
        touch(pageID)
    }

    /// Ink edits date the notebook when they're saved, without touching the observed manifest on every stroke.
    private func inkChanged() {
        inkModifiedAt = .now
        scheduleSave()
    }

    private func registerInkUndo(_ pageID: UUID, restoring before: PKDrawing, then after: PKDrawing) {
        undoManager.registerUndo(withTarget: self) { document in
            document.replaceInk(pageID, with: before)
            document.registerInkUndo(pageID, restoring: after, then: before)
        }
        undoManager.setActionName(String(localized: "Ink"))
    }

    /// Replaces a page's ink from the model side and tells a live canvas to show it. The copy matters: given an
    /// earlier version of a drawing it has seen, PencilKit brings the later strokes back with the next stroke.
    func replaceInk(_ pageID: UUID, with drawing: PKDrawing) {
        setInk(pageID, PKDrawing(strokes: drawing.strokes))
        inkObserver?.document(self, didReplaceInkOf: pageID)
        inkChanged()
    }

    /// Replaces the ink of several pages as one undo step, for ink moved between pages. Every page named must have
    /// its ink in memory; one that hasn't leaves the whole change undone.
    @discardableResult
    func updateInk(_ changes: [UUID: PKDrawing], actionName: String) -> Bool {
        guard !isReadOnly, !changes.isEmpty, changes.keys.allSatisfy({ inks[$0] != nil && index(of: $0) != nil }) else { return false }
        applyInk(changes, actionName: actionName)
        return true
    }

    private func applyInk(_ changes: [UUID: PKDrawing], actionName: String) {
        var before: [UUID: PKDrawing] = [:]
        for (pageID, drawing) in changes {
            before[pageID] = inks[pageID]?.drawing ?? PKDrawing()
            replaceInk(pageID, with: drawing)
        }
        undoManager.registerUndo(withTarget: self) { $0.applyInk(before, actionName: actionName) }
        undoManager.setActionName(actionName)
    }

    // MARK: Pages

    func insertPages(_ newPages: [NotebookPage], at index: Int, ink: [UUID: PKDrawing] = [:], actionName: String = String(localized: "Add Page")) {
        guard !isReadOnly, !newPages.isEmpty else { return }
        let position = min(max(index, 0), manifest.pages.count)
        for (pageID, drawing) in ink { setInk(pageID, drawing) }
        manifest.pages.insert(contentsOf: newPages, at: position)
        structureChanged()
        let ids = newPages.map(\.id)
        undoManager.registerUndo(withTarget: self) { document in
            document.removePages(ids, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    func removePages(_ ids: [UUID], actionName: String = String(localized: "Delete Page")) {
        guard !isReadOnly else { return }
        let removed = manifest.pages.enumerated().filter { ids.contains($0.element.id) }.map { (offset: $0.offset, page: $0.element) }
        guard !removed.isEmpty else { return }
        let placeholder = removed.count == manifest.pages.count ? manifest.defaults.newPage() : nil
        applyRemoval(removed, placeholder: placeholder, actionName: actionName)
    }

    /// Removing every page leaves one blank page. Redo re-applies exactly the same change, same placeholder
    /// included, so later redo steps still find the pages they refer to.
    private func applyRemoval(_ removed: [(offset: Int, page: NotebookPage)], placeholder: NotebookPage?, actionName: String) {
        let ids = Set(removed.map(\.page.id))
        manifest.pages.removeAll { ids.contains($0.id) }
        if let placeholder, manifest.pages.isEmpty { manifest.pages = [placeholder] }
        structureChanged()
        undoManager.registerUndo(withTarget: self) { document in
            document.undoRemoval(removed, placeholder: placeholder, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func undoRemoval(_ removed: [(offset: Int, page: NotebookPage)], placeholder: NotebookPage?, actionName: String) {
        if let placeholder { manifest.pages.removeAll { $0.id == placeholder.id } }
        for (offset, page) in removed {
            manifest.pages.insert(page, at: min(offset, manifest.pages.count))
        }
        structureChanged()
        undoManager.registerUndo(withTarget: self) { document in
            document.applyRemoval(removed, placeholder: placeholder, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    func movePage(from source: Int, to destination: Int) {
        guard !isReadOnly, manifest.pages.indices.contains(source), manifest.pages.indices.contains(destination), source != destination else { return }
        let page = manifest.pages.remove(at: source)
        manifest.pages.insert(page, at: destination)
        structureChanged()
        undoManager.registerUndo(withTarget: self) { $0.movePage(from: destination, to: source) }
        undoManager.setActionName(String(localized: "Move Page"))
    }

    /// Returns where the copy went.
    @discardableResult
    func duplicatePage(at index: Int) async -> Int? {
        guard !isReadOnly, manifest.pages.indices.contains(index) else { return nil }
        let original = manifest.pages[index]
        let drawing = await ink(original.id)
        guard let position = self.index(of: original.id) else { return nil }
        var copy = original.duplicated()
        copy.inkHash = nil
        insertPages([copy], at: position + 1, ink: drawing.strokes.isEmpty ? [:] : [copy.id: drawing], actionName: String(localized: "Duplicate Page"))
        return position + 1
    }

    /// A new page for inserting after `index`: it matches that page's paper when it's a template page or the user's own paper,
    /// and otherwise uses the notebook's defaults.
    func newPage(after index: Int?, template: PaperTemplate? = nil) -> NotebookPage {
        var page = manifest.defaults.newPage()
        if let index, manifest.pages.indices.contains(index), !manifest.pages[index].isBoard,
           manifest.pages[index].template != nil || manifest.pages[index].notebookPaper != nil {
            let anchor = manifest.pages[index]
            page.size = anchor.size
            page.paperColor = anchor.paperColor
            page.background = anchor.background
            page.paperID = anchor.paperID
        }
        if let template {
            page.background = .template(template)
            if page.paperID != nil {
                page.paperID = nil
                page.paperColor = manifest.defaults.paperColor
            }
        }
        return page
    }

    /// Template and colour together, as one undo step.
    func setPaper(template: PaperTemplate, color: PaperColor, forPage pageID: UUID) {
        guard let index = index(of: pageID) else { return }
        let page = manifest.pages[index]
        guard page.template != nil || page.notebookPaper != nil, page.template != template || page.paperColor != color else { return }
        updatePage(pageID, actionName: String(localized: "Change Paper")) {
            $0.background = .template(template)
            $0.paperColor = color
            $0.paperID = nil
        }
    }

    /// The user's own paper on a page, which keeps its width, as one undo step.
    func setPaper(_ paper: NotebookPaper, forPage pageID: UUID) {
        guard let index = index(of: pageID) else { return }
        let page = manifest.pages[index]
        guard !page.isBoard, page.template != nil || page.notebookPaper != nil, page.paperID != paper.id || page.background != paper.background else { return }
        let size = CGSize(width: page.size.width, height: (page.size.width * paper.size.height / max(paper.size.width, 1)).rounded())
        updatePage(pageID, actionName: String(localized: "Change Paper")) {
            $0.background = paper.background
            $0.paperColor = .white
            $0.size = size
            $0.paperID = paper.id
        }
    }

    /// The notebook's copy of the user's paper, made the first time a page uses it.
    func keepCopy(of paper: CustomPaper) async throws -> NotebookPaper {
        let kept = ([manifest.defaults.paper] + manifest.pages.map(\.notebookPaper)).lazy.compactMap { $0 }.first { $0.id == paper.id }
        if let kept, let file = kept.background.assetFile, FileManager.default.fileExists(atPath: package.assetURL(file).path(percentEncoded: false)) {
            return NotebookPaper(id: paper.id, background: kept.background, size: paper.size)
        }
        let file = try await package.importAsset(from: paper.url, ext: paper.url.pathExtension)
        return NotebookPaper(id: paper.id, background: paper.background(file: file), size: paper.size)
    }

    func updatePage(_ pageID: UUID, actionName: String, _ change: (inout NotebookPage) -> Void) {
        guard !isReadOnly, let index = index(of: pageID) else { return }
        let before = manifest.pages[index]
        change(&manifest.pages[index])
        structureChanged()
        registerPageRestore(before, actionName: actionName)
    }

    /// The ink's hash stays as the last save left it: the ink has undo steps of its own.
    private func registerPageRestore(_ page: NotebookPage, actionName: String) {
        undoManager.registerUndo(withTarget: self) { document in
            guard let index = document.index(of: page.id) else {
                document.registerPageRestore(page, actionName: actionName)
                return
            }
            let current = document.manifest.pages[index]
            document.manifest.pages[index] = page
            document.manifest.pages[index].inkHash = current.inkHash
            document.structureChanged()
            document.registerPageRestore(current, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    // MARK: Notebook

    func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isReadOnly, !trimmed.isEmpty, trimmed != manifest.title else { return }
        manifest.title = trimmed
        structureChanged()
    }

    func updateCover(_ cover: CoverSpec) {
        guard !isReadOnly, cover != manifest.cover else { return }
        manifest.cover = cover
        structureChanged()
    }

    /// Records the open in the manifest, so the library's Last Opened order survives the next index.
    func noteOpened() {
        guard !isReadOnly else { return }
        manifest.library.lastOpenedAt = .now
        manifestVersion += 1
        scheduleSave(after: .seconds(5), coalesce: true)
    }

    func noteCurrentPage(_ index: Int) {
        guard !isReadOnly, manifest.library.currentPage != index else { return }
        manifest.library.currentPage = index
        manifest.library.lastOpenedAt = .now
        manifestVersion += 1
        scheduleSave(after: .seconds(5), coalesce: true)
    }

    func addRecording(_ recording: RecordingEntry) {
        guard !isReadOnly else { return }
        manifest.recordings.append(recording)
        structureChanged()
    }

    /// Names a recording's audio in the manifest as it starts, saved at once, so quitting before Stop doesn't lose it.
    func beginRecording(_ recording: RecordingEntry) {
        guard !isReadOnly else { return }
        var recording = recording
        recording.device = package.root.deviceID
        manifest.unfinishedRecordings.append(recording)
        manifest.modifiedAt = .now
        manifestVersion += 1
        scheduleSave(after: .zero)
    }

    /// The recording joins the list once its audio is a finished file; closing waits for that.
    func finishRecording(_ recording: RecordingEntry) {
        guard !isReadOnly else { return }
        let package = package
        perform { [self] in
            let finished = await package.finishRecording(recording, keepingUnreadable: true)
            manifest.unfinishedRecordings.removeAll { $0.id == recording.id }
            if let finished { manifest.recordings.append(finished) }
            structureChanged()
        }
    }

    func noteRecordingStopped(_ message: String) {
        note(.recordingStopped, message, replacing: [.recordingStopped])
    }

    /// One undo step. Its audio and transcript stay in the package until the editor closes, so undo has them to bring back.
    func removeRecording(_ id: UUID) {
        guard !isReadOnly, let index = manifest.recordings.firstIndex(where: { $0.id == id }) else { return }
        let recording = manifest.recordings.remove(at: index)
        structureChanged()
        recorder?.recordingRemoved(recording)
        undoManager.registerUndo(withTarget: self) { $0.restoreRecording(recording, at: index) }
        undoManager.setActionName(String(localized: "Delete Recording"))
    }

    private func restoreRecording(_ recording: RecordingEntry, at index: Int) {
        guard !manifest.recordings.contains(where: { $0.id == recording.id }) else { return }
        manifest.recordings.insert(recording, at: min(index, manifest.recordings.count))
        structureChanged()
        recorder?.recordingRestored(recording)
        undoManager.registerUndo(withTarget: self) { $0.removeRecording(recording.id) }
        undoManager.setActionName(String(localized: "Delete Recording"))
    }

    /// One undo step. Nothing, or only spaces, takes the name off.
    func renameRecording(_ id: UUID, to title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed?.isEmpty == false ? trimmed : nil
        guard !isReadOnly, let index = manifest.recordings.firstIndex(where: { $0.id == id }), manifest.recordings[index].title != title else { return }
        let before = manifest.recordings[index].title
        manifest.recordings[index].title = title
        structureChanged()
        undoManager.registerUndo(withTarget: self) { $0.renameRecording(id, to: before) }
        undoManager.setActionName(String(localized: "Rename Recording"))
    }

    func setTranscript(_ file: String?, forRecording id: UUID) {
        guard !isReadOnly, let index = manifest.recordings.firstIndex(where: { $0.id == id }) else { return }
        manifest.recordings[index].transcriptFile = file
        structureChanged()
    }

    /// Favourite, lock, tag, trash and folder changes made from the library while this notebook is open. They are
    /// stamped, not dated: see `LibraryState.changedAt`.
    func updateLibraryState(_ change: (inout LibraryState) -> Void) {
        guard !isReadOnly else { return }
        let before = manifest.library
        change(&manifest.library)
        manifest.library.stamp(changesSince: before, at: .now)
        manifestVersion += 1
        scheduleSave()
        if manifest.library.isLocked != before.isLocked { recorder?.noteLockChanged() }
    }

    /// A change the library would write to a closed notebook's manifest, made here instead: a tag renamed everywhere,
    /// or a change that found the notebook opening.
    func applyLibraryChange(_ change: (inout NotebookManifest) -> Void) {
        guard !isReadOnly else { return }
        var changed = manifest
        change(&changed)
        guard changed != manifest else { return }
        let wasLocked = manifest.library.isLocked
        manifest = changed
        manifestVersion += 1
        scheduleSave()
        onStructureChange?()
        if manifest.library.isLocked != wasLocked { recorder?.noteLockChanged() }
    }

    func dismissNotice(_ notice: DocumentNotice) {
        notices.removeAll { $0.id == notice.id }
    }

    func dismissNotices(_ kind: DocumentNotice.Kind) {
        notices.removeAll { $0.kind == kind }
    }

    /// A finger dragged on a page and drew nothing, because only the Pencil draws.
    func noteOnlyPencilDraws() {
        noteOnce(.onlyPencilDraws, String(localized: "Only Apple Pencil draws right now."))
    }

    /// A finger drew on an iPhone's page, where one finger writes and two scroll.
    func noteTwoFingersScroll() {
        noteOnce(.twoFingersScroll, String(localized: "One finger writes. Scroll and zoom with two fingers."))
    }

    /// Another device wrote in the notebook since, and so did this one: Keep Both, or closing it, keeps both.
    func noteNewerVersion() {
        noteOnce(.newerVersion, String(localized: "This notebook was changed on another device too. Keep Both keeps the older version as a conflicted copy, as closing it would."))
    }

    /// Keep Both kept the other version as a notebook of its own.
    func noteKeptCopy(_ message: String) {
        note(.keptCopy, message, replacing: [.newerVersion, .keptCopy])
    }

    /// Adds a notice of this kind unless one is showing already.
    private func noteOnce(_ kind: DocumentNotice.Kind, _ message: @autoclosure () -> String) {
        guard !notices.contains(where: { $0.kind == kind }) else { return }
        notices.append(DocumentNotice(kind: kind, message: message()))
    }

    /// Adds a notice in place of any of the `replacing` kinds.
    private func note(_ kind: DocumentNotice.Kind, _ message: String, replacing kinds: [DocumentNotice.Kind]) {
        notices.removeAll { kinds.contains($0.kind) }
        notices.append(DocumentNotice(kind: kind, message: message))
    }

    /// Nothing is unsaved, under way or being recorded, so a newer version can take its place.
    var canBeSetAside: Bool { !hasUnsavedChanges && pendingWork.isEmpty && activeSave == nil && recorder?.isRecording != true }

    func setAside() {
        isSetAside = true
        pendingSave?.cancel()
    }

    private func structureChanged() {
        manifestVersion += 1
        manifest.modifiedAt = .now
        scheduleSave()
        onStructureChange?()
    }

    // MARK: Work in flight

    /// Runs work that will add to the document, such as an import, so closing waits for it to land.
    func perform(_ work: @escaping @MainActor () async -> Void) {
        let token = UUID()
        pendingWork[token] = Task {
            await work()
            self.pendingWork[token] = nil
        }
    }

    func finishPendingWork() async {
        while let task = pendingWork.values.first { await task.value }
    }

    // MARK: Saving

    /// Debounced: each edit pushes the save back by `delay`, but never past `maxSaveLatency` after the first
    /// unsaved edit. With `coalesce`, an earlier pending save is never postponed.
    func scheduleSave(after delay: Duration? = nil, coalesce: Bool = false) {
        guard !isReadOnly, !isSetAside else { return }
        if case .failed = saveState { return }
        let now = ContinuousClock.now
        let since = pendingSince ?? now
        var deadline = min(now + (delay ?? saveDelay), since + maxSaveLatency)
        if coalesce, let pendingDeadline { deadline = min(deadline, pendingDeadline) }
        pendingSince = since
        pendingDeadline = deadline
        pendingSave?.cancel()
        if saveState == .saved { saveState = .pending }
        pendingSave = Task { [self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            pendingDeadline = nil
            pendingSince = nil
            await save()
        }
    }

    /// Writes dirty pages, then the manifest. Only one save runs at a time; a failed save keeps everything
    /// dirty and retries with backoff. Returns true when everything is on disk.
    @discardableResult
    func save() async -> Bool {
        if let activeSave {
            _ = await activeSave.value
            if !hasUnsavedChanges { return true }
        }
        guard !isReadOnly, !isSetAside, hasUnsavedChanges else {
            if !isReadOnly { saveState = .saved }
            return true
        }
        let task = Task { await performSave() }
        activeSave = task
        let result = await task.value
        activeSave = nil
        return result
    }

    struct PendingSave {
        let snapshot: SaveSnapshot
        let versions: [UUID: Int]
        let manifestVersion: Int
        let inkModifiedAt: Date?
    }

    /// The main-thread part of a save: value snapshots of the manifest and the dirty pages' ink.
    func makePendingSave() -> PendingSave {
        var versions: [UUID: Int] = [:]
        var dirtyInk: [UUID: PKDrawing] = [:]
        for (pageID, ink) in inks where ink.isDirty && index(of: pageID) != nil {
            dirtyInk[pageID] = ink.drawing
            versions[pageID] = ink.version
        }
        var snapshot = manifest
        if let inkModifiedAt { snapshot.modifiedAt = max(snapshot.modifiedAt, inkModifiedAt) }
        return PendingSave(snapshot: SaveSnapshot(manifest: snapshot, ink: dirtyInk), versions: versions,
                           manifestVersion: manifestVersion, inkModifiedAt: inkModifiedAt)
    }

    private func performSave() async -> Bool {
        pendingSave?.cancel()
        pendingDeadline = nil
        pendingSince = nil
        let interval = signposter.beginInterval("Save")
        saveState = .saving
        let pending = makePendingSave()
        signposter.emitEvent("Save snapshot taken")
        do {
            let receipt = try await package.write(pending.snapshot)
            takeLaterFiling(receipt.manifest.library)
            for (pageID, version) in pending.versions {
                inks[pageID]?.savedVersion = version
                if inks[pageID]?.version == version, let hash = receipt.inkHashes[pageID], let index = index(of: pageID) {
                    manifest.pages[index].inkHash = hash
                }
            }
            if let written = pending.inkModifiedAt {
                if manifest.modifiedAt < written { manifest.modifiedAt = written }
                if inkModifiedAt == written { inkModifiedAt = nil }
                let inked = pending.versions.keys.filter { (receipt.inkHashes[$0] ?? nil) != nil }
                if !inked.isEmpty { onInkSaved?(inked, written) }
            }
            if let heaviest = receipt.inkBytes.values.max(), heaviest > heaviestEditedPage {
                heaviestEditedPage = heaviest
                undoManager.levelsOfUndo = UndoBudget.levels(forPageBytes: heaviest)
            }
            if manifestVersion == pending.manifestVersion { savedManifestVersion = pending.manifestVersion }
            failures = 0
            saveState = hasUnsavedChanges ? .pending : .saved
            if notices.contains(where: { $0.kind == .saveFailed }) { notices.removeAll { $0.kind == .saveFailed } }
            signposter.endInterval("Save", interval)
            let signature = IndexSignature(receipt.manifest)
            if signature != indexedSignature {
                indexedSignature = signature
                onSaved?(receipt.manifest)
            }
            if hasUnsavedChanges { scheduleSave() }
            onWritten?()
            return !hasUnsavedChanges
        } catch {
            failures += 1
            let wait = min(retryBase * (1 << min(failures - 1, 6)), .seconds(60))
            saveState = .failed(error.localizedDescription, retryIn: wait)
            noteOnce(.saveFailed, String(localized: "Couldn't save your latest changes. OwlLuna will keep trying; nothing has been lost."))
            signposter.endInterval("Save", interval)
            pendingSave = Task { [self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                if case .failed = saveState { saveState = .pending }
                await save()
            }
            return false
        }
    }

    /// Filing the save kept from the file, changed there after this document read it, is the document's too.
    private func takeLaterFiling(_ written: LibraryState) {
        let wasLocked = manifest.library.isLocked
        manifest.library.takeLaterChanges(from: written)
        if manifest.library.isLocked != wasLocked { recorder?.noteLockChanged() }
    }

    /// Saves everything now, retrying a few times. Used when the app moves to the background and on close.
    @discardableResult
    func flush(attempts: Int = 3) async -> Bool {
        for _ in 0..<attempts {
            if case .failed = saveState { saveState = .pending }
            if await save() { return true }
        }
        return !hasUnsavedChanges
    }

    /// Removes files of pages that are gone for good. Call after a successful flush when the editor closes.
    func collectGarbage() async {
        guard !hasUnsavedChanges, !isReadOnly, !isSetAside else { return }
        await package.collectGarbage(keeping: manifest)
    }
}
