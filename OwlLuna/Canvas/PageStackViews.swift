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
    /// The highlighter's canvas, under this one: its ink is multiplied into a light page, so print shows through it.
    private(set) var ground: PageCanvasView?
    /// On the highlighter's canvas, the page's canvas it lies under.
    private(set) weak var sheet: PageCanvasView?
    /// PencilKit's own lasso is used on this canvas, so with it in hand all the ink is here.
    var lassoesItself = false
    private var lay = InkLay.apart
    private var drawsUnder = false
    /// Which of the page's strokes are the highlighter's, in the order the page keeps them.
    private var marks: [Bool] = []
    private var whole: PKDrawing?
    private var isLaying = false
    /// The canvas that is drawing ink a tool change moved to it. Until it has, the other goes on showing that ink.
    private weak var awaited: PageCanvasView?

    /// Where a page's ink lies: the highlighter's under and the rest over, or all of it on one of the two canvases.
    private enum InkLay { case apart, under, over }

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

    /// The stack scrolls, never the canvas. PencilKit turns the canvas's own pan back on after it drags a selection.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer !== panGestureRecognizer && super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    // MARK: The highlighter's canvas

    /// This canvas and the one under it.
    var both: [PageCanvasView] { ground.map { [self, $0] } ?? [self] }
    /// The page's canvas, asked of either of the two.
    var owner: PageCanvasView { sheet ?? self }

    /// Lays the highlighter's canvas under this one. It goes wherever this one is put.
    func layGround() {
        guard ground == nil, sheet == nil else { return }
        let under = PageCanvasView(frame: frame)
        under.sheet = self
        under.isAccessibilityElement = false
        under.accessibilityElementsHidden = true
        ground = under
        tint(under)
        if let superview { superview.insertSubview(under, belowSubview: self) }
    }

    private func tint(_ under: PageCanvasView) {
        under.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        under.layer.compositingFilter = overrideUserInterfaceStyle == .dark ? nil : "multiplyBlendMode"
    }

    override var overrideUserInterfaceStyle: UIUserInterfaceStyle {
        didSet { if let ground { tint(ground) } }
    }

    override var drawingPolicy: PKCanvasViewDrawingPolicy {
        didSet { ground?.drawingPolicy = drawingPolicy }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard let ground else { return }
        if let superview { superview.insertSubview(ground, belowSubview: self) } else { ground.removeFromSuperview() }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        drawsUnder ? nil : super.hitTest(point, with: event)
    }

    /// Both canvases are the same window onto the page: `frame`, with the page `content` large and scrolled to `offset`.
    func place(frame: CGRect, content: CGSize, offset: CGPoint, scale: CGFloat) {
        for canvas in both {
            if canvas.zoomScale != scale || canvas.minimumZoomScale != scale || canvas.maximumZoomScale != scale {
                canvas.minimumZoomScale = min(canvas.minimumZoomScale, scale)
                canvas.maximumZoomScale = max(canvas.maximumZoomScale, scale)
                canvas.zoomScale = scale
                canvas.minimumZoomScale = scale
                canvas.maximumZoomScale = scale
            }
            if canvas.frame != frame { canvas.frame = frame }
            if canvas.contentSize != content { canvas.contentSize = content }
            if canvas.contentOffset != offset { canvas.contentOffset = offset }
        }
    }

    /// Takes the tool in hand. The highlighter draws on the canvas under this one and the eraser rubs there: at the
    /// highlighter's ink alone, or at all the ink, which is put there for it.
    func take(_ tool: PKTool, ruler: Bool, highlighterOnly: Bool) {
        let erases = tool is PKEraserTool
        let lay: InkLay = lassoesItself && tool is PKLassoTool ? .over : erases && !highlighterOnly ? .under : .apart
        drawsUnder = ground != nil && lay != .over && (erases || (tool as? PKInkingTool)?.inkType == .marker)
        for canvas in both { canvas.tool = tool }
        isRulerActive = ruler && !drawsUnder
        ground?.isRulerActive = ruler && drawsUnder
        guard lay != self.lay, ground != nil else { return }
        let ink = ink
        self.lay = lay
        put(ink, handingOver: true)
    }

    var rulerIsOut: Bool { both.contains { $0.isRulerActive } }

    /// Whether a stroke is being drawn or rubbed out.
    var isInUse: Bool { both.contains { [.began, .changed].contains($0.drawingGestureRecognizer.state) } }

    /// All the page's ink, from both canvases, in the order the page keeps it.
    var ink: PKDrawing {
        get {
            guard let ground else { return drawing }
            if let whole { return whole }
            var merged = lay == .under ? ground.drawing : drawing
            let under = lay == .apart ? ground.drawing.strokes : []
            if !under.isEmpty {
                let over = drawing.strokes
                var strokes: [PKStroke] = []
                var u = 0, o = 0
                for mark in marks {
                    if mark, u < under.count {
                        strokes.append(under[u])
                        u += 1
                    } else if !mark, o < over.count {
                        strokes.append(over[o])
                        o += 1
                    }
                }
                merged = over.isEmpty ? ground.drawing : PKDrawing(strokes: strokes + over[o...] + under[u...])
            }
            marks = merged.strokes.map { $0.ink.inkType == .marker }
            whole = merged
            return merged
        }
        set { put(newValue, handingOver: false) }
    }

    /// Ink a tool change moves from one canvas to the other is taken off the first only once the second has drawn
    /// it, so it never blinks.
    private func put(_ ink: PKDrawing, handingOver: Bool) {
        guard let ground else { return drawing = ink }
        let strokes = ink.strokes
        marks = strokes.map { $0.ink.inkType == .marker }
        var under = PKDrawing(), over = PKDrawing()
        switch lay {
        case .under: under = ink
        case .over: over = ink
        case .apart where !marks.contains(true): over = ink
        case .apart where !marks.contains(false): under = ink
        case .apart:
            under = PKDrawing(strokes: zip(strokes, marks).filter { $0.1 }.map(\.0))
            over = PKDrawing(strokes: zip(strokes, marks).filter { !$0.1 }.map(\.0))
        }
        awaited = nil
        isLaying = true
        for (canvas, laid) in [(ground, under), (self, over)] where canvas.drawing != laid {
            if handingOver, laid.strokes.count < canvas.drawing.strokes.count { continue }
            canvas.drawing = laid
            if handingOver { awaited = canvas }
        }
        isLaying = false
        whole = ink
        guard handingOver else { return }
        guard let awaited else { return settle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak awaited] in
            if let awaited { self?.didFinishRendering(awaited) }
        }
    }

    /// Takes off each canvas the ink that has been handed to the other.
    private func settle() {
        awaited = nil
        guard let ground else { return }
        isLaying = true
        for canvas in both {
            let strokes = canvas.drawing.strokes
            let kept = strokes.filter { lay == .apart ? ($0.ink.inkType == .marker) == (canvas === ground) : (lay == .under) == (canvas === ground) }
            if kept.count != strokes.count { canvas.drawing = PKDrawing(strokes: kept) }
        }
        isLaying = false
    }

    func didFinishRendering(_ canvas: PageCanvasView) {
        if awaited === canvas { settle() }
    }

    /// The ink on one of the two canvases changed. Returns whether PencilKit changed it, and not this canvas laying it.
    func inkDidChange() -> Bool {
        guard !isLaying else { return false }
        if awaited != nil { settle() }
        whole = nil
        return true
    }

    /// PencilKit draws its tiles again only when the strokes change, so the canvas is emptied and given them back.
    func redrawTiles() {
        let strokes = drawing.strokes
        owner.isLaying = true
        drawing = PKDrawing()
        drawing = PKDrawing(strokes: strokes)
        owner.isLaying = false
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

    /// The page's own actions for assistive technologies, such as turning it in single flow.
    var pageActions: [UIAccessibilityCustomAction]?
    /// Asked each time the actions are read: pasting the clipboard's ink, while there is some.
    var pasteAction: (() -> UIAccessibilityCustomAction?)?

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let all = (pageActions ?? []) + [pasteAction?()].compactMap { $0 }
            return all.isEmpty ? nil : all
        }
        set { pageActions = newValue }
    }

    override var accessibilityValue: String? {
        get {
            let count = strokeCount ?? ink.strokes.count
            strokeCount = count
            return count == 0 ? String(localized: "canvas.empty", defaultValue: "Empty") : String(localized: "\(count) strokes")
        }
        set {}
    }
}

/// The page stack's scroll view. It leaves a drag to something else when asked, as when a finger lands on selected
/// ink, and holds its zoom while a handle is shaping that ink.
final class PageScrollView: UIScrollView {
    var yieldsDrag: ((UIPanGestureRecognizer) -> Bool)?
    var holdsZoom: (() -> Bool)?

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, yieldsDrag?(panGestureRecognizer) == true { return false }
        if gestureRecognizer === pinchGestureRecognizer, holdsZoom?() == true { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
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
                insertSubview(view, belowSubview: canvas.ground ?? canvas)
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
