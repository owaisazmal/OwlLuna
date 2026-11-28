import XCTest
import PencilKit
@testable import OwlLuna

/// What the screen shows, read a point at a time.
@MainActor
private struct Screen {
    private let width: Int, height: Int, scale: CGFloat
    private let bytes: [UInt8]

    init(_ window: UIWindow) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let picture = image.cgImage
        let w = picture?.width ?? 1, h = picture?.height ?? 1
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            if let picture { ctx?.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        }
        width = w; height = h; scale = 2; bytes = data
    }

    func color(at point: CGPoint) -> [Int] {
        let x = min(max(Int(point.x * scale), 0), width - 1), y = min(max(Int(point.y * scale), 0), height - 1)
        return (0..<3).map { Int(bytes[(y * width + x) * 4 + $0]) }
    }
}

/// Highlights kept even: the highlighter's ink lies on its canvas in ink that draws nothing, a wash under it shows each
/// stroke as a flat shape, and the page's ink comes back from the canvases as it was written.
@MainActor
final class EvenHighlightCanvasTests: XCTestCase {
    private let yellow = UIColor(red: 232 / 255, green: 176 / 255, blue: 35 / 255, alpha: 1)

    override func setUp() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.evenHighlights)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: SettingsKey.evenHighlights)
    }

    /// A highlight as a finger lays it, with the chisel across the way it goes.
    private func mark(_ a: CGPoint, _ b: CGPoint, stamp: TimeInterval, color: UIColor? = nil, width: CGFloat = 20, mask: UIBezierPath? = nil) -> PKStroke {
        let count = max(Int(hypot(b.x - a.x, b.y - a.y) / 6), 1), level = abs(b.x - a.x) >= abs(b.y - a.y), size = 0.667 * width
        let points = (0...count).map { i -> PKStrokePoint in
            let t = CGFloat(i) / CGFloat(count)
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: TimeInterval(i) / 60,
                                 size: CGSize(width: size, height: size), opacity: 1, force: 0, azimuth: level ? .pi / 2 : .pi, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.marker, color: color ?? yellow), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: stamp)), mask: mask)
    }

    /// The layers that draw the wash's marks, lowest first.
    private func shapes(of wash: HighlightWashView) -> [CAShapeLayer] {
        var found: [CAShapeLayer] = [], layers = wash.layer.sublayers ?? []
        while !layers.isEmpty {
            let layer = layers.removeFirst()
            if let shape = layer as? CAShapeLayer { found.append(shape) }
            layers += layer.sublayers ?? []
        }
        return found.sorted { $0.zPosition < $1.zPosition }
    }

    /// A notebook of one blank page of `paper` holding `ink`, open in a window as `OpenPage` opens a white one.
    private func open(paper color: PaperColor, ink: [PKStroke]) async throws -> (controller: PageStackController, window: UIWindow) {
        let root = temporaryRoot(self)
        let paper = PageDefaults(template: .blank, paperColor: color, pageSize: .letter)
        let manifest = NotebookManifest(title: "Paper", defaults: paper, pages: [paper.newPage()])
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[0].id: PKDrawing(strokes: ink)]))
        let session = EditorSession(document: try await NotebookDocument.open(manifest.id, root: root))
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
        return (controller, window)
    }

    private func mark(y: CGFloat, stamp: TimeInterval, color: UIColor? = nil) -> PKStroke {
        mark(CGPoint(x: 100, y: y), CGPoint(x: 300, y: y), stamp: stamp, color: color)
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

    private func isHighlight(_ stroke: PKStroke) -> Bool { stroke.ink.inkType == .marker }

    /// Whether two strokes are one: ink to the last bit, path, place, mask and, where PencilKit names strokes, name.
    private func same(_ a: PKStroke, _ b: PKStroke) -> Bool {
        guard a.ink.inkType == b.ink.inkType, a.ink.color.cgColor.components == b.ink.color.cgColor.components,
              a.path.creationDate == b.path.creationDate, a.path.count == b.path.count, a.transform == b.transform,
              a.mask?.cgPath == b.mask?.cgPath, a.randomSeed == b.randomSeed else { return false }
        if #available(iOS 27.0, *) { return a.id == b.id && a.renderGroupID == b.renderGroupID }
        return true
    }

    private func assertSame(_ ink: PKDrawing, _ written: [PKStroke], _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(ink.strokes.count, written.count, message, line: line)
        for (index, pair) in zip(ink.strokes, written).enumerated() {
            XCTAssertTrue(same(pair.0, pair.1), "stroke \(index) \(message)", line: line)
        }
    }

    func testTheGroundHoldsUnseenInkAndTheWashShowsIt() async throws {
        let faint = yellow.withAlphaComponent(ReplayInk.faint)
        let open = try await OpenPage.open(self, ink: [line(y: 100, stamp: 1), mark(y: 100, stamp: 2), line(y: 200, stamp: 3), mark(y: 200, stamp: 4, color: faint)])
        let canvas = open.canvas, ground = try XCTUnwrap(canvas.ground), wash = try XCTUnwrap(canvas.wash), written = open.ink
        XCTAssertEqual(stamps(canvas.drawing), [1, 3])
        XCTAssertEqual(stamps(ground.drawing), [2, 4])
        XCTAssertTrue(ground.drawing.strokes.allSatisfy(UnseenInk.isUnseen), "the highlighter's ink draws nothing there")
        XCTAssertEqual(ground.drawing.strokes.map { $0.ink.color.cgColor.alpha }, [written[1], written[3]].map { $0.ink.color.cgColor.alpha / 16_777_216 })
        XCTAssertEqual(wash.marks.count, 2, "and the wash shows each stroke")
        XCTAssertNotEqual(wash.marks[0].color, wash.marks[1].color, "a faint one fainter")
        assertSame(canvas.ink, written, "comes back as it was written")
        XCTAssertEqual(stamps(canvas.ink), [1, 2, 3, 4])

        let views = try XCTUnwrap(canvas.superview?.subviews)
        XCTAssertEqual(views.firstIndex(of: wash).map { $0 + 1 }, views.firstIndex(of: ground), "right under the highlighter's canvas")
        XCTAssertTrue(canvas.lowest === wash)
        XCTAssertEqual(wash.frame, ground.frame)
        XCTAssertEqual(wash.bounds.origin, ground.contentOffset)
        XCTAssertEqual(wash.layer.compositingFilter as? String, "multiplyBlendMode")
        XCTAssertFalse(wash.isUserInteractionEnabled)
        XCTAssertFalse(wash.isAccessibilityElement)
        XCTAssertTrue(wash.accessibilityElementsHidden)
        XCTAssertNotNil(ground.layer.mask, "at rest the ground shows nothing of its own")
        XCTAssertEqual(canvas.accessibilityValue, "4 strokes")

        let light = wash.marks[0].color
        canvas.overrideUserInterfaceStyle = .dark
        XCTAssertNil(wash.layer.compositingFilter, "laid over dark paper, not multiplied into it")
        XCTAssertNotEqual(wash.marks[0].color, light)
        canvas.overrideUserInterfaceStyle = .light
        XCTAssertEqual(wash.layer.compositingFilter as? String, "multiplyBlendMode")
        XCTAssertEqual(wash.marks[0].color, light)

        await pause()
        XCTAssertFalse(ground.hasBlankInkTile, "ink that draws nothing is no lost tile")
        XCTAssertFalse(open.document.undoManager.canUndo)
        XCTAssertFalse(open.document.hasUnsavedInk(open.page))
    }

    func testThePagesInkComesBackAsWrittenThroughToolsErasersAndUndo() async throws {
        let open = try await OpenPage.open(self, ink: [line(y: 100, stamp: 1), mark(y: 100, stamp: 2), line(y: 200, stamp: 3), mark(y: 200, stamp: 4)])
        let canvas = open.canvas, ground = try XCTUnwrap(canvas.ground), wash = try XCTUnwrap(canvas.wash), written = open.ink

        // With an eraser in hand all the ink is on the ground, the pens' as it is and the highlighter's unseen.
        canvas.take(PKEraserTool(.vector), ruler: false, highlighterOnly: false)
        await pause()
        XCTAssertEqual(stamps(ground.drawing), [1, 2, 3, 4])
        XCTAssertEqual(ground.drawing.strokes.map(UnseenInk.isUnseen), [false, true, false, true])
        XCTAssertNil(ground.layer.mask, "the pens' ink is seen on the ground")
        assertSame(canvas.ink, written, "with an eraser in hand")
        XCTAssertEqual(wash.marks.count, 2, "picking a tool up changes nothing that is seen")
        XCTAssertFalse(open.document.undoManager.canUndo)

        if #available(iOS 27.0, *) {
            // PencilKit's pixel eraser goes down through the first line and the highlight on it.
            let rub = (0...10).map {
                PKStrokePoint(location: CGPoint(x: 200, y: 60 + CGFloat($0) * 8), timeOffset: TimeInterval($0) / 60, size: CGSize(width: 12, height: 12),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            ground.drawing = ground.drawing.erasingPath(PKStrokePath(controlPoints: rub, creationDate: Date(timeIntervalSince1970: 9)))
            await pause(0.3)
            let saved = open.ink
            XCTAssertEqual(stamps(PKDrawing(strokes: saved)), [1, 1, 2, 2, 3, 4])
            XCTAssertFalse(saved.contains(where: UnseenInk.isUnseen), "what reaches the document is in its own ink")
            for piece in saved.filter(isHighlight).prefix(2) {
                XCTAssertEqual(piece.ink.color.cgColor.components, written[1].ink.color.cgColor.components)
                XCTAssertNotNil(piece.mask)
            }
            XCTAssertTrue(ground.drawing.strokes.filter(isHighlight).allSatisfy(UnseenInk.isUnseen))
            XCTAssertEqual(wash.marks.count, 3, "the wash shows the two pieces")
            assertSame(canvas.ink, saved)
            open.document.undoManager.undo()
            XCTAssertEqual(wash.marks.count, 2)
            assertSame(canvas.ink, written, "undone")
            XCTAssertEqual(ground.drawing.strokes.map(UnseenInk.isUnseen), [false, true, false, true])
        }

        // Kept to the highlighter, the eraser finds the highlights alone, still unseen.
        canvas.take(PKEraserTool(.vector), ruler: false, highlighterOnly: true)
        await pause()
        XCTAssertEqual(stamps(ground.drawing), [2, 4])
        XCTAssertNotNil(ground.layer.mask)
        ground.drawing = PKDrawing(strokes: [ground.drawing.strokes[0]])
        await pause(0.3)
        XCTAssertEqual(stamps(PKDrawing(strokes: open.ink)), [1, 2, 3])
        XCTAssertFalse(open.ink.contains(where: UnseenInk.isUnseen))
        XCTAssertEqual(wash.marks.count, 1)
        open.document.undoManager.undo()
        assertSame(canvas.ink, written)
        XCTAssertEqual(wash.marks.count, 2)

        canvas.take(PKInkingTool(.pen, color: .black, width: 3), ruler: false, highlighterOnly: false)
        await pause()
        XCTAssertEqual(stamps(canvas.drawing), [1, 3])
        XCTAssertTrue(ground.drawing.strokes.allSatisfy(UnseenInk.isUnseen))
        assertSame(canvas.ink, written, "with a pen in hand again")
    }

    func testAStrokeTheHighlighterDrawsLandsOnTheWash() async throws {
        let open = try await OpenPage.open(self, ink: [line(y: 100, stamp: 1), mark(y: 100, stamp: 2)])
        let canvas = open.canvas, ground = try XCTUnwrap(canvas.ground), wash = try XCTUnwrap(canvas.wash)
        canvas.take(PKInkingTool(.marker, color: yellow, width: 20), ruler: false, highlighterOnly: false)

        // PencilKit puts the stroke on the ground in the highlighter's own ink.
        let drawn = mark(y: 300, stamp: 3)
        ground.layer.mask = nil
        ground.drawing = PKDrawing(strokes: ground.drawing.strokes + [drawn])
        XCTAssertEqual(wash.marks.count, 2, "the wash has it at once")
        XCTAssertNotNil(ground.layer.mask, "and the ground stops showing it in the same pass")
        XCTAssertTrue(same(try XCTUnwrap(open.ink.last), drawn), "the document has it as it was drawn")
        await pause(0.3)
        XCTAssertEqual(stamps(ground.drawing), [2, 3])
        XCTAssertEqual(ground.drawing.strokes.map(UnseenInk.isUnseen), [true, false], "the ground is not given ink again for it: that could cost the next stroke")
        XCTAssertNotNil(ground.layer.mask, "it stays out of sight")
        assertSame(canvas.ink, open.ink)
        XCTAssertTrue(same(canvas.ink.strokes[2], drawn))
        XCTAssertEqual(open.document.undoManager.undoActionName.isEmpty, false)

        open.document.undoManager.undo()
        XCTAssertEqual(stamps(ground.drawing), [2])
        XCTAssertEqual(wash.marks.count, 1)
        open.document.undoManager.redo()
        XCTAssertEqual(wash.marks.count, 2)
        XCTAssertTrue(ground.drawing.strokes.allSatisfy(UnseenInk.isUnseen), "laid again, it is unseen like the rest")
        XCTAssertTrue(same(canvas.ink.strokes[2], drawn))

        // The strip of the zoom window shows the page the same way, and what is written in it reaches the page's wash.
        open.session.setZoomWindow(true)
        var views = [open.controller.view!], found: PageCanvasView?
        while found == nil, !views.isEmpty {
            let view = views.removeFirst()
            if let canvas = view as? PageCanvasView, canvas.accessibilityIdentifier == "zoom.canvas" { found = canvas }
            views += view.subviews
        }
        let strip = try XCTUnwrap(found), under = try XCTUnwrap(strip.ground)
        for _ in 0..<100 where !strip.isLoaded { await pause(0.05) }
        XCTAssertEqual(strip.wash?.marks.count, 2)
        XCTAssertTrue(under.drawing.strokes.allSatisfy(UnseenInk.isUnseen))
        under.drawing = PKDrawing(strokes: under.drawing.strokes + [mark(y: 400, stamp: 4)])
        await pause(0.3)
        XCTAssertEqual(stamps(PKDrawing(strokes: open.ink)), [1, 2, 3, 4])
        XCTAssertFalse(open.ink.contains(where: UnseenInk.isUnseen))
        XCTAssertEqual(wash.marks.count, 3, "the page's wash has what the strip was given")
        XCTAssertTrue(ground.drawing.strokes.allSatisfy(UnseenInk.isUnseen))
        open.session.setZoomWindow(false)
    }

    func testTheSwitchChangesOpenPagesOverAndLeavesThemUnwritten() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.evenHighlights)
        let open = try await OpenPage.open(self, ink: [line(y: 100, stamp: 1), mark(y: 100, stamp: 2), mark(y: 106, stamp: 3)])
        let canvas = open.canvas, ground = try XCTUnwrap(canvas.ground), written = open.ink
        XCTAssertNil(canvas.wash, "off, highlights are PencilKit's")
        XCTAssertNil(ground.layer.mask)
        XCTAssertFalse(ground.drawing.strokes.contains(where: UnseenInk.isUnseen))
        XCTAssertTrue(canvas.lowest === ground)

        UserDefaults.standard.set(true, forKey: SettingsKey.evenHighlights)
        await pause(0.2)
        let wash = try XCTUnwrap(canvas.wash)
        XCTAssertEqual(wash.marks.count, 2)
        XCTAssertFalse(wash.isHidden)
        XCTAssertTrue(ground.drawing.strokes.allSatisfy(UnseenInk.isUnseen))
        XCTAssertNotNil(ground.layer.mask)
        assertSame(canvas.ink, written, "switched on")
        XCTAssertFalse(open.document.undoManager.canUndo, "the switch is no change to the page")
        XCTAssertFalse(open.document.hasUnsavedInk(open.page))

        UserDefaults.standard.set(false, forKey: SettingsKey.evenHighlights)
        await pause(0.1)
        XCTAssertFalse(ground.drawing.strokes.contains(where: UnseenInk.isUnseen), "the ground has the ink to draw at once")
        await pause(0.7)
        XCTAssertTrue(wash.isHidden, "and the wash goes once the ground has drawn it")
        XCTAssertTrue(wash.marks.isEmpty)
        XCTAssertNil(ground.layer.mask)
        assertSame(canvas.ink, written, "switched off")
        XCTAssertFalse(open.document.undoManager.canUndo)
        XCTAssertFalse(open.document.hasUnsavedInk(open.page))
    }

    func testACrossingIsTheLinesColourAndPrintUnderItStaysBlack() async throws {
        let level = mark(CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200), stamp: 1), upright = mark(CGPoint(x: 200, y: 120), CGPoint(x: 200, y: 280), stamp: 2)
        let open = try await OpenPage.open(self, ink: [level, upright])
        let canvas = open.canvas, ground = try XCTUnwrap(canvas.ground), window = try XCTUnwrap(canvas.window), slot = try XCTUnwrap(canvas.superview)
        let scale = ground.zoomScale
        func onScreen(_ x: CGFloat, _ y: CGFloat) -> CGPoint { ground.convert(CGPoint(x: x * scale, y: y * scale), to: window) }
        let print = UIView(frame: CGRect(x: 120 * scale, y: 180 * scale, width: 30 * scale, height: 40 * scale))
        print.backgroundColor = .black
        slot.insertSubview(print, belowSubview: canvas.lowest)
        await pause(0.8)

        var screen = Screen(window)
        let laid = EvenHighlights.color(of: open.ink[0], onDark: false).components?.prefix(3).map { Int(($0 * 255).rounded()) } ?? []
        let line = screen.color(at: onScreen(260, 200))
        XCTAssertEqual(screen.color(at: onScreen(60, 60)), [255, 255, 255])
        for (channel, value) in line.enumerated() { XCTAssertEqual(value, laid[channel], accuracy: 1, "the line is the colour worked out for it") }
        XCTAssertEqual(screen.color(at: onScreen(200, 200)), line, "where the two cross")
        XCTAssertEqual(screen.color(at: onScreen(200, 140)), line, "a line from the same pen the other way")
        XCTAssertEqual(screen.color(at: onScreen(196, 196)), line)
        XCTAssertEqual(screen.color(at: onScreen(135, 200)), [0, 0, 0], "print under a highlight stays black")

        // Off, the crossing is darker, as PencilKit lays it.
        UserDefaults.standard.set(false, forKey: SettingsKey.evenHighlights)
        await pause(1)
        screen = Screen(window)
        XCTAssertLessThan(screen.color(at: onScreen(200, 200))[2], screen.color(at: onScreen(260, 200))[2] - 20)
        XCTAssertEqual(screen.color(at: onScreen(135, 200)), [0, 0, 0])
    }

    func testTheWashMirrorsAnEraserUntilPencilKitSaysWhatItTook() throws {
        try mirror(onDark: false)
        try mirror(onDark: true)
    }

    private func mirror(onDark: Bool) throws {
        let wash = HighlightWashView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        wash.onDark = onDark
        let strokes = [mark(y: 100, stamp: 1), mark(y: 200, stamp: 2)]
        wash.show(strokes)
        XCTAssertEqual(shapes(of: wash).count, 0, "nothing is drawn until it is a window onto the page")
        wash.place(frame: wash.frame, offset: .zero, scale: 1)
        XCTAssertEqual(shapes(of: wash).count, 2)
        XCTAssertTrue(wash.marks[0].outline.contains(CGPoint(x: 200, y: 100)))

        // The pixel eraser cuts what it sweeps out of a mark.
        wash.rub(from: CGPoint(x: 200, y: 60), to: CGPoint(x: 200, y: 140), width: 20)
        XCTAssertFalse(wash.marks[0].outline.contains(CGPoint(x: 200, y: 100)))
        XCTAssertFalse(wash.marks[0].outline.contains(CGPoint(x: 208, y: 100)))
        XCTAssertTrue(wash.marks[0].outline.contains(CGPoint(x: 150, y: 100)))
        XCTAssertTrue(wash.marks[0].outline.contains(CGPoint(x: 212, y: 100)))
        XCTAssertTrue(wash.marks[1].outline.contains(CGPoint(x: 200, y: 200)), "and leaves the rest")

        // The object eraser takes the marks it touches whole, and no more.
        wash.rub(from: CGPoint(x: 150, y: 170), to: CGPoint(x: 150, y: 186), width: nil)
        XCTAssertFalse(wash.marks[1].outline.isEmpty, "a little way off it takes nothing")
        wash.rub(from: CGPoint(x: 150, y: 186), to: CGPoint(x: 150, y: 196), width: nil)
        XCTAssertTrue(wash.marks[1].outline.isEmpty)
        XCTAssertEqual(shapes(of: wash).count, 1)

        // PencilKit says the page is as it was: the marks are whole again.
        wash.show(strokes)
        XCTAssertTrue(wash.marks[0].outline.contains(CGPoint(x: 200, y: 100)))
        XCTAssertTrue(wash.marks[1].outline.contains(CGPoint(x: 200, y: 200)))
        XCTAssertEqual(shapes(of: wash).count, 2)

        // Only marks near the window have layers, and those are drawn at the window's scale.
        wash.place(frame: wash.frame, offset: CGPoint(x: 0, y: 3000), scale: 1)
        XCTAssertEqual(shapes(of: wash).count, 0)
        wash.place(frame: wash.frame, offset: CGPoint(x: 500, y: 300), scale: 5)
        XCTAssertEqual(wash.bounds.origin, CGPoint(x: 500, y: 300))
        let drawn = shapes(of: wash)
        XCTAssertEqual(drawn.count, 1, "the lower mark is out of the window's reach")
        let box = try XCTUnwrap(drawn.first?.path?.boundingBoxOfPath), page = wash.marks[0].outline.boundingBoxOfPath
        XCTAssertEqual(box.minX, page.minX * 5, accuracy: 0.01)
        XCTAssertEqual(box.width, page.width * 5, accuracy: 0.01)

        // A mark longer than 4,096 points on screen is drawn only where it is near the window.
        wash.show(strokes + [mark(CGPoint(x: 10, y: 300), CGPoint(x: 910, y: 300), stamp: 3)])
        wash.place(frame: wash.frame, offset: CGPoint(x: 500, y: 1400), scale: 5)
        let long = try XCTUnwrap(shapes(of: wash).last?.path?.boundingBoxOfPath)
        XCTAssertEqual(wash.marks.count, 3)
        XCTAssertEqual(long.width, 800, accuracy: 1, "the window is 80 points of the page wide, and half as much again is kept each way")
        XCTAssertEqual(long.minX, 300, accuracy: 1)
    }

    func testWhileTheHighlighterDrawsTheGroundIsSeenButNotWhereItStillDrawsEarlierStrokes() async throws {
        let open = try await OpenPage.open(self, ink: [line(y: 100, stamp: 1), mark(y: 100, stamp: 2)])
        let canvas = open.canvas, ground = try XCTUnwrap(canvas.ground), scale = ground.zoomScale
        func isSeen(_ x: CGFloat, _ y: CGFloat) -> Bool? {
            (ground.layer.mask as? CAShapeLayer)?.path?.contains(CGPoint(x: x * scale, y: y * scale), using: .evenOdd)
        }
        canvas.take(PKInkingTool(.marker, color: yellow, width: 20), ruler: false, highlighterOnly: false)
        XCTAssertNotNil(ground.layer.mask)
        canvas.unveil()
        XCTAssertNil(ground.layer.mask, "with nothing of its own drawn, the ground is seen whole while the highlighter draws")

        ground.drawing = PKDrawing(strokes: ground.drawing.strokes + [mark(y: 300, stamp: 3)])
        XCTAssertNotNil(ground.layer.mask)
        XCTAssertNil(ground.layer.mask as? CAShapeLayer, "at rest nothing of it is seen")
        canvas.unveil()
        XCTAssertEqual(isSeen(200, 300), false, "the stroke it drew is under its mark")
        XCTAssertEqual(isSeen(200, 310.5), false, "and so is its soft edge")
        XCTAssertEqual(isSeen(200, 320), true)
        XCTAssertEqual(isSeen(200, 100), true, "a highlight laid in unseen ink needs no cover")

        // More strokes, one touching the first and one apart: each is covered as it lands.
        ground.drawing = PKDrawing(strokes: ground.drawing.strokes + [mark(y: 312, stamp: 4)])
        ground.drawing = PKDrawing(strokes: ground.drawing.strokes + [mark(y: 400, stamp: 5)])
        XCTAssertEqual(canvas.wash?.marks.count, 4)
        canvas.unveil()
        for y in [300, 306, 312, 400] as [CGFloat] { XCTAssertEqual(isSeen(200, y), false, "at \(y)") }
        XCTAssertEqual(isSeen(200, 350), true)
        XCTAssertEqual(isSeen(50, 300), true)

        // Laid again, they are unseen like the rest and the ground needs no cover.
        open.document.undoManager.undo()
        XCTAssertTrue(ground.drawing.strokes.allSatisfy(UnseenInk.isUnseen))
        canvas.unveil()
        XCTAssertNil(ground.layer.mask)
    }

    func testInkTheLassoLiftsIsPicturedWithItsHighlightsEven() throws {
        let level = mark(CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200), stamp: 1), upright = mark(CGPoint(x: 200, y: 120), CGPoint(x: 200, y: 280), stamp: 2)
        let ink = PKDrawing(strokes: [level, upright, line(y: 240, stamp: 3)]), bounds = ink.bounds.insetBy(dx: -2, dy: -2)
        func colors(at points: [CGPoint]) -> [[Int]] {
            var image = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent { image = PageStackController.picture(of: ink, in: bounds, scale: 2, appearance: .light) }
            let width = Int(bounds.width * 2), height = Int(bounds.height * 2)
            var data = [UInt8](repeating: 0, count: width * height * 4)
            data.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                if let picture = image.cgImage { ctx?.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height)) }
            }
            return points.map { point in
                let x = Int((point.x - bounds.minX) * 2), y = Int((point.y - bounds.minY) * 2)
                return (0..<4).map { Int(data[(y * width + x) * 4 + $0]) }
            }
        }
        let places = [CGPoint(x: 260, y: 200), CGPoint(x: 200, y: 200), CGPoint(x: 200, y: 150), CGPoint(x: 250, y: 240), CGPoint(x: 120, y: 150)]
        var seen = colors(at: places)
        for channel in 0..<4 {
            XCTAssertEqual(seen[1][channel], seen[0][channel], accuracy: 1, "the crossing is lifted as the line: \(seen[1]) and \(seen[0])")
            XCTAssertEqual(seen[2][channel], seen[0][channel], accuracy: 1)
        }
        XCTAssertEqual(Double(seen[0][3]) / 255, Double(EvenHighlights.strength(of: level)), accuracy: 0.02, "at the highlight's strength, so the page shows through as it did")
        XCTAssertGreaterThan(seen[3][3], 240, "the pen's line is in the picture")
        XCTAssertLessThan(seen[3][0], 30)
        XCTAssertEqual(seen[4][3], 0)

        UserDefaults.standard.set(false, forKey: SettingsKey.evenHighlights)
        seen = colors(at: places)
        XCTAssertGreaterThan(seen[1][3], seen[0][3] + 20, "off, the picture is PencilKit's, darker where they cross")
    }

    func testAHighlightGivenBackToAGroundInSightIsHiddenAtOnce() async throws {
        let open = try await OpenPage.open(self, ink: [line(y: 100, stamp: 1), mark(y: 100, stamp: 2)])
        let canvas = open.canvas, ground = try XCTUnwrap(canvas.ground), wash = try XCTUnwrap(canvas.wash)
        canvas.take(PKEraserTool(.vector), ruler: false, highlighterOnly: false)
        await pause()
        XCTAssertNil(ground.layer.mask, "with an eraser in hand the ground is in sight")
        let back = mark(y: 300, stamp: 3)
        ground.drawing = PKDrawing(strokes: ground.drawing.strokes + [back])
        XCTAssertEqual(ground.drawing.strokes.map(UnseenInk.isUnseen), [false, true, true], "it is not left for the ground to draw over its mark")
        XCTAssertEqual(wash.marks.count, 2)
        XCTAssertTrue(same(try XCTUnwrap(open.ink.last), back), "and the page has it in its own ink")
        assertSame(canvas.ink, open.ink)
    }

    /// A stroke already cut can be cut again without its mask's box or its own bounds moving. PencilKit names strokes
    /// only from iOS 27, so the cut itself has to tell the two apart.
    func testAStrokeCutAgainWithinItsBoundsIsShownAsItIsNow() throws {
        func notched(at x: CGFloat) -> UIBezierPath {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 90, y: 85))
            for point in [CGPoint(x: x, y: 85), CGPoint(x: x, y: 104), CGPoint(x: x + 20, y: 104), CGPoint(x: x + 20, y: 85), CGPoint(x: 310, y: 85),
                          CGPoint(x: 310, y: 115), CGPoint(x: 90, y: 115)] { path.addLine(to: point) }
            path.close()
            return path
        }
        let first = mark(y: 100, stamp: 1).path
        let once = PKStroke(ink: PKInk(.marker, color: yellow), path: first, mask: notched(at: 150))
        let twice = PKStroke(ink: PKInk(.marker, color: yellow), path: first, mask: notched(at: 230))
        XCTAssertEqual(once.mask?.bounds, twice.mask?.bounds)
        XCTAssertEqual(once.renderBounds, twice.renderBounds)
        let wash = HighlightWashView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        wash.place(frame: wash.frame, offset: .zero, scale: 1)
        wash.show([once])
        XCTAssertFalse(wash.marks[0].outline.contains(CGPoint(x: 160, y: 96)))
        XCTAssertTrue(wash.marks[0].outline.contains(CGPoint(x: 240, y: 96)))
        wash.show([twice])
        XCTAssertTrue(wash.marks[0].outline.contains(CGPoint(x: 160, y: 96)), "the mark is the stroke as it is cut now")
        XCTAssertFalse(wash.marks[0].outline.contains(CGPoint(x: 240, y: 96)))
        XCTAssertNotNil(wash.outline(of: twice))
    }

    /// Dark paper has nothing to multiply into: there the marks hold the ink itself and are laid over the page at the
    /// stroke's strength, as PencilKit lays a single line.
    func testOnDarkPaperALineReadsAsPencilKitLaysItAndACrossingAsTheLine() async throws {
        let saved = [SettingsKey.appearance, SettingsKey.darkPaper].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        addTeardownBlock { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set(true, forKey: SettingsKey.darkPaper)
        let pink = UIColor(red: 236 / 255, green: 90 / 255, blue: 140 / 255, alpha: 1)
        let ink = [mark(CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200), stamp: 1), mark(CGPoint(x: 200, y: 120), CGPoint(x: 200, y: 230), stamp: 2),
                   mark(CGPoint(x: 100, y: 260), CGPoint(x: 300, y: 260), stamp: 3, color: pink),
                   // Two pens of two strengths, each crossing the other's line drawn before it.
                   mark(CGPoint(x: 100, y: 340), CGPoint(x: 300, y: 340), stamp: 4), mark(CGPoint(x: 150, y: 300), CGPoint(x: 150, y: 440), stamp: 5, color: pink, width: 40),
                   mark(CGPoint(x: 100, y: 410), CGPoint(x: 300, y: 410), stamp: 6)]
        for night in [false, true] {
            UserDefaults.standard.set(false, forKey: SettingsKey.evenHighlights)
            let opened = try await open(paper: night ? .white : .chalkboard, ink: ink)
            let controller = opened.controller, window = opened.window
            if night {
                // White paper that Dark Mode shows dark.
                UserDefaults.standard.set(AppAppearance.dark.rawValue, forKey: SettingsKey.appearance)
                window.overrideUserInterfaceStyle = .dark
                window.updateTraitsIfNeeded()
                controller.updateTraitsIfNeeded()
                for _ in 0..<200 where controller.canvas(forPage: 0)?.isLoaded != true { await pause(0.05) }
            }
            let canvas = try XCTUnwrap(controller.canvas(forPage: 0)), ground = try XCTUnwrap(canvas.ground), slot = try XCTUnwrap(canvas.superview)
            XCTAssertEqual(canvas.overrideUserInterfaceStyle, .dark, "ink is drawn for dark paper")
            let scale = ground.zoomScale
            func onScreen(_ x: CGFloat, _ y: CGFloat) -> CGPoint { ground.convert(CGPoint(x: x * scale, y: y * scale), to: window) }
            let print = UIView(frame: CGRect(x: 120 * scale, y: 180 * scale, width: 30 * scale, height: 40 * scale))
            print.backgroundColor = .white
            slot.insertSubview(print, belowSubview: canvas.lowest)
            await pause(1)
            var screen = Screen(window)
            let places = [("the yellow line", onScreen(260, 200)), ("the pink line", onScreen(260, 260)), ("print under a highlight", onScreen(135, 200))]
            let pencilKits = places.map { screen.color(at: $0.1) }, paper = screen.color(at: onScreen(60, 60))
            XCTAssertLessThan(paper[0], 80, "the paper is dark")

            UserDefaults.standard.set(true, forKey: SettingsKey.evenHighlights)
            await pause(1)
            let wash = try XCTUnwrap(canvas.wash)
            XCTAssertNil(wash.layer.compositingFilter)
            XCTAssertNil(ground.layer.compositingFilter)
            screen = Screen(window)
            for (place, was) in zip(places, pencilKits) {
                let now = screen.color(at: place.1)
                for channel in 0..<3 { XCTAssertEqual(now[channel], was[channel], accuracy: 3, "\(place.0) reads as it does with the switch off, \(now) and \(was), night \(night)") }
            }
            let line = screen.color(at: onScreen(260, 200))
            for channel in 0..<3 {
                XCTAssertEqual(screen.color(at: onScreen(200, 200))[channel], line[channel], accuracy: 1, "a crossing of one pen reads as the line")
                XCTAssertEqual(screen.color(at: onScreen(200, 150))[channel], line[channel], accuracy: 1)
            }
            XCTAssertEqual(screen.color(at: onScreen(60, 60)), paper)
            // Two strengths: the later line is laid over the earlier at its own strength, so a little of the earlier shows through it.
            let broad = screen.color(at: onScreen(150, 375)), thin = screen.color(at: onScreen(260, 410)), first = screen.color(at: onScreen(260, 340))
            let strengths = [EvenHighlights.strength(of: ink[4]), EvenHighlights.strength(of: ink[5])]
            XCTAssertGreaterThan(strengths[0], strengths[1] + 0.05, "a broad pen lays more")
            func over(_ top: [Int], _ under: [Int], strength: CGFloat) -> [CGFloat] {
                (0..<3).map { CGFloat(top[$0]) + CGFloat(under[$0] - paper[$0]) * (1 - strength) }
            }
            let crossings = [(onScreen(150, 340), over(broad, first, strength: strengths[0]), over(first, broad, strength: strengths[1]), "the broad pen's line over the one before it"),
                             (onScreen(150, 410), over(thin, broad, strength: strengths[1]), over(broad, thin, strength: strengths[0]), "the line drawn after the broad one over it")]
            for (point, laid, other, name) in crossings {
                let now = screen.color(at: point)
                for channel in 0..<3 { XCTAssertEqual(CGFloat(now[channel]), laid[channel], accuracy: 3, "\(name): \(now), night \(night)") }
                XCTAssertGreaterThan(abs(CGFloat(now[0]) - other[0]) + abs(CGFloat(now[1]) - other[1]), 12, "\(name), and not the other way up")
            }

            // A stroke the highlighter draws lands there as on light paper.
            if !night {
                canvas.take(PKInkingTool(.marker, color: yellow, width: 20), ruler: false, highlighterOnly: false)
                ground.drawing = PKDrawing(strokes: ground.drawing.strokes + [mark(CGPoint(x: 100, y: 500), CGPoint(x: 300, y: 500), stamp: 7)])
                XCTAssertEqual(wash.marks.count, ink.count + 1)
                XCTAssertNotNil(ground.layer.mask)
                await pause(0.5)
                let landed = Screen(window).color(at: onScreen(260, 500))
                for channel in 0..<3 { XCTAssertEqual(landed[channel], line[channel], accuracy: 1, "a line just drawn reads as the others") }
            }
            window.isHidden = true
        }
    }
}
