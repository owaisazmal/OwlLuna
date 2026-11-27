import UIKit
import PencilKit
import ImageIO
import UniformTypeIdentifiers

/// A page as an SVG document, a point to a unit: the paper and each thing on it as a picture of its own, the ink as shapes. Thread-safe.
enum PageSVG {
    /// Pixels a point for ruling and imported PDF pages, as the PNG export draws them.
    static let paperScale: CGFloat = 2
    /// Pixels a point for text boxes, stickers, links and tape, so words stay sharp when another app zooms in.
    static let itemScale: CGFloat = 3
    /// Photos go in at their own pixels, but no finer than this many a point.
    static let photoLimit: CGFloat = 3
    /// No picture's long side passes this many pixels.
    static let pixelLimit: CGFloat = 4096

    /// A whiteboard goes out as one sheet, as large as what is on it.
    static func data(for page: NotebookPage, ink: PKDrawing, assets: URL, title: String, options: NotebookExporter.Options = .init(),
                     links: LinkTitles? = nil) -> Data {
        let page = Whiteboard.whole(page, ink: ink)
        let width = SVGText.number(page.size.width), height = SVGText.number(page.size.height)
        var out = Writer()
        out.add("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        out.add("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" version=\"1.1\" width=\"\(width)\" "
            + "height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\">\n")
        out.add("<title>\(SVGText.escaped(title))</title>\n")
        paper(page, assets: assets, paper: options.paper, into: &out)
        let items = page.hasItems ? page.items.filter { $0.content != .unknown } : []
        let onDark = options.paper && page.isDark(night: false)
        var number = 0
        group("items", items.filter { !$0.isOverInk }, number: &number, assets: assets, onDark: onDark, links: links, into: &out)
        out.add(InkSVG.group(ink, from: page.inkRect, size: page.size, style: NotebookExporter.inkStyle(for: page, options: options)) + "\n")
        group("tape", items.filter(\.isOverInk), number: &number, assets: assets, onDark: onDark, links: links, into: &out)
        out.add("</svg>\n")
        return out.data
    }

    /// The paper's colour, and over it what the paper has that is drawn rather than filled. Without `paper`, only an imported PDF page or a photo.
    private static func paper(_ page: NotebookPage, assets: URL, paper: Bool, into out: inout Writer) {
        let width = SVGText.number(page.size.width), height = SVGText.number(page.size.height)
        let picture = autoreleasepool { paperPicture(page, assets: assets, paper: paper) }
        guard paper || picture != nil else { return }
        out.add("<g id=\"paper\">\n")
        if paper { out.add("<rect width=\"\(width)\" height=\"\(height)\" fill=\"\(SVGText.color(PageRenderer.paperColor(page.effectivePaperColor)).hex)\"/>\n") }
        if let picture { out.image("id=\"paper-picture\" width=\"\(width)\" height=\"\(height)\"", picture) }
        out.add("</g>\n")
    }

    /// Ruling, a masthead, a PDF page or a photo, as `PageRenderer` draws them; nil for paper that is only a colour.
    private static func paperPicture(_ page: NotebookPage, assets: URL, paper: Bool) -> Picture? {
        let drawn = switch page.background {
        case .template: paper && (page.template != .blank || !page.isBoard && page.day != nil)
        case .pdf, .image: true
        case .unknown: false
        }
        guard drawn else { return nil }
        let size = page.size
        var scale = Whiteboard.scale(for: size, wanted: paperScale, limit: pixelLimit), photo = false
        if case .image(let file) = page.background, let image = PageItemRenderer.image(file, assets: assets) {
            scale = Whiteboard.scale(for: size, wanted: min(max(CGFloat(image.width) / max(size.width, 1), 1), photoLimit), limit: pixelLimit)
            photo = true
        }
        let fill = paper && page.template == nil ? PageRenderer.paperColor(page.effectivePaperColor) : nil
        let bitmap = Bitmap(size, scale: scale, fill: fill) { PageRenderer.drawPaper(page, assets: assets, in: $0, size: size, night: false) }
        return bitmap.flatMap { $0.clear ? nil : $0.encoded(photo: photo) }
    }

    /// Each item as an `<image>` of it alone, placed with its centre, size and turn; left out when nothing in it would show.
    private static func group(_ id: String, _ items: [PageItem], number: inout Int, assets: URL, onDark: Bool, links: LinkTitles?, into out: inout Writer) {
        var opened = false
        for item in items {
            autoreleasepool {
                guard let picture = picture(of: item, assets: assets, onDark: onDark, links: links) else { return }
                if !opened {
                    out.add("<g id=\"\(id)\">\n")
                    opened = true
                }
                number += 1
                let url = item.link?.externalURL
                if let url { out.add("<a xlink:href=\"\(SVGText.escaped(url.absoluteString))\">") }
                var transform = "translate(\(SVGText.number(item.center.x)) \(SVGText.number(item.center.y)))"
                if item.rotation != 0 { transform += " rotate(\(SVGText.number(item.rotation * 180 / .pi)))" }
                let w = item.size.width, h = item.size.height, words = item.text?.string
                out.image("id=\"item-\(number)\" x=\"\(SVGText.number(-w / 2))\" y=\"\(SVGText.number(-h / 2))\" width=\"\(SVGText.number(w))\" "
                    + "height=\"\(SVGText.number(h))\" transform=\"\(transform)\"", picture,
                          desc: words?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? words : nil, closing: url != nil ? "</a>" : "")
            }
        }
        if opened { out.add("</g>\n") }
    }

