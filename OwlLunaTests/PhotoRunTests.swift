import XCTest
@testable import OwlLuna

final class PhotoRunTests: XCTestCase {
    private let page = CGRect(x: 0, y: 0, width: 612, height: 792).insetBy(dx: PhotoRun.margin, dy: PhotoRun.margin)
    private let photo = CGSize(width: 4032, height: 3024)

    func testAPhotoIsSizedToWhatIsShowingOfThePage() {
        let whole = PhotoRun(visible: page, bounds: page)
        let corner = PhotoRun(visible: CGRect(origin: page.origin, size: CGSize(width: page.width / 2, height: page.height / 2)), bounds: page)
        XCTAssertEqual(whole.size(for: photo).width, ((page.width - PhotoRun.gap) / 2).rounded(), accuracy: 1)
        XCTAssertEqual(corner.size(for: photo).width, whole.size(for: photo).width / 2, accuracy: PhotoRun.gap / 2, "zoomed in twice as far, half as big")
    }

    func testTheFirstLandsAtTheTopLeftOfWhatIsShowing() throws {
        var run = PhotoRun(visible: CGRect(x: 300, y: 400, width: 306, height: 396), bounds: page)
        let frame = try XCTUnwrap(run.place(run.size(for: photo)))
        XCTAssertEqual(frame.origin, CGPoint(x: 300, y: 400))
    }

    func testAWholePageHoldsSixLandscapePhotos() {
        var run = PhotoRun(visible: CGRect(x: 0, y: 0, width: 612, height: 792), bounds: page)
        let size = run.size(for: photo)
        var count = 0
        while run.place(size) != nil { count += 1 }
        XCTAssertEqual(count, 6)
    }

    func testTheNextGoBelowThenBesideThenOnANewPage() throws {
        var run = PhotoRun(visible: CGRect(x: 0, y: 0, width: 612, height: 792), bounds: page)
        let size = CGSize(width: 180, height: 135)
        var frames: [CGRect] = []
        while let frame = run.place(size) { frames.append(frame) }
        XCTAssertGreaterThan(frames.count, 4)
        XCTAssertEqual(frames[1].minX, frames[0].minX)
        XCTAssertEqual(frames[1].minY, frames[0].maxY + PhotoRun.gap)
        let beside = try XCTUnwrap(frames.first { $0.minX > frames[0].maxX })
        XCTAssertEqual(beside.minY, frames[0].minY, "a new column starts level with the first")
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(page.contains(frame), "\(frame) stays on the page")
            for other in frames[..<index] { XCTAssertFalse(frame.intersects(other), "\(frame) overlaps \(other)") }
        }
        run.turnPage(to: page)
        XCTAssertEqual(run.place(size)?.origin, page.origin, "a new page starts at its top left")
    }
}
