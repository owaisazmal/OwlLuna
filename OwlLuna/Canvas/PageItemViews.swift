import UIKit

/// One picture, sticker, text box or link in the editor, under the canvas, or a strip of study tape over it.
/// Its frame follows the page's baked scale.
final class PageItemView: UIView {
    private(set) var item: PageItem
    private let assets: URL
    private var loadedFile: String?
    /// A picture is shown by its own layer and nothing is drawn behind it, so it has no bitmap the size of the item.
    private let picture = CALayer()
    /// Where a sticker, text box, link or tape is drawn. A picture has none.
    private var art: ItemArtView?
    private var onDark = false
    private var linkTitle = ""
    private var linkResolved = true
    private var isLifted = false
    var onActivate: ((UUID) -> Void)?
    /// Ticks a line of a checklist, or takes its tick off, for VoiceOver. False when the page can't be changed now.
    var onTick: ((UUID, Int) -> Bool)?
    /// Moving, turning and layering the item while it is selected, for VoiceOver.
    var arrangeActions: [UIAccessibilityCustomAction] = [] {
        didSet { accessibilityCustomActions = ticks + arrangeActions }
    }
    private var ticks: [UIAccessibilityCustomAction] = []

    init(item: PageItem, assets: URL) {
        self.item = item
        self.assets = assets
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        picture.contentsGravity = .resize
        layer.addSublayer(picture)
        isAccessibilityElement = true
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ newItem: PageItem, onDark: Bool = false, links: LinkTitles = LinkTitles(), lifted: Bool = false) {
        let title = newItem.link.map(links.title(for:)) ?? "", resolved = newItem.link.map(links.resolves) ?? true
        let changed = newItem.content != item.content || onDark != self.onDark || title != linkTitle || resolved != linkResolved || lifted != isLifted
        item = newItem
        self.onDark = onDark
        linkTitle = title
        linkResolved = resolved
        isLifted = lifted
        // Tape takes the touches that land on it, so a tap lifts it and nothing is written on it.
        isUserInteractionEnabled = newItem.isOverInk
        if changed { reload() }
    }

    func layout(scale: CGFloat) {
        placeTurned(bounds: CGRect(x: 0, y: 0, width: item.size.width * scale, height: item.size.height * scale),
                    center: CGPoint(x: item.center.x * scale, y: item.center.y * scale), transform: CGAffineTransform(rotationAngle: item.rotation))
        CATransaction.withoutActions {
            picture.frame = bounds
            picture.contentsRect = item.crop ?? PageItem.wholePicture
        }
        art?.frame = bounds
        art?.fitScale()
    }

    /// The picture as shown, the whole file, for cropping it without reading it again.
    var shownPicture: Any? { picture.contents }

    /// Width over height of the part of the file that shows, once it has loaded.
    var naturalAspect: CGFloat? {
        guard let contents = picture.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        let image = contents as! CGImage, crop = item.crop ?? PageItem.wholePicture
        guard image.height > 0, crop.height > 0 else { return nil }
        return CGFloat(image.width) * crop.width / (CGFloat(image.height) * crop.height)
    }

    /// Pixels per point for drawn art: the screen's, until its bitmap would pass about a screenful of pixels.
    static func drawingScale(for size: CGSize, screen: CGFloat) -> CGFloat {
        let budget: CGFloat = 2400 * 2400, side: CGFloat = 8192
        return min(screen, (budget / max(size.width * size.height, 1)).squareRoot(), side / max(size.width, size.height, 1))
    }

