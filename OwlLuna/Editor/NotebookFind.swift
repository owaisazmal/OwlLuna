import UIKit
import PDFKit
import Vision
import PencilKit

/// One place the words being looked for were found: a rectangle on a page, in page points.
struct FindMatch: Hashable, Sendable {
    let pageID: UUID
    let page: Int
    let rect: CGRect
}

/// A line the recogniser read, kept so each new search can ask it where its words are.
struct RecognizedLine: @unchecked Sendable {
    let text: VNRecognizedText
}

/// Where the query is marked on a page, and the text of each source it was looked for in.
struct FindRects: Sendable {
    var texts: [String] = []
    var rects: [CGRect] = []

    /// Every term is on the page, each within one source's text.
    func holds(_ search: SearchQuery) -> Bool {
        search.terms.allSatisfy { term in texts.contains { $0.localizedStandardContains(term) } }
    }

    static func += (found: inout FindRects, more: FindRects) {
        found.texts += more.texts
        found.rects += more.rects
    }
}

/// Pieces of text joined by single spaces, each word kept with its place in its piece.
struct FlatText {
    let pieces: [String]
    private(set) var text = ""
    private var words: [(piece: Int, range: Range<String.Index>, start: Int, length: Int)] = []

    init(_ pieces: [String]) {
        self.pieces = pieces
        var count = 0
        for (index, piece) in pieces.enumerated() {
            for word in piece.split(whereSeparator: \.isWhitespace) {
                if count > 0 {
                    text.append(" ")
                    count += 1
                }
                words.append((index, word.startIndex..<word.endIndex, count, word.utf16.count))
                text.append(contentsOf: word)
                count += word.utf16.count
            }
        }
    }

    /// What a range of the text covers of each piece, in order.
    func spans(of range: Range<String.Index>) -> [(piece: Int, range: Range<String.Index>)] {
        let lower = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.utf16.distance(from: text.startIndex, to: range.upperBound)
        var spans: [(piece: Int, range: Range<String.Index>)] = []
        for word in words where word.start < upper && lower < word.start + word.length {
            let utf16 = pieces[word.piece].utf16
            let from = utf16.index(word.range.lowerBound, offsetBy: max(lower - word.start, 0))
            let to = utf16.index(word.range.lowerBound, offsetBy: min(upper - word.start, word.length))
            if let last = spans.last, last.piece == word.piece {
                spans[spans.count - 1].range = last.range.lowerBound..<to
            } else {
                spans.append((word.piece, from..<to))
            }
        }
        return spans
    }
}

/// Where words are on a page: in what was typed, in a PDF's own text, and in what the recogniser reads of ink, scans and pictures.
enum NotebookFind {
    static func contains(_ text: String, anyOf search: SearchQuery) -> Bool {
        search.terms.contains { text.localizedStandardContains($0) }
    }

    /// A text box that holds a term is marked whole; presenter notes count toward the page but aren't marked.
    static func typed(_ search: SearchQuery, on page: NotebookPage) -> FindRects {
        var found = FindRects(texts: [SearchQuery.collapsed(page.notes)])
        guard page.hasItems else { return found }
        for item in page.items {
            guard let box = item.text else { continue }
            let text = SearchQuery.collapsed(box.string)
            found.texts.append(text)
            if contains(text, anyOf: search) { found.rects.append(item.boundingBox) }
        }
        return found
    }

