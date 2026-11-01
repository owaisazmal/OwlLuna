import UIKit
import PencilKit
import os
import ImageIO
import UniformTypeIdentifiers

/// `CGPDFDocument` is immutable once opened and safe to read from the tiling threads.
struct SharedPDF: @unchecked Sendable {
    let document: CGPDFDocument
}

struct SharedImage: @unchecked Sendable {
    let image: CGImage
}

/// Draws page backgrounds (paper templates, PDF pages, photos) in page-local points. Thread-safe.
enum PageRenderer {
    static let pdfs = LRUCache<SharedPDF>(capacity: 6)
    static let images = LRUCache<SharedImage>(capacity: 12)

    static func paperColor(_ color: PaperColor, night: Bool = false) -> UIColor {
        let (r, g, b) = night ? color.nightRGB : color.rgb
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// Fills `rect` (whose size is the page size scaled by `rect.width / page.size.width`) with the page background.
    /// The editor passes `items: false`: there, pictures and stickers are live views that can be moved.
    /// At `night` light paper is drawn dark, as the screen shows it in Dark Mode. What is exported leaves it out.
    /// Without `paper` a page has no colour or ruling of its own; an imported PDF page or a photo is still drawn.
    static func drawBackground(_ page: NotebookPage, assets: URL, in ctx: CGContext, size: CGSize, items: Bool = true, links: LinkTitles? = nil,
                               night: Bool = false, paper: Bool = true) {
        let night = page.turnsDark(night)
        if paper {
            ctx.setFillColor(paperColor(page.effectivePaperColor, night: night).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            drawPaper(page, assets: assets, in: ctx, size: size, night: night)
        } else if page.template == nil {
            drawPaper(page, assets: assets, in: ctx, size: size, night: false)
        }
        if items, page.hasItems {
            PageItemRenderer.draw(page.items, pageSize: page.size, assets: assets, in: ctx, size: size, onDark: paper && page.isDark(night: night), links: links)
        }
    }

    /// While a PDF is written to be small, photos and scans go in no finer than this many pixels a point.
    @TaskLocal static var pictureLimit: CGFloat?

    /// The picture as it is, or under `pictureLimit` a copy no finer than that for `size` points, as a JPEG where it has no transparency.
    static func limited(_ image: CGImage, for size: CGSize) -> CGImage {
        guard let limit = pictureLimit, size.width > 0, size.height > 0 else { return image }
        let factor = min(limit * size.width / CGFloat(image.width), limit * size.height / CGFloat(image.height))
        guard factor < 1 else { return image }
        let width = max(Int((CGFloat(image.width) * factor).rounded()), 1), height = max(Int((CGFloat(image.height) * factor).rounded()), 1)
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = ctx.makeImage() else { return image }
        let data = NSMutableData()
        guard opaque, let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return small }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithData(data, nil),
              let jpeg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return small }
        return jpeg
    }

    /// The study tape on a page, which goes on after the ink. Tape that is lifted isn't drawn.
    static func drawOverInk(_ page: NotebookPage, assets: URL, in ctx: CGContext, size: CGSize, lifted: Set<UUID> = []) {
        guard page.hasItems else { return }
        PageItemRenderer.draw(page.items, pageSize: page.size, assets: assets, in: ctx, size: size, overInk: true, lifted: lifted)
    }

    private static func drawPaper(_ page: NotebookPage, assets: URL, in ctx: CGContext, size: CGSize, night: Bool) {
        switch page.background {
        case .template where page.isBoard:
            drawBoardPaper(page.template ?? .blank, color: page.paperColor, origin: page.cut ?? .zero, scale: size.width / max(page.size.width, 1), in: ctx,
                           night: night)
        case .template:
            drawTemplate(page.template ?? .blank, color: page.paperColor, in: ctx, size: size, night: night)
            if let day = page.day {
                PageMasthead.draw(day: day, template: page.template ?? .blank, paper: page.paperColor, in: ctx, size: size, night: night)
            }
        case .pdf(let file, let index):
            let url = assets.appending(path: file)
            guard let pdf = pdfs.value(url.path(percentEncoded: false), create: {
                CGPDFDocument(url as CFURL).map(SharedPDF.init)
            }), let pdfPage = pdf.document.page(at: index + 1) else { return }
            drawPDFPage(pdfPage, in: ctx, size: size, marks: PDFMarks.has(pdfPage) ? .file(url, index: index) : nil)
        case .image(let file):
            let url = assets.appending(path: file)
            guard let image = images.value(url.path(percentEncoded: false), create: {
                UIImage(contentsOfFile: url.path(percentEncoded: false))?.cgImage.map(SharedImage.init)
            }) else { return }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(limited(image.image, for: size), in: CGRect(origin: .zero, size: size))
            ctx.restoreGState()
        case .unknown:
            break
        }
    }