    private func reload() {
        accessibilityHint = String(localized: "Touch and hold to move or resize")
        accessibilityTraits = .image
        accessibilityValue = nil
        ticks = []
        defer { accessibilityCustomActions = ticks + arrangeActions }
        isAccessibilityElement = true
        if item.assetFile == nil {
            picture.contents = nil
            loadedFile = nil
            showArt()
        } else {
            art?.removeFromSuperview()
            art = nil
        }
        switch item.content {
        case .sticker:
            accessibilityLabel = item.sticker.map { String(localized: "Sticker, \($0.displayName)") } ?? String(localized: "Sticker")
        case .image(let file):
            accessibilityLabel = item.source == nil ? String(localized: "Picture") : String(localized: "Sticker")
            guard file != loadedFile else { return }
            loadedFile = file
            let assets = assets
            Task { [weak self] in
                let image = await Task.detached(priority: .userInitiated) { PageItemRenderer.image(file, assets: assets).map(SharedImage.init) }.value
                guard let self, self.loadedFile == file else { return }
                self.picture.contents = image?.image
            }
        case .text(let box):
            accessibilityLabel = box.string
            accessibilityTraits = .staticText
            guard box.list == .check else { break }
            let lines = box.lines.enumerated().filter { TextBox.isItem($0.element) }
            accessibilityLabel = lines.map { box.checked.contains($0.offset) ? String(localized: "\($0.element), ticked") : $0.element }
                .joined(separator: "\n")
            ticks = lines.map { line, text in
                let name = box.checked.contains(line) ? String(localized: "Untick \(text)") : String(localized: "Tick \(text)")
                return UIAccessibilityCustomAction(name: name) { [weak self] _ in
                    guard let self, let onTick = self.onTick else { return false }
                    return onTick(self.item.id, line)
                }
            }
        case .link(let link):
            accessibilityTraits = .link
            switch link.kind {
            case .page:
                accessibilityLabel = linkResolved ? String(localized: "Link to \(linkTitle)") : String(localized: "Link to a page that was deleted")
                accessibilityHint = String(localized: "Opens the page. Touch and hold to move or resize.")
            case .notebook:
                accessibilityLabel = linkResolved ? String(localized: "Link to the notebook \(linkTitle)") : String(localized: "Link to a notebook that was deleted")
                accessibilityHint = String(localized: "Opens the notebook. Touch and hold to move or resize.")
            case .web:
                accessibilityLabel = String(localized: "Web link, \(linkTitle)")
                accessibilityHint = String(localized: "Opens the address in your browser. Touch and hold to move or resize.")
            }
        case .tape:
            accessibilityLabel = String(localized: "Study tape")
            accessibilityValue = isLifted ? String(localized: "Lifted") : String(localized: "Covering")
            accessibilityTraits = .button
            accessibilityHint = String(localized: "Lifts the tape or puts it back. Touch and hold to move or resize.")
        case .unknown:
            isAccessibilityElement = false
        }
    }

    private func showArt() {
        if art == nil {
            let art = ItemArtView(frame: bounds)
            art.paint = { [weak self] ctx, rect in self?.drawArt(in: ctx, rect: rect) }
            addSubview(art)
            self.art = art
            art.fitScale()
        }
        art?.setNeedsDisplay()
    }

    private func drawArt(in ctx: CGContext, rect: CGRect) {
        switch item.content {
        case .sticker:
            item.sticker?.draw(in: ctx, rect: rect)
        case .text(let box):
            let scale = rect.width / max(item.size.width, 1)
            ctx.scaleBy(x: scale, y: scale)
            box.draw(in: ctx, rect: CGRect(origin: .zero, size: item.size), onDark: onDark)
        case .link(let link):
            PageLinkArt.draw(title: linkTitle, kind: link.kind, resolved: linkResolved, in: ctx, rect: rect)
        case .tape(let color):
            TapeArt.draw(color, lifted: isLifted, in: ctx, rect: rect)
        case .image, .unknown:
            break
        }
    }

    override func accessibilityActivate() -> Bool {
        onActivate?(item.id)
        return onActivate != nil
    }
}

/// The bitmap an item is drawn into, at no more pixels than `PageItemView.drawingScale` allows.
private final class ItemArtView: UIView {
    var paint: (CGContext, CGRect) -> Void = { _, _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        fitScale()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        paint(ctx, bounds)
    }
}

private extension UIView {
    /// Draws at the screen's scale, or fewer pixels once the bitmap would pass `PageItemView.drawingScale`'s budget.
    func fitScale() {
        let screen = window?.traitCollection.displayScale ?? traitCollection.displayScale
        guard screen > 0 else { return }
        let wanted = PageItemView.drawingScale(for: bounds.size, screen: screen)
        if contentScaleFactor != wanted { contentScaleFactor = wanted }
    }
}

/// A list's bullets, numbers and boxes under the words of a text box being typed in, where its text view leaves room.
final class TextMarkersView: UIView {
    private var box: TextBox?
    private var onDark = false
    private var scale: CGFloat = 1

    init() {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        fitScale()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fitScale()
    }

    func show(_ box: TextBox?, onDark: Bool, scale: CGFloat) {
        isHidden = box == nil
        fitScale()
        guard box != self.box || onDark != self.onDark || scale != self.scale else { return }
        self.box = box
        self.onDark = onDark
        self.scale = scale
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let box, let ctx = UIGraphicsGetCurrentContext() else { return }
        box.draw(in: ctx, rect: bounds, onDark: onDark, scale: scale, markersOnly: true)
    }
}

