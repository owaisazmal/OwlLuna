import SwiftUI

/// The moon tile: a crescent rises on a spring and rocks for ever, while four stars pop in and twinkle.
enum BentoMoonTile {
    private struct Star: Sendable {
        let outline: Path
        let centre: CGPoint
        let pop: SplashBeat
        let twinkle: SplashBeat

        init(_ order: Double, x: CGFloat, y: CGFloat, _ shape: String) {
            outline = Path(svg: shape).offsetBy(dx: x, dy: y)
            centre = outline.boundingRect.point(0.5, 0.5)
            pop = SplashBeat(delay: 1000 + order * 110, duration: 520, curve: .bounce)
            twinkle = SplashBeat(delay: order * 230, duration: 700, curve: .easeInOut)
        }
    }

    private static let box = CGSize(width: 240, height: 112)
    private static let disc = Path(ellipseIn: CGRect(x: 76, y: 22, width: 72, height: 72))
    private static let shadow = Path(ellipseIn: CGRect(x: 98, y: 15, width: 60, height: 60))
    private static let crescent = disc.boundingRect.union(shadow.boundingRect)
    private static let pivot = crescent.point(0.44, 0.54)
    private static let rise = SplashBeat(delay: 620, duration: 850, curve: .lively)
    private static let rock = SplashBeat(delay: 0, duration: 1500, curve: .easeInOut)
    private static let stars = [
        Star(0, x: 186, y: 36, "M0,-14 Q2,-2 14,0 Q2,2 0,14 Q-2,2 -14,0 Q-2,-2 0,-14 Z"),
        Star(1, x: 44, y: 30, "M0,-9 Q1.4,-1.4 9,0 Q1.4,1.4 0,9 Q-1.4,1.4 -9,0 Q-1.4,-1.4 0,-9 Z"),
        Star(2, x: 206, y: 86, "M0,-7 Q1.2,-1.2 7,0 Q1.2,1.2 0,7 Q-1.2,1.2 -7,0 Q-1.2,-1.2 0,-7 Z"),
        Star(3, x: 60, y: 88, "M0,-6 Q1,-1 6,0 Q1,1 0,6 Q-1,1 -6,0 Q-1,-1 0,-6 Z"),
    ]

    /// How far below the crescent starts: 165% of the height of the upright box around it as it rocks.
    private static func fall(_ rocking: CGAffineTransform) -> CGFloat { crescent.applying(rocking).height * 1.65 }

    static func draw(_ context: GraphicsContext, size: CGSize, scene: BentoScene) {
        let art = context.moved(by: .fitting(box, in: CGRect(origin: .zero, size: size)))
        let risen = rise.progress(scene.time)
        let rocking = CGAffineTransform.turning(mix(-9, 9, rock.cycle(scene.time, alternating: true)), about: pivot)
        art.moved(by: rocking.lowered(by: fall(rocking) * (1 - risen))).group(opacity: risen / inked) { moon in
            moon.paint(disc, fill: scene.palette.moon)
            moon.paint(shadow, fill: scene.palette.ink)
        }
        for star in stars {
            let popped = star.pop.progress(scene.time)
            guard popped > 0 else { continue }
            let scale = popped * mix(1, 0.62, star.twinkle.cycle(scene.time, alternating: true))
            art.moved(by: .turning(-90 * (1 - popped), scale: scale, about: star.centre)).paint(star.outline, fill: scene.palette.moonLight)
        }
    }
}

/// The flashcard tile: three index cards fan up from below, then the stamp slams on and wobbles.
enum BentoCardsTile {
    private static let box = CGSize(width: 240, height: 176)
    private static let card = Path(roundedRect: CGRect(x: 46, y: 36, width: 148, height: 94), cornerRadius: 4, style: .circular)
    /// Well below the card, so that the three open like a fan.
    private static let hinge = card.boundingRect.point(0.5, 1.6)
    private static let heading = Path(svg: "M46,58 H194")
    private static let rules = Path(svg: "M58,74 H182 M58,89 H182 M58,104 H128")
    private static let tilts = [-8.0, 7, -1]
    private static let rises = tilts.indices.map { SplashBeat(delay: 800 + Double($0) * 80, duration: 800, curve: .lively) }

