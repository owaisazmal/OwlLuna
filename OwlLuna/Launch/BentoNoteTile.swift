import SwiftUI

/// The note page: ruled paper with a margin and three punched holes, filled in by hand with a checklist, a row of moon phases and a squiggle.
enum BentoNoteTile {
    static func draw(_ context: GraphicsContext, size: CGSize, scene: BentoScene) {
        let pitch = min(size.height * 0.116, size.width * 0.113)
        guard pitch > 0 else { return }
        drawPaper(context, size: size, pitch: pitch, scene: scene)
        let page = CGRect(x: context.edge(pitch * 1.95), y: context.edge(pitch * 1.9), width: pitch * 6.6, height: pitch * 6)
        drawInk(context.moved(by: .fitting(inkBox, in: page, anchor: .topLeading)), scene: scene)
        drawLabels(context, size: size, pitch: pitch, scene: scene)
    }

    private static let margin = SplashBeat(delay: 560, duration: 520)
    private static let header = SplashBeat(delay: 600, duration: 520)
    private static let rules = (0..<9).map { SplashBeat(delay: 640 + 40 * Double($0), duration: 460) }
    private static let holes = (0..<3).map { SplashBeat(delay: 620 + 70 * Double($0), duration: 420, curve: .bounce) }
    private static let labels = [SplashBeat(delay: 680, duration: 450), SplashBeat(delay: 740, duration: 450)]

    private static func drawPaper(_ context: GraphicsContext, size: CGSize, pitch: CGFloat, scene: BentoScene) {
        let unit = scene.unit, palette = scene.palette, time = scene.time
        let hairline = context.pixels(unit * 0.24, .down), rim = context.pixels(unit * 0.36, .down)
        for index in 0..<max(rules.count, Int(size.height / pitch - 2.4)) {
            let foot = context.edge(pitch * (2.9 + CGFloat(index)))
            let drawn = rules[min(index, rules.count - 1)].progress(time)
            context.fill(Path(CGRect(x: 0, y: foot - hairline, width: size.width * drawn, height: hairline)), with: .color(palette.rule))
        }
        let bar = CGRect(x: 0, y: context.edge(pitch * 1.9 - unit * 0.5), width: size.width * header.progress(time), height: context.pixels(unit * 0.5))
        let stripe = CGRect(x: context.edge(pitch * 1.5), y: 0, width: context.pixels(unit * 0.38), height: size.height * margin.progress(time))
        context.fill(Path(bar), with: .color(palette.ink))
        context.fill(Path(stripe), with: .color(palette.tomato))
        for (beat, y) in zip(holes, [pitch * 0.95, size.height / 2, size.height - pitch * 0.95]) {
            let grown = beat.progress(time)
            guard grown > 0 else { continue }
            let radius = (pitch * 0.28 - rim / 2) * grown
            let hole = Path(ellipseIn: CGRect(x: pitch * 0.75 - radius, y: y - radius, width: radius * 2, height: radius * 2))
            context.paint(hole, fill: palette.ground, stroke: palette.ink, width: rim * grown)
        }
    }

    private static func drawLabels(_ context: GraphicsContext, size: CGSize, pitch: CGFloat, scene: BentoScene) {
        let em = scene.labelSize, line = pitch * 0.95 - em / 2
        context.label(BentoWords.notes, corner: CGPoint(x: pitch * 1.95, y: line), shown: labels[0].progress(scene.time), scene: scene)
        context.label(BentoWords.page, corner: CGPoint(x: size.width - em * 1.3, y: line), trailing: true, shown: labels[1].progress(scene.time), scene: scene)
    }

    /// The drawing's own coordinates, in which the ruled lines are 36 apart.
    private static let inkBox = CGSize(width: 237.6, height: 216)
    private static let wordStart: CGFloat = 35
    /// As far along a row as the pen may go, so that its ink ends before 170 and stands clear of the star.
    private static let wordEnd: CGFloat = 168
    /// As far above its baseline as a row's ink may reach, so that a mark on a capital stands clear of the bar or the rule above.
    private static let wordRise: CGFloat = 29.5
    /// What each row says when the hand cannot print its word.
    private static let english = BentoWords.verbs.map(\.english)

