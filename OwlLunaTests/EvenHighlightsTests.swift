import XCTest
import AVFoundation
import PencilKit
@testable import OwlLuna

private let written = Date(timeIntervalSince1970: 1_790_000_000)
private let yellow = UIColor(red: 0.91, green: 0.69, blue: 0.14, alpha: 1)
private let pink = UIColor(red: 0.93, green: 0.36, blue: 0.55, alpha: 1)

/// A highlighter stroke as a finger lays it: points 0.667 of the tool's width, the chisel turned across the way it goes,
/// heavier at the start and lighter at the last point.
private func finger(_ path: [CGPoint], tool: CGFloat = 20, color: UIColor = yellow, transform: CGAffineTransform = .identity, mask: UIBezierPath? = nil) -> PKStroke {
    let size = 0.667 * tool, count = path.count
    let points = path.enumerated().map { index, location -> PKStrokePoint in
        let a = path[max(index - 1, 0)], b = path[min(index + 1, count - 1)]
        let azimuth = count > 1 ? atan2(b.y - a.y, b.x - a.x) + .pi / 2 : .pi / 2
        let opacity: CGFloat = count == 1 ? 1.5 : index == count - 1 ? 0.6 : index < 3 ? [1.5, 1.28, 1.1][index] : 1
        return PKStrokePoint(location: location, timeOffset: TimeInterval(index) / 60, size: CGSize(width: size, height: size), opacity: opacity,
                             force: 0, azimuth: azimuth, altitude: .pi / 2)
    }
    return PKStroke(ink: PKInk(.marker, color: color), path: PKStrokePath(controlPoints: points, creationDate: written), transform: transform, mask: mask)
}

/// Points a few points apart from `a` to `b`.
private func straight(_ a: CGPoint, _ b: CGPoint, step: CGFloat = 4) -> [CGPoint] {
    let count = max(Int((hypot(b.x - a.x, b.y - a.y) / step).rounded()), 1)
    return (0...count).map { i in
        let t = CGFloat(i) / CGFloat(count)
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// A level line of points all alike, as PencilKit's plateau was measured with.
private func level(tool: CGFloat, y: CGFloat = 60, color: UIColor = yellow) -> PKStroke {
    let size = 0.667 * tool
    let points = straight(CGPoint(x: 30, y: y), CGPoint(x: 330, y: y)).map {
        PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: size, height: size), opacity: 1, force: 0, azimuth: .pi / 2, altitude: .pi / 2)
    }
    return PKStroke(ink: PKInk(.marker, color: color), path: PKStrokePath(controlPoints: points, creationDate: written))
}

private func pen(from a: CGPoint, to b: CGPoint, color: UIColor = .black) -> PKStroke {
    let points = straight(a, b).map {
        PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points, creationDate: written))
}

/// RGBA of something drawn in a context running down the page.
private struct Plane {
    let width: Int, height: Int, scale: CGFloat
    private(set) var bytes: [UInt8]

    init(_ size: CGSize, scale: CGFloat = 4, ground: UIColor? = nil, _ draw: (CGContext) -> Void) {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            if let ground {
                ctx.setFillColor(ground.cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            UIGraphicsPushContext(ctx)
            draw(ctx)
            UIGraphicsPopContext()
        }
        (width, height, self.scale, bytes) = (w, h, scale, buffer)
    }

    /// The first page of a PDF, on white.
    init(pdf data: Data, size: CGSize, scale: CGFloat = 2) throws {
        let page = try XCTUnwrap(CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)?.page(at: 1))
        self.init(size, scale: scale, ground: .white) { ctx in
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.drawPDFPage(page)
        }
    }

    subscript(point: CGPoint) -> [Int] {
        let x = min(max(Int(point.x * scale), 0), width - 1), y = min(max(Int(point.y * scale), 0), height - 1), at = (y * width + x) * 4
        return (0..<3).map { Int(bytes[at + $0]) }
    }

    func alpha(at point: CGPoint) -> Int {
        let x = min(max(Int(point.x * scale), 0), width - 1), y = min(max(Int(point.y * scale), 0), height - 1)
        return Int(bytes[(y * width + x) * 4 + 3])
    }

    /// Where alpha reaches `threshold` of 255.
    func mask(_ threshold: Int) -> [Bool] { (0..<width * height).map { Int(bytes[$0 * 4 + 3]) >= threshold } }

    /// The farthest a pixel of one mask lies from the other, both ways, in points, looking no further than `limit` pixels.
    static func distance(_ a: [Bool], _ b: [Bool], width: Int, height: Int, scale: CGFloat, limit: Int = 24) -> (out: CGFloat, in: CGFloat) {
        func farthest(_ from: [Bool], _ to: [Bool]) -> CGFloat {
            var worst = 0
            for y in 0..<height {
                for x in 0..<width where from[y * width + x] && !to[y * width + x] {
                    var best = limit * limit
                    for dy in -limit...limit where y + dy >= 0 && y + dy < height {
                        for dx in -limit...limit where x + dx >= 0 && x + dx < width && dx * dx + dy * dy < best {
                            if to[(y + dy) * width + x + dx] { best = dx * dx + dy * dy }
                        }
                    }
                    worst = max(worst, best)
                }
            }
            return sqrt(CGFloat(worst)) / scale
        }
        return (farthest(a, b), farthest(b, a))
    }

