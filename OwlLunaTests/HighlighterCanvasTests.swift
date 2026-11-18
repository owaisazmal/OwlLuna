import XCTest
import PencilKit
@testable import OwlLuna

/// The highlighter's ink on a canvas of its own under the page's: multiplied into light paper, in step with the
/// page's ink, and all that an eraser kept to the highlighter can reach.
@MainActor
final class HighlighterCanvasTests: XCTestCase {
    private func mark(y: CGFloat, stamp: TimeInterval) -> PKStroke {
        let line = stroke(from: CGPoint(x: 100, y: y), to: CGPoint(x: 300, y: y), width: 20)
        return PKStroke(ink: PKInk(.marker, color: .yellow), path: PKStrokePath(controlPoints: Array(line.path), creationDate: Date(timeIntervalSince1970: stamp)))
    }

    private func line(y: CGFloat, stamp: TimeInterval) -> PKStroke {
        let line = stroke(from: CGPoint(x: 100, y: y), to: CGPoint(x: 300, y: y))
        return PKStroke(ink: line.ink, path: PKStrokePath(controlPoints: Array(line.path), creationDate: Date(timeIntervalSince1970: stamp)))
    }

    private func stamps(_ ink: PKDrawing?) -> [TimeInterval] {
        (ink?.strokes ?? []).map { $0.path.creationDate.timeIntervalSince1970 }
    }

    private func pause(_ seconds: Double = 0.6) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func testTheHighlightersInkLiesUnderThePensAndIsMultipliedIntoLightPaper() async throws {
        let open = try await OpenPage.open(self, ink: [line(y: 100, stamp: 1), mark(y: 100, stamp: 2), line(y: 200, stamp: 3), mark(y: 200, stamp: 4)])
        let canvas = open.canvas, ground = try XCTUnwrap(canvas.ground)
        XCTAssertEqual(stamps(canvas.drawing), [1, 3], "the pens' ink is on the page's canvas")
        XCTAssertEqual(stamps(ground.drawing), [2, 4], "and the highlighter's on the one under it")
        XCTAssertEqual(stamps(canvas.ink), [1, 2, 3, 4], "between them they hold the page's ink in its order")
        XCTAssertTrue(ground.superview === canvas.superview)
        let views = try XCTUnwrap(canvas.superview?.subviews)
        XCTAssertEqual(views.firstIndex(of: ground).map { $0 + 1 }, views.firstIndex(of: canvas), "right under it")
        XCTAssertEqual(ground.frame, canvas.frame)
        XCTAssertEqual(ground.contentOffset, canvas.contentOffset)
        XCTAssertEqual(ground.zoomScale, canvas.zoomScale)
        XCTAssertEqual(ground.layer.compositingFilter as? String, "multiplyBlendMode")
        XCTAssertNil(canvas.layer.compositingFilter, "the pens are laid over whatever is under them")
        XCTAssertEqual(canvas.accessibilityValue, "4 strokes")
        XCTAssertFalse(ground.isAccessibilityElement)

        canvas.overrideUserInterfaceStyle = .dark
        XCTAssertNil(ground.layer.compositingFilter, "on dark paper the highlighter is laid over it, as it is in what is exported")
        XCTAssertEqual(ground.overrideUserInterfaceStyle, .dark)
        canvas.overrideUserInterfaceStyle = .light
        XCTAssertEqual(ground.layer.compositingFilter as? String, "multiplyBlendMode")
    }