    /// The phrase and word-start terms, or a term anywhere it starts no word; overlaps merged.
    static func ranges(of search: SearchQuery, in text: String) -> [Range<String.Index>] {
        let words = search.highlights(in: text)
        let inside = search.terms.filter { term in !words.contains { text[$0].localizedStandardRange(of: term)?.lowerBound == $0.lowerBound } }
        let ranges = words + inside.flatMap { SearchQuery.ranges(of: $0, in: text) }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { merged, range in
            if let last = merged.last, range.lowerBound < last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
    }

    static func read(_ image: UIImage) -> [RecognizedLine]? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) } catch { return nil }
        return request.results?.compactMap { $0.topCandidates(1).first.map(RecognizedLine.init) } ?? []
    }

    /// The image the lines were read from filled the page, so their boxes are fractions of it, measured from the bottom.
    static func rects(for search: SearchQuery, in lines: [RecognizedLine], pageSize: CGSize) -> FindRects {
        let flat = FlatText(lines.map(\.text.string))
        var rects: [CGRect] = []
        for span in ranges(of: search, in: flat.text).flatMap(flat.spans) {
            guard let box = try? lines[span.piece].text.boundingBox(for: span.range)?.boundingBox else { continue }
            let rect = CGRect(x: box.minX * pageSize.width, y: (1 - box.maxY) * pageSize.height,
                              width: box.width * pageSize.width, height: box.height * pageSize.height)
            if !rects.contains(rect) { rects.append(rect) }
        }
        return FindRects(texts: [flat.text], rects: rects)
    }

    static func pdfRects(for search: SearchQuery, on page: PDFPage, pageSize: CGSize) -> FindRects {
        guard let string = page.string else { return FindRects() }
        let toPage = transform(of: page, to: pageSize), flat = FlatText([string])
        var rects: [CGRect] = []
        for span in ranges(of: search, in: flat.text).flatMap(flat.spans) {
            for line in page.selection(for: NSRange(span.range, in: string))?.selectionsByLine() ?? [] {
                let rect = line.bounds(for: page).applying(toPage).standardized
                if rect.width > 0, rect.height > 0 { rects.append(rect) }
            }
        }
        return FindRects(texts: [flat.text], rects: rects)
    }

    /// From a PDF page's own space to the page as it is shown: the same turn and flip the page is drawn with.
    static func transform(of page: PDFPage, to size: CGSize) -> CGAffineTransform {
        let box = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let display = rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
        var transform = CGAffineTransform(translationX: 0, y: size.height)
            .scaledBy(x: size.width / max(display.width, 1), y: -size.height / max(display.height, 1))
        switch rotation {
        case 90: transform = transform.translatedBy(x: 0, y: display.height).rotated(by: -.pi / 2)
        case 180: transform = transform.translatedBy(x: display.width, y: display.height).rotated(by: .pi)
        case 270: transform = transform.translatedBy(x: display.width, y: 0).rotated(by: .pi / 2)
        default: break
        }
        return transform.translatedBy(x: -box.minX, y: -box.minY)
    }

    /// Changes whenever the ink does, without reading every stroke.
    static func fingerprint(_ ink: PKDrawing) -> String {
        "\(ink.strokes.count)|\(ink.bounds)|\(ink.strokes.last?.path.creationDate.timeIntervalSince1970 ?? 0)"
    }

    /// Top to bottom, then left to right, the way the page is read.
    static func inReadingOrder(_ rects: [CGRect]) -> [CGRect] {
        inReadingOrder(rects) { $0 }
    }

    static func inReadingOrder<Item>(_ items: [Item], by rect: (Item) -> CGRect) -> [Item] {
        items.sorted {
            let one = rect($0), other = rect($1)
            return abs(one.midY - other.midY) > min(one.height, other.height) / 2 ? one.midY < other.midY : one.minX < other.minX
        }
    }
}

/// Does the reading off the main thread, and keeps what it has read so the next search of the same page is quick.
actor FindReader {
    private var lines: [String: [RecognizedLine]] = [:]
    private var pdfs: [String: PDFDocument] = [:]

    func inkRects(for search: SearchQuery, page: NotebookPage, ink: PKDrawing, assets: URL) -> FindRects {
        guard !ink.strokes.isEmpty else { return FindRects() }
        // A whiteboard is read as the part of it that has something on it, and what is found is put back where it lies.
        let piece = Whiteboard.whole(page, ink: ink)
        let key = "ink-\(page.id.uuidString)-\(NotebookFind.fingerprint(ink))" + (piece.cut == nil ? "" : "-\(piece.inkRect)")
        var found = rects(for: search, key: key, pageSize: piece.size) {
            PageRenderer.image(of: piece, ink: ink, assets: assets, width: Whiteboard.readingWidth(for: piece), includeBackground: false)
        }
        guard let cut = piece.cut else { return found }
        found.rects = found.rects.map { $0.offsetBy(dx: cut.x, dy: cut.y) }
        return found
    }

    func pictureRects(for search: SearchQuery, file: URL, pageSize: CGSize) -> FindRects {
        rects(for: search, key: "picture-\(file.lastPathComponent)", pageSize: pageSize) { UIImage(contentsOfFile: file.path(percentEncoded: false)) }
    }

    /// A placed picture is read as it shows, cropped, and what is found is taken through its turn to where it lies.
    func placedPictureRects(for search: SearchQuery, item: PageItem, assets: URL) -> FindRects {
        guard let file = item.assetFile, let key = item.readingKey else { return FindRects() }
        var found = rects(for: search, key: "item-\(key)", pageSize: item.size) {
            PageItemRenderer.image(file, assets: assets, crop: item.crop, cached: false).map(UIImage.init(cgImage:))
        }
        found.rects = found.rects.map { $0.applying(item.placement) }
        return found
    }

    private func rects(for search: SearchQuery, key: String, pageSize: CGSize, image: () -> UIImage?) -> FindRects {
        if lines[key] == nil {
            guard let image = image(), let read = NotebookFind.read(image) else { return FindRects() }
            if lines.count > 400 { lines.removeAll() }
            lines[key] = read
        }
        return NotebookFind.rects(for: search, in: lines[key] ?? [], pageSize: pageSize)
    }

    func pdfRects(for search: SearchQuery, file: URL, index: Int, pageSize: CGSize) -> FindRects {
        let key = file.path(percentEncoded: false)
        if pdfs[key] == nil { pdfs[key] = PDFDocument(url: file) }
        guard let page = pdfs[key]?.page(at: index) else { return FindRects() }
        guard PDFText.isPicture(withText: page.string) else { return NotebookFind.pdfRects(for: search, on: page, pageSize: pageSize) }
        return rects(for: search, key: "pdf-\(file.lastPathComponent)#\(index)", pageSize: pageSize) { PDFText.picture(of: page) }
    }
}

