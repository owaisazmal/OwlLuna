import XCTest
import PencilKit
@testable import OwlLuna

/// Text boxes as they were drawn and stored before typefaces, emphasis, lists and highlights, kept verbatim as the golden
/// for boxes made then.
private enum LegacyText {
    static func attributed(_ box: TextBox, color: UIColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = box.alignment.textAlignment
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: box.string, attributes: [.font: UIFont.systemFont(ofSize: box.fontSize, weight: box.isBold ? .bold : .regular),
                                                                   .foregroundColor: color, .paragraphStyle: paragraph])
    }

    static func height(_ box: TextBox, width: CGFloat) -> CGFloat {
        var measured = box
        if box.string.isEmpty || box.string.hasSuffix("\n") { measured.string += " " }
        let bounds = attributed(measured, color: .black).boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
                                                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return max(bounds.height, UIFont.systemFont(ofSize: box.fontSize, weight: box.isBold ? .bold : .regular).lineHeight).rounded(.up)
    }

    static func draw(_ box: TextBox, in ctx: CGContext, rect: CGRect, onDark: Bool) {
        guard !box.string.isEmpty else { return }
        UIGraphicsPushContext(ctx)
        attributed(box, color: box.tint.color(onDark: onDark)).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
    }

    /// What those builds read of a text box and wrote back: everything they were given, with their own keys set over it and
    /// the box refitted to their own measure, growing downwards.
    static func roundTrip(_ object: [String: JSONValue], edit: (inout String, inout Bool) -> Void) -> [String: JSONValue] {
        var string = object["text"]?.stringValue ?? "", bold = object["bold"]?.boolValue ?? false
        edit(&string, &bold)
        var written = object
        written["text"] = .string(string)
        written["fs"] = object["fs"] ?? .number(17)
        written["bold"] = .bool(bold)
        written["color"] = object["color"] ?? .string("ink")
        written["align"] = object["align"] ?? .string("leading")
        let box = TextBox(string: string, fontSize: CGFloat(written["fs"]?.doubleValue ?? 17), isBold: bold,
                          alignment: written["align"]?.stringValue.flatMap(TextBox.Alignment.init(rawValue:)) ?? .leading)
        let fitted = Double(height(box, width: CGFloat(object["w"]?.doubleValue ?? 1)))
        let dy = (fitted - (object["h"]?.doubleValue ?? fitted)) / 2, turn = object["r"]?.doubleValue ?? 0
        written["h"] = .number(fitted)
        written["x"] = .number((object["x"]?.doubleValue ?? 0) - dy * sin(turn))
        written["y"] = .number((object["y"]?.doubleValue ?? 0) + dy * cos(turn))
        return written
    }
}

/// RGBA pixels drawn into a top-left-origin context.
private struct Pixels: Equatable {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(size: CGSize, scale: CGFloat = 2, draw: (CGContext) -> Void) {
        width = Int((size.width * scale).rounded())
        height = Int((size.height * scale).rounded())
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let (w, h) = (width, height)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            draw(ctx)
        }
    }

    init(image: UIImage) {
        self.init(size: image.size, scale: image.scale) { ctx in
            UIGraphicsPushContext(ctx)
            image.draw(at: .zero)
            UIGraphicsPopContext()
        }
    }

    /// How many pixels in a rect, in points at `scale`, pass a test.
    func count(in rect: CGRect, scale: CGFloat = 2, where test: (UInt8, UInt8, UInt8, UInt8) -> Bool) -> Int {
        var count = 0
        for y in max(0, Int(rect.minY * scale))..<min(height, Int(rect.maxY * scale)) {
            for x in max(0, Int(rect.minX * scale))..<min(width, Int(rect.maxX * scale)) {
                let i = (y * width + x) * 4
                if test(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) { count += 1 }
            }
        }
        return count
    }

    /// Drawn on white: pixels darker than mid grey.
    func dark(in rect: CGRect, scale: CGFloat = 2) -> Int {
        count(in: rect, scale: scale) { r, g, b, _ in 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b) < 160 }
    }

    /// Mean luminance (0–255) of each `cell`-pixel square.
    func cellLuminance(_ cell: Int) -> [Double] {
        var means: [Double] = []
        for top in stride(from: 0, to: height, by: cell) {
            for left in stride(from: 0, to: width, by: cell) {
                var sum = 0.0, count = 0.0
                for y in top..<min(top + cell, height) {
                    for x in left..<min(left + cell, width) {
                        let i = (y * width + x) * 4
                        sum += 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])
                        count += 1
                    }
                }
                means.append(sum / count)
            }
        }
        return means
    }
}

