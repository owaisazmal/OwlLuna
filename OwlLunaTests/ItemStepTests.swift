import XCTest
import PencilKit
@testable import OwlLuna

/// Moving, turning and resizing a selected item a step at a time, from VoiceOver and the keyboard.
@MainActor
final class ItemStepTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
    private let page = CGSize(width: 612, height: 792)

    private func sticker(_ size: CGSize = CGSize(width: 200, height: 100), at center: CGPoint = CGPoint(x: 300, y: 400), rotation: CGFloat = 0) -> PageItem {
        PageItem(content: .sticker(Sticker.star.rawValue), center: center, size: size, rotation: rotation)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func testTheHandleMakesItATenthLargerOrSmallerInTheSameShape() {
        let placed = sticker()
        let larger = placed.stepped(larger: true, page: page)
        XCTAssertEqual(larger.size.width, 220, accuracy: 0.001)
        XCTAssertEqual(larger.size.height, 110, accuracy: 0.001)
        XCTAssertEqual(larger.center, placed.center)
        let back = larger.stepped(larger: false, page: page)
        XCTAssertEqual(back.size.width, 200, accuracy: 0.001)
        XCTAssertEqual(back.size.height, 100, accuracy: 0.001)
        let tiny = sticker(CGSize(width: 48, height: PageItem.minimumSide))
        XCTAssertEqual(tiny.stepped(larger: false, page: page), tiny, "no smaller than a fingertip can grab")
    }

    func testItGrowsNoLargerThanThePageAndNoFurtherOffIt() {
        let wide = sticker(CGSize(width: 600, height: 300), at: CGPoint(x: 306, y: 396))
        let filled = wide.stepped(larger: true, page: page)
        XCTAssertEqual(filled.size.width, 612, accuracy: 0.001, "the last step fills the page's width")
        XCTAssertEqual(filled.stepped(larger: true, page: page), filled)

        let byTheEdge = sticker(CGSize(width: 100, height: 100), at: CGPoint(x: 560, y: 400))
        let grown = byTheEdge.stepped(larger: true, page: page)
        XCTAssertEqual(grown.size.width, 110, accuracy: 0.001)
        XCTAssertEqual(grown.boundingBox.maxX, 612, accuracy: 0.001, "moved in so it stays on the page")

        let hanging = sticker(CGSize(width: 100, height: 100), at: CGPoint(x: 600, y: 400))
        XCTAssertEqual(hanging.stepped(larger: true, page: page).boundingBox.maxX, 650, accuracy: 0.001, "it hangs off no further than it did")

        let turned = sticker(CGSize(width: 700, height: 100), at: CGPoint(x: 306, y: 396), rotation: .pi / 2)
        XCTAssertEqual(turned.stepped(larger: true, page: page).size.width, 770, accuracy: 0.001, "turned, it is tall and still fits")
    }

    func testATextBoxsWordsGrowWithIt() {
        let box = TextBox(string: "Shopping\nEggs\nMilk")
        let text = PageItem(content: .text(box), center: CGPoint(x: 300, y: 200), size: CGSize(width: 200, height: box.height(width: 200)))
        let larger = text.stepped(larger: true, page: page)
        XCTAssertEqual(larger.size.width, 220, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(larger.text?.fontSize), box.fontSize * 1.1, accuracy: 0.001)
        XCTAssertEqual(larger.size.height, try XCTUnwrap(larger.text?.height(width: larger.size.width)), accuracy: 0.001)

        let line = TextBox(string: "Eggs")
        let short = PageItem(content: .text(line), center: CGPoint(x: 300, y: 200), size: CGSize(width: 200, height: line.height(width: 200)))
        XCTAssertLessThan(short.size.height, PageItem.minimumSide)
        XCTAssertEqual(short.stepped(larger: false, page: page), short, "a step down never makes it larger")
        XCTAssertGreaterThan(short.stepped(larger: true, page: page).size.width, 200)
    }

    func testTurningGoesToTheNextFifteenDegrees() {
        let upright = sticker()
        let right = upright.turned(clockwise: true)
        XCTAssertEqual(right.rotation, .pi / 12, accuracy: 1e-9)
        XCTAssertEqual(right.spokenTurn, "Turned 15° right")
        XCTAssertEqual(upright.turned(clockwise: false).turnedDegrees, -15)

        let askew = sticker(rotation: 0.2)
        XCTAssertEqual(askew.turned(clockwise: true).turnedDegrees, 15, "11° turns on to 15°")
        let straightened = askew.turned(clockwise: false)
        XCTAssertEqual(straightened.rotation, 0)
        XCTAssertEqual(straightened.spokenTurn, "Upright")

        let halfTurn = sticker(rotation: .pi).turned(clockwise: true)
        XCTAssertEqual(halfTurn.turnedDegrees, -165)
        XCTAssertEqual(halfTurn.spokenTurn, "Turned 165° left")
        XCTAssertLessThanOrEqual(abs(halfTurn.rotation), .pi, "kept within a half turn either way")
        XCTAssertEqual(sticker(rotation: .pi / 2 + 1e-9).turned(clockwise: true).turnedDegrees, 105)
    }

    func testMovingKeepsItsMiddleOnThePage() {
        XCTAssertEqual(sticker().moved(by: CGSize(width: 20, height: -1), page: page).center, CGPoint(x: 320, y: 399))
        XCTAssertEqual(sticker(at: CGPoint(x: 10, y: 10)).moved(by: CGSize(width: -20, height: -20), page: page).center, .zero)
        XCTAssertEqual(sticker(at: CGPoint(x: 600, y: 780)).moved(by: CGSize(width: 20, height: 20), page: page).center, CGPoint(x: 612, y: 792))
    }

    func testTheArrowKeysNudgeAPointOrTenWithShift() {
        XCTAssertEqual(ItemStep.nudge(UIKeyCommand.inputUpArrow, shift: false), CGSize(width: 0, height: -1))
        XCTAssertEqual(ItemStep.nudge(UIKeyCommand.inputDownArrow, shift: true), CGSize(width: 0, height: 10))
        XCTAssertEqual(ItemStep.nudge(UIKeyCommand.inputLeftArrow, shift: false), CGSize(width: -1, height: 0))
        XCTAssertEqual(ItemStep.nudge(UIKeyCommand.inputRightArrow, shift: true), CGSize(width: 10, height: 0))
        XCTAssertNil(ItemStep.nudge("a", shift: false))
    }

    func testWhatVoiceOverSays() {
        let placed = sticker(CGSize(width: 200.4, height: 99.6))
        XCTAssertEqual(placed.spokenSize, "200 by 100 pt")
        XCTAssertEqual(placed.spokenPlace, "200 pt from the left, 350 pt from the top")
        XCTAssertEqual(sticker(rotation: -.pi / 12).spokenSize, "200 by 100 pt, turned 15° left")
        XCTAssertEqual(sticker(rotation: .pi / 2).spokenSize, "200 by 100 pt, turned 90° right")
    }

    // MARK: In the editor

    private struct Editor {
        let document: NotebookDocument
        let controller: PageStackController
        let window: UIWindow
    }

    private func openEditor(items: [PageItem], ink: PKDrawing = PKDrawing()) async throws -> Editor {
        let root = temporaryRoot(self)
        var first = paper.newPage()
        first.items = items
        let manifest = NotebookManifest(title: "Steps", defaults: paper, pages: [first])
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: [first.id: ink]))
        let document = try await NotebookDocument.open(manifest.id, root: root)
        document.undoManager.groupsByEvent = false
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
        return Editor(document: document, controller: controller, window: window)
    }

    private func step(_ document: NotebookDocument, _ change: () throws -> Void) rethrows {
        document.undoManager.beginUndoGrouping()
        defer { document.undoManager.endUndoGrouping() }
        try change()
    }

    private func views(in window: UIWindow, where matches: (UIView) -> Bool) -> [UIView] {
        var views: [UIView] = [window], found: [UIView] = []
        while !views.isEmpty {
            let view = views.removeFirst()
            if matches(view) { found.append(view) }
            views += view.subviews
        }
        return found
    }

    private func press(_ input: String, shift: Bool = false, on controller: PageStackController) throws {
        let flags: UIKeyModifierFlags = shift ? .shift : []
        let command = try XCTUnwrap(controller.keyCommands?.first { $0.input == input && $0.modifierFlags == flags })
        _ = controller.perform(try XCTUnwrap(command.action), with: command)
    }

    func testVoiceOverAndTheArrowKeysArrangeTheSelectedItemOneUndoStepAtATime() async throws {
        let star = sticker(CGSize(width: 100, height: 100), at: CGPoint(x: 306, y: 396))
        let heart = PageItem(content: .sticker(Sticker.heart.rawValue), center: CGPoint(x: 150, y: 150), size: CGSize(width: 80, height: 80))
        let editor = try await openEditor(items: [star, heart])
        let document = editor.document, controller = editor.controller, pageID = document.pages[0].id
        func current() throws -> PageItem { try XCTUnwrap(document.pages[0].items.first { $0.id == star.id }) }
        func handle() throws -> UIView {
            try XCTUnwrap(views(in: editor.window) { $0.superview is ItemSelectionView && $0.accessibilityLabel == "Resize and rotate" && !$0.isHidden }.first)
        }
        func starView() throws -> PageItemView {
            try XCTUnwrap(views(in: editor.window) { ($0 as? PageItemView)?.item.id == star.id }.first as? PageItemView)
        }
        func action(_ name: String, on view: UIView) throws -> Bool {
            let action = try XCTUnwrap(view.accessibilityCustomActions?.first { $0.name == name }, name)
            return try XCTUnwrap(action.actionHandler)(action)
        }

        let original = try current()
        XCTAssertTrue(controller.keyCommands?.contains { $0.title == "Scroll Down" } ?? false)
        controller.select(ItemSelection(pageID: pageID, itemID: star.id))
        XCTAssertTrue(try handle().accessibilityTraits.contains(.adjustable))
        XCTAssertEqual(try handle().accessibilityValue, "100 by 100 pt")

        try step(document) { try handle().accessibilityIncrement() }
        XCTAssertEqual(document.undoManager.undoActionName, "Arrange")
        XCTAssertEqual(try current().size.width, 110, accuracy: 0.001)
        XCTAssertEqual(try current().size.height, 110, accuracy: 0.001)
        XCTAssertEqual(try handle().accessibilityValue, "110 by 110 pt", "VoiceOver hears the new size")

        let names = ["Move Up", "Move Down", "Move Left", "Move Right", "Rotate Left", "Rotate Right", "Bring Forward", "Send Backward"]
        XCTAssertEqual(try starView().accessibilityCustomActions?.map(\.name), names, "the selected item offers them")
        XCTAssertEqual(try handle().accessibilityCustomActions?.map(\.name), names)
        XCTAssertFalse(try action("Send Backward", on: starView()), "already at the back")
        try step(document) { XCTAssertTrue(try action("Move Down", on: starView())) }
        XCTAssertEqual(try current().center, CGPoint(x: 306, y: 416))
        try step(document) { XCTAssertTrue(try action("Rotate Right", on: handle())) }
        XCTAssertEqual(try current().turnedDegrees, 15)
        XCTAssertEqual(try handle().accessibilityValue, "110 by 110 pt, turned 15° right")
        try step(document) { XCTAssertTrue(try action("Bring Forward", on: starView())) }
        XCTAssertEqual(document.pages[0].items.map(\.id), [heart.id, star.id])
        XCTAssertEqual(document.undoManager.undoActionName, "Bring Forward")

        XCTAssertFalse(controller.keyCommands?.contains { $0.title == "Scroll Down" } ?? true, "the arrows move the item, not the page")
        try step(document) { try press(UIKeyCommand.inputRightArrow, on: controller) }
        try step(document) { try press(UIKeyCommand.inputUpArrow, shift: true, on: controller) }
        XCTAssertEqual(try current().center, CGPoint(x: 307, y: 406))
        XCTAssertEqual(document.undoManager.undoActionName, "Arrange")

        document.undoManager.undo()
        XCTAssertEqual(try current().center, CGPoint(x: 307, y: 416))
        document.undoManager.undo()
        XCTAssertEqual(try current().center, CGPoint(x: 306, y: 416))
        document.undoManager.undo()
        XCTAssertEqual(document.pages[0].items.map(\.id), [star.id, heart.id])
        document.undoManager.undo()
        XCTAssertEqual(try current().rotation, 0)
        document.undoManager.undo()
        XCTAssertEqual(try current().center, star.center)
        document.undoManager.undo()
        XCTAssertEqual(try current(), original, "six steps, six undos")

        controller.select(nil)
        XCTAssertTrue(try starView().accessibilityCustomActions?.isEmpty ?? true, "put down, it gives them up")
        XCTAssertTrue(controller.keyCommands?.contains { $0.title == "Scroll Down" } ?? false)
    }

    func testTheWidthGripAndTapeOfferWhatSuitsThem() async throws {
        let box = TextBox(string: "Notes")
        let text = PageItem(content: .text(box), center: CGPoint(x: 306, y: 200), size: CGSize(width: 200, height: box.height(width: 200)))
        let tape = PageItem(content: .tape(.mustard), center: CGPoint(x: 306, y: 500), size: CGSize(width: 200, height: 40))
        let editor = try await openEditor(items: [text, tape])
        let document = editor.document, pageID = document.pages[0].id
        func element(_ label: String) throws -> UIView {
            try XCTUnwrap(views(in: editor.window) { $0.superview is ItemSelectionView && $0.accessibilityLabel == label && !$0.isHidden }.first, label)
        }

        editor.controller.select(ItemSelection(pageID: pageID, itemID: text.id))
        XCTAssertEqual(try element("Change width").accessibilityValue, "200 pt")
        try step(document) { try element("Change width").accessibilityIncrement() }
        XCTAssertEqual(try XCTUnwrap(document.pages[0].items.first?.size.width), 220, accuracy: 0.001)
        XCTAssertEqual(try element("Change width").accessibilityValue, "220 pt", "VoiceOver hears the new width")
        document.undoManager.undo()
        XCTAssertEqual(document.pages[0].items.first?.size.width, 200)

        editor.controller.select(ItemSelection(pageID: pageID, itemID: tape.id))
        XCTAssertEqual(try element("Resize and rotate").accessibilityCustomActions?.map(\.name),
                       ["Move Up", "Move Down", "Move Left", "Move Right", "Rotate Left", "Rotate Right"], "tape always lies over the ink")
    }

    func testTheArrowsNeverLeaveATextBoxBeingTypedIn() async throws {
        let box = TextBox(string: "Notes")
        let text = PageItem(content: .text(box), center: CGPoint(x: 306, y: 200), size: CGSize(width: 200, height: box.height(width: 200)))
        let editor = try await openEditor(items: [text])
        editor.controller.select(ItemSelection(pageID: editor.document.pages[0].id, itemID: text.id))
        XCTAssertTrue(editor.controller.keyCommands?.contains { $0.input == UIKeyCommand.inputLeftArrow } ?? false)
        editor.controller.editText()
        let arrows = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow]
        XCTAssertFalse(editor.controller.keyCommands?.contains { arrows.contains($0.input ?? "") } ?? true)
    }

    func testTheArrowsNudgeLassoedInkOneUndoStepAPress() async throws {
        let editor = try await openEditor(items: [], ink: PKDrawing(strokes: [stroke(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100))]))
        let document = editor.document, controller = editor.controller, pageID = document.pages[0].id
        func left() throws -> CGFloat { try XCTUnwrap(document.loadedInk(pageID)?.bounds.minX) }
        let start = try left()
        controller.setSelectingInk(true)
        XCTAssertTrue(controller.keyCommands?.contains { $0.title == "Scroll Down" } ?? false, "nothing caught yet")
        controller.catchInk(inside: [CGPoint(x: -5000, y: -5000), CGPoint(x: 5000, y: -5000), CGPoint(x: 5000, y: 5000), CGPoint(x: -5000, y: 5000)])
        try step(document) { try press(UIKeyCommand.inputRightArrow, shift: true, on: controller) }
        XCTAssertEqual(document.undoManager.undoActionName, "Move Ink")
        try step(document) { try press(UIKeyCommand.inputLeftArrow, on: controller) }
        XCTAssertEqual(try left(), start + 9, accuracy: 0.01)
        document.undoManager.undo()
        XCTAssertEqual(try left(), start + 10, accuracy: 0.01)
        document.undoManager.undo()
        XCTAssertEqual(try left(), start, accuracy: 0.01)
    }
}