    func testTheHighlighterDrawsUnderThePensAndItsStrokeReachesThePage() async throws {
        let open = try await OpenPage.open(self, ink: [line(y: 100, stamp: 1), mark(y: 100, stamp: 2)])
        let canvas = open.canvas, ground = try XCTUnwrap(canvas.ground), middle = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        canvas.take(PKInkingTool(.pen, color: .black, width: 3), ruler: false, highlighterOnly: false)
        XCTAssertNotNil(canvas.hitTest(middle, with: nil), "a pen writes on the page's canvas")
        canvas.take(PKInkingTool(.marker, color: .yellow, width: 20), ruler: true, highlighterOnly: false)
        XCTAssertNil(canvas.hitTest(middle, with: nil), "the highlighter's touches go to the canvas under it")
        XCTAssertTrue(ground.tool is PKInkingTool)
        XCTAssertTrue(ground.isRulerActive, "and the ruler is where the stroke is drawn")
        XCTAssertFalse(canvas.isRulerActive)
        XCTAssertTrue(canvas.rulerIsOut)

        ground.drawing = PKDrawing(strokes: ground.drawing.strokes + [mark(y: 300, stamp: 3)])
        await pause(0.3)
        XCTAssertEqual(stamps(open.document.loadedInk(open.page)), [1, 2, 3])
        canvas.take(PKInkingTool(.pen, color: .black, width: 3), ruler: false, highlighterOnly: false)
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [line(y: 300, stamp: 4)])
        await pause(0.3)
        XCTAssertEqual(stamps(open.document.loadedInk(open.page)), [1, 2, 3, 4], "a stroke goes last, whichever canvas it was drawn on")
        open.document.undoManager.undo()
        open.document.undoManager.undo()
        XCTAssertEqual(stamps(ground.drawing), [2])
        XCTAssertEqual(stamps(canvas.drawing), [1])
    }

    func testAnEraserKeptToTheHighlighterReachesOnlyItsInk() async throws {
        let open = try await OpenPage.open(self, ink: [line(y: 100, stamp: 1), mark(y: 100, stamp: 2), line(y: 200, stamp: 3)])
        let canvas = open.canvas, ground = try XCTUnwrap(canvas.ground), middle = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)

        // The eraser rubs on the canvas under the page's, where all the ink is put for it.
        canvas.take(PKEraserTool(.vector), ruler: false, highlighterOnly: false)
        XCTAssertNil(canvas.hitTest(middle, with: nil))
        XCTAssertEqual(stamps(ground.drawing), [1, 2, 3])
        XCTAssertEqual(stamps(canvas.drawing), [1, 3], "the pens' ink stays in sight until the other canvas has drawn it")
        await pause()
        XCTAssertEqual(stamps(canvas.drawing), [])
        XCTAssertEqual(stamps(canvas.ink), [1, 2, 3])
        XCTAssertFalse(open.document.undoManager.canUndo, "taking up a tool is no change to the page")
        XCTAssertFalse(open.document.hasUnsavedInk(open.page))

        // Kept to the highlighter, it finds only the highlighter's ink there.
        canvas.take(PKEraserTool(.vector), ruler: false, highlighterOnly: true)
        XCTAssertNil(canvas.hitTest(middle, with: nil))
        XCTAssertEqual(stamps(canvas.drawing), [1, 3])
        await pause()
        XCTAssertEqual(stamps(ground.drawing), [2])
        XCTAssertFalse(open.document.undoManager.canUndo)
        ground.drawing = PKDrawing()
        await pause(0.3)
        XCTAssertEqual(stamps(open.document.loadedInk(open.page)), [1, 3], "what was written under the highlight is still there")
        open.document.undoManager.undo()
        XCTAssertEqual(stamps(ground.drawing), [2])
        XCTAssertEqual(stamps(canvas.ink), [1, 2, 3])

        // A stroke drawn before the ink has been handed over is kept, and nothing is doubled.
        canvas.take(PKEraserTool(.vector), ruler: false, highlighterOnly: false)
        canvas.take(PKInkingTool(.pen, color: .black, width: 3), ruler: false, highlighterOnly: false)
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [line(y: 300, stamp: 4)])
        await pause(0.3)
        XCTAssertEqual(stamps(open.document.loadedInk(open.page)), [1, 2, 3, 4])
        XCTAssertEqual(stamps(ground.drawing), [2])
        XCTAssertEqual(stamps(canvas.drawing), [1, 3, 4])
    }
}