    private static func baseline(_ row: Int) -> CGFloat { 31 + 36 * CGFloat(row) }

    /// A word of the checklist as the pen prints it on its row, in the drawing's coordinates.
    struct Word: Sendable {
        let strokes: Path
        /// The box round the pen's path; the ink reaches half the pen's width beyond it.
        let bounds: CGRect
        /// The size the word is printed at; at 1 its capitals are 21 tall and the pen 3.2 wide.
        let scale: CGFloat

        var penWidth: CGFloat { NoteHand.penWidth * scale }
    }

    /// Whether the hand has strokes for every character of `word`; small letters count as their capitals, and a space between two words needs none.
    static func canPrint(_ word: String) -> Bool {
        NoteHand.strokes(of: word) != nil
    }

    /// One word a row from the top, all at one size: full size, or as large as lets the longest end before the star and the tallest stand clear of the rule above.
    static func printed(_ words: [String]) -> [Word] {
        let fullSize = zip(words, english).compactMap { NoteHand.strokes(of: $0) ?? NoteHand.strokes(of: $1) }
        guard let longest = fullSize.map(\.boundingRect.maxX).max(), let highest = fullSize.map(\.boundingRect.minY).min() else { return [] }
        let tallest = NoteHand.capHeight - highest + NoteHand.penWidth / 2
        let scale = min(1, (wordEnd - wordStart) / longest, wordRise / tallest)
        return fullSize.enumerated().map { row, word in
            let onRow = CGAffineTransform(translationX: wordStart, y: baseline(row)).scaledBy(x: scale, y: scale).translatedBy(x: 0, y: -NoteHand.capHeight)
            let strokes = word.applying(onRow)
            return Word(strokes: strokes, bounds: strokes.boundingRect, scale: scale)
        }
    }

    /// The checklist in the reader's language.
    static let checklist = printed(BentoWords.verbs.map(\.word))

    /// The highlighter's stripe over the third word: a little longer than the word, and from above its capitals to below its foot.
    private static let swatch: CGRect = {
        let word = checklist[2], scale = word.scale
        return CGRect(x: word.bounds.minX - 6.75 * scale, y: baseline(2) - 23 * scale, width: word.bounds.width + 13.5 * scale, height: 27 * scale)
    }()
    private static let highlighter = Path(roundedRect: swatch, cornerRadius: 2, style: .circular)
    private static let highlight = SplashBeat(delay: 1460, duration: 240)

    /// Each phase's outline, begun at three o'clock and drawn clockwise.
    private static let moons = (0..<5).map { index in
        Path { $0.addRelativeArc(center: CGPoint(x: 16 + 42 * CGFloat(index), y: 162), radius: 13.5, startAngle: .zero, delta: .degrees(360)) }
    }
    /// The dark side of each phase, new moon first; the full moon has none.
    private static let shadows = [
        moons[0],
        Path(svg: "M58,148.5 A13.5,13.5 0 0 0 58,175.5 A6,13.5 0 0 0 58,148.5 Z"),
        Path(svg: "M100,148.5 A13.5,13.5 0 0 0 100,175.5 Z"),
        Path(svg: "M142,148.5 A13.5,13.5 0 0 0 142,175.5 A6,13.5 0 0 1 142,148.5 Z"),
    ]
    private static let shading = (0..<4).map { SplashBeat(delay: 1300 + 65 * Double($0), duration: 160, curve: .easeOut) }

