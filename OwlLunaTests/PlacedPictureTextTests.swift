import XCTest
import PencilKit
@testable import OwlLuna

/// Words printed in a picture placed on a page are read for search, once for each picture and crop, and found where they lie.
@MainActor
final class PlacedPictureTextTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
    /// The sample sheet without its title: what shows is "Revenue grew in the north." and "Costs held steady."
    private let crop = CGRect(x: 0.05, y: 0.16, width: 0.9, height: 0.3)

    /// Recognition runs at utility priority, so a test asks for it from a task of that priority, as ScanTests does.
    private func index(_ package: NotebookPackage, _ pages: [NotebookPage]) async -> String {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                continuation.resume(returning: await HandwritingIndexer.shared.index(HandwritingIndexer.Job(package: package, pages: pages)))
            }
        }
    }

    /// The sample sheet, a quarter of a point to each of its pixels, cropped, turned a quarter and centred at (300, 400).
    private func makeNotebook(root: StorageRoot) async throws -> (NotebookPackage, NotebookPage) {
        let package = NotebookPackage(root: root, id: UUID())
        let file = try await package.writeAsset(XCTUnwrap(DocumentScan.samples()[0].pngData()), ext: "png")
        var item = PageItem(content: .image(file: file), center: CGPoint(x: 155, y: 219.25), size: CGSize(width: 310, height: 438.5)).cropped(to: crop)
        item.center = CGPoint(x: 300, y: 400)
        item.rotation = .pi / 2
        var page = paper.newPage()
        page.items = [item]
        try await package.create(NotebookManifest(id: package.id, title: "Pictures", defaults: paper, pages: [page]))
        return (package, page)
    }

    private func finish(_ finder: NotebookFinder) async {
        for _ in 0..<400 where finder.isSearching { try? await Task.sleep(for: .milliseconds(25)) }
    }

    func testWordsInAPlacedPictureAreSearchable() async throws {
        let (package, page) = try await makeNotebook(root: temporaryRoot(self))
        let header = HandwritingIndexer.header(for: page)
        XCTAssertTrue(header.hasPrefix("#ink:none+pic"))
        XCTAssertEqual(HandwritingIndexer.header(for: paper.newPage()), "#ink:none\n", "a page without pictures is stamped as before")

        let text = await index(package, [page])
        try XCTSkipIf(text.isEmpty, "text recognition isn't available on this simulator")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("revenue grew"), "read as \(text)")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("costs held"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("quarterly"), "the title is cropped away")
        let saved = await package.readText(page.id)
        XCTAssertEqual(saved?.hasPrefix(header), true)
        let kept = await package.readPictureText(page.id)
        XCTAssertEqual(kept.keys.sorted(), [try XCTUnwrap(page.items[0].readingKey)])
    }

    func testThePageIsStampedAnewWhenAPictureOrItsCropChanges() {
        let item = PageItem(content: .image(file: "A.png"), center: CGPoint(x: 200, y: 200), size: CGSize(width: 200, height: 100))
        let other = PageItem(content: .image(file: "B.png"), center: item.center, size: item.size)
        func header(_ items: PageItem...) -> String {
            var page = paper.newPage()
            page.items = items
            return HandwritingIndexer.header(for: page)
        }
        let placed = header(item)

        var moved = item.scaled(by: 1.5, limit: 1000)
        moved.center.x += 40
        moved.rotation = 0.3
        let star = PageItem(content: .sticker(Sticker.star.rawValue), center: .zero, size: CGSize(width: 64, height: 64))
        XCTAssertEqual(header(star, moved, item), placed, "moving, turning, resizing or repeating it shows no new words")

        XCTAssertNotEqual(header(item.cropped(to: crop)), placed, "cropped")
        XCTAssertNotEqual(header(item.cropped(to: crop.insetBy(dx: 0.01, dy: 0))), header(item.cropped(to: crop)), "cropped again")
        XCTAssertNotEqual(header(other), placed, "replaced")
        XCTAssertNotEqual(header(item, other), placed, "another added")
        XCTAssertEqual(header(), "#ink:none\n", "removed")
    }

    func testAPictureAlreadyReadIsNotReadAgain() async throws {
        let (package, page) = try await makeNotebook(root: temporaryRoot(self))
        let key = try XCTUnwrap(page.items[0].readingKey)
        // What this picture showed is kept as words it doesn't hold, so they can only come from what was kept.
        try await package.writePictureText([key: ["Zebra crossing ahead"]], pageID: page.id)
        var text = await index(package, [page])
        XCTAssertEqual(text, "Zebra crossing ahead")

        // Typing on the page, or writing on it, reads the page again but not its picture.
        var typed = page
        typed.items.append(PageItem(content: .text(TextBox(string: "Lab notes")), center: CGPoint(x: 300, y: 700), size: CGSize(width: 200, height: 40)))
        text = await index(package, [typed])
        XCTAssertEqual(text, "Zebra crossing ahead Lab notes", "a page's words are on one line")
        var manifest = try await package.readManifest().manifest
        manifest.pages = [typed]
        let ink = PKDrawing(strokes: BlockLetters.strokes("HELLO", origin: CGPoint(x: 150, y: 760)))
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: [typed.id: ink]))
        let written = try await package.readManifest().manifest.pages[0]
        XCTAssertNotNil(written.inkHash)
        text = await index(package, [written])
        let reread = await package.readText(written.id) ?? ""
        try XCTSkipUnless(reread.hasPrefix(HandwritingIndexer.header(for: written)), "text recognition isn't available on this simulator")
        XCTAssertTrue(text.hasPrefix("Zebra crossing ahead Lab notes"), "read as \(text)")

        // Cropped afresh, it is read again, and only what it shows now is kept.
        var recropped = written
        recropped.items[0] = recropped.items[0].cropped(to: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        text = await index(package, [recropped])
        XCTAssertFalse(text.contains("Zebra"))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("quarterly report"), "read as \(text)")
        let kept = await package.readPictureText(page.id)
        XCTAssertEqual(kept.keys.sorted(), [try XCTUnwrap(recropped.items[0].readingKey)])

        var removed = recropped
        removed.items.removeFirst()
        text = await index(package, [removed])
        XCTAssertFalse(text.localizedCaseInsensitiveContains("quarterly"))
    }

    func testWordsInATurnedCroppedPictureAreFoundWhereTheyLie() async throws {
        let root = temporaryRoot(self)
        let (package, page) = try await makeNotebook(root: root)
        let document = try await NotebookDocument.open(package.id, root: root)
        let finder = NotebookFinder(document: document)
        finder.delay = .zero
        finder.search("revenue")
        await finish(finder)
        try XCTSkipIf(finder.matches.isEmpty, "text recognition isn't available on this simulator")
        XCTAssertEqual(finder.matches.count, 1)
        let rect = finder.matches[0].rect
        // In the cropped picture, 279 × 131.5 pt, the word is 14.5 pt from the left and 23.3 pt from the top. Turned a quarter
        // clockwise about (300, 400), it runs down the page from y 275, 42.4 pt right of the centre.
        XCTAssertEqual(rect.minY, 275, accuracy: 6)
        XCTAssertEqual(rect.midX, 342.4, accuracy: 8)
        XCTAssertGreaterThan(rect.height, rect.width * 2, "a word turned on its side")

        finder.search("quarterly")
        await finish(finder)
        XCTAssertTrue(finder.matches.isEmpty, "the title is cropped away")

        // A picture whose kept reading doesn't hold the words is passed over.
        let key = try XCTUnwrap(page.items[0].readingKey)
        try await package.writePictureText([key: ["Costs held steady."]], pageID: page.id)
        finder.search("revenue ")
        await finish(finder)
        XCTAssertTrue(finder.matches.isEmpty)
    }
}
