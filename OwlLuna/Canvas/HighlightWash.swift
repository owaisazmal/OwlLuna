import UIKit
import PencilKit

/// Ink that draws nothing, for highlighter strokes the wash shows in PencilKit's place: the stroke's own colour with
/// its alpha a 2²⁴th of what it was. PencilKit keeps a colour exactly, so the stroke's ink comes back bit for bit.
enum UnseenInk {
    private static let fold: CGFloat = 16_777_216

    /// Whether a stroke lies on a canvas in unseen ink. No tool writes ink this faint.
    static func isUnseen(_ stroke: PKStroke) -> Bool {
        guard stroke.ink.inkType == .marker else { return false }
        let alpha = stroke.ink.color.cgColor.alpha
        return alpha > 0 && alpha <= 1 / fold
    }

    /// A highlighter stroke as it is laid where the wash shows it. Nothing but its ink is changed, so a canvas that
    /// knows the stroke has to be emptied first to stop drawing it.
    static func hidden(_ stroke: PKStroke) -> PKStroke {
        guard stroke.ink.inkType == .marker else { return stroke }
        return inked(stroke, alpha: stroke.ink.color.cgColor.alpha / fold)
    }

    /// A drawing with every stroke in its own ink. One that holds no unseen ink is given back as it is.
    static func shown(_ drawing: PKDrawing) -> PKDrawing {
        let strokes = drawing.strokes
        return strokes.contains(where: isUnseen) ? PKDrawing(strokes: strokes.map(shown)) : drawing
    }

    /// The stroke with its own ink again, whatever became of it on the canvas.
    static func shown(_ stroke: PKStroke) -> PKStroke {
        isUnseen(stroke) ? inked(stroke, alpha: stroke.ink.color.cgColor.alpha * fold) : stroke
    }

    private static func inked(_ stroke: PKStroke, alpha: CGFloat) -> PKStroke {
        guard let color = stroke.ink.color.cgColor.copy(alpha: alpha) else { return stroke }
        var copy = stroke
        copy.ink = PKInk(stroke.ink.inkType, color: UIColor(cgColor: color))
        return copy
    }
}

/// Keeps the way each touch on a canvas has gone since it landed, without ever recognising. PencilKit's own recogniser
/// begins a little way into a rub, so what an eraser passed before that is found here.
final class TouchTrail: UIGestureRecognizer {
    private var ways: [ObjectIdentifier: (points: [CGPoint], taken: Int)] = [:]
    private var down: Set<ObjectIdentifier> = []

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    /// The points not yet taken of the touch that is now nearest `point`, in the view's coordinates.
    func take(near point: CGPoint) -> [CGPoint] {
        func gap(_ way: (points: [CGPoint], taken: Int)) -> CGFloat {
            way.points.last.map { hypot($0.x - point.x, $0.y - point.y) } ?? .greatestFiniteMagnitude
        }
        guard let key = ways.min(by: { gap($0.value) < gap($1.value) })?.key, let way = ways[key] else { return [] }
        ways[key]?.taken = way.points.count
        return Array(way.points[way.taken...])
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            down.insert(ObjectIdentifier(touch))
            ways[ObjectIdentifier(touch)] = ([touch.location(in: view)], 0)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            for part in event.coalescedTouches(for: touch) ?? [touch] { ways[ObjectIdentifier(touch)]?.points.append(part.location(in: view)) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            ways[ObjectIdentifier(touch)]?.points.append(touch.location(in: view))
            down.remove(ObjectIdentifier(touch))
        }
        if down.isEmpty { state = .failed }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { down.remove(ObjectIdentifier(touch)) }
        if down.isEmpty { state = .failed }
    }

