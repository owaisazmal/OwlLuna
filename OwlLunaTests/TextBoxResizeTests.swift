import XCTest
import UIKit
@testable import OwlLuna

/// Resizing a text box by its corner handle, a pinch, its width grip and VoiceOver's steps: a touch that asks for
/// nothing leaves the box alone, and a limit stops it where it is.
@MainActor
final class TextBoxResizeTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
    private let page = CGSize(width: 612, height: 792)
    /// How far the selection lets a drag or a pinch scale an item on this page, and how wide the grip lets a box get.
    private var limit: CGFloat { max(page.width, page.height) * 1.5 }
    private var widest: CGFloat { page.width * 1.5 }

    private func item(_ box: TextBox, width: CGFloat = 200, rotation: CGFloat = 0) -> PageItem {
        PageItem(content: .text(box), center: CGPoint(x: 300, y: 300), size: CGSize(width: width, height: box.height(width: width)), rotation: rotation)
    }

    private func box(_ string: String = "Eggs", size: CGFloat = 17, list: TextBox.List? = nil) -> TextBox {
        var box = TextBox(string: string, fontSize: size)
        box.list = list
        return box
    }

    /// One of every kind of box the editor makes: each type size on one line, lists, formulas, wrapped and turned.
    private var boxes: [(name: String, item: PageItem)] {
        let wrapped = "A line long enough to wrap when the box is narrow, and then to wrap again"
        return [8, 13, 17, 24, 34, 200].map { ("one line at \($0) pt", item(box(size: $0), width: $0 == 200 ? 600 : 200)) }
            + TextBox.List.allCases.map { ("a \($0.rawValue) list", item(box(list: $0))) }
            + [("a formula", item(box("$x^2$"))), ("a fraction", item(box("$$\\frac{a}{b}$$"))), ("wrapped", item(box(wrapped))),
               ("turned", item(box(), rotation: .pi / 6)), ("as wide as the page", item(box(wrapped), width: page.width))]
    }

    func testATouchThatAsksForNothingLeavesABoxAsItIs() {
        XCTAssertLessThan(item(box(size: 13)).size.height, PageItem.minimumSide, "a line of Small or Body type is shorter than a fingertip")
        XCTAssertLessThan(item(box(size: 17)).size.height, PageItem.minimumSide)
        for (name, placed) in boxes {
            XCTAssertEqual(placed.scaled(by: 1, limit: limit), placed, "\(name): moving or turning it changes neither its size nor its type")
            XCTAssertEqual(ItemSelectionView.stretched(placed, side: .right, by: 0, limit: widest), placed, "\(name): the width grip")
        }
        let long = item(box(Array(repeating: "Line", count: 80).joined(separator: "\n")))
        XCTAssertGreaterThan(long.size.height, limit)
        XCTAssertEqual(long.scaled(by: 1, limit: limit), long, "a box of many lines isn't made smaller for its height")
    }

    func testAOneLineBoxGetsSmallerWithItsType() throws {
        for size in TextBox.sizes.map(\.points) {
            let placed = item(box(size: size))
            let smaller = placed.scaled(by: 0.8, limit: limit)
            XCTAssertEqual(try XCTUnwrap(smaller.text?.fontSize), size * 0.8, accuracy: 0.001, "\(size) pt")
            XCTAssertEqual(smaller.size.width, 160, accuracy: 0.001)
            XCTAssertEqual(smaller.size.height, try XCTUnwrap(smaller.text?.height(width: smaller.size.width)))
            XCTAssertLessThan(smaller.size.height, placed.size.height)
            XCTAssertEqual(smaller.center, placed.center)
        }
    }

    func testEveryKindOfBoxScalesWithItsType() throws {
        for (name, placed) in boxes {
            let type = try XCTUnwrap(placed.text?.fontSize)
            guard type * 0.8 >= TextBox.fontSizes.lowerBound, type * 1.25 <= TextBox.fontSizes.upperBound else { continue }
            for factor in [0.8, 1.25] as [CGFloat] {
                let scaled = placed.scaled(by: factor, limit: limit)
                XCTAssertEqual(try XCTUnwrap(scaled.text?.fontSize), type * factor, accuracy: 0.001, "\(name) by \(factor)")
                XCTAssertEqual(scaled.size.width, placed.size.width * factor, accuracy: 0.001, "\(name) by \(factor)")
                XCTAssertEqual(scaled.size.height, try XCTUnwrap(scaled.text?.height(width: scaled.size.width)), "\(name) by \(factor)")
                XCTAssertEqual(scaled.rotation, placed.rotation)
                XCTAssertEqual(scaled.center, placed.center)
                let saved = try XCTUnwrap(PageItem(json: scaled.json))
                XCTAssertEqual(saved.size, scaled.size, "\(name): saved and read again, it isn't fitted to another size")
                XCTAssertEqual(saved.text, scaled.text)
            }
        }
    }

    func testScalingStopsAtTheSmallestAndLargestTypeAndStaysThere() throws {
        let placed = item(box())
        let smallest = placed.scaled(by: 0.01, limit: limit)
        XCTAssertEqual(smallest.text?.fontSize, TextBox.fontSizes.lowerBound)
        XCTAssertEqual(smallest.size.width, 200 * 8 / 17, accuracy: 0.001, "the box stops with its type and keeps its proportions")
        XCTAssertEqual(smallest.size.height, try XCTUnwrap(smallest.text?.height(width: smallest.size.width)))
        XCTAssertEqual(smallest.scaled(by: 0.5, limit: limit), smallest, "a drag past the smallest type leaves it there")
        XCTAssertEqual(try XCTUnwrap(smallest.scaled(by: 2, limit: limit).text?.fontSize), 16, accuracy: 0.001, "and it grows again from there")

        let largest = placed.scaled(by: 1000, limit: 100_000)
        XCTAssertEqual(largest.text?.fontSize, TextBox.fontSizes.upperBound)
        XCTAssertEqual(largest.size.width, 200 * 200 / 17, accuracy: 0.001)
        XCTAssertEqual(largest.scaled(by: 2, limit: 100_000), largest, "a drag past the largest type leaves it there")
        XCTAssertEqual(try XCTUnwrap(largest.scaled(by: 0.5, limit: 100_000).text?.fontSize), 100, accuracy: 0.001)
    }

    func testScalingStopsAtTheNarrowestWidthAndThePagesLimit() throws {
        let narrow = item(box("Phenolphthalein", size: 34), width: 60)
        let narrowest = narrow.scaled(by: 0.1, limit: limit)
        XCTAssertEqual(narrowest.size.width, PageItem.minimumWidth, accuracy: 0.001, "no narrower than the width grip makes it")
        XCTAssertEqual(try XCTUnwrap(narrowest.text?.fontSize), 34 * PageItem.minimumWidth / 60, accuracy: 0.001)
        XCTAssertEqual(ItemSelectionView.stretched(narrowest, side: .right, by: 0, limit: widest).size.width, narrowest.size.width, accuracy: 0.001)

        let wide = item(box(), width: 600)
        let widened = wide.scaled(by: 10, limit: limit)
        XCTAssertEqual(widened.size.width, limit, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(widened.text?.fontSize), 17 * limit / 600, accuracy: 0.001)
        XCTAssertEqual(widened.scaled(by: 2, limit: limit).size, widened.size)
    }

    func testTheWidthGripStopsAtItsLimitsAndNeverMovesABoxAlreadyPastThem() {
        let placed = item(box())
        let narrowest = ItemSelectionView.stretched(placed, side: .right, by: -1000, limit: widest)
        XCTAssertEqual(narrowest.size.width, PageItem.minimumWidth)
        XCTAssertEqual(ItemSelectionView.stretched(narrowest, side: .right, by: -50, limit: widest), narrowest, "it stays at the narrowest")
        let widened = ItemSelectionView.stretched(placed, side: .right, by: 5000, limit: widest)
        XCTAssertEqual(widened.size.width, widest)
        XCTAssertEqual(ItemSelectionView.stretched(widened, side: .right, by: 50, limit: widest), widened, "and at the widest")

        let slim = item(box("Phenolphthalein"), width: 30)
        XCTAssertEqual(ItemSelectionView.stretched(slim, side: .right, by: -10, limit: widest), slim, "a box narrower than the grip allows isn't widened by a drag inwards")
        XCTAssertEqual(ItemSelectionView.stretched(slim, side: .right, by: 20, limit: widest).size.width, 50)
        let broad = item(box(), width: 1000)
        XCTAssertEqual(ItemSelectionView.stretched(broad, side: .right, by: 50, limit: widest), broad, "nor a wider one narrowed by a drag outwards")
        XCTAssertEqual(ItemSelectionView.stretched(broad, side: .right, by: -100, limit: widest).size.width, 900)
        let tape = PageItem(content: .tape(.mustard), center: CGPoint(x: 300, y: 300), size: CGSize(width: 30, height: 30))
        XCTAssertEqual(ItemSelectionView.stretched(tape, side: .right, by: -10, limit: widest), tape, "tape keeps the same rule")
    }

    func testTheOutlineGoesBackRoundAFormulaWhenTypingEndsWithNothingChanged() async throws {
        let placed = item(box("$$\\frac{a}{b}$$"))
        var sheet = paper.newPage()
        sheet.items = [placed]
        let root = temporaryRoot(self), manifest = NotebookManifest(title: "Lab", defaults: paper, pages: [sheet])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let session = EditorSession(document: document), controller = PageStackController(session: session)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where controller.canvas(forPage: 0)?.isLoaded != true { try? await Task.sleep(for: .seconds(0.05)) }

        controller.select(ItemSelection(pageID: document.pages[0].id, itemID: placed.id))
        let outline = try XCTUnwrap(window.descendants(ItemSelectionView.self).first)
        XCTAssertEqual(outline.item.size, placed.size)
        controller.editText()
        let textView = try XCTUnwrap(window.descendants(UITextView.self).first { $0.accessibilityIdentifier == "page.text.editor" })
        XCTAssertLessThan(outline.item.size.height, placed.size.height, "typed, the fraction is one line of its source")
        XCTAssertFalse(outline.isUserInteractionEnabled, "and while it is typed in, its handles take no drags")
        controller.textViewDidEndEditing(textView)
        XCTAssertEqual(document.pages[0].items.first?.size, placed.size)
        XCTAssertEqual(outline.item.size, placed.size, "the outline is round the box as the page holds it")
        XCTAssertEqual(outline.item.center, placed.center, "so the next drag starts from where the box is")
        XCTAssertTrue(outline.isUserInteractionEnabled)
    }

    func testVoiceOversStepsMakeAOneLineBoxSmallerAndStopAtTheSmallestType() throws {
        let placed = item(box())
        let smaller = placed.stepped(larger: false, page: page)
        XCTAssertEqual(try XCTUnwrap(smaller.text?.fontSize), 17 / ItemStep.growth, accuracy: 0.001)
        XCTAssertEqual(smaller.size.width, 200 / ItemStep.growth, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(smaller.stepped(larger: true, page: page).text?.fontSize), 17, accuracy: 0.001, "a step up undoes a step down")

        let smallest = item(box(size: 8))
        XCTAssertEqual(smallest.stepped(larger: false, page: page), smallest)
        XCTAssertEqual(ItemStep.resize(larger: false).applied(to: smallest, page: page), smallest, "so VoiceOver has nothing to announce")
        let largest = item(box(size: 200), width: 400)
        XCTAssertEqual(largest.stepped(larger: true, page: page), largest)
    }
}

private extension UIView {
    func descendants<View: UIView>(_ type: View.Type) -> [View] {
        subviews.flatMap { ($0 as? View).map { [$0] } ?? [] + $0.descendants(type) }
    }
}
