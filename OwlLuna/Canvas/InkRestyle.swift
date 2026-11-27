import UIKit
import PencilKit

/// How caught ink looks: the colours in it and how broad its lines are.
struct InkLook: Equatable {
    /// Its colours at full strength, as the palette lists them, the most used first.
    var tints: [UInt32]
    /// Its narrowest and its broadest line, in points on the page.
    var widths: ClosedRange<Double>
}

/// A change to how broad the lines of caught ink are.
enum InkLine: Equatable {
    /// So many times as broad as each line is.
    case times(Double)
    /// Every line this broad, in points on the page.
    case width(Double)
}

/// Caught ink in another colour, or with a broader or narrower line. A stroke keeps its kind, its strength, its
/// place in the drawing and where it lies on the page.
enum InkRestyle {
    /// A line is made no narrower and no broader than this, in points on the page.
    static let widths: ClosedRange<Double> = 0.5...80

    /// The width a line `now` broad is given when `asked` is wanted: kept to `widths`, though a line already outside
    /// them is never taken further out, nor drawn in further than asked. A line that draws nothing is given one.
    static func clamped(_ asked: Double, from now: Double) -> Double {
        let lowest = now > 0 ? min(widths.lowerBound, now) : widths.lowerBound
        return min(max(asked, lowest), max(widths.upperBound, now))
    }

