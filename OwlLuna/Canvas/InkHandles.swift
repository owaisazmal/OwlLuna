import UIKit

/// The box round caught ink, in stack points: its middle, its size, and how far it stands turned with the ink.
struct InkBox: Equatable {
    var center: CGPoint
    var size: CGSize
    var turn: CGFloat = 0

    /// A handle makes no side shorter than this, unless it was shorter to begin with.
    static let leastSide: CGFloat = 12

    /// A point of the box given in its unit square: (0, 0) is its top left corner as it stood upright.
    func point(_ unit: CGPoint) -> CGPoint {
        let x = (unit.x - 0.5) * size.width, y = (unit.y - 0.5) * size.height
        return CGPoint(x: center.x + x * cos(turn) - y * sin(turn), y: center.y + x * sin(turn) + y * cos(turn))
    }

    /// How far a point of the stack lies from the box's middle, along the box's own sides.
    func offset(to point: CGPoint) -> CGPoint {
        let dx = point.x - center.x, dy = point.y - center.y
        return CGPoint(x: dx * cos(turn) + dy * sin(turn), y: dy * cos(turn) - dx * sin(turn))
    }

    /// The upright rectangle round it.
    var bounds: CGRect {
        let width = abs(size.width * cos(turn)) + abs(size.height * sin(turn)), height = abs(size.width * sin(turn)) + abs(size.height * cos(turn))
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    func contains(_ point: CGPoint, margin: CGFloat = 0) -> Bool {
        let at = offset(to: point)
        return abs(at.x) <= size.width / 2 + margin && abs(at.y) <= size.height / 2 + margin
    }

    /// With no side shorter than `side`, so there is always something of it to take hold of.
    func grown(toAtLeast side: CGFloat) -> InkBox {
        InkBox(center: center, size: CGSize(width: max(size.width, side), height: max(size.height, side)), turn: turn)
    }

    /// The box after its ink was moved, turned, resized, or stretched along one of the box's own sides.
    func applying(_ change: CGAffineTransform) -> InkBox {
        let across = CGVector(dx: cos(turn) * change.a + sin(turn) * change.c, dy: cos(turn) * change.b + sin(turn) * change.d)
        let down = CGVector(dx: cos(turn) * change.c - sin(turn) * change.a, dy: cos(turn) * change.d - sin(turn) * change.b)
        return InkBox(center: center.applying(change), size: CGSize(width: size.width * hypot(across.dx, across.dy), height: size.height * hypot(down.dx, down.dy)),
                      turn: atan2(across.dy, across.dx))
    }

    /// Whether a change moves no corner of the box as far as half a point.
    func isLeftAlone(by change: CGAffineTransform) -> Bool {
        [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].allSatisfy { unit in
            let corner = point(unit), moved = corner.applying(change)
            return hypot(moved.x - corner.x, moved.y - corner.y) < 0.5
        }
    }

    /// How far it is turned, in whole degrees from -179 to 180, clockwise counting up.
    var turnedDegrees: Int {
        let degrees = Int((turn * 180 / .pi).rounded()) % 360
        return degrees > 180 ? degrees - 360 : degrees <= -180 ? degrees + 360 : degrees
    }

    // MARK: What a handle does

    /// What dragging a handle from `start` to `point` does to the ink, in stack points: a tab resizes it from the far
    /// corner, a bar stretches it from the far side, and the knob turns it about its middle. No side grows past `most`.
    func change(dragging handle: InkHandle, from start: CGPoint, to point: CGPoint, most: CGFloat) -> CGAffineTransform {
        if handle == .knob {
            let from = atan2(start.y - center.y, start.x - center.x), to = atan2(point.y - center.y, point.x - center.x)
            return Self.turning(by: ItemSelectionView.snapped(turn + to - from) - turn, about: center)
        }
        let held = self.point(CGPoint(x: 1 - handle.unit.x, y: 1 - handle.unit.y))
        let reach = CGVector(dx: start.x - held.x, dy: start.y - held.y), now = CGVector(dx: point.x - held.x, dy: point.y - held.y)
        if handle.isCorner {
            let length = reach.dx * reach.dx + reach.dy * reach.dy
            let factor = Self.bounded(length < 1 ? 1 : (now.dx * reach.dx + now.dy * reach.dy) / length, side: max(size.width, size.height), most: most)
            return stretching(by: CGSize(width: factor, height: factor), holding: held)
        }
        let wide = handle.isWide
        let axis = wide ? CGVector(dx: cos(turn), dy: sin(turn)) : CGVector(dx: -sin(turn), dy: cos(turn))
        let before = reach.dx * axis.dx + reach.dy * axis.dy, after = now.dx * axis.dx + now.dy * axis.dy
        let factor = Self.bounded(abs(before) < 1 ? 1 : after / before, side: wide ? size.width : size.height, most: most)
        return stretching(by: wide ? CGSize(width: factor, height: 1) : CGSize(width: 1, height: factor), holding: held)
    }

    /// A step on a handle from an assistive technology: a tenth larger or smaller about the middle, a tenth wider or
    /// taller from the opposite side, or on to the next twelfth of a half turn.
    func change(stepping handle: InkHandle, up: Bool, most: CGFloat) -> CGAffineTransform {
        let growth = up ? ItemStep.growth : 1 / ItemStep.growth
        if handle == .knob {
            let steps = turn / ItemStep.turn
            let next = up ? (steps + 1e-6).rounded(.down) + 1 : (steps - 1e-6).rounded(.up) - 1
            return Self.turning(by: next * ItemStep.turn - turn, about: center)
        }
        if handle.isCorner {
            let factor = Self.bounded(growth, side: max(size.width, size.height), most: most)
            return stretching(by: CGSize(width: factor, height: factor), holding: center)
        }
        let wide = handle.isWide, factor = Self.bounded(growth, side: wide ? size.width : size.height, most: most)
        return stretching(by: wide ? CGSize(width: factor, height: 1) : CGSize(width: 1, height: factor),
                          holding: point(CGPoint(x: 1 - handle.unit.x, y: 1 - handle.unit.y)))
    }

    /// A factor that leaves a side between the least a handle makes and `most`, or as it is where it was already past them.
    static func bounded(_ factor: CGFloat, side: CGFloat, most: CGFloat) -> CGFloat {
        let side = max(side, 0.01)
        return min(max(factor, min(leastSide / side, 1)), max(most / side, 1))
    }

    static func turning(by angle: CGFloat, about point: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -point.x, y: -point.y).concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
    }

