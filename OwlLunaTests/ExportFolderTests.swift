import XCTest
import PDFKit
@testable import OwlLuna

/// Exports and backups are named to fit the file system, and leave nothing in tmp once they have been shared.
@MainActor
final class ExportFolderTests: XCTestCase {
    private let paper = PageDefaults(template: .grid, paperColor: .white, pageSize: .letter)
    private let fileManager = FileManager.default

    private func scratch() throws -> URL {
        let folder = fileManager.temporaryDirectory.appending(path: "export-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path(percentEncoded: false)) }

    /// The folder goes on a utility-priority task, which a busy CI runner can hold back for seconds.
    private func waitUntilGone(_ url: URL) async throws -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while exists(url), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return !exists(url)
    }

    private func input(_ title: String, pages count: Int) async throws -> NotebookExporter.Input {
        let id = UUID()
        let package = NotebookPackage(root: temporaryRoot(self), id: id)
        let pages = (0..<count).map { _ in paper.newPage() }
        try await package.create(NotebookManifest(id: id, title: title, defaults: paper, pages: pages))
        return NotebookExporter.Input(title: title, pages: pages, inMemoryInk: [:], package: package)
    }

    private func exportFolders() -> Set<String> {
        let names = (try? fileManager.contentsOfDirectory(atPath: fileManager.temporaryDirectory.path(percentEncoded: false))) ?? []
        return Set(names.filter { $0.hasPrefix("export-") && !$0.hasPrefix("export-tests-") })
    }

    private func stem(_ name: String, tail: String) throws -> String {
        XCTAssertTrue(name.hasSuffix(tail), name)
        return String(name.dropLast(tail.count))
    }

    private func assertFits(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(name.utf8.count, NotebookExporter.nameLimit, file: file, line: line)
        XCTAssertLessThanOrEqual(name.decomposedStringWithCanonicalMapping.utf8.count, NotebookExporter.nameLimit, "stored decomposed too", file: file, line: line)
        XCTAssertLessThanOrEqual(NotebookExporter.nameLimit, 255)
    }

    func testALongTitleIsCutToFitAndKeepsItsExtension() throws {
        XCTAssertEqual(NotebookExporter.fileName("Bio: Cells", extension: "pdf"), "Bio- Cells.pdf", "a short title is only cleaned")
        XCTAssertEqual(NotebookExporter.fileName("  \n", extension: "pdf"), "Untitled.pdf")
        XCTAssertEqual(NotebookExporter.fileName("Bio", number: " 07", extension: "png"), "Bio 07.png")

        let title = String(repeating: "Lecture notes on thermodynamics ", count: 40)
        let name = NotebookExporter.fileName(title, extension: "pdf")
        assertFits(name)
        let kept = try stem(name, tail: ".pdf")
        XCTAssertTrue(title.hasPrefix(kept))
        XCTAssertGreaterThan(kept.utf8.count, 200, "as much of the title as fits is kept")
        XCTAssertFalse(kept.hasSuffix(" "), "no space is left before the extension")

        let page = NotebookExporter.fileName(title, number: " 012", extension: "png")
        assertFits(page)
        XCTAssertTrue(page.hasSuffix(" 012.png"), "the page number survives the cut")

        let folder = try scratch()
        XCTAssertThrowsError(try Data([1]).write(to: folder.appending(path: title + ".pdf")), "the name the title made before is too long to write")
        XCTAssertNoThrow(try Data([1]).write(to: folder.appending(path: name)))
        XCTAssertNoThrow(try Data([1]).write(to: folder.appending(path: page)))
    }

    func testANonLatinTitleIsCutAtAWholeCharacter() throws {
        let folder = try scratch()
        let japanese = String(repeating: "東京大学の講義ノート", count: 30)
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 30)
        let accented = String(repeating: "e\u{301}", count: 200)
        let korean = String(repeating: "한국어 필기 ", count: 60)
        for title in [japanese, family, accented, korean] {
            let name = NotebookExporter.fileName(title, extension: "pdf")
            assertFits(name)
            let kept = try stem(name, tail: ".pdf")
            XCTAssertFalse(kept.isEmpty)
            XCTAssertTrue(title.hasPrefix(kept), "cut between characters, never inside one")
            XCTAssertNoThrow(try Data([1]).write(to: folder.appending(path: name)), name)
            XCTAssertNoThrow(try Data([1]).write(to: folder.appending(path: "nfd-" + String(name.dropFirst(4)).decomposedStringWithCanonicalMapping)))
        }
        let families = try stem(NotebookExporter.fileName(family, extension: "pdf"), tail: ".pdf")
        XCTAssertTrue(families.allSatisfy { $0 == "👨‍👩‍👧‍👦" }, "a family of four isn't split up")
        XCTAssertEqual(families.unicodeScalars.count, families.count * 7)
        let accents = try stem(NotebookExporter.fileName(accented, extension: "pdf"), tail: ".pdf")
        XCTAssertEqual(accents.unicodeScalars.count, accents.count * 2, "no letter loses its accent")
        let hangul = try stem(NotebookExporter.fileName(korean, extension: "pdf"), tail: ".pdf")
        XCTAssertLessThan(hangul.utf8.count, hangul.decomposedStringWithCanonicalMapping.utf8.count, "counted as the jamo it may be stored as")
    }

