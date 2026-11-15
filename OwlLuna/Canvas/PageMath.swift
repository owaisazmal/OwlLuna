import CoreGraphics
import CoreText
import Foundation

/// A formula written in TeX, set in STIX Two Math to stand among a text box's words. Thread-safe.
struct MathFormula {
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    private let marks: [MathMark]

    /// nil when the font is missing or the formula uses something this typesetter doesn't know, so it can be shown as typed.
    init?(_ source: String, size: CGFloat, display: Bool, textFont: CTFont) {
        var parser = MathParser(source)
        guard size > 0, let math = MathFontData.shared, let nodes = try? parser.parse(), !nodes.isEmpty else { return nil }
        let box = MathSetter(size: size, textFont: textFont, math: math).list(nodes, MathStyle(level: display ? .display : .text))
        guard box.width > 0, !box.marks.isEmpty else { return nil }
        width = box.width + max(box.italic, 0)
        ascent = max(box.ascent, 0)
        descent = max(box.descent, 0)
        marks = box.marks
    }

    /// The size math is set at beside words in `font`, so the two have the same x-height.
    static func size(beside font: CTFont) -> CGFloat {
        let size = CTFontGetSize(font)
        guard let math = MathFontData.shared, math.xHeight > 0, size > 0 else { return size }
        return size * min(max(CTFontGetXHeight(font) / size / math.xHeight, 0.9), 1.3)
    }

    /// Draws with the left end of its baseline at `origin` in a y-down context, `scale` times its size.
    func draw(in ctx: CGContext, at origin: CGPoint, color: CGColor, scale: CGFloat = 1) {
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setFillColor(color)
        ctx.textMatrix = .identity
        for mark in marks { mark.draw(in: ctx) }
        ctx.restoreGState()
    }
}

/// The runs of a text box's text that are formulas: `$…$` and `\(…\)` in a line, `$$…$$` and `\[…\]` set larger.
struct MathRun: Equatable {
    var range: NSRange
    var source: String
    var display: Bool
    /// A `\$` outside a formula, which shows as a plain dollar sign.
    var isEscape = false

