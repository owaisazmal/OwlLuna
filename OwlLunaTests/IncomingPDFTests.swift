import XCTest
import SwiftData
import UniformTypeIdentifiers
@testable import OwlLuna

/// PDFs shared from Files, dropped on the shelf or dropped on the app's icon come in through the same import, and the
/// copies made for the app go once they are in.
@MainActor
final class IncomingPDFTests: XCTestCase {
    private var container: ModelContainer?

    private func makeStore() throws -> LibraryStore {
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        self.container = container
        return LibraryStore(root: temporaryRoot(self), context: container.mainContext)
    }

    private func pdf(_ name: String, pages: Int, in folder: URL? = nil) throws -> URL {
        let folder = folder ?? temporaryRoot(self).url
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(name).pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: PageSize.letter.points)).writePDF(to: url) { context in
            for _ in 0..<pages { context.beginPage() }
        }
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    func testAFilePDFIsOneToImportAndALinkIsNot() throws {
        XCTAssertTrue(IncomingPDFs.isPDF(try pdf("Lecture", pages: 1)))
        XCTAssertFalse(IncomingPDFs.isPDF(URL(string: "owlluna://today")!))
        XCTAssertFalse(IncomingPDFs.isPDF(temporaryRoot(self).url.appending(path: "notes.txt")))
        XCTAssertTrue(IncomingPDFs.isPDF(temporaryRoot(self).url.appending(path: "Scan.PDF")))
    }

    func testTheSystemsInboxCopyGoesAfterImportAndAChosenFileStays() async throws {
        let store = try makeStore()
        let root = temporaryRoot(self).url
        let inboxes = [root.appending(path: "Inbox", directoryHint: .isDirectory), root.appending(path: "tmp/com.owais.OwlLuna-Inbox", directoryHint: .isDirectory)]
        let holding = root.appending(path: "Incoming", directoryHint: .isDirectory)
        let shared = try pdf("Shared", pages: 2, in: inboxes[0]), opened = try pdf("Opened", pages: 1, in: inboxes[1])
        let chosen = try pdf("Chosen", pages: 1)

        let run = PDFImportRun()
        run.add([shared, opened, chosen]) { url, password, progress in
            defer { IncomingPDFs.discard(url, inboxes: inboxes, holding: holding) }
            try await store.importPDF(from: url, folder: nil, password: password, progress: progress)
        }
        await run.finish()

        XCTAssertTrue(run.missed.isEmpty)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<NotebookRecord>()), 3)
        XCTAssertFalse(exists(shared), "the copy the system made is the app's to remove")
        XCTAssertFalse(exists(opened))
        XCTAssertTrue(exists(inboxes[1]), "the system's own folder is left to it")
        XCTAssertTrue(exists(chosen), "a file the user chose is never touched")
    }

    func testACopyThatCouldntBeReadGoesTooWithItsDropFolder() throws {
        let root = temporaryRoot(self).url
        let inboxes = [root.appending(path: "Inbox", directoryHint: .isDirectory)], holding = root.appending(path: "Incoming", directoryHint: .isDirectory)
        let folder = holding.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dropped = folder.appending(path: "Broken.pdf")
        try Data("not a pdf".utf8).write(to: dropped)

        IncomingPDFs.discard(dropped, inboxes: inboxes, holding: holding)
        XCTAssertFalse(exists(dropped))
        XCTAssertFalse(exists(folder), "the folder made for the drop goes with it")
        XCTAssertTrue(exists(holding))
    }

    func testDroppedProvidersAreCopiedUnderTheirNamesAndOtherTypesLeftOut() async throws {
        let holding = temporaryRoot(self).url.appending(path: "Incoming", directoryHint: .isDirectory)
        let first = try pdf("Lecture 3 notes", pages: 1), second = try pdf("Syllabus", pages: 2)
        let text = temporaryRoot(self).url.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)
        // A drag from Files names each file; a provider made from a URL doesn't on its own.
        let providers = [first, text, second].map { url in
            let provider = NSItemProvider(contentsOf: url)!
            provider.suggestedName = url.lastPathComponent
            return provider
        }

        let copies = await IncomingPDFs.receive(providers, holding: holding)

        XCTAssertEqual(copies.map(\.lastPathComponent), ["Lecture 3 notes.pdf", "Syllabus.pdf"])
        XCTAssertEqual(copies.map { IncomingPDFs.isCopy($0, holding: holding) }, [true, true])
        XCTAssertEqual(try copies.map { try Data(contentsOf: $0) }, try [first, second].map { try Data(contentsOf: $0) })
        XCTAssertTrue(exists(first), "the dropped file itself is never touched")
    }
}
