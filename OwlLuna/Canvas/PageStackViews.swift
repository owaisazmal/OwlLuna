import UIKit
import PencilKit

/// A canvas bound to one page. Its undo manager is a proxy so PencilKit never writes to the document stack.
final class PageCanvasView: PKCanvasView {
    var pageID: UUID?
    var isLoaded = false
    weak var undoProxy: UndoManager?
    /// Counted lazily, only when an assistive technology asks, and reset whenever the drawing changes.
    var strokeCount: Int?
    /// Renders still to be looked over for a lost tile after ink was put on from the page's side.
    var tileChecks = 0
    private let holdGuard = LoneFingerHoldGuard()
    /// How many of PencilKit's handwriting holds wait for the guard, for tests.
    private(set) var guardedHolds = 0

    override var undoManager: UndoManager? { undoProxy ?? super.undoManager }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(holdGuard)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if guardedHolds == 0 { guardedHolds = holdGuard.guardHolds(in: self) }
    }

    /// Whether a tile PencilKit has drawn is empty where a stroke runs through it. When memory runs short PencilKit
    /// can lose a tile's render and leave it blank until the strokes change.
    var hasBlankInkTile: Bool {
        let blank = tileLayers(in: self).filter { $0.contents == nil && !$0.isHidden }.map { $0.convert($0.bounds, to: layer) }
        let scale = zoomScale, ink = drawing
        guard !blank.isEmpty, blank.contains(where: { $0.intersects(ink.bounds.scaled(by: scale)) }) else { return false }
        for stroke in ink.strokes {
            let near = blank.filter { $0.intersects(stroke.renderBounds.scaled(by: scale)) }
            guard !near.isEmpty else { continue }
            for point in stroke.path.interpolatedPoints(by: .distance(4)) {
                let location = point.location.applying(stroke.transform)
                if near.contains(where: { $0.contains(CGPoint(x: location.x * scale, y: location.y * scale)) }) { return true }
            }
        }
        return false
    }

    private func tileLayers(in view: UIView) -> [CALayer] {
        guard NSStringFromClass(type(of: view)) == "PKCanvasAttachmentView" else { return view.subviews.flatMap { tileLayers(in: $0) } }
        return view.subviews.flatMap { holder in (holder.layer.sublayers ?? []).filter { $0.delegate == nil } }
    }

    override var accessibilityValue: String? {
        get {
            let count = strokeCount ?? drawing.strokes.count
            strokeCount = count
            return count == 0 ? String(localized: "canvas.empty", defaultValue: "Empty") : String(localized: "\(count) strokes")
        }
        set {}
    }
}

/// Stays first responder so the page stack's key commands work on every page, and routes ⌘Z to the document.
final class ResponderAnchor: UIView {
    weak var undoProxy: UndoManager?
    var onResign: (() -> Void)?
    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { undoProxy ?? super.undoManager }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }
}

/// Marks where the words being looked for are on a page. The match being shown is outlined as well as filled,
/// so it never stands out by colour alone. Each mark is its own small layer: a page zoomed to 5× is too large to draw whole.
final class FindHighlightView: UIView {
    private var marks: [CAShapeLayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ rects: [CGRect], current: CGRect?, scale: CGFloat, onDark: Bool) {
        while marks.count > rects.count { marks.removeLast().removeFromSuperlayer() }
        while marks.count < rects.count {
            let mark = CAShapeLayer()
            layer.addSublayer(mark)
            marks.append(mark)
        }
        CATransaction.withoutActions {
            for (mark, rect) in zip(marks, rects) {
                let box = rect.scaled(by: scale).insetBy(dx: -3, dy: -2)
                let shown = rect == current
                mark.path = CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil)
                mark.fillColor = UIColor(hex: 0xE8B023, alpha: shown ? 0.5 : 0.3).cgColor
                mark.strokeColor = shown ? UIColor(hex: onDark ? 0xF7F1E3 : 0x1B2230).cgColor : UIColor(hex: 0xB07F0E).cgColor
                mark.lineWidth = shown ? 2 : 1
            }
        }
    }
}