    static func find(in text: NSString) -> [MathRun] {
        let dollar: unichar = 36, slash: unichar = 92, newline: unichar = 10
        let length = text.length
        func character(_ index: Int) -> unichar { index < length ? text.character(at: index) : 0 }
        func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 9 || unit == newline || unit == 0xA0 }
        func isDigit(_ unit: unichar) -> Bool { unit >= 48 && unit <= 57 }
        func close(_ mark: String, from start: Int, inLine: Bool) -> Int? {
            var index = start
            while index < length {
                let unit = character(index)
                if inLine, unit == newline { return nil }
                if unit == slash, mark.first != "\\" { index += 2; continue }
                if text.substring(with: NSRange(location: index, length: min((mark as NSString).length, length - index))) == mark { return index }
                index += 1
            }
            return nil
        }
        func run(_ open: Int, _ start: Int, _ end: Int, closing: Int, display: Bool) -> MathRun? {
            let source = text.substring(with: NSRange(location: start, length: end - start))
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return MathRun(range: NSRange(location: open, length: end + closing - open), source: source, display: display)
        }
        var runs: [MathRun] = [], index = 0
        while index < length {
            let unit = character(index)
            if unit == slash {
                let next = character(index + 1)
                if next == dollar {
                    runs.append(MathRun(range: NSRange(location: index, length: 2), source: "$", display: false, isEscape: true))
                } else if next == 40 || next == 91, let end = close(next == 40 ? "\\)" : "\\]", from: index + 2, inLine: next == 40),
                          let found = run(index, index + 2, end, closing: 2, display: next == 91) {
                    runs.append(found)
                    index = end + 2
                    continue
                }
                index += 2
            } else if unit == dollar, character(index + 1) == dollar {
                if let end = close("$$", from: index + 2, inLine: false), let found = run(index, index + 2, end, closing: 2, display: true) {
                    runs.append(found)
                    index = end + 2
                } else {
                    index += 2
                }
            } else if unit == dollar, index + 1 < length, !isSpace(character(index + 1)) {
                var end = index + 1
                while let found = close("$", from: end, inLine: true) {
                    if !isSpace(character(found - 1)), !isDigit(character(found + 1)) { end = found; break }
                    end = found + 1
                }
                if end > index + 1, character(end) == dollar, let found = run(index, index + 1, end, closing: 1, display: false) {
                    runs.append(found)
                    index = end + 1
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return runs
    }
}

private enum MathMark {
    case glyph(CTFont, CGGlyph, CGPoint, stretch: CGFloat)
    case line(CTLine, CGPoint)
    case rule(CGRect)

    func moved(by dx: CGFloat, _ dy: CGFloat) -> MathMark {
        switch self {
        case .glyph(let font, let glyph, let at, let stretch): .glyph(font, glyph, CGPoint(x: at.x + dx, y: at.y + dy), stretch: stretch)
        case .line(let line, let at): .line(line, CGPoint(x: at.x + dx, y: at.y + dy))
        case .rule(let rect): .rule(rect.offsetBy(dx: dx, dy: dy))
        }
    }

    func draw(in ctx: CGContext) {
        switch self {
        case .glyph(let font, var glyph, let at, let stretch):
            ctx.saveGState()
            ctx.translateBy(x: at.x, y: at.y)
            ctx.scaleBy(x: 1, y: stretch)
            ctx.textMatrix = .identity
            var origin = CGPoint.zero
            CTFontDrawGlyphs(font, &glyph, &origin, 1, ctx)
            ctx.restoreGState()
        case .line(let line, let at):
            ctx.textPosition = at
            CTLineDraw(line, ctx)
            ctx.textPosition = .zero
        case .rule(let rect):
            ctx.fill(rect)
        }
    }
}

private enum MathKind: Int {
    case ord, op, bin, rel, open, close, punct, inner
}

private struct MathStyle {
    enum Level: Int { case display, text, script, scriptScript }

    var level: Level
    var cramped = false

    var isScript: Bool { level.rawValue >= Level.script.rawValue }
    var sup: MathStyle { MathStyle(level: isScript ? .scriptScript : .script, cramped: cramped) }
    var sub: MathStyle { MathStyle(level: sup.level, cramped: true) }
    var numerator: MathStyle { MathStyle(level: level == .display ? .text : sup.level, cramped: cramped) }
    var denominator: MathStyle { MathStyle(level: numerator.level, cramped: true) }
    var squeezed: MathStyle { MathStyle(level: level, cramped: true) }
}

/// Laid-out math, from the left end of its baseline, y up.
private struct MathBox {
    var width: CGFloat = 0
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    /// How far a lone slanted glyph's top leans past its advance.
    var italic: CGFloat = 0
    /// Where an accent over a lone glyph is centred.
    var accent: CGFloat?
    /// A lone symbol, whose scripts keep their standard shifts.
    var single = false
    /// A big operator, whose advance already takes in its lean.
    var isOperator = false
    var marks: [MathMark] = []

    mutating func add(_ box: MathBox, x: CGFloat = 0, y: CGFloat = 0) {
        guard !box.marks.isEmpty else { return }
        if marks.isEmpty {
            (ascent, descent) = (box.ascent + y, box.descent - y)
        } else {
            ascent = max(ascent, box.ascent + y)
            descent = max(descent, box.descent - y)
        }
        marks += box.marks.map { $0.moved(by: x, y) }
    }

    mutating func append(_ box: MathBox) {
        add(box, x: width)
        width += box.width
    }

    func shifted(by dy: CGFloat) -> MathBox {
        var box = self
        box.marks = marks.map { $0.moved(by: 0, dy) }
        box.ascent += dy
        box.descent -= dy
        return box
    }
}

private indirect enum MathNode {
    case symbol(String, MathKind)
    case word(String, MathKind)
    case text(String, bold: Bool, italic: Bool)
    case group([MathNode])
    case scripts(MathNode, sub: [MathNode]?, sup: [MathNode]?)
    case largeOp(String, limits: Bool?)
    case function(String, limits: Bool?)
    case fraction([MathNode], [MathNode], rule: Bool, level: MathStyle.Level?, fence: Bool)
    case radical([MathNode], degree: [MathNode]?)
    case fenced(String, [MathNode], String)
    case middle(String)
    case big(String, CGFloat, MathKind)
    case accent(String, [MathNode], wide: Bool)
    case bar([MathNode], over: Bool)
    case stretchy([MathNode], String, over: Bool, kind: MathKind)
    case stack(MathNode, over: [MathNode]?, under: [MathNode]?)
    case space(CGFloat)
    case style(MathStyle.Level)
    case table([[[MathNode]]], MathTable)
    case boxed([MathNode])

    var isMiddle: Bool {
        if case .middle = self { return true }
        return false
    }

    var isPrime: Bool {
        if case .symbol("\u{2032}", _) = self { return true }
        return false
    }
}

/// How an environment such as `pmatrix`, `cases` or `aligned` sets its cells.
private struct MathTable {
    enum Align { case left, center, right }

    var left = "", right = ""
    var aligns: [Align] = [.center]
    /// Between columns, in ems, taken in turn.
    var gaps: [CGFloat] = [1]
    var level = MathStyle.Level.text
    var jot: CGFloat = 0
    /// Each second column starts with an empty atom, so a relation there keeps its spacing.
    var pairs = false

    init?(_ name: String) {
        switch name {
        case "matrix", "array": break
        case "pmatrix": (left, right) = ("(", ")")
        case "bmatrix": (left, right) = ("[", "]")
        case "Bmatrix": (left, right) = ("{", "}")
        case "vmatrix": (left, right) = ("|", "|")
        case "Vmatrix": (left, right) = ("\u{2016}", "\u{2016}")
        case "smallmatrix": (level, gaps) = (.script, [0.5])
        case "cases", "dcases": (left, aligns, level) = ("{", [.left], name == "cases" ? .text : .display)
        case "rcases": (right, aligns) = ("}", [.left])
        case "aligned", "align", "align*", "split", "alignat", "alignat*", "alignedat", "eqnarray", "eqnarray*":
            (aligns, gaps, level, jot, pairs) = ([.right, .left], [0, 2], .display, 0.3, true)
        case "gathered", "gather", "gather*": (level, jot) = (.display, 0.3)
        default: return nil
        }
    }
}

private struct MathParser {
    struct Unsupported: Error {}

    private let characters: [Character]
    private var at = 0

    init(_ source: String) {
        characters = Array(source)
    }

    mutating func parse() throws -> [MathNode] {
        let nodes = try list(.math)
        guard at == characters.count else { throw Unsupported() }
        return nodes
    }

    private var current: Character? { at < characters.count ? characters[at] : nil }

    private mutating func skipSpaces() {
        while let character = current, character.isWhitespace { at += 1 }
    }

    private func peekCommand() -> String? {
        guard current == "\\", at + 1 < characters.count else { return nil }
        var end = at + 1
        guard characters[end].isASCIILetter else { return String(characters[end]) }
        while end < characters.count, characters[end].isASCIILetter { end += 1 }
        return String(characters[(at + 1)..<end])
    }

    private mutating func readCommand() throws -> String {
        guard let name = peekCommand() else { throw Unsupported() }
        at += 1 + name.count
        return name
    }

    private mutating func expect(_ character: Character) throws {
        skipSpaces()
        guard current == character else { throw Unsupported() }
        at += 1
    }

    private mutating func list(_ alphabet: Alphabet, until stop: Character? = nil) throws -> [MathNode] {
        var nodes: [MathNode] = []
        while true {
            skipSpaces()
            guard let character = current, character != "}", character != "&", character != stop else { break }
            if let name = peekCommand() {
                if ["right", "end", "\\", "cr"].contains(name) { break }
                if name == "middle" {
                    at += 1 + name.count
                    nodes.append(.middle(try delimiter()))
                    continue
                }
            }
            switch character {
            case "^", "_":
                at += 1
                nodes.append(try attach(try argument(alphabet), to: nodes.popLast(), sup: character == "^"))
            case "'":
                var primes: [MathNode] = []
                while current == "'" {
                    primes.append(.symbol("\u{2032}", .ord))
                    at += 1
                }
                nodes.append(try attach(primes, to: nodes.popLast(), sup: true))
            default:
                nodes.append(try atom(alphabet))
            }
        }
        return nodes
    }

    private func attach(_ script: [MathNode], to base: MathNode?, sup: Bool) throws -> MathNode {
        guard case .scripts(let nucleus, let sub, let over)? = base else {
            return .scripts(base ?? .group([]), sub: sup ? nil : script, sup: sup ? script : nil)
        }
        if !sup {
            guard sub == nil else { throw Unsupported() }
            return .scripts(nucleus, sub: script, sup: over)
        }
        guard let over else { return .scripts(nucleus, sub: sub, sup: script) }
        guard over.allSatisfy(\.isPrime) else { throw Unsupported() }
        return .scripts(nucleus, sub: sub, sup: over + script)
    }

    private mutating func argument(_ alphabet: Alphabet) throws -> [MathNode] {
        skipSpaces()
        guard let character = current, !"}&^_".contains(character) else { throw Unsupported() }
        if character == "{" {
            at += 1
            let nodes = try list(alphabet)
            try expect("}")
            return nodes
        }
        return [try atom(alphabet)]
    }

    private mutating func atom(_ alphabet: Alphabet) throws -> MathNode {
        guard let character = current else { throw Unsupported() }
        if character == "{" { return .group(try argument(alphabet)) }
        if character == "\\" { return try command(alphabet) }
        at += 1
        if let kind = Self.punctuation[character] {
            return .symbol(character == "-" ? "\u{2212}" : character == "*" ? "\u{2217}" : String(character), kind)
        }
        guard !"#%$~".contains(character) else {
            if character == "~" { return .space(6) }
            throw Unsupported()
        }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return .symbol(String(character), .ord) }
        if Self.largeOperators.values.contains(String(character)) {
            return .largeOp(String(character), limits: try limits(default: Self.integrals.contains(String(character)) ? false : nil))
        }
        if character.isLetter || character.isNumber { return .symbol(alphabet.map(scalar), .ord) }
        return .symbol(String(character), Self.kinds[String(character)] ?? .ord)
    }

    private mutating func command(_ alphabet: Alphabet) throws -> MathNode {
        let name = try readCommand()
        if let mu = Self.spaces[name] { return .space(mu) }
        if let entry = Self.symbols[name] { return .symbol(entry.0, entry.1) }
        if let letter = Self.greek[name], let scalar = Unicode.Scalar(letter) { return .symbol(alphabet.map(scalar), .ord) }
        if let symbol = Self.largeOperators[name] {
            return .largeOp(symbol, limits: try limits(default: Self.integrals.contains(symbol) ? false : nil))
        }
        if let limited = Self.functions[name] {
            let word = name == "liminf" ? "lim\u{2006}inf" : name == "limsup" ? "lim\u{2006}sup" : name
            return .function(word, limits: try limits(default: limited ? nil : false))
        }
        if let font = Alphabet(command: name) { return .group(try argument(font)) }
        if let entry = Self.accents[name] { return .accent(entry.0, try argument(alphabet), wide: entry.1) }
        if let level = Self.styles[name] { return .style(level) }
        if let entry = Self.bigs[name] { return .big(try delimiter(), entry.0, entry.1) }
        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            let level: MathStyle.Level? = name == "dfrac" || name == "cfrac" ? .display : name == "tfrac" ? .text : nil
            return .fraction(try argument(alphabet), try argument(alphabet), rule: true, level: level, fence: false)
        case "binom", "dbinom", "tbinom":
            let level: MathStyle.Level? = name == "dbinom" ? .display : name == "tbinom" ? .text : nil
            return .fraction(try argument(alphabet), try argument(alphabet), rule: false, level: level, fence: true)
        case "sqrt":
            skipSpaces()
            var degree: [MathNode]?
            if current == "[" {
                at += 1
                degree = try list(alphabet, until: "]")
                try expect("]")
            }
            return .radical(try argument(alphabet), degree: degree)
        case "left":
            let left = try delimiter(), body = try list(alphabet)
            guard try readCommand() == "right" else { throw Unsupported() }
            return .fenced(left, body, try delimiter())
        case "text", "textrm", "textnormal", "textup", "mbox", "hbox", "textbf", "textit", "textsf", "texttt":
            return .text(try rawText(), bold: name == "textbf", italic: name == "textit")
        case "operatorname":
            let starred = current == "*"
            if starred { at += 1 }
            return .function(try rawText(), limits: try limits(default: starred ? nil : false))
        case "overline", "underline": return .bar(try argument(alphabet), over: name == "overline")
        case "overbrace": return .stretchy(try argument(alphabet), "\u{23DE}", over: true, kind: .op)
        case "underbrace": return .stretchy(try argument(alphabet), "\u{23DF}", over: false, kind: .op)
        case "overrightarrow": return .stretchy(try argument(alphabet), "\u{2192}", over: true, kind: .ord)
        case "overleftarrow": return .stretchy(try argument(alphabet), "\u{2190}", over: true, kind: .ord)
        case "overleftrightarrow": return .stretchy(try argument(alphabet), "\u{2194}", over: true, kind: .ord)
        case "overset", "stackrel", "underset":
            let script = try argument(alphabet), base = try argument(alphabet)
            let nucleus = base.count == 1 ? base[0] : .group(base)
            return name == "underset" ? .stack(nucleus, over: nil, under: script) : .stack(nucleus, over: script, under: nil)
        case "boxed": return .boxed(try argument(alphabet))
        case "begin": return try environment(alphabet)
        case "not":
            guard case .symbol(let symbol, let kind) = try atom(alphabet) else { throw Unsupported() }
            return .symbol(Self.negations[symbol] ?? symbol + "\u{0338}", kind)
        case "bmod": return .word("mod", .bin)
        case "pmod":
            return .group([.space(8), .symbol("(", .open), .word("mod", .ord), .space(6)] + (try argument(alphabet)) + [.symbol(")", .close)])
        default: throw Unsupported()
        }
    }

