import UIKit
import PencilKit

/// Reads a scratching-out from the points of one stroke, and which earlier strokes it scratches out. Pure geometry,
/// so it can be tested without a canvas.
enum ScribbleRecognizer {
    static let minimumReversals = 5
    /// How many times its own diagonal a scribble has to travel.
    static let density: CGFloat = 4
    /// How much of an earlier stroke has to lie under the scribble.
    static let cover = 0.5
    static let reach: CGFloat = 6

    /// A stroke that goes back and forth along its own length, again and again.
    static func isZigzag(_ points: [CGPoint]) -> Bool {
        guard points.count >= 8 else { return false }
        let box = ShapeRecognizer.bounds(of: points)
        let diagonal = hypot(box.width, box.height)
        guard diagonal >= 20, ShapeRecognizer.length(of: points) >= density * diagonal else { return false }
        return reversals(points) >= minimumReversals
    }

    /// Turns back along the stroke's longer direction. A turn counts once the stroke has come back by a good part
    /// of its whole length, so the loops of a spring and the humps of an "m" don't.
    static func reversals(_ points: [CGPoint]) -> Int {
        guard points.count >= 3 else { return 0 }
        let (mean, angle) = ShapeRecognizer.principalAxis(of: points)
        let along = points.map { ($0.x - mean.x) * cos(angle) + ($0.y - mean.y) * sin(angle) }
        guard let least = along.min(), let most = along.max() else { return 0 }
        let step = max(0.35 * (most - least), 8)
        var low = along[0], high = along[0], heading = 0, turns = 0
        for value in along {
            switch heading {
            case 0:
                low = min(low, value)
                high = max(high, value)
                if value - low >= step { heading = 1; high = value } else if high - value >= step { heading = -1; low = value }
            case 1:
                if value > high { high = value } else if high - value >= step { heading = -1; low = value; turns += 1 }
            default:
                if value < low { low = value } else if value - low >= step { heading = 1; high = value; turns += 1 }
            }
        }
        return turns
    }

    /// The places in `strokes` of the ones the scribble scratches out; none if it is not a scribble or lies on bare paper.
    /// Shading is left alone: an earlier zigzag under this one, or an outline this one is filling in.
    static func erased(by scribble: [CGPoint], from strokes: [[CGPoint]]) -> [Int] {
        guard isZigzag(scribble) else { return [] }
        return covered(by: scribble, in: strokes)
    }

    static func covered(by scribble: [CGPoint], in strokes: [[CGPoint]]) -> [Int] {
        let hull = InkVectors.convexHull(scribble)
        let box = ShapeRecognizer.bounds(of: scribble).insetBy(dx: -reach, dy: -reach)
        func isUnder(_ point: CGPoint) -> Bool {
            guard box.contains(point) else { return false }
            if InkLasso.contains(hull, point) { return true }
            return zip(scribble, scribble.dropFirst()).contains { ShapeRecognizer.distance(point, toSegment: $0, $1) <= reach }
        }
        return strokes.indices.filter { index in
            let points = strokes[index]
            guard !points.isEmpty, Double(points.count(where: isUnder)) >= cover * Double(points.count), !isZigzag(points) else { return false }
            guard LoopRecognizer.outline(points) != nil else { return true }
            return Double(scribble.count(where: { InkLasso.contains(points, $0) })) < 0.7 * Double(scribble.count)
        }
    }
}

/// Reads a closed loop, the kind drawn round something, from the points of one stroke.
enum LoopRecognizer {
    /// The stroke as an outline, if its ends meet and it goes round some room.
    static func outline(_ points: [CGPoint]) -> [CGPoint]? {
        guard points.count >= 8, let first = points.first, let last = points.last else { return nil }
        let box = ShapeRecognizer.bounds(of: points)
        let diagonal = hypot(box.width, box.height)
        guard diagonal >= 24, ShapeRecognizer.distance(first, last) <= max(0.3 * diagonal, 20) else { return nil }
        var twice: CGFloat = 0, previous = last
        for point in points {
            twice += previous.x * point.y - point.x * previous.y
            previous = point
        }
        guard abs(twice) / 2 >= 0.3 * box.width * box.height else { return nil }
        // Once round, or a little more: a scribble that ends where it began is not a loop.
        guard ShapeRecognizer.length(of: points) <= 3 * (box.width + box.height) else { return nil }
        return points
    }
}

/// Scribble to erase and circle and hold to select: the two recognisers applied to PencilKit strokes.
enum PencilGestures {
    static var scribbleErases: Bool { UserDefaults.standard.bool(forKey: SettingsKey.scribbleErases, default: false) }
    static var circleSelects: Bool { UserDefaults.standard.bool(forKey: SettingsKey.circleSelects, default: true) }