    /// Everything the pen draws, in the order it lies on the page: boxes, words, ticks, the star, the phases and the squiggle.
    private static let lines: [PenLine] = {
        let box = Path(svg: "M4,13.5 L19.5,13 L20,29 L4.5,29.5 Z"), tick = Path(svg: "M6.5,20 L12,27 L24.5,7.5")
        let star = Path(svg: "M200,21 L214.6,66 L176.3,38.2 L223.7,38.2 L185.4,66 Z")
        let squiggle = Path(svg: "M4,207 q4.5,-9 9,0 t9,0 t9,0 t9,0 t9,0 m11,0 q4.5,-9 9,0 t9,0 t9,0 m11,0 q4.5,-9 9,0 t9,0 t9,0 t9,0")
        func row(_ path: Path, _ index: Int) -> Path { path.applying(CGAffineTransform(translationX: 0, y: 36 * CGFloat(index))) }
        func beat(_ delay: Double, _ duration: Double, _ curve: SplashCurve = .glide) -> SplashBeat { SplashBeat(delay: delay, duration: duration, curve: curve) }
        var lines = (0..<3).map { PenLine(row(box, $0), width: 2.8, beat: beat(760 + 70 * Double($0), 260)) }
        lines += checklist.enumerated().map { PenLine($1.strokes, width: $1.penWidth, beat: beat(840 + 180 * Double($0), 320, .bezier(0.4, 0, 0.6, 1))) }
        lines += (0..<2).map { PenLine(row(tick, $0), width: 4, red: true, beat: beat(1190 + 180 * Double($0), 170, .easeOut)) }
        lines.append(PenLine(star, width: 3.6, red: true, beat: beat(1330, 340, .easeInOut)))
        lines += moons.indices.map { PenLine(moons[$0], width: 2.8, beat: beat(1120 + 65 * Double($0), 300, .easeInOut)) }
        lines.append(PenLine(squiggle, width: 3.2, beat: beat(1440, 240, .linear)))
        return lines
    }()

    private static func drawInk(_ context: GraphicsContext, scene: BentoScene) {
        let palette = scene.palette, time = scene.time
        let swept = highlight.progress(time)
        if swept > 0 {
            let sweep = CGAffineTransform(translationX: swatch.minX, y: 0).scaledBy(x: swept, y: 1).translatedBy(x: -swatch.minX, y: 0)
            context.moved(by: sweep).fill(highlighter, with: .color(palette.moon))
        }
        for (shadow, beat) in zip(shadows, shading) {
            context.fill(shadow, with: .color(palette.ink.opacity(beat.progress(time))))
        }
        for line in lines {
            line.draw(in: context, at: time, palette: palette)
        }
    }
}

/// A line of the drawing and the beat that draws it. Its strokes all start together, each at the pace of the whole line.
private struct PenLine: Sendable {
    private let strokes: [(path: Path, share: Double)]
    private let width: CGFloat
    private let red: Bool
    private let beat: SplashBeat

    init(_ path: Path, width: CGFloat, red: Bool = false, beat: SplashBeat) {
        strokes = path.strokes
        self.width = width
        self.red = red
        self.beat = beat
    }

    func draw(in context: GraphicsContext, at time: Double, palette: SplashPalette) {
        context.draw(strokes: strokes, upTo: beat.progress(time), stroke: red ? palette.tomato : palette.ink, width: width)
    }
}

/// The hand the checklist is printed in: leaning capitals, each standing a little off its neighbours' line.
private enum NoteHand {
    static let capHeight: CGFloat = 21
    static let penWidth: CGFloat = 3.2
    /// How far a stroke leans to the right for each unit it rises: nine degrees.
    static let slant: CGFloat = 0.158
    static let letterGap: CGFloat = 5.7
    /// The room a space leaves between two words, on top of the gap after a letter.
    static let wordSpace: CGFloat = 10

    struct Capital: Sendable {
        let width: CGFloat
        var strokes: Path

        init(_ width: CGFloat, _ strokes: String) {
            self.width = width
            self.strokes = Path(svg: strokes)
        }
    }

