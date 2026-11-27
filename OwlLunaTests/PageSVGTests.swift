import XCTest
import ImageIO
import PencilKit
@testable import OwlLuna

/// A page as SVG: well-formed, its groups in order, without paper as the other exports are, and drawn as the PNG export draws it.
@MainActor
final class PageSVGTests: XCTestCase {
    private let defaults = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)

    /// The document's elements in the order written, each with the one it is in.
    private final class Tree: NSObject, XMLParserDelegate {
        struct Node {
            let name: String
            let attributes: [String: String]
            let parent: Int?
            var text = ""
        }

        private(set) var nodes: [Node] = []
        private var open: [Int] = []

        static func parse(_ data: Data) throws -> Tree {
            let tree = Tree(), parser = XMLParser(data: data)
            parser.delegate = tree
            guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
            return tree
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            nodes.append(Node(name: name, attributes: attributes, parent: open.last))
            open.append(nodes.count - 1)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            open.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let last = open.last { nodes[last].text += string }
        }

        var groups: [String] { nodes.filter { $0.parent == 0 && $0.name == "g" }.compactMap { $0.attributes["id"] } }

        func named(_ name: String) -> [Node] { nodes.filter { $0.name == name } }

        func node(id: String) -> Node? { nodes.first { $0.attributes["id"] == id } }

        func children(of id: String) -> [Node] {
            guard let index = nodes.firstIndex(where: { $0.attributes["id"] == id }) else { return [] }
            return nodes.filter { $0.parent == index }
        }

        /// The group at the top of the document that a node is, or is in.
        func group(of node: Node) -> String? {
            var current: Node? = node
            while let next = current {
                if next.parent == 0 { return next.name == "g" ? next.attributes["id"] : nil }
                current = next.parent.map { nodes[$0] }
            }
            return nil
        }
    }

    private struct Fixture {
        let package: NotebookPackage
        var assets: URL { package.assetsDirectory }
        let ruled: NotebookPage, daily: NotebookPage, pdf: NotebookPage, photo: NotebookPage, board: NotebookPage, everything: NotebookPage
        let dark: NotebookPage, boardInk: PKDrawing
        let web: URL
    }

    private func fixture() async throws -> Fixture {
        let root = temporaryRoot(self), id = UUID()
        let package = NotebookPackage(root: root, id: id)
        try await package.create(NotebookManifest(id: id, title: "SVG", defaults: defaults, pages: []))
        let letter = PageSize.letter.points

        let printed = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: letter)).pdfData { context in
            context.beginPage()
            UIColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1).setFill()
            context.fill(CGRect(x: 60, y: 80, width: 300, height: 120))
            ("Osmosis" as NSString).draw(at: CGPoint(x: 80, y: 260), withAttributes: [.font: UIFont.systemFont(ofSize: 48, weight: .black)])
        }
        let pdfFile = try await package.writeAsset(printed, ext: "pdf")

        let photoFormat = UIGraphicsImageRendererFormat(scale: 1, opaque: true)
        let shot = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: photoFormat).jpegData(withCompressionQuality: 0.85) { context in
            for y in stride(from: 0, to: 1200, by: 40) {
                for x in stride(from: 0, to: 1600, by: 40) {
                    UIColor(red: CGFloat(x) / 1600, green: CGFloat(y) / 1200, blue: CGFloat((x + y) % 400) / 400, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 40, height: 40))
                }
            }
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 1000, y: 200, width: 400, height: 400))
        }
        let photoFile = try await package.writeAsset(shot, ext: "jpg")

        let cutout = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: UIGraphicsImageRendererFormat(scale: 1)).pngData { context in
            UIColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 20, y: 20, width: 360, height: 260))
            UIColor.black.setFill()
            context.fill(CGRect(x: 180, y: 0, width: 40, height: 300))
        }
        let cutoutFile = try await package.writeAsset(cutout, ext: "png")

        let ruled = NotebookPage.template(.narrowRuled, color: .yellow, size: .letter)
        var daily = NotebookPage.template(.dotted, color: .ivory, size: .letter)
        daily.day = "2026-11-26"
        let pdf = NotebookPage(background: .pdf(file: pdfFile, index: 0), paperColor: .white, size: letter)
        let photo = NotebookPage(background: .image(file: photoFile), paperColor: .white, size: CGSize(width: 800, height: 600))

        var board = NotebookPage.board(template: .grid, color: .sage)
        let middle = Whiteboard.center
        board.items = [PageItem(content: .sticker("star"), center: CGPoint(x: middle.x + 300, y: middle.y - 120), size: CGSize(width: 90, height: 90), rotation: 0.3)]
        let boardInk = PKDrawing(strokes: [stroke(from: CGPoint(x: middle.x - 400, y: middle.y), to: CGPoint(x: middle.x + 200, y: middle.y + 150), width: 6)])

        let web = try XCTUnwrap(URL(string: "https://example.com/notes?a=1&b=\"2\""))
        var everything = NotebookPage.template(.grid, color: .white, size: .letter)
        var turned = PageItem(content: .image(file: photoFile), center: CGPoint(x: 220, y: 190), size: CGSize(width: 640, height: 480))
            .cropped(to: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5))
        turned.rotation = 0.35
        var linkToPage = PageItem(content: .link(PageLink(target: ruled.id)), center: CGPoint(x: 440, y: 600), size: CGSize(width: 180, height: 30))
        linkToPage.rotation = -0.2
        var wash = PageItem(content: .link(PageLink(.web(web))), center: CGPoint(x: 300, y: 700), size: CGSize(width: 160, height: 24))
        wash.isPDFLink = true
        everything.items = [
            turned,
            PageItem(content: .image(file: cutoutFile), center: CGPoint(x: 470, y: 180), size: CGSize(width: 200, height: 150), rotation: -0.5),
            PageItem(content: .image(file: photoFile), center: CGPoint(x: 540, y: 330), size: CGSize(width: 80, height: 60), rotation: 0.6),
            PageItem(content: .sticker("noteYellow"), center: CGPoint(x: 140, y: 420), size: CGSize(width: 140, height: 140), rotation: 0.15),
            PageItem(content: .text(TextBox(string: "Cells & tissues <3\nMitochondria \"power\" it", fontSize: 22, isBold: true, tint: .cobalt, list: .bullet)),
                     center: CGPoint(x: 400, y: 430), size: CGSize(width: 260, height: 60), rotation: -0.12).fittedToText(),
            PageItem(content: .link(PageLink(.web(web))), center: CGPoint(x: 180, y: 600), size: CGSize(width: 200, height: 30)),
            linkToPage,
            wash,
            PageItem(content: .tape(.rose), center: CGPoint(x: 300, y: 520), size: CGSize(width: 240, height: 36), rotation: 0.2),
        ]
        var dark = NotebookPage.template(.wideRuled, color: .charcoal, size: .letter)
        dark.items = [PageItem(content: .text(TextBox(string: "Chalk-white words", fontSize: 28)), center: CGPoint(x: 300, y: 200),
                               size: CGSize(width: 300, height: 40)).fittedToText()]
        return Fixture(package: package, ruled: ruled, daily: daily, pdf: pdf, photo: photo, board: board, everything: everything, dark: dark,
                       boardInk: boardInk, web: web)
    }

    private func svg(_ page: NotebookPage, ink: PKDrawing = PKDrawing(), _ fixture: Fixture, title: String = "Page", paper: Bool = true) -> Data {
        var options = NotebookExporter.Options()
        options.paper = paper
        return PageSVG.data(for: page, ink: ink, assets: fixture.assets, title: title, options: options, links: LinkTitles(pages: [fixture.ruled]))
    }

    private func picture(_ node: Tree.Node) throws -> (type: String, image: CGImage) {
        let href = try XCTUnwrap(node.attributes["xlink:href"])
        XCTAssertNil(node.attributes["href"], "the picture isn't written twice")
        let parts = href.split(separator: ",", maxSplits: 1)
        XCTAssertEqual(parts.count, 2)
        let head = String(parts[0]), type = head.replacingOccurrences(of: "data:", with: "").replacingOccurrences(of: ";base64", with: "")
        XCTAssertTrue(["data:image/png;base64", "data:image/jpeg;base64"].contains(head), head)
        let data = try XCTUnwrap(Data(base64Encoded: String(parts[1])), "the payload is base64")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, type == "image/png" ? "public.png" : "public.jpeg")
        return (type, try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    func testEveryKindOfPageIsWellFormedWithItsGroupsInOrder() async throws {
        let f = try await fixture()
        let cases: [(String, NotebookPage, PKDrawing, [String])] = [
            ("ruled", f.ruled, PKDrawing(), ["paper", "ink"]),
            ("daily", f.daily, PKDrawing(), ["paper", "ink"]),
            ("pdf", f.pdf, PKDrawing(), ["paper", "ink"]),
            ("photo", f.photo, PKDrawing(), ["paper", "ink"]),
            ("board", f.board, f.boardInk, ["paper", "items", "ink"]),
            ("everything", f.everything, PKDrawing(strokes: [stroke(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 300, y: 90))]), ["paper", "items", "ink", "tape"]),
        ]
        for (name, page, ink, groups) in cases {
            let data = svg(page, ink: ink, f)
            let tree = try Tree.parse(data)
            let root = try XCTUnwrap(tree.nodes.first)
            let whole = Whiteboard.whole(page, ink: ink)
            let width = SVGText.number(whole.size.width), height = SVGText.number(whole.size.height)
            XCTAssertEqual(root.name, "svg", name)
            XCTAssertEqual(root.attributes["xmlns"], "http://www.w3.org/2000/svg", name)
            XCTAssertEqual(root.attributes["xmlns:xlink"], "http://www.w3.org/1999/xlink", name)
            XCTAssertEqual(root.attributes["width"], width, name)
            XCTAssertEqual(root.attributes["height"], height, name)
            XCTAssertEqual(root.attributes["viewBox"], "0 0 \(width) \(height)", name)
            XCTAssertEqual(tree.groups, groups, name)
            for node in tree.nodes where tree.group(of: node) != "ink" {
                XCTAssertFalse(node.attributes["id"]?.hasPrefix("ink") ?? false, "\(name): ids beginning with ink are the ink writer's")
            }
            XCTAssertTrue(tree.named("script").isEmpty && tree.named("style").isEmpty, name)
            XCTAssertFalse(tree.nodes.contains { $0.attributes["class"] != nil || $0.attributes["style"] != nil }, name)
            for node in tree.nodes where node.name != "a" {
                XCTAssertTrue(node.attributes["xlink:href"].map { $0.hasPrefix("data:image/") } ?? true, "\(name): nothing is fetched from outside")
            }
            for image in tree.named("image") { _ = try picture(image) }
        }
        XCTAssertEqual(try Tree.parse(svg(f.board, ink: f.boardInk, f)).children(of: "paper").map(\.name), ["rect", "image"], "a board's grid goes in")
    }

    func testWithoutPaperOnlyAPDFPageOrAPhotoStays() async throws {
        let f = try await fixture()
        let ruled = try Tree.parse(svg(f.ruled, f))
        XCTAssertEqual(ruled.children(of: "paper").map(\.name), ["rect", "image"])
        XCTAssertEqual(ruled.children(of: "paper").first?.attributes["fill"], SVGText.color(PageRenderer.paperColor(.yellow)).hex)
        let bareRuled = try Tree.parse(svg(f.ruled, f, paper: false))
        XCTAssertNil(bareRuled.node(id: "paper"), "no colour or ruling")
        XCTAssertTrue(bareRuled.named("image").isEmpty && bareRuled.named("rect").isEmpty)
        XCTAssertNil(try Tree.parse(svg(f.daily, f, paper: false)).node(id: "paper"), "nor a masthead")

        for (name, page) in [("pdf", f.pdf), ("photo", f.photo)] {
            XCTAssertEqual(try Tree.parse(svg(page, f)).children(of: "paper").map(\.name), ["rect", "image"], name)
            let bare = try Tree.parse(svg(page, f, paper: false))
            XCTAssertEqual(bare.children(of: "paper").map(\.name), ["image"], "\(name) stays without its paper")
        }
        let (type, photo) = try picture(try XCTUnwrap(Tree.parse(svg(f.photo, f, paper: false)).children(of: "paper").first))
        XCTAssertEqual(type, "image/jpeg")
        XCTAssertEqual(photo.width, 1600, "a photo page keeps its own pixels")

        let blank = defaults.newPage()
        let plain = try Tree.parse(svg(blank, f))
        XCTAssertEqual(plain.children(of: "paper").map(\.name), ["rect"], "a blank page needs no picture")
        let bare = try Tree.parse(svg(blank, f, paper: false))
        XCTAssertTrue(bare.named("image").isEmpty)
        XCTAssertEqual(bare.groups, ["ink"])
    }

    func testPicturesDecodeAndEachItemIsPlacedAsItIs() async throws {
        let f = try await fixture()
        let tree = try Tree.parse(svg(f.everything, f))
        let written = f.everything.items.filter { !$0.isOverInk } + f.everything.items.filter(\.isOverInk)
        for (index, item) in written.enumerated() {
            let id = "item-\(index + 1)"
            let node = try XCTUnwrap(tree.node(id: id), id)
            XCTAssertEqual(node.name, "image")
            XCTAssertEqual(tree.group(of: node), item.isOverInk ? "tape" : "items", id)
            let number = { (key: String) in CGFloat(Double(node.attributes[key] ?? "") ?? .nan) }
            XCTAssertEqual(number("width"), item.size.width, accuracy: 0.01, id)
            XCTAssertEqual(number("height"), item.size.height, accuracy: 0.01, id)
            XCTAssertEqual(number("x"), -item.size.width / 2, accuracy: 0.01, id)
            XCTAssertEqual(number("y"), -item.size.height / 2, accuracy: 0.01, id)
            let transform = try XCTUnwrap(Transform(node.attributes["transform"] ?? ""), id)
            XCTAssertEqual(transform.translation.x, item.center.x, accuracy: 0.01, id)
            XCTAssertEqual(transform.translation.y, item.center.y, accuracy: 0.01, id)
            XCTAssertEqual(transform.degrees, item.rotation * 180 / .pi, accuracy: 0.01, id)
            XCTAssertEqual(node.attributes["preserveAspectRatio"], "none")
            let (type, image) = try picture(node)
            let parent = node.parent.map { tree.nodes[$0] }
            if let url = item.link?.externalURL {
                XCTAssertEqual(parent?.name, "a", id)
                XCTAssertEqual(parent?.attributes["xlink:href"], url.absoluteString, id)
            } else {
                XCTAssertEqual(parent?.name, "g", id)
            }
            let position = tree.nodes.firstIndex { $0.attributes["id"] == id }
            let desc = tree.nodes.filter { $0.name == "desc" && $0.parent == position }
            XCTAssertEqual(desc.first?.text, item.text?.string, id)
            switch item.content {
            case .image(let file) where file.hasSuffix("jpg"):
                XCTAssertEqual(type, "image/jpeg", "\(id): an opaque photo")
                let own = PageItemRenderer.pixels(of: item.crop ?? PageItem.wholePicture, width: 1600, height: 1200)
                let limit = min(1, PageSVG.photoLimit * item.size.width / own.width)
                XCTAssertEqual(CGFloat(image.width), (own.width * limit).rounded(), accuracy: 1, "\(id): its own pixels, cropped, no finer than the limit")
                XCTAssertEqual(CGFloat(image.height), (own.height * limit).rounded(), accuracy: 1, id)
            case .image:
                XCTAssertEqual(type, "image/png", "\(id): a picture with clear parts")
                XCTAssertEqual(image.width, 400)
            default:
                XCTAssertEqual(type, "image/png", id)
                XCTAssertEqual(CGFloat(image.width), (item.size.width * PageSVG.itemScale).rounded(), accuracy: 1, "\(id): drawn sharp")
            }
        }
        XCTAssertNil(tree.node(id: "item-\(written.count + 1)"))

        let title = "Tom & Jerry's <\"notes\"> \u{1F989}"
        XCTAssertEqual(try Tree.parse(svg(f.ruled, f, title: title)).named("title").first?.text, title)
    }

    func testTheWholeIsDrawnAsThePNGExportDrawsIt() async throws {
        let f = try await fixture()
        let cases: [(String, NotebookPage, Bool)] = [
            ("everything", f.everything, true), ("everything without paper", f.everything, false), ("daily", f.daily, true), ("pdf", f.pdf, true),
            ("pdf without paper", f.pdf, false), ("photo", f.photo, true), ("dark", f.dark, true), ("board", f.board, true),
        ]
        for (name, page, paper) in cases {
            let whole = Whiteboard.whole(page, ink: PKDrawing())
            let scale: CGFloat = 2
            let drawing = try Drawing(Tree.parse(svg(page, f, paper: paper)))
            let export = PageRenderer.image(of: page, ink: PKDrawing(), assets: f.assets, width: whole.size.width, scale: scale,
                                            links: LinkTitles(pages: [f.ruled]), paper: paper)
            let expected = Pixels(whole.size, scale: scale) { _ in export.draw(in: CGRect(origin: .zero, size: whole.size)) }
            let ours = Pixels(whole.size, scale: scale) { drawing.draw(in: $0) }
            let all = ours.difference(to: expected, in: CGRect(origin: .zero, size: whole.size))
            XCTAssertLessThan(all.bad, 0.001, "\(name): \(all)")
            XCTAssertLessThan(all.mean, 1.5, "\(name): \(all)")
            for (index, item) in drawing.items.enumerated() {
                let box = item.box.insetBy(dx: -2, dy: -2)
                let near = ours.difference(to: expected, in: box)
                XCTAssertLessThan(near.bad, 0.015, "\(name), \(item.id): \(near)")
                guard name == "everything" else { continue }
                for (wrong, change) in Drawing.mistakes {
                    var mistaken = drawing
                    change(&mistaken.items[index])
                    let off = Pixels(whole.size, scale: scale) { mistaken.draw(in: $0) }.difference(to: expected, in: box.union(mistaken.items[index].box))
                    // More of the box far off, or on faint art like a PDF link's wash, more of it changed at all.
                    XCTAssertTrue(off.bad > near.bad + 0.015 || off.changed > near.changed + 0.04, "\(item.id) \(wrong) would be caught: \(off)")
                }
            }
        }
    }

    /// `translate(x y)` with an optional `rotate(degrees)` after it, as the items are placed.
    private struct Transform {
        var translation: CGPoint
        var degrees: CGFloat

        init?(_ text: String) {
            let numbers = text.replacingOccurrences(of: "translate(", with: " ").replacingOccurrences(of: "rotate(", with: " ")
                .replacingOccurrences(of: ")", with: " ").split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) }
            guard text.hasPrefix("translate("), numbers.count == 2 || numbers.count == 3 && text.contains(") rotate(") else { return nil }
            translation = CGPoint(x: numbers[0], y: numbers[1])
            degrees = numbers.count == 3 ? numbers[2] : 0
        }
    }

    /// The rects and images the page writer uses, drawn as a browser would.
    private struct Drawing {
        struct Item {
            var id: String
            var rect: CGRect
            var transform: Transform
            var image: UIImage

            /// The upright box it covers on the page.
            var box: CGRect {
                rect.applying(CGAffineTransform(translationX: transform.translation.x, y: transform.translation.y).rotated(by: transform.degrees * .pi / 180))
            }
        }

        var fills: [(CGRect, UIColor)] = []
        var paper: [(CGRect, UIImage)] = []
        var items: [Item] = []

        static var mistakes: [(String, (inout Item) -> Void)] { [
            ("moved 6 pt", { $0.transform.translation.x += 6 }),
            ("turned 5° more", { $0.transform.degrees += 5 }),
            ("a tenth larger", { $0.rect = $0.rect.insetBy(dx: -$0.rect.width / 20, dy: -$0.rect.height / 20) }),
        ] }

        init(_ tree: Tree) throws {
            for node in tree.nodes {
                let value = { (key: String) in CGFloat(Double(node.attributes[key] ?? "0") ?? 0) }
                let rect = CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))
                switch node.name {
                case "rect":
                    let hex = try XCTUnwrap(UInt32(node.attributes["fill"]?.dropFirst() ?? "", radix: 16))
                    fills.append((rect, UIColor(red: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)))
                case "image":
                    let data = try XCTUnwrap(node.attributes["xlink:href"]?.split(separator: ",").last.flatMap { Data(base64Encoded: String($0)) })
                    let image = try XCTUnwrap(UIImage(data: data))
                    if let transform = node.attributes["transform"] {
                        items.append(Item(id: node.attributes["id"] ?? "", rect: rect, transform: try XCTUnwrap(Transform(transform)), image: image))
                    } else {
                        paper.append((rect, image))
                    }
                default:
                    break
                }
            }
        }

        func draw(in ctx: CGContext) {
            for (rect, color) in fills {
                color.setFill()
                ctx.fill(rect)
            }
            for (rect, image) in paper { image.draw(in: rect) }
            for item in items {
                ctx.saveGState()
                ctx.translateBy(x: item.transform.translation.x, y: item.transform.translation.y)
                ctx.rotate(by: item.transform.degrees * .pi / 180)
                item.image.draw(in: item.rect)
                ctx.restoreGState()
            }
        }
    }

    /// What was drawn on white, as sRGB bytes in rows from the top.
    private struct Pixels {
        let width: Int, height: Int, scale: CGFloat
        var bytes: [UInt8]

        init(_ size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) {
            (width, height, self.scale) = (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()), scale)
            bytes = [UInt8](repeating: 0, count: width * height * 4)
            let (w, h) = (width, height)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: scale, y: -scale)
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
                UIGraphicsPushContext(ctx)
                draw(ctx)
                UIGraphicsPopContext()
            }
        }

        /// Within `rect` of the page, the mean of each pixel's largest channel difference, and the shares that differ by more than 40
        /// and by more than 10 from every pixel next to it in `other`, so an edge drawn a pixel aside doesn't count.
        func difference(to other: Pixels, in rect: CGRect) -> (mean: Double, bad: Double, changed: Double) {
            let columns = max(Int(rect.minX * scale), 1)..<min(Int(rect.maxX * scale), width - 1), rows = max(Int(rect.minY * scale), 1)..<min(Int(rect.maxY * scale), height - 1)
            guard !columns.isEmpty, !rows.isEmpty else { return (0, 0, 0) }
            func distance(_ i: Int, _ j: Int) -> Int {
                max(abs(Int(bytes[i]) - Int(other.bytes[j])), abs(Int(bytes[i + 1]) - Int(other.bytes[j + 1])), abs(Int(bytes[i + 2]) - Int(other.bytes[j + 2])))
            }
            var sum = 0, bad = 0, changed = 0
            for y in rows {
                for x in columns {
                    let i = (y * width + x) * 4, direct = distance(i, i)
                    sum += direct
                    guard direct > 10 else { continue }
                    var nearest = direct
                    for dy in -1...1 {
                        for dx in -1...1 where nearest > 10 { nearest = min(nearest, distance(i, ((y + dy) * width + x + dx) * 4)) }
                    }
                    if nearest > 10 { changed += 1 }
                    if nearest > 40 { bad += 1 }
                }
            }
            let count = Double(columns.count * rows.count)
            return (Double(sum) / count, Double(bad) / count, Double(changed) / count)
        }
    }
}
