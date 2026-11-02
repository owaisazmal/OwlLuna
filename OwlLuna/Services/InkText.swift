import UIKit
import PencilKit

/// Reads selected handwriting as text, on the device, with the recogniser that indexes pages for search.
enum InkText {
    /// Recognition can wait on Vision, so it must leave Swift's cooperative workers free.
    static func recognizeInBackground(_ pieces: [PKDrawing]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: recognize(pieces))
            }
        }
    }

    /// Each piece is the ink picked on one page, top page first. Nil when the recogniser failed.
    static func recognize(_ pieces: [PKDrawing]) -> String? {
        #if DEBUG
        // A UI test can only drag straight lines; `-scriptedInkText` says what they read as.
        if let scripted = LaunchOptions.value("-scriptedInkText") { return pieces.contains { !$0.strokes.isEmpty } ? scripted : "" }
        #endif
        var lines: [String] = []
        for piece in pieces {
            guard let image = image(of: piece) else { continue }
            guard var found = HandwritingIndexer.recognizeText(in: image) else { return nil }
            // A word the recogniser passes over is often read with more room at its sides.
            let sides = piece.bounds.height
            if found.isEmpty, sides > 24, let wider = self.image(of: piece, sides: sides) { found = HandwritingIndexer.recognizeText(in: wider) ?? [] }
            lines += found
        }
        return lines.joined(separator: "\n")
    }

    @MainActor private static var isWarm = false

    /// Loads the recogniser ahead of the first reading, which otherwise waits for its models and is the slowest.
    @MainActor static func warmUp() {
        guard !isWarm else { return }
        isWarm = true
        DispatchQueue.global(qos: .utility).async {
            let size = CGSize(width: 240, height: 96)
            let words = UIGraphicsImageRenderer(size: size).image { _ in
                UIColor.white.setFill()
                UIRectFill(CGRect(origin: .zero, size: size))
                NSAttributedString(string: "Handwriting", attributes: [.font: UIFont.systemFont(ofSize: 34), .foregroundColor: UIColor.black])
                    .draw(at: CGPoint(x: 24, y: 24))
            }
            _ = HandwritingIndexer.recognizeText(in: words)
            let point = PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            _ = image(of: PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point], creationDate: .now))]))
        }
    }

    /// The ink as dark writing on white with room round it, large enough for small handwriting to be read.
    static func image(of drawing: PKDrawing, sides: CGFloat = 24) -> UIImage? {
        let bounds = drawing.bounds
        guard !drawing.strokes.isEmpty, !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        let frame = bounds.insetBy(dx: -sides, dy: -24)
        let scale = min(max(2400 / max(frame.width, frame.height), 1), 3)
        var ink: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: frame, scale: scale)
        }
        guard let ink else { return nil }
        let format = UIGraphicsImageRendererFormat(scale: scale, opaque: true)
        return UIGraphicsImageRenderer(size: frame.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: frame.size))
            ink.draw(in: CGRect(origin: .zero, size: frame.size))
        }
    }

    /// A text box that takes the place of handwriting: where it was, about as large, and kept on the page.
    static func box(for text: String, replacing bounds: CGRect, pageSize: CGSize) -> PageItem {
        let lines = max(text.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
        var box = TextBox(string: text)
        box.fontSize = min(max((bounds.height / CGFloat(lines) * 0.62).rounded(), 13), 34)
        let room = max(pageSize.width - 24, 60)
        let width = min(max(box.naturalWidth(limit: room), min(bounds.width, room), 60), room)
        let size = CGSize(width: width, height: box.height(width: width))
        let x = min(max(bounds.minX, 12), max(pageSize.width - 12 - width, 12))
        let y = min(max(bounds.minY, 12), max(pageSize.height - 12 - size.height, 12))
        return PageItem(content: .text(box), center: CGPoint(x: x + width / 2, y: y + size.height / 2), size: size)
    }
}
