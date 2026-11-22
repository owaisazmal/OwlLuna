import XCTest
import UIKit
@testable import OwlLuna

/// The handles of a selected item: where they stand, that they stay on the page, and what a drag or a step on each does.
@MainActor
final class ItemHandleTests: XCTestCase {
    private let page = CGSize(width: 612, height: 792)
    private var limit: CGFloat { max(page.width, page.height) * 1.5 }

    private func text(at centre: CGPoint = CGPoint(x: 300, y: 400), width: CGFloat = 200, turned: CGFloat = 0) -> PageItem {
        let box = TextBox(string: "Eggs")
        return PageItem(content: .text(box), center: centre, size: CGSize(width: width, height: box.height(width: width)), rotation: turned)
    }

    private func picture(at centre: CGPoint = CGPoint(x: 300, y: 400), size: CGSize = CGSize(width: 240, height: 160), turned: CGFloat = 0) -> PageItem {
        PageItem(content: .image(file: "leaf.png"), center: centre, size: size, rotation: turned)
    }

    private func tape(at centre: CGPoint) -> PageItem {
        PageItem(content: .tape(.mustard), center: centre, size: CGSize(width: 200, height: 30))
    }

    /// Every handle an item shows, by name, where its middle stands on the page in screen points.
    private func handles(of item: PageItem, scale: CGFloat = 1, covered: CGFloat = 0) -> [(name: String, point: CGPoint)] {
        let layout = ItemHandleLayout(item: item, page: page, scale: scale, covered: covered)
        var all = [("corner", layout.onPage(layout.corner))]
        if item.text != nil { all.append(("knob", layout.onPage(layout.knob.center))) }
        let sides: [ItemSelectionView.Side] = item.text != nil || item.tape != nil ? [.right] : item.assetFile != nil ? ItemSelectionView.Side.allCases : []
        return all + sides.map { ("\($0) grip", layout.onPage(layout.grip($0))) }
    }

    private func assertOnThePage(_ item: PageItem, scale: CGFloat = 1, covered: CGFloat = 0, _ what: String, line: UInt = #line) {
        let margin = ItemHandleLayout.margin - 0.02
        let room = CGRect(x: margin, y: margin, width: page.width * scale - margin * 2, height: page.height * scale - margin * 2)
        for handle in handles(of: item, scale: scale, covered: covered) {
            XCTAssertTrue(room.contains(handle.point), "\(what): the \(handle.name) is at \(handle.point)", line: line)
        }
    }

    private func assertAt(_ point: CGPoint, _ x: CGFloat, _ y: CGFloat, _ what: String, line: UInt = #line) {
        XCTAssertEqual(point.x, x, accuracy: 0.01, what, line: line)
        XCTAssertEqual(point.y, y, accuracy: 0.01, what, line: line)
    }

    // MARK: Where they stand

    func testWithRoomEveryHandleStandsAtItsOwnPlace() {
        let box = text(), layout = ItemHandleLayout(item: box, page: page, scale: 1)
        XCTAssertEqual(box.size.height, 21)
        assertAt(layout.onPage(layout.corner), 196, 414.5, "the tab is on the outline's lower left corner")
        assertAt(layout.onPage(layout.grip(.right)), 404, 400, "the width grip is on the middle of the right side")
        assertAt(layout.onPage(layout.knob.center), 300, 389.5 - ItemHandleLayout.rise, "the knob stands off the middle of the top")
        assertAt(layout.onPage(layout.knob.foot), 300, 385.5, "and its stalk leaves the outline there")

        let leaf = picture(), framed = ItemHandleLayout(item: leaf, page: page, scale: 1)
        assertAt(framed.onPage(framed.corner), 424, 484, "a picture's knob is on its lower right corner")
        assertAt(framed.onPage(framed.grip(.top)), 300, 316, "and a grip on each side")
        assertAt(framed.onPage(framed.grip(.left)), 176, 400, "")

        let zoomed = ItemHandleLayout(item: box, page: page, scale: 2)
        assertAt(zoomed.onPage(zoomed.corner), 396, 825, "zoomed in, the handles keep their distance from the box on the screen")
        assertAt(zoomed.onPage(zoomed.knob.center), 600, 779 - ItemHandleLayout.rise, "")

        let turned = text(turned: .pi / 2), quarter = ItemHandleLayout(item: turned, page: page, scale: 1)
        assertAt(quarter.onPage(quarter.corner), 285.5, 296, "turned a quarter, the handles turn with the box")
        assertAt(quarter.onPage(quarter.knob.center), 310.5 + ItemHandleLayout.rise, 400, "")
    }