    /// The colours and the widths of some strokes; nil for none. A stroke that draws nothing has no width to show.
    static func look(of strokes: [PKStroke]) -> InkLook? {
        guard !strokes.isEmpty else { return nil }
        var counts: [UInt32: Int] = [:], order: [UInt32] = []
        var least = Double.infinity, most = 0.0
        for stroke in strokes {
            let tint = ToolPreset.bytes(of: stroke.ink.color) | 0xFF
            if counts[tint] == nil { order.append(tint) }
            counts[tint, default: 0] += 1
            let width = width(of: stroke)
            guard width > 0 else { continue }
            least = min(least, width)
            most = max(most, width)
        }
        let tints = order.enumerated().sorted { a, b in
            let x = counts[a.element] ?? 0, y = counts[b.element] ?? 0
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        return InkLook(tints: tints, widths: least <= most ? least...most : 0...0)
    }

    /// How broad a stroke's line is on the page, in points, where its nib is drawn broadside on; 0 if it draws nothing.
    /// Over a line that swells and thins it is the breadth half the shown length is drawn at or above, so tapered ends
    /// and the points bunched where the pen slowed count only for their length.
    static func width(of stroke: PKStroke) -> Double {
        Double(breadth(of: stroke.path, nib: Nib(stroke.ink.inkType)) * scale(of: stroke.transform))
    }

    /// The stroke in another colour, as faint as it was. It is made anew: a canvas keeps its old picture of a stroke
    /// it knows whose ink alone has changed.
    static func tinted(_ stroke: PKStroke, _ tint: UInt32) -> PKStroke {
        let color = stroke.ink.color
        guard ToolPreset.bytes(of: color) | 0xFF != tint | 0xFF else { return stroke }
        let ink = PKInk(stroke.ink.inkType, color: ToolPreset.uiColor(tint).withAlphaComponent(color.cgColor.alpha))
        return PKStroke(ink: ink, path: stroke.path, transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
    }

    /// The stroke with its line changed, along the same path. Each point keeps its share of the line's swell, and a
    /// flat nib its proportions. A partly rubbed-out stroke's mask hugs the line it was, so it grows as much as the line.
    static func lined(_ stroke: PKStroke, _ line: InkLine) -> PKStroke {
        let path = stroke.path, nib = Nib(stroke.ink.inkType), scale = scale(of: stroke.transform)
        guard path.count > 0, scale > 0 else { return stroke }
        let old = Array(path), now = Double(breadth(of: old, nib: nib) * scale)
        let asked: Double
        switch line {
        case .times(let factor): asked = now * factor
        case .width(let width): asked = width
        }
        guard asked.isFinite else { return stroke }
        let wanted = clamped(asked, from: now)
        var points: [PKStrokePoint] = [], growth: CGFloat = 0
        points.reserveCapacity(old.count)
        if now > 0 {
            let factor = CGFloat(wanted / now)
            guard abs(factor - 1) > 1e-9 else { return stroke }
            for point in old {
                let breadth = nib.breadth(point.size, opacity: point.opacity)
                guard breadth > 0 else { points.append(point); continue }
                points.append(point.sized(nib.size(point.size, opacity: point.opacity, times: factor)))
                growth = max(growth, (factor - 1) * breadth)
            }
        } else {
            let breadth = CGFloat(wanted) / scale
            points = old.map { $0.sized(nib.size(drawing: breadth, opacity: $0.opacity)) }
            growth = breadth
        }
        var result = stroke
        result.path = PKStrokePath(controlPoints: points, creationDate: path.creationDate)
        if let mask = stroke.mask, growth > 0 { result.mask = grown(mask, by: growth / 2) }
        return result
    }

    /// The drawings that hold the selection, with its strokes in another colour. No stroke changes its place.
    static func tinted(_ selection: InkSelection, _ tint: UInt32, in drawings: [UUID: PKDrawing]) -> [UUID: PKDrawing] {
        changed(selection, in: drawings) { tinted($0, tint) }
    }

    /// The drawings that hold the selection, with its lines changed. No stroke changes its place.
    static func lined(_ selection: InkSelection, _ line: InkLine, in drawings: [UUID: PKDrawing]) -> [UUID: PKDrawing] {
        changed(selection, in: drawings) { lined($0, line) }
    }

    private static func changed(_ selection: InkSelection, in drawings: [UUID: PKDrawing], _ change: (PKStroke) -> PKStroke) -> [UUID: PKDrawing] {
        var result: [UUID: PKDrawing] = [:]
        for (page, indices) in selection {
            guard let drawing = drawings[page], !indices.isEmpty else { continue }
            var strokes = drawing.strokes
            for index in Set(indices) where strokes.indices.contains(index) { strokes[index] = change(strokes[index]) }
            result[page] = PKDrawing(strokes: strokes)
        }
        return result
    }

    /// A mask spread `reach` further all round.
    private static func grown(_ mask: UIBezierPath, by reach: CGFloat) -> UIBezierPath {
        let shape = mask.usesEvenOddFillRule ? mask.cgPath.normalized(using: .evenOdd) : mask.cgPath
        let rim = shape.copy(strokingWithWidth: 2 * reach, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return UIBezierPath(cgPath: shape.union(rim))
    }

    /// How much a stroke's transform enlarges its line.
    private static func scale(of transform: CGAffineTransform) -> CGFloat {
        abs(transform.a * transform.d - transform.b * transform.c).squareRoot()
    }

    /// The breadth half the shown length of a path is drawn at or above, in the path's points. Each point stands for
    /// half the way to the points either side of it.
    private static func breadth(of points: some Collection<PKStrokePoint>, nib: Nib) -> CGFloat {
        var pieces: [(breadth: CGFloat, length: CGFloat)] = []
        pieces.reserveCapacity(points.count)
        var last: CGPoint?, least = CGFloat.infinity, most: CGFloat = 0
        for point in points {
            let here = point.location, half = last.map { hypot(here.x - $0.x, here.y - $0.y) / 2 } ?? 0
            if !pieces.isEmpty { pieces[pieces.count - 1].length += half }
            let breadth = nib.breadth(point.size, opacity: point.opacity)
            pieces.append((breadth, half))
            if breadth > 0 { least = min(least, breadth); most = max(most, breadth) }
            last = here
        }
        guard most > 0 else { return 0 }
        guard least < most else { return most }
        pieces.removeAll { $0.breadth <= 0 }
        var total = pieces.reduce(0) { $0 + $1.length }
        if total > 0 {
            pieces.removeAll { $0.length <= 0 }
        } else {
            pieces = pieces.map { ($0.breadth, 1) }
            total = CGFloat(pieces.count)
        }
        pieces.sort { $0.breadth < $1.breadth }
        var walked: CGFloat = 0
        for (index, piece) in pieces.enumerated() {
            walked += piece.length
            guard walked >= total / 2 else { continue }
            // Exactly half way, as in a line of two points, lies between this breadth and the next.
            if walked - total / 2 <= total * 1e-9, index + 1 < pieces.count { return (piece.breadth + pieces[index + 1].breadth) / 2 }
            return piece.breadth
        }
        return pieces.last?.breadth ?? 0
    }
}

/// How a kind of ink lays a point down, as PencilKit's own picture of it measures: the breadth of the line it draws
/// where the nib is drawn broadside on, in the path's points.
private enum Nib {
    /// Pen and fineliner: a disc 2 pt narrower all round than the point.
    case round
    /// That disc flattened to a quarter across the azimuth, and cut short along it at the point's height less 1.
    case fountain
    case pencil
    /// A chisel set along the azimuth, as long as about 1.35 times the point's height.
    case highlighter
    /// An oval along the azimuth, as long as about 1.35 to 1.66 times the point's height, the more the stronger.
    case crayon
    /// A blot about 1.39 to 1.66 times the point's size across, the more the stronger.
    case watercolour
    /// A flat nib along the azimuth, twice the point's height.
    case calligraphy
    case other

    init(_ ink: PKInk.InkType) {
        switch ink {
        case .pen, .monoline: self = .round
        case .fountainPen: self = .fountain
        case .pencil: self = .pencil
        case .marker: self = .highlighter
        case .crayon: self = .crayon
        case .watercolor: self = .watercolour
        default:
            if #available(iOS 26.0, *), ink == .reed { self = .calligraphy } else { self = .other }
        }
    }

    func breadth(_ size: CGSize, opacity: CGFloat) -> CGFloat {
        let w = size.width, h = size.height, o = min(max(opacity, 0), 1)
        switch self {
        case .round: return 2 * w - 4
        case .fountain: return 2 * min(w - 2, h - 1)
        case .pencil: return Self.pencil(w, o)
        case .highlighter: return (1.52 * h - 0.17 * w) * (0.97 + 0.03 * o)
        case .crayon: return Self.spread(o, Self.crayonSpreads) * h
        case .watercolour: return Self.spread(o, Self.watercolourSpreads) * (w + h) / 2
        case .calligraphy: return 1.99 * h
        case .other: return w
        }
    }

    /// A point's size that draws `factor` times as broad a line.
    func size(_ size: CGSize, opacity: CGFloat, times factor: CGFloat) -> CGSize {
        switch self {
        case .round, .fountain:
            // One cut short by its height stays cut as much; any other keeps its height to its width, so a round one stays round.
            let width = 2 + factor * (size.width - 2)
            return CGSize(width: width, height: size.height < size.width - 1 ? max(1 + factor * (size.height - 1), 0) : width + (size.height - size.width))
        case .pencil:
            let o = min(max(opacity, 0), 1), width = Self.pencilSize(drawing: factor * Self.pencil(size.width, o), o)
            return CGSize(width: width, height: size.width > 0 ? width * (size.height / size.width) : width)
        default:
            return CGSize(width: size.width * factor, height: size.height * factor)
        }
    }

    /// The size of a round point that draws a line `breadth` broad.
    func size(drawing breadth: CGFloat, opacity: CGFloat) -> CGSize {
        let side: CGFloat
        switch self {
        case .round, .fountain: side = 2 + breadth / 2
        case .pencil: side = Self.pencilSize(drawing: breadth, min(max(opacity, 0), 1))
        default: side = breadth / max(self.breadth(CGSize(width: 1, height: 1), opacity: opacity), 0.01)
        }
        return CGSize(width: side, height: side)
    }

    /// How many times its size a crayon's or a watercolour's line is broad, at these opacities.
    private static let crayonSpreads: [(CGFloat, CGFloat)] = [(0.1, 1.35), (0.3, 1.44), (0.5, 1.565), (0.75, 1.645), (1, 1.657)]
    private static let watercolourSpreads: [(CGFloat, CGFloat)] = [(0.05, 1.386), (0.17, 1.453), (0.4, 1.545), (0.7, 1.615), (1, 1.655)]

    private static func spread(_ opacity: CGFloat, _ table: [(CGFloat, CGFloat)]) -> CGFloat {
        var below = table[0]
        guard opacity > below.0 else { return below.1 }
        for above in table.dropFirst() {
            if opacity <= above.0 { return below.1 + (above.1 - below.1) * (opacity - below.0) / (above.0 - below.0) }
            below = above
        }
        return below.1
    }

    /// How many times its size a pencil's line is broad, at these sizes across and these opacities down. A pencil
    /// narrower than about 1.6 draws a line only as broad as itself.
    private static let pencilSizes: [CGFloat] = [0.5, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 6, 8]
    private static let pencilRatios: [(opacity: CGFloat, ratios: [CGFloat])] = [
        (0.1, [0.964, 0.964, 0.966, 0.969, 1.001, 1.009, 1.032, 1.051, 1.076, 1.098, 1.1]),
        (0.2, [0.982, 0.952, 0.966, 1.006, 1.064, 1.082, 1.137, 1.159, 1.205, 1.245, 1.257]),
        (0.35, [0.982, 0.97, 0.986, 1.039, 1.167, 1.186, 1.28, 1.314, 1.386, 1.415, 1.427]),
        (0.5, [0.984, 0.996, 1.023, 1.083, 1.267, 1.301, 1.398, 1.444, 1.521, 1.557, 1.558]),
        (0.75, [1.016, 1.016, 1.08, 1.192, 1.409, 1.455, 1.554, 1.587, 1.635, 1.677, 1.673]),
        (1, [1.04, 1.054, 1.127, 1.262, 1.514, 1.545, 1.63, 1.67, 1.715, 1.745, 1.755]),
    ]

    /// The breadth a pencil of size `pencilSizes[index]` draws at an opacity.
    private static func pencilBreadth(at index: Int, _ o: CGFloat) -> CGFloat {
        var below = pencilRatios[0]
        guard o > below.opacity else { return pencilSizes[index] * below.ratios[index] }
        for above in pencilRatios.dropFirst() {
            if o <= above.opacity {
                let t = (o - below.opacity) / (above.opacity - below.opacity)
                return pencilSizes[index] * (below.ratios[index] + (above.ratios[index] - below.ratios[index]) * t)
            }
            below = above
        }
        return pencilSizes[index] * below.ratios[index]
    }

    private static func pencil(_ w: CGFloat, _ o: CGFloat) -> CGFloat {
        guard w > 0 else { return 0 }
        let last = pencilSizes.count - 1
        if w <= pencilSizes[0] { return w * pencilBreadth(at: 0, o) / pencilSizes[0] }
        if w >= pencilSizes[last] { return w * pencilBreadth(at: last, o) / pencilSizes[last] }
        var index = 0
        while pencilSizes[index + 1] < w { index += 1 }
        let a = pencilBreadth(at: index, o), b = pencilBreadth(at: index + 1, o)
        return a + (b - a) * (w - pencilSizes[index]) / (pencilSizes[index + 1] - pencilSizes[index])
    }

    /// The size of pencil that draws a line `breadth` broad at an opacity.
    private static func pencilSize(drawing breadth: CGFloat, _ o: CGFloat) -> CGFloat {
        guard breadth > 0 else { return 0 }
        var a = pencilBreadth(at: 0, o)
        if breadth <= a { return breadth * pencilSizes[0] / a }
        for index in 1..<pencilSizes.count {
            let b = pencilBreadth(at: index, o)
            if breadth <= b { return pencilSizes[index - 1] + (pencilSizes[index] - pencilSizes[index - 1]) * (breadth - a) / (b - a) }
            a = b
        }
        return breadth * pencilSizes[pencilSizes.count - 1] / a
    }
}

private extension PKStrokePoint {
    /// The same touch of the nib at another size. PencilKit keeps a point's height as a share of its width cut down
    /// to a thousandth, so a quarter of a thousandth more is asked for, or heights would shrink with every change.
    func sized(_ wanted: CGSize) -> PKStrokePoint {
        var size = wanted
        if size.width > 0, size.height > 0 { size.height = size.width * ((size.height / size.width * 1000).rounded() + 0.25) / 1000 }
        if #available(iOS 27.0, *) {
            return PKStrokePoint(location: location, timeOffset: timeOffset, size: size, opacity: opacity, force: force, azimuth: azimuth, altitude: altitude,
                                 secondaryScale: secondaryScale, threshold: threshold, lateralJitter: lateralJitter)
        }
        if #available(iOS 26.0, *) {
            return PKStrokePoint(location: location, timeOffset: timeOffset, size: size, opacity: opacity, force: force, azimuth: azimuth, altitude: altitude,
                                 secondaryScale: secondaryScale, threshold: threshold)
        }
        return PKStrokePoint(location: location, timeOffset: timeOffset, size: size, opacity: opacity, force: force, azimuth: azimuth, altitude: altitude,
                             secondaryScale: secondaryScale)
    }
}
