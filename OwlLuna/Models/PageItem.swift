import Foundation
import CoreGraphics

/// Typed text on a page. The box's width is the item's; its height follows the text.
struct TextBox: Sendable, Hashable {
    enum Tint: String, Sendable, CaseIterable, Identifiable {
        case ink, tomato, cobalt, moss, plum
        var id: String { rawValue }
    }

    enum Alignment: String, Sendable, CaseIterable, Identifiable {
        case leading, center, trailing
        var id: String { rawValue }
    }

    enum Face: String, Sendable, CaseIterable, Identifiable {
        case system, serif, mono, fraunces
        var id: String { rawValue }
    }

    /// Every line of a box that is a list is an item of it.
    enum List: String, Sendable, CaseIterable, Identifiable {
        case bullet, dash, number, check
        var id: String { rawValue }
    }

    /// The highlighter's tints, laid behind the words.
    enum Highlight: String, Sendable, CaseIterable, Identifiable {
        case yellow, green, pink, blue
        var id: String { rawValue }
    }

    static let fontSizes: ClosedRange<CGFloat> = 8...200

    var string: String
    var fontSize: CGFloat = 17
    var isBold = false
    var tint = Tint.ink
    var alignment = Alignment.leading
    var face = Face.system
    var isItalic = false
    var isUnderlined = false
    var list: List?
    var highlight: Highlight?
    /// The lines of a checklist that are ticked, counted from 0. Kept while the box is another kind of list.
    var checked: Set<Int> = []
}

extension TextBox {
    /// The whole point `steps` up or down from a size, the first step from between two points going to the nearer one that way.
    static func size(_ size: CGFloat, steppedBy steps: Int) -> CGFloat {
        guard steps != 0 else { return size }
        let first = steps > 0 ? size.rounded(.down) + 1 : size.rounded(.up) - 1
        return min(max(first + CGFloat(steps - steps.signum()), fontSizes.lowerBound), fontSizes.upperBound)
    }

    var lines: [String] { (string as NSString).components(separatedBy: "\n") }

    /// Whether any of the text is written between dollar signs, to be set as a formula.
    var hasFormulas: Bool { MathRun.find(in: string as NSString).contains { !$0.isEscape } }

