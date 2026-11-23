import SwiftUI

/// Where the study tape lies on a tape card's question, in the picture's own points (`UIImage.size`).
struct LiftStrip: Equatable, Sendable {
    var center: CGPoint
    var size: CGSize
    /// In radians, as on the page.
    var rotation: CGFloat
    var color: TapeColor

    /// A card made from study tape with both its pictures answers in place: the tape lifts off instead of the card turning over.
    static func lifts(_ card: Flashcard) -> Bool {
        card.tapeID != nil && card.front.image != nil && card.back.image != nil
    }

    /// The same strip on the picture as drawn, `drawn` points across.
    func placed(from picture: CGSize, in drawn: CGSize) -> LiftStrip {
        let scale = picture.width > 0 ? drawn.width / picture.width : 1
        return LiftStrip(center: CGPoint(x: center.x * scale, y: center.y * scale),
                         size: CGSize(width: size.width * scale, height: size.height * scale), rotation: rotation, color: color)
    }

    /// The strip unturned, round its centre.
    var frame: CGRect { CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height) }
}

extension LiftStrip {
    /// From what the card was cut from. Nil when that doesn't fit the picture, as when the clippings were cut again since.
    init?(clip: CardClip, picture: CGSize) {
        let region = clip.region, tape = clip.tapeSize
        guard region.width >= 1, region.height >= 1, picture.width >= 1, picture.height >= 1, tape.width >= 1, tape.height >= 1 else { return nil }
        let aspect = region.width / region.height
        guard abs(picture.width / picture.height - aspect) <= aspect * 0.04 else { return nil }
        let middle = clip.tapeCenterInClipping
        guard CGRect(origin: .zero, size: region.size).insetBy(dx: -tape.width / 2, dy: -tape.height / 2).contains(middle) else { return nil }
        let scale = picture.width / region.width
        self.init(center: CGPoint(x: middle.x * scale, y: middle.y * scale), size: CGSize(width: tape.width * scale, height: tape.height * scale),
                  rotation: clip.tapeRotation, color: clip.color)
    }

