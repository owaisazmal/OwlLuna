import XCTest
@testable import OwlLuna

/// Counts take the form each language uses for that number, from the plural rules in the string catalogs.
final class PluralTests: XCTestCase {
    private var widgets: Bundle {
        get throws { try XCTUnwrap(Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appending(path: "OwlLunaWidgets.appex")) }) }
    }

    private func language(_ code: String, in bundle: Bundle = .main) throws -> Bundle {
        try XCTUnwrap(bundle.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)), "\(code) is built in")
    }

    private func text(_ value: String.LocalizationValue, _ code: String) throws -> String {
        String(localized: value, bundle: try language(code), locale: Locale(identifier: code))
    }

    func testACountTakesTheFormItsNumberNeeds() throws {
        XCTAssertEqual(try text("\(1) pages", "en"), "1 page")
        XCTAssertEqual(try text("\(0) pages", "en"), "0 pages")
        XCTAssertEqual(try text("\(12) pages", "en"), "12 pages")
        XCTAssertEqual(try text("\(0) pages", "fr"), "0 page", "French counts nought as one")
        XCTAssertEqual(try text("\(1) pages", "es"), "1 página")
        XCTAssertEqual(try text("\(5) pages", "de"), "5 Seiten")
        XCTAssertEqual(try text("\(1) strokes. Drag to move, tap for more.", "en"), "1 stroke. Drag to move, tap for more.")
        XCTAssertEqual(try text("\(1) notebooks waiting until they're closed", "de"), "1 Notizbuch wartet, bis es geschlossen ist")
        XCTAssertEqual(try text("\(1) more matches", "en"), "1 more match")
        XCTAssertEqual(try text("\(12) more matches", "en"), "12 more matches")
        XCTAssertEqual(try text("\(1) more matches", "de"), "1 weiterer Treffer")
        XCTAssertEqual(try text("\(3) more matches", "fr"), "3 autres résultats")
    }

    func testCountsInsideSentencesAgreeToo() throws {
        XCTAssertEqual(try text("\("Physics"), folder, \(1) notebooks", "en"), "Physics, folder, 1 notebook")
        XCTAssertEqual(try text("\("Physique"), folder, \(3) notebooks", "fr"), "Physique, dossier, 3 carnets")
        XCTAssertEqual(try text("\(1) pages on \(1) days", "en"), "1 page on 1 day")
        XCTAssertEqual(try text("\(3) pages on \(1) days", "en"), "3 pages on 1 day")
        XCTAssertEqual(try text("\(3) pages on \(2) days", "de"), "3 Seiten an 2 Tagen")
        XCTAssertEqual(try text("Moved \(1) notebooks to \("Biology")", "es"), "1 cuaderno movido a Biology")
        XCTAssertEqual(try text("\(0) of \(1) strokes written", "en"), "0 of 1 stroke written")
        XCTAssertEqual(try text("\(1) of \(5) strokes written", "fr"), "1 trait écrit sur 5", "in French the strokes written are counted")
        XCTAssertEqual(try text("\(1) of \(5) strokes written", "de"), "1 von 5 Strichen geschrieben")
    }

    func testTheWidgetsWordUnderTheWeeksCountAgreesWithIt() throws {
        let widgets = try self.widgets
        func caption(_ pages: Int, _ code: String) throws -> String {
            String(localized: "widget.pagesCaption", defaultValue: "\(pages) pages", bundle: try language(code, in: widgets), locale: Locale(identifier: code))
        }
        XCTAssertEqual(try caption(1, "en"), "page")
        XCTAssertEqual(try caption(4, "en"), "pages")
        XCTAssertEqual(try caption(1, "de"), "Seite")
        XCTAssertEqual(try caption(0, "fr"), "page")
        XCTAssertEqual(String(localized: "This week: \(1) pages on \(1) days", bundle: try language("es", in: widgets), locale: Locale(identifier: "es")),
                       "Esta semana: 1 página en 1 día")
    }

    /// A count spelled out as "1 page" beside "%lld pages" only has the two forms English needs.
    func testNoCountIsWrittenOutForOne() throws {
        let pattern = try NSRegularExpression(pattern: #"(^|[^%$\d])1 [a-z]|\(s\)"#)
        for bundle in [Bundle.main, try widgets] {
            let spanish = try language("es", in: bundle)
            var keys: [String] = []
            for kind in ["strings", "stringsdict"] {
                let url = try XCTUnwrap(spanish.url(forResource: "Localizable", withExtension: kind))
                keys += (NSDictionary(contentsOf: url)?.allKeys as? [String]) ?? []
            }
            XCTAssertGreaterThan(keys.count, 10)
            let spelled = keys.filter { $0 != "1 to %lld" && pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            XCTAssertEqual(spelled, [], "use one string with plural variations instead")
        }
    }
}
