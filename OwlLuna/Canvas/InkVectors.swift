import UIKit
import PencilKit

/// Ink as shapes, so a PDF of it is small and sharp at any zoom: the pen, fineliner and fountain pen as the outline their nib
/// sweeps. Other inks go in as pictures in their place among the strokes, the highlighter multiplied in as the screen shows it,
/// or with even highlights as flat shapes under all the other ink.
enum InkVectors {
    struct Style: Sendable {
        /// Dark converts the colours as PencilKit does on dark paper.
        var appearance: UIUserInterfaceStyle = .light
        var multipliesHighlighter = true
        /// How finely the inks drawn as pictures are drawn, in pixels a point.
        var pictureScale: CGFloat = 3
        var evenHighlights = EvenHighlights.isOn

        /// Highlights are lightened into paper the highlighter isn't multiplied into.
        var highlightsOnDark: Bool { !multipliesHighlighter }
    }

    enum Nib { case round, oval }

    /// How far a simplified outline may stray from the nib's path, in points of the page.
    static let tolerance: CGFloat = 0.03

    /// `rect` of a drawing laid over a page of `size`.
    static func toPage(from rect: CGRect, size: CGSize) -> CGAffineTransform {
        let factor = size.width / max(rect.width, 1)
        return CGAffineTransform(translationX: -rect.minX, y: -rect.minY).concatenating(CGAffineTransform(scaleX: factor, y: factor))
    }

