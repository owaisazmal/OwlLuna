import XCTest
import PencilKit
@testable import OwlLuna

/// The Shapes shortcut: the strip over the tray, the shape a drag gives, and what is saved of it.
@MainActor
final class ShapeStripTests: XCTestCase {
    private func freshDefaults() throws -> UserDefaults {
        let suite = "ShapeStripTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testADragGivesTheShapeInItsBoxWhicheverWayItGoes() {
        XCTAssertEqual(ShapeKind.line.shape(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 12)),
                       .line(CGPoint(x: 10, y: 11), CGPoint(x: 110, y: 11)), "a line dragged nearly level is made level")
        XCTAssertEqual(ShapeKind.line.shape(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 90)), .line(CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 90)))
        XCTAssertEqual(ShapeKind.arrow.shape(from: CGPoint(x: 110, y: 12), to: CGPoint(x: 10, y: 10), width: 2),
                       .arrow(CGPoint(x: 110, y: 11), CGPoint(x: 10, y: 11), head: 20), "an arrow points where the drag ends, and is squared as a line is")
        XCTAssertEqual(ShapeKind.circle.shape(from: CGPoint(x: 100, y: 100), to: .zero),
                       .ellipse(center: CGPoint(x: 50, y: 50), radii: CGSize(width: 50, height: 50), rotation: 0))
        XCTAssertEqual(ShapeKind.circle.shape(from: .zero, to: CGPoint(x: 200, y: 100)),
                       .ellipse(center: CGPoint(x: 100, y: 50), radii: CGSize(width: 100, height: 50), rotation: 0), "a long box gives an ellipse")
        XCTAssertEqual(ShapeKind.circle.shape(from: .zero, to: CGPoint(x: 100, y: 92)),
                       .ellipse(center: CGPoint(x: 50, y: 46), radii: CGSize(width: 48, height: 48), rotation: 0), "a nearly square one a circle")
        XCTAssertEqual(ShapeKind.rectangle.shape(from: CGPoint(x: 40, y: 10), to: CGPoint(x: 0, y: 50)),
                       .polygon([CGPoint(x: 0, y: 10), CGPoint(x: 40, y: 10), CGPoint(x: 40, y: 50), CGPoint(x: 0, y: 50)]))
        XCTAssertEqual(ShapeKind.triangle.shape(from: CGPoint(x: 60, y: 40), to: .zero),
                       .polygon([CGPoint(x: 30, y: 0), CGPoint(x: 60, y: 40), CGPoint(x: 0, y: 40)]), "a triangle stands on the box's foot")
    }

    func testAShapeIsDrawnInThePensInkAndReadsAsItself() throws {
        let tool = PKInkingTool(.monoline, color: ToolPreset.uiColor(0x2747_B8FF), width: 2)
        let drawn: [(ShapeKind, String)] = [(.line, "line"), (.arrow, "arrow"), (.circle, "circle"), (.rectangle, "rectangle"), (.triangle, "triangle")]
        for (kind, name) in drawn {
            let start = CGPoint(x: 100, y: 80), end = CGPoint(x: 260, y: 200)
            let stroke = ShapeSnap.stroke(kind.shape(from: start, to: end, width: tool.width), tool: tool, startingNear: start)
            XCTAssertEqual(stroke.ink.inkType, .monoline)
            XCTAssertEqual(ToolPreset.bytes(of: stroke.ink.color), 0x2747_B8FF, "in the pen's colour")
            XCTAssertEqual(try XCTUnwrap(stroke.path.first).size.width, 4, accuracy: 0.01, "2 pt more than the fineliner's width, as its strokes by hand are")
            let bounds = PKDrawing(strokes: [stroke]).bounds
            XCTAssertEqual(bounds.minX, 100, accuracy: 4, name)
            XCTAssertEqual(bounds.maxX, 260, accuracy: 4, name)
            XCTAssertEqual(bounds.minY, 80, accuracy: 4, name)
            XCTAssertEqual(bounds.maxY, 200, accuracy: 4, name)
            // Draw and hold would leave it as it is.
            let points = stroke.path.interpolatedPoints(by: .distance(3)).map(\.location)
            XCTAssertEqual(ShapeRecognizer.recognize(points)?.displayName, name == "circle" ? "ellipse" : name)
        }
    }

    func testAnArrowHasABarbEitherSideOfItsTipAsLargeAsThePenIsWide() throws {
        let tail = CGPoint(x: 100, y: 300), tip = CGPoint(x: 400, y: 300)
        guard case .arrow(_, _, let fine) = ShapeKind.arrow.shape(from: tail, to: tip, width: 2.7),
              case .arrow(_, _, let broad) = ShapeKind.arrow.shape(from: tail, to: tip, width: 20),
              case .arrow(_, _, let short) = ShapeKind.arrow.shape(from: tail, to: CGPoint(x: 160, y: 300), width: 20) else { return XCTFail() }
        XCTAssertEqual(fine, 22.1, accuracy: 0.01)
        XCTAssertGreaterThan(broad, fine, "a wider pen has a larger head")
        XCTAssertEqual(short, 20, accuracy: 0.01, "never more than a third of the arrow")

        let (left, right) = SnappedShape.barbs(tail: tail, tip: tip, head: 26)
        XCTAssertEqual(left.x, 400 - 26 * cos(.pi / 6), accuracy: 0.01, "the barbs turn back 30 degrees from the shaft")
        XCTAssertEqual(right.x, left.x, accuracy: 0.01)
        XCTAssertEqual(left.y + right.y, 600, accuracy: 0.01, "one either side")
        XCTAssertEqual(abs(left.y - 300), 13, accuracy: 0.01)

        let tool = PKInkingTool(.pen, color: .black, width: 4)
        let stroke = ShapeSnap.stroke(ShapeKind.arrow.shape(from: tail, to: tip, width: tool.width), tool: tool, startingNear: tip)
        let outline = stroke.path.interpolatedPoints(by: .distance(2)).map(\.location)
        XCTAssertEqual(try XCTUnwrap(outline.first).x, 100, accuracy: 1.5, "it is drawn from the tail")
        for corner in [tail, tip, left, right] {
            XCTAssertLessThan(outline.map { ShapeRecognizer.distance($0, corner) }.min() ?? 99, 1.5, "one stroke, sharp at the tip and the barbs")
        }
    }

    func testAShapeLeavesAMarkAtThePensThinnestWidth() {
        for ink in [PKInkingTool.InkType.pen, .monoline, .fountainPen] {
            let tool = PKInkingTool(ink, color: .black, width: ToolPreset.widths(of: ink).lowerBound)
            let stroke = ShapeSnap.stroke(ShapeKind.line.shape(from: CGPoint(x: 60, y: 10), to: CGPoint(x: 60, y: 110), width: tool.width), tool: tool, startingNear: .zero)
            let image = PKDrawing(strokes: [stroke]).image(from: CGRect(x: 0, y: 0, width: 120, height: 120), scale: 2)
            XCTAssertGreaterThan(inkedPixels(image), 200, "\(ink.rawValue) at \(tool.width)")
        }
    }

    private func inkedPixels(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 64 }.count
    }

    func testEveryArrowFromTheStripReadsBackAsAnArrow() {
        for (ink, width) in [(.pen, 1), (.pen, 2.7), (.pen, 6), (.pen, 20), (.monoline, 0.5)] as [(PKInkingTool.InkType, CGFloat)] {
            let tool = PKInkingTool(ink, color: .black, width: width)
            for length in [40, 120, 320, 640, 960] as [CGFloat] {
                for step in 0..<8 {
                    let angle = CGFloat(step) * .pi / 4 + 0.2
                    let tail = CGPoint(x: 1000, y: 1000), tip = CGPoint(x: 1000 + length * cos(angle), y: 1000 + length * sin(angle))
                    let stroke = ShapeSnap.stroke(ShapeKind.arrow.shape(from: tail, to: tip, width: width), tool: tool, startingNear: tail)
                    let read = ShapeRecognizer.recognize(stroke.path.interpolatedPoints(by: .distance(3)).map(\.location))
                    XCTAssertEqual(read?.displayName, "arrow", "\(length) pt at width \(width), turned \(step)")
                }
            }
        }
    }

    func testTheStripKeepsWithinANarrowPane() {
        XCTAssertEqual(ToolTray.shapeButton(room: 1024), ToolTray.button)
        XCTAssertEqual(ToolTray.shapeButton(room: 320), 42.5, accuracy: 0.01, "six buttons, a rule and the padding fill the pane's width within its margins")
        XCTAssertEqual(ToolTray.shapeButton(room: 200), ToolSwatch.side, "never narrower than a button's well")
    }

    func testTheStripComesOutWithTheLastShapeAndAPen() throws {
        let defaults = try freshDefaults()
        let toolbox = Toolbox(defaults: defaults)
        let pens = toolbox.shelf.usable
        XCTAssertNil(toolbox.shape)
        toolbox.take(.pen(pens[2].id))
        toolbox.take(.eraser)
        toolbox.setShapesOut(true)
        XCTAssertEqual(toolbox.shape, .circle, "it comes out with a circle the first time")
        XCTAssertEqual(toolbox.choice, .pen(pens[2].id), "and the pen last in hand, since a shape is drawn in ink")

        toolbox.pick(.triangle)
        toolbox.take(.pen(pens[1].id))
        XCTAssertEqual(toolbox.shape, .triangle, "another pen draws the shape in its ink")
        toolbox.setShapesOut(false)
        XCTAssertNil(toolbox.shape)
        toolbox.setShapesOut(true)
        XCTAssertEqual(toolbox.shape, .triangle, "and it comes back with the shape last picked")

        toolbox.take(.lasso)
        XCTAssertNil(toolbox.shape, "the lasso puts it away")
        toolbox.pick(.line)
        XCTAssertEqual(toolbox.shape, .line)
        XCTAssertNotNil(toolbox.pen)
        toolbox.isRulerActive = true
        XCTAssertNil(toolbox.shape, "the ruler and the shapes both take the drags, so one puts the other away")
        toolbox.setShapesOut(true)
        XCTAssertFalse(toolbox.isRulerActive)

        toolbox.setExtra(.shapes, shown: true)
        toolbox.setExtra(.shapes, shown: false)
        XCTAssertNil(toolbox.shape, "taken off the tray, it is put away")
        toolbox.setShapesOut(true)
        XCTAssertNil(Toolbox(defaults: defaults).shape, "like the ruler, it is put away between launches")
    }

    /// An older build reads the saved shortcuts as names and leaves out the ones it doesn't know.
    func testAnOlderBuildKeepsItsOwnToolsBesideASavedShapesShortcut() throws {
        let defaults = try freshDefaults()
        let toolbox = Toolbox(defaults: defaults)
        toolbox.setExtra(.shapes, shown: true)
        toolbox.setExtra(.ruler, shown: true)
        toolbox.take(.eraser)
        toolbox.setEraser(Eraser(kind: .part, width: 30))

        struct Older: Decodable {
            var choice: ToolChoice?
            var eraser: Eraser?
            var extras: [String]?
        }
        let known: Set = ["picture", "text", "sticker", "link", "tape", "ruler", "zoomWindow", "typing"]
        let data = try XCTUnwrap(defaults.data(forKey: SettingsKey.toolbox))
        let older = try JSONDecoder().decode(Older.self, from: data)
        XCTAssertEqual(older.extras, ["picture", "text", "ruler", "shapes"])
        XCTAssertEqual(older.extras?.filter(known.contains), ["picture", "text", "ruler"])
        XCTAssertEqual(older.choice, .eraser)
        XCTAssertEqual(older.eraser, Eraser(kind: .part, width: 30))
    }

    func testShortcutsALaterBuildSavedAreKept() throws {
        let defaults = try freshDefaults()
        defaults.set(Data(#"{"extras":["picture","stamp"]}"#.utf8), forKey: SettingsKey.toolbox)
        let toolbox = Toolbox(defaults: defaults)
        XCTAssertEqual(toolbox.extras, [.picture])
        toolbox.setExtra(.shapes, shown: true)
        let saved = try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: SettingsKey.toolbox))) as? [String: Any]
        XCTAssertEqual(saved?["extras"] as? [String], ["picture", "shapes", "stamp"])
    }
}
