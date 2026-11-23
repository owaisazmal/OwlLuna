import UIKit
import PencilKit

/// Cuts a piece out of a page for a flashcard: the paper, the ink and what is placed on it, as they look. Thread-safe.
enum CardClipping {
    static let scale: CGFloat = 2

    /// A tape card's two clippings, what they read as, and the part of the page they were cut from.
    struct TapeCut: Sendable {
        let front: UIImage
        let back: UIImage
        let frontText: String?
        let backText: String?
        let clip: CardClip?
    }

    /// The fixed area round a strip of study tape: the line it covers and a little of what is round it. Every tape card
    /// was cut from it before a card kept its own area, and a new card's area is never smaller.
    static func region(around tape: PageItem, on page: NotebookPage) -> CGRect {
        fitted(fixed(around: tape), to: page)
    }

    private static func fixed(around tape: PageItem) -> CGRect {
        let box = tape.boundingBox
        let reach = max((420 - box.width) / 2, 90)
        return box.insetBy(dx: -reach, dy: -64)
    }

    /// The area a new tape card starts with: the fixed one, grown to the whole line the tape is on and the lines that run
    /// on above and below it.
    static func startingRegion(around tape: PageItem, on page: NotebookPage, ink: PKDrawing, assets: URL) -> CGRect {
        let found = CardArea.marks(near: tape, on: page, ink: ink, assets: assets)
        return fitted(CardArea.region(around: tape, fixed: fixed(around: tape), marks: found.marks, held: found.held,
                                      limit: CardArea.limit(round: tape, on: page)), to: page)
    }

    /// What a card's clippings show now: the area kept with it, or the fixed one round the tape for a card that kept
    /// none or whose tape has since been moved out of it.
    static func region(of clip: CardClip?, tape: PageItem, on page: NotebookPage) -> CGRect {
        let box = tape.boundingBox.intersection(CGRect(origin: .zero, size: page.size))
        guard let kept = clip.map({ fitted($0.region, to: page) }), kept.contains(box) else { return region(around: tape, on: page) }
        return kept
    }

    static func region(around ink: PKDrawing, on page: NotebookPage) -> CGRect {
        fitted(ink.bounds.insetBy(dx: -18, dy: -18), to: page)
    }

    /// `rect` in whole points, and no more of it than the page has.
    static func fitted(_ rect: CGRect, to page: NotebookPage) -> CGRect {
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

    /// The two sides of a card made from a strip of study tape: `region` of the page with the tape on, and with it
    /// lifted. Without a region, the one a new card starts with.
    static func tapeSides(_ tape: PageItem, on page: NotebookPage, ink: PKDrawing, assets: URL, region: CGRect? = nil) -> (front: UIImage, back: UIImage) {
        let region = region ?? startingRegion(around: tape, on: page, ink: ink, assets: assets)
        return (image(of: page, ink: ink, assets: assets, region: region),
                image(of: page, ink: ink, assets: assets, region: region, lifted: [tape.id], revealed: tape))
    }

    /// The words of a tape card's sides, read from the answer: on the question, those under the tape are one blank.
    static func tapeText(_ tape: PageItem, region: CGRect, answer: UIImage) async -> (front: String?, back: String?) {
        tapeText(PageWords.words(in: await NotebookFind.readInBackground(answer) ?? [], size: region.size), tape: tape, region: region)
    }

    /// Both sides of a tape card cut from `region`, read, and with the record of where they came from. A card is made
    /// this way, and cut again this way when its area is changed.
    static func cut(_ tape: PageItem, on page: NotebookPage, ink: PKDrawing, assets: URL, region: CGRect) async -> TapeCut {
        let region = fitted(region, to: page)
        let sides = tapeSides(tape, on: page, ink: ink, assets: assets, region: region)
        let words = await tapeText(tape, region: region, answer: sides.back)
        return TapeCut(front: sides.front, back: sides.back, frontText: words.front, backText: words.back, clip: CardClip(region: region, tape: tape))
    }

    /// `window` of a page with its tape on, for choosing a card's area from: all of an ordinary page, a piece of a whiteboard.
    static func picture(of page: NotebookPage, ink: PKDrawing, assets: URL, window: CGRect) -> UIImage {
        let shown = page.isBoard && page.cut == nil ? Whiteboard.piece(of: page, in: window) : page
        return PageRenderer.image(of: shown, ink: ink, assets: assets, width: shown.size.width, scale: Whiteboard.scale(for: shown.size, wanted: scale, limit: 3200))
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
