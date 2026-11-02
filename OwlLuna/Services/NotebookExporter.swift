import UIKit
import SwiftUI
import PencilKit
import AVFoundation
import os

/// Writes a notebook as a PDF: vector backgrounds (templates, the original PDF pages, photos) with the ink
/// on top, clipped to each page. Runs off the main thread and reports progress; cancellable between pages.
enum NotebookExporter {
    private static let signposter = OSSignposter(category: "export")

    /// How a PDF is made: with the paper or without, how finely what can't be drawn as shapes goes in, and whether the words
    /// read from handwriting and pictures lie under them as text. A text export is plain or Markdown.
    struct Options: Sendable, Equatable {
        enum Quality: Sendable, Equatable { case smaller, sharper }

        var paper = true
        var quality = Quality.sharper
        var searchable = true
        var markdown = false

        /// Pixels a point for the inks with a grain and the highlighter.
        var inkScale: CGFloat { quality == .sharper ? 3 : 1.5 }
        /// Photos and scans go in no finer than this, or as they are.
        var pictureLimit: CGFloat? { quality == .sharper ? nil : 1.5 }
    }

    struct Input: Sendable {
        var title: String
        var pages: [NotebookPage]
        var inMemoryInk: [UUID: PKDrawing]
        var package: NotebookPackage
        var recordings: [RecordingEntry] = []
        /// The whole notebook when `pages` is some of it, so links and bookmarks keep the numbers their pages have in it.
        var notebook: [NotebookPage]?

        var allPages: [NotebookPage] { notebook ?? pages }
        var numbers: [UUID: Int] { Dictionary(allPages.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { first, _ in first }) }
    }

    /// The open document, with its unsaved ink, if the notebook is being edited, otherwise its saved pages.
    @MainActor
    static func input(for id: UUID, root: StorageRoot) async throws -> Input {
        if let document = DocumentRegistry.shared.document(for: id) { return Input(document: document) }
        let package = NotebookPackage(root: root, id: id)
        let load = try await package.readManifest()
        let manifest = await PDFImport.linking(load, in: package).manifest
        return Input(title: manifest.title, pages: manifest.pages, inMemoryInk: [:], package: package, recordings: manifest.recordings)
    }

    /// Streams pages to disk one at a time: each page's ink is read, drawn and released before the next,
    /// so memory stays flat however long the notebook is.
    static func export(_ input: Input, options: Options = Options(), progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        let interval = signposter.beginInterval("Export", "\(input.pages.count) pages")
        defer { signposter.endInterval("Export", interval) }
        return try await ExportFolder.make(.export) { directory in
            let url = directory.appending(path: fileName(input.title, extension: "pdf"))
            try Task.checkCancellation()

            try await renderPDF(input, to: url, options: options, progress: progress)
            try Task.checkCancellation()
            await progress(1)
            return url
        }
    }

