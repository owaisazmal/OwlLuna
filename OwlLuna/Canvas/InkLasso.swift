import UIKit
import PencilKit

/// Ink picked out across pages: for each page, the places of the chosen strokes in that page's drawing.
typealias InkSelection = [UUID: [Int]]

/// Selecting and moving ink across pages. PencilKit's own lasso stops at the edge of its canvas, and each page has
/// its own canvas, so this works on the pages' drawings instead. Everything here is in "stack points": page points,
/// offset by where the page sits in the page stack.
enum InkLasso {
    /// Even-odd test for a point inside a closed outline.
    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y),
               point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    /// What a drawn path encloses. A loop encloses itself; a straight drag is taken as the diagonal of a box.
    static func outline(from path: [CGPoint]) -> [CGPoint] {
        guard let first = path.first, let last = path.last, path.count >= 2 else { return [] }
        let span = ShapeRecognizer.distance(first, last)
        let wander = path.map { ShapeRecognizer.distance($0, toSegment: first, last) }.max() ?? 0
        guard span > 12, wander <= max(0.06 * span, 4) else { return path }
        return [first, CGPoint(x: last.x, y: first.y), last, CGPoint(x: first.x, y: last.y)]
    }

    /// The strokes with most of themselves inside the outline. `polygon` is in the page's own points.
    static func strokes(in drawing: PKDrawing, inside polygon: [CGPoint]) -> [Int] {
        guard polygon.count >= 3 else { return [] }
        let box = ShapeRecognizer.bounds(of: polygon)
        return drawing.strokes.enumerated().compactMap { index, stroke in
            guard stroke.renderBounds.intersects(box) else { return nil }
            var total = 0, inside = 0
            for sample in stroke.path.interpolatedPoints(by: .distance(8)) {
                total += 1
                if contains(polygon, sample.location.applying(stroke.transform)) { inside += 1 }
            }
            return total > 0 && Double(inside) >= 0.6 * Double(total) ? index : nil
        }
    }

    /// The rectangle round the selection, in stack points.
    static func bounds(of selection: InkSelection, drawings: [UUID: PKDrawing], frames: [UUID: CGRect]) -> CGRect? {
        var result: CGRect?
        for (page, indices) in selection {
            guard let drawing = drawings[page], let frame = frames[page] else { continue }
            for index in indices where drawing.strokes.indices.contains(index) {
                let box = drawing.strokes[index].renderBounds.offsetBy(dx: frame.minX, dy: frame.minY)
                result = result?.union(box) ?? box
            }
        }
        return result
    }

    /// The page a point in the stack belongs to: the one it is on, or else the nearest.
    static func page(at point: CGPoint, frames: [UUID: CGRect]) -> UUID? {
        if let hit = frames.first(where: { $0.value.contains(point) }) { return hit.key }
        func distance(_ frame: CGRect) -> CGFloat {
            hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
        }
        return frames.min { distance($0.value) < distance($1.value) }?.key
    }

    /// Moves, or copies, the selected strokes by `delta`. A stroke whose middle lands on another page becomes that
    /// page's ink; on a page whose drawing isn't given it stays where it came from. Returns the drawings that changed
    /// and where the strokes are now.
    static func moved(_ selection: InkSelection, by delta: CGSize, copying: Bool = false,
                      drawings: [UUID: PKDrawing], frames: [UUID: CGRect]) -> (drawings: [UUID: PKDrawing], selection: InkSelection) {
        var strokes: [UUID: [PKStroke]] = [:]
        var arrivals: [UUID: [PKStroke]] = [:]
        var result: InkSelection = [:]
        for (page, indices) in selection {
            guard let drawing = drawings[page], let frame = frames[page] else { continue }
            let chosen = Set(indices)
            var kept: [PKStroke] = []
            for (index, stroke) in drawing.strokes.enumerated() {
                guard chosen.contains(index) else { kept.append(stroke); continue }
                let box = stroke.renderBounds
                let middle = CGPoint(x: frame.minX + box.midX + delta.width, y: frame.minY + box.midY + delta.height)
                var target = Self.page(at: middle, frames: frames) ?? page
                if drawings[target] == nil { target = page }
                let origin = frames[target] ?? frame
                var moved = stroke
                moved.transform = stroke.transform.concatenating(CGAffineTransform(translationX: delta.width + frame.minX - origin.minX,
                                                                                   y: delta.height + frame.minY - origin.minY))
                if copying {
                    kept.append(stroke)
                    // A copy is a stroke of its own, or a canvas would take it for the one it was copied from.
                    arrivals[target, default: []].append(PKStroke(ink: moved.ink, path: moved.path, transform: moved.transform, mask: moved.mask, randomSeed: moved.randomSeed))
                } else if target == page {
                    result[page, default: []].append(kept.count)
                    kept.append(moved)
                } else {
                    arrivals[target, default: []].append(moved)
                }
            }
            strokes[page] = kept
        }
        for (page, arriving) in arrivals {
            var all = strokes[page] ?? drawings[page]?.strokes ?? []
            result[page, default: []] += (all.count..<(all.count + arriving.count))
            all += arriving
            strokes[page] = all
        }
        return (strokes.mapValues { PKDrawing(strokes: $0) }, result)
    }

    static func removing(_ selection: InkSelection, from drawings: [UUID: PKDrawing]) -> [UUID: PKDrawing] {
        var result: [UUID: PKDrawing] = [:]
        for (page, indices) in selection {
            guard let drawing = drawings[page] else { continue }
            result[page] = drawing.removingStrokes(at: Set(indices))
        }
        return result
    }
}

