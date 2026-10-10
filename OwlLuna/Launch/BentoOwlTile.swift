import SwiftUI

/// The owl tile: a perch under a pale disc, and the owl hopping up onto it to write a line on its pad, look up and blink.
enum BentoOwlTile {
    static func draw(_ context: GraphicsContext, size: CGSize, scene: BentoScene) {
        let time = scene.time, palette = scene.palette
        let fit = CGAffineTransform.fitting(artBox.size, in: CGRect(origin: .zero, size: size), anchor: .bottom)

        let across = CGAffineTransform(translationX: 0, y: fit.ty).scaledBy(x: size.width * perchGrows.progress(time), y: fit.a)
        context.moved(by: across).paint(perch, fill: palette.ink)

        let art = context.moved(by: fit.translatedBy(x: -artBox.minX, y: -artBox.minY))
        art.moved(by: .turning(0, scale: discPops.progress(time), about: discCentre)).paint(disc, fill: palette.moonLight)
        if time > hops.delay { drawOwl(art, scene: scene) }

        let inset = scene.labelSize * 1.45
        context.label(BentoWords.notebook, corner: CGPoint(x: inset, y: inset), shown: labelRises.progress(time), scene: scene)
    }

    private static func drawOwl(_ art: GraphicsContext, scene: BentoScene) {
        let time = scene.time, ink = scene.palette.ink, tones = scene.palette.owl
        let dark = Color(tones.bodyDark)
        let written = writes.progress(time)
        let nudge = CGAffineTransform(translationX: armBox.width * -0.375 * (1 - written), y: armBox.height * (0.06 * (1 - written) + jitter.value(time)))
        let reach = CGAffineTransform.turning(mix(-30, 0, swings.progress(time)), about: shoulder).concatenating(nudge)
        let drop = standing.union(armBox.applying(reach)).applying(stance).height * 1.28 * (1 - hops.progress(time))
        let owl = art.moved(by: CGAffineTransform(translationX: 0, y: drop)).moved(by: stance)

        owl.paint(feet, fill: Color(tones.feet), stroke: ink, width: 5)
        owl.paint(body, fill: Color(tones.body), stroke: ink, width: 6)
        owl.paint(belly, fill: Color(tones.belly))
        owl.paint(feathers, stroke: Color(tones.body), width: 4)
        drawHead(owl.moved(by: .turning(mix(cocked, 3.5, tilts.progress(time)), about: chin)), scene: scene)

        let pad = owl.moved(by: padLean)
        pad.paint(page, fill: Color(tones.pad), stroke: ink, width: 5)
        pad.paint(binding, fill: ink)
        pad.stroke(rules, with: .color(scene.palette.rule), lineWidth: 2.5)
        pad.paint(notes, stroke: ink, width: 3.2)
        pad.draw(strokes: scribble, upTo: written, stroke: ink, width: 3.2)

        owl.paint(leftWing, fill: dark, stroke: ink, width: 5)
        let arm = owl.moved(by: reach)
        arm.paint(rightWing, fill: dark, stroke: ink, width: 5)
        let pencil = arm.moved(by: hold)
        pencil.paint(barrel, fill: Color(tones.pencil))
        pencil.paint(shade, fill: Color(tones.pencilShade))
        pencil.paint(wood, fill: Color(tones.pencilWood))
        pencil.paint(lead, fill: Color(tones.pencilTip))
        pencil.paint(ferrule, fill: Color(tones.ferrule))
        pencil.paint(eraser, fill: Color(tones.eraser))
        pencil.paint(casing, stroke: ink, width: 5)
        pencil.paint(bands, stroke: ink, width: 3)
        pencil.paint(grip, fill: dark, stroke: ink, width: 4)
    }

    private static func drawHead(_ head: GraphicsContext, scene: BentoScene) {
        let ink = scene.palette.ink, white = scene.palette.white, tones = scene.palette.owl
        head.paint(ears, fill: Color(tones.bodyDark), stroke: ink, width: 6)
        head.paint(skull, fill: Color(tones.body), stroke: ink, width: 6)
        head.paint(cheeks, fill: Color(tones.face))
        head.paint(whites, fill: white, stroke: ink, width: 6)

        let down = 1 - looksUp.progress(scene.time), aside = glances.progress(scene.exit)
        let gaze = head.moved(by: CGAffineTransform(translationX: eyesBox.width * (-0.045 * down - 0.065 * aside),
                                                    y: eyesBox.height * (0.15 * down + 0.02 * aside)))
        gaze.paint(irises, fill: Color(tones.iris), stroke: Color(tones.irisRing), width: 6)
        gaze.paint(pupils, fill: Color(tones.pupil))
        gaze.paint(glints, fill: white)

        let raised = blink.value(scene.time, repeating: true)
        for eye in eyelids where raised < 1 {
            var socket = head
            socket.clip(to: eye.socket)
            socket.translateBy(x: 0, y: -lidTravel * raised)
            socket.paint(eye.lid, fill: Color(tones.face))
            socket.paint(eye.lash, stroke: ink, width: 5)
        }
        head.paint(beak, fill: Color(tones.beak), stroke: ink, width: 5)
    }