    private mutating func limits(default value: Bool?) throws -> Bool? {
        skipSpaces()
        switch peekCommand() {
        case "limits":
            _ = try readCommand()
            return true
        case "nolimits":
            _ = try readCommand()
            return false
        default:
            return value
        }
    }

    private mutating func delimiter() throws -> String {
        skipSpaces()
        guard let character = current else { throw Unsupported() }
        if character == "\\" {
            guard let symbol = Self.delimiters[try readCommand()] else { throw Unsupported() }
            return symbol
        }
        at += 1
        switch character {
        case "(", ")", "[", "]", "|", "/": return String(character)
        case ".": return ""
        case "<": return "\u{27E8}"
        case ">": return "\u{27E9}"
        default: throw Unsupported()
        }
    }

    /// What a `\text{…}` holds, as written.
    private mutating func rawText() throws -> String {
        try expect("{")
        var text = "", depth = 0
        while let character = current {
            at += 1
            switch character {
            case "{":
                depth += 1
            case "}":
                if depth == 0 { return text }
                depth -= 1
            case "\\":
                guard let next = current, !next.isASCIILetter else { throw Unsupported() }
                at += 1
                text.append(next == "\\" ? " " : next)
            case "~":
                text.append("\u{00A0}")
            case "$":
                throw Unsupported()
            default:
                text.append(character.isNewline ? " " : character)
            }
        }
        throw Unsupported()
    }

    private mutating func environment(_ alphabet: Alphabet) throws -> MathNode {
        let name = try rawText()
        guard var table = MathTable(name) else { throw Unsupported() }
        if name == "array" {
            let columns = try rawText().compactMap { (column: Character) -> MathTable.Align? in
                switch column {
                case "l": .left
                case "c": .center
                case "r": .right
                default: nil
                }
            }
            if !columns.isEmpty { table.aligns = columns }
        }
        if name.hasPrefix("alignat") { _ = try rawText() }
        var rows: [[[MathNode]]] = [], row: [[MathNode]] = []
        while true {
            row.append(try list(alphabet))
            skipSpaces()
            if current == "&" {
                at += 1
                continue
            }
            let command = try readCommand()
            if command == "\\" || command == "cr" {
                rows.append(row)
                row = []
                skipSpaces()
                if current == "[" {
                    while let character = current, character != "]" { at += 1 }
                    try expect("]")
                }
                continue
            }
            guard command == "end", try rawText() == name else { throw Unsupported() }
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            guard !rows.isEmpty else { throw Unsupported() }
            return .table(rows, table)
        }
    }

    private static let punctuation: [Character: MathKind] = [
        "+": .bin, "-": .bin, "*": .bin, "=": .rel, "<": .rel, ">": .rel, ":": .rel, ",": .punct, ";": .punct,
        "(": .open, "[": .open, ")": .close, "]": .close, "!": .close, "?": .close, ".": .ord, "/": .ord, "|": .ord, "@": .ord, "\"": .ord,
    ]

    private static let spaces: [String: CGFloat] = [
        ",": 3, ":": 4, ">": 4, ";": 5, "!": -3, " ": 6, "quad": 18, "qquad": 36, "enspace": 9, "thinspace": 3, "medspace": 4,
        "thickspace": 5, "negthinspace": -3, "negmedspace": -4, "negthickspace": -5, "space": 6, "nobreakspace": 6,
    ]

    private static let symbols: [String: (String, MathKind)] = [
        "{": ("{", .open), "}": ("}", .close), "lbrace": ("{", .open), "rbrace": ("}", .close), "langle": ("⟨", .open), "rangle": ("⟩", .close),
        "lfloor": ("⌊", .open), "rfloor": ("⌋", .close), "lceil": ("⌈", .open), "rceil": ("⌉", .close), "lvert": ("|", .open),
        "rvert": ("|", .close), "lVert": ("‖", .open), "rVert": ("‖", .close), "vert": ("|", .ord), "|": ("‖", .ord), "Vert": ("‖", .ord),
        "lbrack": ("[", .open), "rbrack": ("]", .close), "backslash": ("\\", .ord),
        "%": ("%", .ord), "$": ("$", .ord), "#": ("#", .ord), "&": ("&", .ord), "_": ("_", .ord),
        "leq": ("≤", .rel), "le": ("≤", .rel), "geq": ("≥", .rel), "ge": ("≥", .rel), "neq": ("≠", .rel), "ne": ("≠", .rel),
        "equiv": ("≡", .rel), "approx": ("≈", .rel), "sim": ("∼", .rel), "simeq": ("≃", .rel), "cong": ("≅", .rel), "propto": ("∝", .rel),
        "ll": ("≪", .rel), "gg": ("≫", .rel), "subset": ("⊂", .rel), "supset": ("⊃", .rel), "subseteq": ("⊆", .rel),
        "supseteq": ("⊇", .rel), "nsubseteq": ("⊈", .rel), "sqsubseteq": ("⊑", .rel), "sqsupseteq": ("⊒", .rel), "in": ("∈", .rel),
        "ni": ("∋", .rel), "notin": ("∉", .rel), "to": ("→", .rel), "rightarrow": ("→", .rel), "leftarrow": ("←", .rel),
        "gets": ("←", .rel), "leftrightarrow": ("↔", .rel), "Rightarrow": ("⇒", .rel), "Leftarrow": ("⇐", .rel),
        "Leftrightarrow": ("⇔", .rel), "implies": ("⟹", .rel), "impliedby": ("⟸", .rel), "iff": ("⟺", .rel), "mapsto": ("↦", .rel),
        "longrightarrow": ("⟶", .rel), "longleftarrow": ("⟵", .rel), "longleftrightarrow": ("⟷", .rel), "Longrightarrow": ("⟹", .rel),
        "Longleftarrow": ("⟸", .rel), "Longleftrightarrow": ("⟺", .rel), "longmapsto": ("⟼", .rel), "hookrightarrow": ("↪", .rel),
        "rightleftharpoons": ("⇌", .rel), "uparrow": ("↑", .rel), "downarrow": ("↓", .rel), "nearrow": ("↗", .rel),
        "searrow": ("↘", .rel), "nwarrow": ("↖", .rel), "swarrow": ("↙", .rel), "perp": ("⊥", .rel), "parallel": ("∥", .rel),
        "mid": ("∣", .rel), "nmid": ("∤", .rel), "vdash": ("⊢", .rel), "models": ("⊨", .rel), "prec": ("≺", .rel), "succ": ("≻", .rel),
        "preceq": ("⪯", .rel), "succeq": ("⪰", .rel), "asymp": ("≍", .rel), "doteq": ("≐", .rel), "leqslant": ("⩽", .rel),
        "geqslant": ("⩾", .rel), "nleq": ("≰", .rel), "ngeq": ("≱", .rel), "lt": ("<", .rel), "gt": (">", .rel), "coloneqq": ("≔", .rel),
        "triangleq": ("≜", .rel), "therefore": ("∴", .rel), "because": ("∵", .rel), "colon": (":", .punct),
        "pm": ("±", .bin), "mp": ("∓", .bin), "times": ("×", .bin), "div": ("÷", .bin), "cdot": ("⋅", .bin), "ast": ("∗", .bin),
        "star": ("⋆", .bin), "circ": ("∘", .bin), "bullet": ("∙", .bin), "cup": ("∪", .bin), "cap": ("∩", .bin), "wedge": ("∧", .bin),
        "land": ("∧", .bin), "vee": ("∨", .bin), "lor": ("∨", .bin), "oplus": ("⊕", .bin), "ominus": ("⊖", .bin), "otimes": ("⊗", .bin),
        "oslash": ("⊘", .bin), "odot": ("⊙", .bin), "setminus": ("∖", .bin), "sqcup": ("⊔", .bin), "sqcap": ("⊓", .bin),
        "uplus": ("⊎", .bin), "dagger": ("†", .bin), "ddagger": ("‡", .bin), "amalg": ("⨿", .bin), "wr": ("≀", .bin),
        "diamond": ("⋄", .bin), "triangleleft": ("◃", .bin), "triangleright": ("▹", .bin),
        "infty": ("∞", .ord), "partial": ("𝜕", .ord), "nabla": ("∇", .ord), "forall": ("∀", .ord), "exists": ("∃", .ord),
        "nexists": ("∄", .ord), "emptyset": ("∅", .ord), "varnothing": ("∅", .ord), "neg": ("¬", .ord), "lnot": ("¬", .ord),
        "angle": ("∠", .ord), "measuredangle": ("∡", .ord), "triangle": ("△", .ord), "hbar": ("ℏ", .ord), "hslash": ("ℏ", .ord),
        "ell": ("ℓ", .ord), "wp": ("℘", .ord), "Re": ("ℜ", .ord), "Im": ("ℑ", .ord), "aleph": ("ℵ", .ord), "beth": ("ℶ", .ord),
        "prime": ("′", .ord), "top": ("⊤", .ord), "bot": ("⊥", .ord), "degree": ("°", .ord), "circledast": ("⊛", .bin),
        "ldots": ("…", .inner), "cdots": ("⋯", .inner), "dots": ("…", .inner), "dotsc": ("…", .inner), "dotsb": ("⋯", .inner),
        "vdots": ("⋮", .ord), "ddots": ("⋱", .inner), "checkmark": ("✓", .ord), "clubsuit": ("♣", .ord), "diamondsuit": ("♢", .ord),
        "heartsuit": ("♡", .ord), "spadesuit": ("♠", .ord), "flat": ("♭", .ord), "natural": ("♮", .ord), "sharp": ("♯", .ord),
        "square": ("□", .ord), "Box": ("□", .ord), "blacksquare": ("■", .ord), "imath": ("𝚤", .ord), "jmath": ("𝚥", .ord),
        "complement": ("∁", .ord), "mho": ("℧", .ord), "surd": ("√", .ord),
    ]

