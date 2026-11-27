import XCTest
import PencilKit
@testable import OwlLuna

private let written = Date(timeIntervalSince1970: 1_790_000_000)

/// A straight stroke of points that are all alike.
private func line(_ ink: PKInk.InkType, color: UIColor = .black, width: CGFloat, height: CGFloat? = nil, opacity: CGFloat = 1, y: CGFloat = 100,
                  azimuth: CGFloat = .pi / 2, count: Int = 24) -> PKStroke {
    let points = (0..<count).map { i -> PKStrokePoint in
        let t = CGFloat(i) / CGFloat(max(count - 1, 1))
        return PKStrokePoint(location: CGPoint(x: 40 + 320 * t, y: y), timeOffset: TimeInterval(t), size: CGSize(width: width, height: height ?? width),
                             opacity: opacity, force: 1, azimuth: azimuth, altitude: 1)
    }
    return PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: points, creationDate: written))
}

/// A line of loops that swells and thins, its strength changing too, like quick handwriting.
private func scribble(_ ink: PKInk.InkType, color: UIColor = .black, sizes: ClosedRange<CGFloat>, opacities: ClosedRange<CGFloat> = 1...1,
                      origin: CGPoint = CGPoint(x: 40, y: 80)) -> PKStroke {
    let points = (0..<60).map { i -> PKStrokePoint in
        let t = CGFloat(i) / 59, angle = t * 8 * .pi, swell = 0.5 + 0.5 * sin(t * 7)
        let size = sizes.lowerBound + (sizes.upperBound - sizes.lowerBound) * swell
        return PKStrokePoint(location: CGPoint(x: origin.x + t * 220 + cos(angle) * 9, y: origin.y + sin(angle) * 14), timeOffset: TimeInterval(t),
                             size: CGSize(width: size, height: size), opacity: opacities.lowerBound + (opacities.upperBound - opacities.lowerBound) * (1 - swell),
                             force: 1, azimuth: .pi / 2, altitude: 1)
    }
    return PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: points, creationDate: written))
}

/// A stroke of the given points.
private func stroke(_ ink: PKInk.InkType, _ points: [PKStrokePoint], color: UIColor = .black) -> PKStroke {
    PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: points, creationDate: written))
}

private func point(_ x: CGFloat, _ y: CGFloat, size: CGFloat, opacity: CGFloat = 1) -> PKStrokePoint {
    PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: TimeInterval(x) / 100, size: CGSize(width: size, height: size), opacity: opacity, force: 1,
                  azimuth: .pi / 2, altitude: 1)
}

@MainActor
final class InkRestyleTests: XCTestCase {
    /// Sizes a hand records for each ink, from narrow to broad.
    private var inks: [(name: String, kind: PKInk.InkType, sizes: ClosedRange<CGFloat>, opacities: ClosedRange<CGFloat>)] {
        var inks: [(String, PKInk.InkType, ClosedRange<CGFloat>, ClosedRange<CGFloat>)] = [
            ("pen", .pen, 3...5, 1...1), ("fineliner", .monoline, 2.5...4, 1...1), ("fountain pen", .fountainPen, 3...7, 1...1),
            ("pencil", .pencil, 1.2...4, 0.2...0.6), ("highlighter", .marker, 8...14, 1...1), ("crayon", .crayon, 6...10, 0.3...1),
            ("watercolour", .watercolor, 8...14, 0.1...0.3),
        ]
        if #available(iOS 26.0, *) { inks.append(("calligraphy pen", .reed, 4...8, 0.5...1)) }
        return inks
    }