    private static let perchGrows = SplashBeat(delay: 330, duration: 600)
    private static let discPops = SplashBeat(delay: 350, duration: 700, curve: .bounce)
    private static let labelRises = SplashBeat(delay: 500, duration: 450)
    private static let hops = SplashBeat(delay: 470, duration: 900, curve: .spring(damping: 0.68, settle: 6.8))
    private static let swings = SplashBeat(delay: 800, duration: 520, curve: .bounce)
    private static let writes = SplashBeat(delay: 1040, duration: 520, curve: .linear)
    private static let tilts = SplashBeat(delay: 1540, duration: 620, curve: .bounce)
    private static let looksUp = SplashBeat(delay: 1560, duration: 320)
    /// Runs on the leaving clock: a look aside as the tiles go.
    private static let glances = SplashBeat(delay: 0, duration: 180)
    /// The pencil's bobbing as it writes, in arm heights.
    private static let jitter = SplashTrack(delay: 1040, duration: 520, stops: [0, -0.05, 0.025, -0.05, 0.025, -0.05, 0.025, -0.05, 0].enumerated().map {
        SplashTrack.Stop(at: Double($0.offset) / 8, value: $0.element)
    })
    /// How far the lids are raised: 1 clear of the eyes, 0 shut.
    private static let blink = SplashTrack(delay: 1700, duration: 2600, stops: [
        .init(at: 0, value: 1, curve: .easeIn), .init(at: 0.035, value: 0), .init(at: 0.048, value: 0, curve: .easeOut), .init(at: 0.09, value: 1),
    ])

    /// The part of the drawing the tile shows, resting on the tile's foot.
    private static let artBox = CGRect(x: 20, y: 0, width: 360, height: 400)
    /// One unit of the perch's length; it is stretched across the tile.
    private static let perch = Path(CGRect(x: 0, y: 372, width: 1, height: 8))
    private static let discCentre = CGPoint(x: 200, y: 204)
    private static let disc = Path(discs: 156, at: [discCentre])

    /// The owl stands a little smaller than it was drawn, about the point between its feet.
    private static let stance = CGAffineTransform.turning(0, scale: 0.93, about: CGPoint(x: 200, y: 378))
    private static let feet = Path { path in
        for (x, y) in [(143, 358), (158, 360), (173, 358), (213, 358), (228, 360), (243, 358)] {
            path.addRoundedRect(in: CGRect(x: x, y: y, width: 14, height: 25), cornerSize: CGSize(width: 7, height: 7), style: .circular)
        }
    }
    private static let body = Path(svg: "M200,150 C275,150 316,215 316,278 C316,338 268,368 200,368 C132,368 84,338 84,278 C84,215 125,150 200,150 Z")
    private static let belly = Path(ellipseIn: CGRect(x: 130, y: 236, width: 140, height: 124))
    private static let feathers = Path(svg: "M210,258 q7,9 14,0 M238,266 q7,9 14,0 M222,284 q7,9 14,0 M210,338 q7,9 14,0 M236,330 q7,9 14,0")
    private static let leftWing = Path(svg: "M88,216 C58,246 54,300 76,332 C100,320 110,278 104,238 Z")

