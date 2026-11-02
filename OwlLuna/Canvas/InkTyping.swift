import UIKit
import PencilKit

/// Handwriting set as type while it is written (the tray's Handwriting to Text): how long the pen has to rest, and
/// whether what was written next carries on the text made just before. Kept off the canvas, so it can be tested without one.
enum InkTyping {
    /// How long the pen rests before what was written is set as type. `-inkTypingPause` lets a UI test, which is slow
    /// between strokes, finish a word first.
    static var pause: TimeInterval {
        #if DEBUG
        if let scripted = LaunchOptions.value("-inkTypingPause").flatMap(TimeInterval.init) { return scripted }
        #endif
        return 1.0
    }

    /// How far into the rest the reading begins, so it is done by the time the rest is long enough.
    static var lookAhead: TimeInterval { min(0.4, pause) }

    /// What `read` makes of each piece, handed back no sooner than `rest` seconds after the reading began.
    static func read(_ pieces: [PKDrawing], handingBackAfter rest: TimeInterval, with read: @escaping @Sendable (PKDrawing) -> String?) async -> [String?] {
        let due = ContinuousClock.now + .seconds(rest)
        var texts: [String?] = []
        for piece in pieces {
            texts.append(await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: read(piece))
                }
            })
        }
        try? await Task.sleep(until: due, clock: .continuous)
        return texts
    }

    enum Join: Equatable { case sameLine, nextLine }

    /// What was last set as type: its box, where its handwriting stood on the page, and how tall a line of that was.
    struct Last: Equatable {
        var pageID: UUID
        var itemID: UUID
        var written: CGRect
        var lineHeight: CGFloat
    }

    /// Whether handwriting at `bounds` carries on what was `written` before it: further along its last line, or
    /// at the start of the line below. Anything else is a text of its own.
    static func join(_ bounds: CGRect, after written: CGRect, lineHeight: CGFloat) -> Join? {
        guard !bounds.isNull, !written.isNull, lineHeight > 0 else { return nil }
        let lastLine = (written.maxY - lineHeight * 1.2)...(written.maxY + lineHeight * 0.2)
        if lastLine.contains(bounds.midY), bounds.minX > written.minX + lineHeight * 0.5, bounds.minX - written.maxX <= lineHeight * 6 {
            return .sameLine
        }
        let below = (written.maxY - lineHeight * 0.3)...(written.maxY + lineHeight * 1.6)
        if below.contains(bounds.minY), bounds.minX <= written.minX + lineHeight * 3, bounds.maxX >= written.minX { return .nextLine }
        return nil
    }

    /// The box with `text` added to its last line or on a new one, grown to hold it and kept where it began.
    static func extended(_ item: PageItem, with text: String, _ join: Join, pageSize: CGSize) -> PageItem? {
        guard case .text(var box) = item.content, item.rotation == 0 else { return nil }
        box.string += (join == .sameLine ? " " : "\n") + text
        let left = item.center.x - item.size.width / 2, top = item.center.y - item.size.height / 2
        let room = max(pageSize.width - 12 - left, 60)
        let width = min(max(box.naturalWidth(limit: room), item.size.width), room)
        var grown = item
        grown.content = .text(box)
        grown.size = CGSize(width: width, height: box.height(width: width))
        grown.center = CGPoint(x: left + width / 2, y: top + grown.size.height / 2)
        return grown
    }

    /// The text colour nearest a pen's ink.
    static func tint(for color: UIColor) -> TextBox.Tint {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard brightness >= 0.2, saturation >= 0.2 else { return .ink }
        switch hue * 360 {
        case ..<40, 345...: return brightness < 0.6 && hue * 360 >= 15 ? .ink : .tomato
        case ..<65: return .ink
        case ..<195: return .moss
        case ..<255: return .cobalt
        default: return .plum
        }
    }
}