    /// What a symbol typed as itself, such as ≤, is in a formula.
    private static let kinds: [String: MathKind] = Dictionary(symbols.values.map { ($0.0, $0.1) }, uniquingKeysWith: { $0.rawValue <= $1.rawValue ? $0 : $1 })

    private static let greek: [String: UInt32] = [
        "alpha": 0x3B1, "beta": 0x3B2, "gamma": 0x3B3, "delta": 0x3B4, "epsilon": 0x3F5, "varepsilon": 0x3B5, "zeta": 0x3B6,
        "eta": 0x3B7, "theta": 0x3B8, "vartheta": 0x3D1, "iota": 0x3B9, "kappa": 0x3BA, "varkappa": 0x3F0, "lambda": 0x3BB, "mu": 0x3BC,
        "nu": 0x3BD, "xi": 0x3BE, "omicron": 0x3BF, "pi": 0x3C0, "varpi": 0x3D6, "rho": 0x3C1, "varrho": 0x3F1, "sigma": 0x3C3,
        "varsigma": 0x3C2, "tau": 0x3C4, "upsilon": 0x3C5, "phi": 0x3D5, "varphi": 0x3C6, "chi": 0x3C7, "psi": 0x3C8, "omega": 0x3C9,
        "Gamma": 0x393, "Delta": 0x394, "Theta": 0x398, "Lambda": 0x39B, "Xi": 0x39E, "Pi": 0x3A0, "Sigma": 0x3A3, "Upsilon": 0x3A5,
        "Phi": 0x3A6, "Psi": 0x3A8, "Omega": 0x3A9,
    ]

    private static let largeOperators: [String: String] = [
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮", "oiint": "∯", "bigcup": "⋃",
        "bigcap": "⋂", "bigvee": "⋁", "bigwedge": "⋀", "bigoplus": "⨁", "bigotimes": "⨂", "bigodot": "⨀", "biguplus": "⨄", "bigsqcup": "⨆",
    ]

    private static let integrals: Set<String> = ["∫", "∬", "∭", "∮", "∯"]

    /// Each named function, and whether it takes limits under it when set large.
    private static let functions: [String: Bool] = [
        "sin": false, "cos": false, "tan": false, "cot": false, "sec": false, "csc": false, "arcsin": false, "arccos": false,
        "arctan": false, "sinh": false, "cosh": false, "tanh": false, "coth": false, "log": false, "ln": false, "lg": false, "exp": false,
        "arg": false, "deg": false, "dim": false, "hom": false, "ker": false, "lim": true, "liminf": true, "limsup": true, "max": true,
        "min": true, "sup": true, "inf": true, "det": true, "gcd": true, "Pr": true,
    ]

    private static let accents: [String: (String, Bool)] = [
        "hat": ("\u{0302}", false), "check": ("\u{030C}", false), "tilde": ("\u{0303}", false), "acute": ("\u{0301}", false),
        "grave": ("\u{0300}", false), "dot": ("\u{0307}", false), "ddot": ("\u{0308}", false), "dddot": ("\u{20DB}", false),
        "breve": ("\u{0306}", false), "bar": ("\u{0304}", false), "vec": ("\u{20D7}", false), "mathring": ("\u{030A}", false),
        "widehat": ("\u{0302}", true), "widetilde": ("\u{0303}", true), "widecheck": ("\u{030C}", true),
    ]

    private static let styles: [String: MathStyle.Level] = [
        "displaystyle": .display, "textstyle": .text, "scriptstyle": .script, "scriptscriptstyle": .scriptScript,
    ]

    /// `\big(` and its kin: the delimiter's height in ems, and what kind of atom it makes.
    private static let bigs: [String: (CGFloat, MathKind)] = {
        var bigs: [String: (CGFloat, MathKind)] = [:]
        for (name, height) in [("big", 1.2), ("Big", 1.8), ("bigg", 2.4), ("Bigg", 3.0)] as [(String, CGFloat)] {
            for (end, kind) in [("", MathKind.ord), ("l", .open), ("r", .close), ("m", .rel)] { bigs[name + end] = (height, kind) }
        }
        return bigs
    }()

    private static let delimiters: [String: String] = [
        "{": "{", "}": "}", "lbrace": "{", "rbrace": "}", "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈",
        "rceil": "⌉", "|": "‖", "vert": "|", "Vert": "‖", "lvert": "|", "rvert": "|", "lVert": "‖", "rVert": "‖", "backslash": "\\",
        "uparrow": "↑", "downarrow": "↓", "updownarrow": "↕", "Uparrow": "⇑", "Downarrow": "⇓", "lbrack": "[", "rbrack": "]",
        "llbracket": "⟦", "rrbracket": "⟧",
    ]

    private static let negations: [String: String] = [
        "=": "≠", "<": "≮", ">": "≯", "∈": "∉", "≡": "≢", "⊂": "⊄", "⊃": "⊅", "⊆": "⊈", "⊇": "⊉", "∼": "≁", "≈": "≉", "≤": "≰",
        "≥": "≱", "∣": "∤", "∥": "∦", "∃": "∄", "≅": "≇", "≃": "≄", "→": "↛", "←": "↚", "⇒": "⇏", "⇔": "⇎", "↔": "↮", "∋": "∌",
        "≺": "⊀", "≻": "⊁",
    ]
}

/// The letters of `\mathbf`, `\mathbb` and the like, from Unicode's mathematical alphanumerics.
private enum Alphabet {
    case math, roman, italic, bold, boldItalic, blackboard, script, fraktur, sans, mono

    init?(command: String) {
        switch command {
        case "mathnormal": self = .math
        case "mathrm", "mathup": self = .roman
        case "mathit": self = .italic
        case "mathbf": self = .bold
        case "boldsymbol", "bm", "mathbfit": self = .boldItalic
        case "mathbb": self = .blackboard
        case "mathcal", "mathscr": self = .script
        case "mathfrak": self = .fraktur
        case "mathsf": self = .sans
        case "mathtt": self = .mono
        default: return nil
        }
    }