    /// How broad each point alone draws.
    private func breadths(of stroke: PKStroke) -> [Double] {
        stroke.path.map { InkRestyle.width(of: PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: [$0], creationDate: written), transform: stroke.transform)) }
    }

    /// How dark a drawing is at each pixel of `rect`, on white, from 0 to 255, row by row.
    private func darkness(_ drawing: PKDrawing, in rect: CGRect, scale: CGFloat) -> (values: [Int], width: Int, height: Int) {
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { image = drawing.image(from: rect, scale: scale) }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let picture = image.cgImage else { return }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let values = (0..<(width * height)).map { p in
            255 - (Int(bytes[p * 4]) * 299 + Int(bytes[p * 4 + 1]) * 587 + Int(bytes[p * 4 + 2]) * 114) / 1000
        }
        return (values, width, height)
    }

    /// The breadth across the middle of a level line at half its strongest, as PencilKit draws it. PencilKit lays a grainy ink
    /// afresh for every path, so the line is drawn several times over and the cross-sections averaged.
    private func drawnBreadth(_ stroke: PKStroke, times: Int = 8, across span: ClosedRange<CGFloat> = 160...240) -> Double {
        let scale: CGFloat = 4, rect = CGRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: 200)
        var profile = [Double](repeating: 0, count: Int(rect.height * scale))
        for _ in 0..<times {
            let path = PKStrokePath(controlPoints: Array(stroke.path), creationDate: stroke.path.creationDate)
            let copy = PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask)
            let dark = darkness(PKDrawing(strokes: [copy]), in: rect, scale: scale)
            for row in 0..<dark.height {
                profile[row] += Double(dark.values[(row * dark.width)..<((row + 1) * dark.width)].reduce(0, +)) / Double(dark.width * times)
            }
        }
        let half = (profile.max() ?? 0) / 2
        guard half > 1, let first = profile.firstIndex(where: { $0 >= half }), let last = profile.lastIndex(where: { $0 >= half }),
              first > 0, last < profile.count - 1 else { return 0 }
        func crossing(_ a: Int, _ b: Int) -> Double { Double(a) + (half - profile[a]) / (profile[b] - profile[a]) * Double(b - a) }
        return (crossing(last, last + 1) - crossing(first - 1, first)) / Double(scale)
    }

    private func assertSamePath(_ a: PKStroke, _ b: PKStroke, sizes: Bool, _ message: String, line: UInt = #line) {
        XCTAssertEqual(a.path.count, b.path.count, message, line: line)
        XCTAssertEqual(a.path.creationDate, b.path.creationDate, message, line: line)
        XCTAssertEqual(a.transform, b.transform, message, line: line)
        XCTAssertEqual(a.ink.inkType, b.ink.inkType, message, line: line)
        for (p, q) in zip(a.path, b.path) {
            XCTAssertEqual(p.location, q.location, message, line: line)
            XCTAssertEqual(p.timeOffset, q.timeOffset, message, line: line)
            XCTAssertEqual(p.opacity, q.opacity, message, line: line)
            XCTAssertEqual(p.azimuth, q.azimuth, message, line: line)
            XCTAssertEqual(p.altitude, q.altitude, message, line: line)
            XCTAssertEqual(p.force, q.force, message, line: line)
            if sizes { XCTAssertEqual(p.size, q.size, message, line: line) }
        }
    }

    // MARK: Width

    func testWidthIsHowBroadEachInkDraws() {
        var cases: [(PKInk.InkType, CGSize, CGFloat, Double)] = [
            (.pen, CGSize(width: 5, height: 5), 1, 6), (.pen, CGSize(width: 5, height: 3), 1, 6), (.monoline, CGSize(width: 2.5, height: 2.5), 1, 1),
            (.fountainPen, CGSize(width: 6, height: 6), 1, 8), (.fountainPen, CGSize(width: 9, height: 6), 1, 10),
            (.pencil, CGSize(width: 4, height: 4), 0.5, 6.084), (.pencil, CGSize(width: 1, height: 1), 1, 1.054), (.pencil, CGSize(width: 16, height: 16), 1, 28.08),
            (.marker, CGSize(width: 8, height: 8), 1, 10.8), (.marker, CGSize(width: 8, height: 16), 1, 22.96),
            (.crayon, CGSize(width: 9, height: 6), 1, 9.942), (.crayon, CGSize(width: 6, height: 9), 1, 14.913),
            (.watercolor, CGSize(width: 12, height: 12), 0.17, 17.436), (.watercolor, CGSize(width: 12, height: 12), 1, 19.86),
        ]
        if #available(iOS 26.0, *) { cases.append((.reed, CGSize(width: 6, height: 4), 1, 7.96)) }
        for (kind, size, opacity, expected) in cases {
            let drawn = line(kind, width: size.width, height: size.height, opacity: opacity)
            XCTAssertEqual(InkRestyle.width(of: drawn), expected, accuracy: expected * 0.002, "\(kind.rawValue) \(size) at \(opacity)")
        }
        XCTAssertEqual(InkRestyle.width(of: line(.pen, width: 1.8)), 0, "a pen point under 2 draws nothing")
    }

    func testTheWidthOfASwellingLineIsWhatMostOfItsLengthIsDrawnAt() {
        // Thin ends crowded with points, as where the pen slowed to start and stop, and a long even middle.
        let start = (0..<12).map { point(40 + CGFloat($0) * 0.3, 100, size: 2.5 + CGFloat($0) * 0.1) }
        let middle = (0..<10).map { point(60 + CGFloat($0) * 30, 100, size: 5) }
        let end = (0..<12).map { point(345 + CGFloat($0) * 0.3, 100, size: 3.6 - CGFloat($0) * 0.1) }
        XCTAssertEqual(InkRestyle.width(of: stroke(.pen, start + middle + end)), 6, accuracy: 1e-9)

        // Broad for a third of its length and fine for the rest, it reads as fine.
        let mostlyFine = (0..<30).map { point(40 + CGFloat($0) * 10, 100, size: $0 < 10 ? 8 : 3) }
        XCTAssertEqual(InkRestyle.width(of: stroke(.pen, mostlyFine)), 2, accuracy: 1e-9)

        // Two points share the length evenly, so the width lies between them; one point is its own width.
        XCTAssertEqual(InkRestyle.width(of: stroke(.pen, [point(40, 100, size: 3), point(80, 100, size: 5)])), 4, accuracy: 1e-9)
        XCTAssertEqual(InkRestyle.width(of: stroke(.pen, [point(40, 100, size: 4)])), 4, accuracy: 1e-9)

        // Points that draw nothing don't count, and a stroke none of whose points draw has no width.
        let fading = (0..<20).map { point(40 + CGFloat($0) * 10, 100, size: $0 < 14 ? 1.5 : 3.5) }
        XCTAssertEqual(InkRestyle.width(of: stroke(.pen, fading)), 3, accuracy: 1e-9)
        XCTAssertEqual(InkRestyle.width(of: line(.pen, width: 1.5)), 0)
    }

    func testATransformScalesTheWidth() {
        var turned = line(.pen, width: 4)
        turned.transform = CGAffineTransform(scaleX: 2.5, y: 2.5).rotated(by: 0.4).translatedBy(x: 30, y: -12)
        XCTAssertEqual(InkRestyle.width(of: turned), 10, accuracy: 1e-6)

        let lined = InkRestyle.lined(turned, .width(5))
        XCTAssertEqual(InkRestyle.width(of: lined), 5, accuracy: 1e-4)
        XCTAssertEqual(lined.transform, turned.transform)
        XCTAssertEqual(lined.path[0].size.width, 3, accuracy: 1e-5, "a line 2 broad in the stroke's own points")
    }

    // MARK: Lines

    func testEveryInkTakesTheWidthAskedAndKeepsItsSwell() {
        for ink in inks {
            let original = scribble(ink.kind, sizes: ink.sizes, opacities: ink.opacities)
            let before = InkRestyle.width(of: original), shares = breadths(of: original)
            XCTAssertGreaterThan(before, 0, ink.name)
            for asked in [0.5, 1.2, 3, 7.5, 18, 42, 60, 80] {
                let lined = InkRestyle.lined(original, .width(asked))
                XCTAssertEqual(InkRestyle.width(of: lined), asked, accuracy: asked * 1e-3, "\(ink.name) at \(asked)")
                assertSamePath(lined, original, sizes: false, ink.name)
                let factor = asked / before
                for (old, new) in zip(shares, breadths(of: lined)) {
                    XCTAssertEqual(new / old, factor, accuracy: factor * 2e-3, "\(ink.name): each point keeps its share of the swell")
                }
            }
            for factor in [0.4, 0.75, 1.5, 2, 3.5] {
                let lined = InkRestyle.lined(original, .times(factor))
                XCTAssertEqual(InkRestyle.width(of: lined), InkRestyle.clamped(before * factor, from: before), accuracy: before * factor * 1e-3,
                               "\(ink.name) times \(factor)")
            }
            let again = InkRestyle.lined(InkRestyle.lined(original, .times(2)), .times(0.5))
            XCTAssertEqual(InkRestyle.width(of: again), before, accuracy: before * 1e-3, "\(ink.name) there and back")
            XCTAssertEqual(InkRestyle.lined(original, .times(1)).path.count, original.path.count)
        }
    }

    /// PencilKit keeps a point's height as a share of its width, cut to a thousandth, so heights are compared that finely.
    func testANibKeepsItsProportions() {
        var chisels: [PKInk.InkType] = [.marker, .crayon, .watercolor]
        if #available(iOS 26.0, *) { chisels.append(.reed) }
        for kind in chisels {
            let original = line(kind, width: 12, height: 8), size = original.path[0].size
            let lined = InkRestyle.lined(original, .times(2))
            XCTAssertEqual(lined.path[0].size.width, 2 * size.width, accuracy: 1e-4, kind.rawValue)
            XCTAssertEqual(lined.path[0].size.height, 2 * size.height, accuracy: 0.024, kind.rawValue)
        }
        // A fountain pen's nib is 2 narrower than its point all round, and cut short at its height less 1.
        let fountain = line(.fountainPen, width: 9, height: 6), size = fountain.path[0].size
        let broader = InkRestyle.lined(fountain, .times(2))
        XCTAssertEqual(broader.path[0].size.width, 16, accuracy: 1e-4)
        XCTAssertEqual(broader.path[0].size.height, 1 + 2 * (size.height - 1), accuracy: 0.016)
        XCTAssertEqual(InkRestyle.width(of: broader), 2 * InkRestyle.width(of: fountain), accuracy: 0.032)
        let pen = InkRestyle.lined(line(.pen, width: 4), .times(3))
        XCTAssertEqual(pen.path[0].size.width, 8, accuracy: 1e-4, "a 4 pt line from a 4 pt point; 12 pt takes an 8 pt point")
    }

    func testLiningKeepsWhereAndHowTheStrokeLies() {
        var original = scribble(.pencil, sizes: 1.5...3, opacities: 0.2...0.7)
        original.transform = CGAffineTransform(rotationAngle: 0.3).translatedBy(x: 12, y: 40)
        original.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 150, height: 200))
        let lined = InkRestyle.lined(original, .times(1.7)), narrowed = InkRestyle.lined(original, .times(0.6))
        assertSamePath(lined, original, sizes: false, "pencil")
        assertSamePath(narrowed, original, sizes: false, "pencil")
        XCTAssertEqual(narrowed.mask?.cgPath.boundingBoxOfPath, original.mask?.cgPath.boundingBoxOfPath)
        XCTAssertTrue(lined.mask?.bounds.contains(original.mask?.bounds ?? .null) ?? false)
        XCTAssertEqual(lined.randomSeed, original.randomSeed)
        XCTAssertEqual(lined.ink.color, original.ink.color)
        if #available(iOS 27.0, *) { XCTAssertEqual(lined.id, original.id, "it is the same stroke") }
    }

    func testWidthsStayWithinTheLimits() {
        let pen = line(.pen, width: 4)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(pen, .width(1000))), InkRestyle.widths.upperBound, accuracy: 1e-4)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(pen, .width(0.01))), InkRestyle.widths.lowerBound, accuracy: 1e-4)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(pen, .times(1000))), InkRestyle.widths.upperBound, accuracy: 1e-4)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(pen, .times(0))), InkRestyle.widths.lowerBound, accuracy: 1e-4)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(pen, .times(-3))), InkRestyle.widths.lowerBound, accuracy: 1e-4)
        for odd in [Double.nan, .infinity] {
            XCTAssertEqual(InkRestyle.lined(pen, .times(odd)).path[0].size, pen.path[0].size)
            XCTAssertEqual(InkRestyle.lined(pen, .width(odd)).path[0].size, pen.path[0].size)
        }

        // A line finer than the limit isn't made finer.
        let fine = line(.pen, width: 2.15)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(fine, .times(0.5))), 0.3, accuracy: 1e-4)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(fine, .times(3))), 0.9, accuracy: 1e-4)
    }

    /// A stroke resized by its handles carries a transform that can take its line past the limits. It is never taken
    /// further out, nor drawn in further than asked; once drawn in, it can't go back out past the limit.
    func testALinePastTheLimitsByItsTransformIsKeptWhereItIs() {
        var broad = line(.pen, width: 22)
        broad.transform = CGAffineTransform(scaleX: 3, y: 3).rotated(by: 0.5)
        XCTAssertEqual(InkRestyle.width(of: broad), 120, accuracy: 1e-6)
        XCTAssertEqual(InkRestyle.lined(broad, .times(1.5)).path[0].size, broad.path[0].size, "no broader")
        XCTAssertEqual(InkRestyle.lined(broad, .width(200)).path[0].size, broad.path[0].size)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(broad, .times(0.5))), 60, accuracy: 1e-4)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(broad, .width(100))), 100, accuracy: 1e-4)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(broad, .width(1))), 1, accuracy: 1e-4)
        let drawnIn = InkRestyle.lined(broad, .times(0.8))
        XCTAssertEqual(InkRestyle.width(of: drawnIn), 96, accuracy: 1e-4)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(drawnIn, .times(1.25))), 96, accuracy: 1e-4, "kept to where it was drawn in to")
        XCTAssertEqual(InkRestyle.lined(drawnIn, .times(1.25)).transform, broad.transform)

        var tiny = line(.pen, width: 2.5)
        tiny.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        XCTAssertEqual(InkRestyle.width(of: tiny), 0.3, accuracy: 1e-6)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(tiny, .times(0.5))), 0.3, accuracy: 1e-6, "no finer")
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(tiny, .width(0.1))), 0.3, accuracy: 1e-6)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(tiny, .times(3))), 0.9, accuracy: 1e-5)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(InkRestyle.lined(tiny, .times(3)), .times(1 / 3))), 0.5, accuracy: 1e-5,
                       "once out, it comes back only to the limit")
    }

    // MARK: Again and again

    /// The largest share by which two strokes' point sizes differ, across and along.
    private func sizeDrift(_ a: PKStroke, _ b: PKStroke) -> (width: Double, height: Double) {
        var width = 0.0, height = 0.0
        for (p, q) in zip(a.path, b.path) {
            width = max(width, abs(p.size.width - q.size.width) / q.size.width)
            height = max(height, abs(p.size.height - q.size.height) / q.size.height)
        }
        return (width, height)
    }

    func testTimesOneAfterAnotherIsTimesTheirProduct() {
        for ink in inks {
            let original = scribble(ink.kind, sizes: ink.sizes, opacities: ink.opacities)
            for (a, b) in [(1.1, 1.1), (0.9, 1.3), (2, 1.5), (0.5, 0.8), (3, 0.5), (0.6, 4)] {
                let twice = InkRestyle.lined(InkRestyle.lined(original, .times(a)), .times(b)), once = InkRestyle.lined(original, .times(a * b))
                XCTAssertEqual(InkRestyle.width(of: twice), InkRestyle.width(of: once), accuracy: InkRestyle.width(of: once) * 1e-5, "\(ink.name) \(a) then \(b)")
                let drift = sizeDrift(twice, once)
                XCTAssertLessThan(drift.width, 1e-5, "\(ink.name) \(a) then \(b)")
                XCTAssertLessThan(drift.height, 1e-5, "\(ink.name) \(a) then \(b)")
            }
        }
    }

    /// The width strip's plates, a tenth of the first width each, tapped up to three times, down to half and back.
    func testARunOfPlatesComesBackToTheLineItWas() {
        var steps: [Double] = []
        for tenth in 10..<30 { steps.append(Double(tenth + 1) / Double(tenth)) }
        for tenth in stride(from: 30, to: 5, by: -1) { steps.append(Double(tenth - 1) / Double(tenth)) }
        for tenth in 5..<10 { steps.append(Double(tenth + 1) / Double(tenth)) }
        var chisel = line(.marker, width: 12, height: 8)
        chisel.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
        let strokes = inks.map { (name: $0.name, stroke: scribble($0.kind, sizes: $0.sizes, opacities: $0.opacities)) }
            + [("flat highlighter", chisel), ("flat crayon", line(.crayon, width: 9, height: 6, opacity: 0.6))]
        for (name, original) in strokes {
            var stroke = original
            for step in steps { stroke = InkRestyle.lined(stroke, .times(step)) }
            XCTAssertEqual(InkRestyle.width(of: stroke), InkRestyle.width(of: original), accuracy: InkRestyle.width(of: original) * 1e-5, name)
            let drift = sizeDrift(stroke, original)
            XCTAssertLessThan(drift.width, 1e-5, name)
            XCTAssertLessThan(drift.height, 1e-5, name)
            assertSamePath(stroke, original, sizes: false, name)

            let back = InkRestyle.lined(InkRestyle.lined(original, .times(2)), .times(0.5))
            XCTAssertLessThan(sizeDrift(back, original).width, 1e-6, "\(name) out and back")
            XCTAssertLessThan(sizeDrift(back, original).height, 1e-6, "\(name) out and back")
        }
    }

    /// What a limit takes on the way can't be had back: the line comes back narrower, or broader, than it was.
    func testALimitHitOnTheWayIsLost() {
        let broad = line(.pen, width: 22)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(broad, .times(3))), 80, accuracy: 1e-4)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(InkRestyle.lined(broad, .times(3)), .times(1 / 3))), 80.0 / 3, accuracy: 1e-4)
        let fine = line(.pen, width: 2.5)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(InkRestyle.lined(fine, .times(0.25)), .times(4))), 2, accuracy: 1e-4)

        // A partly rubbed-out stroke's mask grows with its line and stays grown when the line is drawn in again.
        var erased = line(.pen, width: 4)
        erased.mask = UIBezierPath(rect: CGRect(x: 0, y: 97, width: 200, height: 6))
        let back = InkRestyle.lined(InkRestyle.lined(erased, .times(2)), .times(0.5))
        XCTAssertLessThan(sizeDrift(back, erased).width, 1e-6)
        XCTAssertEqual(back.mask?.cgPath.boundingBoxOfPath.maxX ?? 0, 202, accuracy: 0.05)
    }

    func testAStrokeThatDrawsNothingIsGivenALineWhenOneIsAsked() {
        let unseen = line(.pen, width: 1.5)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(unseen, .times(2))), InkRestyle.widths.lowerBound, accuracy: 1e-4)
        XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(unseen, .width(3))), 3, accuracy: 1e-4)
        for ink in inks {
            let blank = line(ink.kind, width: 0, opacity: ink.opacities.lowerBound)
            XCTAssertEqual(InkRestyle.width(of: blank), 0, ink.name)
            XCTAssertEqual(InkRestyle.width(of: InkRestyle.lined(blank, .width(4))), 4, accuracy: 4e-3, ink.name)
        }
    }

    func testAnEmptyPathIsLeftAlone() {
        let empty = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [], creationDate: written))
        XCTAssertEqual(InkRestyle.width(of: empty), 0)
        XCTAssertEqual(InkRestyle.lined(empty, .times(2)).path.count, 0)
        XCTAssertEqual(InkRestyle.lined(empty, .width(3)).path.count, 0)
        XCTAssertEqual(InkRestyle.look(of: [empty]), InkLook(tints: [0x0000_00FF], widths: 0...0))
        XCTAssertEqual(InkRestyle.look(of: [empty, line(.pen, width: 4)])?.widths, 4...4)
    }

    /// PencilKit masks a partly rubbed-out stroke to the line it was. Broadened, the mask grows with it: the line is
    /// drawn broader, and what was rubbed out stays out, the gap closing by as much as the line grows.
    func testARubbedOutStrokeGrowsWithItsMask() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("PencilKit rubs out in code from iOS 27") }
        let eraser = (0...10).map { point(200, 60 + CGFloat($0) * 8, size: 12) }
        let erased = PKDrawing(strokes: [line(.pen, width: 4)]).erasingPath(PKStrokePath(controlPoints: eraser, creationDate: written))
        XCTAssertEqual(erased.strokes.count, 2)
        XCTAssertTrue(erased.strokes.allSatisfy { $0.mask != nil })
        XCTAssertLessThan(erased.strokes[0].mask?.bounds.height ?? 0, 8, "the mask hugs the line")

        let broad = PKDrawing(strokes: erased.strokes.map { InkRestyle.lined($0, .times(3)) })
        XCTAssertEqual(drawnBreadth(broad.strokes[0], times: 1, across: 60...160), 12, accuracy: 0.3)
        let dark = darkness(broad, in: CGRect(x: 0, y: 0, width: 400, height: 200), scale: 1)
        XCTAssertEqual(dark.values[100 * dark.width + 200], 0, "the gap stays")

        let fine = InkRestyle.lined(erased.strokes[0], .times(0.5))
        let kept = try XCTUnwrap(fine.mask?.bounds), was = try XCTUnwrap(erased.strokes[0].mask?.bounds)
        for (a, b) in [(kept.minX, was.minX), (kept.minY, was.minY), (kept.maxX, was.maxX), (kept.maxY, was.maxY)] {
            XCTAssertEqual(a, b, accuracy: 0.05, "narrowed, it keeps its mask")
        }
        XCTAssertEqual(drawnBreadth(fine, times: 1, across: 60...160), 2, accuracy: 0.3)
    }

    /// Pen, highlighter and the grainy pencil, as PencilKit draws them: twice as broad, and as broad as asked.
    func testPencilKitDrawsTheWidthsAsked() {
        let cases: [(String, PKStroke, tolerance: Double, asked: [Double])] = [
            ("pen", line(.pen, width: 3.2), 0.02, [1, 8, 20]),
            ("highlighter", line(.marker, width: 13.75), 0.03, [8, 30]),
            ("pencil", line(.pencil, width: 1.4, opacity: 0.35), 0.06, [0.8, 2.5, 6]),
            ("pencil", line(.pencil, width: 3, opacity: 0.8), 0.05, [1.5, 12]),
        ]
        for (name, original, tolerance, asked) in cases {
            let before = drawnBreadth(original)
            XCTAssertEqual(before, InkRestyle.width(of: original), accuracy: before * tolerance, "\(name) as it is")
            XCTAssertEqual(drawnBreadth(InkRestyle.lined(original, .times(2))) / before, 2, accuracy: 2 * tolerance, "\(name) twice as broad")
            for width in asked {
                XCTAssertEqual(drawnBreadth(InkRestyle.lined(original, .width(width))), width, accuracy: width * tolerance, "\(name) at \(width)")
            }
        }
    }

    // MARK: Colour

    func testEveryInkTakesEveryColourAndKeepsItsStrength() throws {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for kind in ToolPreset.kinds {
            for tint in ToolPreset.inks + ToolPreset.tints {
                for alpha: CGFloat in [1, 0.6, 0.25] {
                    let original = scribble(kind, color: UIColor(white: 0, alpha: alpha), sizes: 4...6)
                    let tinted = InkRestyle.tinted(original, tint)
                    let saved = try PKDrawing(data: PKDrawing(strokes: [tinted]).dataRepresentation()).strokes[0]
                    let name = "\(kind.rawValue) \(String(tint, radix: 16)) at \(alpha)"
                    for (stroke, kept) in [(tinted, "tinted"), (saved, "saved")] {
                        XCTAssertEqual(InkRestyle.look(of: [stroke])?.tints, [tint], "\(name) \(kept)")
                        // PencilKit saves a fineliner's ink as a pen's, which draws the same.
                        XCTAssertEqual(stroke.ink.inkType, kept == "saved" && kind == .monoline ? .pen : kind, "\(name) \(kept)")
                        XCTAssertEqual(stroke.ink.color.cgColor.alpha, alpha, accuracy: 1e-6, "\(name) \(kept)")
                        XCTAssertEqual(ToolPreset.bytes(of: stroke.ink.color.resolvedColor(with: dark)), ToolPreset.bytes(of: stroke.ink.color),
                                       "\(name) \(kept): kept as the ink is on light paper")
                    }
                    assertSamePath(tinted, original, sizes: true, name)
                }
            }
        }
        let red = line(.pen, color: ToolPreset.uiColor(0xC945_2FFF), width: 4)
        XCTAssertEqual(InkRestyle.tinted(red, 0xC945_2FFF).ink.color, red.ink.color, "already that colour")

        var placed = scribble(.crayon, sizes: 6...9, opacities: 0.4...1)
        placed.transform = CGAffineTransform(rotationAngle: 0.2).translatedBy(x: 5, y: 9)
        placed.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 120, height: 200))
        let blue = InkRestyle.tinted(placed, 0x2747_B8FF)
        assertSamePath(blue, placed, sizes: true, "crayon")
        XCTAssertEqual(blue.randomSeed, placed.randomSeed)
        XCTAssertEqual(blue.mask?.bounds, placed.mask?.bounds)
        if #available(iOS 27.0, *) { XCTAssertNotEqual(blue.id, placed.id, "made anew, so a canvas draws it again") }
    }

    func testTheLookPutsTheMostUsedColourFirst() {
        let colours: [UInt32] = [0xC945_2FFF, 0x2747_B8FF, 0x2747_B8FF, 0x2F8F_4EFF, 0xC945_2FFF, 0xFFD4_26FF, 0x2747_B8FF]
        let strokes = colours.enumerated().map { index, colour in
            line(index == 5 ? .marker : .pen, color: ToolPreset.uiColor(colour & 0xFFFF_FF00 | 0x80), width: 3 + CGFloat(index))
        }
        let look = InkRestyle.look(of: strokes)
        XCTAssertEqual(look?.tints, [0x2747_B8FF, 0xC945_2FFF, 0x2F8F_4EFF, 0xFFD4_26FF])
        XCTAssertEqual(look?.widths.lowerBound ?? 0, 2, accuracy: 1e-6)
        XCTAssertEqual(look?.widths.upperBound ?? 0, 14, accuracy: 1e-6)
        XCTAssertNil(InkRestyle.look(of: []))
        XCTAssertEqual(InkRestyle.look(of: [line(.pen, width: 1.5), line(.pen, width: 3)])?.widths, 2...2, "a stroke that draws nothing has no width")
    }

    // MARK: Selections

    func testASelectionChangesOnlyItsStrokesAndKeepsTheirPlaces() throws {
        let first = UUID(), second = UUID(), third = UUID()
        func page(_ count: Int, at y: CGFloat) -> PKDrawing {
            PKDrawing(strokes: (0..<count).map { line(.pen, color: .darkGray, width: 3 + CGFloat($0), y: y + CGFloat($0) * 20) })
        }
        let drawings = [first: page(5, at: 40), second: page(4, at: 300), third: page(3, at: 600)]
        let selection: InkSelection = [first: [1, 3, 3], second: [0, 9], third: []]

        let lined = InkRestyle.lined(selection, .times(2), in: drawings)
        XCTAssertEqual(Set(lined.keys), [first, second], "pages with nothing chosen are left out")
        let tinted = InkRestyle.tinted(selection, 0xC945_2FFF, in: drawings)
        XCTAssertEqual(Set(tinted.keys), [first, second])

        for (id, chosen) in [(first, Set([1, 3])), (second, Set([0]))] {
            let before = try XCTUnwrap(drawings[id]).strokes
            let wider = try XCTUnwrap(lined[id]).strokes, coloured = try XCTUnwrap(tinted[id]).strokes
            XCTAssertEqual(wider.count, before.count)
            XCTAssertEqual(coloured.count, before.count)
            for index in before.indices {
                let width = InkRestyle.width(of: before[index])
                if chosen.contains(index) {
                    XCTAssertEqual(InkRestyle.width(of: wider[index]), 2 * width, accuracy: 1e-4, "changed once, in its place")
                    XCTAssertEqual(InkRestyle.look(of: [coloured[index]])?.tints, [0xC945_2FFF])
                    assertSamePath(wider[index], before[index], sizes: false, "\(index)")
                } else {
                    assertSamePath(wider[index], before[index], sizes: true, "\(index) not chosen")
                    assertSamePath(coloured[index], before[index], sizes: true, "\(index) not chosen")
                    XCTAssertEqual(ToolPreset.bytes(of: coloured[index].ink.color), ToolPreset.bytes(of: before[index].ink.color))
                }
                assertSamePath(coloured[index], before[index], sizes: true, "\(index) tinted")
            }
        }
        XCTAssertTrue(InkRestyle.lined([UUID(): [0]], .times(2), in: drawings).isEmpty, "a page not given")
    }
}