    static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// With `marks`, what another app left on the page is drawn over it: highlights, comments, filled-in forms.
    static func drawPDFPage(_ page: CGPDFPage, in ctx: CGContext, size: CGSize, marks: PDFMarks.Source? = nil) {
        let box = page.getBoxRect(.cropBox)
        let display = displaySize(of: page)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / display.width, y: -size.height / display.height)
        ctx.clip(to: CGRect(origin: .zero, size: display))
        ctx.saveGState()
        switch rotation {
        case 90:
            ctx.translateBy(x: 0, y: display.height)
            ctx.rotate(by: -.pi / 2)
        case 180:
            ctx.translateBy(x: display.width, y: display.height)
            ctx.rotate(by: .pi)
        case 270:
            ctx.translateBy(x: display.width, y: 0)
            ctx.rotate(by: .pi / 2)
        default:
            break
        }
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.clip(to: box)
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        if let marks { PDFMarks.draw(marks, in: ctx) }
        ctx.restoreGState()
    }

    /// Renders a page (background plus ink clipped to the page) to an image `width` points wide. Thread-safe.
    /// A whiteboard is drawn as the part of it that has something on it.
    /// Without `paper` the picture is clear where the page has nothing on it.
    static func image(of page: NotebookPage, ink: PKDrawing, assets: URL, width: CGFloat, scale: CGFloat = 1,
                      includeBackground: Bool = true, links: LinkTitles? = nil, lifted: Set<UUID> = [], night: Bool = false, paper: Bool = true) -> UIImage {
        let page = Whiteboard.whole(page, ink: ink)
        let factor = width / max(page.size.width, 1)
        let size = CGSize(width: width, height: (page.size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat(scale: scale, opaque: paper || !includeBackground)
        let onPaper = includeBackground && paper
        let appearance = UITraitCollection(userInterfaceStyle: onPaper ? page.inkAppearance(night: night) : .light)
        let runs = inkRuns(ink, within: page.inkRect, multiplying: !(onPaper && page.isDark(night: night)))
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            if includeBackground {
                drawBackground(page, assets: assets, in: context.cgContext, size: size, links: links, night: night, paper: paper)
            } else {
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            for run in runs {
                autoreleasepool {
                    var picture: UIImage?
                    appearance.performAsCurrent { picture = run.ink.image(from: page.inkRect, scale: factor * scale) }
                    picture?.draw(in: CGRect(origin: .zero, size: size), blendMode: run.multiplies ? .multiply : .normal, alpha: 1)
                }
            }
            if includeBackground { drawOverInk(page, assets: assets, in: context.cgContext, size: size, lifted: lifted) }
        }
    }

    /// The ink as one picture, or cut where the highlighter starts and stops so it can be multiplied over what is under it.
    static func inkRuns(_ ink: PKDrawing, within rect: CGRect, multiplying: Bool) -> [(ink: PKDrawing, multiplies: Bool)] {
        let strokes = ink.strokes
        guard !strokes.isEmpty else { return [] }
        guard multiplying, strokes.contains(where: { $0.ink.inkType == .marker }) else { return [(ink, false)] }
        var runs: [(strokes: [PKStroke], multiplies: Bool)] = []
        for stroke in strokes where stroke.renderBounds.intersects(rect) {
            let marker = stroke.ink.inkType == .marker
            if runs.last?.multiplies == marker { runs[runs.count - 1].strokes.append(stroke) } else { runs.append(([stroke], marker)) }
        }
        return runs.map { (PKDrawing(strokes: $0.strokes), $0.multiplies) }
    }
}

extension UIGraphicsImageRendererFormat {
    /// A plain format (not the screen's `preferred()`) at `scale`.
    convenience init(scale: CGFloat, opaque: Bool = false) {
        self.init()
        self.scale = scale
        self.opaque = opaque
    }
}
