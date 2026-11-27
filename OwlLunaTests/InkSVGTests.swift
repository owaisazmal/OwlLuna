import XCTest
import PencilKit
@testable import OwlLuna

private let written = Date(timeIntervalSince1970: 1_790_000_000)

/// A straight stroke of points that are all alike.
private func line(_ ink: PKInk.InkType, color: UIColor = .black, from a: CGPoint, to b: CGPoint, width: CGFloat, height: CGFloat? = nil, opacity: CGFloat = 1,
                  azimuth: CGFloat = .pi / 2, count: Int = 12) -> PKStroke {
    let points = (0..<count).map { i -> PKStrokePoint in
        let t = count > 1 ? CGFloat(i) / CGFloat(count - 1) : 0
        return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: TimeInterval(t),
                             size: CGSize(width: width, height: height ?? width), opacity: opacity, force: 1, azimuth: azimuth, altitude: 1)
    }
    return PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: points, creationDate: written))
}

/// A line of loops that thickens and thins, like quick handwriting.
private func scribble(_ ink: PKInk.InkType, color: UIColor = .black, origin: CGPoint, widths: ClosedRange<CGFloat>, azimuth: CGFloat = 0.6, turning: Bool = true,
                      opacity: CGFloat = 1) -> PKStroke {
    let points = (0..<60).map { i -> PKStrokePoint in
        let t = Double(i) / 59, angle = t * 8 * .pi
        let width = widths.lowerBound + (widths.upperBound - widths.lowerBound) * CGFloat(0.5 + 0.5 * sin(t * 7))
        return PKStrokePoint(location: CGPoint(x: origin.x + CGFloat(t * 220 + cos(angle) * 9), y: origin.y + CGFloat(sin(angle) * 14 + sin(t * 5) * 6)),
                             timeOffset: t, size: CGSize(width: width, height: width), opacity: opacity, force: 1, azimuth: azimuth + (turning ? CGFloat(t) : 0),
                             altitude: 1)
    }
    return PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: points, creationDate: written))
}

/// Short looping strokes set out in lines, as many as a page of dense handwriting has.
private func handwriting(_ ink: PKInk.InkType, count: Int, size: ClosedRange<CGFloat>, swing: CGFloat = 0, opacity: CGFloat = 1) -> PKDrawing {
    var seed: UInt64 = 42
    func random() -> CGFloat {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(seed >> 40) / CGFloat(1 << 24)
    }
    return PKDrawing(strokes: (0..<count).map { index -> PKStroke in
        let origin = CGPoint(x: 40 + CGFloat(index % 50) * 10.6, y: 40 + CGFloat(index / 50) * 18)
        let radius = 3 + random() * 4, turns = 0.6 + random() * 1.4, start = random() * 2 * .pi, lean = random() * 6
        let width = size.lowerBound + random() * (size.upperBound - size.lowerBound)
        let points = (0..<14).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 13, angle = start + t * turns * 2 * .pi, w = width * (1 - swing / 2 + swing * (0.5 + 0.5 * sin(t * 3)))
            return PKStrokePoint(location: CGPoint(x: origin.x + t * lean + cos(angle) * radius, y: origin.y + sin(angle) * radius * 1.4),
                                 timeOffset: TimeInterval(t) * 0.2, size: CGSize(width: w, height: w), opacity: opacity, force: 1, azimuth: 0.8, altitude: 1)
        }
        return PKStroke(ink: PKInk(ink, color: .black), path: PKStrokePath(controlPoints: points, creationDate: written))
    })
}

/// The colours of something drawn on a ground, in a top-left-origin context.
private struct Pixels {
    let width: Int, height: Int, scale: CGFloat
    private(set) var bytes: [UInt8]

    init(_ size: CGSize, scale: CGFloat = 3, on ground: UIColor = .white, _ draw: (CGContext) -> Void) {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.setFillColor(ground.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            UIGraphicsPushContext(ctx)
            draw(ctx)
            UIGraphicsPopContext()
        }
        (width, height, self.scale, bytes) = (w, h, scale, buffer)
    }

    func gray(_ pixel: Int) -> Int {
        (Int(bytes[pixel * 4]) * 299 + Int(bytes[pixel * 4 + 1]) * 587 + Int(bytes[pixel * 4 + 2]) * 114) / 1000
    }

    func luminance(at point: CGPoint) -> Double {
        Double(gray(Int(point.y * scale) * width + Int(point.x * scale))) / 255
    }

    /// The mean difference where either has ink, and the share of those pixels that differ by more than a quarter.
    func difference(to other: Pixels) -> (mean: Double, bad: Double) {
        var inked = 0, sum = 0, bad = 0
        for pixel in 0..<min(width * height, other.width * other.height) {
            let a = gray(pixel), b = other.gray(pixel)
            guard a < 250 || b < 250 else { continue }
            let d = abs(a - b)
            inked += 1
            sum += d
            if d > 64 { bad += 1 }
        }
        return (Double(sum) / Double(max(inked, 1)), Double(bad) / Double(max(inked, 1)))
    }

    /// What is on white: how much ink in square points of full black, where its middle lies, the box it fills, and the share of
    /// red, green and blue it takes out of the light.
    struct Ink {
        var mass = 0.0, centre = CGPoint.zero, box = CGRect.null, taken = [0.0, 0.0, 0.0]
    }

