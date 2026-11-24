import XCTest
import UIKit
@testable import OwlLuna

/// Text boxes as the TestFlight build before typefaces, emphasis, lists and highlights measured and stored them.
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

    /// What that build read of a text box and wrote back: everything it was given, with its own keys set over it and the
    /// box refitted to its own measure, growing downwards.
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

/// Text boxes with the new styles going through the older build and coming back.
@MainActor
final class TextBoxCompatTests: XCTestCase {
    private func item(_ box: TextBox, width: CGFloat = 240, at centre: CGPoint = CGPoint(x: 200, y: 200)) -> PageItem {
        PageItem(content: .text(box), center: centre, size: CGSize(width: width, height: box.height(width: width)))
    }

    /// Written here, then read, edited and written back by the older build, then read here again.
    private func throughOlderBuild(_ placed: PageItem, edit: (inout String) -> Void = { _ in }) throws -> PageItem {
        let older = LegacyText.roundTrip(try XCTUnwrap(placed.json.objectValue)) { string, _ in edit(&string) }
        return try XCTUnwrap(PageItem(json: .object(older)))
    }

    /// The thumbnail key as builds before text styles worked it out, for a page on a template.
    private func unsaltedKey(_ page: NotebookPage) -> String {
        guard case .template(let raw) = page.background else { return "" }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let dayKey = page.day.map { "|d:\($0)" } ?? ""
        let itemsKey = page.extra["items"].flatMap { try? $0.serialized(pretty: false) }.map { "|i:" + String(decoding: $0, as: UTF8.self) } ?? ""
        for byte in "t:\(raw)|\(page.paperColorRaw)|\(Int(page.size.width))x\(Int(page.size.height))\(dayKey)\(itemsKey)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01b3
        }
        return String(hash, radix: 16).prefix(8).description
    }

    // MARK: Storing

    func testAPlainBoxIsStoredAsBefore() throws {
        let before: Set<String> = ["id", "kind", "text", "fs", "bold", "color", "align", "x", "y", "w", "h", "r"]
        for box in [TextBox(string: "Avogadro's number\n6.022 × 10²³", fontSize: 24, isBold: true, tint: .cobalt, alignment: .center),
                    TextBox(string: "Oats\n\nFlour"), TextBox(string: "Plum, right", tint: .plum, alignment: .trailing)] {
            let object = try XCTUnwrap(item(box).json.objectValue)
            XCTAssertEqual(Set(object.keys), before, "\(box.string) is written with the keys it always had")
        }
        let washed = try XCTUnwrap(item(TextBox(string: "Underlined and washed", isUnderlined: true, highlight: .yellow)).json.objectValue)
        XCTAssertNil(washed["fit"], "an underline or highlight doesn't change where the words wrap")
        XCTAssertNil(washed["checkedText"])

        let checklist = try XCTUnwrap(item(TextBox(string: "Oats\nFlour", list: .check, checked: [1])).json.objectValue)
        XCTAssertEqual(checklist["checkedText"], .string("Oats\nFlour"))
        XCTAssertNotNil(checklist["fit"])
        XCTAssertNil(item(TextBox(string: "Oats\nFlour", list: .check)).json.objectValue?["checkedText"], "no ticks, nothing to place them by")

        let older = try throughOlderBuild(item(TextBox(string: "Oats\nFlour"))) { $0 += " and sugar from the mill past the bridge" }
        XCTAssertEqual(older.size.height, LegacyText.height(TextBox(string: "Oats\nFlour and sugar from the mill past the bridge"), width: 240),
                       "a plain box keeps the height the older build gave it")
    }

    // MARK: Heights

    func testABoxTheOlderBuildRefittedIsAsTallAsItsWordsAgain() throws {
        let boxes: [(name: String, box: TextBox)] = [
            ("Fraunces", TextBox(string: "Lab notes\nTitration", face: .fraunces)),
            ("Mono", TextBox(string: "Write up the titration and its error bars before Friday", face: .mono)),
            ("checklist", TextBox(string: "Buy oats\nWrite up the titration and its error bars\nReturn the burette", list: .check, checked: [1])),
            ("dashes", TextBox(string: "Buy oats\nWrite up the titration and its error bars\nReturn the burette", list: .dash)),
        ]
        for (name, box) in boxes {
            let width = try XCTUnwrap(stride(from: 120 as CGFloat, through: 320, by: 4).first { LegacyText.height(box, width: $0) < box.height(width: $0) },
                                      "\(name) is shorter as the older build measures it")
            let placed = item(box, width: width)
            let back = try throughOlderBuild(placed)
            XCTAssertEqual(back.size.width, width)
            XCTAssertEqual(back.size.height, box.height(width: width), "\(name) is as tall again as its words need")
            XCTAssertEqual(back.center.y - back.size.height / 2, placed.center.y - placed.size.height / 2, accuracy: 0.001, "\(name)'s top stays put")
            XCTAssertEqual(back.text, box)

            let again = try XCTUnwrap(PageItem(json: back.json))
            XCTAssertEqual(again.size, back.size)
            XCTAssertEqual(again.center, back.center)
            XCTAssertEqual(again.json, back.json, "written back, \(name)'s height and its fit agree again")
        }
    }

    func testNewWordsTheOlderBuildWrappedAreMeasuredAgainEvenAtTheSameHeight() throws {
        let placed = item(TextBox(string: "Oats\nFlour", list: .bullet))
        var older = LegacyText.roundTrip(try XCTUnwrap(placed.json.objectValue)) { string, _ in
            string += " from the mill on the hill, the one past the bridge, in the big paper sacks"
        }
        older["h"] = .number(Double(placed.size.height))
        older["y"] = .number(Double(placed.center.y))
        let back = try XCTUnwrap(PageItem(json: .object(older)))
        let edited = try XCTUnwrap(back.text)
        XCTAssertGreaterThan(edited.height(width: 240), placed.size.height)
        XCTAssertEqual(back.size.height, edited.height(width: 240))

        var roomy = item(TextBox(string: "Oats", face: .serif))
        roomy.size.height += 30
        XCTAssertEqual(PageItem(json: roomy.json)?.size, roomy.size, "a height this build gave a box itself is kept")
    }

    // MARK: Ticks

    func testTicksStayOnTheirLinesThroughTheOlderBuildsEdits() throws {
        func ticked(_ text: String, _ checked: Set<Int>, edit: (inout String) -> Void) throws -> [String] {
            let back = try XCTUnwrap(throughOlderBuild(item(TextBox(string: text, list: .check, checked: checked)), edit: edit).text)
            return back.checked.sorted().map { back.lines[$0] }
        }
        XCTAssertEqual(try ticked("Milk\nEggs\nBread", [1]) { $0 = "Butter\n" + $0 }, ["Eggs"], "a line typed above")
        XCTAssertEqual(try ticked("Milk\nEggs\nBread", [2]) { $0 = "Eggs\nBread" }, ["Bread"], "a line deleted above")
        XCTAssertEqual(try ticked("Milk\nEgs\nBread", [1]) { $0 = "Milk\nEggs\nBread" }, ["Eggs"], "a typo fixed in the ticked line")
        XCTAssertEqual(try ticked("Milk\nEgs\nBread", [1, 2]) { $0 = "Milk\nEggs\nBread\nButter" }, ["Eggs", "Bread"], "a typo fixed and a line added at the end")
        XCTAssertEqual(try ticked("Milk\nEggs\nBread\nJam", [1, 3]) { $0 = "Butter\nMilk\nEggs\nJam" }, ["Eggs", "Jam"], "a line added above and one deleted below")
        XCTAssertEqual(try ticked("Milk\nEggs\nBread", [0, 1]) { $0 = "Milk\nBread" }, ["Milk"], "a ticked line deleted takes its tick with it")
        XCTAssertEqual(try ticked("Milk\nEggs\nBread", [2]) { $0 = "Milk\nEggs" }, [], "and so does the last line")

        var stale = try XCTUnwrap(item(TextBox(string: "Milk\nEggs", list: .check, checked: [1])).json.objectValue)
        stale["checked"] = .array([.number(1), .number(7)])
        XCTAssertEqual(PageItem(json: .object(stale))?.text?.checked, [1], "a tick past the last line is dropped")
    }

    func testATickedLineBackspacedToNothingIsUntickedWhenTypedInAgain() {
        let box = TextBox(string: "Oats\nFlour", list: .check, checked: [0, 1])
        var typed = box
        for line in ["Oat", "Oa", "O", "", "M", "Mi", "Mil", "Milk"] {
            typed.carryChecks(to: line + "\nFlour")
            if line.isEmpty { XCTAssertEqual(typed.checked, [1], "an emptied line has no box, so it has no tick") }
        }
        XCTAssertEqual(typed.string, "Milk\nFlour")
        XCTAssertEqual(typed.checked, [1], "what is typed on it starts unticked")

        var pressed = box
        for _ in 0..<4 { pressed.replaceCharacters(in: NSRange(location: (pressed.lines[0] as NSString).length - 1, length: 1), with: "") }
        XCTAssertEqual(pressed.lines, ["", "Flour"])
        for (offset, letter) in "Milk".enumerated() { pressed.replaceCharacters(in: NSRange(location: offset, length: 0), with: String(letter)) }
        XCTAssertEqual(pressed.string, "Milk\nFlour")
        XCTAssertEqual(pressed.checked, [1])

        var retyped = box
        retyped.replaceCharacters(in: NSRange(location: 0, length: 4), with: "Milk")
        XCTAssertEqual(retyped.checked, [0, 1], "words typed over a ticked line's in one go keep its tick")
    }

    func testBlankLinesWithWindowsReturnsAreLeftOutOfALists() throws {
        XCTAssertEqual(TextBox(string: "Oats\r\n\r\nFlour\r\nEggs", list: .number).numbers, [1, nil, 2, 3])
        XCTAssertFalse(TextBox.isItem("\r"))
        XCTAssertFalse(TextBox.isItem(" \u{2029} "))
        XCTAssertEqual(TextBox(string: "Oats\r\n\r\nFlour", list: .check).checkboxes(width: 240).map(\.line), [0, 2], "a blank line gets no box")
        let read = try XCTUnwrap(PageItem(json: item(TextBox(string: "Oats\r\n\r\nFlour", list: .check, checked: [0, 1])).json))
        XCTAssertEqual(read.text?.checked, [0], "nor a tick")
    }

    // MARK: Newer values

    func testAColourOrAlignmentFromANewerVersionSurvivesAMove() throws {
        var future = try XCTUnwrap(item(TextBox(string: "Saffron")).json.objectValue)
        future["color"] = .string("saffron")
        future["align"] = .string("justified")
        let read = try XCTUnwrap(PageItem(json: .object(future)))
        XCTAssertEqual(read.text?.tint, .ink)
        XCTAssertEqual(read.text?.alignment, .leading)
        var moved = read
        moved.center.x += 10
        let kept = try XCTUnwrap(moved.json.objectValue)
        XCTAssertEqual(kept["color"], .string("saffron"), "this build keeps a newer colour it can't read")
        XCTAssertEqual(kept["align"], .string("justified"))

        var restyled = read
        restyled.content = .text(TextBox(string: "Saffron", tint: .moss, alignment: .center))
        XCTAssertEqual(restyled.json.objectValue?["color"], .string("moss"), "choosing one replaces it")
        XCTAssertEqual(restyled.json.objectValue?["align"], .string("center"))
    }

    func testAListKindThisBuildDoesNotKnowIsPlainWordsAndSurvivesAMove() throws {
        let placed = item(TextBox(string: "Oats\nFlour", list: .dash))
        var future = try XCTUnwrap(placed.json.objectValue)
        future["list"] = .string("arrow")
        let read = try XCTUnwrap(PageItem(json: .object(future)))
        XCTAssertNil(read.text?.list, "a list from a newer version is plain words here")
        XCTAssertEqual(read.size, placed.size, "and keeps the height the newer version gave it")

        var moved = read
        moved.center.x += 10
        let kept = try XCTUnwrap(moved.json.objectValue)
        XCTAssertEqual(kept["list"], .string("arrow"), "this build keeps a newer list it can't read")
        XCTAssertEqual(kept["fit"], future["fit"])

        var restyled = read
        restyled.content = .text(TextBox(string: "Oats\nFlour", list: .dash))
        XCTAssertEqual(restyled.json.objectValue?["list"], .string("dash"), "choosing one replaces it")
    }

    func testADashListSurvivesTheOlderBuildsEdits() throws {
        let back = try throughOlderBuild(item(TextBox(string: "Oats\nFlour", list: .dash))) { $0 += "\nEggs" }
        XCTAssertEqual(back.text?.list, .dash)
        XCTAssertEqual(back.text?.string, "Oats\nFlour\nEggs")
        XCTAssertEqual(back.json.objectValue?["list"], .string("dash"))
    }

    // MARK: Thumbnails

    func testOnlyPagesWithStyledTextGetNewThumbnailNames() {
        let blank = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter).newPage()
        XCTAssertEqual(blank.appearanceKey, unsaltedKey(blank))
        var plain = blank
        plain.items = [item(TextBox(string: "Oats", isBold: true, tint: .tomato)),
                       PageItem(content: .sticker("heart"), center: CGPoint(x: 400, y: 400), size: CGSize(width: 80, height: 80))]
        XCTAssertEqual(plain.appearanceKey, unsaltedKey(plain), "a page of plain boxes keeps the thumbnail it has")

        let changes: [(String, (inout TextBox) -> Void)] = [("list", { $0.list = .bullet }), ("dash list", { $0.list = .dash }), ("face", { $0.face = .mono }),
                                                             ("italic", { $0.isItalic = true }), ("underline", { $0.isUnderlined = true }), ("highlight", { $0.highlight = .yellow })]
        for (name, change) in changes {
            var box = TextBox(string: "Oats")
            change(&box)
            var styled = blank
            styled.items = [item(box)]
            XCTAssertNotEqual(styled.appearanceKey, unsaltedKey(styled), "a page with a \(name) is drawn afresh")
        }
    }
}