    private static let ears = Path(svg: "M98,116 L80,26 L164,60 Z M302,116 L320,26 L236,60 Z")
    private static let skull = Path(svg: "M200,40 C270,40 324,70 324,142 C324,206 270,236 200,236 C130,236 76,206 76,142 C76,70 130,40 200,40 Z")
    private static let eyes = [CGPoint(x: 148, y: 144), CGPoint(x: 252, y: 144)]
    private static let cheeks = Path(discs: 62, at: eyes)
    private static let whites = Path(discs: 45, at: eyes)
    private static let irises = Path(discs: 26, at: eyes)
    private static let pupils = Path(discs: 14, at: eyes)
    private static let glints = Path(discs: 5, at: eyes.map { CGPoint(x: $0.x + 7, y: $0.y - 8) })
    private static let beak = Path(svg: "M184,176 L216,176 L200,208 Z")
    /// Each eye's socket, the white inside its outline, with the lid drawn shut over it and the lash across the lid.
    private static let eyelids: [(socket: Path, lid: Path, lash: Path)] = [
        (Path(discs: 42, at: [eyes[0]]), Path(CGRect(x: 103, y: 97, width: 90, height: 94)), Path(svg: "M103,191 H193 M124,150 q24,18 48,0")),
        (Path(discs: 42, at: [eyes[1]]), Path(CGRect(x: 207, y: 97, width: 90, height: 94)), Path(svg: "M207,191 H297 M228,150 q24,18 48,0")),
    ]
    private static let eyesBox = irises.boundingRect
    /// How far a lid comes down to shut: its own height.
    private static let lidTravel = eyelids[0].lid.boundingRect.height
    /// The head's box takes in the lids where they wait, raised out of sight above the ears.
    private static let headBox = ears.boundingRect.union(skull.boundingRect).union(eyelids[0].lid.boundingRect.offsetBy(dx: 0, dy: -lidTravel))
    private static let chin = CGPoint(x: headBox.midX, y: headBox.maxY)
    /// The head's tilt while the owl looks at its pad, in degrees.
    private static let cocked = -5.0
    /// The owl from its toes to the top of its cocked head; the hop is measured in this and the arm's reach.
    private static let standing = feet.boundingRect.union(headBox.applying(.turning(cocked, about: chin)))

    private static let padLean = CGAffineTransform.turning(-7, about: CGPoint(x: 138, y: 300))
    private static let page = Path(roundedRect: CGRect(x: 80, y: 240, width: 118, height: 110), cornerRadius: 5, style: .circular)
    private static let binding = Path(svg: "M80,245 a5,5 0 0 1 5,-5 h108 a5,5 0 0 1 5,5 v14 h-118 z")
    private static let rules = Path(svg: "M92,286 h94 M92,306 h94 M92,326 h94")
    private static let notes = Path(svg: """
        M96,281 q5,-9 10,0 t10,0 t10,0 t10,0 m9,0 q5,-9 10,0 t10,0 t10,0 \
        M96,301 q5,-9 10,0 t10,0 m9,0 q5,-9 10,0 t10,0 t10,0 t10,0 t10,0
        """)
    private static let scribble = Path(svg: "M96,321 q4,-9 8,0 t8,0 t8,0 m8,0 q4.7,-9 9.3,0 t9.3,0 t9.3,0 t9.3,0 t9.3,0 t9.3,0").strokes

    private static let rightWing = Path(svg: "M318,208 C342,254 306,298 254,284 C260,244 288,220 318,208 Z")
    /// Where the pencil lies in the wing: its point on the pad, its length up and to the right.
    private static let hold = CGAffineTransform(translationX: 186, y: 314).rotated(by: -38 * .pi / 180)
    private static let barrel = Path(CGRect(x: 28, y: -11, width: 124, height: 22))
    private static let shade = Path(CGRect(x: 28, y: 3, width: 124, height: 8))
    private static let wood = Path(svg: "M0,0 L28,-11 V11 Z")
    private static let lead = Path(svg: "M0,0 L11,-4.4 V4.4 Z")
    private static let ferrule = Path(CGRect(x: 152, y: -11, width: 12, height: 22))
    private static let eraser = Path(svg: "M164,-11 h10 a6,6 0 0 1 6,6 v10 a6,6 0 0 1 -6,6 h-10 z")
    private static let casing = Path(svg: "M0,0 L28,-11 H174 a6,6 0 0 1 6,6 v10 a6,6 0 0 1 -6,6 H28 Z")
    private static let bands = Path(svg: "M152,-11 V11 M164,-11 V11")
    private static let grip = Path(ellipseIn: CGRect(x: 87, y: -17, width: 22, height: 36))
    /// The wing and the pencil's own box as it lies in the wing; the swing and the writing are measured in it.
    private static let armBox = rightWing.boundingRect.union(casing.boundingRect.union(grip.boundingRect).applying(hold))
    private static let shoulder = CGPoint(x: armBox.minX + armBox.width * 0.875, y: armBox.minY + armBox.height * 0.146)
}

private extension Path {
    /// Circles of one radius about each centre.
    init(discs radius: CGFloat, at centres: [CGPoint]) {
        self.init()
        for centre in centres { addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)) }
    }
}
