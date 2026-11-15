import XCTest
import UIKit
@testable import OwlLuna

/// Formulas written in TeX between dollar signs in a text box, set as math on the page and kept as typed in the editor.
@MainActor
final class TextMathTests: XCTestCase {
    private let width: CGFloat = 300
    private let tester = "$$\\alpha =0.3\\beta$$"

    private func runs(_ text: String) -> [MathRun] { MathRun.find(in: text as NSString) }

    private func formula(_ source: String, display: Bool = false) -> MathFormula? {
        MathFormula(source, size: 17, display: display, textFont: UIFont.systemFont(ofSize: 17))
    }

    /// The box drawn on paper, and the rows that have any ink in them.
    private func inkedRows(_ box: TextBox, width: CGFloat, canvas: CGSize) -> (rows: [Int], columns: [Int]) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            box.draw(in: context.cgContext, rect: CGRect(x: 0, y: 0, width: width, height: canvas.height), onDark: false)
        }
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return ([], []) }
        var rows = Set<Int>(), columns = Set<Int>()
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width {
                let pixel = bytes + y * cgImage.bytesPerRow + x * cgImage.bitsPerPixel / 8
                if Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) < 600 {
                    rows.insert(y)
                    columns.insert(x)
                }
            }
        }
        return (rows.sorted(), columns.sorted())
    }

    // MARK: Finding formulas

    func testFormulasAreFoundBetweenDollarSigns() {
        XCTAssertEqual(runs(tester).map(\.source), ["\\alpha =0.3\\beta"])
        XCTAssertEqual(runs(tester).map(\.display), [true])
        XCTAssertEqual(runs(tester).first?.range, NSRange(location: 0, length: (tester as NSString).length))
        XCTAssertEqual(runs("so $x^2$ and \\(y\\) then \\[z\\]").map(\.source), ["x^2", "y", "z"])
        XCTAssertEqual(runs("so $x^2$ and \\(y\\) then \\[z\\]").map(\.display), [false, false, true])
        XCTAssertEqual(runs("$$\\begin{matrix} 1 \\\\\n 2 \\end{matrix}$$").count, 1, "a display formula can run over lines")
    }

    func testPricesAndStrayDollarsAreLeftAlone() {
        for text in ["Lunch $12, taxi $8", "$5-$10", "$ x$", "a $\nb$", "costs $", "$$ $$", "$$"] {
            XCTAssertEqual(runs(text).filter { !$0.isEscape }, [], "\(text) has no formula")
        }
        XCTAssertEqual(runs("pay \\$5 for $x$").map(\.isEscape), [true, false])
        XCTAssertEqual(runs("$a \\$ b$").map(\.source), ["a \\$ b"], "an escaped dollar doesn't end a formula")
    }

    // MARK: Setting formulas

    func testTheTestersFormulaIsSet() throws {
        let set = try XCTUnwrap(formula("\\alpha =0.3\\beta", display: true))
        let typed = ("\\alpha =0.3\\beta" as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 17)])
        XCTAssertGreaterThan(set.width, 0)
        XCTAssertLessThan(set.width, typed.width * 0.7, "α = 0.3β is much shorter than its source")
        XCTAssertGreaterThan(set.ascent, 0)
        XCTAssertGreaterThan(set.descent, 0, "β reaches below the line")
    }

    func testWhatCantBeSetIsNotGuessedAt() {
        for source in ["\\unknowncommand{x}", "x^2^3", "x_1_2", "\\frac{1}", "{x", "x}", "\\left( x", "\\begin{tabular} x \\end{tabular}", "a \\\\ b"] {
            XCTAssertNil(formula(source), "\(source) is shown as typed")
        }
    }

    func testDisplayFormulasAreSetLargerThanInlineOnes() throws {
        let inline = try XCTUnwrap(formula("\\sum_{i=1}^n \\frac{1}{i}")), display = try XCTUnwrap(formula("\\sum_{i=1}^n \\frac{1}{i}", display: true))
        XCTAssertGreaterThan(display.ascent + display.descent, (inline.ascent + inline.descent) * 1.3)
        for source in ["\\sqrt[3]{x}", "\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}", "\\begin{cases} x & \\text{if } x > 0 \\\\ 0 & \\text{else} \\end{cases}",
                       "\\left\\{ x \\middle| x > 0 \\right\\}", "\\overbrace{a+b}^{2}", "\\hat{x} \\vec{v} \\mathbb{R}", "\\int_0^1 f(x)\\,dx", "f'(x)",
                       "\\lim_{x \\to 0} \\frac{\\sin x}{x}", "\\binom{n}{k}", "\\boxed{E = mc^2}", "a \\not= b", "α ≤ β"] {
            XCTAssertNotNil(formula(source, display: true), source)
        }
    }

    // MARK: In a text box

    func testABoxWithAFormulaIsMeasuredAsSet() {
        let box = TextBox(string: "$$\\frac{a}{b}$$")
        XCTAssertGreaterThan(box.height(width: width), box.height(width: width, typed: true), "a fraction is taller than its source")
        XCTAssertLessThan(box.naturalWidth(limit: width), TextBox(string: "\\frac{a}{b}").naturalWidth(limit: width))
        XCTAssertEqual(TextBox(string: "pay \\$5").naturalWidth(limit: width), TextBox(string: "pay $5").naturalWidth(limit: width),
                       "an escaped dollar shows as a dollar")
        let unknown = TextBox(string: "$\\unknown{x}$")
        XCTAssertEqual(unknown.height(width: width), unknown.height(width: width, typed: true))
        XCTAssertEqual(unknown.naturalWidth(limit: width), ("$\\unknown{x}$" as NSString).size(withAttributes: [.font: unknown.font()]).width, accuracy: 3,
                       "a formula that can't be set is shown as typed")
    }

    func testTheEditorHoldsTheSource() {
        let box = TextBox(string: "Speed $v = \\frac{d}{t}$")
        XCTAssertEqual(box.editingText(scale: 1, onDark: false).string, box.string)
        XCTAssertNil(box.editingText(scale: 1, onDark: false).attribute(.attachment, at: 6, effectiveRange: nil))
        var item = PageItem(content: .text(box), center: CGPoint(x: 200, y: 200), size: CGSize(width: width, height: 10))
        item = item.fittedToText(typed: true)
        XCTAssertEqual(item.size.height, box.height(width: width, typed: true))
    }

    func testAFormulaIsDrawnWhereTheBoxIsMeasured() {
        let box = TextBox(string: "x $$\\frac{\\alpha}{2}$$ y")
        let height = box.height(width: width), ink = inkedRows(box, width: width, canvas: CGSize(width: 400, height: 200))
        XCTAssertFalse(ink.rows.isEmpty)
        XCTAssertLessThanOrEqual(ink.rows.last ?? 0, Int(height.rounded(.up)), "nothing is drawn below the box")
        XCTAssertGreaterThanOrEqual(ink.rows.first ?? -1, 0)
    }

    func testAFormulaTooWideForItsBoxIsShrunkToFit() {
        let box = TextBox(string: "$$a+b+c+d+e+f+g+h+i+j+k+l+m+n$$"), narrow: CGFloat = 80
        let ink = inkedRows(box, width: narrow, canvas: CGSize(width: 400, height: 120))
        XCTAssertFalse(ink.columns.isEmpty)
        XCTAssertLessThanOrEqual(ink.columns.last ?? 0, Int(narrow) + 1, "the formula stays inside the box")
        XCTAssertLessThan(box.height(width: narrow), box.height(width: 400) + 1)
    }

    func testListsAndChecklistsSetTheirFormulas() {
        var box = TextBox(string: "Area $\\pi r^2$\nVolume $$\\frac{4}{3}\\pi r^3$$", list: .check)
        box.checked = [0]
        XCTAssertEqual(box.checkboxes(width: width).map(\.line), [0, 1])
        XCTAssertGreaterThan(box.height(width: width), box.height(width: width, typed: true))
        XCTAssertFalse(inkedRows(box, width: width, canvas: CGSize(width: 400, height: 200)).rows.isEmpty)
    }

    // MARK: Stored boxes

    func testABoxMeasuredByItsSourceIsRefittedWhenRead() throws {
        let box = TextBox(string: "$$\\frac{a}{b}$$")
        let placed = PageItem(content: .text(box), center: CGPoint(x: 200, y: 200), size: CGSize(width: width, height: box.height(width: width)))
        var object = try XCTUnwrap(placed.json.objectValue)
        XCTAssertNotNil(object["fit"], "a box with a formula is stamped with how it was fitted")
        object["fit"] = nil
        let typed = box.height(width: width, typed: true)
        object["h"] = .number(Double(typed))
        let read = try XCTUnwrap(PageItem(json: .object(object)))
        XCTAssertEqual(read.size.height, box.height(width: width), "a box an older build fitted to its source grows to fit its formula")
        XCTAssertEqual(read.center.y - read.size.height / 2, placed.center.y - typed / 2, accuracy: 0.01, "it grows downwards")
        XCTAssertNil(PageItem(content: .text(TextBox(string: "Lunch $12")), center: .zero, size: CGSize(width: 100, height: 21)).json.objectValue?["fit"])
    }
}
