import UIKit
import PencilKit
import UniformTypeIdentifiers

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
        box(of: selection, drawings: drawings, frames: frames)?.bounds
    }

    /// The box round the selection, in stack points, standing at `turn` as its ink was left turned: the ink is
    /// measured as it lies turned back upright.
    static func box(of selection: InkSelection, turn: CGFloat = 0, drawings: [UUID: PKDrawing], frames: [UUID: CGRect]) -> InkBox? {
        let upright = CGAffineTransform(rotationAngle: -turn)
        var result: CGRect?
        for (page, indices) in selection {
            guard let strokes = drawings[page]?.strokes, let frame = frames[page] else { continue }
            for index in indices where strokes.indices.contains(index) {
                var stroke = strokes[index], box = stroke.renderBounds.offsetBy(dx: frame.minX, dy: frame.minY)
                if turn != 0 {
                    stroke.transform = stroke.transform.concatenating(CGAffineTransform(translationX: frame.minX, y: frame.minY)).concatenating(upright)
                    box = stroke.renderBounds
                }
                result = result?.union(box) ?? box
            }
        }
        guard let result, !result.isNull else { return nil }
        return InkBox(center: CGPoint(x: result.midX, y: result.midY).applying(CGAffineTransform(rotationAngle: turn)), size: result.size, turn: turn)
    }

    /// The page a point in the stack belongs to: the one it is on, or else the nearest.
    static func page(at point: CGPoint, frames: [UUID: CGRect]) -> UUID? {
        if let hit = frames.first(where: { $0.value.contains(point) }) { return hit.key }
        func distance(_ frame: CGRect) -> CGFloat {
            hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
        }
        return frames.min { distance($0.value) < distance($1.value) }?.key
    }

    /// Moves, or copies, the selected strokes by `delta`.
    static func moved(_ selection: InkSelection, by delta: CGSize, copying: Bool = false,
                      drawings: [UUID: PKDrawing], frames: [UUID: CGRect]) -> (drawings: [UUID: PKDrawing], selection: InkSelection) {
        changed(selection, by: CGAffineTransform(translationX: delta.width, y: delta.height), copying: copying, drawings: drawings, frames: frames)
    }

    /// Changes the selected strokes by `change`, given in stack points, or copies them changed. A stroke whose middle
    /// lands on another page becomes that page's ink; on a page whose drawing isn't given it stays where it came from.
    /// Returns the drawings that changed and where the strokes are now.
    static func changed(_ selection: InkSelection, by change: CGAffineTransform, copying: Bool = false,
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
                let middle = CGPoint(x: frame.minX + box.midX, y: frame.minY + box.midY).applying(change)
                var target = Self.page(at: middle, frames: frames) ?? page
                if drawings[target] == nil { target = page }
                let origin = frames[target] ?? frame
                let onPage = CGAffineTransform(translationX: frame.minX, y: frame.minY).concatenating(change)
                    .concatenating(CGAffineTransform(translationX: -origin.minX, y: -origin.minY))
                let moved = Self.changed(stroke, by: onPage)
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

    /// A stroke changed by `change`, in its page's points. Moved, turned or resized evenly, it keeps its path and its
    /// line scales with it. Stretched one way, its path is stretched instead, so its line stays as thick as it was.
    static func changed(_ stroke: PKStroke, by change: CGAffineTransform) -> PKStroke {
        var result = stroke
        let own = stroke.transform
        guard !change.isEven, abs(own.a * own.d - own.b * own.c) > 1e-9 else {
            result.transform = own.concatenating(change)
            return result
        }
        let inPath = own.concatenating(change).concatenating(own.inverted())
        result.path = PKStrokePath(controlPoints: stroke.path.map { $0.moved(to: $0.location.applying(inPath)) }, creationDate: stroke.path.creationDate)
        if let mask = stroke.mask?.copy() as? UIBezierPath {
            mask.apply(inPath)
            result.mask = mask
        }
        return result
    }

    static func removing(_ selection: InkSelection, from drawings: [UUID: PKDrawing]) -> [UUID: PKDrawing] {
        var result: [UUID: PKDrawing] = [:]
        for (page, indices) in selection {
            guard let drawing = drawings[page] else { continue }
            result[page] = drawing.removingStrokes(at: Set(indices))
        }
        return result
    }

    /// Whether two drawings hold the same strokes in the same places, whatever their colours and lines: so a
    /// selection in the one still points at its strokes in the other.
    static func sameStrokes(_ one: PKDrawing, _ other: PKDrawing) -> Bool {
        let old = one.strokes, new = other.strokes
        guard old.count == new.count else { return false }
        return zip(old, new).allSatisfy { was, now in
            let before = was.path, after = now.path
            return was.transform == now.transform && was.ink.inkType == now.ink.inkType && before.count == after.count
                && before.creationDate == after.creationDate && before.first?.location == after.first?.location
                && before.last?.location == after.last?.location
        }
    }
}