    func map(_ scalar: Unicode.Scalar) -> String {
        let value = scalar.value
        let mapped: UInt32? = switch value {
        case 0x41...0x5A: latin(value - 0x41, upper: true)
        case 0x61...0x7A: latin(value - 0x61, upper: false)
        case 0x30...0x39: digit(value - 0x30)
        case 0x391...0x3A9: greek(value - 0x391, upper: true)
        case 0x3B1...0x3C9: greek(value - 0x3B1, upper: false)
        default: Self.greekVariants[value].flatMap { greek($0, upper: false) }
        }
        return String(Character(Unicode.Scalar(mapped ?? value) ?? scalar))
    }

    private func latin(_ index: UInt32, upper: Bool) -> UInt32? {
        if let hole = Self.holes[self]?[(upper ? 0x41 : 0x61) + index] { return hole }
        let start: UInt32? = switch self {
        case .math, .italic: upper ? 0x1D434 : 0x1D44E
        case .roman: nil
        case .bold: upper ? 0x1D400 : 0x1D41A
        case .boldItalic: upper ? 0x1D468 : 0x1D482
        case .blackboard: upper ? 0x1D538 : 0x1D552
        case .script: upper ? 0x1D49C : 0x1D4B6
        case .fraktur: upper ? 0x1D504 : 0x1D51E
        case .sans: upper ? 0x1D5A0 : 0x1D5BA
        case .mono: upper ? 0x1D670 : 0x1D68A
        }
        return start.map { $0 + index }
    }

    private func digit(_ index: UInt32) -> UInt32? {
        let start: UInt32? = switch self {
        case .bold: 0x1D7CE
        case .blackboard: 0x1D7D8
        case .sans: 0x1D7E2
        case .mono: 0x1D7F6
        default: nil
        }
        return start.map { $0 + index }
    }

    /// Lowercase Greek is slanted in a formula and capitals stand upright, as in TeX.
    private func greek(_ index: UInt32, upper: Bool) -> UInt32? {
        let start: UInt32? = switch self {
        case .math: upper ? nil : 0x1D6FC
        case .italic: upper ? 0x1D6E2 : 0x1D6FC
        case .bold: upper ? 0x1D6A8 : 0x1D6C2
        case .boldItalic: upper ? 0x1D71C : 0x1D736
        default: nil
        }
        return start.map { $0 + index }
    }

    /// ϵ, ϑ, ϰ, ϕ, ϱ and ϖ, by where they follow ω in the mathematical Greek alphabets.
    private static let greekVariants: [UInt32: UInt32] = [0x3F5: 0x1A, 0x3D1: 0x1B, 0x3F0: 0x1C, 0x3D5: 0x1D, 0x3F1: 0x1E, 0x3D6: 0x1F]

    /// Letters these alphabets take from Letterlike Symbols instead.
    private static let holes: [Alphabet: [UInt32: UInt32]] = [
        .math: [0x68: 0x210E],
        .italic: [0x68: 0x210E],
        .script: [0x42: 0x212C, 0x45: 0x2130, 0x46: 0x2131, 0x48: 0x210B, 0x49: 0x2110, 0x4C: 0x2112, 0x4D: 0x2133, 0x52: 0x211B,
                  0x65: 0x212F, 0x67: 0x210A, 0x6F: 0x2134],
        .fraktur: [0x43: 0x212D, 0x48: 0x210C, 0x49: 0x2111, 0x52: 0x211C, 0x5A: 0x2128],
        .blackboard: [0x43: 0x2102, 0x48: 0x210D, 0x4E: 0x2115, 0x50: 0x2119, 0x51: 0x211A, 0x52: 0x211D, 0x5A: 0x2124],
    ]
}

private extension Character {
    var isASCIILetter: Bool { isASCII && isLetter }
}

private enum MathConstant: Int {
    case delimitedSubFormulaMinHeight = 2, displayOperatorMinHeight, mathLeading, axisHeight, accentBaseHeight, flattenedAccentBaseHeight,
         subscriptShiftDown, subscriptTopMax, subscriptBaselineDropMin, superscriptShiftUp, superscriptShiftUpCramped, superscriptBottomMin,
         superscriptBaselineDropMax, subSuperscriptGapMin, superscriptBottomMaxWithSubscript, spaceAfterScript, upperLimitGapMin,
         upperLimitBaselineRiseMin, lowerLimitGapMin, lowerLimitBaselineDropMin, stackTopShiftUp, stackTopDisplayStyleShiftUp,
         stackBottomShiftDown, stackBottomDisplayStyleShiftDown, stackGapMin, stackDisplayStyleGapMin, stretchStackTopShiftUp,
         stretchStackBottomShiftDown, stretchStackGapAboveMin, stretchStackGapBelowMin, fractionNumeratorShiftUp,
         fractionNumeratorDisplayStyleShiftUp, fractionDenominatorShiftDown, fractionDenominatorDisplayStyleShiftDown,
         fractionNumeratorGapMin, fractionNumDisplayStyleGapMin, fractionRuleThickness, fractionDenominatorGapMin,
         fractionDenomDisplayStyleGapMin, skewedFractionHorizontalGap, skewedFractionVerticalGap, overbarVerticalGap,
         overbarRuleThickness, overbarExtraAscender, underbarVerticalGap, underbarRuleThickness, underbarExtraDescender,
         radicalVerticalGap, radicalDisplayStyleVerticalGap, radicalRuleThickness, radicalExtraAscender, radicalKernBeforeDegree,
         radicalKernAfterDegree
}

private struct MathVariant: Sendable {
    var glyph: CGGlyph
    var advance: CGFloat
}

private struct MathPart: Sendable {
    var glyph: CGGlyph
    var start: CGFloat
    var end: CGFloat
    var full: CGFloat
    var extender: Bool
}

private struct MathConstruction: Sendable {
    var variants: [MathVariant]
    var parts: [MathPart]
}

/// STIX Two Math's OpenType MATH table: its constants, and the bigger cuts and pieces of its stretchy glyphs, all in ems.
private struct MathFontData: Sendable {
    static let name = "STIXTwoMath-Regular"
    static let shared = MathFontData()

    let xHeight: CGFloat
    let scriptScale: CGFloat
    let scriptScriptScale: CGFloat
    let degreeRaise: CGFloat
    let overlap: CGFloat
    let italics: [CGGlyph: CGFloat]
    let accents: [CGGlyph: CGFloat]
    let vertical: [CGGlyph: MathConstruction]
    let horizontal: [CGGlyph: MathConstruction]
    private let constants: [CGFloat]

    subscript(_ constant: MathConstant) -> CGFloat { constants[constant.rawValue] }

    private init?() {
        let font = CTFontCreateWithName(Self.name as CFString, 1000, nil)
        guard CTFontCopyPostScriptName(font) as String == Self.name, let data = CTFontCopyTable(font, CTFontTableTag(0x4D41_5448), []) as Data? else {
            return nil
        }
        let table = FontTable(data: data), em = CGFloat(CTFontGetUnitsPerEm(font))
        let constantsAt = table.u16(4), infoAt = table.u16(6), variantsAt = table.u16(8)
        guard em > 0, constantsAt > 0, infoAt > 0, variantsAt > 0 else { return nil }
        xHeight = CTFontGetXHeight(font) / 1000
        scriptScale = table.i16(constantsAt) / 100
        scriptScriptScale = table.i16(constantsAt + 2) / 100
        constants = [0, 0, CGFloat(table.u16(constantsAt + 4)) / em, CGFloat(table.u16(constantsAt + 6)) / em]
            + (0..<51).map { table.i16(constantsAt + 8 + 4 * $0) / em }
        degreeRaise = table.i16(constantsAt + 212) / 100

        func values(_ offset: Int) -> [CGGlyph: CGFloat] {
            guard offset > 0 else { return [:] }
            let at = infoAt + offset, glyphs = table.coverage(at + table.u16(at)), count = min(table.u16(at + 2), glyphs.count)
            return Dictionary((0..<count).map { (glyphs[$0], table.i16(at + 4 + 4 * $0) / em) }, uniquingKeysWith: { first, _ in first })
        }
        italics = values(table.u16(infoAt))
        accents = values(table.u16(infoAt + 2))

        overlap = CGFloat(table.u16(variantsAt)) / em
        let verticalCount = table.u16(variantsAt + 6), horizontalCount = table.u16(variantsAt + 8)
        func constructions(coverage offset: Int, count: Int, first: Int) -> [CGGlyph: MathConstruction] {
            guard offset > 0 else { return [:] }
            let glyphs = table.coverage(variantsAt + offset)
            var constructions: [CGGlyph: MathConstruction] = [:]
            for index in 0..<min(count, glyphs.count) {
                let at = variantsAt + table.u16(variantsAt + 10 + 2 * (first + index))
                let variants = (0..<table.u16(at + 2)).map {
                    MathVariant(glyph: CGGlyph(table.u16(at + 4 + 4 * $0)), advance: CGFloat(table.u16(at + 6 + 4 * $0)) / em)
                }
                var parts: [MathPart] = []
                if table.u16(at) > 0 {
                    let assembly = at + table.u16(at)
                    parts = (0..<table.u16(assembly + 4)).map {
                        let part = assembly + 6 + 10 * $0
                        return MathPart(glyph: CGGlyph(table.u16(part)), start: CGFloat(table.u16(part + 2)) / em, end: CGFloat(table.u16(part + 4)) / em,
                                        full: CGFloat(table.u16(part + 6)) / em, extender: table.u16(part + 8) & 1 != 0)
                    }
                }
                constructions[glyphs[index]] = MathConstruction(variants: variants, parts: parts)
            }
            return constructions
        }
        vertical = constructions(coverage: table.u16(variantsAt + 2), count: verticalCount, first: 0)
        horizontal = constructions(coverage: table.u16(variantsAt + 4), count: horizontalCount, first: verticalCount)
    }
}