    /// Vision waits synchronously for its own work. Keep it off Swift's cooperative pool so exports can't
    /// stop the tasks they need to finish, or unrelated work such as saving shelves, on a small pool.
    private static func renderPDF(_ input: Input, to url: URL, options: Options,
                                  progress: @escaping @Sendable (Double) async -> Void) async throws {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
                        try writePDF(input, to: url, options: options, cancelled: cancelled, progress: progress)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private static func writePDF(_ input: Input, to url: URL, options: Options, cancelled: OSAllocatedUnfairLock<Bool>,
                                 progress: @escaping @Sendable (Double) async -> Void) throws {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: input.title, kCGPDFContextCreator as String: "OwlLuna"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: input.pages.first?.shownSize ?? PageSize.letter.points), format: format)
        let assets = input.package.assetsDirectory
        let count = Double(max(input.pages.count, 1))
        let outline = outline(for: input.pages, numbers: input.numbers)
        let links = LinkTitles(pages: input.allPages)
        let linked = linkedPages(in: input.pages)
        try PageRenderer.$pictureLimit.withValue(options.pictureLimit) {
            try renderer.writePDF(to: url) { context in
                if let outline { CGPDFContextSetOutline(context.cgContext, outline as CFDictionary) }
                for (index, page) in input.pages.enumerated() {
                    if cancelled.withLock({ $0 }) { return }
                    autoreleasepool {
                        let unsaved = input.inMemoryInk[page.id]
                        let ink = unsaved ?? savedInk(page, in: input.package)
                        // A whiteboard goes out as one sheet, as large as what is on it.
                        let page = Whiteboard.whole(page, ink: ink)
                        let bounds = CGRect(origin: .zero, size: page.size)
                        context.beginPage(withBounds: bounds, pageInfo: [:])
                        PageRenderer.drawBackground(page, assets: assets, in: context.cgContext, size: page.size, links: links, paper: options.paper)
                        // Destinations are placed in the PDF's own space, which runs up the page.
                        if linked.contains(page.id) { context.addDestination(withName: page.id.uuidString, at: CGPoint(x: 0, y: page.size.height)) }
                        if page.hasItems {
                            for item in page.items {
                                guard let link = item.link else { continue }
                                let box = item.boundingBox
                                let area = CGRect(x: box.minX, y: page.size.height - box.maxY, width: box.width, height: box.height)
                                if let target = link.target {
                                    if linked.contains(target) { context.setDestinationWithName(target.uuidString, for: area) }
                                } else if let url = link.externalURL {
                                    context.setURL(url, for: area)
                                }
                            }
                        }
                        if options.searchable {
                            PageWords.draw(PageWords.read(page, ink: ink, package: input.package, unsaved: unsaved != nil), in: context.cgContext)
                        }
                        if !ink.strokes.isEmpty {
                            InkVectors.draw(ink, from: page.inkRect, in: context.cgContext, size: page.size, style: inkStyle(for: page, options: options))
                        }
                        PageRenderer.drawOverInk(page, assets: assets, in: context.cgContext, size: page.size)
                    }
                    let fraction = Double(index + 1) / count
                    Task { await progress(fraction) }
                }
            }
        }
    }

    /// Ink is drawn as it is on its paper; without the paper, as on white.
    static func inkStyle(for page: NotebookPage, options: Options) -> InkVectors.Style {
        let dark = options.paper && page.effectivePaperColor.isDark
        return InkVectors.Style(appearance: options.paper ? page.effectivePaperColor.inkAppearance : .light, multipliesHighlighter: !dark,
                                pictureScale: options.inkScale)
    }

    /// Under the file system's 255 bytes for a name, with room for the " 2" a copy saved beside it is given.
    static let nameLimit = 240

    /// The title as a file name ending in `number` and `extension`, cut at a whole character to fit `nameLimit`,
    /// counted decomposed as some file systems store it.
    static func fileName(_ title: String, number: String = "", extension ext: String) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let tail = "\(number).\(ext)", room = nameLimit - bytes(tail)
        var name = "", used = 0
        for character in cleaned {
            let size = bytes(String(character))
            guard used + size <= room else { break }
            name.append(character)
            used += size
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.orUntitled) + tail
    }

    private static func bytes(_ text: String) -> Int { text.decomposedStringWithCanonicalMapping.utf8.count }

    /// Writes each page as a PNG, twice the page's size in points, numbered in page order.
    static func exportImages(_ input: Input, options: Options = Options(), progress: @escaping @Sendable (Double) async -> Void) async throws -> [URL] {
        let interval = signposter.beginInterval("Export", "\(input.pages.count) images")
        defer { signposter.endInterval("Export", interval) }
        return try await ExportFolder.make(.export) { directory in
            let assets = input.package.assetsDirectory, links = LinkTitles(pages: input.allPages)
            let digits = String(input.pages.count).count, count = Double(max(input.pages.count, 1))
            var urls: [URL] = []
            for (index, page) in input.pages.enumerated() {
                try Task.checkCancellation()
                let number = input.pages.count == 1 ? "" : " " + String(repeating: "0", count: digits - String(index + 1).count) + String(index + 1)
                let url = directory.appending(path: fileName(input.title, number: number, extension: "png"))
                let ink = input.ink(for: page)
                let data = autoreleasepool {
                    let page = Whiteboard.whole(page, ink: ink)
                    return PageRenderer.image(of: page, ink: ink, assets: assets, width: page.size.width, scale: Whiteboard.scale(for: page.size, wanted: 2), links: links,
                                              paper: options.paper).pngData()
                }
                guard let data else { throw ImportError.unreadable }
                try data.write(to: url, options: .atomic)
                urls.append(url)
                await progress(Double(index + 1) / count)
            }
            return urls
        }
    }

    /// The words of each page, read first where they haven't been yet: plain text, or Markdown with a heading for the notebook
    /// and one for each page that has words.
    static func exportText(_ input: Input, markdown: Bool, progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        try await ExportFolder.make(.export) { directory in
            let url = directory.appending(path: fileName(input.title, extension: markdown ? "md" : "txt"))
            let numbers = input.numbers, count = Double(max(input.pages.count, 1))
            var parts = [markdown ? "# " + input.title : input.title]
            for (index, page) in input.pages.enumerated() {
                try Task.checkCancellation()
                await HandwritingIndexer.shared.index(HandwritingIndexer.Job(package: input.package, pages: [page]))
                let words = StudyGuide.body(ofPageText: await input.package.readText(page.id) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !words.isEmpty { parts.append((markdown ? "## " : "") + page.bookmarkTitle(number: numbers[page.id] ?? index + 1) + "\n\n" + words) }
                await progress(Double(index + 1) / count)
            }
            try Task.checkCancellation()
            try Data((parts.joined(separator: "\n\n") + "\n").utf8).write(to: url, options: .atomic)
            return url
        }
    }

    /// The pages that links on other pages open, so those links still work in the exported PDF.
    static func linkedPages(in pages: [NotebookPage]) -> Set<UUID> {
        let ids = Set(pages.map(\.id))
        var linked = Set<UUID>()
        for page in pages where page.hasItems {
            for item in page.items { if let target = item.link?.target, ids.contains(target) { linked.insert(target) } }
        }
        return linked
    }

    /// Bookmarks become the PDF's outline, so they show in any reader's sidebar.
    static func outline(for pages: [NotebookPage], numbers: [UUID: Int] = [:]) -> [String: Any]? {
        let children: [[String: Any]] = pages.enumerated().compactMap { index, page in
            guard page.bookmark != nil else { return nil }
            return [kCGPDFOutlineTitle as String: page.bookmarkTitle(number: numbers[page.id] ?? index + 1), kCGPDFOutlineDestination as String: index + 1]
        }
        return children.isEmpty ? nil : [kCGPDFOutlineChildren as String: children]
    }

    /// Reads a page's saved ink directly: writes are atomic, so reading outside the package actor is safe.
    /// A file that can't be decoded exports as a blank page; the editor sets it aside when the page is opened.
    static func savedInk(_ page: NotebookPage, in package: NotebookPackage) -> PKDrawing {
        guard let data = try? Data(contentsOf: package.inkURL(page.id)) else { return PKDrawing() }
        return (try? NotebookPackage.decodeInk(data)) ?? PKDrawing()
    }
}