    private static let plate = Path(roundedRect: CGRect(x: 94, y: 95, width: 112, height: 42), cornerRadius: 3, style: .circular)
    private static let centre = plate.boundingRect.point(0.5, 0.5)
    /// The stamp's word, its ink centred on the plate and as wide as its measure; a long word is set smaller rather than squeezed by more than a quarter.
    private static let word: Path = {
        let tracking = 0.06, measure = 84.0, capitals = 0.79 * 30
        let type = SplashType(BentoWords.study, fallback: "STUDY", font: OwlLunaFonts.splashTitle(size: 1000, width: 62), tracking: tracking)
        let across = measure / (type.width + tracking)
        let up = min(capitals / type.capHeight, across / 0.75)
        let baseline = 127 - capitals / 2 - up * type.outline.boundingRect.midY
        return type.outline.applying(CGAffineTransform(translationX: 151.5 - measure / 2, y: baseline).scaledBy(x: across, y: up))
    }()
    private static let slam = SplashTrack(delay: 1340, duration: 300, stops: [
        .init(at: 0, value: 2, curve: .bezier(0.7, 0, 0.84, 0)), .init(at: 0.55, value: 0.92, curve: .easeOut), .init(at: 1, value: 1),
    ])
    private static let inking = SplashTrack(delay: 1340, duration: 300, stops: [.init(at: 0, value: 0, curve: .bezier(0.7, 0, 0.84, 0)), .init(at: 0.55, value: 1)])
    /// The stamp sits nine degrees askew and wobbles either side of that.
    private static let wobble = SplashBeat(delay: 0, duration: 950, curve: .easeInOut)

    static func draw(_ context: GraphicsContext, size: CGSize, scene: BentoScene) {
        let art = context.moved(by: .fitting(box, in: CGRect(origin: .zero, size: size)))
        let palette = scene.palette
        for (index, rise) in rises.enumerated() {
            let risen = rise.progress(scene.time)
            let fanned = CGAffineTransform.turning(tilts[index] * risen, about: hinge).lowered(by: card.boundingRect.height * 1.72 * (1 - risen))
            art.moved(by: fanned).group(opacity: risen / inked) { sheet in
                sheet.paint(card, fill: palette.white, stroke: palette.ink, width: 3.6)
                guard index == rises.count - 1 else { return }
                sheet.paint(heading, stroke: palette.tomato, width: 3)
                sheet.stroke(rules, with: .color(palette.rule), lineWidth: 2.4)
            }
        }
        let askew = -9 + mix(-2.5, 2.5, wobble.cycle(scene.time, alternating: true))
        art.moved(by: .turning(askew, scale: slam.value(scene.time), about: centre)).group(opacity: inking.value(scene.time)) { stamp in
            stamp.paint(plate, fill: palette.white, stroke: palette.tomato, width: 4)
            stamp.paint(word, fill: palette.tomato)
        }
    }
}

/// How far along its rise a thing is fully inked.
private let inked = 0.12

private extension SplashCurve {
    /// The spring the moon and the cards come up on.
    static let lively = SplashCurve.spring(damping: 0.58, settle: 6.4)
}

private extension CGRect {
    /// The point a fraction of the way across and down the box.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: minX + width * x, y: minY + height * y) }
}

private extension CGAffineTransform {
    /// The same transform, then moved down.
    func lowered(by distance: CGFloat) -> CGAffineTransform { concatenating(CGAffineTransform(translationX: 0, y: distance)) }
}

private extension GraphicsContext {
    /// Draws several things as one, so that they fade together, and nothing while they are invisible.
    func group(opacity: Double, _ content: (inout GraphicsContext) -> Void) {
        guard opacity > 0 else { return }
        var copy = self
        guard opacity < 1 else { return content(&copy) }
        copy.opacity = opacity
        copy.drawLayer(content: content)
    }
}