    func testAHandlePastThePagesEdgeSlidesAlongItsSideToStayOnThePage() {
        let margin = ItemHandleLayout.margin
        let left = ItemHandleLayout(item: text(at: CGPoint(x: 0, y: 400)), page: page, scale: 1)
        assertAt(left.onPage(left.corner), margin, 414.5, "off the left edge, the tab slides along the foot of the box")
        assertAt(left.onPage(left.knob.center), margin, 389.5 - ItemHandleLayout.rise, "and the knob along its top")
        assertAt(left.onPage(left.knob.foot), margin, 385.5, "")
        assertAt(left.onPage(left.grip(.right)), 104, 400, "the grip still on the page stays where it was")

        let right = ItemHandleLayout(item: text(at: CGPoint(x: 612, y: 400)), page: page, scale: 1)
        assertAt(right.onPage(right.grip(.right)), page.width - margin, 400, "with all of its side off the page, the grip stands at the page's edge")
        assertAt(right.onPage(right.corner), 508, 414.5, "")

        let top = ItemHandleLayout(item: text(at: CGPoint(x: 300, y: 0)), page: page, scale: 1)
        assertAt(top.onPage(top.knob.center), 300, 10.5 + ItemHandleLayout.rise, "with no room over the box, the knob stands under it")
        assertAt(top.onPage(top.grip(.right)), 404, margin, "and the grip slides down its side")

        let foot = ItemHandleLayout(item: text(at: CGPoint(x: 300, y: 792)), page: page, scale: 1)
        assertAt(foot.onPage(foot.corner), 196, page.height - margin, "off the foot of the page, the tab slides up the box's side")
        assertAt(foot.onPage(foot.knob.center), 300, 781.5 - ItemHandleLayout.rise, "")

        let leaf = ItemHandleLayout(item: picture(at: CGPoint(x: 612, y: 792)), page: page, scale: 1)
        assertAt(leaf.onPage(leaf.corner), page.width - margin, page.height - margin, "a picture's knob with both its sides off the page stands in the page's corner")
        assertAt(leaf.onPage(leaf.grip(.top)), page.width - margin, 708, "and a grip slides along its side to the page's edge")
    }