    /// Makes the ink `factor` times as wide and as tall along the box's own sides, with `point` held still.
    func stretching(by factor: CGSize, holding point: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -point.x, y: -point.y).concatenating(CGAffineTransform(rotationAngle: -turn))
            .concatenating(CGAffineTransform(scaleX: factor.width, y: factor.height)).concatenating(CGAffineTransform(rotationAngle: turn))
            .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
    }
}

extension CGAffineTransform {
    /// Whether it only moves, turns and resizes evenly: nothing is stretched one way or mirrored.
    var isEven: Bool {
        let size = max(abs(a), abs(b), abs(c), abs(d), 1e-9)
        return a * d - b * c > 0 && abs(a - d) <= 1e-6 * size && abs(b + c) <= 1e-6 * size
    }
}

/// A handle on the box round caught ink. A tab on a corner resizes the ink, a bar on a side stretches it one way,
/// and the knob standing off the box turns it.
enum InkHandle: String, CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight, knob

    /// Where on the box it sits, in the box's unit square. The knob stands off the middle of the top.
    var unit: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .top, .knob: CGPoint(x: 0.5, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .left: CGPoint(x: 0, y: 0.5)
        case .right: CGPoint(x: 1, y: 0.5)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomRight: CGPoint(x: 1, y: 1)
        }
    }

    var isCorner: Bool { unit.x != 0.5 && unit.y != 0.5 }
    /// A bar that changes how wide the ink is.
    var isWide: Bool { self == .left || self == .right }
}

/// Where the box and its handles are drawn in the overlay's points, and which handle a touch takes hold of.
struct InkBoxLayout {
    /// The stitched outline stands this far out from the ink, and the handles sit on it.
    static let outset: CGFloat = 8
    /// The box is drawn no smaller than a fingertip, so there is always room inside it to move the ink by.
    static let leastSide: CGFloat = 44
    /// How far from a handle's middle a touch still takes hold of it.
    static let reach: CGFloat = 22
    /// How far off the outline the knob's middle stands.
    static let stalk: CGFloat = 30

    /// The box on the screen, grown to a fingertip's size.
    let box: InkBox
    /// The knob stands under the box where there is no room for it above.
    let knobBelow: Bool

    init(_ box: InkBox, scale: CGFloat, in bounds: CGRect) {
        let grown = InkBox(center: CGPoint(x: box.center.x * scale, y: box.center.y * scale),
                           size: CGSize(width: box.size.width * scale, height: box.size.height * scale), turn: box.turn).grown(toAtLeast: Self.leastSide)
        self.box = grown
        let room = bounds.insetBy(dx: Self.reach, dy: Self.reach), rise = grown.size.height / 2 + Self.outset + Self.stalk
        func knob(_ rise: CGFloat) -> CGPoint { CGPoint(x: grown.center.x + rise * sin(grown.turn), y: grown.center.y - rise * cos(grown.turn)) }
        knobBelow = !room.contains(knob(rise)) && room.contains(knob(-rise))
    }