    /// A line with nothing written on it is passed over by a list: it has no bullet, dash, number or box.
    static func isItem(_ line: String) -> Bool {
        !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Each line's number in a numbered list; one that is passed over has none.
    var numbers: [Int?] { Self.numbers(of: lines) }

    static func numbers(of lines: [String]) -> [Int?] {
        var next = 0
        return lines.map { line in
            guard isItem(line) else { return nil }
            next += 1
            return next
        }
    }

    mutating func toggleCheck(line: Int) {
        if checked.remove(line) == nil { checked.insert(line) }
    }

    /// Replaces part of the text, each tick staying with the line it was on. New lines and emptied ones have none.
    mutating func replaceCharacters(in range: NSRange, with text: String) {
        let old = string as NSString, new = text as NSString
        checked = Self.carried(checked, in: old, range: range, with: new, NSRange(location: 0, length: new.length))
        string = old.replacingCharacters(in: range, with: text)
        dropStrayChecks()
    }

    /// The same, for text that was changed somewhere: what the old and new share at either end is what was kept.
    mutating func carryChecks(to newString: String) {
        let old = string as NSString, new = newString as NSString
        var start = 0
        while start < old.length, start < new.length, old.character(at: start) == new.character(at: start) { start += 1 }
        var end = 0
        while end < old.length - start, end < new.length - start,
              old.character(at: old.length - 1 - end) == new.character(at: new.length - 1 - end) { end += 1 }
        checked = Self.carried(checked, in: old, range: NSRange(location: start, length: old.length - start - end), with: new,
                               NSRange(location: start, length: new.length - start - end))
        string = newString
        dropStrayChecks()
    }

    /// Only the ticks of lines that are there and are items.
    fileprivate mutating func dropStrayChecks() {
        guard !checked.isEmpty else { return }
        let lines = lines
        checked = checked.filter { lines.indices.contains($0) && Self.isItem(lines[$0]) }
    }

    /// Ticks set against the lines of `old`, on the same lines of `new`: a line both have keeps its tick, and a run between
    /// two of those that was changed line for line keeps its ticks in order. The rest are dropped.
    static func checks(_ checked: Set<Int>, carriedFrom old: String, to new: String) -> Set<Int> {
        guard !checked.isEmpty else { return checked }
        let a = (old as NSString).components(separatedBy: "\n"), b = (new as NSString).components(separatedBy: "\n")
        var head = 0, tail = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let n = a.count - head - tail, m = b.count - head - tail
        guard n * m <= 1_000_000 else {
            var box = TextBox(string: old)
            box.checked = checked
            box.carryChecks(to: new)
            return box.checked
        }
        let w = m + 1
        var common = [Int32](repeating: 0, count: (n + 1) * w)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                common[i * w + j] = a[head + i] == b[head + j] ? common[(i + 1) * w + j + 1] + 1 : max(common[(i + 1) * w + j], common[i * w + j + 1])
            }
        }
        var matches = (0..<head).map { ($0, $0) }, i = 0, j = 0
        while i < n, j < m {
            if a[head + i] == b[head + j] {
                matches.append((head + i, head + j))
                i += 1
                j += 1
            } else if common[(i + 1) * w + j] >= common[i * w + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        matches += (0..<tail).map { (a.count - tail + $0, b.count - tail + $0) }
        var moved: Set<Int> = [], last = (-1, -1)
        for match in matches + [(a.count, b.count)] {
            let gap = match.0 - last.0 - 1
            if gap == match.1 - last.1 - 1 {
                for k in 0..<gap where checked.contains(last.0 + 1 + k) { moved.insert(last.1 + 1 + k) }
            }
            if match.0 < a.count, checked.contains(match.0) { moved.insert(match.1) }
            last = match
        }
        return moved
    }

    private static func newlines(in text: NSString, _ range: NSRange) -> Int {
        var count = 0
        for index in range.location..<NSMaxRange(range) where text.character(at: index) == 10 { count += 1 }
        return count
    }

    /// A tick goes with the start of its line. A line loses it when its start is cut away along with its end, or when
    /// it is left joined onto the end of another line.
    private static func carried(_ checked: Set<Int>, in old: NSString, range: NSRange, with new: NSString, _ inserted: NSRange) -> Set<Int> {
        guard !checked.isEmpty else { return checked }
        let line = newlines(in: old, NSRange(location: 0, length: range.location)), removed = newlines(in: old, range), added = newlines(in: new, inserted)
        let atStart = range.location == 0 || old.character(at: range.location - 1) == 10
        let breaks = atStart || inserted.length > 0 && new.character(at: NSMaxRange(inserted) - 1) == 10
        let lastStartsAtEnd = removed > 0 && old.character(at: NSMaxRange(range) - 1) == 10
        return Set(checked.compactMap { ticked in
            if ticked < line || ticked == line && !atStart { return ticked }
            if ticked == line { return removed == 0 ? line + added : nil }
            if ticked < line + removed { return nil }
            if ticked == line + removed { return lastStartsAtEnd && breaks ? ticked + added - removed : nil }
            return ticked + added - removed
        })
    }
}

/// A tab on a page that opens another page, a page of another notebook, or a web address.
struct PageLink: Sendable, Hashable {
    enum Destination: Sendable, Hashable {
        case page(UUID)
        /// `name` is the notebook's title when the link was made, for when the notebook can't be looked up.
        case notebook(UUID, page: UUID?, name: String)
        case web(URL)
    }

    var destination: Destination
    /// Empty while the link is named after what it opens.
    var label = ""

    init(_ destination: Destination, label: String = "") {
        self.destination = destination
        self.label = label
    }

    init(target: UUID, label: String = "") {
        self.init(.page(target), label: label)
    }

    /// The page of this notebook the link opens, if that is what it opens.
    var target: UUID? {
        if case .page(let id) = destination { return id }
        return nil
    }
}

/// Reading a web address the way someone types it.
enum WebAddress {
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), host.contains(".") || host == "localhost" else { return nil }
        return url
    }

    /// "example.com/guide" for "https://www.example.com/guide".
    static func display(_ url: URL) -> String {
        var host = url.host() ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path()
        return path.count > 1 && path.count <= 24 ? host + path : host
    }
}

/// The colours study tape comes in. Raw values are stored in notebooks.
enum TapeColor: String, Sendable, CaseIterable, Identifiable {
    case mustard, rose, sage, sky
    var id: String { rawValue }
}

/// A picture, sticker, text box or link placed on a page, under the ink, or a strip of study tape over it.
/// Geometry is in page points.
struct PageItem: Sendable, Hashable, Identifiable {
    enum Content: Sendable, Hashable {
        case image(file: String)
        case sticker(String)
        case text(TextBox)
        case link(PageLink)
        /// Covers what is under it, ink included, until it is tapped.
        case tape(TapeColor)
        /// Made by a newer version; kept as read and not drawn.
        case unknown
    }