    func testEveryHandleStaysOnThePageWhereverTheBoxHangsOff() {
        let places = [CGPoint(x: 0, y: 400), CGPoint(x: 612, y: 400), CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 792),
                      CGPoint(x: 0, y: 0), CGPoint(x: 612, y: 0), CGPoint(x: 0, y: 792), CGPoint(x: 612, y: 792), CGPoint(x: 300, y: 400)]
        for place in places {
            for scale in [0.6, 1, 1.4, 3] as [CGFloat] {
                for turn in [0, .pi / 6, .pi / 2, .pi, -.pi / 3] as [CGFloat] {
                    let what = "at \(place), turned \(turn), scale \(scale)"
                    assertOnThePage(text(at: place, turned: turn), scale: scale, "a text box \(what)")
                    assertOnThePage(text(at: place, width: 612, turned: turn), scale: scale, "a text box as wide as the page \(what)")
                    assertOnThePage(text(at: place, width: 900, turned: turn), scale: scale, covered: 48, "a wider one under the bars \(what)")
                    assertOnThePage(picture(at: place, turned: turn), scale: scale, "a picture \(what)")
                    assertOnThePage(picture(at: place, size: CGSize(width: 700, height: 900), turned: turn), scale: scale, "a picture larger than the page \(what)")
                }
                assertOnThePage(tape(at: place), scale: scale, "tape at \(place)")
            }
        }
    }

    func testABoxAsWideAsThePageKeepsAHandleAtEachEnd() {
        let margin = ItemHandleLayout.margin
        for width in [612, 900] as [CGFloat] {
            let layout = ItemHandleLayout(item: text(at: CGPoint(x: 306, y: 400), width: width), page: page, scale: 1)
            assertAt(layout.onPage(layout.corner), margin, 414.5, "\(width) pt wide: the tab at the page's left edge")
            assertAt(layout.onPage(layout.grip(.right)), page.width - margin, 400, "the grip at its right")
            assertAt(layout.onPage(layout.knob.center), 306, 389.5 - ItemHandleLayout.rise, "the knob over the middle")
        }
    }

    func testTheKnobKeepsClearOfTheBarsOverTheTopOfThePage() {
        let covered: CGFloat = 48
        // The ribbons hang at the right of the page's top, or at its left for a left hand, and the bar between them.
        for x in [80, 306, 540] as [CGFloat] {
            let high = ItemHandleLayout(item: text(at: CGPoint(x: x, y: 80)), page: page, scale: 1, covered: covered)
            assertAt(high.onPage(high.knob.center), x, 90.5 + ItemHandleLayout.rise, "under the bars at \(x), the knob stands below the box")
            let lower = ItemHandleLayout(item: text(at: CGPoint(x: x, y: 120)), page: page, scale: 1, covered: covered)
            assertAt(lower.onPage(lower.knob.center), x, 109.5 - ItemHandleLayout.rise, "clear of them, above it")
        }
        let free = ItemHandleLayout(item: text(at: CGPoint(x: 306, y: 80)), page: page, scale: 1)
        assertAt(free.onPage(free.knob.center), 306, 69.5 - ItemHandleLayout.rise, "a page further down has nothing over its top")
    }

    // MARK: What a drag does

    private func change(_ hold: ItemSelectionView.Hold, of item: PageItem, from start: CGPoint, by moved: CGPoint) -> PageItem {
        let change = ItemSelectionView.change(dragging: hold, of: item, from: start, to: CGPoint(x: start.x + moved.x, y: start.y + moved.y),
                                              rise: ItemHandleLayout.rise)
        return ItemSelectionView.arranged(item, pinch: change.pinch, twist: change.twist, limit: limit)
    }

    private let drags = [CGPoint(x: 0, y: 60), CGPoint(x: 0, y: -60), CGPoint(x: 60, y: 0), CGPoint(x: -60, y: 0), CGPoint(x: -40, y: 40), CGPoint(x: 50, y: -20)]

    func testADragOnTheTabResizesAndNeverTurns() throws {
        for turn in [0, 0.4, .pi / 2, 0.02] as [CGFloat] {
            let box = text(turned: turn), corner = CGPoint(x: 300 - 100 * cos(turn) - 10.5 * sin(turn), y: 400 - 100 * sin(turn) + 10.5 * cos(turn))
            for drag in drags {
                let dragged = change(.resize, of: box, from: corner, by: drag)
                XCTAssertEqual(dragged.rotation, turn, "turned \(turn), dragged by \(drag)")
                XCTAssertEqual(dragged.center, box.center)
            }
            let out = CGPoint(x: (corner.x - 300) / 2, y: (corner.y - 400) / 2)
            XCTAssertEqual(change(.resize, of: box, from: corner, by: out).size.width, 300, accuracy: 0.01, "half as far out again from the middle, half as large again")
            XCTAssertEqual(try XCTUnwrap(change(.resize, of: box, from: corner, by: out).text?.fontSize), 25.5, accuracy: 0.01)
            XCTAssertEqual(change(.resize, of: box, from: corner, by: CGPoint(x: -out.x, y: -out.y)).size.width, 100, accuracy: 0.01)
        }
        let down = change(.resize, of: text(), from: CGPoint(x: 200, y: 410.5), by: CGPoint(x: 0, y: 60))
        XCTAssertEqual(down.rotation, 0, "a drag straight down, meant for the height, tilts nothing")
        XCTAssertEqual(down.size.width, 200, accuracy: 15, "and is a small change of size")
    }

    func testADragOnTheKnobTurnsAndNeverResizes() {
        let box = text(), reach = box.size.height / 2 + ItemHandleLayout.rise, home = CGPoint(x: 300, y: 400 - reach)
        for drag in drags {
            let turned = change(.turn, of: box, from: home, by: drag)
            XCTAssertEqual(turned.size, box.size, "dragged by \(drag)")
            XCTAssertEqual(turned.text, box.text)
            XCTAssertEqual(turned.center, box.center)
        }
        XCTAssertEqual(change(.turn, of: box, from: home, by: CGPoint(x: reach, y: 0)).rotation, .pi / 4, accuracy: 0.001, "as far across as it stands off the middle is an eighth of a turn")
        XCTAssertEqual(change(.turn, of: box, from: home, by: CGPoint(x: -reach, y: 0)).rotation, -.pi / 4, accuracy: 0.001)
        XCTAssertEqual(change(.turn, of: box, from: home, by: CGPoint(x: reach, y: reach * 0.97)).rotation, .pi / 2, "it settles on a quarter turn")
        XCTAssertEqual(change(.turn, of: text(turned: .pi / 2), from: CGPoint(x: 300 + reach, y: 400), by: CGPoint(x: 0, y: reach)).rotation, .pi * 3 / 4, accuracy: 0.001)
    }

    func testAHandleThatHasSlidInIsNoQuickerThanAtItsOwnPlace() {
        let box = text(), corner = CGPoint(x: 200, y: 410.5), nearMiddle = CGPoint(x: 296, y: 414.5)
        for drag in drags {
            XCTAssertEqual(change(.resize, of: box, from: nearMiddle, by: drag), change(.resize, of: box, from: corner, by: drag), "the tab, dragged by \(drag)")
        }
        let leaf = picture()
        for drag in drags {
            XCTAssertEqual(change(.both, of: leaf, from: CGPoint(x: 304, y: 484), by: drag), change(.both, of: leaf, from: CGPoint(x: 420, y: 480), by: drag),
                           "a picture's knob, dragged by \(drag)")
        }
        let reach = box.size.height / 2 + ItemHandleLayout.rise
        let far = change(.turn, of: box, from: CGPoint(x: 300, y: 400 - reach), by: CGPoint(x: 10, y: 0)).rotation
        let near = change(.turn, of: box, from: CGPoint(x: 300, y: 396), by: CGPoint(x: 10, y: 0)).rotation
        XCTAssertEqual(near, far, accuracy: 0.001, "the knob held close to the box's middle turns it as it would from its stalk")
        XCTAssertEqual(change(.turn, of: box, from: box.center, by: CGPoint(x: 10, y: 0)).rotation, far, accuracy: 0.001, "even on the middle itself")
    }

    func testAPicturesOneKnobStillResizesAndTurns() {
        let leaf = picture(), corner = CGPoint(x: 420, y: 480)
        let larger = change(.both, of: leaf, from: corner, by: CGPoint(x: 60, y: 40))
        XCTAssertEqual(larger.size.width, 360, accuracy: 0.01)
        XCTAssertEqual(larger.size.height, 240, accuracy: 0.01)
        XCTAssertEqual(larger.rotation, 0)
        let turned = change(.both, of: leaf, from: corner, by: CGPoint(x: -80, y: 120))
        XCTAssertEqual(turned.rotation, atan2(200, 40) - atan2(80, 120), accuracy: 0.001)
        XCTAssertEqual(turned.size.width / turned.size.height, 1.5, accuracy: 0.001)
    }

    // MARK: On the selection

    private func handle(_ label: String, on selection: ItemSelectionView) -> UIView? {
        selection.subviews.first { $0.accessibilityLabel == label && !$0.isHidden }
    }

    /// The outline round an item in a slot the size of the page, taking each change it reports as the page stack does.
    private func selection(of item: PageItem, scale: CGFloat = 1) -> (ItemSelectionView, UIView) {
        let slot = UIView(frame: CGRect(origin: .zero, size: page))
        let selection = ItemSelectionView(item: item, pageSize: page)
        selection.scale = scale
        slot.addSubview(selection)
        selection.onChange = { [weak selection] changed, _ in selection?.show(changed) }
        selection.show(item)
        return (selection, slot)
    }

    func testATextBoxHasATabAKnobAndItsWidthGrip() throws {
        let (outline, slot) = selection(of: text())
        let tab = try XCTUnwrap(handle("Resize", on: outline)), knob = try XCTUnwrap(handle("Rotate", on: outline))
        let grip = try XCTUnwrap(handle("Change width", on: outline))
        XCTAssertNil(handle("Resize and rotate", on: outline), "the one knob has become two handles")
        XCTAssertEqual(knob.accessibilityIdentifier, "page.knob")
        for view in [tab, knob, grip] {
            XCTAssertEqual(view.bounds.size, CGSize(width: 44, height: 44), "a fingertip's room round \(view.accessibilityLabel ?? "")")
            XCTAssertTrue(view.accessibilityTraits.contains(.adjustable))
        }
        XCTAssertEqual(tab.subviews.first?.bounds.size, CGSize(width: Grip.tab, height: Grip.tab), "a square tab, as on the lasso's box")
        XCTAssertEqual(knob.subviews.first?.bounds.size, CGSize(width: Grip.knob, height: Grip.knob))
        XCTAssertEqual(tab.accessibilityValue, "200 by 21 pt")
        XCTAssertEqual(knob.accessibilityValue, "Upright")
        assertAt(slot.convert(tab.center, from: outline), 196, 414.5, "")
        assertAt(slot.convert(knob.center, from: outline), 300, 389.5 - ItemHandleLayout.rise, "")
        XCTAssertTrue(outline.hitTest(knob.center, with: nil) === knob, "the knob off the outline takes its own touches")
        XCTAssertTrue(outline.hitTest(tab.center, with: nil) === tab)
        XCTAssertTrue(outline.hitTest(CGPoint(x: outline.bounds.midX, y: outline.bounds.midY), with: nil) === outline, "the box itself is moved")

        tab.accessibilityIncrement()
        XCTAssertEqual(outline.item.size.width, 220, accuracy: 0.01, "a step on the tab is a tenth larger")
        XCTAssertEqual(outline.item.rotation, 0)
        XCTAssertEqual(handle("Resize", on: outline)?.accessibilityValue, "220 by 23 pt")
        knob.accessibilityIncrement()
        XCTAssertEqual(outline.item.rotation, .pi / 12, accuracy: 1e-9, "a step on the knob is fifteen degrees round")
        XCTAssertEqual(outline.item.size.width, 220, accuracy: 0.01)
        XCTAssertEqual(handle("Rotate", on: outline)?.accessibilityValue, "Turned 15° right")
        XCTAssertEqual(handle("Resize", on: outline)?.accessibilityValue, "220 by 23 pt", "the tab says the size alone")
        knob.accessibilityDecrement()
        XCTAssertEqual(outline.item.rotation, 0)

        outline.isEditing = true
        XCTAssertNil(handle("Resize", on: outline), "while the box is typed in the handles step aside")
        XCTAssertNil(handle("Rotate", on: outline))
    }

    func testAPictureAStickerAndTapeKeepTheirOneKnob() throws {
        let star = PageItem(content: .sticker("star"), center: CGPoint(x: 300, y: 400), size: CGSize(width: 100, height: 100))
        for item in [picture(), star, tape(at: CGPoint(x: 300, y: 400))] {
            let (outline, _) = selection(of: item)
            XCTAssertNotNil(handle("Resize and rotate", on: outline))
            XCTAssertNil(handle("Resize", on: outline))
            XCTAssertNil(handle("Rotate", on: outline))
        }
        let (outline, _) = selection(of: text())
        outline.show(star)
        XCTAssertNotNil(handle("Resize and rotate", on: outline), "the same outline round another item changes its handles")
        XCTAssertNil(handle("Rotate", on: outline))
    }

    func testOnASmallBoxTheNearerHandleTakesTheTouch() throws {
        let (outline, _) = selection(of: text(width: 40), scale: 0.5)
        let tab = try XCTUnwrap(handle("Resize", on: outline)), grip = try XCTUnwrap(handle("Change width", on: outline))
        XCTAssertTrue(tab.frame.intersects(grip.frame), "their fingertip rooms overlap")
        XCTAssertTrue(outline.hitTest(CGPoint(x: tab.center.x + 6, y: tab.center.y - 2), with: nil) === tab)
        XCTAssertTrue(outline.hitTest(CGPoint(x: grip.center.x - 6, y: grip.center.y + 2), with: nil) === grip)
    }

    func testOnTheFirstPageTheKnobStandsBelowABoxTheBarsWouldCover() async throws {
        let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
        let high = text(at: CGPoint(x: 300, y: 60)), low = text(at: CGPoint(x: 300, y: 400))
        var sheet = paper.newPage()
        sheet.items = [high, low]
        let root = temporaryRoot(self), manifest = NotebookManifest(title: "Lab", defaults: paper, pages: [sheet])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let session = EditorSession(document: document), controller = PageStackController(session: session)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        // Shorter than the page, so the page starts under the bar as it does on an iPad held upright.
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 800)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where controller.canvas(forPage: 0)?.isLoaded != true { try? await Task.sleep(for: .seconds(0.05)) }
        func outline(_ view: UIView) -> ItemSelectionView? { view as? ItemSelectionView ?? view.subviews.lazy.compactMap(outline).first }

        controller.select(ItemSelection(pageID: document.pages[0].id, itemID: high.id))
        let selection = try XCTUnwrap(outline(window))
        XCTAssertGreaterThan(selection.covered, 0, "the bar for a selected item and the ribbons lie over the top of the first page")
        XCTAssertGreaterThan(try XCTUnwrap(handle("Rotate", on: selection)).center.y, selection.bounds.maxY, "so the knob stands under the box")
        controller.select(ItemSelection(pageID: document.pages[0].id, itemID: low.id))
        XCTAssertLessThan(try XCTUnwrap(handle("Rotate", on: selection)).center.y, 0, "further down the page it stands over it")
    }
}