    /// Each capital standing upright, its top at 0 and its foot at 21, with the room it takes on the line.
    static let capitals: [Character: Capital] = [
        "A": Capital(15.6, "M0,21.1 L7.7,0 L15.6,20.8 M2.9,13.4 L12.8,13.2"),
        "B": Capital(14, "M0.1,21 L0,0 M0,0.5 Q12.4,-0.5 12,5.4 Q11.6,10.5 2.2,10.4 Q14.8,10.2 14,15.8 Q13.4,21.3 0.1,20.9"),
        "C": Capital(14.8, "M13.7,4.4 Q8.4,-2.5 3.1,4 Q-2.2,11.1 3.1,17 Q8.3,23 14.1,17"),
        "D": Capital(14.8, "M0.1,20.9 L0,0 M0,0.6 Q15.8,0.6 14.8,11 Q14.3,20.9 0.1,20.9"),
        "E": Capital(12.7, "M12.1,0.2 L0,0.3 L0,20.7 L12.6,20.7 M0,10.2 L9.5,10.1"),
        "F": Capital(12.3, "M12.3,0.1 L0.1,0.3 L0,21 M0,10.3 L9,10.1"),
        "G": Capital(14.8, "M13.7,4.4 Q8.4,-2.5 3.1,4 Q-2.2,11.1 3.1,17 Q8.3,23 14,16.9 L14.2,11.4 L8.2,11.6"),
        "H": Capital(14.3, "M-0.2,-0.2 L-0.1,20.6 M14.1,0.3 L14.2,21.1 M-0.2,10.7 L14.1,10.7"),
        "I": Capital(4.3, "M2.2,0 L2.1,21"),
        "J": Capital(11.2, "M10.9,0 L10.8,14 Q10.8,21.6 5.4,21.4 Q0.4,21.3 0,15.4"),
        "K": Capital(13.7, "M0,0 L0,21 M12.6,0.4 L0.5,12.7 M4.7,9.1 L13.7,21.5"),
        "L": Capital(12, "M0.1,0 L0,20.8 L12,20.6"),
        "M": Capital(18.4, "M0,21 L1.8,0.1 L9.2,13.4 L16.2,0 L18.4,20.8"),
        "N": Capital(14.8, "M0,21 L0.1,0.2 L14.5,20.8 L14.7,-0.2"),
        "O": Capital(15.4, "M12.8,3.9 Q7.8,-3.3 3.1,4 Q-2.2,10.8 3.1,17.3 Q8,24 12.8,17.1 Q17.6,9.3 11.8,2.6"),
        "P": Capital(13.6, "M0.1,21 L0,0 M0,0.5 Q13.9,-0.5 13.4,6.4 Q12.9,12.3 0.1,12"),
        "Q": Capital(15.4, "M12.8,3.9 Q7.8,-3.3 3.1,4 Q-2.2,10.8 3.1,17.3 Q8,24 12.8,17.1 Q17.6,9.3 11.8,2.6 M9.3,15 L16.5,22.4"),
        "R": Capital(14.7, "M0.1,21 L0,0 M0,0.5 Q13.7,-0.6 13.2,6.2 Q12.6,11.9 0.1,11.6 M5.3,11.7 L13.7,21.4"),
        "S": Capital(13.1, "M11.1,3.2 Q5.1,-2.6 1.1,3.2 Q-2.4,8.9 5.6,10.5 Q14,12.5 11.1,17.8 Q7,23.5 -0.5,17.8"),
        "T": Capital(15.8, "M0,0.5 L15.7,0.5 M7.9,0.8 L7.8,21.2"),
        "U": Capital(14.7, "M0,-0.2 L-0.1,13.4 Q-0.1,21.3 7.3,21.5 Q14.6,21.8 14.6,13.9 L14.6,0.2"),
        "V": Capital(15.6, "M0,0.2 L7.6,21 L15.6,-0.2"),
        "W": Capital(20.4, "M-1.2,0 L4.4,21 L9.2,8.4 L14.9,21 L19,0.1"),
        "X": Capital(14.4, "M0.4,0.2 L14.4,21 M13.9,-0.1 L0,20.8"),
        "Y": Capital(15.8, "M0,-0.3 L7.9,10.9 L15.8,0.3 M7.9,10.9 L7.8,20.9"),
        "Z": Capital(13.8, "M0.3,0.4 L13.6,0.2 L0,20.7 L13.8,20.5"),
    ]