    /// How far a mask reaches before the start of the line from `a` to `b` and past its end, and either side of its middle.
    func extents(_ mask: [Bool], from a: CGPoint, to b: CGPoint) -> (start: CGFloat, end: CGFloat, left: CGFloat, right: CGFloat) {
        let length = hypot(b.x - a.x, b.y - a.y), u = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
        var lo = CGFloat.infinity, hi = -CGFloat.infinity, l = CGFloat.infinity, r = -CGFloat.infinity
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                let px = (CGFloat(x) + 0.5) / scale - a.x, py = (CGFloat(y) + 0.5) / scale - a.y
                let along = px * u.x + py * u.y, across = -px * u.y + py * u.x
                lo = min(lo, along)
                hi = max(hi, along)
                if along > length * 0.3, along < length * 0.7 { (l, r) = (min(l, across), max(r, across)) }
            }
        }
        return (-lo, hi - length, -l, r)
    }
}

private func assertColor(_ found: [Int], _ wanted: [Int], within: Int = 1, _ message: String, line: UInt = #line) {
    XCTAssertTrue(zip(found, wanted).allSatisfy { abs($0 - $1) <= within }, "\(found) is not \(wanted): \(message)", line: line)
}

private func bytes(_ color: CGColor) -> [Int] {
    let parts = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? []
    return parts.prefix(3).map { Int(($0 * 255).rounded()) }
}

/// The shape a path's `d` draws, read from what `SVGText.path` writes.
private func svgPath(_ d: String) -> CGPath {
    let path = CGMutablePath()
    var command: Character = "M", numbers: [CGFloat] = [], token = ""
    func flushToken() {
        if let value = Double(token) { numbers.append(CGFloat(value)) }
        token = ""
    }
    func run() {
        flushToken()
        switch command {
        case "M" where numbers.count >= 2: path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
        case "L" where numbers.count >= 2: path.addLine(to: CGPoint(x: numbers[0], y: numbers[1]))
        case "Q" where numbers.count >= 4: path.addQuadCurve(to: CGPoint(x: numbers[2], y: numbers[3]), control: CGPoint(x: numbers[0], y: numbers[1]))
        case "C" where numbers.count >= 6:
            path.addCurve(to: CGPoint(x: numbers[4], y: numbers[5]), control1: CGPoint(x: numbers[0], y: numbers[1]), control2: CGPoint(x: numbers[2], y: numbers[3]))
        case "Z": path.closeSubpath()
        default: break
        }
        numbers = []
    }
    for character in d {
        if "MLQCZ".contains(character) {
            run()
            command = character
        } else if character == " " {
            flushToken()
        } else {
            token.append(character)
        }
    }
    run()
    return path
}

