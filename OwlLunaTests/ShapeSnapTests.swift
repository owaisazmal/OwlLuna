import XCTest
import PencilKit
@testable import OwlLuna

/// Draw and hold: reading a shape out of a wobbly stroke, and redrawing the stroke as that shape.
final class ShapeSnapTests: XCTestCase {
    /// The same wobble every run.
    private func wobble(_ index: Int, _ amount: CGFloat) -> CGPoint {
        CGPoint(x: sin(CGFloat(index) * 12.9898) * amount, y: cos(CGFloat(index) * 78.233) * amount)
    }

    private func along(_ corners: [CGPoint], spacing: CGFloat = 4, wobble amount: CGFloat = 1.5) -> [CGPoint] {
        var points: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / spacing))
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps), jitter = wobble(points.count, amount)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t + jitter.x, y: a.y + (b.y - a.y) * t + jitter.y))
            }
        }
        if let last = corners.last { points.append(last) }
        return points
    }

    private func ellipse(centre: CGPoint, a: CGFloat, b: CGFloat, turned: CGFloat = 0, wobble amount: CGFloat = 1.5, overshoot: CGFloat = 0.1) -> [CGPoint] {
        (0...70).map { index in
            let angle = 0.4 + (2 * .pi + overshoot) * CGFloat(index) / 70, jitter = wobble(index, amount)
            let x = a * cos(angle), y = b * sin(angle)
            return CGPoint(x: centre.x + x * cos(turned) - y * sin(turned) + jitter.x, y: centre.y + x * sin(turned) + y * cos(turned) + jitter.y)
        }
    }

    func testAWobblyLineBecomesStraight() throws {
        let drawn = along([CGPoint(x: 100, y: 200), CGPoint(x: 420, y: 330)])
        guard case .line(let a, let b)? = ShapeRecognizer.recognize(drawn) else { return XCTFail("not read as a line") }
        XCTAssertEqual(a.x, 100, accuracy: 3)
        XCTAssertEqual(b.y, 330, accuracy: 3)

        guard case .line(let left, let right)? = ShapeRecognizer.recognize(along([CGPoint(x: 80, y: 300), CGPoint(x: 400, y: 308)])) else { return XCTFail() }
        XCTAssertEqual(left.y, right.y, "a line drawn nearly level is made level")
        guard case .line(let top, let bottom)? = ShapeRecognizer.recognize(along([CGPoint(x: 200, y: 100), CGPoint(x: 206, y: 500)])) else { return XCTFail() }
        XCTAssertEqual(top.x, bottom.x, "and one drawn nearly upright, upright")
    }

    func testClosedFiguresAreToldApart() throws {
        let square = along([CGPoint(x: 160, y: 100), CGPoint(x: 300, y: 104), CGPoint(x: 296, y: 240), CGPoint(x: 98, y: 236), CGPoint(x: 102, y: 98), CGPoint(x: 150, y: 101)])
        guard case .polygon(let corners)? = ShapeRecognizer.recognize(square) else { return XCTFail("a rectangle started mid-side wasn't read as one") }
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(Set(corners.map { $0.x.rounded() }).count, 2, "its sides are made upright")
        XCTAssertEqual(Set(corners.map { $0.y.rounded() }).count, 2, "and level")
        XCTAssertEqual(SnappedShape.polygon(corners).displayName, "rectangle")

        let triangle = along([CGPoint(x: 200, y: 100), CGPoint(x: 320, y: 300), CGPoint(x: 90, y: 290), CGPoint(x: 198, y: 104)])
        guard case .polygon(let three)? = ShapeRecognizer.recognize(triangle) else { return XCTFail("not read as a triangle") }
        XCTAssertEqual(three.count, 3)

        let diamond = along([CGPoint(x: 200, y: 80), CGPoint(x: 330, y: 200), CGPoint(x: 200, y: 320), CGPoint(x: 70, y: 200), CGPoint(x: 198, y: 82)])
        guard case .polygon(let four)? = ShapeRecognizer.recognize(diamond) else { return XCTFail("not read as a diamond") }
        XCTAssertEqual(four.count, 4)
        XCTAssertGreaterThan(Set(four.map { $0.x.rounded() }).count, 2, "a square drawn on its corner stays on its corner")

        guard case .ellipse(let centre, let radii, let rotation)? = ShapeRecognizer.recognize(ellipse(centre: CGPoint(x: 300, y: 300), a: 96, b: 104)) else {
            return XCTFail("not read as a circle")
        }
        XCTAssertEqual(radii.width, radii.height, "nearly round is made round")
        XCTAssertEqual(radii.width, 100, accuracy: 6)
        XCTAssertEqual(centre.x, 300, accuracy: 5)
        XCTAssertEqual(rotation, 0)

        guard case .ellipse(_, let wide, let level)? = ShapeRecognizer.recognize(ellipse(centre: CGPoint(x: 300, y: 300), a: 160, b: 70)) else { return XCTFail() }
        XCTAssertEqual(wide.width, 160, accuracy: 6)
        XCTAssertEqual(wide.height, 70, accuracy: 6)
        XCTAssertEqual(level, 0)

        guard case .ellipse(_, let tilted, let turn)? = ShapeRecognizer.recognize(ellipse(centre: CGPoint(x: 300, y: 300), a: 160, b: 60, turned: 0.6)) else { return XCTFail() }
        XCTAssertEqual(turn, 0.6, accuracy: 0.08, "an ellipse drawn at a slant keeps its slant")
        XCTAssertEqual(tilted.width, 160, accuracy: 10)
    }

    /// Started at a corner, the hand runs on past it a little way, a few points off the first side.
    func testABoxOrTriangleThatRunsOnPastItsStartKeepsItsCorners() {
        let box = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 104), CGPoint(x: 296, y: 240), CGPoint(x: 98, y: 236)]
        let triangle = [CGPoint(x: 200, y: 100), CGPoint(x: 320, y: 300), CGPoint(x: 90, y: 290)]
        for (figure, sides) in [(box, 4), (box.reversed(), 4), (triangle, 3), (triangle.reversed(), 3)] as [([CGPoint], Int)] {
            for past: CGFloat in [0.05, 0.1, 0.15, 0.2] {
                let start = figure[0], next = figure[1]
                let end = CGPoint(x: start.x + (next.x - start.x) * past, y: start.y + (next.y - start.y) * past + 3)
                let shape = held(figure + [start, end])
                guard case .polygon(let corners)? = shape else { XCTFail("\(sides) sides run \(past) past the start read as \(String(describing: shape))"); continue }
                XCTAssertEqual(corners.count, sides, "\(sides) sides run \(past) past the start")
                for corner in figure {
                    XCTAssertLessThan(corners.map { ShapeRecognizer.distance($0, corner) }.min() ?? 99, 8, "with no spike where it closed")
                }
                XCTAssertTrue(PencilGestures.keepsFigure(shape), "so round ink it straightens")
            }
        }
        for lumps in [(0.15, 0.1, 0.03), (0.2, 0, 0.06)] as [(CGFloat, CGFloat, CGFloat)] {
            let loop = ShapeRecognizer.recognize(roughLoop(centre: CGPoint(x: 300, y: 300), width: 300, height: 80, lumps: lumps))
            XCTAssertFalse(PencilGestures.keepsFigure(loop), "a flat loop round words that runs on past its start still isn't a box: \(String(describing: loop))")
        }
    }

    func testOpenCornersAreStraightenedAndHandwritingIsLeftAlone() {
        let corner = along([CGPoint(x: 100, y: 100), CGPoint(x: 104, y: 300), CGPoint(x: 320, y: 296)])
        guard case .polyline(let points)? = ShapeRecognizer.recognize(corner) else { return XCTFail("an L wasn't read as two straight lines") }
        XCTAssertEqual(points.count, 3)

        let arc = (0...40).map { CGPoint(x: 200 + 150 * cos(CGFloat($0) / 40 * .pi), y: 300 - 150 * sin(CGFloat($0) / 40 * .pi)) }
        XCTAssertNil(ShapeRecognizer.recognize(arc), "a curve stays as it was drawn")
        let scribble = (0...120).map { step -> CGPoint in
            let t = CGFloat(step)
            let x: CGFloat = 100 + t * 2 + 40 * sin(t * 0.9)
            let y: CGFloat = 200 + 60 * sin(t * 0.37) + 30 * cos(t * 1.3)
            return CGPoint(x: x, y: y)
        }
        XCTAssertNil(ShapeRecognizer.recognize(scribble))
        XCTAssertNil(ShapeRecognizer.recognize(along([CGPoint(x: 100, y: 100), CGPoint(x: 110, y: 104)])), "a dot or a tick is too small to be a shape")
        XCTAssertNil(ShapeRecognizer.recognize([]))
    }

    func testALineWithAHookAtItsEndBecomesAnArrow() throws {
        let hook = along([CGPoint(x: 100, y: 304), CGPoint(x: 420, y: 300), CGPoint(x: 420 - 40 * cos(0.6), y: 300 - 40 * sin(0.6))])
        guard case .arrow(let tail, let tip, let head)? = ShapeRecognizer.recognize(hook) else { return XCTFail("a hook wasn't read as an arrow") }
        XCTAssertEqual(tail.x, 100, accuracy: 3)
        XCTAssertEqual(tip.x, 420, accuracy: 3, "it points where the line ended")
        XCTAssertEqual(tail.y, tip.y, "and is made level as a line is")
        XCTAssertEqual(head, 40, accuracy: 4, "with a head as long as the hook")

        let barbs = along([CGPoint(x: 120, y: 420), CGPoint(x: 360, y: 180), CGPoint(x: 351, y: 213), CGPoint(x: 361, y: 182), CGPoint(x: 327, y: 189)])
        guard case .arrow(_, let point, let size)? = ShapeRecognizer.recognize(barbs) else { return XCTFail("a barb either side wasn't read as an arrow") }
        XCTAssertEqual(point.x, 360, accuracy: 4)
        XCTAssertEqual(point.y, 180, accuracy: 4)
        XCTAssertEqual(size, 34, accuracy: 4)

        guard case .polyline? = ShapeRecognizer.recognize(along([CGPoint(x: 100, y: 300), CGPoint(x: 400, y: 300), CGPoint(x: 400, y: 260)])) else {
            return XCTFail("a hook turned square is a corner")
        }
        guard case .polyline? = ShapeRecognizer.recognize(along([CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 300), CGPoint(x: 300, y: 110)])) else {
            return XCTFail("and so is a V, its arms too long for a head")
        }

        let drawn = try XCTUnwrap(ShapeSnap.snapped(pencilStroke(hook)))
        guard case .arrow(let a, let b, let h) = drawn.shape else { return XCTFail() }
        let (left, right) = SnappedShape.barbs(tail: a, tip: b, head: h)
        let outline = drawn.stroke.path.interpolatedPoints(by: .distance(2)).map(\.location)
        for corner in [a, b, left, right] {
            XCTAssertLessThan(outline.map { ShapeRecognizer.distance($0, corner) }.min() ?? 99, 1.5, "the hook is redrawn as a barb either side")
        }
        XCTAssertEqual(drawn.shape.displayName, "arrow")
    }

    /// What draw and hold makes of a stroke through `corners`, read from PencilKit's path as the app reads it.
    private func held(_ corners: [CGPoint]) -> SnappedShape? {
        ShapeSnap.snapped(pencilStroke(along(corners)))?.shape
    }

    private func isArrow(_ corners: [CGPoint]) -> Bool {
        if case .arrow? = held(corners) { true } else { false }
    }

    /// A line from (100, 300) with a hook `length` long turned back `degrees` from it at its end.
    private func hooked(_ length: CGFloat, _ degrees: CGFloat, line: CGFloat = 300) -> [CGPoint] {
        let angle = degrees * .pi / 180
        return [CGPoint(x: 100, y: 300), CGPoint(x: 100 + line, y: 300), CGPoint(x: 100 + line - length * cos(angle), y: 300 - length * sin(angle))]
    }

    func testOnlyAShortHookOrABarbEitherSideMakesAnArrow() {
        for (length, degrees) in [(60, 20), (60, 50), (40, 35), (90, 30)] as [(CGFloat, CGFloat)] {
            XCTAssertTrue(isArrow(hooked(length, degrees)), "a \(length) pt hook turned back \(degrees)°")
        }
        XCTAssertTrue(isArrow(hooked(24, 30, line: 500)), "a hook too short to be a corner of a long line")
        XCTAssertTrue(isArrow(hooked(36, 35, line: 900)))
        XCTAssertFalse(isArrow(hooked(24, 8, line: 640)), "a short end folded back along a long line")
        XCTAssertTrue(isArrow([CGPoint(x: 100, y: 300), CGPoint(x: 260, y: 284), CGPoint(x: 420, y: 300), CGPoint(x: 390, y: 275)]), "a line with a bow in it")
        XCTAssertTrue(isArrow([CGPoint(x: 100, y: 300), CGPoint(x: 300, y: 300), CGPoint(x: 287.9, y: 307), CGPoint(x: 300, y: 300), CGPoint(x: 287.9, y: 293)]),
                      "a small barb either side")
        XCTAssertTrue(isArrow([CGPoint(x: 100, y: 300), CGPoint(x: 500, y: 300), CGPoint(x: 483.6, y: 311.5), CGPoint(x: 500, y: 300), CGPoint(x: 483.6, y: 288.5)]),
                      "even on a long line")
        XCTAssertTrue(isArrow([CGPoint(x: 100, y: 300), CGPoint(x: 400, y: 300), CGPoint(x: 287.4, y: 235), CGPoint(x: 401, y: 301), CGPoint(x: 287.4, y: 365)]),
                      "a barb either side may be longer than a lone hook")
        guard case .arrow(let tail, let tip, _)? = held([CGPoint(x: 360, y: 280), CGPoint(x: 400, y: 300), CGPoint(x: 360, y: 320), CGPoint(x: 399, y: 301),
                                                          CGPoint(x: 100, y: 300)]) else { return XCTFail("a head drawn before its line") }
        XCTAssertEqual(tail.x, 100, accuracy: 4)
        XCTAssertEqual(tip.x, 400, accuracy: 4, "still points at its head")

        for (length, degrees, why) in [(75, 5, "folded back along the line"), (60, 75, "turned nearly square"), (135, 30, "longer than a third of the line"),
                                       (210, 30, "as long as the line")] as [(CGFloat, CGFloat, String)] {
            XCTAssertFalse(isArrow(hooked(length, degrees)), why)
        }
        XCTAssertFalse(isArrow([CGPoint(x: 100, y: 400), CGPoint(x: 340, y: 100), CGPoint(x: 385, y: 250)]), "a graph's peak")
        XCTAssertFalse(isArrow([CGPoint(x: 100, y: 300), CGPoint(x: 400, y: 300), CGPoint(x: 370, y: 280), CGPoint(x: 400, y: 301), CGPoint(x: 360, y: 285)]),
                       "two barbs on one side")
        XCTAssertFalse(isArrow([CGPoint(x: 100, y: 300), CGPoint(x: 400, y: 300), CGPoint(x: 370, y: 270), CGPoint(x: 380, y: 330), CGPoint(x: 350, y: 320)]),
                       "a zigzag")
    }

    private func pencilStroke(_ points: [CGPoint], width: CGFloat = 5) -> PKStroke {
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        let path = PKStrokePath(controlPoints: points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: width, height: width), opacity: 0.9, force: 1, azimuth: 0.3, altitude: 1)
        }, creationDate: date)
        return PKStroke(ink: PKInk(.pen, color: .blue), path: path)
    }

    func testAStrokeIsRedrawnAsItsShape() throws {
        let drawn = pencilStroke(along([CGPoint(x: 100, y: 200), CGPoint(x: 420, y: 330)]))
        let line = try XCTUnwrap(ShapeSnap.snapped(drawn))
        XCTAssertEqual(line.stroke.ink.inkType, .pen)
        XCTAssertEqual(line.stroke.ink.color, drawn.ink.color)
        XCTAssertEqual(line.stroke.path.creationDate, drawn.path.creationDate, "the stroke keeps its place in a recording")
        let sampled = line.stroke.path.interpolatedPoints(by: .distance(5)).map(\.location)
        XCTAssertGreaterThan(sampled.count, 20)
        for point in sampled {
            XCTAssertLessThan(ShapeRecognizer.distance(point, toSegment: CGPoint(x: 100, y: 200), CGPoint(x: 420, y: 330)), 2.5, "every part of it lies on the line")
        }
        XCTAssertEqual(try XCTUnwrap(sampled.first).x, 100, accuracy: 3, "and it runs the whole way")
        XCTAssertEqual(try XCTUnwrap(sampled.last).x, 420, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(line.stroke.path.first).size.width, 5, accuracy: 0.01, "at the weight it was drawn")

        let square = pencilStroke(along([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 104), CGPoint(x: 296, y: 300), CGPoint(x: 98, y: 296), CGPoint(x: 101, y: 103)]))
        let box = try XCTUnwrap(ShapeSnap.snapped(square))
        guard case .polygon(let corners) = box.shape else { return XCTFail() }
        let outline = box.stroke.path.interpolatedPoints(by: .distance(2)).map(\.location)
        for corner in corners {
            XCTAssertLessThan(outline.map { ShapeRecognizer.distance($0, corner) }.min() ?? 99, 1.5, "corners stay sharp")
        }

        let ring = pencilStroke(ellipse(centre: CGPoint(x: 300, y: 300), a: 100, b: 100))
        let circle = try XCTUnwrap(ShapeSnap.snapped(ring))
        for point in circle.stroke.path.interpolatedPoints(by: .distance(6)).map(\.location) {
            XCTAssertEqual(ShapeRecognizer.distance(point, CGPoint(x: 300, y: 300)), 100, accuracy: 6)
        }
        XCTAssertNil(ShapeSnap.snapped(pencilStroke((0...40).map { CGPoint(x: 200 + 150 * cos(CGFloat($0) / 40 * .pi), y: 300 - 150 * sin(CGFloat($0) / 40 * .pi)) })))
    }

    private let start = CGPoint(x: 100, y: 300)

    /// Half a second of drawing from `time`, coming to rest at `time + 0.5`.
    private func drag(_ touch: AnyHashable, _ rests: inout TouchRests, from time: TimeInterval) {
        for step in 1...10 { rests.moved(touch, to: CGPoint(x: start.x + 30 * CGFloat(step), y: start.y), time: time + 0.05 * Double(step)) }
    }

    func testTheRestIsTakenFromTheEndOfTheStrokeOnce() throws {
        var rests = TouchRests()
        rests.began("pencil", isPencil: true, fingersDraw: false, at: start, time: 0)
        drag("pencil", &rests, from: 0)
        rests.ended("pencil", time: 1.1)
        XCTAssertTrue(rests.isEmpty)
        XCTAssertEqual(try XCTUnwrap(rests.take(at: 1.15, within: 2)), 0.6, accuracy: 0.001)
        XCTAssertNil(rests.take(at: 1.2, within: 2), "a rest is taken once")

        rests.began("pencil", isPencil: true, fingersDraw: false, at: start, time: 2)
        drag("pencil", &rests, from: 2)
        rests.ended("pencil", time: 2.52)
        XCTAssertNil(rests.take(at: 5, within: 2), "and is forgotten after a while")
    }

    func testAPalmThatLandsFirstDoesNotHideThePencilsRest() throws {
        var rests = TouchRests()
        rests.began("palm", isPencil: false, fingersDraw: false, at: CGPoint(x: 600, y: 700), time: 0)
        rests.began("pencil", isPencil: true, fingersDraw: false, at: start, time: 1)
        drag("pencil", &rests, from: 1)
        rests.ended("pencil", time: 2.1)
        XCTAssertEqual(try XCTUnwrap(rests.take(at: 2.15, within: 2)), 0.6, accuracy: 0.001, "the Pencil's hold is measured though a palm was down first")

        rests.began("pencil", isPencil: true, fingersDraw: false, at: start, time: 3)
        drag("pencil", &rests, from: 3)
        rests.ended("pencil", time: 3.55)
        XCTAssertEqual(try XCTUnwrap(rests.take(at: 3.6, within: 2)), 0.05, accuracy: 0.001, "and so is every stroke after it while the palm rests")
        XCTAssertFalse(rests.isEmpty, "the palm is still down, so the strokes go on being watched")

        rests.ended("palm", time: 4)
        XCTAssertNil(rests.take(at: 4.05, within: 2), "the palm lifting is no stroke")
        XCTAssertTrue(rests.isEmpty)
    }

    func testAThumbLiftingMidStrokeLendsTheStrokeNoRest() throws {
        for fingersDraw in [false, true] {
            var rests = TouchRests()
            rests.began("thumb", isPencil: false, fingersDraw: fingersDraw, at: CGPoint(x: 20, y: 500), time: 0)
            rests.began("pencil", isPencil: true, fingersDraw: fingersDraw, at: start, time: 1)
            rests.ended("thumb", time: 1.2)
            drag("pencil", &rests, from: 1)
            rests.ended("pencil", time: 1.55)
            XCTAssertEqual(try XCTUnwrap(rests.take(at: 1.6, within: 2)), 0.05, accuracy: 0.001, "a quick stroke stays quick: the thumb's long rest isn't its")
        }
    }

    func testAFingerFeedsTheHoldOnlyWhenFingersDraw() throws {
        var rests = TouchRests()
        rests.began("finger", isPencil: false, fingersDraw: false, at: start, time: 0)
        drag("finger", &rests, from: 0)
        rests.ended("finger", time: 1.3)
        XCTAssertNil(rests.take(at: 1.35, within: 2), "with Apple Pencil Only a finger never holds")

        rests.began("finger", isPencil: false, fingersDraw: true, at: start, time: 2)
        drag("finger", &rests, from: 2)
        rests.ended("finger", time: 3.3)
        XCTAssertEqual(try XCTUnwrap(rests.take(at: 3.35, within: 2)), 0.8, accuracy: 0.001, "a finger that draws holds like the Pencil")

        rests.began("pencil", isPencil: true, fingersDraw: true, at: start, time: 4)
        drag("pencil", &rests, from: 4)
        rests.ended("pencil", time: 5.1)
        rests.began("palm", isPencil: false, fingersDraw: true, at: CGPoint(x: 600, y: 700), time: 5.12)
        XCTAssertEqual(try XCTUnwrap(rests.take(at: 5.15, within: 2)), 0.6, accuracy: 0.001, "a palm landing as the Pencil lifts leaves its rest alone")
    }

    func testWhenFingersDrawOnlyAFingerAloneOnThePagesHolds() throws {
        var rests = TouchRests()
        rests.began("thumb", isPencil: false, fingersDraw: true, at: CGPoint(x: 20, y: 500), time: 0)
        rests.began("finger", isPencil: false, fingersDraw: true, at: start, time: 1)
        rests.ended("thumb", time: 1.2)
        drag("finger", &rests, from: 1)
        rests.ended("finger", time: 1.55)
        XCTAssertNil(rests.take(at: 1.6, within: 2, strokeBegan: 1), "a thumb that landed first lends the stroke no rest, and two fingers make no stroke")

        rests.began("finger", isPencil: false, fingersDraw: true, at: start, time: 2)
        drag("finger", &rests, from: 2)
        rests.began("thumb", isPencil: false, fingersDraw: true, at: CGPoint(x: 20, y: 500), time: 2.6)
        rests.ended("finger", time: 3.3)
        rests.ended("thumb", time: 3.4)
        XCTAssertNil(rests.take(at: 3.45, within: 2, strokeBegan: 2), "nor does one that lands alongside")

        rests.began("finger", isPencil: false, fingersDraw: true, at: start, time: 4)
        drag("finger", &rests, from: 4)
        rests.ended("finger", time: 5.3)
        XCTAssertEqual(try XCTUnwrap(rests.take(at: 5.35, within: 2, strokeBegan: 4.02)), 0.8, accuracy: 0.001, "a finger alone holds")
    }

    func testARestIsOnlyTheStrokesItsTouchDrew() throws {
        var rests = TouchRests()
        rests.began("pencil", isPencil: true, fingersDraw: false, at: start, time: 10)
        drag("pencil", &rests, from: 10)
        rests.ended("pencil", time: 11.1)
        XCTAssertNil(rests.take(at: 11.2, within: 2, strokeBegan: 3), "a stroke from before, brought back by Redo, isn't given the rest")

        rests.began("pencil", isPencil: true, fingersDraw: false, at: start, time: 12)
        drag("pencil", &rests, from: 12)
        rests.ended("pencil", time: 13.1)
        XCTAssertNil(rests.take(at: 13.5, within: 2, strokeBegan: 13.3), "nor is a stroke begun after the Pencil lifted")

        rests.began("pencil", isPencil: true, fingersDraw: false, at: start, time: 14)
        drag("pencil", &rests, from: 14)
        rests.ended("pencil", time: 15.1)
        XCTAssertEqual(try XCTUnwrap(rests.take(at: 15.15, within: 2, strokeBegan: 14.05)), 0.6, accuracy: 0.001, "the stroke the Pencil drew is")
    }

    func testOnlyAFigureOfThreeOrFourSidesRoundInkIsKeptRatherThanSelected() {
        let rough: [(CGFloat, CGFloat, CGFloat)] = [(0.03, 0.02, 0.01), (0.07, 0.05, 0.03), (0.15, 0.12, 0.06), (0.2, 0.15, 0.05), (0.25, 0.1, 0.03)]
        for lumps in rough {
            for (width, height) in [(220, 100), (300, 80), (160, 140)] as [(CGFloat, CGFloat)] {
                let shape = ShapeRecognizer.recognize(roughLoop(centre: CGPoint(x: 300, y: 300), width: width, height: height, lumps: lumps))
                XCTAssertNotNil(shape, "loops round words mostly read as shapes")
                XCTAssertFalse(PencilGestures.keepsFigure(shape), "but never with so few sides: \(lumps), \(width)×\(height) read as \(String(describing: shape))")
            }
        }
        let box = along([CGPoint(x: 150, y: 72), CGPoint(x: 236, y: 74), CGPoint(x: 234, y: 150), CGPoint(x: 76, y: 148), CGPoint(x: 78, y: 73), CGPoint(x: 140, y: 72)])
        let triangle = along([CGPoint(x: 200, y: 100), CGPoint(x: 320, y: 300), CGPoint(x: 90, y: 290), CGPoint(x: 198, y: 104)])
        let diamond = along([CGPoint(x: 200, y: 80), CGPoint(x: 330, y: 200), CGPoint(x: 200, y: 320), CGPoint(x: 70, y: 200), CGPoint(x: 198, y: 82)])
        for figure in [box, triangle, diamond] {
            XCTAssertTrue(PencilGestures.keepsFigure(ShapeRecognizer.recognize(figure)), "a box, a triangle and a diamond are kept")
        }
        XCTAssertFalse(PencilGestures.keepsFigure(ShapeRecognizer.recognize(ellipse(centre: CGPoint(x: 300, y: 300), a: 160, b: 70))))
        XCTAssertFalse(PencilGestures.keepsFigure(.polygon((0..<5).map { CGPoint(x: cos(CGFloat($0)), y: sin(CGFloat($0))) })))
        XCTAssertFalse(PencilGestures.keepsFigure(.line(.zero, CGPoint(x: 100, y: 0))))
        XCTAssertFalse(PencilGestures.keepsFigure(nil))
    }

    /// On a page, with nothing inside the shape: straightened as one undo step, and a second takes the stroke away.
    @MainActor
    func testAClosedShapeHeldOnBlankPaperIsStraightenedAndUndoGivesTheStrokeBack() async throws {
        let open = try await OpenPage.open(self, ink: [])
        let box = pencilStroke(along([CGPoint(x: 160, y: 100), CGPoint(x: 300, y: 104), CGPoint(x: 296, y: 240), CGPoint(x: 98, y: 236), CGPoint(x: 102, y: 98), CGPoint(x: 150, y: 101)]))
        let ring = pencilStroke(ellipse(centre: CGPoint(x: 300, y: 500), a: 100, b: 100))
        await open.draw(box, resting: 0.6)
        await open.draw(ring, resting: 0.6)
        XCTAssertEqual(open.session.mode, .writing, "with no ink inside it, the ring selects nothing")
        XCTAssertEqual(open.ink.count, 2)
        XCTAssertEqual(open.ink.map(\.path.count), [box, ring].compactMap { ShapeSnap.snapped($0)?.stroke.path.count }, "both are straightened")
        XCTAssertEqual(open.document.undoManager.undoActionName, "Straighten Shape")

        for (index, drawn) in [box, ring].enumerated().reversed() {
            open.document.undoManager.undo()
            try? await Task.sleep(for: .seconds(0.2))
            XCTAssertEqual(open.ink.count, index + 1)
            XCTAssertEqual(open.ink.last?.path.count, drawn.path.count, "undo gives the stroke back as it was drawn")
            open.document.undoManager.undo()
            try? await Task.sleep(for: .seconds(0.2))
            XCTAssertEqual(open.ink.count, index, "and a second takes it away")
        }
    }
}