extension PKDrawing {
    /// Only the strokes at `indices`, in the order they were drawn.
    func keepingStrokes(at indices: Set<Int>) -> PKDrawing {
        PKDrawing(strokes: strokes.enumerated().filter { indices.contains($0.offset) }.map(\.element))
    }

    /// Every stroke but those at `indices`.
    func removingStrokes(at indices: Set<Int>) -> PKDrawing {
        PKDrawing(strokes: strokes.enumerated().filter { !indices.contains($0.offset) }.map(\.element))
    }
}

/// Drawn over the page stack while ink is being selected across pages: the lasso as it is drawn, the stitched box
/// round what it caught, and the caught ink itself while it is being dragged.
final class InkLassoOverlay: UIView {
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { redraw() } }
    }
    /// Whether a touch at a point should go to what lies under the overlay, such as a selected picture's handles.
    var passesThrough: ((CGPoint) -> Bool)?

    private let lasso = CAShapeLayer(), lassoUnder = CAShapeLayer()
    private let box = CAShapeLayer(), boxUnder = CAShapeLayer()
    private let floating = UIView()
    private var path: [CGPoint] = []
    private(set) var selectionBounds: CGRect?
    private var lifted: [(view: UIImageView, rect: CGRect)] = []
    private var drag = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        for (layer, width, dash) in [(lassoUnder, 3.5 as CGFloat, false), (lasso, 2, true), (boxUnder, 3.5, false), (box, 2, true)] {
            layer.fillColor = nil
            layer.lineWidth = width
            layer.lineCap = .round
            layer.lineJoin = .round
            if dash { layer.lineDashPattern = [7, 5] }
            self.layer.addSublayer(layer)
        }
        floating.isUserInteractionEnabled = false
        addSubview(floating)
        colour()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (self: Self, _) in self.colour() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) && passesThrough?(point) != true
    }

    private func colour() {
        let mustard = UIColor.mustard.resolvedColor(with: traitCollection).cgColor
        let ink = UIColor.ink.resolvedColor(with: traitCollection).withAlphaComponent(0.55).cgColor
        lasso.strokeColor = mustard
        box.strokeColor = mustard
        lassoUnder.strokeColor = ink
        boxUnder.strokeColor = ink
    }

    private func onScreen(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale, y: point.y * scale) }

    private func redraw() {
        CATransaction.withoutActions {
            let line = UIBezierPath()
            for (index, point) in path.enumerated() { index == 0 ? line.move(to: onScreen(point)) : line.addLine(to: onScreen(point)) }
            lasso.path = path.isEmpty ? nil : line.cgPath
            lassoUnder.path = lasso.path
            if let selectionBounds {
                let rect = selectionBounds.scaled(by: scale).insetBy(dx: -8, dy: -8).offsetBy(dx: drag.width * scale, dy: drag.height * scale)
                box.path = UIBezierPath(roundedRect: rect, cornerRadius: Radius.plate).cgPath
            } else {
                box.path = nil
            }
            boxUnder.path = box.path
        }
        for item in lifted { item.view.frame = item.rect.scaled(by: scale) }
        floating.transform = CGAffineTransform(translationX: drag.width * scale, y: drag.height * scale)
    }

    // MARK: The lasso

    func begin(at point: CGPoint) {
        path = [point]
        redraw()
    }

    func add(_ point: CGPoint) {
        if let last = path.last, hypot(point.x - last.x, point.y - last.y) * scale < 2 { return }
        path.append(point)
        redraw()
    }

    /// The outline drawn, in stack points; it is taken away.
    func end() -> [CGPoint] {
        defer {
            path = []
            redraw()
        }
        return path
    }

    // MARK: What it caught

    func showSelection(_ bounds: CGRect?) {
        selectionBounds = bounds
        redraw()
    }

    /// Shows the caught ink as pictures that follow the finger; the canvases have stopped drawing it.
    func lift(_ images: [(image: UIImage, rect: CGRect)]) {
        drop()
        lifted = images.map { item in
            let view = UIImageView(image: item.image)
            floating.addSubview(view)
            return (view, item.rect)
        }
        redraw()
    }

    func drag(by delta: CGSize) {
        drag = delta
        redraw()
    }

    func drop() {
        lifted.forEach { $0.view.removeFromSuperview() }
        lifted = []
        drag = .zero
        redraw()
    }
}
