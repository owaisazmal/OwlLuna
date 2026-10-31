import XCTest
@testable import OwlLuna

@MainActor
final class NewNotebookTests: XCTestCase {
    private let id = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    func testEveryStarterHasADistinctTitleAndValidValues() {
        let titles = NotebookStarter.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        for starter in NotebookStarter.allCases {
            XCTAssertFalse(starter.title.isEmpty)
            XCTAssertFalse(starter.notebookTitle.isEmpty)
            let spec = starter.spec(for: id)
            XCTAssertEqual(spec.style, starter.coverStyle)
            XCTAssertNotNil(CoverStyle(rawValue: spec.styleRaw))
            XCTAssertNotNil(ClothColor(rawValue: spec.clothRaw))
            XCTAssertEqual(spec.inksRaw.compactMap(RisoInk.init(rawValue:)).count, 2)
            XCTAssertTrue(starter.accessibilityLabel(for: id).hasPrefix("\(starter.title) starter: "), starter.accessibilityLabel(for: id))
        }
        XCTAssertEqual(NotebookStarter.journal.accessibilityLabel(for: id), "Journal starter: dotted ivory paper, moss cloth")
        XCTAssertEqual(NotebookStarter.lecture.template, .cornell)
        XCTAssertEqual(NotebookStarter.planner.template, .weekPlanner)
        XCTAssertEqual(NotebookStarter.music.spec(for: id).cloth, .oxblood)
        XCTAssertEqual(NotebookStarter.plain.spec(for: id).cloth, .seeded(by: id))
        XCTAssertEqual(NotebookStarter.plain.notebookTitle, "Untitled Notebook")
    }

    func testAPairOfInksIsJoinedInTheLanguageItIsSaidIn() throws {
        XCTAssertEqual(RisoInk.name(of: RisoInk.pairs[0]), "Teal and Riso blue")
        for (code, pair) in [("es", "Verde azulado y Azul riso"), ("fr", "Bleu canard et Bleu riso"), ("de", "Petrol und Riso-Blau")] {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)), code)
            let teal = String(localized: "Teal", bundle: bundle), blue = String(localized: "Riso blue", bundle: bundle)
            XCTAssertEqual(String(localized: "\(teal) and \(blue)", bundle: bundle, locale: Locale(identifier: code)), pair)
        }
    }

    func testPlainFollowsTheSettingsDefaults() {
        let defaults = UserDefaults.standard
        let saved = [SettingsKey.defaultTemplate, SettingsKey.defaultPaperColor].map { ($0, defaults.object(forKey: $0)) }
        addTeardownBlock { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        defaults.set(PaperTemplate.engineering.rawValue, forKey: SettingsKey.defaultTemplate)
        defaults.set(PaperColor.sage.rawValue, forKey: SettingsKey.defaultPaperColor)
        XCTAssertEqual(NotebookStarter.plain.template, .engineering)
        XCTAssertEqual(NotebookStarter.plain.paperColor, .sage)
    }

    func testSketchbookIsAPinkAndYellowPrint() {
        let spec = NotebookStarter.sketchbook.spec(for: id)
        XCTAssertEqual(spec.style, .print)
        XCTAssertEqual(spec.inks.0, .pink)
        XCTAssertEqual(spec.inks.1, .yellow)
        XCTAssertEqual(NotebookStarter.sketchbook.template, .blank)
        XCTAssertEqual(NotebookStarter.sketchbook.paperColor, .white)
    }

    func testShuffleAlwaysChangesSomethingAndKeepsTheStyle() {
        var rng = SplitMix64(state: 42)
        for style in CoverStyle.allCases {
            var spec = CoverSpec(style: style, cloth: .moss, inks: RisoInk.pairs[1], seed: 7)
            for _ in 0..<200 {
                let next = CoverShuffle.next(spec, using: &rng)
                XCTAssertEqual(next.style, style)
                if style == .print {
                    XCTAssertNotEqual(next.seed, spec.seed)
                    XCTAssertFalse(next.inks == spec.inks, "a new pair of inks")
                    XCTAssertTrue(RisoInk.pairs.contains { $0 == next.inks })
                } else {
                    XCTAssertNotEqual(next.cloth, spec.cloth)
                }
                spec = next
            }
        }
    }
}
