import SwiftUI

/// A line of the condensed display face whose letters rise from under it one after another.
private struct RisingLine: Sendable {
    /// The line's measure in ems: its depth, how far down the baseline lies, and how tall a capital stands. The face is scaled to that capital.
    static let height: CGFloat = 0.84
    static let baseline: CGFloat = 0.819
    static let capHeight: CGFloat = 0.7905

    private let type: SplashType
    private let scale: CGFloat
    private let beats: [SplashBeat]

    var width: CGFloat { type.width * scale }

    init(_ text: String, tracking: CGFloat, delay: Double, stagger: Double, duration: Double) {
        type = SplashType(text, font: OwlLunaFonts.splashTitle(size: 1000, width: 62), tracking: tracking)
        scale = Self.capHeight / type.capHeight
        beats = type.letters.indices.map {
            SplashBeat(delay: delay + Double($0) * stagger, duration: duration, curve: .spring(damping: 0.66, settle: 6.6))
        }
    }

    /// `origin` is the top left of the line box. The clip opens `headroom` ems above it, where the spring carries a letter past its place.
    func draw(_ context: GraphicsContext, at origin: CGPoint, em: CGFloat, headroom: CGFloat, time: Double, fill: (Int) -> Color) {
        var window = context
        window.clip(to: Path(CGRect(x: origin.x - em, y: origin.y - headroom * em, width: (width + 2) * em, height: (headroom + Self.height) * em)))
        let body = scale * em
        for (index, letter) in type.letters.enumerated() {
            let drop = (1 - beats[index].progress(time)) * 1.12 * Self.height
            let place = CGAffineTransform(translationX: origin.x + letter.x * body, y: origin.y + (Self.baseline + drop) * em)
            window.moved(by: place.scaledBy(x: body, y: body)).fill(letter.outline, with: .color(fill(index)))
        }
    }
}

/// The wordmark slab: OWLLUNA rises letter by letter over a rule that grows from the left.
enum BentoWordTile {
    private static let line = RisingLine("OWLLUNA", tracking: -0.012, delay: 590, stagger: 55, duration: 780)
    private static let rule = SplashBeat(delay: 470, duration: 700)

    /// The slab's column in ems: the room over the line, the gap under it, the rule, and the room under that.
    private static let headroom: CGFloat = 0.1
    private static let gap: CGFloat = 0.05
    private static let stroke: CGFloat = 0.02
    private static let foot: CGFloat = 0.1

    static func draw(_ context: GraphicsContext, size: CGSize, scene: BentoScene) {
        let palette = scene.palette
        let em = min(size.width * 0.94 / line.width, size.height * 0.86)
        let column = headroom + RisingLine.height + gap + stroke + foot
        let origin = CGPoint(x: (size.width - line.width * em) / 2, y: (size.height - column * em) / 2 + headroom * em)
        line.draw(context, at: origin, em: em, headroom: headroom, time: scene.time) { $0 < 3 ? palette.paper : palette.moon }
        let grown = line.width * em * rule.progress(scene.time)
        context.fill(Path(CGRect(x: origin.x, y: origin.y + (RisingLine.height + gap) * em, width: grown, height: stroke * em)), with: .color(palette.paper))
    }
}

/// The volume label: VOL. fades up in one corner and the digits rise in the opposite one.
enum BentoVolumeTile {
    private static let digits = RisingLine("01", tracking: -0.01, delay: 840, stagger: 80, duration: 760)
    private static let fade = SplashBeat(delay: 800, duration: 450)

    static func draw(_ context: GraphicsContext, size: CGSize, scene: BentoScene) {
        let inset = scene.labelSize * 1.2
        context.label(BentoWords.volume, corner: CGPoint(x: inset, y: inset), shown: fade.progress(scene.time), scene: scene)

        let em = min(size.width * 0.56, size.height * 0.74)
        let origin = CGPoint(x: size.width * 0.94 - digits.width * em, y: size.height * 0.94 - RisingLine.height * em)
        digits.draw(context, at: origin, em: em, headroom: 0.12, time: scene.time) { _ in scene.palette.ink }
    }
}

/// The ticker: the three things the app is for, with ink diamonds between them, running leftwards for ever.
enum BentoTickerTile {
    /// How tall a capital stands in the band's ems; an em is half the tile's height.
    private static let capHeight: CGFloat = 0.716
    /// How far under the tile's middle the baseline runs, in ems: 0.9355 down a line 1.04 deep.
    private static let baseline: CGFloat = 0.9355 - 0.52

    /// One turn of the band in ems, drawn from its baseline: the words, the diamond after each, and how far it runs before it repeats.
    private static let band: (words: Path, diamonds: Path, length: CGFloat) = {
        let tracking: CGFloat = -0.035
        var words = Path(), diamonds = Path()
        var x: CGFloat = 0
        for verb in BentoWords.verbs {
            let type = SplashType(verb.word, fallback: verb.english, font: OwlLunaFonts.splashTitle(size: 1000, width: 95), tracking: tracking)
            let scale = capHeight / type.capHeight
            words.addPath(type.outline, transform: CGAffineTransform(translationX: x, y: 0).scaledBy(x: scale, y: scale))
            x += (type.width + tracking) * scale + 0.42
            diamonds.addPath(Path(CGRect(x: x, y: -0.5, width: 0.3, height: 0.3)), transform: .turning(45, about: CGPoint(x: x + 0.15, y: -0.35)))
            x += 0.3 + 0.42
        }
        return (words, diamonds, x)
    }()
    /// The band runs an em every 432 ms whatever its words, so a longer language takes longer to come round.
    private static let scroll = SplashBeat(delay: 0, duration: band.length * 432, curve: .linear)

    static func draw(_ context: GraphicsContext, size: CGSize, scene: BentoScene) {
        let em = size.height * 0.5
        guard em > 0 else { return }
        for x in stride(from: -scroll.cycle(scene.time) * band.length * em, to: size.width, by: band.length * em) {
            let turn = context.moved(by: CGAffineTransform(translationX: x, y: size.height / 2 + baseline * em).scaledBy(x: em, y: em))
            turn.fill(band.words, with: .color(scene.palette.paper))
            turn.fill(band.diamonds, with: .color(scene.palette.ink))
        }
    }
}
