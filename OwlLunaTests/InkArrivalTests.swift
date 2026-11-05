import XCTest
import PencilKit
@testable import OwlLuna

/// Ink put on a page from the page's side just as the editor opens: Shapes, undo, a page still loading.
@MainActor
final class InkArrivalTests: XCTestCase {
    private func shapes() -> [PKStroke] {
        let black = PKInkingTool(.pen, color: .black, width: 3), blue = PKInkingTool(.pen, color: UIColor(red: 0.15, green: 0.28, blue: 0.72, alpha: 1), width: 3)
        let figures: [(ShapeKind, CGPoint, CGPoint, PKInkingTool)] = [
            (.circle, CGPoint(x: 90, y: 330), CGPoint(x: 200, y: 440), black),
            (.rectangle, CGPoint(x: 250, y: 340), CGPoint(x: 390, y: 430), blue),
            (.triangle, CGPoint(x: 440, y: 330), CGPoint(x: 560, y: 440), black),
            (.line, CGPoint(x: 200, y: 385), CGPoint(x: 250, y: 385), black),
            (.line, CGPoint(x: 390, y: 385), CGPoint(x: 465, y: 385), black),
        ]
        return figures.map { kind, a, b, tool in ShapeSnap.stroke(kind.shape(from: a, to: b), tool: tool, startingNear: a) }
    }