    /// Found from the two pictures, which differ only where the tape was. Nil unless what differs is shaped like a strip. Thread-safe.
    static func find(question: CGImage, answer: CGImage, picture: CGSize) -> LiftStrip? {
        guard let a = Samples(question), let b = Samples(answer), a.width == b.width, a.height == b.height else { return nil }
        let width = a.width, height = a.height

        var marked: [(x: Double, y: Double)] = []
        var mean = (x: 0.0, y: 0.0), ink = (r: 0.0, g: 0.0, b: 0.0)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let d = max(abs(Int(a.bytes[i]) - Int(b.bytes[i])), abs(Int(a.bytes[i + 1]) - Int(b.bytes[i + 1])),
                            abs(Int(a.bytes[i + 2]) - Int(b.bytes[i + 2])))
                guard d > 24 else { continue }
                marked.append((Double(x) + 0.5, Double(y) + 0.5))
                mean.x += Double(x) + 0.5
                mean.y += Double(y) + 0.5
                ink.r += Double(a.bytes[i])
                ink.g += Double(a.bytes[i + 1])
                ink.b += Double(a.bytes[i + 2])
            }
        }
        let count = Double(marked.count)
        guard count >= 40 else { return nil }
        mean = (mean.x / count, mean.y / count)
        var cxx = 0.0, cyy = 0.0, cxy = 0.0
        for p in marked {
            let dx = p.x - mean.x, dy = p.y - mean.y
            cxx += dx * dx
            cyy += dy * dy
            cxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * cxy, cxx - cyy), c = cos(angle), s = sin(angle)
        var u = (low: Double.infinity, high: -Double.infinity), v = u
        for p in marked {
            let dx = p.x - mean.x, dy = p.y - mean.y
            let along = dx * c + dy * s, across = -dx * s + dy * c
            u = (min(u.low, along), max(u.high, along))
            v = (min(v.low, across), max(v.high, across))
        }
        let measured = (length: u.high - u.low + 1, thickness: v.high - v.low + 1)
        guard measured.thickness >= 3, measured.length >= measured.thickness,
              count / (measured.length * measured.thickness) >= 0.55,
              measured.length * measured.thickness <= Double(width * height) * 0.6 else { return nil }
        // The lifted outline's dashes run half their width outside the strip: 1.5 / 30 of its height in all.
        let thickness = measured.thickness / 1.05, length = measured.length - thickness * 0.05
        let mid = (along: (u.low + u.high) / 2, across: (v.low + v.high) / 2)
        let center = CGPoint(x: mean.x + mid.along * c - mid.across * s, y: mean.y + mid.along * s + mid.across * c)
        let scale = picture.width / CGFloat(width)
        return LiftStrip(center: CGPoint(x: center.x * scale, y: center.y * scale),
                         size: CGSize(width: length * scale, height: thickness * scale), rotation: angle,
                         color: nearest(to: (ink.r / count, ink.g / count, ink.b / count)))
    }

    /// Whether the tape is on the question and lifted on the answer, which isn't so once a card's sides are swapped. Thread-safe.
    func covers(question: CGImage, answer: CGImage, picture: CGSize) -> Bool {
        guard picture.width > 0, let a = Samples(question), let b = Samples(answer), a.width == b.width, a.height == b.height else { return false }
        let scale = CGFloat(a.width) / picture.width, c = cos(rotation), s = sin(rotation)
        var on = 0.0, off = 0.0
        for i in -4...4 {
            for j in -1...1 {
                let dx = CGFloat(i) / 10 * size.width, dy = CGFloat(j) / 5 * size.height
                let x = Int(((center.x + dx * c - dy * s) * scale).rounded(.down)), y = Int(((center.y + dx * s + dy * c) * scale).rounded(.down))
                guard let taped = a.color(x, y), let lifted = b.color(x, y) else { continue }
                on += Self.distance(color, taped)
                off += Self.distance(color, lifted)
            }
        }
        return on < off
    }

    /// A picture's pixels, read at no more than about a million.
    private struct Samples {
        let bytes: [UInt8]
        let width: Int
        let height: Int

        init?(_ image: CGImage) {
            let step = max(1, Int((Double(image.width * image.height) / 1_000_000).squareRoot().rounded(.up)))
            let width = image.width / step, height = image.height / step
            guard width > 0, height > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.bytes = bytes
            self.width = width
            self.height = height
        }

        func color(_ x: Int, _ y: Int) -> (Double, Double, Double)? {
            guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
            let i = (y * width + x) * 4
            return (Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2]))
        }
    }

    private static func nearest(to ink: (Double, Double, Double)) -> TapeColor {
        TapeColor.allCases.min { distance($0, ink) < distance($1, ink) } ?? .mustard
    }

    private static func distance(_ color: TapeColor, _ ink: (Double, Double, Double)) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.fill.getRed(&r, green: &g, blue: &b, alpha: &a)
        return pow(Double(r) * 255 - ink.0, 2) + pow(Double(g) * 255 - ink.1, 2) + pow(Double(b) * 255 - ink.2, 2)
    }
}

/// Each tape card's strip, worked out once, off the main thread: where the card says its tape lay, or else found from its pictures.
@MainActor
enum TapeFinder {
    private static var found: [String: LiftStrip?] = [:]

    static func strip(for card: Flashcard, question: UIImage?, answer: UIImage?) async -> LiftStrip? {
        guard LiftStrip.lifts(card), let question, let answer, let a = question.cgImage, let b = answer.cgImage else { return nil }
        let key = "\(card.front.image ?? "")|\(card.back.image ?? "")|\(card.clip != nil)"
        if let hit = found[key] { return hit }
        let size = question.size, given = card.clip.flatMap { LiftStrip(clip: $0, picture: size) }
        let strip = await Task.detached(priority: .userInitiated) { () -> LiftStrip? in
            if let given, given.covers(question: a, answer: b, picture: size) { return given }
            guard let seen = LiftStrip.find(question: a, answer: b, picture: size), seen.covers(question: a, answer: b, picture: size) else { return nil }
            return seen
        }.value
        if found.count >= 200 { found.removeAll() }
        found[key] = .some(strip)
        return strip
    }
}

