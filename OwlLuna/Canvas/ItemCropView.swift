import UIKit

/// Crop mode for a selected picture: all of it, what is cut off dimmed, and edges and corners to drag.
final class ItemCropView: UIView, UIGestureRecognizerDelegate {
    enum Edge: CaseIterable { case top, left, bottom, right }
    private enum Grab { case edges(Set<Edge>), slide }

    private static let outset: CGFloat = 22
    static let step: CGFloat = 0.05

    /// The picture as it was when cropping began.
    let item: PageItem
    private(set) var crop: CGRect
    var scale: CGFloat {
        didSet { if scale != oldValue { layoutPicture() } }
    }
    /// Reports the crop, in the picture's unit square, as each drag ends.
    var onChange: ((CGRect) -> Void)?
    /// A part of the picture, in its unit square, that no edge is let past. Nil for a picture on a page.
    var holds: CGRect?

    private let picture = CALayer()
    private let shade = CAShapeLayer()
    private let underline = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let knobs: [UIView] = (0..<8).map { _ in UIView() }
    private var grab: Grab?
    private var start = PageItem.wholePicture
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged))
    private lazy var edges = Edge.allCases.map { CropEdgeElement(edge: $0, view: self) }

    init(item: PageItem, picture contents: Any?, assets: URL, scale: CGFloat) {
        self.item = item
        crop = item.crop ?? PageItem.wholePicture
        self.scale = scale
        super.init(frame: .zero)
        backgroundColor = .clear
        picture.contentsGravity = .resize
        picture.contents = contents
        shade.fillRule = .evenOdd
        shade.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor
        for (line, width) in [(underline, 3.5 as CGFloat), (outline, 2)] {
            line.fillColor = nil
            line.lineWidth = width
        }
        for sublayer in [picture, shade, underline, outline] { layer.addSublayer(sublayer) }
        for knob in knobs {
            knob.backgroundColor = Grip.fill
            knob.layer.cornerRadius = 2
            knob.layer.borderWidth = 1
            knob.isUserInteractionEnabled = false
            addSubview(knob)
        }
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        isAccessibilityElement = false
        accessibilityElements = edges
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: ItemCropView, _) in view.showCrop() }
        if contents == nil, case .image(let file) = item.content {
            Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) { PageItemRenderer.image(file, assets: assets).map(SharedImage.init) }.value
                self?.picture.contents = image?.image
            }
        }
        layoutPicture()
    }

    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        crop = PageItem.wholePicture
        showCrop()
        onChange?(crop)
    }

    /// Puts the crop where it is told to be.
    func show(_ crop: CGRect) {
        self.crop = kept(crop)
        showCrop()
        onChange?(self.crop)
    }

    /// The crop still round what it `holds`: an edge moved past it stops there, and a crop slid off it is slid back.
    private func kept(_ crop: CGRect, slid: Bool = false) -> CGRect {
        guard let holds, !crop.contains(holds) else { return crop }
        guard slid else { return crop.union(holds) }
        return crop.offsetBy(dx: max(holds.maxX - crop.maxX, 0) + min(holds.minX - crop.minX, 0),
                             dy: max(holds.maxY - crop.maxY, 0) + min(holds.minY - crop.minY, 0))
    }

    /// How much of the picture is cut off past an edge, from 0 to 1.
    func cutOff(_ edge: Edge) -> CGFloat {
        switch edge {
        case .top: crop.minY
        case .left: crop.minX
        case .bottom: 1 - crop.maxY
        case .right: 1 - crop.maxX
        }
    }

    /// Moves an edge in by `amount` of the picture, or out for a negative amount.
    func nudge(_ edge: Edge, by amount: CGFloat) {
        let delta = switch edge {
        case .top: CGPoint(x: 0, y: amount)
        case .left: CGPoint(x: amount, y: 0)
        case .bottom: CGPoint(x: 0, y: -amount)
        case .right: CGPoint(x: -amount, y: 0)
        }
        crop = kept(Self.moved(crop, edges: [edge], by: delta, least: least))
        showCrop()
        onChange?(crop)
    }

    /// The crop with `edges` moved by `delta` of the picture, kept inside it and no smaller than `least`.
    static func moved(_ crop: CGRect, edges: Set<Edge>, by delta: CGPoint, least: CGSize) -> CGRect {
        var minX = crop.minX, minY = crop.minY, maxX = crop.maxX, maxY = crop.maxY
        if edges.contains(.left) { minX = min(max(minX + delta.x, 0), maxX - least.width) }
        if edges.contains(.right) { maxX = max(min(maxX + delta.x, 1), minX + least.width) }
        if edges.contains(.top) { minY = min(max(minY + delta.y, 0), maxY - least.height) }
        if edges.contains(.bottom) { maxY = max(min(maxY + delta.y, 1), minY + least.height) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The same crop over another part of the picture, never past its edges.
    static func slid(_ crop: CGRect, by delta: CGPoint) -> CGRect {
        crop.offsetBy(dx: min(max(delta.x, -crop.minX), 1 - crop.maxX), dy: min(max(delta.y, -crop.minY), 1 - crop.maxY))
    }

    /// No side smaller than a fingertip can grab, unless the whole picture is.
    private var least: CGSize {
        let whole = item.cropped(to: nil).size
        return CGSize(width: min(PageItem.minimumSide / max(whole.width, 1), 1), height: min(PageItem.minimumSide / max(whole.height, 1), 1))
    }

    private var pictureFrame: CGRect { bounds.insetBy(dx: Self.outset, dy: Self.outset) }

    private var keptFrame: CGRect {
        let frame = pictureFrame
        return CGRect(x: frame.minX + crop.minX * frame.width, y: frame.minY + crop.minY * frame.height,
                      width: crop.width * frame.width, height: crop.height * frame.height)
    }

    private func layoutPicture() {
        let whole = item.cropped(to: nil)
        placeTurned(bounds: CGRect(x: 0, y: 0, width: whole.size.width * scale + Self.outset * 2, height: whole.size.height * scale + Self.outset * 2),
                    center: CGPoint(x: whole.center.x * scale, y: whole.center.y * scale), transform: CGAffineTransform(rotationAngle: item.rotation))
        showCrop()
    }

    private func showCrop() {
        let frame = pictureFrame, kept = keptFrame
        let dimmed = CGMutablePath()
        dimmed.addRect(frame)
        dimmed.addRect(kept)
        CATransaction.withoutActions {
            picture.frame = frame
            shade.path = dimmed
            underline.path = CGPath(rect: kept, transform: nil)
            outline.path = underline.path
            outline.strokeColor = UIColor.mustard.resolvedColor(with: traitCollection).cgColor
            underline.strokeColor = UIColor.ink.resolvedColor(with: traitCollection).withAlphaComponent(0.55).cgColor
        }
        let corners = [CGPoint(x: kept.minX, y: kept.minY), CGPoint(x: kept.maxX, y: kept.minY), CGPoint(x: kept.minX, y: kept.maxY), CGPoint(x: kept.maxX, y: kept.maxY)]
        let sides = [CGPoint(x: kept.midX, y: kept.minY), CGPoint(x: kept.minX, y: kept.midY), CGPoint(x: kept.midX, y: kept.maxY), CGPoint(x: kept.maxX, y: kept.midY)]
        let border = Grip.edge(traitCollection)
        for (index, knob) in knobs.enumerated() {
            let corner = index < 4, across = index % 2 == 0
            knob.bounds.size = corner ? CGSize(width: 14, height: 14) : across ? CGSize(width: 28, height: 10) : CGSize(width: 10, height: 28)
            knob.center = corner ? corners[index] : sides[index - 4]
            knob.layer.borderColor = border
        }
        for element in edges {
            let reach = Self.outset
            element.accessibilityFrameInContainerSpace = switch element.edge {
            case .top: CGRect(x: kept.minX, y: kept.minY - reach, width: kept.width, height: reach * 2)
            case .bottom: CGRect(x: kept.minX, y: kept.maxY - reach, width: kept.width, height: reach * 2)
            case .left: CGRect(x: kept.minX - reach, y: kept.minY, width: reach * 2, height: kept.height)
            case .right: CGRect(x: kept.maxX - reach, y: kept.minY, width: reach * 2, height: kept.height)
            }
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        keptFrame.insetBy(dx: -Self.outset, dy: -Self.outset).contains(point)
    }

    /// The page's own scroll and zoom wait for the drag, so a touch on the crop moves the crop.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView
    }

    /// Near an edge moves it, near a corner both of its edges, and further in the crop slides over the picture.
    private func grab(at point: CGPoint) -> Grab {
        let kept = keptFrame, reachX = min(Self.outset, kept.width / 3), reachY = min(Self.outset, kept.height / 3)
        var edges: Set<Edge> = []
        if point.x < kept.minX + reachX { edges.insert(.left) } else if point.x > kept.maxX - reachX { edges.insert(.right) }
        if point.y < kept.minY + reachY { edges.insert(.top) } else if point.y > kept.maxY - reachY { edges.insert(.bottom) }
        return edges.isEmpty ? .slide : .edges(edges)
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let frame = pictureFrame
        guard frame.width > 0, frame.height > 0 else { return }
        let moved = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            let point = gesture.location(in: self)
            grab = grab(at: CGPoint(x: point.x - moved.x, y: point.y - moved.y))
            start = crop
            fallthrough
        case .changed:
            let delta = CGPoint(x: moved.x / frame.width, y: moved.y / frame.height)
            switch grab {
            case .edges(let edges): crop = kept(Self.moved(start, edges: edges, by: delta, least: least))
            case .slide: crop = kept(Self.slid(start, by: delta), slid: true)
            case nil: return
            }
            showCrop()
        case .ended:
            grab = nil
            onChange?(crop)
        case .cancelled, .failed:
            grab = nil
            crop = start
            showCrop()
        default:
            break
        }
    }
}

/// One edge of a crop for VoiceOver: swiping up cuts off more of the picture there, swiping down less.
private final class CropEdgeElement: UIAccessibilityElement {
    let edge: ItemCropView.Edge
    private weak var view: ItemCropView?

    init(edge: ItemCropView.Edge, view: ItemCropView) {
        self.edge = edge
        self.view = view
        super.init(accessibilityContainer: view)
        accessibilityTraits = .adjustable
        accessibilityIdentifier = "page.crop.\(edge)"
        accessibilityLabel = switch edge {
        case .top: String(localized: "Top Edge")
        case .left: String(localized: "Left Edge")
        case .bottom: String(localized: "Bottom Edge")
        case .right: String(localized: "Right Edge")
        }
    }

    override var accessibilityValue: String? {
        get { view.map { String(localized: "\(Double($0.cutOff(edge)).formatted(.percent.precision(.fractionLength(0)))) cut off") } }
        set {}
    }

    override func accessibilityIncrement() { view?.nudge(edge, by: ItemCropView.step) }
    override func accessibilityDecrement() { view?.nudge(edge, by: -ItemCropView.step) }
}