/// Find in the notebook that is open: what is being looked for, where it was found, and which match is shown.
@MainActor
@Observable
final class NotebookFinder {
    private(set) var query = ""
    private(set) var matches: [FindMatch] = []
    private(set) var current: FindMatch?
    private(set) var isSearching = false
    @ObservationIgnored private let document: NotebookDocument
    @ObservationIgnored private let reader = FindReader()
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Called when the matches or the one being shown change.
    @ObservationIgnored var onChange: (() -> Void)?
    /// The page a search starts from, so the first match shown is the nearest one ahead.
    @ObservationIgnored var startPage: () -> Int = { 0 }
    @ObservationIgnored var delay = Duration.milliseconds(300)

    init(document: NotebookDocument) {
        self.document = document
    }

    var position: Int? { current.flatMap(matches.firstIndex(of:)) }

    func search(_ text: String) {
        task?.cancel()
        query = text
        let search = SearchQuery(text)
        guard !search.isEmpty else { return reset() }
        isSearching = true
        task = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.run(search)
        }
    }

    func clear() {
        task?.cancel()
        query = ""
        reset()
    }

    private func reset() {
        matches = []
        current = nil
        isSearching = false
        onChange?()
    }

    /// Reads from the page being looked at to the end, then from the start, so the nearest match ahead comes first.
    private func run(_ search: SearchQuery) async {
        let pages = document.pages
        guard !pages.isEmpty else { return reset() }
        let start = min(max(startPage(), 0), pages.count - 1)
        var found: [Int: [FindMatch]] = [:]
        matches = []
        current = nil
        onChange?()
        for index in Array(start..<pages.count) + Array(0..<start) {
            let rects = await rects(for: search, on: pages[index])
            if Task.isCancelled { return }
            guard !rects.isEmpty else { continue }
            found[index] = rects.map { FindMatch(pageID: pages[index].id, page: index, rect: $0) }
            matches = found.keys.sorted().flatMap { found[$0] ?? [] }
            if current == nil { current = found[index]?.first }
            onChange?()
        }
        isSearching = false
        let count = matches.count
        AccessibilityNotification.Announcement(count == 0 ? String(localized: "No matches") : String(localized: "\(count) matches")).post()
    }

    /// Marks only a page that has every term somewhere on it.
    private func rects(for search: SearchQuery, on page: NotebookPage) async -> [CGRect] {
        let package = document.package, unsaved = document.hasUnsavedInk(page.id)
        // What the page was last read as, while that is still what is on it, says whether it is worth reading again.
        if !unsaved, let text = await package.readText(page.id), text.hasPrefix(HandwritingIndexer.header(for: page)),
           !search.matches(SearchQuery.searchable(text)) { return [] }
        var found = NotebookFind.typed(search, on: page)
        switch page.background {
        case .pdf(let file, let index) where page.hasPDFText:
            found += await reader.pdfRects(for: search, file: package.assetURL(file), index: index, pageSize: page.size)
        case .image(let file) where page.hasPicture:
            found += await reader.pictureRects(for: search, file: package.assetURL(file), pageSize: page.size)
        default:
            break
        }
        let pictures = page.placedPictures
        // What a picture showed was kept when it was read, and it can't change, so one without any of the words is passed over.
        let read = pictures.isEmpty ? [:] : await package.readPictureText(page.id)
        for item in pictures
        where read[item.readingKey ?? ""].map({ NotebookFind.contains(SearchQuery.searchable($0.joined(separator: "\n")), anyOf: search) }) ?? true {
            found += await reader.placedPictureRects(for: search, item: item, assets: package.assetsDirectory)
        }
        if page.inkHash != nil || unsaved {
            let ink = await document.ink(page.id)
            found += await reader.inkRects(for: search, page: page, ink: ink, assets: package.assetsDirectory)
        }
        return found.holds(search) ? NotebookFind.inReadingOrder(found.rects) : []
    }

    /// The next match, or the one before; past either end it comes round again.
    func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let index = ((position ?? (delta > 0 ? -1 : 0)) + delta + matches.count) % matches.count
        current = matches[index]
        onChange?()
        AccessibilityNotification.Announcement(String(localized: "Match \(index + 1) of \(matches.count), page \(matches[index].page + 1)")).post()
    }
}