/// A tape card's clipping, which answers in place: the study tape peels off the question and the answer is under it.
struct TapeLiftClipping: View {
    let question: UIImage
    let answer: UIImage
    /// Nil when the tape couldn't be found: the two pictures cross-fade instead.
    let strip: LiftStrip?
    let lifted: Bool

    static let peelOff = Animation.timingCurve(0.3, 0, 0.25, 1, duration: 0.34)
    static let pressOn = Animation.timingCurve(0.3, 0, 0.25, 1, duration: 0.28)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var peel: CGFloat

    init(question: UIImage, answer: UIImage, strip: LiftStrip?, lifted: Bool) {
        self.question = question
        self.answer = answer
        self.strip = strip
        self.lifted = lifted
        _peel = State(initialValue: lifted ? 1 : 0)
    }

    var body: some View {
        LiftingPicture(question: question, answer: answer, strip: reduceMotion ? nil : strip, peel: peel)
            .clippingHolder(.mustard)
            .accessibilityLabel(Text("Clipping from the page"))
            .onChange(of: lifted) { _, lifted in
                let animation = reduceMotion || strip == nil ? .easeInOut(duration: 0.18) : lifted ? Self.peelOff : Self.pressOn
                withAnimation(animation) { peel = lifted ? 1 : 0 }
            }
    }
}

/// The question, the answer under it and the tape between, each set by how far the tape has come off, frame by frame.
/// Drawn as one, so the card dimming under a finger never shows one through another. Without a strip the question
/// fades to the answer.
private struct LiftingPicture: View, Animatable {
    let question: UIImage
    let answer: UIImage
    let strip: LiftStrip?
    var peel: CGFloat

    nonisolated var animatableData: CGFloat {
        get { peel }
        set { peel = newValue }
    }

    var body: some View {
        let done = min(max(peel, 0), 1)
        Image(uiImage: question)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .opacity(strip == nil ? 1 - done : done > 0 ? 0 : 1)
            .background { Image(uiImage: answer).resizable().opacity(done > 0 ? 1 : 0) }
            .clippingCut()
            .clippingShadow()
            .overlay {
                if let strip {
                    GeometryReader { proxy in
                        PeelingStrip(strip: strip.placed(from: question.size, in: proxy.size), peel: done)
                            .opacity(done > 0 && done < 1 ? 1 : 0)
                    }
                }
            }
            .compositingGroup()
            .transaction { $0.animation = nil }
    }
}

/// The study tape coming off: it peels from one end to the other, the loose part curling up off the paper, and is gone.
private struct PeelingStrip: View {
    let strip: LiftStrip
    let peel: CGFloat

    var body: some View {
        let done = min(max(peel, 0), 1), width = strip.size.width, height = strip.size.height
        let hinge = width * done, curl = min(done * 2.4, 1), loose = hinge * cos(.pi / 180 * 58 * curl)
        ZStack(alignment: .leading) {
            TapeStrip(color: strip.color)
                .mask(alignment: .trailing) { Rectangle().fill(.black).frame(width: max(width - hinge, 0)) }
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.2 * curl)], startPoint: .leading, endPoint: .trailing)
                .frame(width: loose * 1.2, height: height)
                .blur(radius: 2)
                .offset(x: hinge - loose * 1.2, y: height * 0.15)
            TapeStrip(color: strip.color)
                .mask(alignment: .leading) { Rectangle().fill(.black).frame(width: hinge) }
                .rotation3DEffect(.degrees(-58 * curl), axis: (x: 0, y: 1, z: 0), anchor: UnitPoint(x: done, y: 0.5), perspective: 0.8)
        }
        .frame(width: width, height: height)
        .opacity(done < 0.7 ? 1 : (1 - done) / 0.3)
        .rotationEffect(.radians(strip.rotation))
        .position(strip.center)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