    /// `-fakePencilGestures` lets a UI test, which can only drag in straight lines, stand in for both gestures:
    /// any stroke counts as a zigzag, and a straight stroke that was held is the diagonal of a box.
    static var isScripted: Bool {
        #if DEBUG
        return LaunchOptions.arguments.contains("-fakePencilGestures")
        #else
        return false
        #endif
    }

    /// `-fakePencilSqueeze` lets a UI test, which has no Pencil to squeeze, tap the page with two fingers instead.
    static var squeezeIsScripted: Bool {
        #if DEBUG
        return LaunchOptions.arguments.contains("-fakePencilSqueeze")
        #else
        return false
        #endif
    }

    /// Pens write; the marker, watercolour and crayon shade, and shading goes back and forth over ink all the time.
    static func writes(_ tool: PKTool) -> Bool {
        guard let ink = (tool as? PKInkingTool)?.inkType else { return false }
        return ![.marker, .watercolor, .crayon].contains(ink)
    }

    static func points(of stroke: PKStroke, spacing: CGFloat = 4) -> [CGPoint] {
        stroke.path.interpolatedPoints(by: .distance(spacing)).map { $0.location.applying(stroke.transform) }
    }

    /// The drawing without the strokes `scribble` scratches out, or nil if it is ordinary writing.
    static func erasing(_ scribble: PKStroke, from drawing: PKDrawing) -> (drawing: PKDrawing, count: Int)? {
        let path = points(of: scribble)
        guard isScripted || ScribbleRecognizer.isZigzag(path) else { return nil }
        let box = ShapeRecognizer.bounds(of: path).insetBy(dx: -ScribbleRecognizer.reach, dy: -ScribbleRecognizer.reach)
        let near = drawing.strokes.indices.filter { drawing.strokes[$0].renderBounds.intersects(box) }
        let hit = Set(ScribbleRecognizer.covered(by: path, in: near.map { points(of: drawing.strokes[$0]) }).map { near[$0] })
        guard !hit.isEmpty else { return nil }
        return (drawing.removingStrokes(at: hit), hit.count)
    }

    /// The outline `stroke` draws, in the page's points, if it is a loop with ink of `drawing` inside it.
    static func outline(of stroke: PKStroke, roundInkIn drawing: PKDrawing) -> [CGPoint]? {
        let path = points(of: stroke)
        let scripted = isScripted ? InkLasso.outline(from: path) : []
        guard let outline = LoopRecognizer.outline(path) ?? (scripted.count == 4 ? scripted : nil),
              !InkLasso.strokes(in: drawing, inside: outline).isEmpty else { return nil }
        return outline
    }

    /// A held loop round ink that straightens into three or four sides is a box or triangle to keep, not a selection:
    /// a loop round words hardly ever comes out with so few corners. Round ones still select.
    static func keepsFigure(_ shape: SnappedShape?) -> Bool {
        guard case .polygon(let corners)? = shape else { return false }
        return corners.count <= 4
    }
}

/// What a double-tap or a squeeze of the Pencil does.
enum PencilAction: String, CaseIterable, Identifiable {
    case system, eraser, undo, selectInk, toggleTools, palette, zoomWindow
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: String(localized: "System Setting")
        case .eraser: String(localized: "Switch to Eraser")
        case .undo: String(localized: "Undo")
        case .selectInk: String(localized: "Select Ink")
        case .toggleTools: String(localized: "Show or Hide Tools")
        case .palette: String(localized: "Tool Palette at the Pencil")
        case .zoomWindow: String(localized: "Zoom Window")
        }
    }

    static func setting(_ key: String) -> PencilAction {
        UserDefaults.standard.string(forKey: key).flatMap(PencilAction.init(rawValue:)) ?? .system
    }
}

/// Remembers which tools were in hand, so a tap of the Pencil can go back to the one before, or from the eraser to
/// what was in use before it.
struct PencilToolMemory<Tool: Equatable> {
    private(set) var current: Tool?
    private(set) var previous: Tool?
    private var isEraser = false
    private var beforeEraser: Tool?

    mutating func select(_ tool: Tool, isEraser: Bool) {
        guard tool != current else { return }
        if isEraser, !self.isEraser { beforeEraser = current }
        previous = current
        current = tool
        self.isEraser = isEraser
    }

    /// Where the eraser switch goes: to the eraser, or from it to the tool that was in use before.
    func eraserSwitch(eraser: Tool?) -> Tool? {
        isEraser ? beforeEraser ?? previous : eraser
    }
}