    /// Draws `rect` of the drawing to fill `size` of the context, stroke by stroke in the order they were written.
    static func draw(_ drawing: PKDrawing, from rect: CGRect, in ctx: CGContext, size: CGSize, style: Style = Style()) {
        let factor = size.width / max(rect.width, 1)
        let toPage = Self.toPage(from: rect, size: size)
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: size))
        var run: [PKStroke] = [], multiplies = false
        let even = style.evenHighlights
        if even {
            let shown = drawing.strokes.filter { $0.ink.inkType == .marker && $0.renderBounds.intersects(rect) }
            EvenHighlights.draw(EvenHighlights.marks(of: shown, toPage: toPage, onDark: style.highlightsOnDark, appearance: style.appearance), in: ctx,
                                onDark: style.highlightsOnDark)
        }
        func flush() {
            guard !run.isEmpty else { return }
            picture(of: run, within: rect, toPage: toPage, in: ctx, scale: style.pictureScale * factor, appearance: style.appearance, multiplies: multiplies)
            run.removeAll()
        }
        for stroke in drawing.strokes where stroke.renderBounds.intersects(rect) && !(even && stroke.ink.inkType == .marker) {
            if let nib = nib(for: stroke) {
                flush()
                fill(stroke, nib: nib, toPage: toPage, in: ctx, appearance: style.appearance)
            } else {
                let multiplying = style.multipliesHighlighter && stroke.ink.inkType == .marker
                if multiplying != multiplies { flush() }
                multiplies = multiplying
                run.append(stroke)
            }
        }
        flush()
        ctx.restoreGState()
    }

    /// The nib a stroke can be drawn with as a shape, or nil where PencilKit's own picture of it is needed: inks with a grain
    /// or a soft edge, and points whose size or opacity it treats some other way.
    static func nib(for stroke: PKStroke) -> Nib? {
        let nib: Nib
        switch stroke.ink.inkType {
        case .pen, .monoline: nib = .round
        case .fountainPen: nib = .oval
        default: return nil
        }
        for point in stroke.path where abs(point.size.width - point.size.height) > 0.01 || point.opacity < 0.999 { return nil }
        return nib
    }

    /// PencilKit draws a nib two points narrower all round than the size its points are given.
    static func radius(_ point: PKStrokePoint) -> CGFloat { max(point.size.width - 2, 0) }

    /// A point of the nib's path on the page: where it is, how far the nib reaches, and which way it is turned.
    struct Sample {
        var location: CGPoint
        var radius: CGFloat
        var azimuth: CGFloat
    }

    /// A stroke's colour and place: moved or turned goes into its coordinates, stretched unevenly it is drawn through `whole`.
    struct Placement {
        var color: UIColor
        var alpha: CGFloat
        var whole: CGAffineTransform
        var even: Bool
        var scale: CGFloat
        var turn: CGFloat

        var placed: CGAffineTransform { even ? whole : .identity }
        /// The tolerance in the units the stroke's coordinates are in.
        var tolerance: CGFloat { InkVectors.tolerance / scale }
    }

    static func placement(of stroke: PKStroke, toPage: CGAffineTransform, appearance: UIUserInterfaceStyle) -> Placement {
        var color = stroke.ink.color
        if appearance == .dark { color = PKInkingTool.convertColor(color, from: .light, to: .dark) }
        var alpha: CGFloat = 1
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        let whole = stroke.transform.concatenating(toPage)
        let determinant = whole.a * whole.d - whole.b * whole.c
        let even = determinant > 0 && abs(whole.a - whole.d) < 1e-4 && abs(whole.b + whole.c) < 1e-4
        return Placement(color: color, alpha: alpha, whole: whole, even: even, scale: even ? sqrt(determinant) : 1, turn: even ? atan2(whole.b, whole.a) : 0)
    }

    /// The stroke's path half a point at a time, or the points it was given where it has no length.
    static func points(of stroke: PKStroke) -> [PKStrokePoint] {
        let interpolated = Array(stroke.path.interpolatedPoints(by: .distance(0.5)))
        return interpolated.isEmpty ? Array(stroke.path) : interpolated
    }

    static func samples(of stroke: PKStroke, at placement: Placement) -> [Sample] {
        let placed = placement.placed
        return points(of: stroke).map { point in
            Sample(location: rounded(point.location.applying(placed)), radius: radius(point) * placement.scale, azimuth: point.azimuth + placement.turn)
        }
    }

    /// What a nib leaves on the page: a dot, a line of one width with round ends and joins, or an outline to fill.
    enum Piece {
        case dot(CGPoint, radius: CGFloat)
        case line([CGPoint], width: CGFloat)
        case outline([CGPoint], closed: Bool)
    }

    private static func fill(_ stroke: PKStroke, nib: Nib, toPage: CGAffineTransform, in ctx: CGContext, appearance: UIUserInterfaceStyle) {
        let placement = Self.placement(of: stroke, toPage: toPage, appearance: appearance)
        let samples = Self.samples(of: stroke, at: placement)
        guard !samples.isEmpty else { return }
        var color = placement.color
        let alpha = placement.alpha
        let isolated = !placement.even || stroke.mask != nil || alpha < 1
        if isolated { ctx.saveGState() }
        if !placement.even { ctx.concatenate(placement.whole) }
        if let mask = stroke.mask {
            var maskTransform = placement.placed
            if let path = mask.cgPath.copy(using: &maskTransform) { ctx.addPath(path) }
            ctx.clip()
        }
        if alpha < 1 {
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            color = color.withAlphaComponent(1)
        }
        switch nib {
        case .round: drawLines(round(samples, tolerance: placement.tolerance, dot: stroke.path.count == 1), color: color.cgColor, in: ctx)
        case .oval: drawOutlines(oval(samples, tolerance: placement.tolerance), color: color.cgColor, in: ctx)
        }
        if alpha < 1 { ctx.endTransparencyLayer() }
        if isolated { ctx.restoreGState() }
    }

    static func rounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x * 100).rounded() / 100, y: (point.y * 100).rounded() / 100)
    }

    /// Runs of segments as wide as one another are one line with round ends and joins. PencilKit draws a single point as a dot,
    /// and several in one place as nothing.
    static func round(_ samples: [Sample], tolerance: CGFloat, dot: Bool, step: CGFloat = 0.03) -> [Piece] {
        guard let start = samples.first?.location else { return [] }
        if samples.allSatisfy({ abs($0.location.x - start.x) < 0.01 && abs($0.location.y - start.y) < 0.01 }) {
            let r = samples.map(\.radius).max() ?? 0
            return dot && r > 0 ? [.dot(start, radius: r)] : []
        }
        var pieces: [Piece] = [], first = 0
        while first < samples.count - 1 {
            let width = samples[first].radius + samples[first + 1].radius
            var last = first + 1
            while last + 1 < samples.count, abs(samples[last].radius + samples[last + 1].radius - width) <= max(step, width * step) { last += 1 }
            if width > 0 { pieces.append(.line(simplified(samples, first, last, tolerance: tolerance).map { samples[$0].location }, width: width)) }
            first = last
        }
        return pieces
    }

    private static func drawLines(_ pieces: [Piece], color: CGColor, in ctx: CGContext) {
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for piece in pieces {
            switch piece {
            case .dot(let centre, let r): ctx.fillEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
            case .line(let points, let width):
                ctx.setLineWidth(width)
                ctx.addLines(between: points)
                ctx.strokePath()
            case .outline: break
            }
        }
    }

    /// The fountain pen's oval at each sample a straight run can't skip, swept from one to the next.
    static func oval(_ samples: [Sample], tolerance: CGFloat) -> [Piece] {
        guard !samples.isEmpty else { return [] }
        return swept(simplified(samples, 0, samples.count - 1, tolerance: tolerance).map { ellipse(samples[$0], tolerance: tolerance) })
    }

    /// Each step of the nib is the hull of its shape where it starts and where it ends; together they make the stroke.
    static func swept(_ nibs: [[CGPoint]]) -> [Piece] {
        guard var previous = nibs.first else { return [] }
        var pieces: [Piece] = []
        if nibs.count == 1, previous.count > 2 { pieces.append(.outline(convexHull(previous), closed: false)) }
        for next in nibs.dropFirst() {
            let hull = convexHull(previous + next)
            if hull.count > 2 { pieces.append(.outline(hull, closed: true)) }
            previous = next
        }
        return pieces
    }

    private static func drawOutlines(_ pieces: [Piece], color: CGColor, in ctx: CGContext) {
        let path = CGMutablePath()
        for case .outline(let points, let closed) in pieces {
            path.addLines(between: points)
            if closed { path.closeSubpath() }
        }
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath(using: .winding)
    }

    /// The samples a straight run of the nib can skip: where the path, the nib's reach and its turn all change evenly.
    static func simplified(_ samples: [Sample], _ first: Int, _ last: Int, tolerance: CGFloat) -> [Int] {
        guard last - first > 1 else { return first == last ? [first] : [first, last] }
        var keep = [first, last], stack = [(first, last)]
        while let (a, b) = stack.popLast() {
            guard b - a > 1 else { continue }
            let p = samples[a], q = samples[b]
            let dx = q.location.x - p.location.x, dy = q.location.y - p.location.y, length2 = dx * dx + dy * dy
            var worst: CGFloat = 0, at = -1
            for index in (a + 1)..<b {
                let s = samples[index]
                let t = length2 > 0 ? min(max(((s.location.x - p.location.x) * dx + (s.location.y - p.location.y) * dy) / length2, 0), 1) : 0
                let x = p.location.x + dx * t, y = p.location.y + dy * t
                let off = hypot(s.location.x - x, s.location.y - y)
                let reach = abs(s.radius - (p.radius + (q.radius - p.radius) * t))
                let turn = abs(s.azimuth - (p.azimuth + (q.azimuth - p.azimuth) * t)) * s.radius
                let error = max(off, reach, turn)
                if error > worst { (worst, at) = (error, index) }
            }
            if worst > tolerance, at >= 0 {
                keep.append(at)
                stack.append((a, at))
                stack.append((at, b))
            }
        }
        return keep.sorted()
    }

    /// The fountain pen's nib: a quarter as thick as it is long, turned to the Pencil's azimuth.
    private static func ellipse(_ sample: Sample, tolerance: CGFloat) -> [CGPoint] {
        ellipse(at: sample.location, along: sample.radius, across: sample.radius / 4, azimuth: sample.azimuth, tolerance: tolerance)
    }

    /// An oval tip as a polygon, reaching `a` from its centre along its azimuth and `b` across it, cut off `cut` along it.
    static func ellipse(at centre: CGPoint, along a: CGFloat, across b: CGFloat, azimuth: CGFloat, tolerance: CGFloat, cut: CGFloat = .infinity) -> [CGPoint] {
        let reach = max(a, b)
        guard reach > 0 else { return [centre] }
        let sides = Int(min(max((CGFloat.pi / acos(max(1 - tolerance / reach, -1))).rounded(.up), 8), 64))
        let c = cos(azimuth), s = sin(azimuth)
        return (0..<sides).map { index in
            let t = CGFloat(index) / CGFloat(sides) * 2 * .pi
            let x = min(max(a * cos(t), -cut), cut), y = b * sin(t)
            return rounded(CGPoint(x: centre.x + x * c - y * s, y: centre.y + x * s + y * c))
        }
    }

    /// Counter-clockwise, so every hull winds the same way and their union fills.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    private static func picture(of strokes: [PKStroke], within rect: CGRect, toPage: CGAffineTransform, in ctx: CGContext, scale: CGFloat,
                                appearance: UIUserInterfaceStyle, multiplies: Bool) {
        let bounds = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }.insetBy(dx: -2, dy: -2).integral.intersection(rect)
        guard !bounds.isNull, !bounds.isEmpty else { return }
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: appearance).performAsCurrent {
            image = PKDrawing(strokes: strokes).image(from: bounds, scale: Whiteboard.scale(for: bounds.size, wanted: scale))
        }
        guard let image else { return }
        UIGraphicsPushContext(ctx)
        image.draw(in: bounds.applying(toPage), blendMode: multiplies ? .multiply : .normal, alpha: 1)
        UIGraphicsPopContext()
    }
}
