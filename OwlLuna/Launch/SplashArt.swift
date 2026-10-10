import SwiftUI
import CoreText

/// The splash's colours. Its tiles are printed matter and keep their colours at night; only the paper under them and their outline change.
struct SplashPalette: Sendable {
    let ground: Color
    let outline: Color

    let ink = Color(hex: 0x1B2230)
    let paper = Color(hex: 0xF1EDE4)
    let board = Color(hex: 0xFAF7F0)
    let white = Color(hex: 0xFFFDF6)
    let rule = Color(hex: 0xD6CFBE)
    let moon = Color(hex: 0xF4DE3C)
    let moonLight = Color(hex: 0xFBF07A)
    let tomato = Color(hex: 0xC9452F)
    let owl: OwlLunaPalette = .launchLight

    static let light = SplashPalette(ground: .paper, outline: Color(hex: 0x1B2230))
    static let dark = SplashPalette(ground: .paper, outline: Color(hex: 0xECE6DA))
}

extension GraphicsContext {
    /// Fills then strokes, with round caps and joins as a pen leaves them.
    func paint(_ path: Path, fill: Color? = nil, stroke: Color? = nil, width: CGFloat = 0) {
        if let fill { self.fill(path, with: .color(fill)) }
        if let stroke { self.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)) }
    }

    /// The first `amount` of a stroke, as if it were being drawn.
    private func draw(_ path: Path, upTo amount: Double, stroke: Color, width: CGFloat) {
        guard amount > 0 else { return }
        paint(amount >= 1 ? path : path.trimmedPath(from: 0, to: amount), stroke: stroke, width: width)
    }

    /// The first `amount` of a line whose pen strokes all start together, each at the pace of the whole line.
    func draw(strokes: [(path: Path, share: Double)], upTo amount: Double, stroke: Color, width: CGFloat) {
        for part in strokes { draw(part.path, upTo: amount / part.share, stroke: stroke, width: width) }
    }

    /// A copy of the context working in another drawing's coordinates.
    func moved(by transform: CGAffineTransform) -> GraphicsContext {
        var copy = self
        copy.concatenate(transform)
        return copy
    }
}

extension CGAffineTransform {
    /// Fits a drawing of `box` whole inside `rect`, resting against `anchor`.
    static func fitting(_ box: CGSize, in rect: CGRect, anchor: UnitPoint = .center) -> CGAffineTransform {
        let scale = min(rect.width / box.width, rect.height / box.height)
        let x = rect.minX + (rect.width - box.width * scale) * anchor.x
        let y = rect.minY + (rect.height - box.height * scale) * anchor.y
        return CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale)
    }

    /// Turns by `degrees` and grows by `scale` about `pivot`.
    static func turning(_ degrees: Double, scale: CGFloat = 1, about pivot: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: degrees * .pi / 180).scaledBy(x: scale, y: scale)
            .translatedBy(x: -pivot.x, y: -pivot.y)
    }
}

extension Path {
    /// The path's pen strokes, one for each time the pen is put down, each with its share of the whole length.
    var strokes: [(path: Path, share: Double)] {
        var strokes: [Path] = []
        forEach { element in
            if case .move = element { strokes.append(Path()) }
            guard let last = strokes.indices.last else { return }
            switch element {
            case let .move(to): strokes[last].move(to: to)
            case let .line(to): strokes[last].addLine(to: to)
            case let .quadCurve(to, control): strokes[last].addQuadCurve(to: to, control: control)
            case let .curve(to, control1, control2): strokes[last].addCurve(to: to, control1: control1, control2: control2)
            case .closeSubpath: strokes[last].closeSubpath()
            }
        }
        let lengths = strokes.map(\.length)
        let whole = lengths.reduce(0, +)
        return zip(strokes, lengths).map { ($0, whole > 0 ? $1 / whole : 1) }
    }

    /// How far a pen travels along the path, measured over short chords.
    private var length: Double {
        var length = 0.0, pen = CGPoint.zero, start = CGPoint.zero
        Path(cgPath.flattened(threshold: 0.01)).forEach { element in
            switch element {
            case let .move(to):
                (pen, start) = (to, to)
            case let .line(to):
                length += hypot(to.x - pen.x, to.y - pen.y)
                pen = to
            case .closeSubpath:
                length += hypot(start.x - pen.x, start.y - pen.y)
                pen = start
            default:
                break
            }
        }
        return length
    }
}

/// A line of display type as outlines one em tall, so the splash can size it to a width and move each letter alone.
struct SplashType: Sendable {
    struct Letter: Sendable {
        /// Drawn from the baseline, y down, in ems.
        let outline: Path
        let x: CGFloat
    }

    let letters: [Letter]
    let width: CGFloat
    let capHeight: CGFloat
    /// Whether there is a line to set and the font has every character of it; one it lacks is set as the font's empty box.
    let isWhole: Bool

    /// `text` in the font, or `fallback` where the font lacks one of its letters.
    init(_ text: String, fallback: String, font: CTFont, tracking: CGFloat = 0) {
        let wanted = SplashType(text, font: font, tracking: tracking)
        self = wanted.isWhole ? wanted : SplashType(fallback, font: font, tracking: tracking)
    }

