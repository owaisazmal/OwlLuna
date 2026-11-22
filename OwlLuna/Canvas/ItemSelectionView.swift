import UIKit

/// The stitched outline and handle round the selected item. It sits above the canvas, so touches on the item move
/// it instead of drawing. Every change is reported as a whole item; `final` marks the end of a gesture.
final class ItemSelectionView: UIView, UIGestureRecognizerDelegate {
    enum Side: CaseIterable { case top, left, bottom, right }
    /// What a handle does: the one knob resizes and turns, a text box's tab only resizes and its knob on a stalk only turns.
    enum Hold { case both, resize, turn }

    nonisolated static let outset: CGFloat = 8
    private static let handleSize: CGFloat = 44

    private(set) var item: PageItem
    var pageSize: CGSize
    var scale: CGFloat = 1
    /// How much of the page's top the editor's bars cover when the pages are scrolled to their top, in screen points.
    var covered: CGFloat = 0
    /// Width over height of the part of a picture that shows, as the file has it. Squeezing settles on it.
    var naturalAspect: () -> CGFloat? = { nil }
    var onChange: ((PageItem, _ final: Bool) -> Void)?
    /// Where it was tapped, in page points from the item's top left.
    var onTap: ((CGPoint) -> Void)?
    /// Brings the item a step forward or back among the page's items; false when it can go no further.
    var onLayer: ((_ forward: Bool) -> Bool)?
    /// While its text is being typed the outline stays and the handles step aside.
    var isEditing = false {
        didSet {
            isUserInteractionEnabled = !isEditing
            show(item)
        }
    }

