import XCTest
@testable import OwlLuna

/// The size strip's scale: every whole point has its own place, the named sizes fall where the card marks them, and
/// the ends hold.
final class TextSizeStripTests: XCTestCase {
    func testEveryWholePointComesBackFromItsPlace() {
        for points in 8...200 {
            let size = CGFloat(points)
            XCTAssertEqual(TextSizeScale.size(at: TextSizeScale.place(of: size)), size, "\(points) pt")
        }
    }

    func testThePlacesRiseWithTheSize() {
        let places = (8...200).map { TextSizeScale.place(of: CGFloat($0)) }
        XCTAssertEqual(places.first, 0)
        XCTAssertEqual(places.last ?? 0, 1, accuracy: 1e-9)
        XCTAssertTrue(zip(places, places.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testTheNamedSizesFallInOrderWithTheMostRoomBetweenThem() {
        let places = TextBox.sizes.map { TextSizeScale.place(of: $0.points) }
        XCTAssertEqual(places, places.sorted())
        for (place, expected) in zip(places, [0.15, 0.23, 0.34, 0.45]) {
            XCTAssertEqual(place, expected, accuracy: 0.01)
        }
        let body = TextSizeScale.place(of: 18) - TextSizeScale.place(of: 17)
        let poster = TextSizeScale.place(of: 151) - TextSizeScale.place(of: 150)
        XCTAssertGreaterThan(body, poster * 8, "a point at Body takes far more of the strip than one at 150")
    }

    func testTheEndsHold() {
        XCTAssertEqual(TextSizeScale.size(at: 0), 8)
        XCTAssertEqual(TextSizeScale.size(at: 1), 200)
        XCTAssertEqual(TextSizeScale.size(at: -0.4), 8)
        XCTAssertEqual(TextSizeScale.size(at: 1.7), 200)
        XCTAssertEqual(TextSizeScale.place(of: 2), 0)
        XCTAssertEqual(TextSizeScale.place(of: 400), 1)
    }

    func testAPlaceBetweenTwoPointsGoesToTheNearer() {
        let seventeen = TextSizeScale.place(of: 17), eighteen = TextSizeScale.place(of: 18)
        XCTAssertEqual(TextSizeScale.size(at: seventeen + (eighteen - seventeen) * 0.3), 17)
        XCTAssertEqual(TextSizeScale.size(at: seventeen + (eighteen - seventeen) * 0.7), 18)
        XCTAssertEqual(TextSizeScale.size(at: TextSizeScale.place(of: 19.3)), 19, "a size from the corner handle sits between its two points")
    }

    func testTheReadOutKeepsATenthOnlyBetweenWholePoints() {
        XCTAssertEqual(TextBox.pointsLabel(21), String(localized: "\(21) pt"))
        XCTAssertTrue(TextBox.pointsLabel(19.3).hasPrefix(19.3.formatted(.number.precision(.fractionLength(1)))))
        XCTAssertNotEqual(TextBox.pointsLabel(19.96), TextBox.pointsLabel(20), "nearly 20 isn't read as 20")
    }
}
