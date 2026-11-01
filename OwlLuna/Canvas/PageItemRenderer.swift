import UIKit

/// Draws everything placed on a page, back to front, in a y-down context scaled to `size`. Thread-safe.
enum PageItemRenderer {
    /// Without `links`, a link shows its own label or a plain "Page": enough for a thumbnail.
    /// Draws what lies under the ink, or with `overInk` the study tape that lies over it, leaving out any that is lifted.
    static func draw(_ items: [PageItem], pageSize: CGSize, assets: URL, in ctx: CGContext, size: CGSize, onDark: Bool = false, links: LinkTitles? = nil,
                     overInk: Bool = false, lifted: Set<UUID> = []) {
        guard !items.isEmpty, pageSize.width > 0 else { return }
        let scale = size.width / pageSize.width
        for item in items where item.isOverInk == overInk && !lifted.contains(item.id) {
            ctx.saveGState()
            ctx.translateBy(x: item.center.x * scale, y: item.center.y * scale)
            ctx.rotate(by: item.rotation)
            let rect = CGRect(x: -item.size.width * scale / 2, y: -item.size.height * scale / 2, width: item.size.width * scale, height: item.size.height * scale)
            switch item.content {
            case .sticker:
                item.sticker?.draw(in: ctx, rect: rect)
            case .image(let file):
                if let image = image(file, assets: assets, crop: item.crop) {
                    ctx.translateBy(x: 0, y: rect.maxY + rect.minY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.interpolationQuality = .high
                    ctx.draw(PageRenderer.limited(image, for: rect.size), in: rect)
                }
            case .text(let box):
                ctx.scaleBy(x: scale, y: scale)
                box.draw(in: ctx, rect: CGRect(x: -item.size.width / 2, y: -item.size.height / 2, width: item.size.width, height: item.size.height), onDark: onDark)
            case .link(let link) where item.isPDFLink:
                PageLinkArt.drawWash(kind: link.kind, resolved: links?.resolves(link) ?? true, in: ctx, rect: rect)
            case .link(let link):
                let title = links?.title(for: link) ?? (link.target == nil ? LinkTitles().title(for: link) : link.label.isEmpty ? String(localized: "Page") : link.label)
                PageLinkArt.draw(title: title, kind: link.kind, resolved: links?.resolves(link) ?? true, in: ctx, rect: rect)
            case .tape(let color):
                TapeArt.draw(color, in: ctx, rect: rect)
            case .unknown:
                break
            }
            ctx.restoreGState()
        }
    }

    /// The picture, or just its `crop` at the file's own pixels, so an export carries nothing that was cropped away.
    /// Reading its words passes `cached: false`, so it doesn't push what the editor shows out of the cache.
    static func image(_ file: String, assets: URL, crop: CGRect? = nil, cached: Bool = true) -> CGImage? {
        let path = assets.appending(path: file).path(percentEncoded: false)
        let whole = cached ? PageRenderer.images.value(path) { UIImage(contentsOfFile: path)?.cgImage.map(SharedImage.init) }?.image
            : UIImage(contentsOfFile: path)?.cgImage
        guard let whole, let crop else { return whole }
        return whole.cropping(to: pixels(of: crop, width: whole.width, height: whole.height))
    }

    /// A crop in whole pixels of a picture `width` by `height`, at least one each way.
    static func pixels(of crop: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        let x = min((crop.minX * w).rounded(), w - 1), y = min((crop.minY * h).rounded(), h - 1)
        return CGRect(x: x, y: y, width: max(min((crop.maxX * w).rounded(), w) - x, 1), height: max(min((crop.maxY * h).rounded(), h) - y, 1))
    }
}
