import UIKit
import PencilKit

/// Cuts a piece out of a page for a flashcard: the paper, the ink and what is placed on it, as they look. Thread-safe.
enum CardClipping {
    static let scale: CGFloat = 2

    /// The part of the page a strip of study tape sits in: the line it covers and a little of what is round it.
    static func region(around tape: PageItem, on page: NotebookPage) -> CGRect {
        let box = tape.boundingBox
        let reach = max((420 - box.width) / 2, 90)
        return fitted(box.insetBy(dx: -reach, dy: -64), to: page)
    }

    static func region(around ink: PKDrawing, on page: NotebookPage) -> CGRect {
        fitted(ink.bounds.insetBy(dx: -18, dy: -18), to: page)
    }

    private static func fitted(_ rect: CGRect, to page: NotebookPage) -> CGRect {
        let cut = rect.intersection(CGRect(origin: .zero, size: page.size)).integral
        guard cut.isNull || cut.width < 8 || cut.height < 8 else { return cut }
        return page.isBoard ? CGRect(x: rect.midX - 210, y: rect.midY - 150, width: 420, height: 300).integral : CGRect(origin: .zero, size: page.size)
    }

    /// `region` of the page. Tape named in `lifted` is taken off; `revealed` is left as the outline of where it was.
    static func image(of page: NotebookPage, ink: PKDrawing, assets: URL, region: CGRect, lifted: Set<UUID> = [], revealed: PageItem? = nil) -> UIImage {
        if page.isBoard, page.cut == nil {
            // Only the piece is drawn: a whiteboard is far too large to draw whole and cut down.
            var moved = revealed
            moved?.center = CGPoint(x: (revealed?.center.x ?? 0) - region.minX, y: (revealed?.center.y ?? 0) - region.minY)
            return image(of: Whiteboard.piece(of: page, in: region), ink: ink, assets: assets, region: CGRect(origin: .zero, size: region.size),
                         lifted: lifted, revealed: moved)
        }
        let whole = PageRenderer.image(of: page, ink: ink, assets: assets, width: page.size.width, scale: scale, lifted: lifted)
        let format = UIGraphicsImageRendererFormat(scale: scale, opaque: true)
        return UIGraphicsImageRenderer(size: region.size, format: format).image { context in
            let ctx = context.cgContext
            ctx.translateBy(x: -region.minX, y: -region.minY)
            whole.draw(in: CGRect(origin: .zero, size: page.size))
            guard let revealed, let color = revealed.tape else { return }
            ctx.translateBy(x: revealed.center.x, y: revealed.center.y)
            ctx.rotate(by: revealed.rotation)
            TapeArt.draw(color, lifted: true, in: ctx,
                         rect: CGRect(x: -revealed.size.width / 2, y: -revealed.size.height / 2, width: revealed.size.width, height: revealed.size.height))
        }
    }

    /// The two sides of a card made from a strip of study tape: the page with the tape on, and with it lifted.
    static func tapeSides(_ tape: PageItem, on page: NotebookPage, ink: PKDrawing, assets: URL) -> (front: UIImage, back: UIImage) {
        let region = region(around: tape, on: page)
        return (image(of: page, ink: ink, assets: assets, region: region),
                image(of: page, ink: ink, assets: assets, region: region, lifted: [tape.id], revealed: tape))
    }

    /// The words of a tape card's sides, read from the answer: on the question, those under the tape are one blank.
    static func tapeText(_ tape: PageItem, on page: NotebookPage, answer: UIImage) async -> (front: String?, back: String?) {
        let region = region(around: tape, on: page)
        return tapeText(PageWords.words(in: await NotebookFind.readInBackground(answer) ?? [], size: region.size), tape: tape, region: region)
    }

    /// `words` lie in `region`, measured from its corner.
    static func tapeText(_ words: [PageWords.Word], tape: PageItem, region: CGRect) -> (front: String?, back: String?) {
        let read = words.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !read.isEmpty else { return (nil, nil) }
        let toTape = tape.placement.inverted(), strip = CGRect(origin: .zero, size: tape.size)
        var front: [String] = [], hiding = false
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let dx = word.end.x - word.start.x, dy = word.end.y - word.start.y, length = max(hypot(dx, dy), 0.001)
            let middle = CGPoint(x: region.minX + (word.start.x + word.end.x) / 2 + dy / length * word.height / 2,
                                 y: region.minY + (word.start.y + word.end.y) / 2 - dx / length * word.height / 2)
            let hidden = strip.contains(middle.applying(toTape))
            if !hidden { front.append(text) } else if !hiding { front.append(String(localized: "card.blank", defaultValue: "blank")) }
            hiding = hidden
        }
        return (front.joined(separator: " "), read.joined(separator: " "))
    }

    /// Selected handwriting on its own paper, one page's piece under another.
    static func inkImage(_ pieces: [(page: NotebookPage, ink: PKDrawing)], assets: URL) -> UIImage? {
        let cuts = pieces.prefix(3).compactMap { piece -> UIImage? in
            guard !piece.ink.strokes.isEmpty else { return nil }
            var bare = piece.page
            bare.items = []
            return image(of: bare, ink: piece.ink, assets: assets, region: region(around: piece.ink, on: piece.page))
        }
        guard let first = cuts.first else { return nil }
        guard cuts.count > 1 else { return first }
        let width = cuts.map(\.size.width).max() ?? first.size.width
        let height = cuts.reduce(0) { $0 + $1.size.height } + CGFloat(cuts.count - 1) * 6
        let format = UIGraphicsImageRendererFormat(scale: scale)
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            var y: CGFloat = 0
            for cut in cuts {
                cut.draw(at: CGPoint(x: 0, y: y))
                y += cut.size.height + 6
            }
        }
    }
}