    var ink: Ink {
        var mass = 0.0, x = 0.0, y = 0.0, taken = [0.0, 0.0, 0.0]
        var left = width, right = -1, top = height, bottom = -1
        for row in 0..<height {
            for column in 0..<width {
                let pixel = row * width + column, dark = 255 - gray(pixel)
                guard dark > 12 else { continue }
                mass += Double(dark)
                x += Double(dark * column)
                y += Double(dark * row)
                for channel in 0..<3 { taken[channel] += Double(255 - Int(bytes[pixel * 4 + channel])) }
                (left, right, top, bottom) = (min(left, column), max(right, column), min(top, row), max(bottom, row))
            }
        }
        let s = Double(scale), all = max(taken.reduce(0, +), 1)
        guard mass > 0 else { return Ink() }
        return Ink(mass: mass / 255 / (s * s), centre: CGPoint(x: x / mass / s, y: y / mass / s),
                   box: CGRect(x: Double(left) / s, y: Double(top) / s, width: Double(right - left + 1) / s, height: Double(bottom - top + 1) / s),
                   taken: taken.map { $0 / all })
    }
}

/// The SVG the ink writer makes, read back and drawn with Core Graphics: groups, paths, clip paths and the attributes it uses.
private final class SVGReader: NSObject, XMLParserDelegate {
    final class Node {
        let name: String, attributes: [String: String]
        var children: [Node] = []
        init(name: String, attributes: [String: String]) { (self.name, self.attributes) = (name, attributes) }
    }

    private(set) var root: Node?
    private(set) var ids: [String: Node] = [:]
    private var open: [Node] = []