final class EvenHighlightsTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 360, height: 240)

    private func kit(_ stroke: PKStroke, scale: CGFloat = 4) -> Plane {
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { image = PKDrawing(strokes: [stroke]).image(from: rect, scale: scale) }
        return Plane(rect.size, scale: scale) { _ in image.draw(in: CGRect(origin: .zero, size: rect.size)) }
    }

    private func shape(_ stroke: PKStroke, scale: CGFloat = 4) -> Plane {
        let marks = EvenHighlights.marks(of: [stroke], onDark: false)
        return Plane(rect.size, scale: scale) { ctx in
            for mark in marks {
                ctx.addPath(mark.outline)
                ctx.fillPath(using: .winding)
            }
        }
    }

    /// Where PencilKit's picture is at least half as strong as at `peak`, or as at its strongest.
    private func half(_ drawn: Plane, peak: CGPoint?) -> [Bool] {
        let top = peak.map { drawn.alpha(at: $0) } ?? stride(from: 3, to: drawn.bytes.count, by: 4).map { Int(drawn.bytes[$0]) }.max() ?? 0
        return drawn.mask(max(top / 2, 1))
    }

    func testAnOutlineLiesWhereThePencilKitPictureIsHalfAsStrong() {
        let curve = (0...60).map { i -> CGPoint in
            let t = CGFloat(i) / 60 * .pi
            return CGPoint(x: 180 - 120 * cos(t), y: 200 - 140 * sin(t))
        }
        let cases: [(String, PKStroke, CGPoint?, CGFloat)] = [
            ("level", finger(straight(CGPoint(x: 40, y: 60), CGPoint(x: 300, y: 60))), CGPoint(x: 170, y: 60), 0.8),
            ("upright", finger(straight(CGPoint(x: 120, y: 20), CGPoint(x: 120, y: 220))), CGPoint(x: 120, y: 120), 0.8),
            ("slanted", finger(straight(CGPoint(x: 40, y: 200), CGPoint(x: 300, y: 40))), CGPoint(x: 170, y: 120), 0.8),
            ("narrowest", finger(straight(CGPoint(x: 40, y: 60), CGPoint(x: 300, y: 60)), tool: 7.5), CGPoint(x: 170, y: 60), 0.8),
            ("curve", finger(curve), CGPoint(x: 180, y: 60), 0.8),
            ("tap", finger([CGPoint(x: 180, y: 120)]), nil, 0.8),
            ("rubbed out in part", finger(straight(CGPoint(x: 40, y: 60), CGPoint(x: 300, y: 60)), mask: UIBezierPath(rect: CGRect(x: 0, y: 0, width: 150, height: 240))),
             CGPoint(x: 100, y: 60), 0.8),
            // Twice as wide, so its edges may stray twice as far: the same half point in the stroke's own units.
            ("stretched", finger(straight(CGPoint(x: 20, y: 60), CGPoint(x: 140, y: 60)), transform: CGAffineTransform(a: 2, b: 0, c: 0.4, d: 1.3, tx: 0, ty: 20)),
             CGPoint(x: 194, y: 98), 1.6),
            ("broadest", finger(straight(CGPoint(x: 40, y: 120), CGPoint(x: 300, y: 120)), tool: 60), CGPoint(x: 170, y: 120), 1.8),
        ]
        for (name, stroke, peak, limit) in cases {
            let drawn = kit(stroke), outline = shape(stroke)
            let found = Plane.distance(outline.mask(128), half(drawn, peak: peak), width: drawn.width, height: drawn.height, scale: drawn.scale,
                                       limit: Int((limit * drawn.scale).rounded(.up)) + 2)
            XCTAssertLessThanOrEqual(found.out, limit, "\(name): the outline reaches past PencilKit's picture")
            XCTAssertLessThanOrEqual(found.in, limit, "\(name): PencilKit's picture reaches past the outline")
        }
    }

    func testBreadthAndEndsAreWithinHalfAPoint() {
        let lines: [(String, CGPoint, CGPoint, CGFloat)] = [
            ("narrowest", CGPoint(x: 40, y: 120), CGPoint(x: 300, y: 120), 7.5),
            ("default", CGPoint(x: 40, y: 120), CGPoint(x: 300, y: 120), 20),
            ("broadest", CGPoint(x: 60, y: 120), CGPoint(x: 280, y: 120), 60),
            ("upright", CGPoint(x: 180, y: 20), CGPoint(x: 180, y: 220), 20),
            ("slanted", CGPoint(x: 40, y: 200), CGPoint(x: 300, y: 40), 20),
        ]
        for (name, a, b, tool) in lines {
            let stroke = finger(straight(a, b), tool: tool), drawn = kit(stroke), outline = shape(stroke)
            let theirs = drawn.extents(half(drawn, peak: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)), from: a, to: b)
            let ours = outline.extents(outline.mask(128), from: a, to: b)
            XCTAssertEqual(ours.start, theirs.start, accuracy: 0.55, "\(name): start")
            XCTAssertEqual(ours.end, theirs.end, accuracy: 0.55, "\(name): end, where the line fades")
            XCTAssertEqual(ours.left, theirs.left, accuracy: 0.55, "\(name): breadth")
            XCTAssertEqual(ours.right, theirs.right, accuracy: 0.55, "\(name): breadth")
        }
    }

    func testStrengthIsPencilKitsPlateauFromInkAndBreadthAlone() {
        for tool in [7.5, 20, 60] as [CGFloat] {
            let stroke = level(tool: tool), plateau = CGFloat(kit(stroke).alpha(at: CGPoint(x: 180, y: 60))) / 255
            XCTAssertEqual(EvenHighlights.strength(of: stroke), plateau, accuracy: 0.012, "tool width \(tool)")
        }
        let short = finger(straight(CGPoint(x: 40, y: 60), CGPoint(x: 60, y: 60))), long = level(tool: 20, y: 120)
        XCTAssertEqual(EvenHighlights.strength(of: short), EvenHighlights.strength(of: long), "two lines from one pen are as strong")
        XCTAssertEqual(EvenHighlights.color(of: short, onDark: false), EvenHighlights.color(of: long, onDark: false))
        let faint = finger(straight(CGPoint(x: 40, y: 60), CGPoint(x: 60, y: 60)), color: yellow.withAlphaComponent(0.5))
        XCTAssertEqual(EvenHighlights.strength(of: faint), EvenHighlights.strength(of: short) / 2, accuracy: 0.001)
        let unseen = finger(straight(CGPoint(x: 40, y: 60), CGPoint(x: 60, y: 60)), color: yellow.withAlphaComponent(0))
        XCTAssertTrue(EvenHighlights.marks(of: [unseen], onDark: false).isEmpty, "ink that shows nothing leaves no mark to cover others")
    }

    func testOnlyTheHighlighterIsMarkedInTheOrderWritten() {
        let strokes = [pen(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 200, y: 20)), finger(straight(CGPoint(x: 20, y: 60), CGPoint(x: 200, y: 60))),
                       pen(from: CGPoint(x: 20, y: 100), to: CGPoint(x: 200, y: 100)), finger(straight(CGPoint(x: 20, y: 140), CGPoint(x: 200, y: 140)), color: pink)]
        let marks = EvenHighlights.marks(of: strokes, onDark: false)
        XCTAssertEqual(marks.map(\.color), [EvenHighlights.color(of: strokes[1], onDark: false), EvenHighlights.color(of: strokes[3], onDark: false)])
        XCTAssertEqual(marks[0].outline.boundingBoxOfPath.midY, 60, accuracy: 1)
    }

    func testOnDarkPaperAMarkIsTheInkLaidAtItsStrength() {
        let stroke = level(tool: 20), strength = EvenHighlights.strength(of: stroke)
        let charcoal = EvenHighlights.marks(of: [stroke], onDark: true, appearance: .light)[0]
        assertColor(bytes(charcoal.color), [0.91, 0.69, 0.14].map { Int(($0 * 255).rounded()) }, "Charcoal keeps the light ink's colour")
        XCTAssertEqual(charcoal.opacity, strength, accuracy: 0.0001)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        PKInkingTool.convertColor(yellow, from: .light, to: .dark).getRed(&r, green: &g, blue: &b, alpha: nil)
        assertColor(bytes(EvenHighlights.color(of: stroke, onDark: true)), [r, g, b].map { Int(($0 * 255).rounded()) }, "dark ink is turned as PencilKit shows it")
        XCTAssertEqual(EvenHighlights.marks(of: [stroke], onDark: false)[0].opacity, 1, "on light paper a mark is laid whole and multiplied in")
        XCTAssertNil(EvenHighlights.filter(onDark: true))
    }

    func testOutlinesAreKeptAndFollowAChangedStroke() {
        let stroke = finger(straight(CGPoint(x: 40, y: 60), CGPoint(x: 300, y: 60)))
        let first = EvenHighlights.marks(of: [stroke], onDark: false), again = EvenHighlights.marks(of: [stroke], onDark: true)
        XCTAssertTrue(first[0].outline === again[0].outline, "asked again on the main thread, the outline is the one already made")
        XCTAssertNotEqual(first[0].color, again[0].color)
        var moved = stroke
        moved.transform = CGAffineTransform(translationX: 0, y: 50)
        XCTAssertEqual(EvenHighlights.marks(of: [moved], onDark: false)[0].outline.boundingBoxOfPath.midY, 110, accuracy: 1)
        var cut = stroke
        cut.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 150, height: 240))
        XCTAssertLessThan(EvenHighlights.marks(of: [cut], onDark: false)[0].outline.boundingBoxOfPath.maxX, 151)
        var narrowed = cut
        narrowed.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 150, height: 61))
        XCTAssertLessThan(EvenHighlights.marks(of: [narrowed], onDark: false)[0].outline.boundingBoxOfPath.maxY, 62, "a mask cut further is a new outline")
        let zoomed = EvenHighlights.marks(of: [stroke], toPage: CGAffineTransform(scaleX: 2, y: 2), onDark: false)
        XCTAssertEqual(zoomed[0].outline.boundingBoxOfPath.midY, 120, accuracy: 2)
    }

    // MARK: Drawing

    /// A level and an upright line of one pen, then a line of another colour across both.
    private var crossings: [PKStroke] {
        [finger(straight(CGPoint(x: 40, y: 80), CGPoint(x: 300, y: 80))), finger(straight(CGPoint(x: 120, y: 20), CGPoint(x: 120, y: 220))),
         finger(straight(CGPoint(x: 220, y: 20), CGPoint(x: 220, y: 220)), color: pink)]
    }

    /// Paper, a black bar and a grey patch under the crossings, with the marks laid over them.
    private func page(in ctx: CGContext, ground: UIColor, marks: [EvenHighlights.Mark], onDark: Bool) {
        ctx.setFillColor(ground.cgColor)
        ctx.fill(rect)
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 60, y: 76, width: 20, height: 8))
        ctx.setFillColor(UIColor(white: 0.5, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 200, y: 60, width: 40, height: 40))
        EvenHighlights.draw(marks, in: ctx, onDark: onDark)
    }

    private func checkCrossings(_ drawn: Plane, marks: [EvenHighlights.Mark], within: Int, _ kind: String, line: UInt = #line) {
        let laid = bytes(marks[0].color), over = bytes(marks[2].color), grey = drawn[CGPoint(x: 205, y: 65)]
        assertColor(drawn[CGPoint(x: 180, y: 80)], laid, within: within, "\(kind): the line on white is its own colour", line: line)
        assertColor(drawn[CGPoint(x: 120, y: 80)], laid, within: within, "\(kind): two lines of one pen cross unseen", line: line)
        assertColor(drawn[CGPoint(x: 120, y: 150)], laid, within: within, "\(kind): and the upright one is as strong", line: line)
        assertColor(drawn[CGPoint(x: 70, y: 80)], [0, 0, 0], within: within, "\(kind): print under a mark stays black", line: line)
        assertColor(drawn[CGPoint(x: 220, y: 150)], over, within: within, "\(kind): the pink line on white", line: line)
        let multiplied = zip(over, grey).map { ($0 * $1 + 127) / 255 }
        assertColor(drawn[CGPoint(x: 220, y: 70)], multiplied, within: within + 1, "\(kind): over grey, pink multiplied in once", line: line)
        assertColor(drawn[CGPoint(x: 220, y: 80)], multiplied, within: within + 1,
                    "\(kind): the later pink covers the yellow, and the layer is multiplied in whole", line: line)
    }

    func testMarksAreLaidAsOneLayerInABitmap() {
        let marks = EvenHighlights.marks(of: crossings, onDark: false)
        checkCrossings(Plane(rect.size, scale: 2) { page(in: $0, ground: .white, marks: marks, onDark: false) }, marks: marks, within: 1, "bitmap")
    }

    func testMarksAreLaidAsOneLayerInAPDFAsShapes() throws {
        let marks = EvenHighlights.marks(of: crossings, onDark: false)
        let data = UIGraphicsPDFRenderer(bounds: rect).pdfData { context in
            context.beginPage()
            page(in: context.cgContext, ground: .white, marks: marks, onDark: false)
        }
        XCTAssertNil(data.range(of: Data("/Subtype /Image".utf8)), "the marks are shapes, not a picture of them")
        checkCrossings(try Plane(pdf: data, size: rect.size), marks: marks, within: 2, "PDF")
    }

    func testOnDarkPaperMarksAreLaidOverThePageAtTheirStrength() throws {
        let charcoal = UIColor(red: 42 / 255, green: 43 / 255, blue: 47 / 255, alpha: 1)
        let marks = EvenHighlights.marks(of: crossings, onDark: true, appearance: .light), strength = marks[0].opacity
        XCTAssertEqual(EvenHighlights.layers(of: marks).count, 1, "one strength, one layer")
        func over(_ color: CGColor, _ ground: [Int]) -> [Int] { zip(bytes(color), ground).map { Int((CGFloat($0) * strength + CGFloat($1) * (1 - strength)).rounded()) } }
        let bitmap = Plane(rect.size, scale: 2) { page(in: $0, ground: charcoal, marks: marks, onDark: true) }
        let data = UIGraphicsPDFRenderer(bounds: rect).pdfData { context in
            context.beginPage()
            page(in: context.cgContext, ground: charcoal, marks: marks, onDark: true)
        }
        XCTAssertNil(data.range(of: Data("/Subtype /Image".utf8)), "a layer laid at its strength is still shapes")
        for (kind, drawn, within) in [("bitmap", bitmap, 1), ("PDF", try Plane(pdf: data, size: rect.size), 2)] {
            let grey = drawn[CGPoint(x: 205, y: 65)]
            assertColor(drawn[CGPoint(x: 180, y: 80)], over(marks[0].color, [42, 43, 47]), within: within, "\(kind): the ink at its strength over the paper")
            assertColor(drawn[CGPoint(x: 120, y: 80)], drawn[CGPoint(x: 180, y: 80)], within: within, "\(kind): two lines of one pen cross unseen")
            assertColor(drawn[CGPoint(x: 70, y: 80)], over(marks[0].color, [0, 0, 0]), within: within, "\(kind): what is under it is hazed as PencilKit hazes it")
            assertColor(drawn[CGPoint(x: 220, y: 70)], over(marks[2].color, grey), within: within + 1, "\(kind): pink over grey")
            assertColor(drawn[CGPoint(x: 220, y: 80)], drawn[CGPoint(x: 220, y: 70)], within: within + 1, "\(kind): the later pink of the same strength covers the yellow")
        }
    }

    func testMarksOfOneStrengthShareALayer() {
        func mark(_ rect: CGRect, _ opacity: CGFloat) -> EvenHighlights.Mark {
            EvenHighlights.Mark(outline: CGPath(rect: rect, transform: nil), color: UIColor.yellow.cgColor, opacity: opacity)
        }
        let level = CGRect(x: 0, y: 40, width: 300, height: 20), upright = CGRect(x: 100, y: 0, width: 20, height: 200)
        XCTAssertEqual(EvenHighlights.layers(of: [mark(level, 1), mark(upright, 1), mark(level.offsetBy(dx: 0, dy: 10), 1)]).map(\.marks), [[0, 1, 2]])
        let apart = (0..<6).map { mark(CGRect(x: CGFloat($0) * 50, y: 0, width: 20, height: 20), $0 % 2 == 0 ? 0.77 : 0.69) }
        XCTAssertEqual(EvenHighlights.layers(of: apart).map(\.marks), [[0, 2, 4], [1, 3, 5]], "two strengths that never touch stay two layers")
        let over = EvenHighlights.layers(of: [mark(level, 0.77), mark(upright, 0.69), mark(upright.offsetBy(dx: 0, dy: 150), 0.77)])
        XCTAssertEqual(over.map(\.marks), [[0], [1], [2]], "a stroke over a stronger or weaker one it touches goes on top")
        XCTAssertEqual(over.map(\.opacity), [0.77, 0.69, 0.77])
        let back = EvenHighlights.layers(of: [mark(level, 0.77), mark(upright, 0.69), mark(upright.offsetBy(dx: 0, dy: 150), 0.77),
                                              mark(CGRect(x: 200, y: 0, width: 20, height: 100), 0.77)])
        XCTAssertEqual(back.map(\.marks), [[0, 3], [1], [2]], "one touching only marks of its own strength crosses them unseen in their layer")
        XCTAssertEqual(EvenHighlights.layers(of: [mark(level, 0.76), mark(upright, 0.775)]).count, 1, "strengths within 0.02 share")
        XCTAssertEqual(EvenHighlights.layers(of: [mark(level, 0.76), mark(upright, 0.79)]).count, 2)
    }

    // MARK: Pictures of a page

    private func blank(_ size: CGSize) -> NotebookPage {
        NotebookPage(background: .template(PaperTemplate.blank.rawValue), paperColor: .white, size: size)
    }

    /// Black writing, then two crossing highlights of one pen over it and a pink one, as people highlight what they wrote.
    private var annotated: PKDrawing {
        PKDrawing(strokes: [pen(from: CGPoint(x: 40, y: 80), to: CGPoint(x: 300, y: 80))] + crossings)
    }

    func testAPictureOfThePageLaysHighlightsUnderTheInk() {
        let page = blank(rect.size), assets = temporaryRoot(self).url, ink = annotated
        let even = Plane(rect.size, scale: 2) { _ in
            PageRenderer.image(of: page, ink: ink, assets: assets, width: rect.width, scale: 2, evenHighlights: true).draw(in: rect)
        }
        let marks = EvenHighlights.marks(of: crossings, onDark: false)
        assertColor(even[CGPoint(x: 180, y: 86)], bytes(marks[0].color), "the highlight beside the writing is its own colour")
        assertColor(even[CGPoint(x: 120, y: 86)], bytes(marks[0].color), "and where it crosses itself the same")
        assertColor(even[CGPoint(x: 180, y: 80)], [0, 0, 0], within: 12, "the writing shows black through it")
        let plain = Plane(rect.size, scale: 2) { _ in
            PageRenderer.image(of: page, ink: ink, assets: assets, width: rect.width, scale: 2, evenHighlights: false).draw(in: rect)
        }
        XCTAssertLessThan(plain[CGPoint(x: 120, y: 86)][2] + 20, plain[CGPoint(x: 180, y: 86)][2], "without it the crossing is darker, as PencilKit lays it")
        let reading = { (even: Bool) in
            PageRenderer.image(of: page, ink: ink, assets: assets, width: 360, includeBackground: false, evenHighlights: even).pngData()
        }
        XCTAssertEqual(reading(true), reading(false), "a picture for reading keeps PencilKit's highlights")
    }

    func testThePDFOfAPageHasHighlightsAsShapesUnderTheInk() throws {
        let ink = annotated, rect = rect
        let data = { (style: InkVectors.Style) in
            UIGraphicsPDFRenderer(bounds: rect).pdfData { context in
                context.beginPage()
                InkVectors.draw(ink, from: rect, in: context.cgContext, size: rect.size, style: style)
            }
        }
        let even = data(InkVectors.Style(evenHighlights: true))
        XCTAssertNil(even.range(of: Data("/Subtype /Image".utf8)), "with pens and highlights only, nothing is a picture")
        XCTAssertNotNil(data(InkVectors.Style(evenHighlights: false)).range(of: Data("/Subtype /Image".utf8)), "without it the highlighter is PencilKit's picture")
        let drawn = try Plane(pdf: even, size: rect.size), marks = EvenHighlights.marks(of: crossings, onDark: false)
        assertColor(drawn[CGPoint(x: 120, y: 86)], bytes(marks[0].color), within: 2, "the crossing is the line's colour")
        assertColor(drawn[CGPoint(x: 180, y: 80)], [0, 0, 0], within: 12, "the writing lies over the highlight")
        XCTAssertNotNil(even.range(of: Data("/Multiply".utf8)), "on light paper, and with no paper, the blend stays in the file")
        let charcoal = UIColor(red: 42 / 255, green: 43 / 255, blue: 47 / 255, alpha: 1)
        let night = Plane(rect.size, scale: 2, ground: charcoal) { ctx in
            InkVectors.draw(ink, from: rect, in: ctx, size: rect.size, style: InkVectors.Style(multipliesHighlighter: false, evenHighlights: true))
        }
        let dark = EvenHighlights.marks(of: crossings, onDark: true, appearance: .light)[0]
        assertColor(night[CGPoint(x: 120, y: 86)], zip(bytes(dark.color), [42, 43, 47]).map { Int((CGFloat($0) * dark.opacity + CGFloat($1) * (1 - dark.opacity)).rounded()) },
                    "dark paper has them laid over it at their strength")
    }

    /// The paper's colour down a column of an empty page: what most of it is.
    private func paper(_ blank: Plane, x: CGFloat) -> [Int] {
        let column = stride(from: 0, to: rect.height, by: 1 / blank.scale).map { blank[CGPoint(x: x, y: $0)] }
        return (0..<3).map { channel in column.map { $0[channel] }.sorted()[column.count / 2] }
    }

    /// The row nearest `y` where every column in `xs` shows plain paper.
    private func plainRow(_ blank: Plane, xs: [CGFloat], near y: CGFloat) -> CGFloat {
        let papers = xs.map { paper(blank, x: $0) }
        let rows = stride(from: 0, through: 6, by: 1 / blank.scale).flatMap { [y + $0, y - $0] }
        return rows.first { row in zip(xs, papers).allSatisfy { x, paper in zip(blank[CGPoint(x: x, y: row)], paper).allSatisfy { abs($0 - $1) <= 1 } } } ?? y
    }

    /// The row within a few points of `y` where ruling stands out most from the paper, if any does.
    private func ruledRow(_ blank: Plane, x: CGFloat, near y: CGFloat) -> CGFloat? {
        let paper = paper(blank, x: x)
        let rows = stride(from: y - 6, through: y + 6, by: 1 / blank.scale).map { row in (row, zip(blank[CGPoint(x: x, y: row)], paper).map { abs($0 - $1) }.reduce(0, +)) }
        return rows.max { $0.1 < $1.1 }.flatMap { $0.1 > 12 ? $0.0 : nil }
    }

    /// On dark paper an even highlight is PencilKit's own: a line, and the ruling under it, are as PencilKit draws them, a crossing
    /// of one pen is the line, and a later colour of the same strength covers an earlier one. PencilKit's line is a little
    /// fainter off its middle (0.75 against 0.765), so the line is read along its middle and the ruling, wherever it falls, to 4.
    private func checkDark(even: Plane, kit: Plane, blank: Plane, _ kind: String, line: UInt = #line) {
        let level = plainRow(blank, xs: [120, 180], near: 80), lower = plainRow(blank, xs: [220], near: 150), across = plainRow(blank, xs: [220], near: 80)
        assertColor(even[CGPoint(x: 180, y: level)], kit[CGPoint(x: 180, y: level)], within: 2, "\(kind): a line is PencilKit's own colour", line: line)
        if let ruled = ruledRow(blank, x: 180, near: 80) {
            assertColor(even[CGPoint(x: 180, y: ruled)], kit[CGPoint(x: 180, y: ruled)], within: 4, "\(kind): ruling under it is hazed as PencilKit hazes it", line: line)
        } else {
            XCTFail("\(kind): no ruling under the line", line: line)
        }
        assertColor(even[CGPoint(x: 120, y: level)], even[CGPoint(x: 180, y: level)], within: 1, "\(kind): two lines of one pen cross unseen", line: line)
        XCTAssertGreaterThan(zip(kit[CGPoint(x: 120, y: level)], kit[CGPoint(x: 180, y: level)]).map { abs($0 - $1) }.max() ?? 0, 6,
                             "\(kind): where PencilKit's own cross, it shows", line: line)
        assertColor(even[CGPoint(x: 220, y: across)], even[CGPoint(x: 220, y: lower)], within: 1, "\(kind): the later pink covers the yellow", line: line)
    }

    func testOnDarkPaperAPictureHasPencilKitsOwnColours() async throws {
        let ink = PKDrawing(strokes: crossings), assets = temporaryRoot(self).url
        func ruled(_ color: PaperColor) -> NotebookPage {
            NotebookPage(background: .template(PaperTemplate.narrowRuled.rawValue), paperColor: color, size: rect.size)
        }
        func plane(_ image: UIImage) -> Plane { Plane(rect.size, scale: 2) { _ in image.draw(in: CGRect(origin: .zero, size: self.rect.size)) } }

        let chalkboard = ruled(.chalkboard)
        let board = { (ink: PKDrawing, even: Bool) in plane(PageRenderer.image(of: chalkboard, ink: ink, assets: assets, width: 360, scale: 2, evenHighlights: even)) }
        checkDark(even: board(ink, true), kit: board(ink, false), blank: board(PKDrawing(), false), "Chalkboard")

        let white = ruled(.white)
        let thumbnail = { (ink: PKDrawing, even: Bool) in plane(PageThumbnailer.render(page: white, ink: ink, assets: assets, night: true, even: even)) }
        checkDark(even: thumbnail(ink, true), kit: thumbnail(ink, false), blank: thumbnail(PKDrawing(), false), "white paper turned dark in a thumbnail")

        let charcoal = ruled(.charcoal), root = temporaryRoot(self)
        let paper = PageDefaults(template: .narrowRuled, paperColor: .charcoal, pageSize: .letter)
        let manifest = NotebookManifest(title: "Dark", defaults: paper, pages: [charcoal])
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        var exported: [Plane] = []
        for (drawing, even) in [(ink, true), (ink, false), (PKDrawing(), false)] {
            var options = NotebookExporter.Options()
            options.evenHighlights = even
            let input = NotebookExporter.Input(title: "Dark", pages: [charcoal], inMemoryInk: [charcoal.id: drawing], package: package)
            let urls = try await NotebookExporter.exportImages(input, options: options) { _ in }
            addTeardownBlock { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
            exported.append(plane(try XCTUnwrap(UIImage(contentsOfFile: urls[0].path(percentEncoded: false)))))
        }
        checkDark(even: exported[0], kit: exported[1], blank: exported[2], "Charcoal in an export")
    }

    func testAPictureWithoutPaperLetsWhatItIsLaidOnShowThrough() {
        let page = blank(rect.size), assets = temporaryRoot(self).url, ink = PKDrawing(strokes: crossings)
        let bare = PageRenderer.image(of: page, ink: ink, assets: assets, width: 360, scale: 2, paper: false, evenHighlights: true)
        let clear = Plane(rect.size, scale: 2) { _ in bare.draw(in: CGRect(origin: .zero, size: self.rect.size)) }
        let strength = Int((EvenHighlights.strength(of: crossings[0]) * 255).rounded())
        XCTAssertEqual(clear.alpha(at: CGPoint(x: 180, y: 80)), strength, accuracy: 2, "a highlight is see-through, at its strength")
        XCTAssertEqual(clear.alpha(at: CGPoint(x: 120, y: 80)), strength, accuracy: 2, "and where one pen crosses itself the same")
        let onWhite = Plane(rect.size, scale: 2, ground: .white) { _ in bare.draw(in: CGRect(origin: .zero, size: self.rect.size)) }
        let withPaper = Plane(rect.size, scale: 2) { _ in
            PageRenderer.image(of: page, ink: ink, assets: assets, width: 360, scale: 2, evenHighlights: true).draw(in: CGRect(origin: .zero, size: self.rect.size))
        }
        for point in [CGPoint(x: 180, y: 80), CGPoint(x: 120, y: 80), CGPoint(x: 220, y: 150)] {
            assertColor(onWhite[point], withPaper[point], within: 2, "on white it looks as with the paper, at \(point)")
        }
    }

    func testTheSVGKeepsAnElementEachAndATranslucentGroup() throws {
        let group = InkSVG.group(annotated, from: rect, size: rect.size, style: InkVectors.Style(evenHighlights: true))
        let ids = group.matches(of: /id="(ink[^"]*)"/).map { String($0.output.1) }
        XCTAssertEqual(ids, ["ink", "ink-highlights", "ink-2", "ink-3", "ink-4", "ink-1"], "highlights first, under the writing, each still its own element")
        let opening = try XCTUnwrap(group.firstMatch(of: /<g id="ink-highlights" opacity="([0-9.]+)" style="mix-blend-mode:multiply">/))
        let opacity = try XCTUnwrap(Double(opening.output.1))
        XCTAssertEqual(opacity, Double(EvenHighlights.strength(of: crossings[0])), accuracy: 0.011, "a reader without blend modes sees the page through them")
        let paths = group.matches(of: /<path id="ink-([234])" data-ink="highlighter" fill="#([0-9a-f]{6})" fill-rule="nonzero" d="([^"]+)"\/>/)
        XCTAssertEqual(paths.count, 3, "solid shapes with no opacity of their own")
        func drawn(blending: Bool, fill: (Int) -> CGColor) -> Plane {
            Plane(rect.size, scale: 2, ground: .white) { ctx in
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(CGRect(x: 60, y: 76, width: 20, height: 8))
                if blending { ctx.setBlendMode(.multiply) }
                ctx.setAlpha(opacity)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setBlendMode(.normal)
                for path in paths {
                    ctx.setFillColor(fill(Int(path.output.2, radix: 16) ?? 0))
                    ctx.addPath(svgPath(String(path.output.3)))
                    ctx.fillPath(using: .winding)
                }
                ctx.endTransparencyLayer()
            }
        }
        let read = drawn(blending: true) { CGColor(srgbRed: CGFloat($0 >> 16) / 255, green: CGFloat($0 >> 8 & 255) / 255, blue: CGFloat($0 & 255) / 255, alpha: 1) }
        let marks = EvenHighlights.marks(of: crossings, onDark: false)
        assertColor(read[CGPoint(x: 180, y: 86)], bytes(marks[0].color), within: 2, "drawn as written, a highlight is as strong as in a picture")
        assertColor(read[CGPoint(x: 120, y: 86)], bytes(marks[0].color), within: 2, "and crosses itself unseen")
        assertColor(read[CGPoint(x: 70, y: 80)], [0, 0, 0], "black stays black under it")
        let plain = drawn(blending: false) { _ in UIColor.white.cgColor }
        XCTAssertLessThan(plain[CGPoint(x: 70, y: 80)].max() ?? 255, 240, "without blend modes even a white shape leaves what is under it showing")
        let off = InkSVG.group(annotated, from: rect, size: rect.size, style: InkVectors.Style(evenHighlights: false))
        XCTAssertNil(off.range(of: "ink-highlights"), "without the setting the SVG is as it was")
    }

    func testOnDarkPaperTheSVGHasAGroupForEachLayer() throws {
        let narrow = finger(straight(CGPoint(x: 40, y: 200), CGPoint(x: 300, y: 200)), tool: 7.5)
        let strokes = PKDrawing(strokes: annotated.strokes + [narrow, finger(straight(CGPoint(x: 260, y: 150), CGPoint(x: 260, y: 230)))])
        let style = InkVectors.Style(appearance: .dark, multipliesHighlighter: false, evenHighlights: true)
        let group = InkSVG.group(strokes, from: rect, size: rect.size, style: style)
        XCTAssertNil(group.range(of: "mix-blend-mode"), "laid over dark paper, nothing is blended")
        XCTAssertEqual(group.matches(of: /id="(ink[^"]*)"/).map { String($0.output.1) }, ["ink", "ink-highlights", "ink-2", "ink-3", "ink-4", "ink-5", "ink-6", "ink-1"])
        let layers = group.matches(of: /<g opacity="([0-9.]+)">((?:\n<path [^>]+\/>)+)\n<\/g>/)
        XCTAssertEqual(layers.map { String($0.output.1) }, ["0.77", "0.69", "0.77"], "the narrow line between two of the default width starts a layer, and the last goes over it")
        XCTAssertEqual(layers.map { $0.output.2.matches(of: /id="ink-(\d)"/).map { String($0.output.1) } }, [["2", "3", "4"], ["5"], ["6"]])
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        PKInkingTool.convertColor(yellow, from: .light, to: .dark).getRed(&r, green: &g, blue: &b, alpha: nil)
        XCTAssertNotNil(group.range(of: "id=\"ink-2\" data-ink=\"highlighter\" fill=\"\(SVGText.color(UIColor(red: r, green: g, blue: b, alpha: 1)).hex)\""),
                        "each shape is the ink as PencilKit shows it on dark paper, solid")
    }

    func testThePageSVGFollowsTheExportsSetting() {
        let page = blank(rect.size), assets = temporaryRoot(self).url
        var options = NotebookExporter.Options()
        options.evenHighlights = true
        let even = String(decoding: PageSVG.data(for: page, ink: annotated, assets: assets, title: "Even", options: options), as: UTF8.self)
        options.evenHighlights = false
        let plain = String(decoding: PageSVG.data(for: page, ink: annotated, assets: assets, title: "Even", options: options), as: UTF8.self)
        XCTAssertNotNil(even.range(of: "<g id=\"ink-highlights\""))
        XCTAssertNil(plain.range(of: "<g id=\"ink-highlights\""))
    }

    func testTheTimelapseEndsWithEvenHighlights() async throws {
        let root = temporaryRoot(self)
        let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
        let manifest = NotebookManifest(title: "Film", defaults: paper, pages: [paper.newPage()])
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        let input = NotebookExporter.Input(title: manifest.title, pages: manifest.pages, inMemoryInk: [manifest.pages[0].id: annotated], package: package)
        var dark = manifest.pages[0]
        dark.paperColor = .charcoal
        let night = NotebookExporter.Input(title: manifest.title, pages: [dark], inMemoryInk: [dark.id: PKDrawing(strokes: crossings)], package: package)
        var colours: [[Int]] = []
        for (input, even) in [(input, true), (input, false), (night, true), (night, false)] {
            let url: URL
            do {
                url = try await InkTimelapse.export(input, evenHighlights: even) { _ in }
            } catch InkTimelapse.Failure.writer(let reason) {
                throw XCTSkip("no video encoder here: \(reason)")
            }
            addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let asset = AVURLAsset(url: url), seconds = try await asset.load(.duration).seconds
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(seconds: seconds - 0.2, preferredTimescale: 600)).image
            let scale = CGFloat(frame.width) / paper.pageSize.points.width, size = CGSize(width: CGFloat(frame.width) / scale, height: CGFloat(frame.height) / scale)
            let drawn = Plane(size, scale: scale) { ctx in
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(frame, in: CGRect(origin: .zero, size: size))
            }
            // Beside the pen's line on white paper, along the highlight's middle on dark, where PencilKit's is as strong as ours.
            let y: CGFloat = input.pages[0].paperColor == .charcoal ? 80 : 86
            colours += [drawn[CGPoint(x: 180, y: y)], drawn[CGPoint(x: 120, y: y)]]
        }
        assertColor(colours[1], colours[0], within: 4, "with even highlights the last frame's crossing is the line's colour")
        XCTAssertLessThan(colours[3][2] + 20, colours[2][2], "without, the crossing is darker")
        assertColor(colours[5], colours[4], within: 4, "on dark paper too")
        assertColor(colours[4], colours[6], within: 4, "and the line is PencilKit's own colour")
    }

    // MARK: Pictures already made

    func testThumbnailsAndCoversAreNamedForTheSetting() async throws {
        let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
        let page = paper.newPage()
        XCTAssertNotEqual(PageThumbnailer.key(for: page, night: false, even: true), PageThumbnailer.key(for: page, night: false, even: false))
        XCTAssertNotEqual(PageThumbnailer.key(for: page, night: true, even: true), PageThumbnailer.key(for: page, night: false, even: true))
        XCTAssertEqual(PageThumbnailer.key(for: page, night: false, even: false), page.thumbnailKey, "with the setting off, names are as they were")

        let root = temporaryRoot(self)
        let manifest = NotebookManifest(title: "Thumbs", defaults: paper, pages: [page])
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        for key in PageThumbnailer.keys(for: page, even: true) + PageThumbnailer.keys(for: page, even: false) {
            try await package.writeThumbnail(Data([1]), pageID: page.id, key: key)
        }
        await package.collectGarbage(keeping: manifest)
        let kept = Set(try FileManager.default.contentsOfDirectory(atPath: package.thumbsDirectory.path(percentEncoded: false)))
        let now = Set(PageThumbnailer.keys(for: page).map { package.thumbURL(page.id, key: $0).lastPathComponent })
        XCTAssertEqual(kept, now, "the clean-up keeps the thumbnails the setting shows and no others")
    }
}
