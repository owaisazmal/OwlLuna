import UIKit
import os

@MainActor
@Observable
final class ExportJob: Identifiable {
    enum State: Equatable { case choosing, running, finished([URL]), failed(String), cancelled }
    /// One PDF, a PNG or an SVG for every page, a film of one page being written, or the words as text.
    enum Format: Sendable { case pdf, images, svg, timelapse, text }
    /// The PDF zipped with the notebook's recordings, once that has been asked for.
    enum Bundle: Equatable { case making, made(URL), failed(String) }

    let id = UUID()
    let format: Format
    /// The first page's width over its height, for showing a film of it.
    let shape: CGFloat
    /// Locked notebooks left out of an export of several, because nobody unlocked them.
    let skipped: Int
    private(set) var progress: Double = 0
    private(set) var state: State
    var options = NotebookExporter.Options()
    /// The pages chosen, by their place in the notebook. Only an export of one notebook chooses.
    var range: ClosedRange<Int>
    /// The page open in the editor when the export was asked for.
    let currentPage: Int?
    /// It asked what to export before it started.
    let asks: Bool
    /// The recordings that can go with a single notebook's PDF; none for any other export.
    let recordingCount: Int
    private(set) var includesRecordings = false
    private(set) var bundle: Bundle?
    @ObservationIgnored private var inputs: [NotebookExporter.Input]
    @ObservationIgnored private let refresh: (@MainActor () async -> NotebookExporter.Input?)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var withRecordings: NotebookExporter.Input?
    @ObservationIgnored private var bundling: Task<Void, Never>?

    /// `pages` narrows the export to some of the notebook's pages. `choosing` asks first which of them: all, or with `thisPage`
    /// the page `current`, which it can always come back to.
    convenience init(document: NotebookDocument, format: Format = .pdf, pages: [NotebookPage]? = nil, choosing: Bool = false, current: Int? = nil,
                     thisPage: Bool = false) {
        let input = NotebookExporter.Input(document: document, pages: pages)
        let ids = Set(input.pages.map(\.id))
        // Words are read from what is saved, so the text waits for the editor's ink to be written.
        var refresh: (@MainActor () async -> NotebookExporter.Input?)?
        if format == .text {
            refresh = { [weak document] () async -> NotebookExporter.Input? in
                guard let document else { return nil }
                _ = await document.flush()
                let kept: [NotebookPage]? = pages == nil ? nil : document.pages.filter { ids.contains($0.id) }
                return NotebookExporter.Input(document: document, pages: kept)
            }
        }
        self.init(inputs: [input], format: format, choosing: choosing, current: current, thisPage: thisPage, refresh: refresh)
    }

    /// Exports from the library: the open document, with its unsaved ink, if the notebook is being edited, otherwise the saved pages.
    static func forNotebook(_ id: UUID, root: StorageRoot, format: Format = .pdf, choosing: Bool = false) async throws -> ExportJob {
        if format == .text, let document = DocumentRegistry.shared.document(for: id) { _ = await document.flush() }
        return ExportJob(inputs: [try await NotebookExporter.input(for: id, root: root)], format: format, choosing: choosing)
    }

    /// A PDF of each notebook. Locked ones go in once whoever is holding the iPad has shown it is theirs, asked once
    /// for all of them; otherwise they are left out, and the sheet says so.
    static func pdfs(of records: [NotebookRecord], root: StorageRoot, choosing: Bool = false) async throws -> ExportJob {
        let locked = records.filter(\.isLocked)
        var ids = records.map(\.id)
        if !locked.isEmpty {
            let lock = NotebookLock.shared
            let reason = locked.count == 1 ? String(localized: "Export “\(locked[0].title)”") : String(localized: "Export \(locked.count) locked notebooks")
            let unlocked = lock.isAvailable ? await lock.confirm(reason) : false
            if !unlocked { ids = records.filter { !$0.isLocked }.map(\.id) }
        }
        var inputs: [NotebookExporter.Input] = []
        for id in ids { inputs.append(try await NotebookExporter.input(for: id, root: root)) }
        return ExportJob(inputs: inputs, skipped: records.count - ids.count, choosing: choosing)
    }

    convenience init(input: NotebookExporter.Input, format: Format = .pdf) {
        self.init(inputs: [input], format: format)
    }

