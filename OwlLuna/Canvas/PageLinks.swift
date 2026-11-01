import UIKit

/// What a link is called: its own label, or the name of what it opens (a bookmark name or page number, a notebook's
/// title, a web address without its scheme).
struct LinkTitles: Sendable, Equatable {
    private var titles: [UUID: String] = [:]
    /// The library's notebooks by ID. Nil when they weren't looked up: then a link to a notebook uses the name it was made with.
    private var notebooks: [UUID: String]?

    init(pages: [NotebookPage] = [], notebooks: [UUID: String]? = nil) {
        for (index, page) in pages.enumerated() {
            titles[page.id] = page.bookmark.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Page \(index + 1)")
        }
        self.notebooks = notebooks
    }

    func resolves(_ link: PageLink) -> Bool {
        switch link.destination {
        case .page(let id): titles[id] != nil
        case .notebook(let id, _, _): notebooks.map { $0[id] != nil } ?? true
        case .web: true
        }
    }

    func title(for link: PageLink) -> String {
        guard link.label.isEmpty else { return link.label }
        switch link.destination {
        case .page(let id): return titles[id] ?? String(localized: "Missing page")
        case .notebook(let id, _, let name): return notebooks?[id] ?? (name.isEmpty ? String(localized: "Notebook") : name)
        case .web(let url): return WebAddress.display(url)
        }
    }
}

extension PageLink {
    /// What its tab looks like.
    enum Kind: Sendable { case page, notebook, web }

    var kind: Kind {
        switch destination {
        case .page: .page
        case .notebook: .notebook
        case .web: .web
        }
    }

    /// The link an exported PDF carries for something outside the document.
    var externalURL: URL? {
        switch destination {
        case .page: nil
        case .web(let url): url
        case .notebook(let id, let page, _): AppAction.url(forNotebook: id, page: page)
        }
    }
}

/// The index tab a link is drawn as. Thread-safe.
enum PageLinkArt {
    static let height: CGFloat = 30
    private static let sage = UIColor(hex: 0xA9D6AD)
    private static let sky = UIColor(hex: 0xA6BBFF)
    private static let faded = UIColor(hex: 0xB9B4A8)

    private static func label(_ title: String, size: CGFloat, color: UIColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: title, attributes: [.font: UIFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color,
                                                              .paragraphStyle: paragraph])
    }

    /// The size a new link is placed at, wide enough for its title.
    static func size(for title: String) -> CGSize {
        let text = label(title, size: 14, color: ArtPalette.ink).size().width.rounded(.up)
        return CGSize(width: min(max(height + 8 + text + 12, 84), 320), height: height)
    }

    private static func tint(_ kind: PageLink.Kind, resolved: Bool) -> UIColor {
        guard resolved else { return faded }
        return switch kind {
        case .page: ArtPalette.mustard
        case .notebook: sage
        case .web: sky
        }
    }

    /// A link an imported PDF had, as a faint wash in its tab's colour over the words it is on.
    static func drawWash(kind: PageLink.Kind, resolved: Bool, in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.setFillColor(tint(kind, resolved: resolved).withAlphaComponent(kind == .page && resolved ? 0.22 : 0.38).cgColor)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    /// An arrow for a page, a book for another notebook, an arrow leaving the page for the web.
    private static func glyph(_ kind: PageLink.Kind, in tab: CGRect, unit: CGFloat, ctx: CGContext) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tab.minX + x * unit, y: tab.minY + y * unit) }
        switch kind {
        case .page:
            ctx.addLines(between: [point(9.5, 15), point(21, 15)])
            ctx.addLines(between: [point(16, 10), point(21, 15), point(16, 20)])
        case .web:
            ctx.addLines(between: [point(10.5, 19.5), point(19.5, 10.5)])
            ctx.addLines(between: [point(12.5, 10.5), point(19.5, 10.5), point(19.5, 17.5)])
        case .notebook:
            ctx.addPath(CGPath(roundedRect: CGRect(x: tab.minX + 9.5 * unit, y: tab.minY + 8 * unit, width: 11 * unit, height: 14 * unit),
                               cornerWidth: 1.5 * unit, cornerHeight: 1.5 * unit, transform: nil))
            ctx.addLines(between: [point(13, 8), point(13, 22)])
        }
        ctx.strokePath()
    }

    /// Draws in a y-down context. The tab is as wide as the chip is tall; the title shrinks before it is cut short.
    static func draw(title: String, kind: PageLink.Kind = .page, resolved: Bool, in ctx: CGContext, rect: CGRect) {
        let unit = rect.height / height
        let chip = CGPath(roundedRect: rect.insetBy(dx: unit, dy: unit), cornerWidth: 6 * unit, cornerHeight: 6 * unit, transform: nil)
        ctx.saveGState()
        ctx.addPath(chip)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(2 * unit)
        ctx.strokePath()
        ctx.addPath(chip)
        ctx.clip()
        ctx.setFillColor(ArtPalette.cream.cgColor)
        ctx.fill(rect)
        let tab = CGRect(x: rect.minX, y: rect.minY, width: rect.height, height: rect.height)
        ctx.setFillColor(tint(kind, resolved: resolved).cgColor)
        ctx.fill(tab)
        ctx.setStrokeColor(ArtPalette.ink.cgColor)
        ctx.setLineWidth((kind == .notebook ? 1.8 : 2.2) * unit)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        glyph(kind, in: tab, unit: unit, ctx: ctx)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(chip)
        ctx.setStrokeColor(ArtPalette.ink.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(unit)
        ctx.strokePath()
        ctx.restoreGState()

        let room = rect.maxX - tab.maxX - 18 * unit
        guard room > 4 else { return }
        var size = 14 * unit
        let natural = label(title, size: size, color: ArtPalette.ink).size().width
        if natural > room { size *= max(room / natural, 0.7) }
        let text = label(title, size: size, color: resolved ? ArtPalette.ink : ArtPalette.ink.withAlphaComponent(0.6))
        let line = text.size().height
        UIGraphicsPushContext(ctx)
        text.draw(with: CGRect(x: tab.maxX + 8 * unit, y: rect.midY - line / 2, width: room, height: line),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        UIGraphicsPopContext()
    }
}