/// A whiteboard among the pages: what is on it, on a card that opens it. Nothing is written here.
final class BoardCardView: UIView {
    private let picture = UIImageView()
    private let chip = UIView()
    private let label = UILabel()
    private let symbol = UIImageView(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
    var onOpen: (() -> Void)?
    /// What the picture was drawn from, so it is only drawn again when that changes.
    var shownKey: String?

    var image: UIImage? {
        get { picture.image }
        set { picture.image = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.frame = bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(picture)

        chip.backgroundColor = .board
        chip.layer.borderColor = UIColor.hairline.resolvedColor(with: traitCollection).cgColor
        chip.layer.borderWidth = 1
        chip.layer.shadowColor = UIColor(hex: 0x3A2A12).cgColor
        chip.layer.shadowOpacity = 0.16
        chip.layer.shadowRadius = 3
        chip.layer.shadowOffset = CGSize(width: 0, height: 1)
        chip.isUserInteractionEnabled = false
        label.text = String(localized: "Open Whiteboard")
        let style = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .subheadline)
        label.font = UIFont(descriptor: style.withSymbolicTraits(.traitBold) ?? style, size: 0)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .ink
        symbol.tintColor = .ink
        let row = UIStackView(arrangedSubviews: [symbol, label])
        row.spacing = Space.x2
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(row)
        addSubview(chip)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: Space.x4),
            row.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -Space.x4),
            row.topAnchor.constraint(equalTo: chip.topAnchor, constant: Space.x2),
            row.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -Space.x2),
            chip.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            chip.centerXAnchor.constraint(equalTo: centerXAnchor),
            chip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Space.x5),
            chip.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -Space.x4),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(open)))
        addInteraction(UIPointerInteraction())
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Opens the whiteboard")
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (self: Self, _) in
            self.chip.layer.borderColor = UIColor.hairline.resolvedColor(with: self.traitCollection).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        chip.layer.cornerRadius = Radius.plate
    }

    @objc private func open() { onOpen?() }

    override func accessibilityActivate() -> Bool {
        onOpen?()
        return true
    }
}

final class PageSlotView: UIView {
    var page: NotebookPage
    /// Whether the app is showing light paper dark. The slot is made again when that changes.
    let night: Bool
    var paper: PagePaperView?
    var card: BoardCardView?
    weak var canvas: PageCanvasView?
    var findView: FindHighlightView?
    private(set) var itemViews: [UUID: PageItemView] = [:]

    /// Pictures, stickers, text and links sit above the paper and below the canvas, back to front. Study tape sits
    /// above the canvas, so it covers the ink.
    func syncItems(assets: URL, scale: CGFloat, links: LinkTitles, lifted: Set<UUID>, onActivate: @escaping (UUID) -> Void) {
        let items = page.items.filter { $0.content != .unknown }
        let keep = Set(items.map(\.id))
        for (id, view) in itemViews where !keep.contains(id) {
            view.removeFromSuperview()
            itemViews[id] = nil
        }
        for item in items {
            let view = itemViews[item.id] ?? PageItemView(item: item, assets: assets)
            view.update(item, onDark: page.isDark(night: night), links: links, lifted: lifted.contains(item.id))
            view.onActivate = onActivate
            view.layout(scale: scale)
            itemViews[item.id] = view
            if item.isOverInk {
                continue
            } else if let canvas, canvas.superview === self {
                insertSubview(view, belowSubview: canvas)
            } else {
                addSubview(view)
            }
        }
        raiseTape()
    }

    /// Puts the tape back over the canvas, after either was added. Each goes in just above the canvas, so the last
    /// strip in the page's list ends on top and whatever is selected stays above them all.
    func raiseTape() {
        for item in page.items.reversed() where item.isOverInk {
            guard let view = itemViews[item.id] else { continue }
            if let canvas, canvas.superview === self { insertSubview(view, aboveSubview: canvas) } else { addSubview(view) }
        }
    }

    func showLifted(_ lifted: Set<UUID>, links: LinkTitles) {
        for item in page.items where item.isOverInk {
            itemViews[item.id]?.update(item, onDark: page.isDark(night: night), links: links, lifted: lifted.contains(item.id))
        }
    }

    func layoutItems(scale: CGFloat) {
        for view in itemViews.values { view.layout(scale: scale) }
    }

    init(page: NotebookPage, night: Bool = false) {
        self.page = page
        self.night = night
        super.init(frame: .zero)
        backgroundColor = PageRenderer.paperColor(page.effectivePaperColor, night: page.turnsDark(night))
        clipsToBounds = true
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension CATransaction {
    /// Makes layer changes at once, without their implicit animations.
    static func withoutActions(_ changes: () -> Void) {
        begin()
        setDisableActions(true)
        changes()
        commit()
    }
}

extension UIView {
    /// Sets bounds and centre with the view unturned, then turns it by `transform`.
    func placeTurned(bounds: CGRect, center: CGPoint, transform: CGAffineTransform) {
        self.transform = .identity
        self.bounds = bounds
        self.center = center
        self.transform = transform
    }
}