    init(_ svg: String) throws {
        super.init()
        let parser = XMLParser(data: Data(svg.utf8))
        parser.delegate = self
        guard parser.parse(), root != nil else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let node = Node(name: name, attributes: attributes)
        if let id = attributes["id"] {
            XCTAssertNil(ids[id], "\(id) is used twice")
            ids[id] = node
        }
        if let parent = open.last { parent.children.append(node) } else { root = node }
        open.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { open.removeLast() }

    /// The `<g id="ink">` and the elements of its strokes.
    var ink: Node? { ids["ink"] }
    var strokes: [Node] { ink?.children ?? [] }

    func all(under node: Node? = nil) -> [Node] {
        guard let node = node ?? root else { return [] }
        return [node] + node.children.flatMap { all(under: $0) }
    }

    func draw(in ctx: CGContext) {
        if let root { draw(root, inherited: [:], in: ctx) }
    }

    private static let inherited = ["fill", "fill-rule", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin"]

    private func draw(_ node: Node, inherited: [String: String], in ctx: CGContext) {
        guard node.name != "defs", node.name != "clipPath" else { return }
        var paint = inherited
        for name in Self.inherited { if let value = node.attributes[name] { paint[name] = value } }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let transform = node.attributes["transform"] {
            let terms = Self.numbers(in: transform)
            XCTAssertTrue(transform.hasPrefix("matrix(") && terms.count == 6, "only a matrix is written: \(transform)")
            if terms.count == 6 { ctx.concatenate(CGAffineTransform(a: terms[0], b: terms[1], c: terms[2], d: terms[3], tx: terms[4], ty: terms[5])) }
        }
        if let reference = node.attributes["clip-path"] {
            let clip = ids[String(reference.dropFirst("url(#".count).dropLast())]
            XCTAssertEqual(clip?.name, "clipPath", "\(reference) should name a clip path")
            for child in clip?.children ?? [] where child.name == "path" { ctx.addPath(Self.path(child.attributes["d"] ?? "")) }
            ctx.clip()
        }
        if node.attributes["style"] == "mix-blend-mode:multiply" { ctx.setBlendMode(.multiply) }
        let opacity = node.attributes["opacity"].flatMap(Double.init) ?? 1
        if opacity < 1 {
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if node.name == "path" {
            let path = Self.path(node.attributes["d"] ?? ""), fill = paint["fill"] ?? "#000000", stroke = paint["stroke"] ?? "none"
            if fill != "none" {
                ctx.setFillColor(Self.color(fill).cgColor)
                ctx.addPath(path)
                ctx.fillPath(using: paint["fill-rule"] == "evenodd" ? .evenOdd : .winding)
            }
            if stroke != "none" {
                ctx.setStrokeColor(Self.color(stroke).cgColor)
                ctx.setLineWidth(paint["stroke-width"].flatMap(Double.init) ?? 1)
                ctx.setLineCap(paint["stroke-linecap"] == "round" ? .round : .butt)
                ctx.setLineJoin(paint["stroke-linejoin"] == "round" ? .round : .miter)
                ctx.addPath(path)
                ctx.strokePath()
            }
        } else {
            for child in node.children { draw(child, inherited: paint, in: ctx) }
        }
        if opacity < 1 { ctx.endTransparencyLayer() }
    }

    static func color(_ hex: String) -> UIColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return UIColor(red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func numbers(in text: String) -> [CGFloat] {
        var numbers: [CGFloat] = [], token = ""
        func end() {
            if let value = Double(token) { numbers.append(value) }
            token = ""
        }
        for character in text {
            if character.isNumber || character == "." {
                token.append(character)
            } else {
                end()
                if character == "-" { token = "-" }
            }
        }
        end()
        return numbers
    }

    /// Path data as the writer makes it: absolute moves, lines, curves and closes.
    static func path(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var command: Character = "M", text = ""
        func run() {
            let values = numbers(in: text)
            func point(_ index: Int) -> CGPoint { CGPoint(x: values[index * 2], y: values[index * 2 + 1]) }
            switch command {
            case "M" where values.count == 2: path.move(to: point(0))
            case "L" where values.count == 2: path.addLine(to: point(0))
            case "Q" where values.count == 4: path.addQuadCurve(to: point(1), control: point(0))
            case "C" where values.count == 6: path.addCurve(to: point(2), control1: point(0), control2: point(1))
            case "Z" where values.isEmpty: path.closeSubpath()
            default: XCTFail("path data the writer shouldn't make: \(command)\(text)")
            }
            text = ""
        }
        var started = false
        for character in d {
            if character.isLetter {
                if started { run() }
                command = character
                started = true
            } else {
                text.append(character)
            }
        }
        if started { run() }
        return path
    }
}

/// Ink as SVG: every stroke an element of its own, the nib inks as the PDF draws them, the rest a likeness of PencilKit's picture.
@MainActor
final class InkSVGTests: XCTestCase {
    private let blue = UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    private let yellow = UIColor(red: 0.91, green: 0.69, blue: 0.14, alpha: 1)

    private func read(_ drawing: PKDrawing, from rect: CGRect, size: CGSize? = nil, style: InkVectors.Style = .init()) throws -> SVGReader {
        try SVGReader("<svg xmlns=\"http://www.w3.org/2000/svg\">\n" + InkSVG.group(drawing, from: rect, size: size ?? rect.size, style: style) + "\n</svg>")
    }

    /// The box a path's points lie in, before its line is given a width.
    private func assertBox(_ node: SVGReader.Node?, _ expected: CGRect, _ message: String = "", line: UInt = #line) {
        let box = SVGReader.path(node?.attributes["d"] ?? "").boundingBoxOfPath
        for (found, wanted) in [(box.minX, expected.minX), (box.minY, expected.minY), (box.maxX, expected.maxX), (box.maxY, expected.maxY)] {
            XCTAssertEqual(found, wanted, accuracy: 0.05, "\(box) \(message)", line: line)
        }
    }

    private func picture(_ drawing: PKDrawing, rect: CGRect, scale: CGFloat = 3, dark: Bool = false) -> UIImage {
        var picture = UIImage()
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent { picture = drawing.image(from: rect, scale: scale) }
        return picture
    }

    /// PencilKit lays its grain afresh on every path it is given, so its picture is measured over several of the same stroke.
    private func kitInk(_ stroke: PKStroke, rect: CGRect) -> Pixels.Ink {
        let times = stroke.ink.inkType == .marker ? 1 : 8
        var mean = Pixels.Ink(box: .zero)
        for _ in 0..<times {
            let path = PKStrokePath(controlPoints: Array(stroke.path), creationDate: stroke.path.creationDate)
            let image = picture(PKDrawing(strokes: [PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask)]), rect: rect)
            let ink = Pixels(rect.size) { _ in image.draw(in: rect) }.ink, share = 1 / Double(times)
            mean.mass += ink.mass * share
            mean.centre = CGPoint(x: mean.centre.x + ink.centre.x * share, y: mean.centre.y + ink.centre.y * share)
            mean.box.size = CGSize(width: mean.box.width + ink.box.width * share, height: mean.box.height + ink.box.height * share)
            for channel in 0..<3 { mean.taken[channel] += ink.taken[channel] * share }
        }
        return mean
    }

    /// One stroke of every ink, at the sizes a finger records.
    private func everyInk() -> [(name: String, stroke: PKStroke)] {
        var strokes: [(String, PKStroke)] = [
            ("pen", scribble(.pen, origin: CGPoint(x: 30, y: 40), widths: 3.2...3.2)),
            ("fineliner", scribble(.monoline, color: .brown, origin: CGPoint(x: 30, y: 90), widths: 2.5...2.5)),
            ("fountain pen", scribble(.fountainPen, color: blue, origin: CGPoint(x: 30, y: 140), widths: 4...6)),
            ("pencil", scribble(.pencil, color: .darkGray, origin: CGPoint(x: 30, y: 190), widths: 1.9...1.9, opacity: 0.35)),
            ("highlighter", scribble(.marker, color: yellow, origin: CGPoint(x: 30, y: 250), widths: 13.75...13.75, azimuth: .pi / 2, turning: false)),
            ("crayon", scribble(.crayon, color: .red, origin: CGPoint(x: 30, y: 320), widths: 8...8, azimuth: .pi / 2, turning: false)),
            ("watercolour", scribble(.watercolor, color: .purple, origin: CGPoint(x: 30, y: 390), widths: 12...12, opacity: 0.17)),
        ]
        if #available(iOS 26.0, *) {
            strokes.append(("calligraphy pen", scribble(.reed, color: .black, origin: CGPoint(x: 30, y: 460), widths: 6...6, azimuth: .pi / 4, turning: false)))
        }
        return strokes
    }

    func testEveryStrokeIsAnElementOfItsOwnInTheOrderWritten() throws {
        let inks = everyInk(), rect = CGRect(x: 0, y: 0, width: 300, height: 520)
        let group = InkSVG.group(PKDrawing(strokes: inks.map(\.stroke)), from: rect, size: rect.size)
        XCTAssertTrue(group.hasPrefix("<g id=\"ink\">") && group.hasSuffix("</g>"))
        let reader = try SVGReader("<svg xmlns=\"http://www.w3.org/2000/svg\">" + group + "</svg>")
        XCTAssertEqual(reader.root?.children.count, 1)
        XCTAssertEqual(reader.strokes.map { $0.attributes["id"] }, (1...inks.count).map { "ink-\($0)" })
        XCTAssertEqual(reader.strokes.map { $0.attributes["data-ink"] }, inks.map(\.name))
        XCTAssertTrue(reader.strokes.allSatisfy { $0.name == "path" }, "a stroke of one width is one path")
        let known: Set = ["xmlns", "id", "data-ink", "d", "fill", "fill-rule", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "opacity", "transform",
                          "clip-path", "style"]
        for node in reader.all() {
            XCTAssertTrue(["svg", "g", "path", "defs", "clipPath"].contains(node.name), node.name)
            for (name, value) in node.attributes {
                XCTAssertTrue(known.contains(name), "\(name) on \(node.name)")
                if name == "id" { XCTAssertTrue(value.hasPrefix("ink"), value) }
                if name == "style" { XCTAssertEqual(value, "mix-blend-mode:multiply") }
                if name == "d" || name == "stroke-width" || name == "opacity" {
                    XCTAssertNil(value.range(of: #"[^0-9MLQCZ. -]|\.[0-9]{3}"#, options: .regularExpression), "\(name)=\(value.prefix(60))")
                }
            }
        }
        XCTAssertEqual(InkSVG.group(PKDrawing(), from: rect, size: rect.size), "<g id=\"ink\"/>")
        let pointless = [PKInk.InkType.pen, .fountainPen, .marker].map { PKStroke(ink: PKInk($0, color: .black), path: PKStrokePath()) }
        XCTAssertTrue(try read(PKDrawing(strokes: pointless), from: rect).all().allSatisfy { $0.attributes["d"] == nil }, "a stroke with no points draws nothing")
    }

    func testPenFinelinerAndFountainPenAreTheShapesThePDFDraws() throws {
        var moved = scribble(.pen, origin: .zero, widths: 3...6)
        moved.transform = CGAffineTransform(translationX: 40, y: 70).rotated(by: 0.25)
        var stretched = scribble(.pen, origin: CGPoint(x: 30, y: 60), widths: 3...6)
        stretched.transform = CGAffineTransform(a: 1.2, b: 0.1, c: 0, d: 0.6, tx: 5, ty: 20)
        var stretchedOval = scribble(.fountainPen, color: UIColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 0.6), origin: CGPoint(x: 30, y: 60), widths: 4...9)
        stretchedOval.transform = CGAffineTransform(a: 0.7, b: 0, c: 0.2, d: 1.3, tx: 5, ty: -20)
        let base = scribble(.pen, origin: CGPoint(x: 30, y: 60), widths: 3...6)
        let erased = PKStroke(ink: base.ink, path: base.path, transform: .identity, mask: UIBezierPath(rect: CGRect(x: 0, y: 0, width: 140, height: 120)))
        var erasedAndStretched = PKStroke(ink: PKInk(.fountainPen, color: blue), path: base.path, transform: .identity,
                                          mask: UIBezierPath(ovalIn: CGRect(x: 40, y: 30, width: 140, height: 70)))
        erasedAndStretched.transform = CGAffineTransform(a: 1.1, b: 0, c: 0.3, d: 0.8, tx: -10, ty: 10)
        let cases: [(String, [PKStroke])] = [
            ("pen", [scribble(.pen, origin: CGPoint(x: 30, y: 60), widths: 2.6...7)]),
            ("thick pen", [scribble(.pen, origin: CGPoint(x: 30, y: 60), widths: 8...16)]),
            ("fineliner", [scribble(.monoline, origin: CGPoint(x: 30, y: 60), widths: 3.5...3.5)]),
            ("fountain pen", [scribble(.fountainPen, origin: CGPoint(x: 30, y: 60), widths: 4...9)]),
            ("see-through blue", [scribble(.pen, color: blue.withAlphaComponent(0.5), origin: CGPoint(x: 30, y: 60), widths: 3...7)]),
            ("see-through fountain pen", [scribble(.fountainPen, color: blue.withAlphaComponent(0.5), origin: CGPoint(x: 30, y: 60), widths: 4...9)]),
            ("moved and turned", [moved]),
            ("stretched", [stretched, stretchedOval]),
            ("partly erased", [erased, erasedAndStretched]),
            ("dots", [line(.pen, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50), width: 9, count: 1),
                      line(.fountainPen, from: CGPoint(x: 90, y: 50), to: CGPoint(x: 90, y: 50), width: 9, azimuth: 0.5, count: 1)]),
        ]
        let size = CGSize(width: 300, height: 120), rect = CGRect(origin: .zero, size: size)
        for (name, strokes) in cases {
            for stroke in strokes { XCTAssertNotNil(InkVectors.nib(for: stroke), name) }
            let drawing = PKDrawing(strokes: strokes), reader = try read(drawing, from: rect)
            let pdf = Pixels(size) { InkVectors.draw(drawing, from: rect, in: $0, size: size) }
            let svg = Pixels(size) { reader.draw(in: $0) }
            let difference = pdf.difference(to: svg)
            XCTAssertGreaterThan(pdf.ink.mass, 20, name)
            XCTAssertLessThan(difference.mean, 2, name)
            XCTAssertLessThan(difference.bad, 0.002, "\(name): the same pixels as the PDF's shapes")
        }
    }

    func testAnEvenLineIsOnePathAndOneThatSwellsIsAGroupOfLines() throws {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        let reader = try read(PKDrawing(strokes: [scribble(.monoline, color: blue, origin: CGPoint(x: 30, y: 60), widths: 3.5...3.5),
                                                  scribble(.pen, origin: CGPoint(x: 30, y: 60), widths: 3...7),
                                                  scribble(.fountainPen, origin: CGPoint(x: 30, y: 60), widths: 4...9)]), from: rect)
        let even = reader.strokes[0], swelling = reader.strokes[1], oval = reader.strokes[2]
        XCTAssertEqual(even.name, "path")
        XCTAssertEqual(even.attributes["fill"], "none")
        XCTAssertEqual(even.attributes["stroke"], "#3366cc")
        XCTAssertEqual(even.attributes["stroke-width"], "3", "the nib is two points narrower all round than its size")
        XCTAssertEqual(even.attributes["stroke-linecap"], "round")
        XCTAssertEqual(even.attributes["stroke-linejoin"], "round")
        XCTAssertEqual(swelling.name, "g")
        XCTAssertGreaterThan(swelling.children.count, 3)
        XCTAssertTrue(swelling.children.allSatisfy { $0.name == "path" && $0.attributes["stroke-width"] != nil && $0.attributes["stroke"] == nil })
        XCTAssertEqual(swelling.attributes["stroke"], "#000000")
        XCTAssertGreaterThan(Set(swelling.children.compactMap { $0.attributes["stroke-width"] }).count, 3)
        XCTAssertEqual(oval.name, "path")
        XCTAssertEqual(oval.attributes["fill"], "#000000")
        XCTAssertEqual(oval.attributes["fill-rule"], "nonzero")
        XCTAssertNil(oval.attributes["stroke"])
    }

    func testTheFountainPensHullsAreMergedIntoOneOutline() throws {
        let stroke = scribble(.fountainPen, origin: CGPoint(x: 30, y: 60), widths: 4...9), rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        let placement = InkVectors.placement(of: stroke, toPage: .identity, appearance: .light)
        let hulls = InkVectors.oval(InkVectors.samples(of: stroke, at: placement), tolerance: placement.tolerance)
        let hullPoints = hulls.reduce(0) { count, piece in
            if case .outline(let points, _) = piece { return count + points.count }
            return count
        }
        let d = try XCTUnwrap(try read(PKDrawing(strokes: [stroke]), from: rect).strokes.first?.attributes["d"])
        let written = d.filter { $0 == "L" || $0 == "M" }.count
        XCTAssertGreaterThan(hulls.count, 20)
        XCTAssertLessThan(written * 4, hullPoints, "\(written) points written for \(hullPoints) in the hulls")
        XCTAssertLessThan(d.filter { $0 == "M" }.count, 8, "an outline and the holes its loops leave")
    }

    func testColourOpacityAndDarkPaper() throws {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 120)
        let strokes = [scribble(.monoline, color: blue.withAlphaComponent(0.5), origin: CGPoint(x: 30, y: 60), widths: 3.5...3.5),
                       scribble(.fountainPen, color: .black, origin: CGPoint(x: 30, y: 60), widths: 4...9),
                       scribble(.pencil, color: .black, origin: CGPoint(x: 30, y: 60), widths: 2...2, opacity: 0.3)]
        let light = try read(PKDrawing(strokes: strokes), from: rect)
        XCTAssertEqual(light.strokes[0].attributes["stroke"], "#3366cc")
        XCTAssertEqual(light.strokes[0].attributes["opacity"], "0.5", "the colour's alpha is the opacity of the whole element")
        XCTAssertEqual(light.strokes[1].attributes["fill"], "#000000")
        XCTAssertNil(light.strokes[1].attributes["opacity"])
        XCTAssertNil(light.all().first { $0.attributes["stroke-opacity"] != nil || $0.attributes["fill-opacity"] != nil })
        let dark = try read(PKDrawing(strokes: strokes), from: rect, style: .init(appearance: .dark, multipliesHighlighter: false))
        let converted = SVGText.color(PKInkingTool.convertColor(.black, from: .light, to: .dark)).hex
        XCTAssertNotEqual(converted, "#000000")
        XCTAssertEqual(dark.strokes[1].attributes["fill"], converted, "black ink is light on dark paper")
        XCTAssertEqual(dark.strokes[2].attributes["stroke"], converted)
        XCTAssertEqual(dark.strokes[0].attributes["stroke"], SVGText.color(PKInkingTool.convertColor(blue, from: .light, to: .dark)).hex)
        XCTAssertEqual(dark.strokes[0].attributes["opacity"], "0.5")
    }

    func testAStrokePartlyRubbedOutIsClipped() throws {
        let base = scribble(.pen, origin: CGPoint(x: 30, y: 60), widths: 3.5...3.5), size = CGSize(width: 300, height: 120), rect = CGRect(origin: .zero, size: size)
        let erased = PKStroke(ink: base.ink, path: base.path, transform: .identity, mask: UIBezierPath(rect: CGRect(x: 0, y: 0, width: 140, height: 120)))
        let reader = try read(PKDrawing(strokes: [base, erased]), from: rect)
        XCTAssertEqual(reader.strokes[0].name, "path")
        XCTAssertNil(reader.strokes[0].attributes["clip-path"])
        let element = reader.strokes[1]
        XCTAssertEqual(element.name, "g", "a clipped stroke carries its clip path with it")
        XCTAssertEqual(element.attributes["clip-path"], "url(#ink-clip-2)")
        let clip = try XCTUnwrap(reader.ids["ink-clip-2"])
        XCTAssertEqual(clip.name, "clipPath")
        XCTAssertTrue(element.children.first?.name == "defs" && element.children.first?.children.first === clip)
        assertBox(clip.children.first, CGRect(x: 0, y: 0, width: 140, height: 120))
        let alone = try read(PKDrawing(strokes: [erased]), from: rect)
        let drawn = Pixels(size) { alone.draw(in: $0) }.ink
        XCTAssertGreaterThan(drawn.mass, 50)
        XCTAssertEqual(drawn.box.maxX, 140, accuracy: 0.5, "nothing is drawn past the edge of what was rubbed out")
    }

    func testAnUnevenStretchIsATransformAndAnEvenMoveGoesIntoTheCoordinates() throws {
        var stretched = scribble(.monoline, origin: CGPoint(x: 30, y: 60), widths: 3.5...3.5)
        stretched.transform = CGAffineTransform(a: 1.2, b: 0.1, c: 0, d: 0.6, tx: 5, ty: 20)
        var moved = line(.monoline, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 10), width: 4)
        moved.transform = CGAffineTransform(translationX: 30, y: 40).scaledBy(x: 2, y: 2)
        let drawing = PKDrawing(strokes: [stretched, moved]), size = CGSize(width: 300, height: 120), rect = CGRect(origin: .zero, size: size)
        let reader = try read(drawing, from: rect)
        XCTAssertEqual(reader.strokes[0].attributes["transform"], "matrix(1.2 0.1 0 0.6 5 20)")
        XCTAssertEqual(reader.strokes[0].attributes["stroke-width"], "3", "the width is left to the transform, as the PDF leaves it")
        XCTAssertNil(reader.strokes[1].attributes["transform"])
        XCTAssertEqual(reader.strokes[1].attributes["stroke-width"], "8", "a stroke made twice the size is twice as wide")
        assertBox(reader.strokes[1], CGRect(x: 50, y: 60, width: 100, height: 0))
        // On a sheet cut from a whiteboard the page's own placing is part of the matrix, to more places than a length is written with.
        let cut = CGRect(x: 7, y: 3, width: 210, height: 84), sheet = CGSize(width: 300, height: 120)
        let placed = try read(drawing, from: cut, size: sheet)
        let terms = SVGReader.numbers(in: placed.strokes[0].attributes["transform"] ?? "")
        let whole = stretched.transform.concatenating(InkVectors.toPage(from: cut, size: sheet))
        XCTAssertEqual(terms.count, 6)
        for (term, expected) in zip(terms, [whole.a, whole.b, whole.c, whole.d]) { XCTAssertEqual(term, expected, accuracy: 0.000001) }
        XCTAssertNotNil(placed.strokes[0].attributes["transform"]?.range(of: "1.714286"), "ten sevenths to six places")
        let pdf = Pixels(sheet) { InkVectors.draw(drawing, from: cut, in: $0, size: sheet) }
        let svg = Pixels(sheet) { placed.draw(in: $0) }
        XCTAssertLessThan(pdf.difference(to: svg).bad, 0.002)
    }

