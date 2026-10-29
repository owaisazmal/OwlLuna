import UIKit

/// A step the selected item takes from VoiceOver or the keyboard: moved, turned, or made larger or smaller. Each
/// is one undo step.
enum ItemStep: Equatable {
    case move(CGSize)
    case turn(clockwise: Bool)
    case resize(larger: Bool)

    /// An arrow key moves the item a point, or ten with Shift. VoiceOver's Move actions go twenty.
    static let nudge: CGFloat = 1
    static let shiftNudge: CGFloat = 10
    static let spokenMove: CGFloat = 20
    static let turn = CGFloat.pi / 12
    static let growth: CGFloat = 1.1

    /// How far an arrow key moves the item, in page points, or nil for any other key.
    @MainActor
    static func nudge(_ input: String, shift: Bool) -> CGSize? {
        let step = shift ? shiftNudge : nudge
        return switch input {
        case UIKeyCommand.inputUpArrow: CGSize(width: 0, height: -step)
        case UIKeyCommand.inputDownArrow: CGSize(width: 0, height: step)
        case UIKeyCommand.inputLeftArrow: CGSize(width: -step, height: 0)
        case UIKeyCommand.inputRightArrow: CGSize(width: step, height: 0)
        default: nil
        }
    }

    func applied(to item: PageItem, page: CGSize) -> PageItem {
        switch self {
        case .move(let offset): item.moved(by: offset, page: page)
        case .turn(let clockwise): item.turned(clockwise: clockwise)
        case .resize(let larger): item.stepped(larger: larger, page: page)
        }
    }
}

extension PageItem {
    /// Moved by `offset`, with its centre kept on the page as a drag keeps it.
    func moved(by offset: CGSize, page: CGSize) -> PageItem {
        var copy = self
        copy.center.x = min(max(center.x + offset.width, 0), page.width)
        copy.center.y = min(max(center.y + offset.height, 0), page.height)
        return copy
    }

    /// Turned to the next twelfth of a half turn, clockwise or back.
    func turned(clockwise: Bool) -> PageItem {
        let steps = rotation / ItemStep.turn
        let next = clockwise ? (steps + 1e-6).rounded(.down) + 1 : (steps - 1e-6).rounded(.up) - 1
        var copy = self
        copy.rotation = remainder(next * ItemStep.turn, 2 * .pi)
        if abs(copy.rotation) < 1e-9 { copy.rotation = 0 }
        return copy
    }

    /// A tenth larger or smaller about its centre, keeping its proportions. It grows no larger than the page and
    /// hangs off it no further than it did.
    func stepped(larger: Bool, page: CGSize) -> PageItem {
        let box = boundingBox
        var factor = larger ? ItemStep.growth : 1 / ItemStep.growth
        if larger { factor = max(min(factor, page.width / max(box.width, 1), page.height / max(box.height, 1)), 1) }
        guard factor != 1 else { return self }
        var copy = scaled(by: factor, limit: .greatestFiniteMagnitude)
        // A box already under a fingertip's size is only ever scaled up, so a step down leaves it.
        guard larger == (copy.size.width > size.width) else { return self }
        let room = CGRect(origin: .zero, size: page).union(box), grown = copy.boundingBox
        copy.center.x += max(room.minX - grown.minX, 0) + min(room.maxX - grown.maxX, 0)
        copy.center.y += max(room.minY - grown.minY, 0) + min(room.maxY - grown.maxY, 0)
        return copy
    }

    /// How far it is turned, in whole degrees from -179 to 180, clockwise counting up.
    var turnedDegrees: Int {
        let degrees = Int((rotation * 180 / .pi).rounded()) % 360
        return degrees > 180 ? degrees - 360 : degrees <= -180 ? degrees + 360 : degrees
    }

    /// What VoiceOver says of its size and turn.
    var spokenSize: String {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded()), degrees = turnedDegrees
        if degrees > 0 { return String(localized: "\(width) by \(height) pt, turned \(degrees)° right") }
        if degrees < 0 { return String(localized: "\(width) by \(height) pt, turned \(-degrees)° left") }
        return String(localized: "\(width) by \(height) pt")
    }

    /// What VoiceOver says of where it is, from its top left corner.
    var spokenPlace: String {
        let box = boundingBox
        return String(localized: "\(Int(box.minX.rounded())) pt from the left, \(Int(box.minY.rounded())) pt from the top")
    }

    var spokenTurn: String {
        let degrees = turnedDegrees
        if degrees > 0 { return String(localized: "Turned \(degrees)° right") }
        if degrees < 0 { return String(localized: "Turned \(-degrees)° left") }
        return String(localized: "Upright")
    }
}