    /// Each notebook is written in turn into a folder of its own. Unless `choosing`, it starts at once.
    init(inputs: [NotebookExporter.Input], format: Format = .pdf, skipped: Int = 0, choosing: Bool = false, current: Int? = nil, thisPage: Bool = false,
         refresh: (@MainActor () async -> NotebookExporter.Input?)? = nil) {
        self.format = format
        self.skipped = skipped
        self.inputs = inputs
        self.refresh = refresh
        let count = inputs.count == 1 ? inputs[0].allPages.count : 0
        currentPage = current.map { min(max($0, 0), max(count - 1, 0)) }
        range = thisPage ? currentPage.map { $0...$0 } ?? 0...0 : 0...max(count - 1, 0)
        state = choosing ? .choosing : .running
        asks = choosing
        recordingCount = format == .pdf && inputs.count == 1 && skipped == 0 ? inputs[0].recordings.count : 0
        shape = inputs.first?.pages.first.map { $0.size.width / max($0.size.height, 1) } ?? 0.77
        if !choosing { run() }
    }

    var isSeveral: Bool { inputs.count + skipped > 1 }

    /// The notebook's pages, when one notebook is being exported.
    var pages: [NotebookPage] { inputs.count == 1 ? inputs[0].allPages : [] }
    var package: NotebookPackage? { inputs.count == 1 ? inputs[0].package : nil }
    var choosesPages: Bool { inputs.count == 1 && pages.count > 1 }

    /// Goes ahead with what was chosen.
    func start() {
        guard state == .choosing else { return }
        if choosesPages { inputs = [inputs[0].narrowed(to: range)] }
        options.evenHighlights = EvenHighlights.isOn
        state = .running
        run()
    }

    private func run() {
        let format = format, options = options, refresh = refresh, range = range, narrows = choosesPages, prepared = inputs
        let count = Double(max(prepared.count, 1))
        if recordingCount > 0, let input = prepared.first, input.pages.count == input.allPages.count { withRecordings = input }
        task = Task { [weak self] in
            var inputs = prepared
            if let refresh, let fresh = await refresh() { inputs = [narrows ? fresh.narrowed(to: range) : fresh] }
            let chosen = inputs
            let report: @Sendable (Int, Double) async -> Void = { index, value in
                await MainActor.run { self?.progress = max(self?.progress ?? 0, (Double(index) + value) / count) }
            }
            let work = Task.detached(priority: .userInitiated) { () throws -> [URL] in
                var urls: [URL] = []
                do {
                    for (index, input) in chosen.enumerated() {
                        let progress: @Sendable (Double) async -> Void = { await report(index, $0) }
                        switch format {
                        case .pdf: urls.append(try await NotebookExporter.export(input, options: options, progress: progress))
                        case .images: urls += try await NotebookExporter.exportImages(input, options: options, progress: progress)
                        case .svg: urls += try await NotebookExporter.exportSVG(input, options: options, progress: progress)
                        case .timelapse: urls.append(try await InkTimelapse.export(input, evenHighlights: options.evenHighlights, progress: progress))
                        case .text: urls.append(try await NotebookExporter.exportText(input, markdown: options.markdown, progress: progress))
                        }
                    }
                } catch {
                    let written = urls
                    await MainActor.run { ExportFolder.discard(written) }
                    throw error
                }
                return urls
            }
            do {
                let urls = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                if let self, state == .running { state = .finished(urls) } else { ExportFolder.discard(urls) }
            } catch is CancellationError {
                self?.state = .cancelled
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// What Share hands over: the PDF, or the zip that holds it with the recordings once they are included.
    var shared: [URL] {
        guard case .finished(let urls) = state else { return [] }
        if includesRecordings { if case .made(let zip) = bundle { return [zip] } else { return [] } }
        return urls
    }

    /// The recordings go with a PDF of the whole notebook.
    var offersRecordings: Bool { withRecordings != nil }

    /// Off until asked for each time: recordings of people talking only leave with the notes when someone means them to.
    func includeRecordings(_ include: Bool) {
        includesRecordings = include
        guard include, bundling == nil, case .finished(let urls) = state, let pdf = urls.first, let input = withRecordings else { return }
        bundle = .making
        bundling = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { try NotebookExporter.bundle(pdf, with: input) }
            do {
                let zip = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                self?.bundle = .made(zip)
            } catch is CancellationError {
                self?.bundle = nil
            } catch {
                self?.bundle = .failed(error.localizedDescription)
                self?.bundling = nil
            }
        }
    }

    func cancel() {
        task?.cancel()
        state = .cancelled
    }

    /// Its sheet has closed: a running export stops, and the files go once nothing is sharing or printing them.
    func close() {
        if state == .running || state == .choosing { cancel() }
        bundling?.cancel()
        if case .finished(let urls) = state { ExportFolder.discard(urls) }
    }
}
