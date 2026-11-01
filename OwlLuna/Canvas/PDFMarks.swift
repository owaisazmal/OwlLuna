import UIKit
import PDFKit

private final class MarkedPDF: @unchecked Sendable {
    let document: PDFDocument
    let lock = NSLock()

    init(_ document: PDFDocument) { self.document = document }
}

/// What another app left on a PDF's pages: highlights, comments, shapes, stamps and filled-in forms. Links aren't drawn:
/// an imported PDF's links are items on its pages. Thread-safe.
enum PDFMarks {
    /// Where a page's marks are read from: its file, by whichever thread draws, or a page already open on this one.
    enum Source {
        case file(URL, index: Int)
        case page(PDFPage)
    }

    private static let documents = LRUCache<MarkedPDF>(capacity: 4)
    private static let undrawn: Set<String> = ["Link", "Popup"]
    /// Hidden or NoView.
    private static let unseen: CGPDFInteger = 2 | 32

    /// Each annotation's subtype and flags, read from the page's own dictionary.
    static func annotations(of page: CGPDFPage) -> [(subtype: String, flags: CGPDFInteger)] {
        guard let dictionary = page.dictionary else { return [] }
        var list: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &list), let list else { return [] }
        return (0..<CGPDFArrayGetCount(list)).compactMap { index in
            var annotation: CGPDFDictionaryRef?
            var subtype: UnsafePointer<CChar>?
            guard CGPDFArrayGetDictionary(list, index, &annotation), let annotation,
                  CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype else { return nil }
            var flags: CGPDFInteger = 0
            _ = CGPDFDictionaryGetInteger(annotation, "F", &flags)
            return (String(cString: subtype), flags)
        }
    }

    /// Whether a page has marks to draw, so a page with none never opens PDFKit.
    static func has(_ page: CGPDFPage) -> Bool {
        annotations(of: page).contains { !undrawn.contains($0.subtype) && $0.flags & unseen == 0 }
    }

    /// Draws the marks in a context that runs up the page as it is shown, clipped to it.
    static func draw(_ source: Source, in ctx: CGContext) {
        switch source {
        case .page(let page):
            draw(page, in: ctx)
        case .file(let url, let index):
            guard let marked = documents.value(url.path(percentEncoded: false), create: { PDFDocument(url: url).map(MarkedPDF.init) }) else { return }
            marked.lock.withLock {
                guard let page = marked.document.page(at: index) else { return }
                draw(page, in: ctx)
            }
        }
    }

    private static func draw(_ page: PDFPage, in ctx: CGContext) {
        let shown = page.transform(for: .cropBox), reach = ctx.boundingBoxOfClipPath
        for annotation in page.annotations where annotation.shouldDisplay && !undrawn.contains(annotation.type ?? "") {
            // Some marks reach a little past their bounds: a note's icon, a thick border.
            guard annotation.bounds.applying(shown).insetBy(dx: -24, dy: -24).intersects(reach) else { continue }
            ctx.saveGState()
            annotation.draw(with: .cropBox, in: ctx)
            ctx.restoreGState()
        }
    }
}

extension NotebookPage {
    /// Whether the links of its PDF page have been read onto it, so they come once and one taken off stays off.
    var hasPDFLinksRead: Bool {
        get { extra["pdfLinks"]?.boolValue == true }
        set { extra["pdfLinks"] = newValue ? .bool(true) : nil }
    }

    /// An imported PDF page whose links haven't been read yet. Your own paper has none.
    var needsPDFLinks: Bool {
        guard case .pdf = background, paperID == nil else { return false }
        return !hasPDFLinksRead
    }
}

extension PageItem {
    /// A link the imported PDF had: it lies over the words it was on and shows as a wash, not a tab.
    var isPDFLink: Bool {
        get { raw["pdf"]?.boolValue == true }
        set { raw["pdf"] = newValue ? .bool(true) : nil }
    }
}

extension PDFImport {
    /// Adds the links of the PDF at `url`, kept as `file`, to those of `pages` standing on it that haven't had them read.
    /// A link to another page of the PDF opens the first of `pages` standing on that page; one to a page that isn't there,
    /// or to anything but a web address, is left out. They go behind what is on the page already.
    static func addLinks(to pages: inout [NotebookPage], from url: URL, file: String, progress: Progress? = nil) {
        var shown: [Int: UUID] = [:]
        for page in pages.reversed() where page.paperID == nil {
            if case .pdf(file, let index) = page.background { shown[index] = page.id }
        }
        let document = CGPDFDocument(url as CFURL)
        var kit: PDFDocument?
        for position in pages.indices {
            report(position, of: pages.count, to: progress)
            guard pages[position].needsPDFLinks, case .pdf(file, let index) = pages[position].background else { continue }
            guard let sheet = document?.page(at: index + 1) else { continue }
            guard PDFMarks.annotations(of: sheet).contains(where: { $0.subtype == "Link" }) else {
                pages[position].hasPDFLinksRead = true
                continue
            }
            if kit == nil { kit = PDFDocument(url: url) }
            guard let kit, let page = kit.page(at: index) else { continue }
            let display = PageRenderer.displaySize(of: sheet), size = pages[position].size
            guard display.width > 0, display.height > 0 else { continue }
            let toPage = page.transform(for: .cropBox)
                .concatenating(CGAffineTransform(a: size.width / display.width, b: 0, c: 0, d: -size.height / display.height, tx: 0, ty: size.height))
            let links = page.annotations.compactMap { annotation -> PageItem? in
                guard annotation.type == "Link", annotation.shouldDisplay, let destination = destination(of: annotation, in: kit, shown: shown) else { return nil }
                let area = annotation.bounds.applying(toPage).intersection(CGRect(origin: .zero, size: size))
                guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
                var item = PageItem(content: .link(PageLink(destination)), center: CGPoint(x: area.midX, y: area.midY), size: area.size)
                item.isPDFLink = true
                return item
            }
            if !links.isEmpty { pages[position].items = links + pages[position].items }
            pages[position].hasPDFLinksRead = true
        }
    }

    private static func destination(of link: PDFAnnotation, in document: PDFDocument, shown: [Int: UUID]) -> PageLink.Destination? {
        if let url = (link.action as? PDFActionURL)?.url { return WebAddress.url(from: url.absoluteString).map { .web($0) } }
        guard let page = (link.destination ?? (link.action as? PDFActionGoTo)?.destination)?.page, page.document === document else { return nil }
        return shown[document.index(for: page)].map { .page($0) }
    }

    /// The pages of a notebook opened from before links were read on import, with them read now. Only once: each page
    /// is marked as read, links or none.
    static func linking(_ load: ManifestLoad, in package: NotebookPackage) async -> ManifestLoad {
        guard load.manifest.pages.contains(where: \.needsPDFLinks) else { return load }
        return await Task.detached(priority: .userInitiated) {
            var load = load, pages = load.manifest.pages
            var files: [String] = []
            for page in pages where page.needsPDFLinks {
                if case .pdf(let file, _) = page.background, !files.contains(file) { files.append(file) }
            }
            for file in files { addLinks(to: &pages, from: package.assetURL(file), file: file) }
            if pages != load.manifest.pages {
                load.manifest.pages = pages
                if !load.isReadOnly { load.needsSave = true }
            }
            return load
        }.value
    }
}
