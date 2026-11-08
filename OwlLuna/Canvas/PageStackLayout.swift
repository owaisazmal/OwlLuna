import UIKit

/// Page frames in page points, stacked vertically and centred on the widest page. A whiteboard has no size to
/// stack: among the pages it is a card, and once opened it is laid out alone, with every other page put away.
/// In single flow one page is laid out alone the same way, and the others wait their turn.
struct PageStackLayout {
    static let margin: CGFloat = 16

    private(set) var frames: [CGRect] = []
    private(set) var size = CGSize(width: 1, height: 1)
    /// The whiteboard that is open, in place of the stack.
    let solo: Int?
    /// The page shown on its own in single flow, when no whiteboard is open.
    let single: Int?

    init(pages: [NotebookPage] = [], solo: Int? = nil, single: Int? = nil) {
        self.solo = solo.flatMap { pages.indices.contains($0) && pages[$0].isBoard ? $0 : nil }
        if let solo = self.solo {
            self.single = nil
            frames = pages.indices.map { $0 == solo ? CGRect(origin: .zero, size: Whiteboard.size) : .zero }
            size = Whiteboard.size
            return
        }
        self.single = single.flatMap { pages.indices.contains($0) ? $0 : nil }
        let shown = self.single.map { [pages[$0]] } ?? pages
        let sheet = Self.sheetWidth(shown)
        let width = sheet + Self.margin * 2
        var y = Self.margin
        let stacked = shown.map { page in
            let size = page.isBoard ? CGSize(width: sheet, height: (sheet * Whiteboard.shownSize.height / Whiteboard.shownSize.width).rounded()) : page.size
            defer { y += size.height + Self.margin }
            return CGRect(x: ((width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height)
        }
        frames = self.single.map { single in pages.indices.map { $0 == single ? stacked[0] : .zero } } ?? stacked
        size = CGSize(width: width, height: max(y, 1))
    }

    /// The widest page that has a width; a whiteboard counts as a Letter page when there is none.
    static func sheetWidth(_ pages: [NotebookPage]) -> CGFloat {
        pages.lazy.filter { !$0.isBoard }.map(\.size.width).max() ?? Whiteboard.sheet.width
    }

    /// The page laid out in place of the stack, if one is.
    var alone: Int? { solo ?? single }

    /// Whether the page is on show at its own size: the open whiteboard, or any page but a whiteboard in the stack
    /// or on its own.
    func isLaidOut(_ index: Int, in pages: [NotebookPage]) -> Bool {
        guard pages.indices.contains(index), frames.indices.contains(index) else { return false }
        if let solo { return solo == index }
        return (single.map { $0 == index } ?? true) && !pages[index].isBoard
    }

    /// The page at `y`, counting the gap below a page as part of it.
    func pageIndex(atY y: CGFloat) -> Int {
        if let alone { return alone }
        guard !frames.isEmpty else { return 0 }
        var low = 0, high = frames.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY + Self.margin / 2 < y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func range(from top: CGFloat, to bottom: CGFloat) -> ClosedRange<Int>? {
        if let alone { return alone...alone }
        guard !frames.isEmpty else { return nil }
        let first = pageIndex(atY: top)
        var last = first
        while last + 1 < frames.count, frames[last + 1].minY <= bottom { last += 1 }
        return first...last
    }
}

extension CGRect {
    /// The rectangle with its origin and size multiplied by `scale`.
    func scaled(by scale: CGFloat) -> CGRect {
        CGRect(x: minX * scale, y: minY * scale, width: width * scale, height: height * scale)
    }
}