private struct FontTable {
    let data: Data

    func u16(_ at: Int) -> Int {
        guard at >= 0, at + 1 < data.count else { return 0 }
        return Int(data[data.startIndex + at]) << 8 | Int(data[data.startIndex + at + 1])
    }

    func i16(_ at: Int) -> CGFloat {
        let value = u16(at)
        return CGFloat(value >= 0x8000 ? value - 0x10000 : value)
    }

    /// The glyphs a coverage table lists, in coverage order.
    func coverage(_ at: Int) -> [CGGlyph] {
        switch u16(at) {
        case 1:
            return (0..<u16(at + 2)).map { CGGlyph(u16(at + 4 + 2 * $0)) }
        case 2:
            var glyphs: [CGGlyph] = []
            for range in 0..<u16(at + 2) {
                let record = at + 4 + 6 * range, first = u16(record), last = u16(record + 2), index = u16(record + 4)
                guard last >= first else { continue }
                if glyphs.count < index + last - first + 1 { glyphs += Array(repeating: 0, count: index + last - first + 1 - glyphs.count) }
                for glyph in first...last { glyphs[index + glyph - first] = CGGlyph(glyph) }
            }
            return glyphs
        default:
            return []
        }
    }
}

/// Lays parsed formulas out the way TeX does, with the math font's own constants.
private final class MathSetter {
    private let size: CGFloat
    private let textFont: CTFont
    private let math: MathFontData
    private var fonts: [CGFloat: CTFont] = [:]
    /// How tall a `\middle` delimiter grows, while the fence holding it is set.
    private var middle: CGFloat?

    init(size: CGFloat, textFont: CTFont, math: MathFontData) {
        self.size = size
        self.textFont = textFont
        self.math = math
    }

