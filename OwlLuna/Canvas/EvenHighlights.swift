import UIKit
import PencilKit

/// Highlights that keep one strength where they cross. PencilKit's own get darker there, so with the setting on the
/// highlighter's strokes are drawn as flat shapes instead, each laid solid over the ones before it: multiplied into
/// light paper in the colour a stroke leaves on white, and laid over dark paper in its ink at the stroke's strength.
enum EvenHighlights {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: SettingsKey.evenHighlights) }

    /// One highlighter stroke as it is laid: what its tip sweeps, filled by winding, the solid colour it is filled with,
    /// and how much of that is laid over the page: all of it on light paper, the stroke's strength on dark.
    struct Mark {
        var outline: CGPath
        var color: CGColor
        var opacity: CGFloat = 1
    }

    /// Marks laid together: each solid over the ones before it, then all of them over the page at one opacity.
    struct Layer {
        /// Places among the marks given, in the order written.
        var marks: [Int]
        var opacity: CGFloat
    }

    /// Marks are multiplied into light paper, so print shows through them, and laid over dark paper.
    static func blend(onDark: Bool) -> CGBlendMode { onDark ? .normal : .multiply }

    /// The same blend for a view the marks are shown on.
    static func filter(onDark: Bool) -> String? { onDark ? nil : "multiplyBlendMode" }

    /// The layers the marks are laid in, lowest first. A mark joins the lowest layer of its opacity that lies over every
    /// mark it touches, so it covers them and crosses marks of its own strength unseen; with none, it starts a layer on top.
    /// On light paper that is one layer.
    static func layers(of marks: [Mark]) -> [Layer] {
        let boxes = marks.map(\.outline.boundingBoxOfPath)
        var layers: [Layer] = []
        for (index, mark) in marks.enumerated() {
            func fits(_ layer: Int) -> Bool { abs(layers[layer].opacity - mark.opacity) <= 0.02 }
            func touches(_ layer: Int) -> Bool {
                layers[layer].marks.contains { boxes[$0].intersects(boxes[index]) && marks[$0].outline.intersects(mark.outline) }
            }
            var place = layers.indices.first(where: fits)
            if let lowest = place {
                var fitting: Int?
                for layer in layers.indices.reversed() where layer > lowest {
                    if fits(layer) { fitting = layer }
                    if touches(layer) {
                        place = fitting
                        break
                    }
                }
            }
            if let place {
                layers[place].marks.append(index)
            } else {
                layers.append(Layer(marks: [index], opacity: mark.opacity))
            }
        }
        return layers
    }

    /// How thickly the chisel lays ink in a line dragged sideways at opacity 1, for points `breadth` wide: PencilKit's
    /// plateau at the tool's narrowest, default and broadest widths.
    private static func density(_ breadth: CGFloat) -> CGFloat { 1.0766 + 0.010961 * pow(max(breadth, 0), 1.36) }

    private static func breadth(of stroke: PKStroke) -> CGFloat { stroke.path.reduce(0) { max($0, $1.size.width) } }

    private static func strength(alpha: CGFloat, breadth: CGFloat) -> CGFloat { min(max(alpha, 0), 1) * (1 - exp(-density(breadth))) }

    /// How much of its colour a stroke lays: one figure for the whole line, from its ink and its breadth alone, so two
    /// lines from one pen match wherever they meet.
    static func strength(of stroke: PKStroke) -> CGFloat {
        var alpha: CGFloat = 1
        stroke.ink.color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        return strength(alpha: alpha, breadth: breadth(of: stroke))
    }

    /// The solid colour a stroke's mark is filled with: on a light page its ink let down towards white by its strength, on
    /// a dark one its ink, which is then laid at that strength. `appearance` is how PencilKit shows ink on the paper, dark
    /// on a dark page unless said otherwise.
    static func color(of stroke: PKStroke, onDark: Bool, appearance: UIUserInterfaceStyle? = nil) -> CGColor {
        color(of: stroke.ink.color, strength: strength(of: stroke), onDark: onDark, appearance: appearance)
    }

    private static func color(of ink: UIColor, strength: CGFloat, onDark: Bool, appearance: UIUserInterfaceStyle?) -> CGColor {
        var ink = ink
        if (appearance ?? (onDark ? .dark : .light)) == .dark { ink = PKInkingTool.convertColor(ink, from: .light, to: .dark) }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        ink.getRed(&red, green: &green, blue: &blue, alpha: nil)
        func laid(_ part: CGFloat) -> CGFloat {
            let part = min(max(part, 0), 1)
            return onDark ? part : 1 - strength * (1 - part)
        }
        return CGColor(srgbRed: laid(red), green: laid(green), blue: laid(blue), alpha: 1)
    }

    /// The highlighter's strokes among `strokes` as marks, in the order written. `toPage` places the ink on what is drawn on.
    /// On the main thread outlines are kept, so asking again after a stroke only works out the new ones.
    static func marks(of strokes: [PKStroke], toPage: CGAffineTransform = .identity, onDark: Bool, appearance: UIUserInterfaceStyle? = nil) -> [Mark] {
        let keeps = Thread.isMainThread
        return strokes.compactMap { stroke in
            guard stroke.ink.inkType == .marker else { return nil }
            let ink = stroke.ink.color
            var alpha: CGFloat = 1
            ink.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            guard alpha > 0 else { return nil }
            let made = { () -> Kept.Made in
                let breadth = breadth(of: stroke)
                return Kept.Made(outline: outline(of: stroke, at: InkVectors.placement(of: stroke, toPage: toPage, appearance: .light), breadth: breadth), breadth: breadth)
            }
            let found = keeps ? MainActor.assumeIsolated { Kept.made(for: Kept.key(stroke, toPage: toPage), made) } : made()
            let strength = strength(alpha: alpha, breadth: found.breadth)
            guard let outline = found.outline, strength > 0 else { return nil }
            return Mark(outline: outline, color: color(of: ink, strength: strength, onDark: onDark, appearance: appearance), opacity: onDark ? strength : 1)
        }
    }

    /// Outlines worked out on the main thread, in two generations: one filling, and the one before it, dropped when the
    /// first is full. A memory warning drops both.
    private enum Kept {
        /// A `CGPath` is never changed once made, so it is safe to hand between threads.
        struct Made: @unchecked Sendable {
            var outline: CGPath?
            var breadth: CGFloat
        }

        static let limit = 1500
        @MainActor static var filling: [[Double]: Made] = [:], before: [[Double]: Made] = [:]
        @MainActor static let relief = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                filling = [:]
                before = [:]
            }
        }

        @MainActor static func made(for key: [Double], _ make: () -> Made) -> Made {
            _ = relief
            if let hit = filling[key] { return hit }
            let found = before[key] ?? make()
            if filling.count >= limit {
                before = filling
                filling = [:]
            }
            filling[key] = found
            return found
        }

        /// What an outline depends on: the stroke's date and seed, its first, middle and last points, how it is placed and cut.
        static func key(_ stroke: PKStroke, toPage: CGAffineTransform) -> [Double] {
            let path = stroke.path, count = path.count, t = stroke.transform, p = toPage
            var key = [path.creationDate.timeIntervalSinceReferenceDate, Double(stroke.randomSeed), Double(count), t.a, t.b, t.c, t.d, t.tx, t.ty,
                       p.a, p.b, p.c, p.d, p.tx, p.ty]
            for index in count > 0 ? [0, count / 2, count - 1] : [] {
                let point = path[index]
                key += [point.location.x, point.location.y, point.size.width, point.size.height, point.opacity, point.azimuth]
            }
            if let mask = stroke.mask {
                var sum = 0.0, elements = 0.0
                mask.cgPath.applyWithBlock { element in
                    elements += 1
                    let points = element.pointee.points
                    switch element.pointee.type {
                    case .moveToPoint, .addLineToPoint: sum += (points[0].x * 3.1 + points[0].y * 7.3) * elements
                    case .addQuadCurveToPoint: sum += (points[1].x * 3.1 + points[1].y * 7.3 + points[0].x) * elements
                    case .addCurveToPoint: sum += (points[2].x * 3.1 + points[2].y * 7.3 + points[0].x + points[1].y) * elements
                    default: break
                    }
                }
                key += [elements, sum]
            }
            return key
        }
    }

    /// A point of a highlighter's path on what it is drawn on: where it is, how far its chisel reaches each way, its turn and opacity.
    private struct Tip {
        var location: CGPoint
        var along: CGFloat
        var across: CGFloat
        var azimuth: CGFloat
        var opacity: CGFloat
    }

    /// The chisel at each point a straight run can't skip, swept from one to the next. Its ends are drawn in to where
    /// PencilKit's picture is half as strong as the line: a line fades over its last point, a tap over one side.
    static func outline(of stroke: PKStroke, at placement: InkVectors.Placement, breadth: CGFloat? = nil) -> CGPath? {
        let placed = placement.placed, scale = placement.scale, turn = placement.turn, single = stroke.path.count == 1
        var points = Array(stroke.path.interpolatedPoints(by: .distance(3)))
        if points.isEmpty {
            points = Array(stroke.path)
        } else if stroke.path.count > 1 {
            let last = stroke.path.interpolatedPoint(at: CGFloat(stroke.path.count - 1)), end = points[points.count - 1].location
            if abs(last.location.x - end.x) > 0.01 || abs(last.location.y - end.y) > 0.01 { points.append(last) }
        }
        let tips = points.map { point in
            Tip(location: point.location.applying(placed), along: reach(point.size.height) * scale, across: 0.24 * point.size.width * scale,
                azimuth: point.azimuth + turn, opacity: min(max(point.opacity, 0), 2))
        }
        guard let first = tips.first?.location else { return nil }
        if !single, tips.allSatisfy({ abs($0.location.x - first.x) < 0.01 && abs($0.location.y - first.y) < 0.01 }) { return nil }
        let samples = tips.map { InkVectors.Sample(location: $0.location, radius: max($0.along, $0.across), azimuth: $0.azimuth) }
        let kept = single ? [0] : InkVectors.simplified(samples, 0, samples.count - 1, tolerance: 0.3)
        var shapes = kept.map { chisel(tips[$0], corner: 0.15 * points[$0].size.width * scale) }
        if single {
            let azimuth = tips[0].azimuth
            shapes[0] = drawnIn(shapes[0], centre: tips[0].location, toward: CGPoint(x: sin(azimuth), y: -cos(azimuth)), to: 0.53, worn: (scale, 1), behind: false)
        } else {
            let opacities = tips.map(\.opacity).sorted(), breadth = breadth ?? Self.breadth(of: stroke)
            let middle = max(opacities[opacities.count / 2], 0.01), plateau = 1 - exp(-density(breadth) * middle)
            for end in [false, true] {
                let index = end ? kept.count - 1 : 0
                let (way, reach, share) = ending(tips, shape: shapes[index], at: end)
                let ratio = share / middle
                let drawn = end ? lineEnd(ratio) + 0.335 * plateau : 0.9 + 0.335 * (plateau - 0.765) + 0.3 * (ratio - 1)
                if reach > 0 {
                    shapes[index] = drawnIn(shapes[index], centre: tips[kept[index]].location, toward: way, to: min(max(drawn, 0), 1),
                                            worn: (scale, end ? 1 : min(max((Self.reach(breadth) - 9) / 36, 0), 0.5)))
                }
            }
        }
        let path = CGMutablePath()
        if shapes.count == 1 {
            path.addLines(between: InkVectors.convexHull(shapes[0]))
            path.closeSubpath()
        }
        for (previous, next) in zip(shapes, shapes.dropFirst()) {
            let hull = InkVectors.convexHull(previous + next)
            guard hull.count > 2 else { continue }
            path.addLines(between: hull)
            path.closeSubpath()
        }
        var outline: CGPath = path
        if let mask = stroke.mask {
            var cut = placed
            guard let clip = mask.cgPath.copy(using: &cut) else { return nil }
            outline = outline.intersection(clip)
        }
        if !placement.even {
            var whole = placement.whole
            outline = outline.copy(using: &whole) ?? outline
        }
        return outline.isEmpty ? nil : outline
    }

    /// How far the chisel reaches along its azimuth for a point `height` tall: a little more than 1.3 of it, more on a broad tip.
    private static func reach(_ height: CGFloat) -> CGFloat { (0.6451 + 0.000986 * height) * height }

    /// The highlighter's chisel with rounded corners, 0.48 of a point's width across.
    private static func chisel(_ tip: Tip, corner: CGFloat) -> [CGPoint] {
        let a = tip.along, b = tip.across, r = min(corner, a, b), c = cos(tip.azimuth), s = sin(tip.azimuth), centre = tip.location
        let bend = r * (1 - 0.5.squareRoot())
        var shape: [CGPoint] = []
        shape.reserveCapacity(12)
        for (qx, qy) in [(1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)] as [(CGFloat, CGFloat)] {
            for (x, y) in r > 0 ? [(a, b - r), (a - bend, b - bend), (a - r, b)] : [(a, b)] {
                let x = qx * x, y = qy * y
                shape.append(CGPoint(x: centre.x + x * c - y * s, y: centre.y + x * s + y * c))
            }
        }
        return shape
    }

    /// Which way a line leaves at one end, how far its chisel reaches past the end that way, and the mean opacity the
    /// chisel lays over that reach.
    private static func ending(_ tips: [Tip], shape: [CGPoint], at end: Bool) -> (CGPoint, CGFloat, CGFloat) {
        let order = end ? Array(tips.indices.reversed()) : Array(tips.indices)
        let tip = tips[order[0]].location
        var way = CGPoint.zero
        for index in order.dropFirst() {
            let dx = tip.x - tips[index].location.x, dy = tip.y - tips[index].location.y, length = hypot(dx, dy)
            if length > 0.5 || index == order.last {
                way = length > 0 ? CGPoint(x: dx / length, y: dy / length) : .zero
                break
            }
        }
        let reach = shape.reduce(0) { max($0, ($1.x - tip.x) * way.x + ($1.y - tip.y) * way.y) }
        var laid: CGFloat = 0, travelled: CGFloat = 0
        for (from, to) in zip(order, order.dropFirst()) where travelled < reach {
            let a = tips[from], b = tips[to], length = hypot(b.location.x - a.location.x, b.location.y - a.location.y)
            guard length > 0 else { continue }
            let part = min(length, reach - travelled), t = part / length
            laid += part * (a.opacity + (a.opacity + (b.opacity - a.opacity) * t)) / 2
            travelled += part
        }
        return (way, reach, travelled > 0 ? laid / travelled : tips[order[0]].opacity)
    }

    /// How far past a line's last point PencilKit's picture stays half as strong as the line, as a share of the chisel's
    /// reach, for how opaque the end is against the middle, before the part the line's own strength adds.
    private static func lineEnd(_ ratio: CGFloat) -> CGFloat {
        let knots: [(CGFloat, CGFloat)] = [(0.66, 0.089), (0.76, 0.174), (0.917, 0.327), (1, 0.49)]
        if ratio <= knots[0].0 { return knots[0].1 - 0.85 * (knots[0].0 - ratio) }
        for (low, high) in zip(knots, knots.dropFirst()) where ratio <= high.0 {
            return low.1 + (high.1 - low.1) * (ratio - low.0) / (high.0 - low.0)
        }
        return knots[3].1 + 1.96 * (ratio - 1)
    }

    /// The part of a tip on the `toward` side of its centre pressed in to `share` of its reach that way, and its corners that
    /// way worn back as PencilKit's fading picture wears them, from 0.6 of its half breadth out, by `worn.amount` of what
    /// a line's end loses. `worn.scale` turns page points into the tip's units; `behind` lets corners go back past its centre.
    private static func drawnIn(_ shape: [CGPoint], centre: CGPoint, toward way: CGPoint, to share: CGFloat, worn: (scale: CGFloat, amount: CGFloat),
                                behind: Bool = true) -> [CGPoint] {
        let across = CGPoint(x: -way.y, y: way.x)
        let half = shape.reduce(0) { max($0, abs(($1.x - centre.x) * across.x + ($1.y - centre.y) * across.y)) }
        let points = worn.amount > 0 && half > 0 ? densified(InkVectors.convexHull(shape), step: half / 6) : shape
        return points.map { point in
            let dx = point.x - centre.x, dy = point.y - centre.y, side = dx * across.x + dy * across.y
            var out = dx * way.x + dy * way.y
            if out > 0 { out *= share }
            if worn.amount > 0, half > 0 {
                let wear = max(min(abs(side) / half, 1) - 0.6, 0) / 0.4, back = worn.amount * 1.15 * sqrt(half / worn.scale) * worn.scale * wear * wear
                out = behind ? out - back : max(out - back, min(out, 0))
            }
            return CGPoint(x: centre.x + way.x * out + across.x * side, y: centre.y + way.y * out + across.y * side)
        }
    }

    private static func densified(_ loop: [CGPoint], step: CGFloat) -> [CGPoint] {
        guard loop.count > 1, step > 0 else { return loop }
        return loop.indices.flatMap { index -> [CGPoint] in
            let a = loop[index], b = loop[(index + 1) % loop.count], pieces = max(Int((hypot(b.x - a.x, b.y - a.y) / step).rounded(.up)), 1)
            return (0..<pieces).map { piece in
                let t = CGFloat(piece) / CGFloat(pieces)
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        }
    }

    /// Lays the marks over what the context holds, each of their layers blended in whole at its opacity. Marks of one
    /// colour one after another are filled as one shape.
    static func draw(_ marks: [Mark], in ctx: CGContext, onDark: Bool) {
        guard !marks.isEmpty else { return }
        let bounds = marks.reduce(CGRect.null) { $0.union($1.outline.boundingBoxOfPath) }
        ctx.saveGState()
        ctx.clip(to: bounds.insetBy(dx: -1, dy: -1))
        ctx.setBlendMode(blend(onDark: onDark))
        for layer in layers(of: marks) {
            ctx.saveGState()
            ctx.setAlpha(layer.opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setBlendMode(.normal)
            ctx.setAlpha(1)
            var index = 0
            while index < layer.marks.count {
                let color = marks[layer.marks[index]].color
                ctx.setFillColor(color)
                while index < layer.marks.count, marks[layer.marks[index]].color == color {
                    ctx.addPath(marks[layer.marks[index]].outline)
                    index += 1
                }
                ctx.fillPath(using: .winding)
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}