    func testANotebookWithAVeryLongTitleExports() async throws {
        let title = Array(repeating: "Organic chemistry — reaction mechanisms", count: 20).joined(separator: " ")
        let source = try await input(title, pages: 3)
        let pdf = try await NotebookExporter.export(source) { _ in }
        addTeardownBlock { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
        assertFits(pdf.lastPathComponent)
        XCTAssertEqual(pdf.pathExtension, "pdf")
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 3)
        XCTAssertEqual(PDFDocument(url: pdf)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, title, "the PDF keeps the whole title")

        let images = try await NotebookExporter.exportImages(source) { _ in }
        addTeardownBlock { try? FileManager.default.removeItem(at: images[0].deletingLastPathComponent()) }
        XCTAssertEqual(Set(images.map(\.lastPathComponent)).count, 3)
        XCTAssertEqual(images.map { String($0.deletingPathExtension().lastPathComponent.suffix(2)) }, [" 1", " 2", " 3"])
        for image in images { assertFits(image.lastPathComponent) }
    }

    func testTheLaunchSweepRemovesOnlyTheAppsOwnFolders() throws {
        let tmp = try scratch(), outside = try scratch()
        let old = Date.now.addingTimeInterval(-3600)
        func folder(_ name: String, files: [String] = []) throws -> URL {
            let url = tmp.appending(path: name, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            for file in files {
                let path = url.appending(path: file)
                try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1]).write(to: path)
            }
            try fileManager.setAttributes([.creationDate: old], ofItemAtPath: url.path(percentEncoded: false))
            return url
        }
        let leftovers = [
            try folder("export-\(UUID().uuidString)", files: ["Biology.pdf"]),
            try folder("backup-\(UUID().uuidString)", files: ["OwlLuna Backup.owllunabackup", "info/backup.json"]),
            try folder(UUID().uuidString, files: ["Biology 1.png", "Biology 2.PNG"]),
            try folder(UUID().uuidString, files: ["Chemistry.mp4"]),
            try folder(UUID().uuidString),
        ]
        let others = [
            try folder("restore-\(UUID().uuidString)", files: ["backup.json"]),
            try folder("folders-\(UUID().uuidString)"),
            try folder("export-biology", files: ["Biology.pdf"]),
            try folder("backup-\(UUID().uuidString)-copy", files: ["a.pdf"]),
            try folder(UUID().uuidString, files: ["Biology.pdf", "manifest.json"]),
            try folder(UUID().uuidString, files: ["notes/Biology.pdf"]),
            try folder("com.owais.OwlLuna-Inbox", files: ["Lecture.pdf"]),
        ]
        let loose = tmp.appending(path: "export-\(UUID().uuidString)")
        try Data([1]).write(to: loose)
        let target = outside.appending(path: "kept.pdf")
        try Data([1]).write(to: target)
        let link = tmp.appending(path: "backup-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)
        let fresh = tmp.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data([1]).write(to: fresh.appending(path: "Physics.pdf"))

        XCTAssertEqual(ExportFolder.sweep(tmp, madeBefore: Date.now.addingTimeInterval(-60)), leftovers.count)
        for url in leftovers { XCTAssertFalse(exists(url), url.lastPathComponent) }
        for url in others { XCTAssertTrue(exists(url), url.lastPathComponent) }
        XCTAssertTrue(exists(fresh.appending(path: "Physics.pdf")), "an export begun since launch is left alone")

        XCTAssertEqual(ExportFolder.sweep(tmp, madeBefore: Date.now.addingTimeInterval(60)), 1, "whenever they were made, only export folders go")
        XCTAssertFalse(exists(fresh))
        for url in others + [loose, link] { XCTAssertTrue(exists(url), url.lastPathComponent) }
        XCTAssertTrue(exists(target), "a link is never followed")
    }

    func testAnExportGoesWhenItsSheetClosesAndNothingIsSharingIt() async throws {
        let job = ExportJob(input: try await input("Biology", pages: 2), format: .pdf)
        let deadline = Date().addingTimeInterval(30)
        while job.state == .running, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard case .finished(let urls) = job.state, let pdf = urls.first else { return XCTFail("the export finishes: \(job.state)") }
        let folder = pdf.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("export-"))

        ExportFolder.beginReading(urls)
        job.close()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(exists(pdf), "a share still reading it keeps it")
        ExportFolder.beginReading(urls)
        ExportFolder.endReading(urls)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(exists(pdf), "until every share and print has finished")
        ExportFolder.endReading(urls)
        let gone = try await waitUntilGone(folder)
        XCTAssertTrue(gone, "then the folder goes")
    }

    func testAnExportStoppedByClosingItsSheetLeavesNothing() async throws {
        let before = exportFolders()
        let job = ExportJob(input: try await input("Long", pages: 40), format: .images)
        job.close()
        XCTAssertEqual(job.state, .cancelled)
        try await Task.sleep(for: .seconds(1))
        let deadline = Date().addingTimeInterval(20)
        // The launch sweep may remove exports from an earlier run while this one is being cancelled.
        while !exportFolders().subtracting(before).isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(exportFolders().subtracting(before).isEmpty, "the cancelled export leaves no new folder")
    }

    func testABackupGoesOnceItsShareHasEnded() async throws {
        let backup = try LibraryBackup.create(root: temporaryRoot(self))
        let folder = backup.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("backup-"))

        ExportFolder.beginReading([backup])
        ExportFolder.discard([backup])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(exists(backup), "Save to Files may still be copying it")
        ExportFolder.endReading([backup])
        let gone = try await waitUntilGone(folder)
        XCTAssertTrue(gone)

        let unshared = try LibraryBackup.create(root: temporaryRoot(self))
        ExportFolder.discard([unshared])
        let alsoGone = try await waitUntilGone(unshared.deletingLastPathComponent())
        XCTAssertTrue(alsoGone, "one never shared goes at once")
    }

    func testOnlyExportFoldersAreEverDiscarded() async throws {
        let folder = try scratch()
        let file = folder.appending(path: "Lecture.pdf")
        try Data([1]).write(to: file)
        ExportFolder.discard([file])
        ExportFolder.beginReading([file])
        ExportFolder.endReading([file])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(exists(file))
    }
}
