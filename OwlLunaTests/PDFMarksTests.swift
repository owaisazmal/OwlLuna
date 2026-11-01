import XCTest
import PDFKit
import PencilKit
@testable import OwlLuna

/// A PDF marked up in another app shows its highlights and filled-in forms wherever its pages are drawn, and its links
/// come in as links on the page that work there and in the export.
@MainActor
final class PDFMarksTests: XCTestCase {
    /// In the PDF's own space, which runs up a Letter page.
    private let highlightBox = CGRect(x: 72, y: 680, width: 200, height: 30)
    private let fieldBox = CGRect(x: 72, y: 500, width: 240, height: 30)
    private let insideBox = CGRect(x: 72, y: 400, width: 150, height: 24)
    private let webBox = CGRect(x: 72, y: 340, width: 150, height: 24)

    /// The same box on the page as it is shown, which runs down it.
    private func shown(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: PageSize.letter.points.height - box.maxY, width: box.width, height: box.height)
    }

    /// Two pages as another app leaves them: a highlight, a filled-in field, a link to the second page and one to the web.
    private func markedPDF(rotated: Bool = false) throws -> URL {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: PageSize.letter.points)).pdfData { context in
            for title in ["Field notes", "Methods"] {
                context.beginPage()
                (title as NSString).draw(at: CGPoint(x: 72, y: 600), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
        // PDFKit on iOS writes the links of a document it read as going nowhere, so the PDF is made new.
        let printed = try XCTUnwrap(PDFDocument(data: data)), document = PDFDocument()
        for index in 0..<printed.pageCount { document.insert(try XCTUnwrap(printed.page(at: index)?.copy() as? PDFPage), at: index) }
        let first = try XCTUnwrap(document.page(at: 0)), second = try XCTUnwrap(document.page(at: 1))
        if rotated { first.rotation = 90 }
        let highlight = PDFAnnotation(bounds: highlightBox, forType: .highlight, withProperties: nil)
        highlight.color = .yellow
        first.addAnnotation(highlight)
        let field = PDFAnnotation(bounds: fieldBox, forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "name"
        field.font = UIFont.boldSystemFont(ofSize: 22)
        field.widgetStringValue = "WWWWWWWWW"
        first.addAnnotation(field)
        let inside = PDFAnnotation(bounds: insideBox, forType: .link, withProperties: nil)
        inside.destination = PDFDestination(page: second, at: CGPoint(x: 0, y: 792))
        first.addAnnotation(inside)
        let web = PDFAnnotation(bounds: webBox, forType: .link, withProperties: nil)
        web.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com/guide")))
        first.addAnnotation(web)
        let hidden = PDFAnnotation(bounds: CGRect(x: 72, y: 280, width: 150, height: 24), forType: .link, withProperties: nil)
        hidden.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com/hidden")))
        hidden.shouldDisplay = false
        first.addAnnotation(hidden)
        let url = temporaryRoot(self).url.appending(path: "Marked.pdf")
        XCTAssertTrue(document.write(to: url))
        return url
    }

    private func imported(_ root: StorageRoot) async throws -> (package: NotebookPackage, pages: [NotebookPage]) {
        let package = NotebookPackage(root: root, id: UUID())
        let file = try await package.importAsset(from: try markedPDF(), ext: "pdf")
        return (package, try PDFImport.pages(at: package.assetURL(file), file: file))
    }

    private func pixel(_ image: CGImage, at point: CGPoint) throws -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -point.x.rounded(.down), y: point.y.rounded(.down) - CGFloat(image.height) + 1,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    /// The share of a box's pixels, at `scale` pixels a point, that are dark: the letters of a filled-in field.
    private func inked(_ image: CGImage, in box: CGRect, scale: CGFloat = 1) throws -> Double {
        let points = stride(from: box.minX + 1, to: box.maxX - 1, by: 1).flatMap { x in
            stride(from: box.minY + 1, to: box.maxY - 1, by: 1).map { CGPoint(x: x * scale, y: $0 * scale) }
        }
        let dark = try points.filter { let p = try pixel(image, at: $0); return p.r + p.g + p.b < 240 }
        return Double(dark.count) / Double(points.count)
    }

    private func assertMarks(_ image: CGImage, scale: CGFloat = 1, _ place: String, line: UInt = #line) throws {
        let highlight = shown(highlightBox)
        let yellow = try pixel(image, at: CGPoint(x: highlight.midX * scale, y: highlight.midY * scale))
        XCTAssertTrue(yellow.r > 200 && yellow.g > 200 && yellow.b < 120, "the highlight shows \(place): \(yellow)", line: line)
        XCTAssertGreaterThan(try inked(image, in: shown(fieldBox), scale: scale), 0.05, "the field's words show \(place)", line: line)
    }

    func testAPDFPageShowsItsHighlightAndFilledInFieldWhereverItIsDrawn() async throws {
        let (package, pages) = try await imported(temporaryRoot(self))
        let assets = package.assetsDirectory, page = pages[0]
        let picture = try XCTUnwrap(PageRenderer.image(of: page, ink: PKDrawing(), assets: assets, width: page.size.width).cgImage)
        try assertMarks(picture, "on the page")
        let night = try XCTUnwrap(PageRenderer.image(of: page, ink: PKDrawing(), assets: assets, width: page.size.width, night: true).cgImage)
        try assertMarks(night, "with paper dark, since a PDF keeps its own colours")
        let tile = try XCTUnwrap(PagePaperView.image(of: page, assets: assets, unit: 1, density: 0.5, pixels: CGRect(x: 0, y: 0, width: 306, height: 396)))
        try assertMarks(tile, scale: 0.5, "in the editor's paper")

        let plain = try XCTUnwrap(CGPDFDocument(package.assetURL(try XCTUnwrap(page.background.assetFile)) as CFURL)?.page(at: 1))
        let bare = UIGraphicsImageRenderer(size: page.size, format: UIGraphicsImageRendererFormat(scale: 1, opaque: true)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: page.size))
            PageRenderer.drawPDFPage(plain, in: context.cgContext, size: page.size)
        }
        XCTAssertEqual(try inked(try XCTUnwrap(bare.cgImage), in: shown(fieldBox)), 0, "the page's own content has none of it: it's drawn from the marks")

        let reading = try XCTUnwrap(PDFDocument(url: package.assetURL(try XCTUnwrap(page.background.assetFile)))?.page(at: 0))
        let scan = try XCTUnwrap(PDFText.picture(of: reading)?.cgImage)
        try assertMarks(scan, scale: CGFloat(scan.height) / page.size.height, "where its words are read")
    }

    func testRotatedPDFKeepsMarksAndLinksInTheirShownPositions() async throws {
        let package = NotebookPackage(root: temporaryRoot(self), id: UUID())
        let file = try await package.importAsset(from: try markedPDF(rotated: true), ext: "pdf")
        let pages = try PDFImport.pages(at: package.assetURL(file), file: file)
        let page = try XCTUnwrap(pages.first)
        XCTAssertEqual(page.size, CGSize(width: 792, height: 612))
        let image = try XCTUnwrap(PageRenderer.image(of: page, ink: PKDrawing(), assets: package.assetsDirectory, width: page.size.width).cgImage)
        let yellow = try pixel(image, at: CGPoint(x: highlightBox.midY, y: highlightBox.midX))
        XCTAssertTrue(yellow.r > 200 && yellow.g > 200 && yellow.b < 120, "the highlight follows the page rotation: \(yellow)")
        let field = CGRect(x: fieldBox.minY, y: fieldBox.minX, width: fieldBox.height, height: fieldBox.width)
        XCTAssertGreaterThan(try inked(image, in: field), 0.05)
        let inside = try XCTUnwrap(page.items.first { $0.link?.target != nil })
        XCTAssertEqual(inside.boundingBox.midX, insideBox.midY, accuracy: 0.5)
        XCTAssertEqual(inside.boundingBox.midY, insideBox.midX, accuracy: 0.5)
    }

    func testItsLinksComeInAsLinksOverTheirWords() async throws {
        let (_, pages) = try await imported(temporaryRoot(self))
        XCTAssertEqual(pages.count, 2)
        XCTAssertTrue(pages.allSatisfy(\.hasPDFLinksRead))
        XCTAssertFalse(pages[1].hasItems)
        let links = pages[0].items
        XCTAssertEqual(links.count, 2, "the highlight and the field aren't items")
        XCTAssertTrue(links.allSatisfy(\.isPDFLink))
        let inside = try XCTUnwrap(links.first { $0.link?.target != nil })
        XCTAssertEqual(inside.link?.destination, .page(pages[1].id), "it opens the notebook's page of the PDF page it went to")
        XCTAssertEqual(inside.boundingBox.minX, shown(insideBox).minX, accuracy: 0.5)
        XCTAssertEqual(inside.boundingBox.minY, shown(insideBox).minY, accuracy: 0.5)
        XCTAssertEqual(inside.size.width, insideBox.width, accuracy: 0.5)
        XCTAssertEqual(inside.size.height, insideBox.height, accuracy: 0.5)
        let web = try XCTUnwrap(links.first { $0.link?.target == nil })
        XCTAssertEqual(web.link?.destination, .web(try XCTUnwrap(URL(string: "https://example.com/guide"))))
        XCTAssertEqual(web.boundingBox.midY, shown(webBox).midY, accuracy: 0.5)

        let stored = try XCTUnwrap(PageItem(json: inside.json))
        XCTAssertTrue(stored.isPDFLink, "kept as a PDF's link when saved")
        XCTAssertFalse(PageItem(content: .link(PageLink(target: pages[1].id)), center: .zero, size: CGSize(width: 90, height: 30)).isPDFLink)
    }

    func testTheExportKeepsTheMarksAndOneOfEachLink() async throws {
        let (package, pages) = try await imported(temporaryRoot(self))
        let input = NotebookExporter.Input(title: "Marked", pages: pages, inMemoryInk: [:], package: package)
        let url = try await NotebookExporter.export(input) { _ in }
        let exported = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: 1))
        XCTAssertFalse(PDFMarks.has(exported), "the marks are drawn into the page, not left as annotations")
        let size = PageRenderer.displaySize(of: exported)
        let drawn = UIGraphicsImageRenderer(size: size, format: UIGraphicsImageRendererFormat(scale: 1, opaque: true)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            PageRenderer.drawPDFPage(exported, in: context.cgContext, size: size)
        }
        let image = try XCTUnwrap(drawn.cgImage)
        try assertMarks(image, "in the exported PDF")
        let mustard = try pixel(image, at: CGPoint(x: shown(insideBox).maxX - 4, y: shown(insideBox).minY + 3))
        XCTAssertTrue(mustard.r > 235 && mustard.b < 230 && mustard.r > mustard.b + 20, "a link to a page has a mustard wash: \(mustard)")
        let sky = try pixel(image, at: CGPoint(x: shown(webBox).maxX - 4, y: shown(webBox).minY + 3))
        XCTAssertTrue(sky.b > 240 && sky.r < 235 && sky.b > sky.r + 15, "a web link has a sky wash: \(sky)")

        let document = try XCTUnwrap(PDFDocument(url: url))
        let links = try XCTUnwrap(document.page(at: 0)).annotations.filter { $0.type == "Link" }
        XCTAssertEqual(links.count, 2, "each link once: the PDF's own aren't carried as well")
        XCTAssertEqual(links.compactMap { ($0.action as? PDFActionURL)?.url?.absoluteString }, ["https://example.com/guide"])
        let goes = links.compactMap { ($0.destination ?? ($0.action as? PDFActionGoTo)?.destination)?.page }.map(document.index(for:))
        XCTAssertEqual(goes, [1], "the link to the second page still goes there")

        let pngs = try await NotebookExporter.exportImages(input) { _ in }
        let png = try XCTUnwrap(UIImage(contentsOfFile: pngs[0].path(percentEncoded: false))?.cgImage)
        try assertMarks(png, scale: 2, "in an exported picture")
    }

    func testANotebookImportedBeforeGetsItsLinksOnceWhenItOpens() async throws {
        let root = temporaryRoot(self)
        let (package, imported) = try await imported(root)
        let earlier = imported.map { page in
            var page = page
            page.items = []
            page.hasPDFLinksRead = false
            return page
        }
        let manifest = NotebookManifest(id: package.id, title: "Earlier", defaults: PageDefaults(template: .blank, paperColor: .white, pageSize: .letter),
                                        pages: earlier)
        try await package.create(manifest)

        let document = try await NotebookDocument.open(package.id, root: root)
        let links = document.pages[0].items
        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(links.contains { $0.link?.destination == .page(document.pages[1].id) })
        XCTAssertTrue(document.hasUnsavedChanges)
        document.updatePage(document.pages[0].id, actionName: "Delete") { $0.items = [] }
        let saved = await document.save()
        XCTAssertTrue(saved)

        let again = try await NotebookDocument.open(package.id, root: root)
        XCTAssertFalse(again.pages[0].hasItems, "links taken off stay off")
        XCTAssertFalse(again.hasUnsavedChanges)
    }

    func testExportingAnOlderNotebookReadsItsLinksWithoutOpeningIt() async throws {
        let root = temporaryRoot(self)
        let (package, imported) = try await imported(root)
        let pages = imported.map { page in
            var page = page
            page.items = []
            page.hasPDFLinksRead = false
            return page
        }
        let manifest = NotebookManifest(id: package.id, title: "Earlier", defaults: PageDefaults(template: .blank, paperColor: .white, pageSize: .letter),
                                        pages: pages)
        try await package.create(manifest)
        let input = try await NotebookExporter.input(for: package.id, root: root)
        XCTAssertEqual(input.pages[0].items.count, 2)
        let output = try await NotebookExporter.export(input) { _ in }
        let document = try XCTUnwrap(PDFDocument(url: output))
        let links = try XCTUnwrap(document.page(at: 0)).annotations.filter { $0.type == "Link" }
        XCTAssertEqual(links.count, 2)
    }

    func testMissingPDFLinksAreRetriedWhenItsAssetBecomesAvailable() async throws {
        let (package, imported) = try await imported(temporaryRoot(self))
        let page = imported[0]
        let file = try XCTUnwrap(page.background.assetFile)
        var pages = imported.map { page in
            var page = page
            page.items = []
            page.hasPDFLinksRead = false
            return page
        }
        PDFImport.addLinks(to: &pages, from: package.assetURL("missing.pdf"), file: file)
        XCTAssertFalse(pages[0].hasPDFLinksRead)
        PDFImport.addLinks(to: &pages, from: package.assetURL(file), file: file)
        XCTAssertTrue(pages[0].hasPDFLinksRead)
        XCTAssertEqual(pages[0].items.count, 2)
    }

    func testYourOwnPaperFromAMarkedPDFKeepsItsMarks() throws {
        let root = temporaryRoot(self)
        let paper = try PaperShelf.add(pdf: try markedPDF(), name: "Form", to: root)
        let page = try XCTUnwrap(CGPDFDocument(paper.url as CFURL)?.page(at: 1))
        XCTAssertFalse(PDFMarks.has(page))
        let drawn = UIGraphicsImageRenderer(size: paper.size, format: UIGraphicsImageRendererFormat(scale: 1, opaque: true)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: paper.size))
            PageRenderer.drawPDFPage(page, in: context.cgContext, size: paper.size)
        }
        try assertMarks(try XCTUnwrap(drawn.cgImage), "on the paper")
    }
}
