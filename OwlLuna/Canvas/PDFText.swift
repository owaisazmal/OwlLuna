import UIKit
import PDFKit
import PencilKit
import Vision

/// What is selected of a PDF page's own text: the words, and a rectangle for each line of them, in page points.
struct TextSelection: Sendable, Equatable {
    let text: String
    let lines: [CGRect]
}

/// A PDF page's own text: what lies between two points, the word at a point, and the stretch of a line that a
/// highlighter was drawn along. Points and rectangles are in the page's points as it is shown.
enum PDFText {
    static var snapsHighlighter: Bool { UserDefaults.standard.bool(forKey: SettingsKey.snapsHighlighter, default: true) }

    /// The lines of text on a page, each as a rectangle.
    static func lines(on page: PDFPage, pageSize: CGSize) -> [CGRect] {
        page.selection(for: page.bounds(for: .cropBox)).map { rects(of: $0, on: page, pageSize: pageSize) } ?? []
    }

    /// A picture of a page, such as a scan or slides saved as images, has next to no text of its own.
    static func isPicture(withText text: String?) -> Bool {
        (text ?? "").unicodeScalars.count(where: CharacterSet.alphanumerics.contains) < 40
    }

    /// The page drawn on white with what was written on it, its long side 2,400 px like a scan's, for the recogniser to read.
    static func picture(of page: PDFPage) -> UIImage? {
        guard let sheet = page.pageRef else { return nil }
        let shown = PageRenderer.displaySize(of: sheet)
        guard shown.width > 0, shown.height > 0 else { return nil }
        let factor = 2400 / max(shown.width, shown.height)
        let size = CGSize(width: (shown.width * factor).rounded(), height: (shown.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat(scale: 1, opaque: true)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            PageRenderer.drawPDFPage(sheet, in: context.cgContext, size: size, marks: PDFMarks.has(sheet) ? .page(page) : nil)
        }
    }

    /// Where a touch is taken to be in the text: on the line it is on or nearest to, and never past that line's ends.
    /// Given a point off the text, PDFKit picks a letter that can be lines away, or none.
    static func settled(_ point: CGPoint, among lines: [CGRect]) -> (point: CGPoint, line: CGRect)? {
        let sideways = lines.count(where: { $0.width >= $0.height }) * 2 >= lines.count
        func away(_ line: CGRect) -> (CGFloat, CGFloat) {
            let across = max(line.minY - point.y, 0, point.y - line.maxY), along = max(line.minX - point.x, 0, point.x - line.maxX)
            return sideways ? (across, along) : (along, across)
        }
        guard let line = lines.min(by: { away($0) < away($1) }) else { return nil }
        let inside = inner(line)
        let held = CGPoint(x: min(max(point.x, inside.minX), inside.maxX), y: min(max(point.y, inside.minY), inside.maxY))
        return (line.width >= line.height ? CGPoint(x: held.x, y: line.midY) : CGPoint(x: line.midX, y: held.y), line)
    }

    private static func inner(_ line: CGRect) -> CGRect {
        line.insetBy(dx: min(0.5, line.width / 4), dy: min(0.5, line.height / 4))
    }

    /// The text from the letter under one point to the letter under the other, the way text is selected anywhere.
    static func selection(on page: PDFPage, from start: CGPoint, to end: CGPoint, pageSize: CGSize, lines: [CGRect]? = nil) -> TextSelection? {
        let lines = lines ?? Self.lines(on: page, pageSize: pageSize)
        guard let start = settled(start, among: lines)?.point, let end = settled(end, among: lines)?.point else { return nil }
        let toPDF = NotebookFind.transform(of: page, to: pageSize).inverted()
        return page.selection(from: start.applying(toPDF), to: end.applying(toPDF)).flatMap { made(of: $0, on: page, pageSize: pageSize) }
    }

    /// The word under a point, or nil when the point isn't on the text. PDFKit's own `selectionForWord(at:)` needs
    /// a PDFView behind the page and ends the app without one. Here the line is read from its start to the point and
    /// from the point to its end: the letter under the point is where the two meet.
    static func word(on page: PDFPage, at point: CGPoint, pageSize: CGSize, lines: [CGRect]? = nil) -> TextSelection? {
        let lines = lines ?? Self.lines(on: page, pageSize: pageSize)
        guard lines.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }), let (held, line) = settled(point, among: lines),
              let text = page.string as NSString? else { return nil }
        let toPDF = NotebookFind.transform(of: page, to: pageSize).inverted(), inside = inner(line), sideways = line.width >= line.height
        func range(from start: CGPoint, to end: CGPoint) -> NSRange? {
            guard let run = page.selection(from: start.applying(toPDF), to: end.applying(toPDF)), run.numberOfTextRanges(on: page) > 0 else { return nil }
            let range = run.range(at: 0, on: page)
            return range.length > 0 ? range : nil
        }
        let before = range(from: sideways ? CGPoint(x: inside.minX, y: line.midY) : CGPoint(x: line.midX, y: inside.minY), to: held)
        let after = range(from: held, to: sideways ? CGPoint(x: inside.maxX, y: line.midY) : CGPoint(x: line.midX, y: inside.maxY))
        let place: Int
        switch (before, after) {
        case let (before?, after?): place = max(before.location, after.location)
        case let (nil, after?): place = after.location
        case let (before?, nil): place = before.upperBound - 1
        case (nil, nil): return nil
        }
        guard place < text.length else { return nil }
        // A touch on the last half of a word's last letter meets the space after it.
        var word: NSRange?
        text.enumerateSubstrings(in: text.paragraphRange(for: NSRange(location: place, length: 0)), options: [.byWords, .substringNotRequired]) { _, found, _, stop in
            guard NSLocationInRange(place, found) || found.upperBound == place else { return }
            word = found
            stop.pointee = true
        }
        return word.flatMap { page.selection(for: $0) }.flatMap { made(of: $0, on: page, pageSize: pageSize) }
    }

    static func everything(on page: PDFPage, pageSize: CGSize) -> TextSelection? {
        page.selection(for: page.bounds(for: .cropBox)).flatMap { made(of: $0, on: page, pageSize: pageSize) }
    }

    private static func made(of selection: PDFSelection, on page: PDFPage, pageSize: CGSize) -> TextSelection? {
        let lines = rects(of: selection, on: page, pageSize: pageSize)
        let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return lines.isEmpty || text.isEmpty ? nil : TextSelection(text: text, lines: lines)
    }

    private static func rects(of selection: PDFSelection, on page: PDFPage, pageSize: CGSize) -> [CGRect] {
        let toPage = NotebookFind.transform(of: page, to: pageSize)
        return selection.selectionsByLine().map { $0.bounds(for: page).applying(toPage).standardized }.filter { $0.width > 0.5 && $0.height > 0.5 }
    }

    /// Whether a stroke runs the way a highlighter is drawn along a line of text: sideways, without much wander.
    static func runsAlongALine(_ points: [CGPoint]) -> Bool {
        guard let first = points.first, let last = points.last, points.count >= 2 else { return false }
        let span = hypot(last.x - first.x, last.y - first.y)
        guard abs(last.x - first.x) >= 12, abs(last.y - first.y) <= 0.3 * abs(last.x - first.x) else { return false }
        return points.allSatisfy { ShapeRecognizer.distance($0, toSegment: first, last) <= max(0.12 * span, 9) }
    }

    /// The characters of one line of text that a stroke drawn along it passes over, as one rectangle the height of
    /// the line. Nil when the stroke isn't drawn along a line, or there is no text under it.
    static func line(on page: PDFPage, under points: [CGPoint], pageSize: CGSize) -> CGRect? {
        guard runsAlongALine(points) else { return nil }
        let box = ShapeRecognizer.bounds(of: points)
        let middle = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        let reach = max(box.height / 4, 2)
        let band = CGRect(x: box.minX, y: middle - reach, width: box.width, height: reach * 2)
        let toPDF = NotebookFind.transform(of: page, to: pageSize).inverted()
        guard let touched = page.selection(for: band.applying(toPDF).standardized) else { return nil }
        let lines = rects(of: touched, on: page, pageSize: pageSize).filter { $0.width >= 3 && $0.width > $0.height / 2 }
        // Of the lines the band touches, the one the stroke's middle runs through.
        return lines.filter { $0.minY - 1 <= middle && middle <= $0.maxY + 1 }.min { abs($0.midY - middle) < abs($1.midY - middle) }
    }
}