@MainActor
final class TextBoxStyleTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)

    /// One box in every new style, each with the lines a list needs.
    private var styled: [(name: String, box: TextBox)] {
        let lines = "Buy oats\nWrite up the titration and its error bars\n\nReturn the burette"
        var boxes: [(String, TextBox)] = TextBox.Face.allCases.map { face in
            var box = TextBox(string: lines)
            box.face = face
            return (face.rawValue, box)
        }
        for (name, change) in [("italic", { (box: inout TextBox) in box.isItalic = true }), ("underline", { $0.isUnderlined = true }),
                               ("bold italic serif", { $0.isBold = true; $0.isItalic = true; $0.face = .serif }),
                               ("highlight", { $0.highlight = .yellow }), ("bullets", { $0.list = .bullet }), ("dashes", { $0.list = .dash }),
                               ("numbers", { $0.list = .number }), ("checklist", { $0.list = .check; $0.checked = [1] }),
                               ("everything", { $0.face = .fraunces; $0.isItalic = true; $0.isUnderlined = true; $0.highlight = .pink; $0.list = .check; $0.checked = [0, 3] })] {
            var box = TextBox(string: lines)
            change(&box)
            boxes.append((name, box))
        }
        return boxes
    }

    private func item(_ box: TextBox, width: CGFloat = 240, at centre: CGPoint = CGPoint(x: 200, y: 200)) -> PageItem {
        PageItem(content: .text(box), center: centre, size: CGSize(width: width, height: box.height(width: width)))
    }

    private func makeDocument(items: [PageItem] = []) async throws -> (NotebookDocument, StorageRoot) {
        let root = temporaryRoot(self)
        var page = paper.newPage()
        page.items = items
        let manifest = NotebookManifest(title: "Lab", defaults: paper, pages: [page])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        return (try await NotebookDocument.open(manifest.id, root: root), root)
    }

    /// Drawn alone on white, as wide as `width`.
    private func drawn(_ box: TextBox, width: CGFloat = 240) -> Pixels {
        let size = CGSize(width: width, height: box.height(width: width))
        return Pixels(size: size) { ctx in
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            box.draw(in: ctx, rect: CGRect(origin: .zero, size: size), onDark: false)
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: Storing

    func testNewStylesSurviveTheManifest() throws {
        var page = paper.newPage()
        page.items = styled.map { item($0.box) }
        let decoded = try XCTUnwrap(ManifestCodec.decodePage(ManifestCodec.encodePage(page)))
        XCTAssertEqual(decoded.items.compactMap(\.text), styled.map(\.box))

        let everything = try XCTUnwrap(decoded.items.last?.json.objectValue)
        XCTAssertEqual(everything["face"], .string("fraunces"))
        XCTAssertEqual(everything["italic"], .bool(true))
        XCTAssertEqual(everything["underline"], .bool(true))
        XCTAssertEqual(everything["highlight"], .string("pink"))
        XCTAssertEqual(everything["list"], .string("check"))
        XCTAssertEqual(everything["checked"], .array([.number(0), .number(3)]))
        XCTAssertEqual(decoded.items.first { $0.text?.list == .dash }?.json.objectValue?["list"], .string("dash"))

        var plain = decoded.items[decoded.items.count - 1]
        plain.content = .text(TextBox(string: "Plain again"))
        let object = try XCTUnwrap(plain.json.objectValue)
        for key in ["face", "italic", "underline", "highlight", "list", "checked"] {
            XCTAssertNil(object[key], "\(key) is left out once it is back at its default")
        }
    }

    func testABoxFromBeforeLooksAndIsStoredAsItWas() throws {
        let id = UUID().uuidString
        let old: [String: JSONValue] = ["id": .string(id), "kind": .string("text"), "text": .string("Avogadro's number\n6.022 × 10²³"),
                                        "fs": .number(24), "bold": .bool(true), "color": .string("cobalt"), "align": .string("center"),
                                        "x": .number(200), "y": .number(100), "w": .number(240), "h": .number(60), "r": .number(0)]
        let read = try XCTUnwrap(PageItem(json: .object(old)))
        let box = try XCTUnwrap(read.text)
        XCTAssertEqual(box.face, .system)
        XCTAssertFalse(box.isItalic || box.isUnderlined)
        XCTAssertNil(box.list)
        XCTAssertNil(box.highlight)
        XCTAssertTrue(box.checked.isEmpty)
        XCTAssertEqual(read.json, .object(old), "a box from before is written back key for key")

        let boxes = [TextBox(string: "One line"), TextBox(string: "Two\nlines, the second long enough to wrap in a narrow box", fontSize: 13),
                     TextBox(string: "Bold, tomato, right", fontSize: 34, isBold: true, tint: .tomato, alignment: .trailing),
                     TextBox(string: "Centred plum\n\nwith a gap", tint: .plum, alignment: .center), TextBox(string: "ends in a return\n"), box]
        for old in boxes {
            for width in [90, 240] as [CGFloat] {
                XCTAssertEqual(old.height(width: width), LegacyText.height(old, width: width), "\(old.string) at \(width)")
                let size = CGSize(width: width, height: old.height(width: width) + 8)
                for onDark in [false, true] {
                    let before = Pixels(size: size) { LegacyText.draw(old, in: $0, rect: CGRect(origin: .zero, size: size), onDark: onDark) }
                    let after = Pixels(size: size) { old.draw(in: $0, rect: CGRect(origin: .zero, size: size), onDark: onDark) }
                    XCTAssertEqual(before, after, "\(old.string) at \(width), on dark \(onDark), is drawn pixel for pixel as it was")
                }
            }
        }
    }

    func testAnOlderBuildKeepsWhatItCannotRead() throws {
        var box = TextBox(string: "Oats\nFlour\nEggs")
        box.face = .mono
        box.isItalic = true
        box.isUnderlined = true
        box.list = .check
        box.checked = [2]
        box.highlight = .green
        let written = try XCTUnwrap(item(box).json.objectValue)
        let newKeys = ["face", "italic", "underline", "list", "checked", "highlight"]

        let older = LegacyText.roundTrip(written) { string, bold in
            string += "\nMilk"
            bold = true
        }
        for key in newKeys { XCTAssertEqual(older[key], written[key], "an older build writes \(key) back untouched") }
        let back = try XCTUnwrap(PageItem(json: .object(older))?.text)
        XCTAssertEqual(back.face, .mono)
        XCTAssertTrue(back.isItalic && back.isUnderlined && back.isBold)
        XCTAssertEqual(back.list, .check)
        XCTAssertEqual(back.checked, [2])
        XCTAssertEqual(back.highlight, .green)
        XCTAssertEqual(back.string, "Oats\nFlour\nEggs\nMilk")

        var future = written
        future["face"] = .string("calligraphy")
        future["list"] = .string("roman")
        future["highlight"] = .string("neon")
        future["glow"] = .number(3)
        let read = try XCTUnwrap(PageItem(json: .object(future)))
        XCTAssertEqual(read.text?.face, .system, "a typeface from a newer version draws in the system's")
        XCTAssertNil(read.text?.list)
        XCTAssertNil(read.text?.highlight)
        var moved = read
        moved.center.x += 10
        let kept = try XCTUnwrap(moved.json.objectValue)
        for key in ["face", "list", "highlight", "glow"] { XCTAssertEqual(kept[key], future[key], "this build keeps a newer \(key) it can't read") }
        var restyled = read
        if case .text(var changed) = restyled.content {
            changed.face = .serif
            changed.list = .bullet
            restyled.content = .text(changed)
        }
        XCTAssertEqual(restyled.json.objectValue?["face"], .string("serif"), "choosing one replaces it")
        XCTAssertEqual(restyled.json.objectValue?["list"], .string("bullet"))
    }

    // MARK: Lists

    func testListsNumberTheirLinesAndStandIn() {
        XCTAssertEqual(TextBox(string: "Oats\n\nFlour\n   \nEggs").numbers, [1, nil, 2, nil, 3], "a blank line has no number and isn't counted")
        XCTAssertEqual(TextBox(string: "").numbers, [nil])
        XCTAssertEqual(TextBox(string: (1...12).map { "Step \($0)" }.joined(separator: "\n")).numbers.last, 12)

        let plain = TextBox(string: "Oats\nFlour\nEggs")
        let width: CGFloat = 200, height = plain.height(width: width)
        XCTAssertEqual(UITextView.typeset(plain, width: width).firstGlyphX, 0, accuracy: 0.5)
        for list in TextBox.List.allCases {
            var box = plain
            box.list = list
            let indent = UITextView.typeset(box, width: width).firstGlyphX
            XCTAssertGreaterThan(indent, box.fontSize, "\(list) stands its words in")
            XCTAssertGreaterThan(drawn(box, width: width).dark(in: CGRect(x: 0, y: 0, width: indent - 3, height: height)), 20,
                                 "\(list) draws its markers in the room before the words")
            XCTAssertEqual(box.height(width: width), height, accuracy: 1, "\(list) markers stand beside the lines, not between them")
        }

        var long = TextBox(string: (1...12).map { "Step \($0)" }.joined(separator: "\n"))
        long.list = .number
        var short = long
        short.string = "Step 1\nStep 2"
        let tenth = UITextView.typeset(long, width: 300).firstGlyphX, second = UITextView.typeset(short, width: 300).firstGlyphX
        XCTAssertGreaterThan(tenth, second, "a list of ten or more stands in far enough for its widest number")
    }

    func testADashListStandsInAndDrawsItsMarkerLikeABulletListAndNumbersNothing() {
        XCTAssertEqual(TextBox.List.allCases.map(\.rawValue), ["bullet", "dash", "number", "check"], "the card offers them in this order")
        XCTAssertEqual(TextBox.List(rawValue: "dash"), .dash)
        XCTAssertNotNil(UIImage(systemName: TextBox.List.dash.symbol), "the card's icon for dashes exists")

        let width: CGFloat = 200, lines = "Oats\n\nFlour\nEggs"
        let bullets = TextBox(string: lines, list: .bullet), dashes = TextBox(string: lines, list: .dash)
        let bulleted = UITextView.typeset(bullets, width: width), dashed = UITextView.typeset(dashes, width: width)
        XCTAssertEqual(dashed.firstGlyphX, bulleted.firstGlyphX, accuracy: 0.01, "the words stand in as far as a bullet list's")
        XCTAssertEqual(dashes.height(width: width), bullets.height(width: width), "and take as much room")

        let withDashes = drawn(dashes, width: width)
        XCTAssertNotEqual(withDashes, drawn(bullets, width: width), "a dash is drawn where a bullet would be")
        for (line, start) in dashed.lineStarts.enumerated() {
            let room = CGRect(x: 0, y: start.minY, width: dashed.firstGlyphX - 3, height: start.height)
            if TextBox.isItem(dashes.lines[line]) {
                XCTAssertGreaterThan(withDashes.dark(in: room), 10, "line \(line) has its dash before the words")
            } else {
                XCTAssertEqual(withDashes.dark(in: room), 0, "a blank line is passed over")
            }
        }

        let long = TextBox(string: (1...12).map { "Step \($0)" }.joined(separator: "\n"), list: .dash)
        var short = long
        short.string = "Step 1\nStep 2"
        XCTAssertEqual(UITextView.typeset(long, width: 300).firstGlyphX, UITextView.typeset(short, width: 300).firstGlyphX, accuracy: 0.01,
                       "a dash counts nothing, so ten items stand in no further than two")
    }

    func testADashSitsAtTheHeightOfABulletInEveryTypefaceAndSize() {
        func middle(of marker: String, in font: UIFont) -> CGFloat? {
            var characters = Array(marker.utf16), glyphs = [CGGlyph](repeating: 0, count: characters.count)
            guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count) else { return nil }
            var bounds = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(font, .default, glyphs, &bounds, 1)
            return bounds.midY / font.pointSize
        }
        for face in TextBox.Face.allCases {
            for size in [13, 34] as [CGFloat] {
                for bold in [false, true] {
                    let font = TextBox(string: "", fontSize: size, isBold: bold, face: face).font()
                    let dash = middle(of: "\u{2013}", in: font), bullet = middle(of: "\u{2022}", in: font)
                    XCTAssertNotNil(dash, "\(face) has an en dash of its own at \(Int(size)) pt")
                    if let dash, let bullet { XCTAssertEqual(dash, bullet, accuracy: 0.03, "\(face) at \(Int(size)) pt, bold \(bold): a dash is as high as a bullet") }
                }
            }
        }
    }

    func testTicksFollowTheirLinesThroughEdits() {
        var box = TextBox(string: "Oats\nFlour\nEggs")
        box.list = .check
        box.toggleCheck(line: 1)
        XCTAssertEqual(box.checked, [1])
        box.toggleCheck(line: 1)
        XCTAssertEqual(box.checked, [])
        box.checked = [0, 2]

        var above = box
        above.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Milk\n")
        XCTAssertEqual(above.string, "Milk\nOats\nFlour\nEggs")
        XCTAssertEqual(above.checked, [1, 3], "a line typed above moves the ticks down with their lines")

        var returnAtStart = box
        returnAtStart.replaceCharacters(in: NSRange(location: 11, length: 0), with: "\n")
        XCTAssertEqual(returnAtStart.lines, ["Oats", "Flour", "", "Eggs"])
        XCTAssertEqual(returnAtStart.checked, [0, 3], "a return at the start of a ticked line takes its tick down with it")

        var returnAtEnd = box
        returnAtEnd.replaceCharacters(in: NSRange(location: 4, length: 0), with: "\n")
        XCTAssertEqual(returnAtEnd.lines, ["Oats", "", "Flour", "Eggs"])
        XCTAssertEqual(returnAtEnd.checked, [0, 3], "the new line after a ticked one starts unticked")

        var split = box
        split.replaceCharacters(in: NSRange(location: 2, length: 0), with: "\n")
        XCTAssertEqual(split.lines, ["Oa", "ts", "Flour", "Eggs"])
        XCTAssertEqual(split.checked, [0, 3])

        var joined = box
        joined.replaceCharacters(in: NSRange(location: 10, length: 1), with: "")
        XCTAssertEqual(joined.lines, ["Oats", "FlourEggs"])
        XCTAssertEqual(joined.checked, [0], "a line joined onto the one above loses its tick")

        var gone = box
        gone.replaceCharacters(in: NSRange(location: 0, length: 5), with: "")
        XCTAssertEqual(gone.lines, ["Flour", "Eggs"])
        XCTAssertEqual(gone.checked, [1], "deleting a whole ticked line takes its tick with it")

        var typed = box
        typed.replaceCharacters(in: NSRange(location: 4, length: 0), with: " (rolled)")
        XCTAssertEqual(typed.checked, [0, 2], "typing in a line keeps the ticks where they are")

        for (range, text) in [(NSRange(location: 0, length: 0), "Milk\n"), (NSRange(location: 11, length: 0), "\n"), (NSRange(location: 4, length: 0), "\n"),
                              (NSRange(location: 10, length: 1), ""), (NSRange(location: 4, length: 6), "\nButter\nSugar\n"), (NSRange(location: 15, length: 0), "\nMilk")] {
            var exact = box, worked = box
            exact.replaceCharacters(in: range, with: text)
            worked.carryChecks(to: exact.string)
            XCTAssertEqual(worked.checked, exact.checked, "worked out from before and after, \(text.debugDescription) at \(range.location) ticks the same lines")
            XCTAssertEqual(worked.string, exact.string)
        }
    }

    func testATapTicksABoxThatIsntBeingTypedInAndUndoTakesItBack() async throws {
        var box = TextBox(string: "Oats\nFlour\nEggs", fontSize: 24)
        box.list = .check
        let placed = item(box, width: 260, at: CGPoint(x: 300, y: 300))
        let (document, root) = try await makeDocument(items: [placed])
        let pageID = document.pages[0].id
        let session = EditorSession(document: document)
        let controller = PageStackController(session: session)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where controller.canvas(forPage: 0)?.isLoaded != true { await pause(0.05) }
        func ticks() -> Set<Int> { document.pages[0].items.first?.text?.checked ?? [] }

        let view = try XCTUnwrap(window.descendants(PageItemView.self).first { $0.item.id == placed.id })
        let actions = try XCTUnwrap(view.accessibilityCustomActions)
        XCTAssertEqual(actions.map(\.name), ["Tick Oats", "Tick Flour", "Tick Eggs"])
        XCTAssertTrue(actions[1].actionHandler?(actions[1]) ?? false)
        XCTAssertEqual(ticks(), [1])
        XCTAssertEqual(document.undoManager.undoActionName, "Tick")
        func label() -> String? { window.descendants(PageItemView.self).first { $0.item.id == placed.id }?.accessibilityLabel }
        for _ in 0..<40 where label() == "Oats\nFlour\nEggs" { await pause(0.05) }
        XCTAssertEqual(label(), "Oats\nFlour, ticked\nEggs", "VoiceOver hears which lines are ticked")
        document.undoManager.undo()
        XCTAssertEqual(ticks(), [], "a tick is one undo step")

        controller.select(ItemSelection(pageID: pageID, itemID: placed.id))
        let selection = try XCTUnwrap(window.descendants(ItemSelectionView.self).first)
        let boxes = box.checkboxes(width: placed.size.width)
        XCTAssertEqual(boxes.map(\.line), [0, 1, 2])
        selection.onTap?(CGPoint(x: boxes[2].rect.midX, y: boxes[2].rect.midY))
        XCTAssertEqual(ticks(), [2], "a tap on a box ticks it")
        XCTAssertFalse(session.isEditingText, "and doesn't start typing")
        await pause(0.1)
        selection.onTap?(CGPoint(x: boxes[2].rect.midX + 2, y: boxes[2].rect.midY - 3))
        XCTAssertEqual(ticks(), [], "a second tap takes the tick off")
        await pause(0.1)
        document.undoManager.undo()
        XCTAssertEqual(ticks(), [2])

        let saved = await document.flush()
        XCTAssertTrue(saved)
        let stored = try await NotebookPackage(root: root, id: document.id).readManifest().manifest
        XCTAssertEqual(stored.pages[0].items.first?.text?.checked, [2], "the tick is saved")

        selection.onTap?(CGPoint(x: placed.size.width - 20, y: boxes[1].rect.midY))
        XCTAssertTrue(session.isEditingText, "a tap on the words starts typing")
        XCTAssertEqual(ticks(), [2])
    }

    // MARK: Drawing

    func testEachStyleChangesWhatIsDrawn() {
        let width: CGFloat = 240
        let plain = TextBox(string: "Hamburgefonstiv\nquick brown fox")
        let upright = drawn(plain)
        for (name, box) in styled where !(box.face == .system && box.list == nil && !box.isItalic && !box.isUnderlined && box.highlight == nil) {
            XCTAssertNotEqual(drawn(TextBox(string: plain.string, face: box.face, isItalic: box.isItalic, isUnderlined: box.isUnderlined, list: box.list,
                                            highlight: box.highlight)), upright, "\(name) changes the drawing")
        }

        for face in TextBox.Face.allCases {
            var box = TextBox(string: "Hamburgefonstiv")
            box.face = face
            box.isItalic = true
            let font = box.font()
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic) || !font.fontDescriptor.matrix.isIdentity,
                          "\(face) has an italic of its own or leans")
            box.isItalic = false
            let regular = drawn(box).dark(in: CGRect(x: 0, y: 0, width: width, height: 30))
            box.isBold = true
            XCTAssertGreaterThan(drawn(box).dark(in: CGRect(x: 0, y: 0, width: width, height: 30)), regular + regular / 5, "\(face) has a bold")
        }
        XCTAssertTrue(TextBox(string: "", face: .fraunces).font().fontName.hasPrefix("Fraunces"), "the bundled Fraunces is found")
        XCTAssertTrue(TextBox(string: "", face: .mono).font().fontDescriptor.symbolicTraits.contains(.traitMonoSpace))

        let highlighted = drawn(TextBox(string: plain.string, highlight: .yellow))
        func washed(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> Bool { r > 200 && Int(r) - Int(b) > 80 }
        XCTAssertGreaterThan(highlighted.count(in: CGRect(x: 0, y: 0, width: width, height: 20), where: washed), 200, "a yellow wash lies behind the words")
        XCTAssertEqual(upright.count(in: CGRect(x: 0, y: 0, width: width, height: 20), where: washed), 0)

        let underlined = drawn(TextBox(string: "Hamburgefonstiv", isUnderlined: true)), bare = drawn(TextBox(string: "Hamburgefonstiv"))
        let baseline = UIFont.systemFont(ofSize: 17).ascender
        let below = CGRect(x: 0, y: baseline + 0.5, width: 100, height: 3)
        XCTAssertGreaterThan(underlined.dark(in: below), bare.dark(in: below) + 40, "an underline runs under the words")

        var checklist = TextBox(string: "Oats\nFlour", list: .check)
        let open = drawn(checklist)
        checklist.checked = [0]
        let done = drawn(checklist)
        let first = checklist.checkboxes(width: width)[0].rect
        XCTAssertGreaterThan(done.dark(in: first.insetBy(dx: 3, dy: 3)), open.dark(in: first.insetBy(dx: 3, dy: 3)) + 10, "a ticked box has its tick")
        XCTAssertGreaterThan(open.dark(in: first), 30, "an open box is drawn")
    }

    func testEveryStyleLooksTheSameOnScreenInThumbnailsAndInExport() async throws {
        let items = styled.enumerated().map { index, entry in
            item(entry.box, width: 250, at: CGPoint(x: 150 + CGFloat(index % 2) * 300, y: 70 + CGFloat(index / 2) * 110))
        }
        let (document, _) = try await makeDocument(items: items)
        let page = document.pages[0]
        let url = try await NotebookExporter.export(.init(title: "Lab", pages: document.pages, inMemoryInk: [:], package: document.package)) { _ in }
        let pdf = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: 1))
        let exported = Pixels(size: page.size, scale: 1) { ctx in
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: page.size))
            PageRenderer.drawPDFPage(pdf, in: ctx, size: page.size)
        }
        let screen = Pixels(image: PageRenderer.image(of: page, ink: PKDrawing(), assets: document.package.assetsDirectory, width: page.size.width))
        let worst = zip(exported.cellLuminance(16), screen.cellLuminance(16)).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, 6, "the exported page matches the page as thumbnails draw it")

        for entry in items {
            guard let box = entry.text else { continue }
            let size = entry.size
            let alone = Pixels(size: size) { box.draw(in: $0, rect: CGRect(origin: .zero, size: size), onDark: false) }
            let inPage = Pixels(size: size) { ctx in
                ctx.translateBy(x: -entry.center.x + size.width / 2, y: -entry.center.y + size.height / 2)
                PageItemRenderer.draw([entry], pageSize: page.size, assets: document.package.assetsDirectory, in: ctx, size: page.size)
            }
            XCTAssertEqual(alone, inPage, "the editor's own drawing of \(box.string.prefix(8)) is the renderer's")
        }
    }

    func testTheEditorLaysTypingOutAsTheBoxIsDrawn() {
        let width: CGFloat = 240
        for (name, box) in styled {
            let typing = UITextView.typeset(box, width: width)
            XCTAssertEqual(typing.height, box.height(width: width), accuracy: 2, "\(name) is as tall typed as drawn")
            guard box.list == .check else { continue }
            // Zoomed in, the words are typed and the boxes drawn beside them at the zoom.
            for scale in [1, 1.5, 2.25] as [CGFloat] {
                let typed = UITextView.typeset(box, width: width * scale, scale: scale)
                let boxes = box.checkboxes(width: width * scale, scale: scale)
                XCTAssertEqual(boxes.map(\.line), box.lines.indices.filter { TextBox.isItem(box.lines[$0]) }, name)
                for (line, rect) in boxes {
                    let caret = typed.lineStarts[line]
                    XCTAssertEqual(caret.midY, rect.midY, accuracy: 3 * scale, "\(name) at \(scale)×: line \(line)'s box sits on the line typed")
                    XCTAssertGreaterThan(caret.minX, rect.maxX, "\(name) at \(scale)×: line \(line)'s words start after its box")
                }
            }
        }
    }

    func testZoomedInTypingWrapsWhereTheBoxIsDrawn() {
        var boxes = styled
        for (name, size) in [("small", 13), ("title", 34)] as [(String, CGFloat)] {
            var box = TextBox(string: "Write up the titration and its error bars\nReturn the burette")
            box.fontSize = size
            boxes.append((name, box))
        }
        func lines(_ height: CGFloat, _ font: UIFont) -> Int { Int((height / font.lineHeight).rounded()) }
        for (name, box) in boxes {
            for width in stride(from: 120, through: 300, by: 30) as StrideThrough<CGFloat> {
                let drawn = lines(box.height(width: width), box.font())
                for scale in [1, 1.5, 2.25] as [CGFloat] {
                    let typed = UITextView.typeset(box, width: width * scale, scale: scale)
                    XCTAssertEqual(lines(typed.height, box.font(scale: scale)), drawn, "\(name), \(Int(width)) pt wide, at \(scale)× wraps as drawn")
                }
            }
        }
    }
}

private extension UIView {
    func descendants<View: UIView>(_ type: View.Type) -> [View] {
        subviews.flatMap { ($0 as? View).map { [$0] } ?? [] + $0.descendants(type) }
    }
}

private extension UITextView {
    struct Typing {
        var height: CGFloat
        var lineStarts: [CGRect]
        var firstGlyphX: CGFloat { lineStarts.first?.minX ?? 0 }
    }

    /// A text view set up as the editor sets its own up over a box, holding the box's words, laid out at a width.
    static func typeset(_ box: TextBox, width: CGFloat, scale: CGFloat = 1) -> Typing {
        let view = UITextView()
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.attributedText = box.editingText(scale: scale, onDark: false)
        view.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
        view.layoutIfNeeded()
        let height = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        var starts: [CGRect] = [], offset = 0
        for line in box.lines {
            let position = view.position(from: view.beginningOfDocument, offset: offset) ?? view.endOfDocument
            starts.append(view.caretRect(for: position))
            offset += (line as NSString).length + 1
        }
        return Typing(height: height, lineStarts: starts)
    }
}