/// Ink on the clipboard, as PencilKit's own drawing type, so it pastes into Notes and comes back from it, beside a
/// picture of it for everything else.
@MainActor
enum InkClipboard {
    static let type = PKAppleDrawingTypeIdentifier as String
    /// The general pasteboard; tests put their own here.
    static var pasteboard = UIPasteboard.general
    /// A picture of the ink is kept under this many pixels.
    private static let pixelLimit: CGFloat = 8_000_000

    static var hasInk: Bool { pasteboard.contains(pasteboardTypes: [type]) }

    static func copy(_ ink: PKDrawing) {
        var item: [String: Any] = [type: ink.dataRepresentation()]
        let bounds = ink.bounds.insetBy(dx: -4, dy: -4)
        if !bounds.isNull, !bounds.isEmpty {
            let scale = min(2, (pixelLimit / (bounds.width * bounds.height)).squareRoot())
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent { image = ink.image(from: bounds, scale: scale) }
            if let png = image?.pngData() { item[UTType.png.identifier] = png }
        }
        pasteboard.setItems([item])
    }

    static func ink() -> PKDrawing? {
        guard let data = pasteboard.data(forPasteboardType: type), let ink = try? PKDrawing(data: data), !ink.strokes.isEmpty else { return nil }
        return ink
    }

    /// The ink as new strokes of its own, shifted so that its middle is at `center` and kept on a page of `size`
    /// where it fits.
    static func placed(_ ink: PKDrawing, at center: CGPoint, onPageOf size: CGSize) -> [PKStroke] {
        let bounds = ink.bounds
        guard !bounds.isNull else { return [] }
        func shift(_ middle: CGFloat, _ length: CGFloat, _ target: CGFloat, _ room: CGFloat) -> CGFloat {
            length >= room ? room / 2 - middle : min(max(target, length / 2), room - length / 2) - middle
        }
        let move = CGAffineTransform(translationX: shift(bounds.midX, bounds.width, center.x, size.width),
                                     y: shift(bounds.midY, bounds.height, center.y, size.height))
        return ink.strokes.map { PKStroke(ink: $0.ink, path: $0.path, transform: $0.transform.concatenating(move), mask: $0.mask, randomSeed: $0.randomSeed) }
    }
}

private extension PKStrokePoint {
    /// The same touch of the nib at another place.
    func moved(to place: CGPoint) -> PKStrokePoint {
        if #available(iOS 27.0, *) {
            return PKStrokePoint(location: place, timeOffset: timeOffset, size: size, opacity: opacity, force: force, azimuth: azimuth, altitude: altitude,
                                 secondaryScale: secondaryScale, threshold: threshold, lateralJitter: lateralJitter)
        }
        if #available(iOS 26.0, *) {
            return PKStrokePoint(location: place, timeOffset: timeOffset, size: size, opacity: opacity, force: force, azimuth: azimuth, altitude: altitude,
                                 secondaryScale: secondaryScale, threshold: threshold)
        }
        return PKStrokePoint(location: place, timeOffset: timeOffset, size: size, opacity: opacity, force: force, azimuth: azimuth, altitude: altitude,
                             secondaryScale: secondaryScale)
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
/// round what it caught with the handles that shape it, and the caught ink itself while it is being dragged.
final class InkLassoOverlay: UIView {
    var scale: CGFloat = 1 {
        didSet { if scale != oldValue { redraw() } }
    }
    /// Whether a touch at a point should go to what lies under the overlay, such as a selected picture's handles.
    var passesThrough: ((CGPoint) -> Bool)?
    /// Whether the box wears its handles. Ink that can't be changed has none.
    var hasHandles = true {
        didSet { if hasHandles != oldValue { redraw() } }
    }
    /// A step on a handle from an assistive technology.
    var onStep: ((InkHandle, _ up: Bool) -> Void)?