/// What the recogniser read off a picture of a page: its lines in reading order, and each word's box shared out along its
/// letters, a space taking the gap. Boxes are fractions of the page, measured from the top, until `on(_:)`.
struct PictureText: Sendable {
    struct Line: Sendable {
        let letters: [Character]
        /// One for each letter, each as tall as the line.
        let boxes: [CGRect]
        let rect: CGRect

        func span(_ range: ClosedRange<Int>) -> CGRect {
            let first = boxes[range.lowerBound], last = boxes[range.upperBound]
            return CGRect(x: first.minX, y: rect.minY, width: last.maxX - first.minX, height: rect.height)
        }
    }

    let lines: [Line]

    init(_ read: [RecognizedLine]) {
        lines = NotebookFind.inReadingOrder(read.compactMap(Self.line), by: \.rect)
    }

    private init(lines: [Line]) {
        self.lines = lines
    }

    private static func line(_ read: RecognizedLine) -> Line? {
        let string = read.text.string
        var boxes: [CGRect?] = string.indices.map { index in
            guard !string[index].isWhitespace, let box = try? read.text.boundingBox(for: index..<string.index(after: index))?.boundingBox,
                  box.width > 0, box.height > 0 else { return nil }
            return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
        var start = 0
        while start < boxes.count {
            var end = start + 1
            while end < boxes.count, boxes[end] != nil, boxes[end] == boxes[start] { end += 1 }
            if let box = boxes[start], end - start > 1 {
                let share = box.width / CGFloat(end - start)
                for index in start..<end { boxes[index] = CGRect(x: box.minX + share * CGFloat(index - start), y: box.minY, width: share, height: box.height) }
            }
            start = end
        }
        let found = boxes.compactMap { $0 }
        guard let first = found.first else { return nil }
        let rect = found.reduce(first) { $0.union($1) }
        var lead = rect.minX
        let filled = boxes.indices.map { index -> CGRect in
            if let box = boxes[index] {
                lead = box.maxX
                return CGRect(x: box.minX, y: rect.minY, width: box.width, height: rect.height)
            }
            let next = boxes[(index + 1)...].lazy.compactMap { $0 }.first?.minX ?? lead
            return CGRect(x: lead, y: rect.minY, width: max(next - lead, 0), height: rect.height)
        }
        return Line(letters: Array(string), boxes: filled, rect: rect)
    }

    /// In the points of a page this size. The picture that was read filled the page.
    func on(_ size: CGSize) -> PictureText {
        let scale = CGAffineTransform(scaleX: size.width, y: size.height)
        return PictureText(lines: lines.map { Line(letters: $0.letters, boxes: $0.boxes.map { $0.applying(scale) }, rect: $0.rect.applying(scale)) })
    }

    /// The line a point is on or nearest to, and the letter of it the point is at.
    private func place(_ point: CGPoint) -> (line: Int, letter: Int)? {
        let rects = lines.map(\.rect)
        guard let (held, rect) = PDFText.settled(point, among: rects), let line = rects.firstIndex(of: rect) else { return nil }
        let boxes = lines[line].boxes
        return (line, boxes.firstIndex { $0.maxX >= held.x } ?? boxes.count - 1)
    }

    func selection(from start: CGPoint, to end: CGPoint) -> TextSelection? {
        guard let start = place(start), let end = place(end) else { return nil }
        return start <= end ? made(from: start, through: end) : made(from: end, through: start)
    }

    func word(at point: CGPoint) -> TextSelection? {
        guard lines.contains(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }), let place = place(point) else { return nil }
        let text = String(lines[place.line].letters)
        var word: Range<Int>?
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, found, _, stop in
            let range = text.distance(from: text.startIndex, to: found.lowerBound)..<text.distance(from: text.startIndex, to: found.upperBound)
            guard range.contains(place.letter) || range.upperBound == place.letter else { return }
            word = range
            stop = true
        }
        return word.flatMap { made(from: (place.line, $0.lowerBound), through: (place.line, $0.upperBound - 1)) }
    }

    var everything: TextSelection? {
        guard let last = lines.last else { return nil }
        return made(from: (0, 0), through: (lines.count - 1, last.letters.count - 1))
    }

    /// A rectangle for each line, leaving out the spaces at either end of it.
    private func made(from first: (line: Int, letter: Int), through last: (line: Int, letter: Int)) -> TextSelection? {
        var text: [String] = [], rects: [CGRect] = []
        for index in first.line...last.line {
            let line = lines[index]
            let taken = (index == first.line ? first.letter : 0)...(index == last.line ? last.letter : line.letters.count - 1)
            guard let low = taken.first(where: { !line.letters[$0].isWhitespace }), let high = taken.last(where: { !line.letters[$0].isWhitespace }) else { continue }
            text.append(String(line.letters[low...high]))
            rects.append(line.span(low...high))
        }
        return text.isEmpty ? nil : TextSelection(text: text.joined(separator: "\n"), lines: rects)
    }

    /// The letters of one line that a highlighter stroke drawn along it passes over, as one rectangle the height of the line.
    func line(under points: [CGPoint]) -> CGRect? {
        guard PDFText.runsAlongALine(points) else { return nil }
        let box = ShapeRecognizer.bounds(of: points)
        let middle = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        let along = lines.filter { $0.rect.minY - 1 <= middle && middle <= $0.rect.maxY + 1 && $0.rect.minX <= box.maxX && box.minX <= $0.rect.maxX }
        guard let line = along.min(by: { abs($0.rect.midY - middle) < abs($1.rect.midY - middle) }) else { return nil }
        // A letter is passed over when the stroke reaches its middle.
        let passed = line.boxes.indices.filter { !line.letters[$0].isWhitespace && box.minX <= line.boxes[$0].midX && line.boxes[$0].midX <= box.maxX }
        guard let low = passed.first, let high = passed.last else { return nil }
        let rect = line.span(low...high)
        return rect.width >= 3 && rect.width > rect.height / 2 ? rect : nil
    }
}