    /// A picture from its own file's pixels, cropped as it shows; anything else drawn upright on its own, as large as it is.
    private static func picture(of item: PageItem, assets: URL, onDark: Bool, links: LinkTitles?) -> Picture? {
        if case .image(let file) = item.content {
            guard let image = PageItemRenderer.image(file, assets: assets, crop: item.crop) else { return nil }
            let pixels = CGSize(width: image.width, height: image.height)
            let factor = min(1, photoLimit * item.size.width / pixels.width, photoLimit * item.size.height / pixels.height,
                             pixelLimit / max(pixels.width, pixels.height))
            return Bitmap(pixels, scale: factor) { ctx in
                ctx.translateBy(x: 0, y: pixels.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(origin: .zero, size: pixels))
            }.flatMap { $0.clear ? nil : $0.encoded(photo: true) }
        }
        var alone = item
        alone.center = CGPoint(x: item.size.width / 2, y: item.size.height / 2)
        alone.rotation = 0
        let scale = min(itemScale, pixelLimit / max(item.size.width, item.size.height, 1))
        return Bitmap(item.size, scale: scale) { ctx in
            PageItemRenderer.draw([alone], pageSize: item.size, assets: assets, in: ctx, size: item.size, onDark: onDark, links: links,
                                  overInk: item.isOverInk)
        }.flatMap { $0.clear ? nil : $0.encoded(photo: false) }
    }

    /// What was drawn, in sRGB pixels, knowing whether all of it is opaque or all of it clear.
    private struct Bitmap {
        let image: CGImage
        let opaque: Bool
        let clear: Bool

        /// `size` points at `scale` pixels a point, drawn in a y-down context over `fill`.
        init?(_ size: CGSize, scale: CGFloat, fill: UIColor? = nil, draw: (CGContext) -> Void) {
            let width = max(Int((size.width * scale).rounded()), 1), height = max(Int((size.height * scale).rounded()), 1)
            guard size.width > 0, size.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)
            if let fill {
                ctx.setFillColor(fill.cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            UIGraphicsPushContext(ctx)
            draw(ctx)
            UIGraphicsPopContext()
            guard let bytes = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var opaque = true, clear = true
            let row = ctx.bytesPerRow
            scan: for y in 0..<height {
                let line = bytes + y * row
                for x in 0..<width {
                    let alpha = line[x * 4 + 3]
                    if alpha != 255 { opaque = false }
                    if alpha != 0 { clear = false }
                    if !opaque && !clear { break scan }
                }
            }
            guard let image = ctx.makeImage() else { return nil }
            self.opaque = opaque
            self.clear = clear
            if opaque, let provider = image.dataProvider,
               let solid = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.bytesPerRow, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                                   shouldInterpolate: true, intent: .defaultIntent) {
                self.image = solid
            } else {
                self.image = image
            }
        }

        /// PNG where it is see-through; JPEG for an opaque photo, or for anything else opaque that is much smaller that way.
        func encoded(photo: Bool) -> Picture? {
            guard opaque else { return Self.encode(image, as: .png).map { Picture(type: "image/png", data: $0) } }
            guard let jpeg = Self.encode(image, as: .jpeg) else { return nil }
            if photo { return Picture(type: "image/jpeg", data: jpeg) }
            guard let png = Self.encode(image, as: .png), png.count <= jpeg.count * 2 else { return Picture(type: "image/jpeg", data: jpeg) }
            return Picture(type: "image/png", data: png)
        }

        private static func encode(_ image: CGImage, as type: UTType) -> Data? {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
            let properties: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }
    }

    /// A picture as a file of its own, `type` being its MIME type.
    private struct Picture {
        let type: String
        let data: Data
    }

    /// The document as it is written, pictures going in as base64 a piece at a time.
    private struct Writer {
        var data = Data()

        mutating func add(_ text: String) {
            data.append(contentsOf: text.utf8)
        }

        /// An `<image>` with `attributes`, stretched to fill them, its picture inline and `desc` as its words, then `closing`.
        mutating func image(_ attributes: String, _ picture: Picture, desc: String? = nil, closing: String = "") {
            let tail = "\"" + (desc.map { "><desc>\(SVGText.escaped($0))</desc></image>" } ?? "/>") + closing + "\n"
            data.reserveCapacity(data.count + attributes.utf8.count + (picture.data.count + 2) / 3 * 4 + tail.utf8.count + 100)
            add("<image \(attributes) preserveAspectRatio=\"none\" xlink:href=\"data:\(picture.type);base64,")
            let chunk = 3 * 16_384
            var start = picture.data.startIndex
            while start < picture.data.endIndex {
                let end = min(start + chunk, picture.data.endIndex)
                data.append(picture.data[start..<end].base64EncodedData())
                start = end
            }
            add(tail)
        }
    }
}
