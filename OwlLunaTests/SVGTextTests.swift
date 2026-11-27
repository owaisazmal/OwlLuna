import XCTest
@testable import OwlLuna

/// The pieces SVG writers share: numbers, escaped text, colours and path data.
final class SVGTextTests: XCTestCase {
    func testNumbersAreShort() {
        XCTAssertEqual(SVGText.number(12), "12")
        XCTAssertEqual(SVGText.number(0.5), "0.5")
        XCTAssertEqual(SVGText.number(3.14159), "3.14")
        XCTAssertEqual(SVGText.number(-0.001), "0")
        XCTAssertEqual(SVGText.number(-7.25), "-7.25")
        XCTAssertEqual(SVGText.number(1.999), "2")
        XCTAssertEqual(SVGText.number(.nan), "0")
        XCTAssertEqual(SVGText.number(1.05), "1.05")
        XCTAssertEqual(SVGText.number(100.1), "100.1")
        XCTAssertEqual(SVGText.number(-0.005), "-0.01")
        XCTAssertEqual(SVGText.number(-0.5), "-0.5")
        XCTAssertEqual(SVGText.number(.infinity), "0")
        XCTAssertEqual(SVGText.number(123456.789), "123456.79")
    }

    func testTextIsEscaped() {
        XCTAssertEqual(SVGText.escaped("Tom & \"Jerry\" <3>"), "Tom &amp; &quot;Jerry&quot; &lt;3&gt;")
        XCTAssertEqual(SVGText.escaped("a\u{0}b\u{8}c\nd"), "abc\nd")
    }

    func testColoursAreHexWithOpacity() {
        let red = SVGText.color(UIColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        XCTAssertEqual(red.hex, "#ff0000")
        XCTAssertEqual(red.opacity, 0.5, accuracy: 0.001)
        XCTAssertEqual(SVGText.color(.white).hex, "#ffffff")
        XCTAssertEqual(SVGText.color(UIColor(white: 0.2, alpha: 1)).hex, "#333333")
    }

    func testPathData() {
        XCTAssertEqual(SVGText.path([CGPoint(x: 1, y: 2), CGPoint(x: 3.5, y: 4)]), "M1 2L3.5 4")
        XCTAssertEqual(SVGText.path([CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 4)], closed: true), "M0 0L4 0L4 4Z")
        XCTAssertEqual(SVGText.path([]), "")
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1, y: 1))
        path.addQuadCurve(to: CGPoint(x: 3, y: 1), control: CGPoint(x: 2, y: 0))
        path.addCurve(to: CGPoint(x: 5, y: 5), control1: CGPoint(x: 4, y: 2), control2: CGPoint(x: 5, y: 3))
        path.closeSubpath()
        XCTAssertEqual(SVGText.path(path), "M1 1Q2 0 3 1C4 2 5 3 5 5Z")
    }
}