    var id: UUID
    var content: Content
    var center: CGPoint
    var size: CGSize
    var rotation: CGFloat = 0
    var raw: [String: JSONValue] = [:]

    init(id: UUID = UUID(), content: Content, center: CGPoint, size: CGSize, rotation: CGFloat = 0) {
        self.id = id
        self.content = content
        self.center = center
        self.size = size
        self.rotation = rotation
    }

    static let minimumSide: CGFloat = 24
    /// The narrowest a text box or a strip of tape is made by hand.
    static let minimumWidth: CGFloat = 40

    var sticker: Sticker? {
        if case .sticker(let name) = content { return Sticker(rawValue: name) }
        return nil
    }

    var assetFile: String? {
        if case .image(let file) = content { return file }
        return nil
    }

    var text: TextBox? {
        if case .text(let box) = content { return box }
        return nil
    }

    var link: PageLink? {
        if case .link(let link) = content { return link }
        return nil
    }

    var tape: TapeColor? {
        if case .tape(let color) = content { return color }
        return nil
    }

    /// Study tape lies over the ink; everything else lies under it.
    var isOverInk: Bool { tape != nil }

    /// The sticker of your own this picture was placed from, so placing it again reuses the same file.
    var source: String? {
        get { raw["source"]?.stringValue }
        set { raw["source"] = newValue.map(JSONValue.string) }
    }