    func testOnlyTheStrokesInACutAreWrittenAndTheyArePlacedOnIt() throws {
        let inside = line(.monoline, color: blue, from: CGPoint(x: 120, y: 80), to: CGPoint(x: 180, y: 80), width: 4)
        let outside = line(.pen, from: CGPoint(x: 500, y: 500), to: CGPoint(x: 560, y: 500), width: 4)
        let across = line(.monoline, from: CGPoint(x: 80, y: 120), to: CGPoint(x: 140, y: 120), width: 4)
        let highlighted = line(.marker, color: yellow, from: CGPoint(x: 400, y: 80), to: CGPoint(x: 460, y: 80), width: 14)
        let drawing = PKDrawing(strokes: [outside, inside, highlighted, across])
        let cut = CGRect(x: 100, y: 50, width: 200, height: 100), sheet = CGSize(width: 400, height: 200)
        let reader = try read(drawing, from: cut, size: sheet)
        XCTAssertEqual(reader.strokes.map { $0.attributes["id"] }, ["ink-1", "ink-2"], "numbered as written, not as they are in the drawing")
        XCTAssertEqual(reader.strokes.map { $0.attributes["stroke"] }, ["#3366cc", "#000000"])
        XCTAssertEqual(reader.strokes[0].attributes["stroke-width"], "8")
        assertBox(reader.strokes[0], CGRect(x: 40, y: 60, width: 120, height: 0))
        assertBox(reader.strokes[1], CGRect(x: -40, y: 140, width: 120, height: 0), "a stroke that reaches the cut is written whole")
        let pdf = Pixels(sheet) { InkVectors.draw(drawing, from: cut, in: $0, size: sheet) }
        let svg = Pixels(sheet) { reader.draw(in: $0) }
        XCTAssertLessThan(pdf.difference(to: svg).bad, 0.002)
    }