    /// The hyphen and the apostrophe, straight or curled; they stand in a word as capitals do, but carry no mark.
    static let joiners: [Character: Capital] = [
        "-": Capital(8.4, "M0.3,11.6 L8.1,11.2"),
        "'": Capital(1.6, "M1.3,-0.8 L0.6,5.2"),
        "\u{2019}": Capital(1.6, "M1.3,-0.8 L0.6,5.2"),
    ]

    /// The marks a capital may carry, drawn from the middle of its top: grave, acute, circumflex, tilde, diaeresis and cedilla.
    static let marks: [Unicode.Scalar: Path] = [
        "\u{300}": Path(svg: "M-1.9,-7.2 L1.5,-4.2"),
        "\u{301}": Path(svg: "M1.7,-7.2 L-1.7,-4.2"),
        "\u{302}": Path(svg: "M-3.6,-4.2 L0.2,-7.4 L3.8,-4.4"),
        "\u{303}": Path(svg: "M-4.8,-4.8 Q-2.4,-8.2 0,-5.8 Q2.4,-3.4 4.8,-6.6"),
        "\u{308}": Path(svg: "M-3.6,-5.8 L-3.4,-5.4 M3.4,-5.9 L3.6,-5.5"),
        "\u{327}": Path(svg: "M1,21.4 Q3.6,24.2 -0.8,26"),
    ]

    /// How far below the line each letter of a word sits and how many degrees it tips, one letter after another; a longer word goes round again.
    static let unevenness: [(drop: CGFloat, turn: Double)] = [
        (-0.9, -2.7), (-0.7, 0.65), (0, -0.3), (0.2, -1.05), (0.95, -2.2), (-0.85, -2.9),
        (0.4, -0.8), (-0.3, 0.4), (0.7, -1.9), (-0.6, -0.5), (0.1, -2.5), (0.8, 0.2),
    ]

    /// A character standing upright: a capital, under its mark if it carries one, or a joiner; nil if it has no strokes.
    static func upright(_ character: Character) -> Capital? {
        let scalars = Array(character.unicodeScalars)
        guard scalars.count <= 2, let first = scalars.first, var capital = capitals[Character(first)] else { return joiners[character] }
        for scalar in scalars.dropFirst() {
            guard let mark = marks[scalar] else { return nil }
            capital.strokes.addPath(mark, transform: CGAffineTransform(translationX: capital.width / 2, y: 0))
        }
        return capital
    }

    /// The word in capitals at full size, its tops at 0 and its feet at 21, a space left as a gap; nil if it is empty or a character has no strokes.
    static func strokes(of word: String) -> Path? {
        let letters = Array(word.uppercased().decomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        guard !letters.isEmpty else { return nil }
        var line = Path(), x: CGFloat = 0
        for (index, letter) in letters.enumerated() {
            guard letter != " " else { x += wordSpace; continue }
            guard let shape = upright(letter) else { return nil }
            let wobble = unevenness[index % unevenness.count]
            let middle = CGPoint(x: shape.width / 2, y: capHeight / 2)
            let lean = CGAffineTransform(a: 1, b: 0, c: -slant, d: 1, tx: slant * middle.y, ty: 0)
            let place = lean.concatenating(.turning(wobble.turn, about: middle)).concatenating(CGAffineTransform(translationX: x, y: wobble.drop))
            line.addPath(shape.strokes, transform: place)
            x += shape.width + letterGap
        }
        return line
    }
}

private extension GraphicsContext {
    /// A position moved to the nearest pixel, so that rules and bars keep hard edges.
    func edge(_ position: CGFloat) -> CGFloat {
        (position * environment.displayScale).rounded() / environment.displayScale
    }

    /// A thickness in whole pixels, never less than one.
    func pixels(_ thickness: CGFloat, _ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> CGFloat {
        max(1, (thickness * environment.displayScale).rounded(rule)) / environment.displayScale
    }
}