    private let outline = CAShapeLayer()
    private let underline = CAShapeLayer()
    private let stalk = CAShapeLayer()
    private let stalkUnder = CAShapeLayer()
    private let handle = Handle()
    private let turner = Handle(hold: .turn)
    private let grips = Side.allCases.map { SideGrip(side: $0) }
    private var base: PageItem?
    private var pinch: CGFloat = 1
    private var twist: CGFloat = 0
    private(set) lazy var recognizers: [UIGestureRecognizer] = [
        GripPan(target: self, action: #selector(dragged)),
        UIPinchGestureRecognizer(target: self, action: #selector(pinched)),
        UIRotationGestureRecognizer(target: self, action: #selector(twisted)),
    ]
    private lazy var handlePan = GripPan(target: self, action: #selector(dragHandle))
    private lazy var turnPan = GripPan(target: self, action: #selector(dragHandle))
    /// Everything that is dragged apart from the item itself.
    private var handles: [UIView] { [handle, turner] + grips }

    init(item: PageItem, pageSize: CGSize) {
        self.item = item
        self.pageSize = pageSize
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = false
        for (layer, color, width) in [(underline, UIColor.ink.withAlphaComponent(0.55), 3.5 as CGFloat), (outline, UIColor.mustard, 2),
                                      (stalkUnder, UIColor.ink.withAlphaComponent(0.55), 3.5), (stalk, UIColor.mustard, 2)] {
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = width
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        outline.lineDashPattern = [7, 5]
        addSubview(handle)
        handle.addGestureRecognizer(handlePan)
        handle.accessibilityHint = String(localized: "Swipe up or down to make it larger or smaller.")
        handle.onStep = { [weak self] larger in self?.apply(.resize(larger: larger)) }
        addSubview(turner)
        turner.addGestureRecognizer(turnPan)
        turner.accessibilityIdentifier = "page.knob"
        turner.onStep = { [weak self] clockwise in self?.apply(.turn(clockwise: clockwise)) }
        (recognizers[0] as? UIPanGestureRecognizer)?.maximumNumberOfTouches = 1
        for recognizer in recognizers {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        for pan in [handlePan, turnPan] {
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
        }
        for grip in grips {
            addSubview(grip)
            grip.pan.addTarget(self, action: #selector(dragSide))
            grip.pan.delegate = self
            grip.onStep = { [weak self, side = grip.side] direction in self?.step(side, by: direction) }
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: ItemSelectionView, _) in view.colour() }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        // The knob stands off the box, so a tap on it is not a tap on the words.
        guard turner.isHidden || !turner.frame.contains(point) else { return }
        onTap?(CGPoint(x: (point.x - Self.outset) / max(scale, 0.01), y: (point.y - Self.outset) / max(scale, 0.01)))
    }

    required init?(coder: NSCoder) { fatalError() }

    var isChanging: Bool { base != nil }

    func show(_ newItem: PageItem) {
        item = newItem
        let outset = Self.outset
        placeTurned(bounds: CGRect(x: 0, y: 0, width: item.size.width * scale + outset * 2, height: item.size.height * scale + outset * 2),
                    center: CGPoint(x: item.center.x * scale, y: item.center.y * scale), transform: CGAffineTransform(rotationAngle: item.rotation))
        let path = UIBezierPath(roundedRect: bounds.insetBy(dx: outset / 2, dy: outset / 2), cornerRadius: 4).cgPath
        CATransaction.withoutActions {
            outline.path = path
            underline.path = path
        }
        colour()
        let layout = ItemHandleLayout(item: item, page: pageSize, scale: scale, covered: covered)
        let hasGrip = item.text != nil || item.tape != nil, squeezes = item.assetFile != nil
        // A text box has a tab that resizes it and a knob that turns it; anything else has the one knob for both.
        handle.hold = item.text == nil ? .both : .resize
        handle.center = layout.corner
        handle.isHidden = isEditing
        handle.accessibilityValue = item.text == nil ? item.spokenSize : item.spokenSides
        handle.accessibilityCustomActions = arrangeActions
        let knob = layout.knob
        turner.center = knob.center
        turner.isHidden = isEditing || item.text == nil
        turner.accessibilityValue = item.spokenTurn
        let stem = UIBezierPath()
        stem.move(to: knob.foot)
        stem.addLine(to: knob.center)
        CATransaction.withoutActions {
            stalk.path = turner.isHidden ? nil : stem.cgPath
            stalkUnder.path = stalk.path
        }
        for grip in grips {
            let across = grip.side == .top || grip.side == .bottom
            // A picture's grips stand only where they are clear of the corner handle.
            let room = (across ? bounds.width : bounds.height) - outset * 2 >= Self.handleSize * 2
            grip.isHidden = isEditing || !(hasGrip ? grip.side == .right : squeezes && room)
            grip.center = layout.grip(grip.side)
            grip.show(item)
        }
    }

    private func colour() {
        CATransaction.withoutActions {
            outline.strokeColor = UIColor.mustard.resolvedColor(with: traitCollection).cgColor
            underline.strokeColor = UIColor.ink.resolvedColor(with: traitCollection).withAlphaComponent(0.55).cgColor
            stalk.strokeColor = outline.strokeColor
            stalkUnder.strokeColor = underline.strokeColor
        }
        for handle in [handle, turner] { handle.colour(traitCollection) }
        for grip in grips { grip.colour(traitCollection) }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) || handles.contains { !$0.isHidden && $0.frame.contains(point) }
    }

    /// Where two handles' fingertip rooms overlap, on a small box, the nearer one takes the touch.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, self.point(inside: point, with: event) else { return nil }
        func distance(_ view: UIView) -> CGFloat { hypot(view.center.x - point.x, view.center.y - point.y) }
        return handles.filter { !$0.isHidden && $0.frame.contains(point) }.min { distance($0) < distance($1) } ?? self
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        recognizers.contains(gestureRecognizer) && recognizers.contains(other)
    }

    /// The page's own scroll and zoom wait for these, so two fingers on the item resize it and don't zoom the page.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView
    }

    private func begin() {
        if base == nil {
            base = item
            pinch = 1
            twist = 0
        }
    }

    /// The item with its centre kept on the page.
    private func keptOnPage(_ changed: PageItem) -> PageItem {
        var changed = changed
        changed.center.x = min(max(changed.center.x, 0), pageSize.width)
        changed.center.y = min(max(changed.center.y, 0), pageSize.height)
        return changed
    }

    private func report(_ changed: PageItem, state: UIGestureRecognizer.State) {
        let changed = keptOnPage(changed)
        let others = (recognizers + [handlePan, turnPan] + grips.map(\.pan)).contains { $0.state == .began || $0.state == .changed }
        switch state {
        case .changed:
            onChange?(changed, false)
        case .ended where others:
            onChange?(changed, false)
        case .ended:
            base = nil
            onChange?(changed, true)
        case .cancelled, .failed:
            guard !others, let base else { return }
            self.base = nil
            onChange?(base, false)
        default:
            break
        }
    }

    private func composed(from base: PageItem, translation: CGPoint = .zero) -> PageItem {
        var changed = Self.arranged(base, pinch: pinch, twist: twist, limit: max(pageSize.width, pageSize.height) * 1.5)
        changed.center = CGPoint(x: item.center.x + translation.x, y: item.center.y + translation.y)
        return changed
    }

    /// `base` scaled by `pinch` and turned by `twist`, settling on the quarter turns. With no turn asked it keeps the one it has.
    nonisolated static func arranged(_ base: PageItem, pinch: CGFloat, twist: CGFloat, limit: CGFloat) -> PageItem {
        var changed = base.scaled(by: pinch, limit: limit)
        if twist != 0 { changed.rotation = snapped(base.rotation + twist) }
        return changed
    }

    /// Settles on the quarter turns when within three degrees of one.
    nonisolated static func snapped(_ angle: CGFloat) -> CGFloat {
        let quarter = CGFloat.pi / 2
        let nearest = (angle / quarter).rounded() * quarter
        return abs(angle - nearest) < 3 * .pi / 180 ? nearest : angle
    }

    @objc private func dragged(_ gesture: GripPan) {
        guard let superview else { return }
        if gesture.state == .began {
            begin()
            let point = gesture.location(in: superview), down = gesture.start(in: superview)
            gesture.setTranslation(CGPoint(x: point.x - down.x, y: point.y - down.y), in: superview)
            return
        }
        guard let base else { return }
        let moved = gesture.translation(in: superview)
        gesture.setTranslation(.zero, in: superview)
        report(composed(from: base, translation: CGPoint(x: moved.x / max(scale, 0.01), y: moved.y / max(scale, 0.01))), state: gesture.state)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { begin() }
        guard let base else { return }
        pinch = gesture.scale
        report(composed(from: base), state: gesture.state)
    }

    @objc private func twisted(_ gesture: UIRotationGestureRecognizer) {
        if gesture.state == .began { begin() }
        guard let base else { return }
        twist = gesture.rotation
        report(composed(from: base), state: gesture.state)
    }

    @objc private func dragHandle(_ gesture: GripPan) {
        guard let superview, let hold = (gesture.view as? Handle)?.hold else { return }
        if gesture.state == .began { begin() }
        guard let base else { return }
        let point = gesture.location(in: superview), start = gesture.start(in: superview), unit = 1 / max(scale, 0.01)
        (pinch, twist) = Self.change(dragging: hold, of: base, from: CGPoint(x: start.x * unit, y: start.y * unit),
                                     to: CGPoint(x: point.x * unit, y: point.y * unit), rise: ItemHandleLayout.rise * unit)
        report(composed(from: base), state: gesture.state)
    }

    /// How much larger and how far round a drag on a handle makes the item, in page points, as if it were held at its own place.
    nonisolated static func change(dragging hold: Hold, of base: PageItem, from start: CGPoint, to point: CGPoint, rise: CGFloat) -> (pinch: CGFloat, twist: CGFloat) {
        let moved = CGPoint(x: point.x - start.x, y: point.y - start.y), turn = base.rotation
        func round(from: CGPoint) -> CGFloat {
            remainder(atan2(from.y + moved.y, from.x + moved.x) - atan2(from.y, from.x), 2 * .pi)
        }
        if hold == .turn {
            let from = CGPoint(x: start.x - base.center.x, y: start.y - base.center.y), length = hypot(from.x, from.y)
            let reach = max(length, base.size.height / 2 + rise, 1)
            let arm = length < 0.01 ? CGPoint(x: reach * sin(turn), y: -reach * cos(turn)) : CGPoint(x: from.x * reach / length, y: from.y * reach / length)
            return (1, round(from: arm))
        }
        let x = (base.text != nil || base.tape != nil ? -0.5 : 0.5) * base.size.width, y = base.size.height / 2
        let corner = CGPoint(x: x * cos(turn) - y * sin(turn), y: x * sin(turn) + y * cos(turn)), length = max(hypot(corner.x, corner.y), 1)
        if hold == .resize { return (max(1 + (moved.x * corner.x + moved.y * corner.y) / (length * length), 0.01), 0) }
        return (max(hypot(corner.x + moved.x, corner.y + moved.y) / length, 0.01), round(from: corner))
    }

    /// A side grip moves its side and holds the opposite one still: a picture is squeezed, a text box wraps again and
    /// grows downwards, tape gets longer.
    @objc private func dragSide(_ gesture: GripPan) {
        guard let superview, let side = (gesture.view as? SideGrip)?.side else { return }
        if gesture.state == .began { begin() }
        guard let base else { return }
        let point = gesture.location(in: superview), start = gesture.start(in: superview), turn = base.rotation
        let moved = CGPoint(x: point.x - start.x, y: point.y - start.y)
        let along = side == .left || side == .right ? moved.x * cos(turn) + moved.y * sin(turn) : moved.y * cos(turn) - moved.x * sin(turn)
        let outwards = side == .left || side == .top ? -along : along
        report(stretched(base, side: side, by: outwards / max(scale, 0.01)), state: gesture.state)
    }

    /// A step from VoiceOver or the keyboard, as one undo step. Returns the item as it now is, or nil when it couldn't
    /// go further or a gesture is changing it.
    @discardableResult
    func apply(_ step: ItemStep) -> PageItem? {
        guard base == nil, !isEditing else { return nil }
        let changed = step.applied(to: item, page: pageSize)
        guard changed != item else { return nil }
        onChange?(changed, true)
        return changed
    }

    /// VoiceOver's actions on the selection, which the selected item offers too. Tape lies over the ink, so it has no
    /// place among the others to move to.
    var arrangeActions: [UIAccessibilityCustomAction] { item.tape == nil ? steps + layers : steps }

    private lazy var steps: [UIAccessibilityCustomAction] = {
        let move = ItemStep.spokenMove
        let moves = [(String(localized: "Move Up"), CGSize(width: 0, height: -move)), (String(localized: "Move Down"), CGSize(width: 0, height: move)),
                     (String(localized: "Move Left"), CGSize(width: -move, height: 0)), (String(localized: "Move Right"), CGSize(width: move, height: 0))]
        let turns = [(String(localized: "Rotate Left"), false), (String(localized: "Rotate Right"), true)]
        return moves.map { name, offset in spoken(name, .move(offset), saying: \.spokenPlace) }
            + turns.map { name, clockwise in spoken(name, .turn(clockwise: clockwise), saying: \.spokenTurn) }
    }()

    private lazy var layers = [(String(localized: "Bring Forward"), true), (String(localized: "Send Backward"), false)].map { name, forward in
        UIAccessibilityCustomAction(name: name) { [weak self] _ in self?.onLayer?(forward) ?? false }
    }

    private func spoken(_ name: String, _ step: ItemStep, saying words: KeyPath<PageItem, String>) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: name) { [weak self] _ in
            guard let changed = self?.apply(step) else { return false }
            UIAccessibility.post(notification: .announcement, argument: changed[keyPath: words])
            return true
        }
    }

    /// VoiceOver's swipes on a grip: a tenth wider or taller, or narrower or shorter, as one undo step.
    private func step(_ side: Side, by direction: CGFloat) {
        guard base == nil else { return }
        let length = side == .left || side == .right ? item.size.width : item.size.height
        let changed = keptOnPage(stretched(item, side: side, by: length * 0.1 * direction))
        onChange?(changed, true)
    }

    private func stretched(_ item: PageItem, side: Side, by amount: CGFloat) -> PageItem {
        let limit = item.text != nil || item.tape != nil ? pageSize.width * 1.5 : max(pageSize.width, pageSize.height) * 1.5
        return Self.stretched(item, side: side, by: amount, limit: limit, natural: naturalAspect())
    }

    /// `side` moved out by `amount` page points, or in for a negative amount, with the opposite side held still. A text box
    /// or tape only gets wider. A picture is squeezed, and settles on its `natural` proportions within 3% of them.
    static func stretched(_ item: PageItem, side: Side, by amount: CGFloat, limit: CGFloat, natural: CGFloat? = nil) -> PageItem {
        if item.text != nil || item.tape != nil {
            let width = min(max(item.size.width + amount, min(PageItem.minimumWidth, item.size.width)), max(limit, item.size.width))
            return item.resized(to: CGSize(width: width, height: item.text?.height(width: width) ?? item.size.height))
        }
        let wide = side == .left || side == .right
        var size = item.size
        if wide { size.width += amount } else { size.height += amount }
        if let natural, natural > 0, size.width > 0, size.height > 0, abs(size.width / size.height / natural - 1) < 0.03 {
            if wide { size.width = size.height * natural } else { size.height = size.width / natural }
        }
        size.width = min(max(size.width, PageItem.minimumSide), limit)
        size.height = min(max(size.height, PageItem.minimumSide), limit)
        let held = switch side {
        case .top: CGPoint(x: 0.5, y: 1)
        case .left: CGPoint(x: 1, y: 0.5)
        case .bottom: CGPoint(x: 0.5, y: 0)
        case .right: CGPoint(x: 0, y: 0.5)
        }
        return item.resized(to: size, holding: held)
    }
}

/// The corner handle or a text box's knob, drawn as the lasso's box draws its own. VoiceOver swipes it a step at a time.
private final class Handle: UIView {
    var hold: ItemSelectionView.Hold {
        didSet { if hold != oldValue { dress() } }
    }
    var onStep: ((_ up: Bool) -> Void)?
    private let shape = UIImageView()

    init(hold: ItemSelectionView.Hold = .both) {
        self.hold = hold
        super.init(frame: CGRect(x: 0, y: 0, width: InkBoxLayout.reach * 2, height: InkBoxLayout.reach * 2))
        shape.backgroundColor = Grip.fill
        shape.layer.borderWidth = 1
        shape.tintColor = Grip.ink
        shape.contentMode = .center
        addSubview(shape)
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        dress()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func dress() {
        let side = hold == .resize ? Grip.tab : Grip.knob
        shape.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        shape.layer.cornerRadius = hold == .resize ? 2 : side / 2
        shape.image = switch hold {
        case .both: UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: Grip.symbol)
        case .resize: nil
        case .turn: UIImage(systemName: "arrow.clockwise", withConfiguration: Grip.symbol)
        }
        accessibilityLabel = switch hold {
        case .both: String(localized: "Resize and rotate")
        case .resize: String(localized: "Resize")
        case .turn: String(localized: "Rotate")
        }
    }

    func colour(_ traits: UITraitCollection) {
        shape.layer.borderColor = Grip.edge(traits)
    }

    override func accessibilityIncrement() { onStep?(true) }
    override func accessibilityDecrement() { onStep?(false) }
}

/// Where a selected item's handles stand, in the selection's own points. One past the page's edge slides along its side to stay on the page.
struct ItemHandleLayout {
    /// A handle's middle keeps this far inside the page, so all of its shape shows.
    static let margin: CGFloat = 14
    /// How far above the item's top edge the middle of a text box's knob stands, in screen points.
    static let rise = ItemSelectionView.outset / 2 + InkBoxLayout.stalk

    let item: PageItem
    let page: CGSize
    let scale: CGFloat
    /// How much of the page's top the editor's bars cover, in screen points. The knob keeps clear of it.
    var covered: CGFloat = 0

    /// The selection's own size: the item on the screen and the outline's room round it.
    var size: CGSize {
        CGSize(width: item.size.width * scale + ItemSelectionView.outset * 2, height: item.size.height * scale + ItemSelectionView.outset * 2)
    }

    /// A corner of the outline: (0, 0) is its top left.
    private func spot(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let inset = ItemSelectionView.outset / 2
        return CGPoint(x: x == 0 ? inset : size.width - inset, y: y == 0 ? inset : size.height - inset)
    }

    /// One of the selection's own points on the page, in screen points from the page's top left.
    func onPage(_ point: CGPoint) -> CGPoint {
        let x = point.x - size.width / 2, y = point.y - size.height / 2, turn = item.rotation
        return CGPoint(x: item.center.x * scale + x * cos(turn) - y * sin(turn), y: item.center.y * scale + x * sin(turn) + y * cos(turn))
    }

    private func own(_ point: CGPoint) -> CGPoint {
        let x = point.x - item.center.x * scale, y = point.y - item.center.y * scale, turn = item.rotation
        return CGPoint(x: size.width / 2 + x * cos(turn) + y * sin(turn), y: size.height / 2 + y * cos(turn) - x * sin(turn))
    }

    /// Where a handle's middle may stand on the page.
    private var room: CGRect {
        let width = page.width * scale, height = page.height * scale, margin = min(Self.margin, width / 2, height / 2)
        return CGRect(x: margin, y: margin, width: width - margin * 2, height: height - margin * 2)
    }

    /// The same for the knob, clear of the bars as well where the page is tall enough for that.
    private var knobRoom: CGRect {
        let room = room, top = max(room.minY, covered + Self.margin)
        return top < room.maxY ? CGRect(x: room.minX, y: top, width: room.width, height: room.maxY - top) : room
    }

    private func isIn(_ room: CGRect, _ point: CGPoint) -> Bool {
        room.insetBy(dx: -0.01, dy: -0.01).contains(onPage(point))
    }

    /// The place in `room` nearest `home` along a side of the outline, `off` it; nil when none of the side is in it.
    private func slid(from start: CGPoint, to end: CGPoint, home: CGFloat, off: CGPoint = .zero, in room: CGRect) -> (center: CGPoint, foot: CGPoint, travel: CGFloat)? {
        let first = onPage(CGPoint(x: start.x + off.x, y: start.y + off.y)), last = onPage(CGPoint(x: end.x + off.x, y: end.y + off.y))
        let along = CGPoint(x: last.x - first.x, y: last.y - first.y)
        var low: CGFloat = 0, high: CGFloat = 1
        for (step, slack) in [(-along.x, first.x - room.minX), (along.x, room.maxX - first.x), (-along.y, first.y - room.minY), (along.y, room.maxY - first.y)] {
            if abs(step) < 1e-9 {
                if slack < -0.01 { return nil }
            } else if step < 0 {
                low = max(low, slack / step)
            } else {
                high = min(high, slack / step)
            }
        }
        guard low <= high + 1e-9 else { return nil }
        let part = min(max(home, low), max(high, low))
        let foot = CGPoint(x: start.x + (end.x - start.x) * part, y: start.y + (end.y - start.y) * part)
        return (CGPoint(x: foot.x + off.x, y: foot.y + off.y), foot, abs(part - home) * hypot(along.x, along.y))
    }

    /// `point` moved the least it takes to stand in `room`.
    private func kept(_ point: CGPoint, in room: CGRect) -> CGPoint {
        let at = onPage(point)
        return own(CGPoint(x: min(max(at.x, room.minX), room.maxX), y: min(max(at.y, room.minY), room.maxY)))
    }

    /// The corner handle. A text box or a strip of tape keeps its right edge for the width grip, so theirs is on the left.
    var corner: CGPoint {
        let x: CGFloat = item.text != nil || item.tape != nil ? 0 : 1, home = spot(x, 1)
        if isIn(room, home) { return home }
        let slides = [slid(from: home, to: spot(1 - x, 1), home: 0, in: room), slid(from: home, to: spot(x, 0), home: 0, in: room)].compactMap { $0 }
        return slides.min { $0.travel < $1.travel }?.center ?? kept(home, in: room)
    }

    func grip(_ side: ItemSelectionView.Side) -> CGPoint {
        let ends = switch side {
        case .top: (spot(0, 0), spot(1, 0))
        case .left: (spot(0, 0), spot(0, 1))
        case .bottom: (spot(0, 1), spot(1, 1))
        case .right: (spot(1, 0), spot(1, 1))
        }
        return slid(from: ends.0, to: ends.1, home: 0.5, in: room)?.center
            ?? kept(CGPoint(x: (ends.0.x + ends.1.x) / 2, y: (ends.0.y + ends.1.y) / 2), in: room)
    }

    /// A text box's knob and its stalk's foot: over the top, under the foot where there is no room above, slid like the rest.
    var knob: (center: CGPoint, foot: CGPoint) {
        let room = knobRoom, stalk = InkBoxLayout.stalk
        let above = (spot(0, 0), spot(1, 0), CGPoint(x: 0, y: -stalk)), below = (spot(0, 1), spot(1, 1), CGPoint(x: 0, y: stalk))
        for side in [above, below] {
            let foot = CGPoint(x: (side.0.x + side.1.x) / 2, y: side.0.y), home = CGPoint(x: foot.x, y: foot.y + side.2.y)
            if isIn(room, home) { return (home, foot) }
        }
        for side in [above, below] {
            if let place = slid(from: side.0, to: side.1, home: 0.5, off: side.2, in: room) { return (place.center, place.foot) }
        }
        let place = kept(CGPoint(x: size.width / 2, y: above.0.y - stalk), in: room)
        return (place, place)
    }
}

/// A grip on one side of the selection. VoiceOver hears the width or height it changes and swipes it a tenth at a time.
private final class SideGrip: UIView {
    let side: ItemSelectionView.Side
    let pan = GripPan()
    var onStep: ((CGFloat) -> Void)?
    private let bar = UIView()

    init(side: ItemSelectionView.Side) {
        self.side = side
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        let across = side == .top || side == .bottom
        bar.frame = across ? CGRect(x: 8, y: 17, width: 28, height: 10) : CGRect(x: 17, y: 8, width: 10, height: 28)
        bar.backgroundColor = Grip.fill
        bar.layer.cornerRadius = 2
        bar.layer.borderWidth = 1
        bar.isUserInteractionEnabled = false
        addSubview(bar)
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        accessibilityIdentifier = "page.grip.\(side)"
        // VoiceOver needs one grip for the width and one for the height.
        isAccessibilityElement = side == .right || side == .bottom
        guard isAccessibilityElement else { return }
        accessibilityLabel = across ? String(localized: "Change height") : String(localized: "Change width")
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError() }

    func colour(_ traits: UITraitCollection) {
        bar.layer.borderColor = Grip.edge(traits)
    }

    func show(_ item: PageItem) {
        let length = side == .top || side == .bottom ? item.size.height : item.size.width
        accessibilityValue = String(localized: "\(Int(length.rounded())) pt")
    }

    override func accessibilityIncrement() { onStep?(1) }
    override func accessibilityDecrement() { onStep?(-1) }
}

/// A pan that keeps where the finger came down, as its own translation only counts from where it was recognised.
final class GripPan: UIPanGestureRecognizer {
    private var down: CGPoint = .zero

    func start(in view: UIView) -> CGPoint { view.convert(down, from: nil) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if numberOfTouches == 0, let touch = touches.first { down = touch.location(in: nil) }
        super.touchesBegan(touches, with: event)
    }

    /// When one of two fingers lifts first, as at the end of a pinch, the one left counts from where it is then.
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let touch = event.touches(for: self)?.subtracting(touches).first { down = touch.location(in: nil) }
        super.touchesEnded(touches, with: event)
    }
}

/// The knobs on a selection or a crop. In Dark Mode they turn to cream card stock so they show on a dark page and a
/// dimmed picture; Increase Contrast darkens their edge.
enum Grip {
    /// The sides of a square tab and of a round knob, and the symbol a knob wears.
    static let tab: CGFloat = 14
    static let knob: CGFloat = 28
    static let symbol = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
    static let fill = UIColor { ($0.userInterfaceStyle == .dark ? UIColor.labelCream : .surface).resolvedColor(with: $0) }
    static let ink = UIColor { ($0.userInterfaceStyle == .dark ? UIColor.labelInk : .ink).resolvedColor(with: $0) }

    static func edge(_ traits: UITraitCollection) -> CGColor {
        ink.resolvedColor(with: traits).withAlphaComponent(traits.accessibilityContrast == .high ? 0.75 : 0.35).cgColor
    }
}