    private func window() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1210)
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return window
    }

    /// Three blank ruled pages, as a new notebook has, on screen. Their ink is still loading when this returns.
    private func open(in window: UIWindow) async throws -> (NotebookDocument, PageStackController) {
        let root = temporaryRoot(self)
        let paper = PageDefaults(template: .narrowRuled, paperColor: .white, pageSize: .letter)
        let manifest = NotebookManifest(title: "Arrival", defaults: paper, pages: (0..<3).map { _ in paper.newPage() })
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let session = EditorSession(document: document)
        let controller = PageStackController(session: session)
        session.canvas = controller
        window.rootViewController = controller
        controller.view.layoutIfNeeded()
        return (document, controller)
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The points along the strokes where the screen shows only paper.
    private func missing(_ strokes: [PKStroke], on canvas: PageCanvasView, in window: UIWindow) throws -> [CGPoint] {
        let slot = try XCTUnwrap(canvas.superview)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        func luminance(_ x: Int, _ y: Int) -> CGFloat {
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return (0.2126 * CGFloat(pixels[i]) + 0.7152 * CGFloat(pixels[i + 1]) + 0.0722 * CGFloat(pixels[i + 2])) / 255
        }
        let scale = canvas.zoomScale
        let blankSpot = slot.convert(CGPoint(x: 300 * scale, y: 30 * scale), to: window)
        let paper = luminance(Int(blankSpot.x), Int(blankSpot.y))
        return strokes.flatMap { stroke in
            stroke.path.interpolatedPoints(by: .distance(6)).map(\.location).filter { location in
                let point = slot.convert(CGPoint(x: location.x * scale, y: location.y * scale), to: window)
                let x = Int(point.x), y = Int(point.y)
                return !(-2...2).contains { dy in (-2...2).contains { dx in abs(luminance(x + dx, y + dy) - paper) > 0.25 } }
            }
        }
    }

    /// Waits for the strokes to show in full, and returns what is still missing after fifteen seconds.
    private func drawn(_ strokes: [PKStroke], on canvas: PageCanvasView, in window: UIWindow) async throws -> [CGPoint] {
        var missed: [CGPoint] = []
        for _ in 0..<150 {
            missed = try missing(strokes, on: canvas, in: window)
            if missed.isEmpty { break }
            await pause(0.1)
        }
        return missed
    }

    private func tileLayers(in view: UIView) -> [CALayer] {
        guard NSStringFromClass(type(of: view)) == "PKCanvasAttachmentView" else { return view.subviews.flatMap { tileLayers(in: $0) } }
        return view.subviews.flatMap { holder in (holder.layer.sublayers ?? []).filter { $0.delegate == nil } }
    }

    func testInkPutOnAPageAsItFinishesLoadingIsDrawnWhole() async throws {
        let window = try window()
        for attempt in 0..<4 {
            let (document, controller) = try await open(in: window)
            let page = document.pages[0].id
            // Each wait goes to the back of the main queue, so this runs before the canvas hears that the page has loaded.
            let start = CACurrentMediaTime()
            while document.loadedInk(page) == nil, CACurrentMediaTime() - start < 5 { await Task.yield() }
            let ink = try XCTUnwrap(document.loadedInk(page))
            let added = shapes()
            XCTAssertTrue(document.updateInk([page: PKDrawing(strokes: ink.strokes + added)], actionName: "Draw Shape"))

            let canvas = try XCTUnwrap(controller.canvas(forPage: 0))
            let missed = try await drawn(added, on: canvas, in: window)
            XCTAssertEqual(canvas.drawing.strokes.count, added.count, "attempt \(attempt): the page loading doesn't put its old ink back")
            XCTAssertEqual(document.loadedInk(page)?.strokes.count, added.count)
            XCTAssertTrue(missed.isEmpty, "attempt \(attempt): \(missed.count) points of the shapes don't show, e.g. \(missed.prefix(3))")
        }
    }

    func testATileThatLostItsRenderIsDrawnAgain() async throws {
        let window = try window()
        let (document, controller) = try await open(in: window)
        let page = document.pages[0].id
        _ = await document.ink(page)
        let added = shapes()
        XCTAssertTrue(document.updateInk([page: PKDrawing(strokes: added)], actionName: "Draw Shape"))
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0))
        let firstMissed = try await drawn(added, on: canvas, in: window)
        XCTAssertTrue(firstMissed.isEmpty)
        XCTAssertFalse(canvas.hasBlankInkTile)

        // What PencilKit leaves when memory runs short between drawing a tile and showing it.
        let scale = canvas.zoomScale, rectangle = CGPoint(x: 320 * scale, y: 340 * scale)
        let tile = try XCTUnwrap(tileLayers(in: canvas).first { $0.contents != nil && $0.convert($0.bounds, to: canvas.layer).contains(rectangle) })
        tile.contents = nil
        XCTAssertTrue(canvas.hasBlankInkTile)
        XCTAssertFalse(try missing(added, on: canvas, in: window).isEmpty, "the lost tile shows as missing ink")

        canvas.tileChecks = 1
        controller.canvasViewDidFinishRendering(canvas)
        let missed = try await drawn(added, on: canvas, in: window)
        XCTAssertTrue(missed.isEmpty, "\(missed.count) points still missing, e.g. \(missed.prefix(3))")
        XCTAssertFalse(canvas.hasBlankInkTile)
        XCTAssertEqual(canvas.drawing.strokes.count, added.count)
        XCTAssertEqual(document.loadedInk(page)?.strokes.count, added.count, "the page's ink is left as it was")
    }

    func testTheEmptyMiddleOfARingIsNotTakenForALostTile() async throws {
        let window = try window()
        let (document, controller) = try await open(in: window)
        let page = document.pages[0].id
        _ = await document.ink(page)
        let ring = ShapeSnap.stroke(ShapeKind.circle.shape(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 600, y: 640)), tool: PKInkingTool(.pen, color: .black, width: 3), startingNear: CGPoint(x: 20, y: 60))
        XCTAssertTrue(document.updateInk([page: PKDrawing(strokes: [ring])], actionName: "Draw Shape"))
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0))
        let missed = try await drawn([ring], on: canvas, in: window)
        XCTAssertTrue(missed.isEmpty)
        XCTAssertFalse(canvas.hasBlankInkTile)
        let scale = canvas.zoomScale, middle = CGPoint(x: 310 * scale, y: 350 * scale)
        let tile = try XCTUnwrap(tileLayers(in: canvas).first { $0.convert($0.bounds, to: canvas.layer).contains(middle) })
        tile.contents = nil
        XCTAssertFalse(canvas.hasBlankInkTile, "no stroke runs through the middle of the ring, so its tile is meant to be empty")
    }
}
