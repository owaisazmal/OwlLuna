import UIKit

/// The stitched outline and handle round the selected item. It sits above the canvas, so touches on the item move
/// it instead of drawing. Every change is reported as a whole item; `final` marks the end of a gesture.
final class ItemSelectionView: UIView, UIGestureRecognizerDelegate {
    enum Side: CaseIterable { case top, left, bottom, right }

    static let outset: CGFloat = 8
    private static let handleSize: CGFloat = 44

    private(set) var item: PageItem
    var pageSize: CGSize
    var scale: CGFloat = 1
    /// Width over height of the part of a picture that shows, as the file has it. Squeezing settles on it.
    var naturalAspect: () -> CGFloat? = { nil }
    var onChange: ((PageItem, _ final: Bool) -> Void)?
    /// Where it was tapped, in page points from the item's top left.
    var onTap: ((CGPoint) -> Void)?
    /// While its text is being typed the outline stays and the handles step aside.
    var isEditing = false {
        didSet {
            isUserInteractionEnabled = !isEditing
            show(item)
        }
    }

    private let outline = CAShapeLayer()
    private let underline = CAShapeLayer()
    private let handle = UIView()
    private let knob = UIImageView()
    private let grips = Side.allCases.map { SideGrip(side: $0) }
    private var base: PageItem?
    private var pinch: CGFloat = 1
    private var twist: CGFloat = 0
    private var handleStart: CGPoint = .zero
    private(set) lazy var recognizers: [UIGestureRecognizer] = [
        GripPan(target: self, action: #selector(dragged)),
        UIPinchGestureRecognizer(target: self, action: #selector(pinched)),
        UIRotationGestureRecognizer(target: self, action: #selector(twisted)),
    ]
    private lazy var handlePan = GripPan(target: self, action: #selector(dragHandle))

    init(item: PageItem, pageSize: CGSize) {
        self.item = item
        self.pageSize = pageSize
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = false
        for (layer, color, width) in [(underline, UIColor.ink.withAlphaComponent(0.55), 3.5 as CGFloat), (outline, UIColor.mustard, 2)] {
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = width
            self.layer.addSublayer(layer)
        }
        outline.lineDashPattern = [7, 5]
        outline.lineCap = .round
        handle.frame = CGRect(x: 0, y: 0, width: Self.handleSize, height: Self.handleSize)
        knob.frame = handle.bounds.insetBy(dx: 8, dy: 8)
        knob.backgroundColor = Grip.fill
        knob.layer.cornerRadius = knob.bounds.width / 2
        knob.layer.borderWidth = 1
        knob.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        knob.tintColor = Grip.ink
        knob.contentMode = .center
        handle.addSubview(knob)
        addSubview(handle)
        handle.addGestureRecognizer(handlePan)
        handle.isAccessibilityElement = true
        handle.accessibilityLabel = String(localized: "Resize and rotate")
        handle.accessibilityTraits = .adjustable
        (recognizers[0] as? UIPanGestureRecognizer)?.maximumNumberOfTouches = 1
        handlePan.maximumNumberOfTouches = 1
        for recognizer in recognizers {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        handlePan.delegate = self
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
        // A text box or a strip of tape keeps its right edge for the width grip, so its corner handle moves to the left.
        let hasGrip = item.text != nil || item.tape != nil, squeezes = item.assetFile != nil
        handle.center = CGPoint(x: hasGrip ? bounds.minX + outset / 2 : bounds.maxX - outset / 2, y: bounds.maxY - outset / 2)
        handle.isHidden = isEditing
        for grip in grips {
            let across = grip.side == .top || grip.side == .bottom
            // A picture's grips stand only where they are clear of the corner handle.
            let room = (across ? bounds.width : bounds.height) - outset * 2 >= Self.handleSize * 2
            grip.isHidden = isEditing || !(hasGrip ? grip.side == .right : squeezes && room)
            grip.center = switch grip.side {
            case .top: CGPoint(x: bounds.midX, y: bounds.minY + outset / 2)
            case .left: CGPoint(x: bounds.minX + outset / 2, y: bounds.midY)
            case .bottom: CGPoint(x: bounds.midX, y: bounds.maxY - outset / 2)
            case .right: CGPoint(x: bounds.maxX - outset / 2, y: bounds.midY)
            }
            grip.show(item)
        }
    }

    private func colour() {
        CATransaction.withoutActions {
            outline.strokeColor = UIColor.mustard.resolvedColor(with: traitCollection).cgColor
            underline.strokeColor = UIColor.ink.resolvedColor(with: traitCollection).withAlphaComponent(0.55).cgColor
        }
        knob.layer.borderColor = Grip.edge(traitCollection)
        for grip in grips { grip.colour(traitCollection) }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) || handle.frame.contains(point) || grips.contains { !$0.isHidden && $0.frame.contains(point) }
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
        let others = (recognizers + [handlePan] + grips.map(\.pan)).contains { $0.state == .began || $0.state == .changed }
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
        var changed = base.scaled(by: pinch, limit: max(pageSize.width, pageSize.height) * 1.5)
        changed.rotation = Self.snapped(base.rotation + twist)
        changed.center = CGPoint(x: item.center.x + translation.x, y: item.center.y + translation.y)
        return changed
    }

    /// Settles on the quarter turns when within three degrees of one.
    static func snapped(_ angle: CGFloat) -> CGFloat {
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
        guard let superview else { return }
        let point = gesture.location(in: superview)
        let vector = CGPoint(x: point.x - center.x, y: point.y - center.y)
        if gesture.state == .began {
            begin()
            let down = gesture.start(in: superview)
            handleStart = CGPoint(x: down.x - center.x, y: down.y - center.y)
        }
        guard let base else { return }
        let start = max(hypot(handleStart.x, handleStart.y), 1)
        pinch = hypot(vector.x, vector.y) / start
        twist = atan2(vector.y, vector.x) - atan2(handleStart.y, handleStart.x)
        report(composed(from: base), state: gesture.state)
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
            let width = min(max(item.size.width + amount, 40), limit)
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
private final class GripPan: UIPanGestureRecognizer {
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
    static let fill = UIColor { ($0.userInterfaceStyle == .dark ? UIColor.labelCream : .surface).resolvedColor(with: $0) }
    static let ink = UIColor { ($0.userInterfaceStyle == .dark ? UIColor.labelInk : .ink).resolvedColor(with: $0) }

    static func edge(_ traits: UITraitCollection) -> CGColor {
        ink.resolvedColor(with: traits).withAlphaComponent(traits.accessibilityContrast == .high ? 0.75 : 0.35).cgColor
    }
}
