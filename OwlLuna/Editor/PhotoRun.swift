import CoreGraphics

/// Where photos taken one after another land, in page points. They are sized to what was showing of the page when the
/// camera opened, two to its width; the first goes at its top left, each next one below the last, then in a column to
/// the right, and when the page is full the run goes on at the top of a new one.
struct PhotoRun: Equatable {
    static let gap: CGFloat = 12
    static let margin: CGFloat = 24

    /// What each photo is fitted into.
    let box: CGSize
    private(set) var bounds: CGRect
    private(set) var last: CGRect?
    private var start: CGPoint
    private var top: CGFloat = 0
    private var columnLeft: CGFloat = 0
    private var columnRight: CGFloat = 0

    init(visible: CGRect, bounds: CGRect) {
        let shown = visible.intersection(bounds)
        let area = shown.isNull || shown.width < 1 || shown.height < 1 ? bounds : shown
        box = CGSize(width: min((area.width - Self.gap) / 2, bounds.width), height: min(area.height * 0.45, bounds.height))
        start = area.origin
        self.bounds = bounds
    }

    func size(for picture: CGSize) -> CGSize {
        let fit = min(box.width / max(picture.width, 1), box.height / max(picture.height, 1))
        return CGSize(width: max((picture.width * fit).rounded(), PageItem.minimumSide),
                      height: max((picture.height * fit).rounded(), PageItem.minimumSide))
    }

    /// The frame for the next photo, or nil when there is no room left for it on this page.
    mutating func place(_ size: CGSize) -> CGRect? {
        let frame: CGRect
        if let last {
            let below = CGRect(origin: CGPoint(x: columnLeft, y: last.maxY + Self.gap), size: size)
            if below.maxY <= bounds.maxY, below.maxX <= bounds.maxX {
                frame = below
            } else {
                let beside = CGRect(origin: CGPoint(x: columnRight + Self.gap, y: top), size: size)
                guard beside.maxX <= bounds.maxX, beside.maxY <= bounds.maxY else { return nil }
                frame = beside
                columnLeft = beside.minX
            }
        } else {
            frame = CGRect(x: min(max(start.x, bounds.minX), max(bounds.maxX - size.width, bounds.minX)),
                           y: min(max(start.y, bounds.minY), max(bounds.maxY - size.height, bounds.minY)),
                           width: size.width, height: size.height)
            top = frame.minY
            columnLeft = frame.minX
            columnRight = frame.maxX
        }
        columnRight = max(columnRight, frame.maxX)
        last = frame
        return frame
    }

    /// Goes on at the top left of a fresh page.
    mutating func turnPage(to bounds: CGRect) {
        self.bounds = bounds
        last = nil
        start = bounds.origin
    }
}