    /// TeX's spaces between kinds of atom, in mu; negative ones are left out in scripts.
    private static let spacing: [[CGFloat]] = [
        [0, 3, -4, -5, 0, 0, 0, -3],
        [3, 3, 0, -5, 0, 0, 0, -3],
        [-4, -4, 0, 0, -4, 0, 0, -4],
        [-5, -5, 0, 0, -5, 0, 0, -5],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 3, -4, -5, 0, 0, 0, -3],
        [-3, -3, 0, -3, -3, -3, -3, -3],
        [-3, 3, -4, -5, -3, 0, -3, -3],
    ]

    private func em(_ style: MathStyle) -> CGFloat {
        switch style.level {
        case .display, .text: size
        case .script: size * math.scriptScale
        case .scriptScript: size * math.scriptScriptScale
        }
    }

    private func value(_ constant: MathConstant, _ style: MathStyle) -> CGFloat { math[constant] * em(style) }

    private func font(_ style: MathStyle) -> CTFont {
        let em = self.em(style)
        if let font = fonts[em] { return font }
        let font = CTFontCreateWithName(MathFontData.name as CFString, em, nil)
        fonts[em] = font
        return font
    }

    func list(_ nodes: [MathNode], _ start: MathStyle) -> MathBox {
        var style = start
        var items: [(box: MathBox, kind: MathKind?, style: MathStyle)] = []
        for node in nodes {
            if case .style(let level) = node {
                style = MathStyle(level: level, cramped: style.cramped)
                continue
            }
            let (box, kind) = atom(node, style)
            items.append((box, kind, style))
        }
        var last: Int?
        for index in items.indices {
            guard let kind = items[index].kind else { continue }
            let before = last.flatMap { items[$0].kind }
            if kind == .bin, before.map({ [MathKind.bin, .op, .rel, .open, .punct].contains($0) }) ?? true { items[index].kind = .ord }
            if [.rel, .close, .punct].contains(kind), let last, items[last].kind == .bin { items[last].kind = .ord }
            last = index
        }
        if let last, items[last].kind == .bin { items[last].kind = .ord }
        if items.count == 1 { return items[0].box }
        var box = MathBox(), previous: MathKind?
        for item in items {
            if let kind = item.kind {
                if let previous {
                    let mu = Self.spacing[previous.rawValue][kind.rawValue]
                    if mu > 0 || !item.style.isScript { box.width += abs(mu) * em(item.style) / 18 }
                }
                previous = kind
            }
            box.append(item.box)
            box.italic = item.box.italic
        }
        return box
    }

    private func atom(_ node: MathNode, _ style: MathStyle) -> (box: MathBox, kind: MathKind?) {
        switch node {
        case .symbol(let symbol, let kind):
            return (self.symbol(symbol, style), kind)
        case .word(let word, let kind):
            return (line(word, font(style)), kind)
        case .text(let text, let bold, let italic):
            return (line(text, textFace(style, bold: bold, italic: italic)), .ord)
        case .group(let nodes):
            return (list(nodes, style), .ord)
        case .scripts(let base, let sub, let sup):
            return scripts(base, sub: sub, sup: sup, style)
        case .largeOp(let symbol, _):
            return (largeOperator(symbol, style), .op)
        case .function(let name, _):
            return (line(name, font(style)), .op)
        case .fraction(let top, let bottom, let rule, let level, let fence):
            return (fraction(top, bottom, rule: rule, level: level, fence: fence, style), .inner)
        case .radical(let body, let degree):
            return (radical(body, degree: degree, style), .ord)
        case .fenced(let left, let body, let right):
            var inner = list(body, style)
            let height = fenceHeight(inner, style)
            if body.contains(where: \.isMiddle) {
                let outer = middle
                middle = height
                inner = list(body, style)
                middle = outer
            }
            return (fence(inner, left, right, height: height, style), .inner)
        case .middle(let symbol):
            return (delimiter(symbol, height: middle ?? 0, style), .rel)
        case .big(let symbol, let height, let kind):
            return (delimiter(symbol, height: height * em(style), style), kind)
        case .accent(let mark, let body, let wide):
            return (accent(mark, body, wide: wide, style), .ord)
        case .bar(let body, let over):
            return (bar(body, over: over, style), .ord)
        case .stretchy(let body, let symbol, let over, let kind):
            return (stretchy(body, symbol, over: over, style), kind)
        case .stack(let base, let over, let under):
            let (box, kind) = atom(base, style)
            return (limits(box, over: over.map { list($0, style.sup) }, under: under.map { list($0, style.sub) }, style), kind)
        case .space(let mu):
            return (MathBox(width: mu * em(style) / 18), nil)
        case .style:
            return (MathBox(), nil)
        case .table(let rows, let table):
            return self.table(rows, table, style)
        case .boxed(let body):
            return (boxed(body, style), .ord)
        }
    }

    private func glyph(for symbol: String, in font: CTFont) -> CGGlyph? {
        guard symbol.unicodeScalars.count == 1 else { return nil }
        let units = Array(symbol.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), glyphs[0] != 0 else { return nil }
        return glyphs[0]
    }

    private func glyphBox(_ glyph: CGGlyph, _ font: CTFont, _ style: MathStyle) -> MathBox {
        var glyph = glyph, ink = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &ink, 1)
        let advance = CGFloat(CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)), em = self.em(style)
        var box = MathBox(width: advance, ascent: ink.maxY, descent: -ink.minY)
        box.italic = (math.italics[glyph] ?? 0) * em
        box.accent = math.accents[glyph].map { $0 * em } ?? ink.midX
        box.single = true
        box.marks = [.glyph(font, glyph, .zero, stretch: 1)]
        return box
    }

    private func symbol(_ symbol: String, _ style: MathStyle) -> MathBox {
        let font = self.font(style)
        guard let glyph = self.glyph(for: symbol, in: font) else { return line(symbol, font) }
        return glyphBox(glyph, font, style)
    }

    private func line(_ text: String, _ font: CTFont) -> MathBox {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        var box = MathBox(width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        if !ink.isNull {
            box.ascent = ink.maxY
            box.descent = -ink.minY
        }
        box.marks = [.line(line, .zero)]
        return box
    }

    private func textFace(_ style: MathStyle, bold: Bool, italic: Bool) -> CTFont {
        let font = CTFontCreateCopyWithAttributes(textFont, CTFontGetSize(textFont) * em(style) / size, nil, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return font }
        return CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) ?? font
    }

    private func ruled(_ rect: CGRect) -> MathBox {
        MathBox(width: rect.maxX, ascent: rect.maxY, descent: -rect.minY, marks: [.rule(rect)])
    }

    private func centered(_ box: MathBox, _ style: MathStyle) -> MathBox {
        box.shifted(by: value(.axisHeight, style) - (box.ascent - box.descent) / 2)
    }

    private func takesLimits(_ node: MathNode, _ style: MathStyle) -> Bool {
        switch node {
        case .largeOp(_, let limits), .function(_, let limits): limits ?? (style.level == .display)
        case .stretchy(_, _, _, let kind): kind == .op
        default: false
        }
    }

    private func scripts(_ base: MathNode, sub: [MathNode]?, sup: [MathNode]?, _ style: MathStyle) -> (box: MathBox, kind: MathKind?) {
        let (nucleus, kind) = atom(base, style)
        let over = sup.map { list($0, style.sup) }, under = sub.map { list($0, style.sub) }
        if takesLimits(base, style) { return (limits(nucleus, over: over, under: under, style), kind) }
        var up: CGFloat = 0, down: CGFloat = 0
        if let over {
            up = max(value(style.cramped ? .superscriptShiftUpCramped : .superscriptShiftUp, style), over.descent + value(.superscriptBottomMin, style))
            if !nucleus.single { up = max(up, nucleus.ascent - value(.superscriptBaselineDropMax, style)) }
        }
        if let under {
            down = max(value(.subscriptShiftDown, style), under.ascent - value(.subscriptTopMax, style))
            if !nucleus.single { down = max(down, nucleus.descent + value(.subscriptBaselineDropMin, style)) }
        }
        if let over, let under {
            let gap = (up - over.descent) - (under.ascent - down), least = value(.subSuperscriptGapMin, style)
            if gap < least {
                down += least - gap
                let lift = value(.superscriptBottomMaxWithSubscript, style) - (up - over.descent)
                if lift > 0 {
                    up += lift
                    down -= lift
                }
            }
        }
        var box = nucleus, width = nucleus.width
        let overX = nucleus.width + (nucleus.isOperator ? 0 : nucleus.italic), underX = nucleus.width - (nucleus.isOperator ? nucleus.italic : 0)
        if let over {
            box.add(over, x: overX, y: up)
            width = max(width, overX + over.width)
        }
        if let under {
            box.add(under, x: underX, y: -down)
            width = max(width, underX + under.width)
        }
        box.width = width + value(.spaceAfterScript, style)
        box.italic = 0
        box.accent = nil
        box.single = false
        box.isOperator = false
        return (box, kind)
    }

    private func limits(_ base: MathBox, over: MathBox?, under: MathBox?, _ style: MathStyle) -> MathBox {
        let width = max(base.width, over?.width ?? 0, under?.width ?? 0), lean = base.italic / 2
        var box = MathBox(width: width)
        box.add(base, x: (width - base.width) / 2)
        if let over {
            let gap = max(value(.upperLimitGapMin, style), value(.upperLimitBaselineRiseMin, style) - over.descent)
            box.add(over, x: (width - over.width) / 2 + lean, y: base.ascent + gap + over.descent)
        }
        if let under {
            let gap = max(value(.lowerLimitGapMin, style), value(.lowerLimitBaselineDropMin, style) - under.ascent)
            box.add(under, x: (width - under.width) / 2 - lean, y: -(base.descent + gap + under.ascent))
        }
        return box
    }

    private func largeOperator(_ symbol: String, _ style: MathStyle) -> MathBox {
        let font = self.font(style)
        guard var glyph = self.glyph(for: symbol, in: font) else { return line(symbol, font) }
        if style.level == .display, let variants = math.vertical[glyph]?.variants {
            let least = math[.displayOperatorMinHeight]
            glyph = (variants.first { $0.advance >= least } ?? variants.last)?.glyph ?? glyph
        }
        var box = centered(glyphBox(glyph, font, style), style)
        box.single = false
        box.isOperator = true
        return box
    }

    private func fraction(_ top: [MathNode], _ bottom: [MathNode], rule: Bool, level: MathStyle.Level?, fence: Bool, _ outer: MathStyle) -> MathBox {
        let style = level.map { MathStyle(level: $0, cramped: outer.cramped) } ?? outer, display = style.level == .display
        let numerator = list(top, style.numerator), denominator = list(bottom, style.denominator)
        let axis = value(.axisHeight, style), thickness = rule ? value(.fractionRuleThickness, style) : 0
        var up: CGFloat, down: CGFloat
        if rule {
            up = max(value(display ? .fractionNumeratorDisplayStyleShiftUp : .fractionNumeratorShiftUp, style),
                     axis + thickness / 2 + value(display ? .fractionNumDisplayStyleGapMin : .fractionNumeratorGapMin, style) + numerator.descent)
            down = max(value(display ? .fractionDenominatorDisplayStyleShiftDown : .fractionDenominatorShiftDown, style),
                       value(display ? .fractionDenomDisplayStyleGapMin : .fractionDenominatorGapMin, style) + denominator.ascent - axis + thickness / 2)
        } else {
            up = value(display ? .stackTopDisplayStyleShiftUp : .stackTopShiftUp, style)
            down = value(display ? .stackBottomDisplayStyleShiftDown : .stackBottomShiftDown, style)
            let gap = (up - numerator.descent) - (denominator.ascent - down), least = value(display ? .stackDisplayStyleGapMin : .stackGapMin, style)
            if gap < least {
                up += (least - gap) / 2
                down += (least - gap) / 2
            }
        }
        let pad = 0.12 * em(style), inner = max(numerator.width, denominator.width)
        var box = MathBox(width: inner + 2 * pad)
        box.add(numerator, x: pad + (inner - numerator.width) / 2, y: up)
        box.add(denominator, x: pad + (inner - denominator.width) / 2, y: -down)
        if rule { box.add(ruled(CGRect(x: pad, y: axis - thickness / 2, width: inner, height: thickness))) }
        return fence ? self.fence(box, "(", ")", height: fenceHeight(box, style), style) : box
    }

    private func radical(_ body: [MathNode], degree: [MathNode]?, _ style: MathStyle) -> MathBox {
        let inner = list(body, style.squeezed), thickness = value(.radicalRuleThickness, style)
        var gap = value(style.level == .display ? .radicalDisplayStyleVerticalGap : .radicalVerticalGap, style)
        let needed = inner.ascent + inner.descent + gap + thickness
        let sign = stretched("\u{221A}", to: needed, vertical: true, style), height = sign.ascent + sign.descent
        if height > needed { gap += (height - needed) / 2 }
        let top = inner.ascent + gap + thickness
        var box = MathBox(), x: CGFloat = 0
        if let degree {
            let index = list(degree, MathStyle(level: .scriptScript, cramped: true))
            let before = value(.radicalKernBeforeDegree, style), after = value(.radicalKernAfterDegree, style)
            box.add(index, x: before, y: top - height + math.degreeRaise * height)
            x = max(0, before + index.width + after)
        }
        box.add(sign.shifted(by: top - sign.ascent), x: x)
        x += sign.width
        box.add(ruled(CGRect(x: x, y: top - thickness, width: inner.width, height: thickness)))
        box.add(inner, x: x)
        box.width = x + inner.width
        box.ascent = max(box.ascent, top + value(.radicalExtraAscender, style))
        return box
    }

    /// A glyph grown along an axis to at least `target`: one of its bigger cuts, else built from its pieces, else stretched.
    private func stretched(_ symbol: String, to target: CGFloat, vertical: Bool, _ style: MathStyle) -> MathBox {
        let font = self.font(style), em = self.em(style)
        guard let glyph = self.glyph(for: symbol, in: font) else { return line(symbol, font) }
        let base = glyphBox(glyph, font, style)
        func extent(_ box: MathBox) -> CGFloat { vertical ? box.ascent + box.descent : box.width }
        guard extent(base) < target, let construction = (vertical ? math.vertical : math.horizontal)[glyph] else { return base }
        if let variant = construction.variants.first(where: { $0.advance * em >= target }) { return glyphBox(variant.glyph, font, style) }
        if !construction.parts.isEmpty { return assembled(construction.parts, to: target, vertical: vertical, font, style) }
        guard vertical, let biggest = construction.variants.last else { return base }
        var box = glyphBox(biggest.glyph, font, style)
        let factor = target / max(extent(box), 1)
        box.marks = [.glyph(font, biggest.glyph, .zero, stretch: factor)]
        box.ascent *= factor
        box.descent *= factor
        return box
    }

    private func assembled(_ parts: [MathPart], to target: CGFloat, vertical: Bool, _ font: CTFont, _ style: MathStyle) -> MathBox {
        let em = self.em(style), least = math.overlap * em
        func length(_ pieces: [MathPart]) -> CGFloat { pieces.reduce(0) { $0 + $1.full * em } - least * CGFloat(max(pieces.count - 1, 0)) }
        var pieces = parts.filter { !$0.extender }
        if parts.contains(where: \.extender) {
            for repeats in 1...100 where length(pieces) < target {
                pieces = parts.flatMap { $0.extender ? Array(repeating: $0, count: repeats) : [$0] }
            }
        }
        let full = pieces.reduce(0) { $0 + $1.full * em }
        let overlap = pieces.count > 1 ? max(least, (full - target) / CGFloat(pieces.count - 1)) : 0
        var box = MathBox(), at: CGFloat = 0
        for (index, piece) in pieces.enumerated() {
            let part = glyphBox(piece.glyph, font, style)
            if vertical {
                box.add(part, y: at + part.descent)
                box.width = max(box.width, part.width)
            } else {
                box.add(part, x: at)
            }
            at += piece.full * em
            if index + 1 < pieces.count { at -= min(overlap, max(min(piece.end, pieces[index + 1].start) * em, least)) }
        }
        if !vertical { box.width = at }
        return box
    }

    private func delimiter(_ symbol: String, height: CGFloat, _ style: MathStyle) -> MathBox {
        guard !symbol.isEmpty else { return MathBox(width: 0.12 * em(style)) }
        var box = centered(stretched(symbol, to: height, vertical: true, style), style)
        box.single = false
        return box
    }

    private func fenceHeight(_ inner: MathBox, _ style: MathStyle) -> CGFloat {
        let axis = value(.axisHeight, style), reach = 2 * max(inner.ascent - axis, inner.descent + axis)
        return max(reach * 0.901, reach - 0.5 * em(style))
    }

    private func fence(_ inner: MathBox, _ left: String, _ right: String, height: CGFloat, _ style: MathStyle) -> MathBox {
        var box = MathBox()
        box.append(delimiter(left, height: height, style))
        box.append(inner)
        box.append(delimiter(right, height: height, style))
        return box
    }

    private func accent(_ mark: String, _ body: [MathNode], wide: Bool, _ style: MathStyle) -> MathBox {
        let base = list(body, style.squeezed), font = self.font(style)
        guard var glyph = self.glyph(for: mark, in: font) else { return base }
        if wide, let variants = math.horizontal[glyph]?.variants {
            glyph = variants.last { $0.advance * em(style) <= base.width }?.glyph ?? glyph
        }
        let accent = glyphBox(glyph, font, style)
        var box = base
        box.add(accent, x: (base.accent ?? base.width / 2) - (accent.accent ?? accent.width / 2), y: max(0, base.ascent - value(.accentBaseHeight, style)))
        box.accent = nil
        box.single = false
        return box
    }

    private func bar(_ body: [MathNode], over: Bool, _ style: MathStyle) -> MathBox {
        let base = list(body, over ? style.squeezed : style)
        var box = base
        if over {
            let gap = value(.overbarVerticalGap, style), thickness = value(.overbarRuleThickness, style)
            box.add(ruled(CGRect(x: 0, y: base.ascent + gap, width: base.width, height: thickness)))
            box.ascent = base.ascent + gap + thickness + value(.overbarExtraAscender, style)
        } else {
            let gap = value(.underbarVerticalGap, style), thickness = value(.underbarRuleThickness, style)
            box.add(ruled(CGRect(x: 0, y: -base.descent - gap - thickness, width: base.width, height: thickness)))
            box.descent = base.descent + gap + thickness + value(.underbarExtraDescender, style)
        }
        box.italic = 0
        box.accent = nil
        box.single = false
        return box
    }

    /// A brace or arrow stretched over or under its body.
    private func stretchy(_ body: [MathNode], _ symbol: String, over: Bool, _ style: MathStyle) -> MathBox {
        let base = list(body, style), mark = stretched(symbol, to: base.width, vertical: false, style)
        let width = max(base.width, mark.width)
        var box = MathBox(width: width)
        box.add(base, x: (width - base.width) / 2)
        let y = over ? base.ascent + value(.stretchStackGapBelowMin, style) + mark.descent
            : -(base.descent + value(.stretchStackGapAboveMin, style) + mark.ascent)
        box.add(mark, x: (width - mark.width) / 2, y: y)
        return box
    }

    private func boxed(_ body: [MathNode], _ style: MathStyle) -> MathBox {
        let base = list(body, style), pad = 0.3 * em(style), line = value(.fractionRuleThickness, style)
        let frame = CGRect(x: 0, y: -base.descent - pad - line, width: base.width + 2 * (pad + line), height: base.ascent + base.descent + 2 * (pad + line))
        var box = MathBox(width: frame.width)
        box.add(base, x: pad + line)
        for edge in [CGRect(x: 0, y: frame.minY, width: frame.width, height: line), CGRect(x: 0, y: frame.maxY - line, width: frame.width, height: line),
                     CGRect(x: 0, y: frame.minY, width: line, height: frame.height), CGRect(x: frame.maxX - line, y: frame.minY, width: line, height: frame.height)] {
            box.add(ruled(edge))
        }
        return box
    }

    private func table(_ rows: [[[MathNode]]], _ table: MathTable, _ style: MathStyle) -> (box: MathBox, kind: MathKind?) {
        let cellStyle = MathStyle(level: style.isScript ? style.level : table.level), em = self.em(cellStyle)
        let cells = rows.map { row in row.enumerated().map { column, nodes in list(table.pairs && column % 2 == 1 ? [.group([])] + nodes : nodes, cellStyle) } }
        let columns = cells.map(\.count).max() ?? 0
        var widths = [CGFloat](repeating: 0, count: columns)
        for row in cells {
            for (column, cell) in row.enumerated() { widths[column] = max(widths[column], cell.width) }
        }
        let ups = cells.map { row in row.reduce(0.84 * em) { max($0, $1.ascent) } }, downs = cells.map { row in row.reduce(0.36 * em) { max($0, $1.descent) } }
        let jot = table.jot * em, height = zip(ups, downs).reduce(0) { $0 + $1.0 + $1.1 } + jot * CGFloat(max(cells.count - 1, 0))
        let axis = value(.axisHeight, style)
        var box = MathBox(), y = height / 2 + axis
        for (index, row) in cells.enumerated() {
            y -= ups[index]
            var x: CGFloat = 0
            for column in 0..<columns {
                if column < row.count {
                    let free = widths[column] - row[column].width
                    let dx: CGFloat = switch table.aligns[column % table.aligns.count] {
                    case .left: 0
                    case .center: free / 2
                    case .right: free
                    }
                    box.add(row[column], x: x + dx, y: y)
                }
                x += widths[column]
                if column + 1 < columns { x += table.gaps[column % table.gaps.count] * em }
            }
            box.width = max(box.width, x)
            y -= downs[index] + jot
        }
        box.ascent = height / 2 + axis
        box.descent = height / 2 - axis
        guard !table.left.isEmpty || !table.right.isEmpty else { return (box, .ord) }
        return (fence(box, table.left, table.right, height: fenceHeight(box, style), style), .inner)
    }
}