/// Reads PDF text off the main thread, keeping the documents it has opened and what the recogniser read off pages
/// that are pictures of pages. PDFKit's objects never leave it.
actor PDFTextReader {
    enum Request: Sendable {
        case range(from: CGPoint, to: CGPoint)
        case word(at: CGPoint)
        case everything
    }

    private var documents: [String: PDFDocument] = [:]
    private var opened: [String] = []
    /// The lines of the page last selected in, so a drag reads them once.
    private var lines: (key: String, rects: [CGRect])?
    private var pictures: [String: PictureText] = [:]
    private var printed: Set<String> = []

    private func lines(of page: PDFPage, file: URL, index: Int, pageSize: CGSize) -> [CGRect] {
        let key = "\(file.lastPathComponent)#\(index)|\(pageSize)"
        if lines?.key != key { lines = (key, PDFText.lines(on: page, pageSize: pageSize)) }
        return lines?.rects ?? []
    }

    private func page(_ file: URL, _ index: Int) -> PDFPage? {
        let key = file.path(percentEncoded: false)
        if documents[key] == nil {
            documents[key] = PDFDocument(url: file)
            opened.append(key)
            if opened.count > 3 { documents[opened.removeFirst()] = nil }
        }
        return documents[key]?.page(at: index)
    }

    /// What the recogniser reads off a page that is a picture of a page, read once. Nil for a page with text of its own.
    private func picture(_ page: PDFPage, file: URL, index: Int) async -> PictureText? {
        let key = "\(file.path(percentEncoded: false))#\(index)"
        if let read = pictures[key] { return read }
        guard !printed.contains(key) else { return nil }
        guard PDFText.isPicture(withText: page.string) else {
            printed.insert(key)
            return nil
        }
        guard let image = PDFText.picture(of: page), let read = await NotebookFind.readInBackground(image) else { return nil }
        if pictures.count > 12 { pictures.removeAll() }
        let text = PictureText(read)
        pictures[key] = text
        return text
    }

    /// Reads a page that is a picture of a page ahead of the first touch on it.
    func prepare(file: URL, index: Int) async {
        if let page = page(file, index) { _ = await picture(page, file: file, index: index) }
    }

    func select(_ request: Request, file: URL, index: Int, pageSize: CGSize) async -> TextSelection? {
        guard let page = page(file, index) else { return nil }
        if let picture = await picture(page, file: file, index: index)?.on(pageSize) {
            switch request {
            case .range(let start, let end): return picture.selection(from: start, to: end)
            case .word(let point): return picture.word(at: point)
            case .everything: return picture.everything
            }
        }
        switch request {
        case .range(let start, let end):
            return PDFText.selection(on: page, from: start, to: end, pageSize: pageSize, lines: lines(of: page, file: file, index: index, pageSize: pageSize))
        case .word(let point):
            return PDFText.word(on: page, at: point, pageSize: pageSize, lines: lines(of: page, file: file, index: index, pageSize: pageSize))
        case .everything: return PDFText.everything(on: page, pageSize: pageSize)
        }
    }

    func line(under points: [CGPoint], file: URL, index: Int, pageSize: CGSize) async -> CGRect? {
        guard let page = page(file, index) else { return nil }
        if let picture = await picture(page, file: file, index: index) { return picture.on(pageSize).line(under: points) }
        return PDFText.line(on: page, under: points, pageSize: pageSize)
    }
}