extension NotebookExporter.Input {
    /// The ink the editor holds for a page, unsaved, or else what is saved.
    func ink(for page: NotebookPage) -> PKDrawing {
        inMemoryInk[page.id] ?? NotebookExporter.savedInk(page, in: package)
    }

    /// `pages` narrows the export to some of the notebook's pages; nil takes them all.
    @MainActor
    init(document: NotebookDocument, pages: [NotebookPage]? = nil) {
        let chosen = pages ?? document.pages
        var inMemory: [UUID: PKDrawing] = [:]
        for page in chosen { if let ink = document.loadedInk(page.id) { inMemory[page.id] = ink } }
        self.init(title: document.title, pages: chosen, inMemoryInk: inMemory, package: document.package, recordings: document.manifest.recordings,
                  notebook: pages == nil ? nil : document.pages)
    }

    /// The pages `range` of the notebook takes, by their place in it.
    func narrowed(to range: ClosedRange<Int>) -> Self {
        let all = allPages
        let range = range.clamped(to: 0...max(all.count - 1, 0))
        guard !all.isEmpty, range != 0...(all.count - 1) || notebook != nil else { return self }
        var copy = self
        copy.pages = Array(all[range])
        copy.notebook = all
        copy.inMemoryInk = inMemoryInk.filter { id, _ in copy.pages.contains { $0.id == id } }
        return copy
    }
}

