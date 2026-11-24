import XCTest
@testable import OwlLuna

/// A text box's size stepped a point at a time, and a run of changes to its style kept as one undo step.
@MainActor
final class TextSizeRunTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)

    private func openBox(size: CGFloat = 17) async throws -> (session: EditorSession, document: NotebookDocument) {
        let root = temporaryRoot(self)
        var box = TextBox(string: "Mitochondria")
        box.fontSize = size
        let item = PageItem(content: .text(box), center: CGPoint(x: 300, y: 300), size: CGSize(width: 200, height: box.height(width: 200)))
        var page = paper.newPage()
        page.items = [item]
        let manifest = NotebookManifest(title: "Biology", defaults: paper, pages: [page])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let document = try await NotebookDocument.open(manifest.id, root: root)
        document.undoManager.groupsByEvent = false
        let session = EditorSession(document: document)
        session.selection = ItemSelection(pageID: page.id, itemID: item.id)
        return (session, document)
    }

    /// A change that takes an undo step. One that continues a run takes none, and is made outside a group, where
    /// registering a step would raise.
    private func step(_ document: NotebookDocument, _ change: () -> Void) {
        document.undoManager.beginUndoGrouping()
        change()
        document.undoManager.endUndoGrouping()
    }

    private func size(_ session: EditorSession) -> CGFloat? { session.selectedItem?.text?.fontSize }

    func testASizeStepLandsOnWholePointsWithinTheRange() {
        XCTAssertEqual(TextBox.size(17, steppedBy: 1), 18)
        XCTAssertEqual(TextBox.size(17, steppedBy: -1), 16)
        XCTAssertEqual(TextBox.size(17, steppedBy: 3), 20)
        XCTAssertEqual(TextBox.size(17, steppedBy: -3), 14)
        XCTAssertEqual(TextBox.size(17, steppedBy: 0), 17)
        XCTAssertEqual(TextBox.size(19.3, steppedBy: 1), 20, "a size from the corner handle goes to the next whole point")
        XCTAssertEqual(TextBox.size(19.3, steppedBy: -1), 19)
        XCTAssertEqual(TextBox.size(19.3, steppedBy: 0), 19.3)
        XCTAssertEqual(TextBox.size(8, steppedBy: -1), 8)
        XCTAssertEqual(TextBox.size(8.4, steppedBy: -1), 8)
        XCTAssertEqual(TextBox.size(200, steppedBy: 1), 200)
        XCTAssertEqual(TextBox.size(199.5, steppedBy: 4), 200)
    }

    func testAKnobSlidAlongIsOneUndoStep() async throws {
        let (session, document) = try await openBox()
        let slide = UUID()
        session.updateText(run: slide) { $0.fontSize = 17 }
        XCTAssertFalse(document.undoManager.canUndo, "a slide that hasn't changed anything yet takes no step")
        step(document) { session.updateText(run: slide) { $0.fontSize = 20 } }
        session.updateText(run: slide) { $0.fontSize = 24 }
        session.updateText(run: slide) { $0.fontSize = 31 }
        XCTAssertEqual(size(session), 31)
        let fitted = try XCTUnwrap(session.selectedItem)
        XCTAssertEqual(fitted.size.height, try XCTUnwrap(fitted.text).height(width: fitted.size.width), "the box is as tall as its words at every size")

        document.undoManager.undo()
        XCTAssertEqual(size(session), 17, "one undo takes the whole slide back")
        XCTAssertFalse(document.undoManager.canUndo)
        document.undoManager.redo()
        XCTAssertEqual(size(session), 31, "and one redo brings back where it ended")
    }

    func testAnotherStepEndsTheRun() async throws {
        let (session, document) = try await openBox()
        let slide = UUID()
        step(document) { session.updateText(run: slide) { $0.fontSize = 20 } }
        step(document) { session.updateText { $0.isBold = true } }
        step(document) { session.updateText(run: slide) { $0.fontSize = 24 } }

        document.undoManager.undo()
        XCTAssertEqual(size(session), 20)
        XCTAssertEqual(session.selectedItem?.text?.isBold, true)
        document.undoManager.undo()
        XCTAssertEqual(session.selectedItem?.text?.isBold, false)
        document.undoManager.undo()
        XCTAssertEqual(size(session), 17)
    }

    func testAnUndoEndsTheRun() async throws {
        let (session, document) = try await openBox()
        let slide = UUID()
        step(document) { session.updateText(run: slide) { $0.fontSize = 20 } }
        document.undoManager.undo()
        XCTAssertEqual(size(session), 17)
        step(document) { session.updateText(run: slide) { $0.fontSize = 24 } }
        XCTAssertFalse(document.undoManager.canRedo, "a change after an undo is a new step, with nothing left to redo")
        document.undoManager.undo()
        XCTAssertEqual(size(session), 17)
        document.undoManager.redo()
        XCTAssertEqual(size(session), 24)
    }

    func testStepsOneAfterAnotherAreOneUndoStepUntilAPause() async throws {
        let (session, document) = try await openBox()
        step(document) { session.stepTextSize(by: 1) }
        session.stepTextSize(by: 1)
        session.stepTextSize(by: 1)
        XCTAssertEqual(size(session), 20)

        try await Task.sleep(for: .milliseconds(1200))
        step(document) { session.stepTextSize(by: -1) }
        XCTAssertEqual(size(session), 19)
        document.undoManager.undo()
        XCTAssertEqual(size(session), 20, "a step after a pause is undone on its own")
        document.undoManager.undo()
        XCTAssertEqual(size(session), 17)
    }

    func testAStepAtTheEndOfTheRangeTakesNoUndoStep() async throws {
        let (session, document) = try await openBox(size: 200)
        session.stepTextSize(by: 1)
        XCTAssertEqual(size(session), 200)
        XCTAssertFalse(document.undoManager.canUndo)
    }
}