    func testInksWithAGrainAreShapesThatLookLikePencilKitsPicture() throws {
        let size = CGSize(width: 300, height: 120), rect = CGRect(origin: .zero, size: size), origin = CGPoint(x: 30, y: 60)
        var cases: [(String, PKStroke, lines: Bool)] = [
            ("pencil", scribble(.pencil, color: blue, origin: origin, widths: 1.9...1.9, opacity: 0.35), true),
            ("soft pencil", scribble(.pencil, color: blue, origin: origin, widths: 1.4...3.6, opacity: 0.25), true),
            ("highlighter", scribble(.marker, color: yellow, origin: origin, widths: 13.75...13.75, azimuth: .pi / 2, turning: false), false),
            ("thin highlighter", line(.marker, color: yellow, from: CGPoint(x: 40, y: 60), to: CGPoint(x: 260, y: 64), width: 5), false),
            ("crayon", scribble(.crayon, color: blue, origin: origin, widths: 8...8, azimuth: .pi / 2, turning: false), true),
            ("watercolour", scribble(.watercolor, color: blue, origin: origin, widths: 9...9, opacity: 0.17), true),
            ("pencil dab", line(.pencil, color: blue, from: CGPoint(x: 100, y: 60), to: CGPoint(x: 103, y: 60), width: 2.5, opacity: 0.3, count: 6), true),
            ("highlighter dab", line(.marker, color: yellow, from: CGPoint(x: 100, y: 60), to: CGPoint(x: 108, y: 60), width: 13.75, count: 6), false),
            ("watercolour dab", line(.watercolor, color: blue, from: CGPoint(x: 100, y: 60), to: CGPoint(x: 108, y: 60), width: 16, opacity: 0.17, count: 6), true),
            ("stretched pencil", scribble(.pencil, color: blue, origin: CGPoint(x: 30, y: 50), widths: 2.5...2.5, opacity: 0.4), true),
        ]
        cases[cases.count - 1].1.transform = CGAffineTransform(a: 1.1, b: 0, c: 0.2, d: 0.8, tx: -10, ty: 20)
        if #available(iOS 26.0, *) {
            cases.append(("calligraphy pen", scribble(.reed, color: blue, origin: origin, widths: 6...6, azimuth: .pi / 4, turning: false), false))
        }
        for (name, stroke, lines) in cases {
            XCTAssertNil(InkVectors.nib(for: stroke), "\(name) is a picture in the PDF")
            let drawing = PKDrawing(strokes: [stroke]), reader = try read(drawing, from: rect), element = try XCTUnwrap(reader.strokes.first)
            XCTAssertNil(reader.all().first { $0.name == "image" }, name)
            XCTAssertEqual(element.attributes[lines ? "stroke" : "fill"], SVGText.color(stroke.ink.color).hex, name)
            XCTAssertNotNil(element.attributes["opacity"], "\(name) lies thinner than its colour")
            let kit = kitInk(stroke, rect: rect), ours = Pixels(size) { reader.draw(in: $0) }.ink
            XCTAssertEqual(ours.mass / kit.mass, 1, accuracy: 0.25, "\(name): as much ink")
            XCTAssertEqual(ours.centre.x, kit.centre.x, accuracy: 3, name)
            XCTAssertEqual(ours.centre.y, kit.centre.y, accuracy: 2, name)
            XCTAssertEqual(ours.box.width, kit.box.width, accuracy: 6, name)
            XCTAssertEqual(ours.box.height, kit.box.height, accuracy: 6, name)
            for channel in 0..<3 { XCTAssertEqual(ours.taken[channel], kit.taken[channel], accuracy: 0.06, "\(name): the same colour") }
        }
    }

    func testATapIsOneFaintMarkOfTheTip() throws {
        let size = CGSize(width: 80, height: 80), rect = CGRect(origin: .zero, size: size), at = CGPoint(x: 40, y: 40)
        for (name, ink, width, opacity) in [("pencil", PKInk.InkType.pencil, 2.5, 1), ("highlighter", .marker, 13.75, 1), ("watercolour", .watercolor, 16, 0.5)]
            as [(String, PKInk.InkType, CGFloat, CGFloat)] {
            let drawing = PKDrawing(strokes: [line(ink, color: blue, from: at, to: at, width: width, opacity: opacity, count: 1)])
            let reader = try read(drawing, from: rect), element = try XCTUnwrap(reader.strokes.first)
            XCTAssertEqual(element.name, "path", name)
            XCTAssertEqual(element.attributes["fill"], "#3366cc", name)
            let long = try read(PKDrawing(strokes: [line(ink, from: CGPoint(x: 10, y: 40), to: CGPoint(x: 70, y: 40), width: width, opacity: opacity)]), from: rect)
            let faint = try XCTUnwrap(element.attributes["opacity"].flatMap(Double.init)), full = long.strokes.first?.attributes["opacity"].flatMap(Double.init) ?? 1
            XCTAssertLessThan(faint, full * 0.7, "\(name): a tap is laid thinner than a line")
            let kit = kitInk(drawing.strokes[0], rect: rect), ours = Pixels(size) { reader.draw(in: $0) }.ink
            XCTAssertEqual(ours.mass / kit.mass, 1, accuracy: 0.35, name)
            XCTAssertEqual(ours.centre.x, 40, accuracy: 1, name)
            // PencilKit draws the same point given twice as nothing at all.
            let twice = try read(PKDrawing(strokes: [line(ink, from: at, to: at, width: width, opacity: opacity, count: 2)]), from: rect)
            XCTAssertEqual(twice.strokes.map(\.name), ["g"], name)
            XCTAssertTrue(twice.strokes.first?.children.isEmpty == true && twice.strokes.first?.attributes.count == 2, name)
        }
    }

    func testTheHighlighterIsAChiselMultipliedOverWhatIsUnderIt() throws {
        let size = CGSize(width: 480, height: 300), rect = CGRect(origin: .zero, size: size)
        let under = line(.pen, from: CGPoint(x: 100, y: 200), to: CGPoint(x: 370, y: 200), width: 3.5)
        let across = line(.marker, color: yellow, from: CGPoint(x: 120, y: 200), to: CGPoint(x: 390, y: 200), width: 20)
        let down = line(.marker, color: yellow, from: CGPoint(x: 430, y: 40), to: CGPoint(x: 430, y: 240), width: 20)
        let drawing = PKDrawing(strokes: [under, across, down])
        let reader = try read(drawing, from: rect), element = reader.strokes[1]
        XCTAssertEqual(element.name, "path")
        XCTAssertEqual(element.attributes["data-ink"], "highlighter")
        XCTAssertEqual(element.attributes["fill"], SVGText.color(yellow).hex)
        XCTAssertEqual(element.attributes["style"], "mix-blend-mode:multiply")
        XCTAssertNil(reader.strokes[0].attributes["style"])
        let opacity = try XCTUnwrap(element.attributes["opacity"].flatMap(Double.init))
        XCTAssertEqual(opacity, 0.82, accuracy: 0.06, "dragged across its width it lies thinner")
        XCTAssertGreaterThan(try XCTUnwrap(reader.strokes[2].attributes["opacity"].flatMap(Double.init)), opacity + 0.08, "and along its length thicker")
        let box = SVGReader.path(element.attributes["d"] ?? "").boundingBoxOfPath, tall = SVGReader.path(reader.strokes[2].attributes["d"] ?? "").boundingBoxOfPath
        XCTAssertEqual(box.height, 26.6, accuracy: 0.5, "the chisel stands a third taller than its size")
        XCTAssertEqual(tall.width, 9.6, accuracy: 0.5, "and is half its size thick")
        XCTAssertEqual(box.minX, 120 - 4.8, accuracy: 0.3, "with a flat end")
        let drawn = Pixels(size) { reader.draw(in: $0) }
        XCTAssertLessThan(drawn.luminance(at: CGPoint(x: 250, y: 200)), 0.25, "the line still shows through the highlighter")
        XCTAssertGreaterThan(drawn.luminance(at: CGPoint(x: 250, y: 192)), 0.5, "beside it the highlighter is yellow, not dark")
        XCTAssertLessThan(drawn.luminance(at: CGPoint(x: 250, y: 192)), 0.9)
        let pdf = Pixels(size) { InkVectors.draw(drawing, from: rect, in: $0, size: size) }
        XCTAssertEqual(drawn.luminance(at: CGPoint(x: 250, y: 192)), pdf.luminance(at: CGPoint(x: 250, y: 192)), accuracy: 0.08, "as the PDF's picture of it")
        let plain = try read(drawing, from: rect, style: .init(appearance: .dark, multipliesHighlighter: false))
        XCTAssertNil(plain.all().first { $0.attributes["style"] != nil }, "on dark paper it is laid over, not multiplied")
        XCTAssertNotNil(plain.strokes[1].attributes["opacity"])
    }

    func testPenPointsPencilKitTreatsAnotherWayAreShapesToo() throws {
        let size = CGSize(width: 300, height: 120), rect = CGRect(origin: .zero, size: size)
        let cases: [(String, PKStroke)] = [
            ("faint pen", scribble(.pen, color: blue, origin: CGPoint(x: 30, y: 60), widths: 3...7, opacity: 0.5)),
            ("faint fountain pen", scribble(.fountainPen, color: blue, origin: CGPoint(x: 30, y: 60), widths: 4...9, opacity: 0.4)),
            ("flat pen", line(.pen, from: CGPoint(x: 40, y: 30), to: CGPoint(x: 240, y: 90), width: 12, height: 5)),
            ("flat fountain pen", line(.fountainPen, from: CGPoint(x: 40, y: 30), to: CGPoint(x: 240, y: 90), width: 14, height: 6, azimuth: 0.4)),
        ]
        for (name, stroke) in cases {
            XCTAssertNil(InkVectors.nib(for: stroke), name)
            let drawing = PKDrawing(strokes: [stroke]), reader = try read(drawing, from: rect), image = picture(drawing, rect: rect)
            XCTAssertNil(reader.strokes.first?.attributes["opacity"], "\(name): PencilKit draws it solid whatever its points say")
            let difference = Pixels(size) { _ in image.draw(in: rect) }.difference(to: Pixels(size) { reader.draw(in: $0) })
            XCTAssertLessThan(difference.mean, 12, name)
            XCTAssertLessThan(difference.bad, 0.03, "\(name): only the edges of the ink may differ")
        }
    }

    func testAPageOfHandwritingStaysSmall() {
        let page = CGSize(width: 612, height: 792), rect = CGRect(origin: .zero, size: page)
        let even = InkSVG.group(handwriting(.monoline, count: 600, size: 2.5...3.5), from: rect, size: page)
        XCTAssertEqual(even.components(separatedBy: "<path ").count - 1, 600, "an even line is one path")
        XCTAssertLessThan(even.utf8.count, 600 * 1_200, "\(even.utf8.count / 600) bytes a stroke")
        let oval = InkSVG.group(handwriting(.fountainPen, count: 300, size: 4...6), from: rect, size: page)
        XCTAssertEqual(oval.components(separatedBy: "<path ").count - 1, 300)
        XCTAssertLessThan(oval.utf8.count, 300 * 2_500, "\(oval.utf8.count / 300) bytes a stroke")
    }
}
