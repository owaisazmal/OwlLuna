import UIKit
import PDFKit
import PencilKit

/// Where a tape card's clipping starts: the fixed area round the tape, grown to hold the line the tape is on from end
/// to end and the lines that run on above and below it. Thread-safe.
enum CardArea {
    /// How far past the tape the area grows: above and below it, and along its line on a whiteboard, which has no edge near.
    static let reach = CGSize(width: 400, height: 128)
    /// The room left round the writing the area grew to.
    static let margin = CGSize(width: 12, height: 10)

    /// Something written on the page. It belongs with what is no further from it than `gap`.
    struct Mark: Equatable, Sendable {
        var rect: CGRect
        var gap: CGSize

        /// A line of a PDF's own text: the next word is within a line's height, the next line within most of one.
        static func line(_ rect: CGRect) -> Mark {
            let unit = min(rect.width, rect.height)
            return Mark(rect: rect, gap: CGSize(width: unit, height: unit * 0.6))
        }

        /// A stroke of ink, measured by the tape that covers a line of it.
        static func stroke(_ rect: CGRect, breadth: CGFloat) -> Mark {
            Mark(rect: rect, gap: CGSize(width: breadth, height: breadth * 0.6))
        }
    }

    /// How tall a line the tape covers is taken to be.
    static func breadth(of tape: PageItem) -> CGFloat {
        min(max(min(tape.size.width, tape.size.height), 16), 36)
    }

    /// As far as the area round a strip of tape grows: `reach` above and below it, and from side to side of its page.
    static func limit(round tape: PageItem, on page: NotebookPage) -> CGRect {
        let tall = tape.boundingBox.insetBy(dx: 0, dy: -reach.height), whole = CGRect(origin: .zero, size: page.size)
        let wide = page.isBoard ? tall.insetBy(dx: -reach.width, dy: 0) : CGRect(x: 0, y: tall.minY, width: page.size.width, height: tall.height)
        return wide.intersection(whole)
    }

    /// `fixed` grown to the block of writing the tape is in: every mark within its gap of the tape and of what that reaches,
    /// and `held`, what is placed under the tape. Nothing past `limit` is taken, and no mark is cut through above or below.
    static func region(around tape: PageItem, fixed: CGRect, marks: [Mark], held: [CGRect], limit: CGRect) -> CGRect {
        let box = tape.boundingBox
        guard !limit.isNull else { return fixed }
        var block = held.reduce(box) { $0.union($1.intersection(limit)) }
        var waiting = marks.compactMap { mark -> Mark? in
            guard mark.rect.minY >= limit.minY, mark.rect.maxY <= limit.maxY else { return nil }
            let cut = mark.rect.intersection(limit)
            return cut.isNull || cut.isEmpty ? nil : Mark(rect: cut, gap: mark.gap)
        }
        var grew = true
        while grew {
            grew = false
            waiting.removeAll { mark in
                guard block.insetBy(dx: -mark.gap.width, dy: -mark.gap.height).intersects(mark.rect) else { return false }
                block = block.union(mark.rect)
                grew = true
                return true
            }
        }
        return fixed.union(block.insetBy(dx: -margin.width, dy: -margin.height))
    }

    /// What is written near a strip of tape, and what is placed under it.
    static func marks(near tape: PageItem, on page: NotebookPage, ink: PKDrawing, assets: URL) -> (marks: [Mark], held: [CGRect]) {
        let box = tape.boundingBox, breadth = breadth(of: tape), limit = limit(round: tape, on: page)
        // A stroke far taller than a line is a bracket or a frame, not writing.
        var marks = ink.strokes.map(\.renderBounds).filter { $0.intersects(limit) && $0.height <= breadth * 3 }.map { Mark.stroke($0, breadth: breadth) }
        if case .pdf(let file, let index) = page.background {
            marks += textLines(file: assets.appending(path: file), index: index, size: page.size).filter { $0.intersects(limit) }.map(Mark.line)
        }
        let held = page.hasItems ? page.items.filter { $0.id != tape.id && $0.tape == nil && $0.content != .unknown }.map(\.boundingBox).filter { $0.intersects(box) } : []
        return (marks, held)
    }

    private static let lines = LRUCache<[CGRect]>(capacity: 8)

    /// The lines of a PDF page's own text, in the page's points. Each page is read once, so a deck's cards are made quickly.
    static func textLines(file: URL, index: Int, size: CGSize) -> [CGRect] {
        let key = "\(file.path(percentEncoded: false))#\(index)|\(size.width)x\(size.height)"
        return lines.value(key) {
            guard let page = PDFDocument(url: file)?.page(at: index) else { return [] }
            return PDFText.lines(on: page, pageSize: size)
        } ?? []
    }

    /// A part of the page as a part of `window`'s unit square, as the crop frame measures it.
    static func unit(_ region: CGRect, in window: CGRect) -> CGRect {
        guard window.width > 0, window.height > 0 else { return PageItem.wholePicture }
        let inside = region.intersection(window)
        guard !inside.isNull else { return PageItem.wholePicture }
        return CGRect(x: (inside.minX - window.minX) / window.width, y: (inside.minY - window.minY) / window.height,
                      width: inside.width / window.width, height: inside.height / window.height)
    }

    /// The part of the page a crop of `window` frames, in whole points.
    static func region(_ crop: CGRect, of window: CGRect) -> CGRect {
        CGRect(x: window.minX + crop.minX * window.width, y: window.minY + crop.minY * window.height,
               width: crop.width * window.width, height: crop.height * window.height).integral.intersection(window)
    }

    /// What is shown for choosing an area from: all of an ordinary page, and of a whiteboard `area` with room on every side.
    static func window(showing area: CGRect, on page: NotebookPage) -> CGRect {
        let whole = CGRect(origin: .zero, size: page.size)
        guard page.isBoard, page.cut == nil else { return whole }
        let window = area.insetBy(dx: -300, dy: -300).intersection(whole).integral
        return window.isNull || window.isEmpty ? area : window
    }
}
