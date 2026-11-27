import XCTest
import PencilKit
@testable import OwlLuna

/// Exporting SVGs: a file for each page of the chosen range, named and numbered like the images, each of the page's size.
@MainActor
final class SVGExportTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
    private let fileManager = FileManager.default

    private func input(_ title: String = "Notes", pages: [NotebookPage], saved: [UUID: PKDrawing] = [:], unsaved: [UUID: PKDrawing] = [:]) async throws -> NotebookExporter.Input {
        let id = UUID()
        let package = NotebookPackage(root: temporaryRoot(self), id: id)
        let manifest = NotebookManifest(id: id, title: title, defaults: paper, pages: pages)
        try await package.create(manifest)
        if !saved.isEmpty { _ = try await package.write(SaveSnapshot(manifest: manifest, ink: saved)) }
        return NotebookExporter.Input(title: title, pages: pages, inMemoryInk: unsaved, package: package)
    }

    private func newPages(_ count: Int) -> [NotebookPage] { (0..<count).map { _ in paper.newPage() } }

    private func exportSVGs(_ source: NotebookExporter.Input, options: NotebookExporter.Options = .init()) async throws -> [URL] {
        let urls = try await NotebookExporter.exportSVG(source, options: options) { _ in }
        if let folder = urls.first?.deletingLastPathComponent() { addTeardownBlock { try? FileManager.default.removeItem(at: folder) } }
        return urls
    }

    private func finish(_ job: ExportJob) async throws -> [URL] {
        let deadline = Date().addingTimeInterval(60)
        while job.state == .running || job.state == .choosing, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard case .finished(let urls) = job.state else { XCTFail("the export finishes: \(job.state)"); return [] }
        if let folder = urls.first?.deletingLastPathComponent() { addTeardownBlock { try? FileManager.default.removeItem(at: folder) } }
        return urls
    }

    private func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path(percentEncoded: false)) }

    private func exportFolders() -> Set<String> {
        let names = (try? fileManager.contentsOfDirectory(atPath: fileManager.temporaryDirectory.path(percentEncoded: false))) ?? []
        return Set(names.filter { $0.hasPrefix("export-") && !$0.hasPrefix("export-tests-") })
    }

    /// The root of an SVG file, its title and what is in its ink group, read the way another app would.
    private final class Reader: NSObject, XMLParserDelegate {
        var root: String?
        var attributes: [String: String] = [:]
        var title = ""
        var inkGroups = 0
        var ink: [String] = []
        private var path: [String] = []
        private var inkDepth: Int?
        private var inTitle = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
            if root == nil { root = name; attributes = attributeDict }
            path.append(name)
            inTitle = name == "title" && path.count == 2
            if inkDepth != nil {
                ink.append(name + attributeDict.sorted { $0.key < $1.key }.map { " \($0.key)=\($0.value)" }.joined())
            } else if name == "g", attributeDict["id"] == "ink" {
                inkGroups += 1
                inkDepth = path.count
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if path.count == inkDepth { inkDepth = nil }
            path.removeLast()
            inTitle = false
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inTitle { title += string }
        }
    }

    private func read(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> Reader {
        let parser = XMLParser(data: try Data(contentsOf: url))
        let reader = Reader()
        parser.delegate = reader
        XCTAssertTrue(parser.parse(), "\(url.lastPathComponent): \(parser.parserError?.localizedDescription ?? "")", file: file, line: line)
        return reader
    }

    private func ink(of urls: [URL]) throws -> [[String]] { try urls.map { try read($0).ink } }

    func testPageNumbersAreSharedWithTheImageNames() {
        XCTAssertEqual(NotebookExporter.pageNumber(0, of: 1), "", "a lone page has no number")
        XCTAssertEqual(NotebookExporter.pageNumber(0, of: 3), " 1")
        XCTAssertEqual(NotebookExporter.pageNumber(6, of: 12), " 07")
        XCTAssertEqual(NotebookExporter.pageNumber(8, of: 100), " 009")
        XCTAssertEqual(NotebookExporter.pageNumber(99, of: 100), " 100")
        XCTAssertEqual(NotebookExporter.fileName("Notes", number: NotebookExporter.pageNumber(0, of: 12), extension: "svg"), "Notes 01.svg")
    }

    func testFilesAreNamedAndNumberedLikeTheImages() async throws {
        let twelve = try await exportSVGs(try await input(pages: newPages(12)))
        XCTAssertEqual(twelve.map(\.lastPathComponent), (1...12).map { "Notes \(String(format: "%02d", $0)).svg" })
        XCTAssertEqual(Set(twelve.map { $0.deletingLastPathComponent() }).count, 1, "all in one folder")
        XCTAssertTrue(twelve[0].deletingLastPathComponent().lastPathComponent.hasPrefix("export-"))
        XCTAssertTrue(twelve.allSatisfy(exists))

        let source = try await input(pages: newPages(3))
        let svgs = try await exportSVGs(source)
        let images = try await NotebookExporter.exportImages(source) { _ in }
        addTeardownBlock { try? FileManager.default.removeItem(at: images[0].deletingLastPathComponent()) }
        XCTAssertEqual(svgs.map { $0.deletingPathExtension().lastPathComponent }, images.map { $0.deletingPathExtension().lastPathComponent })
        XCTAssertEqual(svgs.map(\.pathExtension), ["svg", "svg", "svg"])

        let lone = try await exportSVGs(try await input("Biology: Cells", pages: newPages(1)))
        XCTAssertEqual(lone.map(\.lastPathComponent), ["Biology- Cells.svg"], "a lone page has no number")
    }

    func testEachFileIsAnSVGOfItsPageWithTheNotebookAndPageInItsTitle() async throws {
        var pages = [
            PageDefaults(template: .blank, paperColor: .white, pageSize: .letter).newPage(),
            PageDefaults(template: .grid, paperColor: .white, pageSize: .a4).newPage(),
            PageDefaults(template: .wideRuled, paperColor: .white, pageSize: .widescreen).newPage(),
        ]
        pages[1].bookmark = "Cells & <nuclei>"
        let title = "Bio & Chem <1>"
        let urls = try await exportSVGs(try await input(title, pages: pages))
        XCTAssertEqual(urls.count, 3)
        for (index, url) in urls.enumerated() {
            let page = pages[index], file = try read(url)
            XCTAssertEqual(file.root, "svg", url.lastPathComponent)
            XCTAssertEqual(file.attributes["xmlns"], "http://www.w3.org/2000/svg")
            XCTAssertEqual(Double(file.attributes["width"] ?? "") ?? 0, Double(page.size.width), accuracy: 0.01, "width of page \(index + 1)")
            XCTAssertEqual(Double(file.attributes["height"] ?? "") ?? 0, Double(page.size.height), accuracy: 0.01, "height of page \(index + 1)")
            let box = (file.attributes["viewBox"] ?? "").split(separator: " ").compactMap { Double($0) }
            XCTAssertEqual(box.count, 4, "a viewBox of four numbers")
            if box.count == 4 {
                XCTAssertEqual(box[0], 0)
                XCTAssertEqual(box[1], 0)
                XCTAssertEqual(box[2], Double(page.size.width), accuracy: 0.01)
                XCTAssertEqual(box[3], Double(page.size.height), accuracy: 0.01)
            }
            XCTAssertEqual(file.title, title + ", " + page.bookmarkTitle(number: index + 1), "the notebook and the page, as written")
            XCTAssertEqual(file.inkGroups, 1, "one group for the ink")
        }
        XCTAssertNotEqual(pages[0].size, pages[1].size)
        XCTAssertNotEqual(pages[1].size, pages[2].size)

        let single = try await exportSVGs(try await input(title, pages: [pages[0]]))
        XCTAssertEqual(try read(single[0]).title, title, "a notebook of one page is titled with its name alone")
    }

    func testOneFileIsWrittenForEachPageOfTheRangeChosen() async throws {
        var pages = newPages(5)
        pages[2].bookmark = "Mitosis"
        let whole = try await input(pages: pages)

        let some = try await exportSVGs(whole.narrowed(to: 1...3))
        XCTAssertEqual(some.map(\.lastPathComponent), ["Notes 1.svg", "Notes 2.svg", "Notes 3.svg"])
        XCTAssertEqual(try some.map { try read($0).title }, [2, 3, 4].map { "Notes, " + pages[$0 - 1].bookmarkTitle(number: $0) },
                       "pages keep their place in the notebook")
        XCTAssertEqual(try read(some[1]).title, "Notes, Mitosis")

        let one = try await exportSVGs(whole.narrowed(to: 3...3))
        XCTAssertEqual(one.map(\.lastPathComponent), ["Notes.svg"])
        XCTAssertEqual(try read(one[0]).title, "Notes, " + pages[3].bookmarkTitle(number: 4))

        let all = try await exportSVGs(whole.narrowed(to: 0...4))
        XCTAssertEqual(all.count, 5)
    }

    func testTheChoicesNarrowAnExportToThePagesChosen() async throws {
        let source = try await input(pages: newPages(5))
        let here = ExportJob(inputs: [source], format: .svg, choosing: true, current: 2, thisPage: true)
        XCTAssertEqual(here.state, .choosing)
        XCTAssertTrue(here.asks)
        XCTAssertEqual(here.range, 2...2, "This Page has the page on show chosen")
        here.start()
        let page = try await finish(here)
        XCTAssertEqual(page.map(\.lastPathComponent), ["Notes.svg"])
        XCTAssertEqual(try read(page[0]).title, "Notes, " + source.pages[2].bookmarkTitle(number: 3))

        let every = ExportJob(inputs: [source], format: .svg, choosing: true, current: 2)
        XCTAssertEqual(every.range, 0...4, "Every Page has them all chosen")
        every.range = 1...3
        every.start()
        let some = try await finish(every)
        XCTAssertEqual(some.map(\.lastPathComponent), ["Notes 1.svg", "Notes 2.svg", "Notes 3.svg"])
        every.close()
        here.close()
    }

    func testInkTheEditorHoldsUnsavedIsWhatIsWritten() async throws {
        let pages = newPages(3)
        let written = PKDrawing(strokes: [stroke(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 200, y: 40))])
        let typed = PKDrawing(strokes: [
            stroke(from: CGPoint(x: 30, y: 100), to: CGPoint(x: 300, y: 120)),
            stroke(from: CGPoint(x: 30, y: 150), to: CGPoint(x: 300, y: 170)),
            stroke(from: CGPoint(x: 30, y: 200), to: CGPoint(x: 300, y: 220), width: 6),
        ])
        let id = pages[0].id

        let both = try await input(pages: pages, saved: [id: written], unsaved: [id: typed])
        XCTAssertEqual(both.ink(for: pages[0]).strokes.count, 3, "what the editor holds wins over what is saved")
        XCTAssertEqual(both.ink(for: pages[1]).strokes.count, 0)
        let cleared = try await input(pages: pages, saved: [id: written], unsaved: [id: PKDrawing()])
        XCTAssertEqual(cleared.ink(for: pages[0]).strokes.count, 0, "a page cleared and not yet saved is blank")
        let savedOnly = try await input(pages: pages, saved: [id: written])
        XCTAssertEqual(savedOnly.ink(for: pages[0]).strokes.count, 1, "saved ink is read when the editor holds none")

        let typedOnly = try await input(pages: pages, unsaved: [id: typed])
        let blank = try await input(pages: pages)
        let fromBoth = try await exportSVGs(both), fromTyped = try await exportSVGs(typedOnly)
        let fromCleared = try await exportSVGs(cleared), fromBlank = try await exportSVGs(blank)
        XCTAssertEqual(try ink(of: fromBoth), try ink(of: fromTyped), "the saved stroke isn't written under the unsaved ones")
        XCTAssertEqual(try ink(of: fromCleared), try ink(of: fromBlank), "nothing of a saved page the editor has cleared")
    }

    func testAnSVGJobFinishesWithAFilePerPageAndItsFolderGoesWhenItCloses() async throws {
        let job = ExportJob(input: try await input(pages: newPages(4)), format: .svg)
        let urls = try await finish(job)
        XCTAssertEqual(urls.count, 4)
        XCTAssertEqual(job.progress, 1, accuracy: 0.001)
        XCTAssertTrue(urls.allSatisfy { $0.pathExtension == "svg" && exists($0) })
        XCTAssertEqual(job.shared, urls, "Share hands over the SVG files")
        XCTAssertFalse(job.offersRecordings)
        let folder = urls[0].deletingLastPathComponent()

        job.close()
        let deadline = Date().addingTimeInterval(30)
        while exists(folder), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(exists(folder), "the folder goes when the sheet closes")
    }

    func testACancelledExportLeavesNoFolder() async throws {
        let before = exportFolders()
        let source = try await input(pages: newPages(20))
        let task = Task { try await NotebookExporter.exportSVG(source) { _ in withUnsafeCurrentTask { $0?.cancel() } } }
        do {
            _ = try await task.value
            XCTFail("it is cancelled after the first page")
        } catch is CancellationError {
        }
        XCTAssertTrue(exportFolders().subtracting(before).isEmpty, "the folder of the pages already written goes with it")

        let job = ExportJob(input: try await input("Long", pages: newPages(40)), format: .svg)
        job.close()
        XCTAssertEqual(job.state, .cancelled)
        try await Task.sleep(for: .seconds(1))
        let deadline = Date().addingTimeInterval(20)
        while !exportFolders().subtracting(before).isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(exportFolders().subtracting(before).isEmpty, "a job closed while it runs leaves no new folder")
    }
}