    init(_ text: String, font: CTFont, tracking: CGFloat = 0) {
        let size = CTFontGetSize(font)
        let characters = Array(text.precomposedStringWithCanonicalMapping.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        isWhole = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) && !characters.isEmpty
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        var flip = CGAffineTransform(scaleX: 1 / size, y: -1 / size)
        var x: CGFloat = 0
        var letters: [Letter] = []
        for (glyph, advance) in zip(glyphs, advances) {
            let outline = CTFontCreatePathForGlyph(font, glyph, &flip).map { Path($0) } ?? Path()
            letters.append(Letter(outline: outline, x: x))
            x += advance.width / size + tracking
        }
        self.letters = letters
        width = max(0, x - tracking)
        capHeight = CTFontGetCapHeight(font) / size
    }

    /// The whole line as one outline, in ems.
    var outline: Path {
        var path = Path()
        for letter in letters { path.addPath(letter.outline, transform: CGAffineTransform(translationX: letter.x, y: 0)) }
        return path
    }
}

extension Path {
    /// A path from SVG path data: M, L, H, V, C, Q, T, A and Z, absolute or relative.
    init(svg data: String) {
        self.init()
        var reader = SVGPathReader(data)
        var command: UInt8 = 0
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        while true {
            if let next = reader.command() {
                command = next
            } else if !reader.hasNumber || command | 0x20 == UInt8(ascii: "z") || command == 0 {
                break
            }
            let origin = command & 0x20 == 0 ? CGPoint.zero : current
            func point() -> CGPoint {
                let x = reader.number(), y = reader.number()
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            var control: CGPoint?
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                current = point()
                start = current
                move(to: current)
                command = command & 0x20 == 0 ? UInt8(ascii: "L") : UInt8(ascii: "l")
            case UInt8(ascii: "l"):
                current = point()
                addLine(to: current)
            case UInt8(ascii: "h"):
                current.x = origin.x + reader.number()
                addLine(to: current)
            case UInt8(ascii: "v"):
                current.y = origin.y + reader.number()
                addLine(to: current)
            case UInt8(ascii: "c"):
                let first = point(), second = point()
                current = point()
                addCurve(to: current, control1: first, control2: second)
            case UInt8(ascii: "q"):
                let bend = point()
                current = point()
                addQuadCurve(to: current, control: bend)
                control = bend
            case UInt8(ascii: "t"):
                let bend = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                current = point()
                addQuadCurve(to: current, control: bend)
                control = bend
            case UInt8(ascii: "a"):
                let radii = CGSize(width: abs(reader.number()), height: abs(reader.number()))
                let turn = reader.number() * .pi / 180
                let large = reader.number() != 0, sweep = reader.number() != 0
                let end = point()
                addArc(from: current, to: end, radii: radii, turn: turn, large: large, sweep: sweep)
                current = end
            case UInt8(ascii: "z"):
                closeSubpath()
                current = start
            default:
                return
            }
            lastControl = control
        }
    }

    /// An SVG elliptical arc, from its end points to the centre form.
    private mutating func addArc(from: CGPoint, to: CGPoint, radii: CGSize, turn: CGFloat, large: Bool, sweep: Bool) {
        guard radii.width > 0, radii.height > 0, from != to else { return addLine(to: to) }
        let cosine = cos(turn), sine = sin(turn)
        let dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2
        let x = cosine * dx + sine * dy, y = -sine * dx + cosine * dy
        var rx = radii.width, ry = radii.height
        let stretch = x * x / (rx * rx) + y * y / (ry * ry)
        if stretch > 1 { rx *= stretch.squareRoot(); ry *= stretch.squareRoot() }
        let below = rx * rx * y * y + ry * ry * x * x
        let factor = (max(0, rx * rx * ry * ry - below) / below).squareRoot() * (large == sweep ? -1 : 1)
        let cx = factor * rx * y / ry, cy = -factor * ry * x / rx
        let centre = CGPoint(x: cosine * cx - sine * cy + (from.x + to.x) / 2, y: sine * cx + cosine * cy + (from.y + to.y) / 2)
        let first = atan2((y - cy) / ry, (x - cx) / rx)
        var delta = atan2((-y - cy) / ry, (-x - cx) / rx) - first
        if sweep, delta < 0 { delta += 2 * .pi }
        if !sweep, delta > 0 { delta -= 2 * .pi }
        let frame = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: turn).scaledBy(x: rx, y: ry)
        addRelativeArc(center: .zero, radius: 1, startAngle: .radians(first), delta: .radians(delta), transform: frame)
    }
}

private struct SVGPathReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: String) { bytes = Array(data.utf8) }

    private static let commands = Set("MmLlHhVvCcQqTtAaZz".utf8)

    private mutating func skipSeparators() {
        while index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: ",") || bytes[index] < 0x20 { index += 1 }
    }

    var hasNumber: Bool {
        mutating get {
            skipSeparators()
            return index < bytes.count && !Self.commands.contains(bytes[index])
        }
    }

    mutating func command() -> UInt8? {
        skipSeparators()
        guard index < bytes.count, Self.commands.contains(bytes[index]) else { return nil }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func number() -> CGFloat {
        skipSeparators()
        guard index < bytes.count else { return 0 }
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
        var seenPoint = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "."), !seenPoint { seenPoint = true } else if !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { break }
            index += 1
        }
        if index == start { index += 1 }
        return CGFloat(Double(String(decoding: bytes[start..<index], as: UTF8.self)) ?? 0)
    }
}