    private let lasso = CAShapeLayer(), lassoUnder = CAShapeLayer()
    private let outline = CAShapeLayer(), outlineUnder = CAShapeLayer()
    private let stalk = CAShapeLayer(), stalkUnder = CAShapeLayer()
    private let floating = UIView()
    private let grips = InkHandle.allCases.map { InkGrip(handle: $0) }
    private var path: [CGPoint] = []
    /// The box round what is caught, as it stands on the pages.
    private(set) var selectionBox: InkBox?
    private var lifted: [(view: UIImageView, rect: CGRect)] = []
    /// What a drag has done to the lifted ink so far, in stack points.
    private var change = CGAffineTransform.identity

    /// The upright rectangle round what is caught, in stack points.
    var selectionBounds: CGRect? { selectionBox?.bounds }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        for (layer, width, dash) in [(lassoUnder, 3.5 as CGFloat, false), (lasso, 2, true), (outlineUnder, 3.5, false), (outline, 2, true),
                                     (stalkUnder, 3.5, false), (stalk, 2, false)] {
            layer.fillColor = nil
            layer.lineWidth = width
            layer.lineCap = .round
            layer.lineJoin = .round
            if dash { layer.lineDashPattern = [7, 5] }
            self.layer.addSublayer(layer)
        }
        floating.isUserInteractionEnabled = false
        addSubview(floating)
        for grip in grips {
            grip.isHidden = true
            grip.onStep = { [weak self, handle = grip.handle] up in self?.onStep?(handle, up) }
            addSubview(grip)
        }
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
        for line in [lasso, outline, stalk] { line.strokeColor = mustard }
        for line in [lassoUnder, outlineUnder, stalkUnder] { line.strokeColor = ink }
        for grip in grips { grip.colour(traitCollection) }
    }

    private func onScreen(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale, y: point.y * scale) }

    /// The box and its handles as they are drawn: where a drag has taken them so far.
    private var layout: InkBoxLayout? {
        selectionBox.map { InkBoxLayout($0.applying(change), scale: scale, in: bounds) }
    }

    private func redraw() {
        let layout = layout, handled = hasHandles && path.isEmpty
        // The box and its handles go to the screen together.
        CATransaction.withoutActions {
            let line = UIBezierPath()
            for (index, point) in path.enumerated() { index == 0 ? line.move(to: onScreen(point)) : line.addLine(to: onScreen(point)) }
            lasso.path = path.isEmpty ? nil : line.cgPath
            lassoUnder.path = lasso.path
            if let layout {
                let size = layout.outline
                let stitched = UIBezierPath(roundedRect: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                                            cornerRadius: Radius.plate)
                stitched.apply(CGAffineTransform(rotationAngle: layout.box.turn).concatenating(CGAffineTransform(translationX: layout.box.center.x, y: layout.box.center.y)))
                outline.path = stitched.cgPath
                let stem = UIBezierPath()
                stem.move(to: layout.stalkFoot)
                stem.addLine(to: layout.center(of: .knob))
                stalk.path = handled ? stem.cgPath : nil
            } else {
                outline.path = nil
                stalk.path = nil
            }
            outlineUnder.path = outline.path
            stalkUnder.path = stalk.path
            for grip in grips {
                grip.isHidden = layout == nil || !handled
                guard let layout, handled else { continue }
                grip.transform = .identity
                grip.center = layout.center(of: grip.handle)
                grip.transform = CGAffineTransform(rotationAngle: layout.box.turn)
                if let selectionBox { grip.show(selectionBox.applying(change)) }
            }
        }
        for item in lifted { item.view.frame = item.rect.scaled(by: scale) }
        floating.transform = CGAffineTransform(a: change.a, b: change.b, c: change.c, d: change.d, tx: change.tx * scale, ty: change.ty * scale)
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

    func showSelection(_ box: InkBox?) {
        selectionBox = box
        redraw()
    }

    /// The handle a touch at a point of the stack takes hold of, if it lands on one.
    func handle(at point: CGPoint) -> InkHandle? {
        guard hasHandles, path.isEmpty, let layout else { return nil }
        return layout.handle(at: onScreen(point))
    }

    /// Shows the caught ink as pictures that follow a drag; the canvases have stopped drawing it.
    func lift(_ images: [(image: UIImage, rect: CGRect)]) {
        drop()
        lifted = images.map { item in
            let view = UIImageView(image: item.image)
            floating.addSubview(view)
            return (view, item.rect)
        }
        redraw()
    }

    /// Shows the lifted ink and its box as a drag has changed them so far, in stack points.
    func follow(_ change: CGAffineTransform) {
        self.change = change
        redraw()
    }

    func drop() {
        lifted.forEach { $0.view.removeFromSuperview() }
        lifted = []
        change = .identity
        redraw()
    }
}