    override func reset() {
        ways = [:]
        down = []
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// The highlighter's strokes as flat shapes, under its canvas, while highlights are kept even. A window onto the page
/// like the canvases: each mark near it is a layer of its own, cut to what is near if it is very large. The marks lie
/// in coats, each laid over the page at one opacity: one on light paper, and on dark paper one or more a strength.
final class HighlightWashView: UIView {
    /// What tells one stroke's mark from another's, so a stroke shown before is not worked out again: its date and seed,
    /// its ink, its first, middle and last points, where it lies and every point of what it is cut to. PencilKit's own
    /// name for a stroke is not used: before iOS 27 there is none.
    private struct Key: Hashable {
        var parts: [Double]

        init(_ stroke: PKStroke) {
            let path = stroke.path, count = path.count, t = stroke.transform, box = stroke.renderBounds
            parts = [path.creationDate.timeIntervalSinceReferenceDate, Double(stroke.randomSeed), Double(count), t.a, t.b, t.c, t.d, t.tx, t.ty,
                     box.minX, box.minY, box.width, box.height]
            parts += (stroke.ink.color.cgColor.components ?? []).map { Double($0) }
            for index in count > 0 ? [0, count / 2, count - 1] : [] {
                let point = path[index]
                parts += [point.location.x, point.location.y, point.size.width, point.size.height, point.opacity, point.azimuth]
            }
            guard let mask = stroke.mask else { return }
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
            parts += [elements, sum]
        }
    }

    private struct Laid {
        var key: Key
        var mark: EvenHighlights.Mark
        var box: CGRect
        var shape: CAShapeLayer?
        /// Which coat it lies in.
        var coat = 0
        /// Whether the eraser has been at it since PencilKit last said what is on the page.
        var isRubbed = false
        /// The part of the page a very large mark's layer was cut to.
        var cut = CGRect.null
    }

    private var laid: [Laid] = []
    private var made: [Key: EvenHighlights.Mark?] = [:]
    /// The strokes last asked to be shown, in order.
    private var shown: [Key] = []
    /// Counts what has been asked to be shown, so marks worked out for an earlier asking are not laid over a later one.
    private var asked = 0
    /// What is to be shown once the marks being worked out are known.
    private var awaited: (strokes: [PKStroke], done: (() -> Void)?)?

    /// Marks handed back from where they were worked out.
    private struct Made: @unchecked Sendable {
        let marks: [EvenHighlights.Mark?]
    }
    /// More new strokes than this are worked out off the main thread: a mark takes about a millisecond.
    private static let atOnce = 12
    private var spare: [CAShapeLayer] = []
    /// A layer for each coat, lowest first. Its marks are solid in it, and it is laid over the page at the coat's opacity.
    private var coats: [CALayer] = []
    private var scale: CGFloat = 1
    /// The part of the page whose marks have layers: the window and half as much again each way.
    private var kept = CGRect.null
    /// A layer longer than this, in points on screen, is cut to what is kept.
    private static let longest: CGFloat = 4096

    /// Marks are multiplied into light paper, all of them as one layer, and laid over dark paper at their strength.
    var onDark = false {
        didSet {
            guard onDark != oldValue else { return }
            layer.compositingFilter = EvenHighlights.filter(onDark: onDark)
            made = [:]
        }
    }

    /// The marks as they are shown, in the order written.
    var marks: [EvenHighlights.Mark] { laid.map(\.mark) }

    /// What a stroke that has been shown covers of the page.
    func outline(of stroke: PKStroke) -> CGPath? {
        (made[Key(stroke)] ?? nil)?.outline
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        layer.compositingFilter = EvenHighlights.filter(onDark: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the highlighter's strokes among `strokes`, in their order, as PencilKit has them now. A page's worth of
    /// strokes not shown before is worked out off the main thread: until that is done the marks already known are
    /// shown. `done` runs once every mark is.
    func show(_ strokes: [PKStroke], then done: (() -> Void)? = nil) {
        asked += 1
        awaited = nil
        let wanted = strokes.filter { $0.ink.inkType == .marker }, keys = wanted.map(Key.init)
        shown = keys
        var fresh: [Key: PKStroke] = [:]
        for (stroke, key) in zip(wanted, keys) where made[key] == nil { fresh[key] = stroke }
        guard fresh.count > Self.atOnce else {
            for (key, stroke) in fresh { made[key] = .some(EvenHighlights.marks(of: [stroke], onDark: onDark).first) }
            lay(keys, last: true)
            done?()
            return
        }
        lay(keys, last: false)
        awaited = (strokes, done)
        let asking = asked, dark = onDark, order = Array(fresh.keys), ink = PKDrawing(strokes: order.compactMap { fresh[$0] })
        Task.detached(priority: .userInitiated) { [weak self] in
            let made = Made(marks: ink.strokes.map { EvenHighlights.marks(of: [$0], onDark: dark).first })
            await self?.take(made, for: order, asking: asking, dark: dark)
        }
    }

    /// Shows one more stroke over those shown: the one the highlighter has just drawn. The rest are not looked at again.
    func add(_ stroke: PKStroke) {
        guard stroke.ink.inkType == .marker, awaited == nil else { return }
        let key = Key(stroke)
        if made[key] == nil { made[key] = .some(EvenHighlights.marks(of: [stroke], onDark: onDark).first) }
        shown.append(key)
        lay(shown, last: true)
    }

    /// Whether marks are still being worked out, so that one stroke can't simply be added to what is shown.
    var isWorking: Bool { awaited != nil }

    private func take(_ worked: Made, for order: [Key], asking: Int, dark: Bool) {
        if dark == onDark, worked.marks.count == order.count {
            for (key, mark) in zip(order, worked.marks) { made[key] = .some(mark) }
        }
        guard asking == asked, let awaited else { return }
        show(awaited.strokes, then: awaited.done)
    }

    /// Lays the marks known for `keys`, in order. The marks of strokes no longer shown are forgotten once all are known.
    private func lay(_ keys: [Key], last: Bool) {
        var shapes: [Key: CAShapeLayer] = [:]
        for mark in laid {
            guard let shape = mark.shape else { continue }
            if mark.isRubbed || shapes[mark.key] != nil { retire(shape) } else { shapes[mark.key] = shape }
        }
        var next: [Laid] = [], used: [Key: EvenHighlights.Mark?] = [:]
        for key in keys {
            guard let known = made[key] else { continue }
            used[key] = .some(known)
            guard let mark = known else { continue }
            next.append(Laid(key: key, mark: mark, box: mark.outline.boundingBoxOfPath, shape: shapes.removeValue(forKey: key)))
        }
        shapes.values.forEach(retire)
        if last { made = used }
        let layers = onDark ? EvenHighlights.layers(of: next.map(\.mark)) : [EvenHighlights.Layer(marks: Array(next.indices), opacity: 1)]
        for (coat, layer) in layers.enumerated() {
            for index in layer.marks { next[index].coat = coat }
        }
        laid = next
        CATransaction.withoutActions {
            while coats.count > max(layers.count, 1) { coats.removeLast().removeFromSuperlayer() }
            while coats.count < layers.count {
                let coat = CALayer()
                coat.masksToBounds = true
                coat.allowsGroupOpacity = true
                coat.zPosition = CGFloat(coats.count)
                layer.addSublayer(coat)
                coats.append(coat)
            }
            for (coat, layer) in zip(coats, layers) { coat.opacity = Float(layer.opacity) }
            fitCoats()
        }
        lay(again: false)
    }

    /// Each coat is the window itself, so what is laid at its opacity is no larger than what is seen.
    private func fitCoats() {
        for coat in coats where coat.bounds != bounds {
            coat.bounds = bounds
            coat.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    /// The same window onto the page as the canvases: `frame`, showing the page from `offset` at `scale`.
    func place(frame: CGRect, offset: CGPoint, scale: CGFloat) {
        if self.frame != frame { self.frame = frame }
        if bounds.origin != offset { bounds.origin = offset }
        CATransaction.withoutActions { fitCoats() }
        guard scale > 0 else { return }
        let window = CGRect(origin: offset, size: frame.size).scaled(by: 1 / scale)
        let rescaled = scale != self.scale
        guard rescaled || !kept.contains(window) else { return }
        self.scale = scale
        kept = window.insetBy(dx: -window.width / 2, dy: -window.height / 2)
        lay(again: rescaled)
    }

    /// Gives each mark near the window its layer and takes the layers of the rest. `again` draws every layer anew.
    private func lay(again: Bool) {
        CATransaction.withoutActions {
            for index in laid.indices {
                guard !kept.isNull, laid[index].box.intersects(kept) else {
                    if let shape = laid[index].shape { retire(shape) }
                    laid[index].shape = nil
                    continue
                }
                let long = max(laid[index].box.width, laid[index].box.height) * scale > Self.longest
                let cut = long ? kept : .null
                let shape = laid[index].shape ?? spare.popLast() ?? CAShapeLayer()
                if again || laid[index].shape == nil || laid[index].cut != cut { draw(laid[index].mark, cutTo: cut, on: shape) }
                shape.zPosition = CGFloat(index)
                if coats.indices.contains(laid[index].coat), shape.superlayer !== coats[laid[index].coat] { coats[laid[index].coat].addSublayer(shape) }
                laid[index].shape = shape
                laid[index].cut = cut
            }
        }
    }

    private func draw(_ mark: EvenHighlights.Mark, cutTo cut: CGRect, on shape: CAShapeLayer) {
        var toScreen = CGAffineTransform(scaleX: scale, y: scale)
        let outline = cut.isNull ? mark.outline : mark.outline.intersection(CGPath(rect: cut, transform: nil))
        shape.path = outline.copy(using: &toScreen)
        shape.fillColor = mark.color
    }

    private func retire(_ shape: CAShapeLayer) {
        CATransaction.withoutActions {
            shape.removeFromSuperlayer()
            shape.path = nil
        }
        if spare.count < 64 { spare.append(shape) }
    }

    /// The eraser going from one point of the page to the next. PencilKit says what an eraser took only when it
    /// lifts, so until then it is mirrored here: with a `width` what it sweeps is cut out of the marks, and without
    /// one the marks it touches go whole.
    func rub(from: CGPoint, to: CGPoint, width: CGFloat?) {
        let reach = max(width ?? 2 / max(scale, 0.01), 0.1)
        let swept: CGPath
        if from == to {
            swept = CGPath(ellipseIn: CGRect(x: to.x - reach / 2, y: to.y - reach / 2, width: reach, height: reach), transform: nil)
        } else {
            let line = CGMutablePath()
            line.move(to: from)
            line.addLine(to: to)
            swept = line.copy(strokingWithWidth: reach, lineCap: .round, lineJoin: .round, miterLimit: 1)
        }
        let box = swept.boundingBoxOfPath
        CATransaction.withoutActions {
            for index in laid.indices where laid[index].box.intersects(box) {
                if width == nil {
                    guard laid[index].mark.outline.intersects(swept) else { continue }
                    laid[index].mark.outline = CGMutablePath()
                } else {
                    laid[index].mark.outline = laid[index].mark.outline.subtracting(swept)
                }
                laid[index].box = laid[index].mark.outline.boundingBoxOfPath
                laid[index].isRubbed = true
                guard let shape = laid[index].shape else { continue }
                if laid[index].mark.outline.isEmpty {
                    retire(shape)
                    laid[index].shape = nil
                } else {
                    draw(laid[index].mark, cutTo: laid[index].cut, on: shape)
                }
            }
        }
    }
}
