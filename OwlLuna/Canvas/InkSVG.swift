import UIKit
import PencilKit

/// Ink as SVG shapes, one for each stroke in the order written, so another app can take the lines apart.
enum InkSVG {
    /// `rect` of the drawing placed to fill `size`, as one `<g id="ink">`. Every id inside it begins with "ink".
    static func group(_ drawing: PKDrawing, from rect: CGRect, size: CGSize, style: InkVectors.Style = InkVectors.Style()) -> String {
        let toPage = InkVectors.toPage(from: rect, size: size)
        var out = "<g id=\"ink\">", count = 0
        for stroke in drawing.strokes where stroke.renderBounds.intersects(rect) {
            count += 1
            out += "\n"
            out += element(for: stroke, number: count, toPage: toPage, style: style)
        }
        return count == 0 ? "<g id=\"ink\"/>" : out + "\n</g>"
    }

    /// One stroke as a `<path>`, or as a `<g>` where it takes lines of several widths or is clipped.
    private static func element(for stroke: PKStroke, number: Int, toPage: CGAffineTransform, style: InkVectors.Style) -> String {
        let placement = InkVectors.placement(of: stroke, toPage: toPage, appearance: style.appearance)
        let ink = stroke.ink.inkType
        var pieces: [InkVectors.Piece], opacity = placement.alpha
        if let nib = InkVectors.nib(for: stroke) {
            let samples = InkVectors.samples(of: stroke, at: placement)
            switch nib {
            case .round: pieces = InkVectors.round(samples, tolerance: placement.tolerance, dot: stroke.path.count == 1)
            case .oval: pieces = InkVectors.oval(samples, tolerance: placement.tolerance)
            }
        } else {
            let told = likeness(of: stroke, at: placement)
            pieces = told.pieces
            opacity *= told.opacity
        }
        let identity = "id=\"ink-\(number)\" data-ink=\"\(name(of: ink))\""
        var lines: [(d: String, width: CGFloat)] = [], dots = "", hulls: [[CGPoint]] = []
        for piece in pieces {
            switch piece {
            case .dot(let centre, let radius):
                dots += SVGText.path(CGPath(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius), transform: nil))
            case .line(let points, let width): lines.append((SVGText.path(points), width))
            case .outline(let points, _): hulls.append(points)
            }
        }
        let outline = dots + merged(hulls)
        guard !outline.isEmpty || !lines.isEmpty else { return "<g \(identity)/>" }
        var look = identity, clip = ""
        if !placement.even {
            let m = placement.whole
            look += " transform=\"matrix(\(term(m.a)) \(term(m.b)) \(term(m.c)) \(term(m.d)) \(SVGText.number(m.tx)) \(SVGText.number(m.ty)))\""
        }
        if let mask = stroke.mask {
            var placed = placement.placed
            clip = "<defs><clipPath id=\"ink-clip-\(number)\"><path d=\"\(mask.cgPath.copy(using: &placed).map(SVGText.path) ?? "")\"/></clipPath></defs>"
            look += " clip-path=\"url(#ink-clip-\(number))\""
        }
        let shown = SVGText.number(opacity)
        if shown != "1" { look += " opacity=\"\(shown)\"" }
        // A reader without blend modes skips the style and is left with the opacity.
        if ink == .marker, style.multipliesHighlighter { look += " style=\"mix-blend-mode:multiply\"" }
        let hex = SVGText.color(placement.color).hex
        if !outline.isEmpty {
            look += " fill=\"\(hex)\" fill-rule=\"nonzero\""
            return clip.isEmpty ? "<path \(look) d=\"\(outline)\"/>" : "<g \(look)>\(clip)<path d=\"\(outline)\"/></g>"
        }
        look += " fill=\"none\" stroke=\"\(hex)\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
        if lines.count == 1, clip.isEmpty { return "<path \(look) stroke-width=\"\(SVGText.number(lines[0].width))\" d=\"\(lines[0].d)\"/>" }
        return "<g \(look)>\(clip)" + lines.map { "<path stroke-width=\"\(SVGText.number($0.width))\" d=\"\($0.d)\"/>" }.joined() + "</g>"
    }

    /// The hulls a tip sweeps as one outline with no overlaps: a fraction of their points, and what a node tool expects to find.
    private static func merged(_ hulls: [[CGPoint]]) -> String {
        guard hulls.count > 1 else { return hulls.first.map { SVGText.path($0, closed: true) } ?? "" }
        let path = CGMutablePath()
        for hull in hulls {
            path.addLines(between: hull)
            path.closeSubpath()
        }
        let whole = path.normalized(using: .winding), before = path.boundingBoxOfPath, after = whole.boundingBoxOfPath
        let same = !whole.isEmpty && abs(before.minX - after.minX) < 0.1 && abs(before.minY - after.minY) < 0.1
            && abs(before.maxX - after.maxX) < 0.1 && abs(before.maxY - after.maxY) < 0.1
        return same ? SVGText.path(whole) : hulls.map { SVGText.path($0, closed: true) }.joined()
    }

    /// An oval, or a chisel with corners of a radius, and how opaque it lays its colour: in a line, at the line's ends and in a tap.
    private struct Tip {
        var along: CGFloat
        var across: CGFloat
        var azimuth: CGFloat = 0
        var cut = CGFloat.infinity
        var corner: CGFloat?
        var opacity: CGFloat = 1
        var ends: CGFloat = 0.4
        var tap: CGFloat = 1

        var isRound: Bool { corner == nil && abs(along - across) < 0.01 && cut >= along }
        var area: CGFloat { (corner == nil ? .pi : 4) * along * across }
    }

    /// The tip that tells an ink, fitted to PencilKit's own pictures of straight strokes at the sizes each ink records.
    private static func tip(for point: PKStrokePoint, ink: PKInk.InkType) -> Tip {
        let w = point.size.width, h = point.size.height, o = min(max(point.opacity, 0), 1)
        switch ink {
        case .pen, .monoline:
            // Drawn opaque whatever its points say and upright however the Pencil is turned; a point less tall than wide is cut off at its sides.
            let reach = InkVectors.radius(point)
            return Tip(along: reach, across: reach, cut: max(h - 1, 0), ends: 1)
        case .fountainPen:
            let reach = InkVectors.radius(point)
            return Tip(along: reach, across: reach / 4, azimuth: point.azimuth, cut: max(h - 1, 0), ends: 1)
        case .pencil:
            let reach = max((1.75 + 0.31 * log(max(o, 0.05))) * w - 0.4, 0.5) / 2
            return Tip(along: reach, across: reach, cut: h, opacity: min(1 - exp(-1.3 * o * w * w), 0.97), tap: 0.37 * o)
        case .marker:
            return Tip(along: 0.665 * h, across: 0.24 * w, azimuth: point.azimuth, corner: 0.15 * w, opacity: 1 - exp(-(1.09 + 0.0016 * w * w) * o), tap: 0.32 * o)
        case .crayon:
            let spread = 0.725 + 0.15 * o
            return Tip(along: spread * h, across: spread * w, azimuth: point.azimuth, opacity: 0.74 * (1 - pow(1 - o, 2.2)), tap: 0.045)
        case .watercolor:
            let reach = (0.725 + 0.1 * o) * w
            return Tip(along: reach, across: reach, opacity: min(1 - pow(1 - o, 3.6), 0.96), tap: o)
        default:
            if isCalligraphy(ink) { return Tip(along: h, across: 0.115 * w, azimuth: point.azimuth, corner: 0, opacity: 1 - exp(-1.9 * o), tap: 0.33 * o) }
            return Tip(along: h / 2, across: w / 2, azimuth: point.azimuth, opacity: o, tap: 0.4 * o)
        }
    }

    /// A stroke PencilKit draws as a picture, as the shape its tip sweeps and one opacity for the whole of it.
    private static func likeness(of stroke: PKStroke, at placement: InkVectors.Placement) -> (pieces: [InkVectors.Piece], opacity: CGFloat) {
        let ink = stroke.ink.inkType, points = InkVectors.points(of: stroke), placed = placement.placed, scale = placement.scale
        guard !points.isEmpty else { return ([], 1) }
        let tips = points.map { tip(for: $0, ink: ink) }, single = stroke.path.count == 1
        let samples = zip(points, tips).map { point, shape in
            InkVectors.Sample(location: InkVectors.rounded(point.location.applying(placed)), radius: max(shape.along, shape.across) * scale,
                              azimuth: shape.azimuth + placement.turn)
        }
        var laid: CGFloat = 0, body: CGFloat = 0, stamp: CGFloat = 0, tapped: CGFloat = 0, ends: CGFloat = 0
        for (index, shape) in tips.enumerated() {
            var ratio: CGFloat = 1, breadth = shape.along + shape.across
            let a = points[max(index - 1, 0)].location, b = points[min(index + 1, points.count - 1)].location
            let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
            if shape.corner != nil, shape.across > 0, length > 0 {
                // A chisel lays more ink the longer it drags over a place, and covers less of the page the more it travels along itself.
                let c = cos(shape.azimuth), s = sin(shape.azimuth)
                let lengthwise = abs(dx * c + dy * s) / length, sideways = abs(dy * c - dx * s) / length
                ratio = min(shape.along / max(lengthwise, 1e-6), shape.across / max(sideways, 1e-6)) / shape.across
                breadth = 2 * (shape.along * sideways + shape.across * lengthwise)
            }
            let swept = breadth * length / 2
            laid += (1 - pow(1 - min(shape.opacity, 0.999), ratio)) * swept
            body += swept
            stamp += shape.area
            tapped += shape.tap
            ends += shape.ends
        }
        let count = CGFloat(tips.count)
        // PencilKit draws one point as a tap of the tip and several in one place as nothing; a line's ends are laid thinner than its middle.
        guard body > 0 || single else { return ([], 1) }
        let opacity = body > 0 ? laid / body * (body + ends / count * stamp / count) / (body + stamp / count) : tapped / count
        // Inks with a soft edge don't need the nib's hundredths, and fewer points make a cleaner path.
        let crisp = ink == .pen || ink == .monoline || ink == .fountainPen, tolerance = placement.tolerance * (crisp ? 1 : 4)
        if tips.allSatisfy(\.isRound) { return (InkVectors.round(samples, tolerance: tolerance, dot: single, step: crisp ? 0.03 : 0.1), opacity) }
        let kept = InkVectors.simplified(samples, 0, samples.count - 1, tolerance: tolerance)
        let shapes = kept.map { index -> [CGPoint] in
            let shape = tips[index], centre = samples[index].location, azimuth = samples[index].azimuth
            let a = shape.along * scale, b = shape.across * scale
            guard let corner = shape.corner else {
                return InkVectors.ellipse(at: centre, along: a, across: b, azimuth: azimuth, tolerance: tolerance, cut: shape.cut * scale)
            }
            let c = cos(azimuth), s = sin(azimuth), r = min(corner * scale, a, b)
            let turns: [CGFloat] = r > 0 ? [0, .pi / 4, .pi / 2] : [0], quarters: [(x: CGFloat, y: CGFloat)] = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
            return quarters.flatMap { quarter in
                turns.map { turn in
                    let x = quarter.x * (a - r + r * cos(turn)), y = quarter.y * (b - r + r * sin(turn))
                    return InkVectors.rounded(CGPoint(x: centre.x + x * c - y * s, y: centre.y + x * s + y * c))
                }
            }
        }
        return (InkVectors.swept(shapes), opacity)
    }

    private static func isCalligraphy(_ ink: PKInk.InkType) -> Bool {
        if #available(iOS 26.0, *) { return ink == .reed }
        return false
    }

    private static func name(of ink: PKInk.InkType) -> String {
        switch ink {
        case .pen: "pen"
        case .monoline: "fineliner"
        case .fountainPen: "fountain pen"
        case .pencil: "pencil"
        case .marker: "highlighter"
        case .crayon: "crayon"
        case .watercolor: "watercolour"
        default: isCalligraphy(ink) ? "calligraphy pen" : "ink"
        }
    }

    /// A term of a matrix, to six places: at two the far end of a long stretched stroke would move.
    private static func term(_ value: CGFloat) -> String {
        let millionths = (Double(value) * 1_000_000).rounded()
        guard millionths.isFinite, abs(millionths) < 1e17 else { return "0" }
        let whole = Int64(millionths)
        var places = String(abs(whole) % 1_000_000)
        places = String(repeating: "0", count: 6 - places.count) + places
        while places.hasSuffix("0") { places.removeLast() }
        return (whole < 0 ? "-" : "") + String(abs(whole) / 1_000_000) + (places.isEmpty ? "" : "." + places)
    }
}