    /// The outline round the box, before it is turned.
    var outline: CGSize { CGSize(width: box.size.width + Self.outset * 2, height: box.size.height + Self.outset * 2) }

    /// A handle's middle from the box's middle, along the box's own sides.
    private func offset(of handle: InkHandle) -> CGPoint {
        if handle == .knob { return CGPoint(x: 0, y: (knobBelow ? 1 : -1) * (outline.height / 2 + Self.stalk)) }
        return CGPoint(x: (handle.unit.x - 0.5) * outline.width, y: (handle.unit.y - 0.5) * outline.height)
    }

    private func placed(_ offset: CGPoint) -> CGPoint {
        CGPoint(x: box.center.x + offset.x * cos(box.turn) - offset.y * sin(box.turn), y: box.center.y + offset.x * sin(box.turn) + offset.y * cos(box.turn))
    }

    func center(of handle: InkHandle) -> CGPoint { placed(offset(of: handle)) }

    /// Where the knob's stalk leaves the outline.
    var stalkFoot: CGPoint { placed(CGPoint(x: 0, y: (knobBelow ? 1 : -1) * outline.height / 2)) }

    /// The handle a touch at `point` takes hold of: the nearest within reach. Inside the box the ink is moved instead.
    func handle(at point: CGPoint) -> InkHandle? {
        let at = box.offset(to: point)
        guard abs(at.x) > box.size.width / 2 || abs(at.y) > box.size.height / 2 else { return nil }
        var nearest: (handle: InkHandle, distance: CGFloat)?
        for handle in InkHandle.allCases {
            let middle = offset(of: handle), distance = max(abs(at.x - middle.x), abs(at.y - middle.y))
            if distance <= Self.reach, distance < nearest?.distance ?? .infinity { nearest = (handle, distance) }
        }
        return nearest?.handle
    }
}

/// A handle as it is drawn on the box: a tab, a bar or the knob, in the middle of a fingertip's room. The overlay
/// takes its touches; an assistive technology steps it up or down.
final class InkGrip: UIView {
    let handle: InkHandle
    var onStep: ((_ up: Bool) -> Void)?
    private let shape = UIImageView()

    init(handle: InkHandle) {
        self.handle = handle
        super.init(frame: CGRect(x: 0, y: 0, width: InkBoxLayout.reach * 2, height: InkBoxLayout.reach * 2))
        let size = switch handle {
        case .knob: CGSize(width: 28, height: 28)
        case .top, .bottom: CGSize(width: 28, height: 10)
        case .left, .right: CGSize(width: 10, height: 28)
        default: CGSize(width: 14, height: 14)
        }
        shape.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        shape.backgroundColor = Grip.fill
        shape.layer.cornerRadius = handle == .knob ? size.width / 2 : 2
        shape.layer.borderWidth = 1
        if handle == .knob {
            shape.image = UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
            shape.tintColor = Grip.ink
            shape.contentMode = .center
        }
        addSubview(shape)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "page.ink.\(handle.rawValue)"
        // One tab speaks for the four, and one bar for each way the ink stretches.
        switch handle {
        case .bottomRight: accessibilityLabel = String(localized: "Resize")
        case .right: accessibilityLabel = String(localized: "Change width")
        case .bottom: accessibilityLabel = String(localized: "Change height")
        case .knob: accessibilityLabel = String(localized: "Rotate")
        default: return
        }
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError() }

    func colour(_ traits: UITraitCollection) {
        shape.layer.borderColor = Grip.edge(traits)
    }

    /// What VoiceOver says of the ink this handle changes.
    func show(_ box: InkBox) {
        guard isAccessibilityElement else { return }
        let width = Int(box.size.width.rounded()), height = Int(box.size.height.rounded()), degrees = box.turnedDegrees
        accessibilityValue = switch handle {
        case .right: String(localized: "\(width) pt")
        case .bottom: String(localized: "\(height) pt")
        case .knob: degrees > 0 ? String(localized: "Turned \(degrees)° right") : degrees < 0 ? String(localized: "Turned \(-degrees)° left") : String(localized: "Upright")
        default: String(localized: "\(width) by \(height) pt")
        }
    }

    override func accessibilityIncrement() { onStep?(true) }
    override func accessibilityDecrement() { onStep?(false) }
}