    static let wholePicture = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The part of a picture that shows, in its unit square from the top left. Nil shows all of it; the file is never cut.
    var crop: CGRect? {
        get {
            guard let values = raw["crop"]?.arrayValue?.compactMap(\.doubleValue), values.count == 4, values.allSatisfy(\.isFinite) else { return nil }
            let rect = Self.inPicture(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
            return rect.isNull || rect.width <= 0 || rect.height <= 0 || Self.isWhole(rect) ? nil : rect
        }
        set { raw["crop"] = newValue.flatMap { Self.isWhole($0) ? nil : .array([$0.minX, $0.minY, $0.width, $0.height].map { .number(Double($0)) }) } }
    }

    static func isWhole(_ crop: CGRect) -> Bool {
        abs(crop.minX) < 1e-4 && abs(crop.minY) < 1e-4 && abs(crop.maxX - 1) < 1e-4 && abs(crop.maxY - 1) < 1e-4
    }

    /// Cut to the picture, and left exactly as it is when it is already inside it.
    private static func inPicture(_ crop: CGRect) -> CGRect {
        wholePicture.contains(crop) ? crop : crop.intersection(wholePicture)
    }

    /// Shows `newCrop` of the picture, or all of it for nil. What still shows stays where it was on the page, turned or not.
    func cropped(to newCrop: CGRect?) -> PageItem {
        let old = crop ?? Self.wholePicture, new = Self.inPicture(newCrop ?? Self.wholePicture)
        guard !new.isNull, new.width > 0, new.height > 0 else { return self }
        let whole = CGSize(width: size.width / old.width, height: size.height / old.height)
        let dx = (new.midX - old.midX) * whole.width, dy = (new.midY - old.midY) * whole.height
        var copy = self
        copy.size = CGSize(width: new.width * whole.width, height: new.height * whole.height)
        copy.center = CGPoint(x: center.x + dx * cos(rotation) - dy * sin(rotation), y: center.y + dx * sin(rotation) + dy * cos(rotation))
        copy.crop = new
        return copy
    }

    /// Whether a point on the page falls on the item, allowing for its rotation.
    func contains(_ point: CGPoint, slop: CGFloat = 0) -> Bool {
        let dx = point.x - center.x, dy = point.y - center.y
        let x = dx * cos(-rotation) - dy * sin(-rotation), y = dx * sin(-rotation) + dy * cos(-rotation)
        return abs(x) <= size.width / 2 + slop && abs(y) <= size.height / 2 + slop
    }

    /// Scaled about its centre, a text box with its type, as far as `scales(limit:)` allows.
    func scaled(by factor: CGFloat, limit: CGFloat) -> PageItem {
        let scales = scales(limit: limit), clamped = min(max(factor, scales.lowerBound), scales.upperBound)
        var copy = self
        copy.size = CGSize(width: size.width * clamped, height: size.height * clamped)
        if case .text(var box) = content {
            box.fontSize = min(max(box.fontSize * clamped, TextBox.fontSizes.lowerBound), TextBox.fontSizes.upperBound)
            copy.content = .text(box)
            copy.size = CGSize(width: copy.size.width, height: box.height(width: copy.size.width))
        }
        return copy
    }

    /// No smaller than a fingertip can grab or larger than `limit` on its long side. A text box is held by its type size and width instead.
    private func scales(limit: CGFloat) -> ClosedRange<CGFloat> {
        guard let text else {
            let long = max(size.width, size.height), short = max(min(size.width, size.height), 1)
            return Self.minimumSide / short...max(limit / long, Self.minimumSide / short)
        }
        let sizes = TextBox.fontSizes, type = max(text.fontSize, 1), width = max(size.width, 1)
        return min(max(sizes.lowerBound / type, Self.minimumWidth / width), 1)...max(min(sizes.upperBound / type, limit / width), 1)
    }

    /// A new size with one point of the box held still: (0, 0) is its top leading corner, (0.5, 0.5) its centre.
    func resized(to newSize: CGSize, holding unit: CGPoint = .zero) -> PageItem {
        let dx = (newSize.width - size.width) * (0.5 - unit.x), dy = (newSize.height - size.height) * (0.5 - unit.y)
        var copy = self
        copy.size = newSize
        copy.center = CGPoint(x: center.x + dx * cos(rotation) - dy * sin(rotation), y: center.y + dx * sin(rotation) + dy * cos(rotation))
        return copy
    }

    /// A text box as tall as its text needs at its width, growing downwards; `typed`, as tall as the editor needs.
    func fittedToText(typed: Bool = false) -> PageItem {
        guard let text else { return self }
        return resized(to: CGSize(width: size.width, height: text.height(width: size.width, typed: typed)))
    }

    init?(json: JSONValue) {
        guard let object = json.objectValue, let id = object["id"]?.uuidValue,
              let x = object["x"]?.doubleValue, let y = object["y"]?.doubleValue,
              let w = object["w"]?.doubleValue, let h = object["h"]?.doubleValue,
              [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
        self.id = id
        center = CGPoint(x: x, y: y)
        size = CGSize(width: w, height: h)
        rotation = object["r"]?.doubleValue.flatMap { $0.isFinite ? CGFloat($0) : nil } ?? 0
        switch (object["kind"]?.stringValue, object["file"]?.stringValue, object["name"]?.stringValue) {
        case ("image", let file?, _): content = .image(file: file)
        case ("sticker", _, let name?): content = .sticker(name)
        case ("text", _, _):
            guard let string = object["text"]?.stringValue else { content = .unknown; break }
            var box = TextBox(string: string)
            if let size = object["fs"]?.doubleValue, size.isFinite, size > 0 {
                box.fontSize = min(max(CGFloat(size), TextBox.fontSizes.lowerBound), TextBox.fontSizes.upperBound)
            }
            box.isBold = object["bold"]?.boolValue ?? false
            box.tint = object["color"]?.stringValue.flatMap(TextBox.Tint.init(rawValue:)) ?? .ink
            box.alignment = object["align"]?.stringValue.flatMap(TextBox.Alignment.init(rawValue:)) ?? .leading
            box.face = object["face"]?.stringValue.flatMap(TextBox.Face.init(rawValue:)) ?? .system
            box.isItalic = object["italic"]?.boolValue ?? false
            box.isUnderlined = object["underline"]?.boolValue ?? false
            box.list = object["list"]?.stringValue.flatMap(TextBox.List.init(rawValue:))
            box.highlight = object["highlight"]?.stringValue.flatMap(TextBox.Highlight.init(rawValue:))
            box.checked = Set(object["checked"]?.arrayValue?.compactMap { $0.intValue.flatMap { (0..<100_000).contains($0) ? $0 : nil } } ?? [])
            if let was = object["checkedText"]?.stringValue, was != string { box.checked = TextBox.checks(box.checked, carriedFrom: was, to: string) }
            box.dropStrayChecks()
            content = .text(box)
        case ("link", _, _):
            let label = object["label"]?.stringValue ?? ""
            if let url = object["url"]?.stringValue.flatMap(WebAddress.url(from:)) {
                content = .link(PageLink(.web(url), label: label))
            } else if let notebook = object["notebook"]?.uuidValue {
                let page = object["page"]?.uuidValue
                content = .link(PageLink(.notebook(notebook, page: page, name: object["name"]?.stringValue ?? ""), label: label))
            } else if let target = object["target"]?.uuidValue {
                content = .link(PageLink(target: target, label: label))
            } else {
                content = .unknown
            }
        case ("tape", _, _):
            content = object["tint"]?.stringValue.flatMap(TapeColor.init(rawValue:)).map(Content.tape) ?? .unknown
        default: content = .unknown
        }
        raw = object
        if case .text(let box) = content, object["fit"].map({ $0 != Self.fit(box, size: size) }) ?? box.hasFormulas { self = fittedToText() }
    }

    var json: JSONValue {
        var object = raw
        object["id"] = .string(id.uuidString)
        object["x"] = .number(Double(center.x))
        object["y"] = .number(Double(center.y))
        object["w"] = .number(Double(size.width))
        object["h"] = .number(Double(size.height))
        object["r"] = .number(Double(rotation))
        switch content {
        case .image(let file):
            object["kind"] = .string("image")
            object["file"] = .string(file)
        case .sticker(let name):
            object["kind"] = .string("sticker")
            object["name"] = .string(name)
        case .text(let box):
            object["kind"] = .string("text")
            object["text"] = .string(box.string)
            object["fs"] = .number(Double(box.fontSize))
            object["bold"] = .bool(box.isBold)
            object["color"] = Self.kept(box.tint, fallback: .ink, was: object["color"])
            object["align"] = Self.kept(box.alignment, fallback: .leading, was: object["align"])
            object["face"] = Self.optional(box.face == .system ? nil : box.face, was: object["face"])
            object["italic"] = box.isItalic ? .bool(true) : nil
            object["underline"] = box.isUnderlined ? .bool(true) : nil
            object["list"] = Self.optional(box.list, was: object["list"])
            object["highlight"] = Self.optional(box.highlight, was: object["highlight"])
            object["checked"] = box.checked.isEmpty ? nil : .array(box.checked.sorted().map { .number(Double($0)) })
            object["checkedText"] = box.checked.isEmpty ? nil : .string(box.string)
            let foreign = box.face == .system && object["face"] != nil || box.list == nil && object["list"] != nil
            if !foreign { object["fit"] = box.face != .system || box.isItalic || box.list != nil || box.hasFormulas ? Self.fit(box, size: size) : nil }
        case .link(let link):
            object["kind"] = .string("link")
            object["label"] = .string(link.label)
            for key in ["target", "notebook", "page", "name", "url"] { object[key] = nil }
            switch link.destination {
            case .page(let target):
                object["target"] = .string(target.uuidString)
            case .notebook(let notebook, let page, let name):
                object["notebook"] = .string(notebook.uuidString)
                object["page"] = page.map { .string($0.uuidString) }
                object["name"] = .string(name)
            case .web(let url):
                object["url"] = .string(url.absoluteString)
            }
        case .tape(let color):
            object["kind"] = .string("tape")
            object["tint"] = .string(color.rawValue)
        case .unknown:
            break
        }
        return .object(object)
    }

    /// A key left out at its default, so a box made before it existed is stored as it was, unless it holds a value from
    /// a newer version that this one can't read.
    private static func optional<Value: RawRepresentable<String>>(_ value: Value?, was old: JSONValue?) -> JSONValue? {
        if let value { return .string(value.rawValue) }
        guard let old, old.stringValue.flatMap(Value.init(rawValue:)) == nil else { return nil }
        return old
    }

    /// The same for a key that is always written: a newer version's value stays while the box holds the fallback for it.
    private static func kept<Value: RawRepresentable<String>>(_ value: Value, fallback: Value, was old: JSONValue?) -> JSONValue {
        if value.rawValue == fallback.rawValue, let old, old.stringValue.flatMap(Value.init(rawValue:)) == nil { return old }
        return .string(value.rawValue)
    }

    /// A fingerprint of everything an older build rewrites when it refits a box by its own plainer measure.
    private static func fit(_ box: TextBox, size: CGSize) -> JSONValue {
        .string(String(fnv1a("\(Double(size.width))|\(Double(size.height))|\(Double(box.fontSize))|\(box.isBold)|\(box.string)"), radix: 16))
    }
}

extension NotebookPage {
    /// Back to front. Entries this version can't read stay in the manifest untouched, behind the rest.
    var items: [PageItem] {
        get { extra["items"]?.arrayValue?.compactMap(PageItem.init(json:)) ?? [] }
        set {
            let unreadable = extra["items"]?.arrayValue?.filter { PageItem(json: $0) == nil } ?? []
            let all = unreadable + newValue.map(\.json)
            extra["items"] = all.isEmpty ? nil : .array(all)
        }
    }

    var hasItems: Bool { extra["items"] != nil }

    /// Everything typed on the page or in its presenter notes, for search.
    var typedText: String {
        let notes = notes
        guard hasItems else { return notes }
        let boxes = items.compactMap { $0.text?.string.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (boxes + (notes.isEmpty ? [] : [notes])).joined(separator: "\n")
    }
}
