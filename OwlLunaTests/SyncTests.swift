import XCTest
import PencilKit
import SwiftData
import UniformTypeIdentifiers
@testable import OwlLuna

/// Something a test changes while a pass is running.
private final class Shared<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Two devices and the synced copy between them, played out with three folders.
final class SyncTests: XCTestCase {
    private let paper = PageDefaults(template: .grid, paperColor: .white, pageSize: .letter)
    private var cloud: CloudFolder!
    private var a: StorageRoot!
    private var b: StorageRoot!
    private var containers: [ModelContainer] = []

    override func setUp() {
        super.setUp()
        a = temporaryRoot(self)
        b = temporaryRoot(self)
        cloud = CloudFolder(url: temporaryRoot(self).url)
    }

    @discardableResult
    private nonisolated(nonsending) func makeNotebook(_ title: String, on root: StorageRoot, strokes: Int = 1) async throws -> NotebookManifest {
        let manifest = NotebookManifest(title: title, defaults: paper, pages: [paper.newPage(), paper.newPage()])
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        let ink = PKDrawing(strokes: (0..<strokes).map { stroke(from: CGPoint(x: 40, y: 40 + CGFloat($0) * 30), to: CGPoint(x: 200, y: 60 + CGFloat($0) * 30)) })
        let receipt = try await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[0].id: ink]))
        try await package.writeThumbnail(Data([1, 2, 3]), pageID: manifest.pages[0].id, key: "cache")
        return receipt.manifest
    }

    /// An edit as the editor would save it: more ink, a later modification date, perhaps a new title.
    private func edit(_ id: UUID, on root: StorageRoot, title: String? = nil, page: Int = 0, strokes: Int, after seconds: TimeInterval) async throws {
        let package = NotebookPackage(root: root, id: id)
        var manifest = try await package.readManifest().manifest
        manifest.modifiedAt = manifest.modifiedAt.addingTimeInterval(seconds)
        if let title { manifest.title = title }
        let ink = PKDrawing(strokes: (0..<strokes).map { stroke(from: CGPoint(x: 40, y: 40 + CGFloat($0) * 30), to: CGPoint(x: 200, y: 60 + CGFloat($0) * 30)) })
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[page].id: ink]))
    }

    private nonisolated(nonsending) func strokes(_ manifest: NotebookManifest, on root: StorageRoot, page: Int = 0) async -> Int {
        guard case .ink(let drawing, _) = await NotebookPackage(root: root, id: manifest.id).readInk(manifest.pages[page].id) else { return 0 }
        return drawing.strokes.count
    }

    private func titles(on root: StorageRoot) async -> [String] {
        var result: [String] = []
        for id in root.packageIDs() { if let title = try? await NotebookPackage(root: root, id: id).readManifest().manifest.title { result.append(title) } }
        return result.sorted()
    }

    @discardableResult
    private nonisolated(nonsending) func sync(_ root: StorageRoot, busy: Set<UUID> = []) async throws -> SyncReport {
        try await LibrarySync.run(root: root, cloud: cloud, take: { !busy.contains($0) })
    }

    func testANotebookWrittenOnOneDeviceArrivesOnTheOther() async throws {
        let physics = try await makeNotebook("Physics", on: a, strokes: 2)
        let first = try await sync(a)
        XCTAssertEqual(first.pushed, [physics.id])
        XCTAssertFalse(first.changedHere)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.package(physics.id).appending(path: "thumbs").path(percentEncoded: false)), "thumbnails don't travel")

        let second = try await sync(b)
        XCTAssertEqual(second.pulled, [physics.id])
        XCTAssertTrue(second.changedHere)
        let arrived = try await NotebookPackage(root: b, id: physics.id).readManifest()
        XCTAssertEqual(arrived.manifest.title, "Physics")
        XCTAssertTrue(arrived.recoveredPageIDs.isEmpty && arrived.quarantined.isEmpty, "the notebook arrives whole")
        let count = await strokes(physics, on: b)
        XCTAssertEqual(count, 2)

        let againA = try await sync(a), againB = try await sync(b)
        XCTAssertEqual(againA, SyncReport(), "with nothing changed, a sync does nothing")
        XCTAssertEqual(againB, SyncReport())

        try await edit(physics.id, on: b, title: "Physics II", strokes: 5, after: 60)
        let pushed = try await sync(b)
        XCTAssertEqual(pushed.pushed, [physics.id])
        let pulled = try await sync(a)
        XCTAssertEqual(pulled.pulled, [physics.id])
        let edited = await strokes(physics, on: a)
        XCTAssertEqual(edited, 5, "an edit made on the second device comes back to the first")
        let names = await titles(on: a)
        XCTAssertEqual(names, ["Physics II"])
    }

    func testARecordingCutOffOnOneDeviceIsNeverTakenOverByASync() async throws {
        let lecture = try await makeNotebook("Lecture", on: a)
        try await sync(a)
        try await sync(b)
        let cut = {
            var entry = RecordingEntry(id: UUID(), file: "cut.aac", createdAt: .now, duration: 0)
            entry.device = a.deviceID
            return entry
        }()
        func holding(_ root: StorageRoot) async -> [UUID] {
            var found: [UUID] = []
            for id in root.packageIDs() {
                let package = NotebookPackage(root: root, id: id)
                if let manifest = try? await package.readManifest().manifest, manifest.unfinishedRecordings.map(\.id) == [cut.id],
                   FileManager.default.fileExists(atPath: package.assetURL(cut.file).path(percentEncoded: false)) { found.append(id) }
            }
            return found
        }

        // The app on A quits mid-recording, the notebook dated as the recording began; B writes in it meanwhile.
        let packageA = NotebookPackage(root: a, id: lecture.id)
        var manifest = try await packageA.readManifest().manifest
        manifest.unfinishedRecordings = [cut]
        manifest.modifiedAt = manifest.modifiedAt.addingTimeInterval(30)
        _ = try await packageA.write(SaveSnapshot(manifest: manifest, ink: [:]))
        try Data(repeating: 1, count: 256).write(to: packageA.assetURL(cut.file))
        try await edit(lecture.id, on: b, strokes: 4, after: 60)
        try await sync(b)
        let first = try await sync(a)
        XCTAssertEqual(first.conflictCopies.count, 1, "written on both, so both are kept")
        let copy = try XCTUnwrap(first.conflictCopies.first)
        let afterFirst = await holding(a)
        XCTAssertEqual(afterFirst, [copy], "the recording and its audio are in the copy")

        try await sync(a)
        try await sync(b)
        let onB = await holding(b)
        XCTAssertEqual(onB, [copy], "another iPad keeps it as it came")
        try await edit(copy, on: b, strokes: 2, after: 60)
        try await sync(b)
        let kept = try await sync(a)
        XCTAssertEqual(kept.pulled, [copy], "a version that still holds it comes in as usual")
        XCTAssertEqual(kept.conflictCopies, [])

        let packageB = NotebookPackage(root: b, id: copy)
        var dropped = try await packageB.readManifest().manifest
        dropped.unfinishedRecordings = []
        dropped.modifiedAt = dropped.modifiedAt.addingTimeInterval(60)
        _ = try await packageB.write(SaveSnapshot(manifest: dropped, ink: [:]))
        try await sync(b)
        let newer = try await LibrarySync.pullNewer(copy, root: a, cloud: cloud, timeout: .zero)
        XCTAssertEqual(newer, .waiting, "a version without it isn't swapped in")
        let last = try await sync(a)
        XCTAssertEqual(last.conflictCopies.count, 1, "nor taken over it by a pass: both are kept")
        let afterLast = await holding(a)
        XCTAssertEqual(afterLast.count, 1)
    }

    func testNotebooksChangedOnBothDevicesAreBothKept() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        try await edit(notes.id, on: a, strokes: 3, after: 60)
        try await edit(notes.id, on: b, strokes: 7, after: 120)
        try await sync(a)
        let report = try await sync(b)
        XCTAssertEqual(report.conflictCopies.count, 1)
        XCTAssertEqual(report.pushed, [notes.id], "the newer version keeps the notebook's place")
        let onB = await titles(on: b)
        XCTAssertEqual(onB, ["Notes", "Notes (conflicted copy)"])
        let winner = await strokes(notes, on: b)
        XCTAssertEqual(winner, 7)

        try await sync(b)
        let last = try await sync(a)
        XCTAssertEqual(Set(last.pulled).count, 2, "the first device receives the newer version and the copy of its own")
        let onA = await titles(on: a)
        XCTAssertEqual(onA, ["Notes", "Notes (conflicted copy)"])
        let newer = await strokes(notes, on: a)
        XCTAssertEqual(newer, 7)
        var copyStrokes = 0
        for id in a.packageIDs() where id != notes.id {
            let manifest = try await NotebookPackage(root: a, id: id).readManifest().manifest
            XCTAssertEqual(manifest.id, id, "the copy is a notebook of its own")
            copyStrokes = await strokes(manifest, on: a)
        }
        XCTAssertEqual(copyStrokes, 3, "nothing written on either device is lost")
        let settledA = try await sync(a), settledB = try await sync(b)
        XCTAssertEqual(settledA, SyncReport())
        XCTAssertEqual(settledB, SyncReport())
    }

    func testADeleteCarriesOverUnlessTheNotebookWasWrittenInSince() async throws {
        let old = try await makeNotebook("Old", on: a), kept = try await makeNotebook("Kept", on: a)
        // Two of four is no more than a pass takes as deleted at once.
        try await makeNotebook("Other", on: a)
        try await makeNotebook("Another", on: a)
        try await sync(a)
        try await sync(b)

        try FileManager.default.removeItem(at: a.package(old.id))
        try FileManager.default.removeItem(at: a.package(kept.id))
        let removed = try await sync(a)
        XCTAssertEqual(Set(removed.removedThere), [old.id, kept.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.tombstone(old.id).path(percentEncoded: false)))

        try await edit(kept.id, on: b, title: "Kept and written in", strokes: 4, after: 60)
        let report = try await sync(b)
        XCTAssertEqual(report.removedHere, [old.id], "a notebook deleted elsewhere and untouched here goes")
        let gone = try await library(old.id, on: b)
        XCTAssertNotNil(gone.deletedAt, "into Recently Deleted")
        XCTAssertEqual(report.pushed, [kept.id], "one written in since is kept: writing wins over a delete")
        let onB = await titles(on: b)
        XCTAssertEqual(onB, ["Another", "Kept and written in", "Old", "Other"])

        let back = try await sync(a)
        XCTAssertEqual(back.pulled, [kept.id])
        let onA = await titles(on: a)
        XCTAssertEqual(onA, ["Another", "Kept and written in", "Other"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.package(old.id).path(percentEncoded: false)), "and the deleted one doesn't come back")
    }

    func testADeleteDoesNotRemoveWritingAnotherDeviceAlreadySynced() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        try await edit(notes.id, on: b, title: "Notes, written in", strokes: 4, after: 60)
        try await sync(b)
        try FileManager.default.removeItem(at: a.package(notes.id))
        let report = try await sync(a)
        XCTAssertEqual(report.removedThere, [], "the synced copy changed since this device last saw it, so the delete doesn't carry")
        XCTAssertEqual(report.pulled, [notes.id], "and the newer writing comes here instead")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.tombstone(notes.id).path(percentEncoded: false)))
        let arrived = await strokes(notes, on: a)
        XCTAssertEqual(arrived, 4)

        let other = try await sync(b)
        XCTAssertEqual(other, SyncReport(), "nothing is removed on the device that wrote it")
        let onB = await titles(on: b)
        XCTAssertEqual(onB, ["Notes, written in"])
    }

    func testAMarkerLeftBesideANotebookWrittenInSinceIsClearedAway() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)
        // A delete on another device that got as far as its marker and no further.
        try Data().write(to: cloud.tombstone(notes.id))
        try await edit(notes.id, on: b, strokes: 4, after: 60)
        let report = try await sync(b)
        XCTAssertEqual(report.pushed, [notes.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.tombstone(notes.id).path(percentEncoded: false)), "writing wins, so the marker goes")

        let fresh = temporaryRoot(self)
        let arrived = try await LibrarySync.run(root: fresh, cloud: cloud)
        XCTAssertEqual(arrived.pulled, [notes.id], "and a device new to the library receives the notebook rather than finishing the delete")
        try await sync(a)
        try await settled()
        XCTAssertEqual(b.packageIDs(), [notes.id])
    }

    // MARK: A delete made on a view of iCloud that was behind

    private func marked(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: cloud.tombstone(id).path(percentEncoded: false))
    }

    /// One device's own view of the synced copy as it stands now, which hears nothing more from iCloud.
    private func staleView() throws -> CloudFolder {
        let url = temporaryRoot(self).url.appending(path: "view", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: cloud.url, to: url)
        return CloudFolder(url: url)
    }

    /// A delete made on such a view reaches the synced copy: its marker always, and the removal when that is what iCloud keeps.
    private func deliverDelete(of id: UUID, from view: CloudFolder, removing: Bool) throws {
        try? FileManager.default.removeItem(at: cloud.tombstone(id))
        try FileManager.default.copyItem(at: view.tombstone(id), to: cloud.tombstone(id))
        if removing { try FileManager.default.removeItem(at: cloud.package(id)) }
    }

    /// Two devices in step, then written in on the second and synced, then deleted on the first before it heard of that.
    private func deletedBeforeSyncedWritingArrived() async throws -> (notes: NotebookManifest, view: CloudFolder) {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)
        let view = try staleView()
        try await edit(notes.id, on: b, title: "Notes, written in", strokes: 4, after: 60)
        try await sync(b)
        try FileManager.default.removeItem(at: a.package(notes.id))
        let deleting = try await LibrarySync.run(root: a, cloud: view)
        XCTAssertEqual(deleting.removedThere, [notes.id])
        return (notes, view)
    }

    func testADeleteMadeBeforeSyncedWritingArrivedDoesNotRemoveIt() async throws {
        let (notes, view) = try await deletedBeforeSyncedWritingArrived()
        try deliverDelete(of: notes.id, from: view, removing: true)

        let report = try await sync(b)
        XCTAssertEqual(report.removedHere, [], "the marker is for a version from before this writing")
        XCTAssertEqual(report.pushed, [notes.id], "so the writing goes back up")
        XCTAssertFalse(marked(notes.id))
        let kept = await strokes(notes, on: b)
        XCTAssertEqual(kept, 4)

        let back = try await sync(a)
        XCTAssertEqual(back.pulled, [notes.id], "and comes back to the device that deleted the older version")
        let onA = await titles(on: a)
        XCTAssertEqual(onA, ["Notes, written in"])
        try await settled()
    }

    func testAMarkerForAnOlderVersionDoesNotRemoveTheNewerOneBesideIt() async throws {
        let (notes, view) = try await deletedBeforeSyncedWritingArrived()
        // iCloud keeps the upload, so the marker sits beside the newer version.
        try deliverDelete(of: notes.id, from: view, removing: false)
        let inStep = try await sync(b)
        XCTAssertEqual(inStep, SyncReport())
        XCTAssertFalse(marked(notes.id), "a marker for another version is cleared, in step or not")

        try deliverDelete(of: notes.id, from: view, removing: false)
        let fresh = temporaryRoot(self)
        let arrived = try await LibrarySync.run(root: fresh, cloud: cloud)
        XCTAssertEqual(arrived.pulled, [notes.id], "a device new to the library receives the notebook rather than finishing that delete")
        XCTAssertTrue(isSynced(notes.id))

        try deliverDelete(of: notes.id, from: view, removing: false)
        let back = try await sync(a)
        XCTAssertEqual(back.pulled, [notes.id], "and so does the device that deleted the older version")
        XCTAssertTrue(isSynced(notes.id))
        XCTAssertFalse(marked(notes.id))
        let count = await strokes(notes, on: a)
        XCTAssertEqual(count, 4)
        try await settled()
    }

    func testADeleteThatGotAsFarAsItsMarkerIsFinishedByTheNextDevice() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)
        let view = try staleView()
        try FileManager.default.removeItem(at: a.package(notes.id))
        _ = try await LibrarySync.run(root: a, cloud: view)
        try deliverDelete(of: notes.id, from: view, removing: false)

        let inStep = try await sync(b)
        XCTAssertEqual(inStep, SyncReport())
        XCTAssertTrue(marked(notes.id), "a marker for the version beside it stands")
        let fresh = temporaryRoot(self)
        let arrived = try await LibrarySync.run(root: fresh, cloud: cloud)
        XCTAssertEqual(arrived.pulled, [])
        XCTAssertFalse(isSynced(notes.id), "and a device that never had the notebook finishes the delete")
        let report = try await sync(b)
        XCTAssertEqual(report.removedHere, [notes.id])
    }

    func testAnEmptyMarkerFromAnOlderBuildStillCarriesADelete() async throws {
        let old = try await makeNotebook("Old", on: a), kept = try await makeNotebook("Kept", on: a)
        try await sync(a)
        try await sync(b)
        for id in [old.id, kept.id] {
            try Data().write(to: cloud.tombstone(id))
            try FileManager.default.removeItem(at: cloud.package(id))
        }
        try await edit(kept.id, on: b, strokes: 4, after: 60)
        let report = try await sync(b)
        XCTAssertEqual(report.removedHere, [old.id])
        XCTAssertEqual(report.pushed, [kept.id])
    }

    /// A notebook in Recently Deleted on both devices, put there 40 days ago, and in step.
    private nonisolated(nonsending) func longDeleted() async throws -> NotebookManifest {
        let notes = try await makeNotebook("Notes", on: a, strokes: 2)
        try await sync(a)
        try await sync(b)
        let longAgo = Date.now.addingTimeInterval(-40 * 86_400)
        try await file(notes.id, on: a, at: longAgo) { $0.deletedAt = longAgo }
        try await sync(a)
        try await sync(b)
        try await settled()
        return notes
    }

    func testARestoreTheDeletingDeviceHadNotReceivedIsKept() async throws {
        let notes = try await longDeleted()
        // Taken back out on the second device, which hasn't synced since.
        try await file(notes.id, on: b, at: .now) { $0.deletedAt = nil }
        // Its 30 days are up on the first, which removes it for good and carries that over.
        try FileManager.default.removeItem(at: a.package(notes.id))
        let purged = try await sync(a)
        XCTAssertEqual(purged.removedThere, [notes.id])

        let report = try await sync(b)
        XCTAssertEqual(report.removedHere, [], "a restore the deleting device never heard of is kept, as writing would be")
        XCTAssertEqual(report.pushed, [notes.id])
        XCTAssertFalse(marked(notes.id))
        let back = try await sync(a)
        XCTAssertEqual(back.pulled, [notes.id])
        for root in [a!, b!] {
            let state = try await library(notes.id, on: root)
            XCTAssertNil(state.deletedAt)
            let count = await strokes(notes, on: root)
            XCTAssertEqual(count, 2)
        }
        try await settled()
    }

    func testADeleteDoesNotCarryOverARestoreAlreadyInTheSyncedCopy() async throws {
        let notes = try await longDeleted()
        try await file(notes.id, on: b, at: .now) { $0.deletedAt = nil }
        let restored = try await sync(b)
        XCTAssertEqual(restored.stateSent, [notes.id])
        // The first device's 30 days ran out on what it knew before that restore reached it.
        try FileManager.default.removeItem(at: a.package(notes.id))

        let report = try await sync(a)
        XCTAssertEqual(report.removedThere, [], "the notebook was taken back out since this device last saw it, so the delete doesn't carry")
        XCTAssertEqual(report.pulled, [notes.id])
        XCTAssertFalse(marked(notes.id))
        let state = try await library(notes.id, on: a)
        XCTAssertNil(state.deletedAt)
        let other = try await sync(b)
        XCTAssertEqual(other, SyncReport(), "and nothing is removed on the device that restored it")
        XCTAssertEqual(b.packageIDs(), [notes.id])
    }

    func testADeleteForGoodFromRecentlyDeletedStillCarriesOver() async throws {
        let synced = try await longDeleted(), unsynced = try await makeNotebook("Unsynced", on: a)
        try await sync(a)
        try await sync(b)
        // One went into Recently Deleted on both devices; the other is deleted for good before that was ever synced.
        try await file(unsynced.id, on: a, at: .now) { $0.deletedAt = .now }
        for id in [synced.id, unsynced.id] { try FileManager.default.removeItem(at: a.package(id)) }
        let report = try await sync(a)
        XCTAssertEqual(Set(report.removedThere), [synced.id, unsynced.id])
        let other = try await sync(b)
        XCTAssertEqual(Set(other.removedHere), [synced.id, unsynced.id])
        XCTAssertEqual(b.packageIDs(), [unsynced.id], "the one in Recently Deleted here too goes for good")
        let binned = try await library(unsynced.id, on: b)
        XCTAssertNotNil(binned.deletedAt, "and the one that never went in there here goes in now")
    }

    // MARK: Recently Deleted kept for different lengths on each device

    /// This device's own Recently Deleted running out, as the library does it.
    @MainActor
    private func expire(on root: StorageRoot, after length: TrashLength) async throws -> LibraryStore {
        let store = try device(root)
        await store.reloadFromDisk()
        await store.purgeExpiredTrash(olderThan: length.days)
        return store
    }

    @MainActor
    func testRecentlyDeletedRunningOutHereLeavesItOnADeviceThatKeepsItLonger() async throws {
        let notes = try await longDeleted()
        let here = try await expire(on: a, after: .month)
        XCTAssertNil(here.record(notes.id))
        XCTAssertFalse(a.packageIDs().contains(notes.id))
        XCTAssertNotNil(ExpiredTrash.read(a).notebooks[notes.id])

        let report = try await sync(a)
        XCTAssertEqual(report, SyncReport(), "the other device may keep Recently Deleted for 90 days, so its copy is left for it")
        XCTAssertTrue(isSynced(notes.id))
        XCTAssertFalse(marked(notes.id))
        let other = try await sync(b)
        XCTAssertEqual(other, SyncReport())
        let kept = try await library(notes.id, on: b)
        XCTAssertNotNil(kept.deletedAt, "it is still in Recently Deleted there")

        // Taken back out there, it comes back here as any restore would.
        try await file(notes.id, on: b, at: .now) { $0.deletedAt = nil }
        try await sync(b)
        let back = try await sync(a)
        XCTAssertEqual(back.pulled, [notes.id])
        let restored = try await library(notes.id, on: a)
        XCTAssertNil(restored.deletedAt)
        let count = await strokes(notes, on: a)
        XCTAssertEqual(count, 2)
        try await settled()
    }

    @MainActor
    func testADeleteForGoodMadeHereStillGoesEverywhere() async throws {
        let notes = try await longDeleted()
        let here = try await expire(on: a, after: .month)
        try await sync(a)
        try await file(notes.id, on: b, at: .now) { $0.deletedAt = nil }
        try await sync(b)
        try await sync(a)
        // Back here, then put in Recently Deleted again and deleted for good from it.
        try await file(notes.id, on: a, at: .now) { $0.deletedAt = .now }
        try await sync(a)
        try await sync(b)
        await here.reloadFromDisk()
        here.deletePermanently([try XCTUnwrap(here.record(notes.id))])
        XCTAssertNil(ExpiredTrash.read(a).notebooks[notes.id], "a delete made here is meant for every device")

        let report = try await sync(a)
        XCTAssertEqual(report.removedThere, [notes.id])
        let other = try await sync(b)
        XCTAssertEqual(other.removedHere, [notes.id])
        XCTAssertEqual(b.packageIDs(), [])
    }

    @MainActor
    func testOnceNoDeviceCanStillKeepItItsDeleteGoesEverywhere() async throws {
        let notes = try await longDeleted()
        _ = try await expire(on: a, after: .month)
        let kept = try await sync(a)
        XCTAssertEqual(kept, SyncReport())
        // 51 days on it has been in Recently Deleted for more than 90, longer than any device keeps one.
        let later = Date.now.addingTimeInterval(51 * 86_400)
        let report = try await LibrarySync.run(root: a, cloud: cloud, now: later)
        XCTAssertEqual(report.removedThere, [notes.id])
        XCTAssertTrue(marked(notes.id))
        let other = try await LibrarySync.run(root: b, cloud: cloud, now: later)
        XCTAssertEqual(other.removedHere, [notes.id])
        XCTAssertEqual(b.packageIDs(), [], "where its time would have run out by then as well")
    }

    // MARK: A pass and what changes while it runs

    private func sorted(_ manifests: [NotebookManifest]) -> [UUID] { manifests.map(\.id).sorted { $0.uuidString < $1.uuidString } }

    private func isSynced(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: cloud.package(id).appending(path: "manifest.json").path(percentEncoded: false))
    }

    func testEachNotebookIsAskedForWhenItsTurnComes() async throws {
        let ids = sorted([try await makeNotebook("One", on: a), try await makeNotebook("Two", on: a), try await makeNotebook("Three", on: a)])
        // The last one is opened in an editor while the pass is busy with the first, and is open by the time that is done.
        let open = Shared<Set<UUID>>([]), log = Shared<[String]>([]), released = Shared<[UUID]>([])
        let report = try await LibrarySync.run(root: a, cloud: cloud, take: { id in
            log.value.append("take \(id)")
            return !open.value.contains(id)
        }, release: { id in
            log.value.append("release \(id)")
            released.value.append(id)
            if id == ids[0] { open.value.insert(ids[2]) }
        })
        XCTAssertEqual(log.value, ["take \(ids[0])", "release \(ids[0])", "take \(ids[1])", "release \(ids[1])", "take \(ids[2])"],
                       "each in its turn, not all as the pass begins")
        XCTAssertEqual(report.pushed, [ids[0], ids[1]])
        XCTAssertEqual(report.waiting, [ids[2]], "so one opened since is still left alone")
        XCTAssertFalse(isSynced(ids[2]))
        XCTAssertEqual(released.value, [ids[0], ids[1]], "and what was taken is handed back")
    }

    func testAPassStopsWhenAnotherAccountSignsInPartWay() async throws {
        let ids = sorted([try await makeNotebook("One", on: a), try await makeNotebook("Two", on: a), try await makeNotebook("Three", on: a)])
        let signedIn = Shared<String?>("one"), released = Shared<[UUID]>([])
        do {
            _ = try await LibrarySync.run(root: a, cloud: cloud, account: "one", take: { id in
                if id == ids[0] { signedIn.value = "two" }
                return true
            }, release: { released.value.append($0) }, signedIn: { signedIn.value })
            XCTFail("the container now belongs to another account")
        } catch {
            let stopped = error as? StoppedPass
            XCTAssertEqual(stopped?.reason as? SyncError, .accountChanged)
            XCTAssertEqual(stopped?.report.pushed, [ids[0]], "what the pass did before it stopped is handed back")
        }
        XCTAssertTrue(isSynced(ids[0]), "the notebook in hand is finished")
        XCTAssertEqual(released.value, [ids[0]])
        XCTAssertFalse(isSynced(ids[1]) || isSynced(ids[2]), "and nothing more is copied")
        let state = SyncState.read(a)
        XCTAssertEqual(Array(state.notebooks.keys), [ids[0]], "what was sent is kept as agreed")
        XCTAssertEqual(state.copy, try String(contentsOf: cloud.copyFile, encoding: .utf8), "with the copy the pass began with, and no other account's")
        XCTAssertEqual(state.account, "one", "and whose copy that was is kept, so the other account is asked about")
    }

    func testAPassThatIsCancelledStopsBeforeTheNextNotebook() async throws {
        let ids = sorted([try await makeNotebook("One", on: a), try await makeNotebook("Two", on: a)])
        let pass = Shared<Task<SyncReport, Error>?>(nil), cloud = cloud!, a = a!
        let task = Task.detached {
            try await LibrarySync.run(root: a, cloud: cloud, take: { id in
                if id == ids[0] { pass.value?.cancel() }
                return true
            })
        }
        pass.value = task
        do {
            _ = try await task.value
            XCTFail("a cancelled pass doesn't finish")
        } catch {
            XCTAssertTrue((error as? StoppedPass)?.reason is CancellationError)
        }
        XCTAssertFalse(isSynced(ids[1]))
    }

    func testAPassStoppedPartWayRemembersWhatItDid() async throws {
        let ids = sorted([try await makeNotebook("One", on: a), try await makeNotebook("Two", on: a)])
        try await sync(a)
        let signedIn = Shared<String?>("one")
        do {
            _ = try await LibrarySync.run(root: b, cloud: cloud, account: "one", take: { id in
                if id == ids[0] { signedIn.value = "two" }
                return true
            }, signedIn: { signedIn.value })
            XCTFail("the container now belongs to another account")
        } catch {
            XCTAssertEqual((error as? StoppedPass)?.report.pulled, [ids[0]])
        }
        XCTAssertEqual(b.packageIDs(), [ids[0]], "the first notebook arrived before the pass stopped")
        XCTAssertNotNil(SyncState.read(b).notebooks[ids[0]], "and is kept as agreed, though the pass never reached its end")

        // Deleted here afterwards, it is a delete and not a notebook this device has yet to receive.
        try FileManager.default.removeItem(at: b.package(ids[0]))
        let report = try await LibrarySync.run(root: b, cloud: cloud, account: "one")
        XCTAssertEqual(report.removedThere, [ids[0]])
        XCTAssertEqual(report.pulled, [ids[1]])
    }

    func testAConflictInAPassThatWasStoppedIsNotCopiedTwice() async throws {
        let notes = try await makeNotebook("Notes", on: a), other = try await makeNotebook("Other", on: a)
        try await sync(a)
        try await sync(b)
        try await edit(notes.id, on: a, strokes: 7, after: 120)
        try await edit(notes.id, on: b, strokes: 3, after: 60)
        try await sync(a)
        // The copy is made, the newer version can't be pulled yet, and then the pass is stopped before its end.
        let ink = try inkFile(of: notes.id)
        try permit(0o000, ink)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ink.path(percentEncoded: false)) }
        let last = sorted([notes, other])[1], signedIn = Shared<String?>(nil)
        do {
            _ = try await LibrarySync.run(root: b, cloud: cloud, release: { if $0 == last { signedIn.value = "another" } }, signedIn: { signedIn.value })
            XCTFail("the container now belongs to another account")
        } catch {
            XCTAssertEqual((error as? StoppedPass)?.report.conflictCopies.count, 1)
        }
        XCTAssertEqual(b.packageIDs().count, 3)

        try permit(0o644, ink)
        let report = try await sync(b)
        XCTAssertEqual(report.conflictCopies, [], "the copy made by the pass that was stopped is the only one")
        XCTAssertEqual(report.pulled, [notes.id])
        XCTAssertEqual(b.packageIDs().count, 3)
        let onB = try await shelf(b)
        XCTAssertEqual(onB, ["Notes": 7, "Notes (conflicted copy)": 3, "Other": 1])
    }

    func testAPassThatHasToWaitForTheFoldersCopiesNothing() async throws {
        try fill(a)
        try await sync(a)
        try await sync(b)
        let new = try await makeNotebook("New", on: b)
        let foldersFile = cloud.foldersFile
        try permit(0o000, foldersFile)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: foldersFile.path(percentEncoded: false)) }
        do {
            try await sync(b)
            XCTFail("folders that can't be read yet aren't merged")
        } catch {
            XCTAssertEqual(error as? SyncError, .stillArriving)
        }
        XCTAssertFalse(isSynced(new.id), "a pass that can't reach its end sends nothing")

        // Deleted before the folders arrive, the notebook doesn't come back from the synced copy.
        try FileManager.default.removeItem(at: b.package(new.id))
        try permit(0o644, foldersFile)
        let report = try await sync(b)
        XCTAssertEqual(report.pulled, [])
        XCTAssertEqual(b.packageIDs(), [])
    }

    // MARK: An upload cut short

    private func firstInk(of id: UUID, on root: StorageRoot) throws -> URL {
        let ink = root.package(id).appending(path: "ink", directoryHint: .isDirectory)
        return try XCTUnwrap(FileManager.default.contentsOfDirectory(at: ink, includingPropertiesForKeys: nil).first)
    }

    /// The synced copy as a pass killed part-way through an upload left it: the pages, and no manifest.
    private func cutShortUpload(of id: UUID, from root: StorageRoot) throws {
        try FileManager.default.createDirectory(at: cloud.library, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.package(id), to: cloud.package(id))
        for name in ["manifest.json", "thumbs"] { try FileManager.default.removeItem(at: cloud.package(id).appending(path: name)) }
    }

    func testAnUploadCutShortIsSentAgain() async throws {
        let notes = try await makeNotebook("Notes", on: a, strokes: 2)
        try cutShortUpload(of: notes.id, from: a)
        let report = try await sync(a)
        XCTAssertEqual(report.waiting, [], "a package with no manifest, and none on its way, isn't waited on for ever")
        XCTAssertEqual(report.pushed, [notes.id])
        let arrived = try await sync(b)
        XCTAssertEqual(arrived.pulled, [notes.id])
        let count = await strokes(notes, on: b)
        XCTAssertEqual(count, 2)
        try await settled()
    }

    func testAPackageWhoseManifestIsStillOnItsWayIsWaitedFor() async throws {
        let notes = try await makeNotebook("Notes", on: a, strokes: 2)
        try cutShortUpload(of: notes.id, from: a)
        try Data().write(to: cloud.package(notes.id).appending(path: ".manifest.json.icloud"))
        let report = try await sync(a)
        XCTAssertEqual(report.waiting, [notes.id])
        XCTAssertEqual(report.pushed, [], "nothing is copied over a notebook whose manifest iCloud hasn't brought down yet")
    }

    func testAFailedUploadLeavesNothingUnderTheNotebooksName() async throws {
        let notes = try await makeNotebook("Notes", on: a, strokes: 2)
        let ink = try firstInk(of: notes.id, on: a)
        try permit(0o000, ink)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ink.path(percentEncoded: false)) }
        let failed = try await sync(a)
        XCTAssertEqual(failed.waiting, [notes.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.package(notes.id).path(percentEncoded: false)),
                       "a notebook new to the synced copy appears there whole or not at all")
        let other = try await sync(b)
        XCTAssertEqual(other, SyncReport(), "so no other device is left waiting on it")

        try permit(0o644, ink)
        let report = try await sync(a)
        XCTAssertEqual(report.pushed, [notes.id])
        let arrived = try await sync(b)
        XCTAssertEqual(arrived.pulled, [notes.id])
        try await settled()
    }

    func testAnUploadLeftBehindByAQuitIsClearedAwayOnceItIsOld() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        // Two uploads cut short: one from hours ago, and one that may be another device's, still under way.
        let old = cloud.upload(UUID()), recent = cloud.upload(UUID())
        for url in [old, recent] { try FileManager.default.copyItem(at: a.package(notes.id), to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-7200)], ofItemAtPath: old.path(percentEncoded: false))

        let report = try await sync(b)
        XCTAssertEqual(report.pulled, [notes.id], "neither is taken for a notebook")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path(percentEncoded: false)))
    }

    // MARK: A conflict that can't be finished

    private func permit(_ mode: Int, _ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path(percentEncoded: false))
    }

    private func inkFile(of id: UUID) throws -> URL {
        let ink = cloud.package(id).appending(path: "ink", directoryHint: .isDirectory)
        return try XCTUnwrap(FileManager.default.contentsOfDirectory(at: ink, includingPropertiesForKeys: nil).first)
    }

    /// Every notebook on the device is whole and named by its own ID: the titles, and how much is written in each.
    private func shelf(_ root: StorageRoot, file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Int] {
        var result: [String: Int] = [:]
        for id in root.packageIDs() {
            let manifest = try await NotebookPackage(root: root, id: id).readManifest().manifest
            XCTAssertEqual(manifest.id, id, "a notebook is never left under another's ID", file: file, line: line)
            result[manifest.title] = await strokes(manifest, on: root)
        }
        return result
    }

    func testTheNewerVersionInTheSyncedCopyWinsAConflict() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        try await edit(notes.id, on: a, strokes: 7, after: 120)
        try await edit(notes.id, on: b, strokes: 3, after: 60)
        try await sync(a)
        let report = try await sync(b)
        XCTAssertEqual(report.conflictCopies.count, 1)
        XCTAssertEqual(report.pulled, [notes.id], "the newer version comes in under the notebook's ID")
        let onB = try await shelf(b)
        XCTAssertEqual(onB, ["Notes": 7, "Notes (conflicted copy)": 3], "and what was written here is kept beside it")

        try await sync(b)
        try await sync(a)
        let onA = try await shelf(a)
        XCTAssertEqual(onA, ["Notes": 7, "Notes (conflicted copy)": 3])
        try await settled()
    }

    func testAConflictWhosePullFailsLeavesTheNotebookInItsPlace() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        try await edit(notes.id, on: a, strokes: 7, after: 120)
        try await edit(notes.id, on: b, strokes: 3, after: 60)
        try await sync(a)
        // The newer version is in the synced copy, but one of its pages can't be read.
        let ink = try inkFile(of: notes.id)
        try permit(0o000, ink)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ink.path(percentEncoded: false)) }

        let failed = try await sync(b)
        XCTAssertEqual(failed.waiting, [notes.id])
        XCTAssertEqual(failed.pulled, [])
        let kept = try await shelf(b)
        XCTAssertEqual(kept["Notes"], 3, "the notebook is still where it was, with what was written here")

        try permit(0o644, ink)
        let report = try await sync(b)
        XCTAssertEqual(report.pulled, [notes.id])
        XCTAssertEqual(report.removedThere, [], "a pull that failed is never taken for a delete")
        XCTAssertEqual(report.conflictCopies, [], "the copy was made by the pass that failed, and isn't made again")
        XCTAssertEqual(b.packageIDs().count, 2)
        let onB = try await shelf(b)
        XCTAssertEqual(onB, ["Notes": 7, "Notes (conflicted copy)": 3], "one copy is kept, however often it had to try")
        try await sync(b)
        try await sync(a)
        let onA = try await shelf(a)
        XCTAssertEqual(onA, ["Notes": 7, "Notes (conflicted copy)": 3])
    }

    func testAConflictWhosePushFailsLeavesNoHalfMadeCopy() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        try await edit(notes.id, on: a, strokes: 3, after: 60)
        try await edit(notes.id, on: b, strokes: 7, after: 120)
        try await sync(a)
        // The older version is in the synced copy, where its manifest can't be replaced.
        let synced = cloud.package(notes.id)
        try permit(0o555, synced)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: synced.path(percentEncoded: false)) }

        let failed = try await sync(b)
        XCTAssertEqual(failed.waiting, [notes.id])
        XCTAssertEqual(failed.pushed, [])
        let kept = try await shelf(b)
        XCTAssertEqual(kept["Notes"], 7)
        XCTAssertEqual(kept.filter { $0.key != "Notes" }, ["Notes (conflicted copy)": 3], "the older version is kept whole before anything is sent over it")

        try permit(0o755, synced)
        let report = try await sync(b)
        XCTAssertTrue(report.pushed.contains(notes.id))
        XCTAssertEqual(report.conflictCopies, [], "and it isn't copied a second time")
        try await sync(a)
        let onA = try await shelf(a)
        XCTAssertEqual(onA, ["Notes": 7, "Notes (conflicted copy)": 3])
        try await settled()
    }

    func testAnOpenNotebookAndAHalfArrivedOneAreLeftForLater() async throws {
        let open = try await makeNotebook("Open", on: a)
        let busy = try await sync(a, busy: [open.id])
        XCTAssertEqual(busy.waiting, [open.id])
        XCTAssertTrue(busy.pushed.isEmpty)
        try await sync(a)
        try await sync(b)

        try await edit(open.id, on: a, strokes: 6, after: 60)
        try await sync(a)
        let manifest = cloud.package(open.id).appending(path: "manifest.json")
        let whole = try Data(contentsOf: manifest)
        try Data("{".utf8).write(to: manifest)
        let report = try await sync(b)
        XCTAssertEqual(report.waiting, [open.id], "a manifest that can't be read yet is waited for")
        let untouched = await strokes(open, on: b)
        XCTAssertEqual(untouched, 1)
        try whole.write(to: manifest)
        let later = try await sync(b)
        XCTAssertEqual(later.pulled, [open.id])
    }

    func testFoldersAndStickersFollow() async throws {
        let science = FolderEntry(id: UUID(), name: "Science", clothRaw: "jade", createdAt: .now, sortIndex: 0)
        let labs = FolderEntry(id: UUID(), name: "Labs", clothRaw: "moss", createdAt: .now, sortIndex: 1, parentID: science.id)
        var file = FolderFile()
        file.folders = [science, labs]
        try file.write(a)
        try FileManager.default.createDirectory(at: a.stickers, withIntermediateDirectories: true)
        try Data([1]).write(to: a.stickers.appending(path: "cat.png"))
        try await sync(a)
        let first = try await sync(b)
        XCTAssertTrue(first.foldersChanged && first.stickersChanged)
        XCTAssertEqual(FolderFile.read(b).folders.map(\.name), ["Science", "Labs"])
        XCTAssertEqual(FolderFile.read(b).folders.last?.parentID, science.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.stickers.appending(path: "cat.png").path(percentEncoded: false)))

        var changed = FolderFile.read(b)
        changed.folders.removeAll { $0.id == labs.id }
        changed.folders.append(FolderEntry(id: UUID(), name: "Art", clothRaw: "rose", createdAt: .now, sortIndex: 2))
        try changed.write(b)
        try FileManager.default.removeItem(at: b.stickers.appending(path: "cat.png"))
        try Data([2]).write(to: b.stickers.appending(path: "dog.png"))
        try await sync(b)
        try await sync(a)
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name).sorted(), ["Art", "Science"], "a folder deleted on one device goes from the other, and a new one arrives")
        let stickers = try FileManager.default.contentsOfDirectory(atPath: a.stickers.path(percentEncoded: false))
        XCTAssertEqual(stickers, ["dog.png"])
    }

    func testYourOwnPaperFollows() async throws {
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 80)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 30, height: 80)) }
        let planner = try PaperShelf.add(image: picture, name: "Planner", to: a)
        try await sync(a)
        let first = try await sync(b)
        XCTAssertTrue(first.papersChanged)
        XCTAssertEqual(PaperShelf.list(b).map(\.id), [planner.id])

        let moved = try PaperShelf.rename(try XCTUnwrap(PaperShelf.list(b).first), to: "Week Planner")
        let sheet = try PaperShelf.add(image: picture, name: "Lab Sheet", to: b)
        try await sync(b)
        let back = try await sync(a)
        XCTAssertTrue(back.papersChanged)
        XCTAssertEqual(PaperShelf.list(a).map(\.name), ["Lab Sheet", "Week Planner"], "a rename and a new paper carry over")
        XCTAssertEqual(PaperShelf.list(a).map(\.id).sorted(), [moved.id, sheet.id].sorted())

        PaperShelf.remove(sheet)
        try await sync(b)
        try await sync(a)
        XCTAssertEqual(PaperShelf.list(a).map(\.name), ["Week Planner"], "a paper deleted on one device goes from the other")
    }

    // MARK: How a notebook is filed

    private nonisolated(nonsending) func library(_ id: UUID, on root: StorageRoot) async throws -> LibraryState {
        try await NotebookPackage(root: root, id: id).readManifest().manifest.library
    }

    /// A library change as `LibraryStore` writes it: what changed is stamped, and the notebook's own date left alone.
    /// With no date it is as an older build wrote it, unstamped.
    private nonisolated(nonsending) func file(_ id: UUID, on root: StorageRoot, at date: Date?, _ change: @escaping @Sendable (inout LibraryState) -> Void) async throws {
        _ = try await NotebookPackage(root: root, id: id).updateManifest {
            let before = $0.library
            change(&$0.library)
            if let date { $0.library.stamp(changesSince: before, at: date) }
        }
    }

    private nonisolated(nonsending) func settled(file: StaticString = #filePath, line: UInt = #line) async throws {
        let onA = try await sync(a), onB = try await sync(b)
        XCTAssertEqual(onA, SyncReport(), file: file, line: line)
        XCTAssertEqual(onB, SyncReport(), file: file, line: line)
    }

    func testFilingReachesTheOtherDeviceWithoutAnEdit() async throws {
        let diary = try await makeNotebook("Diary", on: a, strokes: 2), folder = UUID()
        try await sync(a)
        try await sync(b)
        _ = try await NotebookPackage(root: b, id: diary.id).updateManifest { $0.library.currentPage = 1 }
        let trashed = Date.now
        try await file(diary.id, on: a, at: .now) {
            $0.isLocked = true
            $0.isFavorite = true
            $0.tags = ["secret"]
            $0.folderID = folder
            $0.deletedAt = trashed
        }

        let sent = try await sync(a)
        XCTAssertEqual(sent.stateSent, [diary.id], "the lock goes at the next sync, with no edit to carry it")
        XCTAssertEqual(sent.pushed, [], "and the pages aren't sent again")
        XCTAssertFalse(sent.changedHere)
        let received = try await sync(b)
        XCTAssertEqual(received.stateReceived, [diary.id])
        XCTAssertEqual(received.pulled, [])
        XCTAssertTrue(received.changedHere, "which is what has the index, Spotlight and the widgets brought up to date")

        let arrived = try await NotebookPackage(root: b, id: diary.id).readManifest().manifest
        XCTAssertTrue(arrived.library.isLocked && arrived.library.isFavorite)
        XCTAssertEqual(arrived.library.tags, ["secret"])
        XCTAssertEqual(arrived.library.folderID, folder)
        XCTAssertEqual(try XCTUnwrap(arrived.library.deletedAt).timeIntervalSince(trashed), 0, accuracy: 0.001)
        XCTAssertEqual(arrived.library.currentPage, 1, "where this device left off reading stays its own")
        XCTAssertEqual(arrived.modifiedAt.timeIntervalSince(diary.modifiedAt), 0, accuracy: 0.001, "and the notebook isn't dated by it")
        let count = await strokes(diary, on: b)
        XCTAssertEqual(count, 2)
        try await settled()
    }

    func testAPullKeepsALockSetHere() async throws {
        let diary = try await makeNotebook("Diary", on: a)
        try await sync(a)
        try await sync(b)

        try await file(diary.id, on: a, at: .now) { $0.isLocked = true }
        try await edit(diary.id, on: b, strokes: 5, after: 60)
        try await sync(b)
        let report = try await sync(a)
        XCTAssertEqual(report.pulled, [diary.id])
        XCTAssertEqual(report.stateSent, [diary.id])
        XCTAssertEqual(report.conflictCopies, [])
        let here = try await library(diary.id, on: a)
        XCTAssertTrue(here.isLocked, "newer pages from a device that never had the lock don't take it off")
        let count = await strokes(diary, on: a)
        XCTAssertEqual(count, 5)

        let back = try await sync(b)
        XCTAssertEqual(back.stateReceived, [diary.id])
        let there = try await library(diary.id, on: b)
        XCTAssertTrue(there.isLocked, "and the lock reaches that device")
        try await settled()
    }

    func testEachPartOfTheFilingGoesByItsOwnDate() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        // Locked here first; the other device, which hasn't heard of the lock, changes other things afterwards.
        let earlier = Date.now, later = earlier.addingTimeInterval(30), shelf = UUID(), drawer = UUID()
        try await file(notes.id, on: a, at: earlier) {
            $0.isLocked = true
            $0.folderID = shelf
        }
        try await file(notes.id, on: b, at: later) {
            $0.isFavorite = true
            $0.folderID = drawer
        }
        try await sync(b)
        let report = try await sync(a)
        XCTAssertEqual(report.stateSent, [notes.id])
        XCTAssertEqual(report.stateReceived, [notes.id])
        try await sync(b)
        for root in [a!, b!] {
            let state = try await library(notes.id, on: root)
            XCTAssertTrue(state.isLocked, "a later favourite made elsewhere doesn't take the lock off")
            XCTAssertTrue(state.isFavorite)
            XCTAssertEqual(state.folderID, drawer, "where both devices moved it, the later move stands")
        }
        try await settled()

        try await file(notes.id, on: b, at: later.addingTimeInterval(30)) { $0.isLocked = false }
        try await sync(b)
        try await sync(a)
        let unlocked = try await library(notes.id, on: a)
        XCTAssertFalse(unlocked.isLocked, "only a later unlock does")
        XCTAssertTrue(unlocked.isFavorite)
    }

    func testALockFromBeforeChangesWereStampedIsNeverDropped() async throws {
        let diary = try await makeNotebook("Diary", on: a), journal = try await makeNotebook("Journal", on: a)
        try await sync(a)
        try await sync(b)
        // Locked by a build that neither stamped nor sent it.
        try await file(diary.id, on: a, at: nil) { $0.isLocked = true }
        try await file(journal.id, on: a, at: nil) { $0.isLocked = true }
        try await file(diary.id, on: b, at: .now) { $0.isFavorite = true }
        try await sync(b)

        let report = try await sync(a)
        XCTAssertEqual(Set(report.stateSent), [diary.id, journal.id], "the unsent lock goes up, and the newer favourite doesn't cost the other its lock")
        XCTAssertEqual(report.stateReceived, [diary.id])
        let here = try await library(diary.id, on: a)
        XCTAssertTrue(here.isLocked && here.isFavorite)
        try await sync(b)
        for id in [diary.id, journal.id] {
            let there = try await library(id, on: b)
            XCTAssertTrue(there.isLocked)
        }
        try await settled()

        try await file(journal.id, on: b, at: Date.now.addingTimeInterval(1)) { $0.isLocked = false }
        try await sync(b)
        try await sync(a)
        let journalHere = try await library(journal.id, on: a)
        XCTAssertFalse(journalHere.isLocked, "and taking such a lock off still carries over")
    }

    func testAConflictedCopyOfALockedNotebookIsLocked() async throws {
        let diary = try await makeNotebook("Diary", on: a)
        try await sync(a)
        try await sync(b)

        // Locked on the device with the newer pages: the copy is made from the other's files, which never had the lock.
        try await file(diary.id, on: b, at: .now) { $0.isLocked = true }
        try await edit(diary.id, on: a, strokes: 3, after: 60)
        try await edit(diary.id, on: b, strokes: 7, after: 120)
        try await sync(a)
        let report = try await sync(b)
        XCTAssertEqual(report.conflictCopies.count, 1)
        XCTAssertEqual(report.pushed, [diary.id], "the newer pages keep the notebook's place")
        for id in b.packageIDs() {
            let state = try await library(id, on: b)
            XCTAssertTrue(state.isLocked, "the notebook and the copy kept beside it are both locked")
        }
        try await sync(b)
        try await sync(a)
        for id in a.packageIDs() {
            let state = try await library(id, on: a)
            XCTAssertTrue(state.isLocked)
        }
        XCTAssertEqual(a.packageIDs().count, 2)
        try await settled()
    }

    private func syncedLibrary(_ id: UUID) throws -> LibraryState {
        try ManifestCodec.decode(Data(contentsOf: cloud.package(id).appending(path: "manifest.json")), fallbackID: id).manifest.library
    }

    func testAStampInTheSyncedCopyNeverMovesBackwards() async throws {
        let diary = try await makeNotebook("Diary", on: a), c = temporaryRoot(self)
        let locked = Date.now, relocked = locked.addingTimeInterval(60)
        try await file(diary.id, on: a, at: locked) { $0.isLocked = true }
        try await sync(a)
        try await sync(b)
        _ = try await LibrarySync.run(root: c, cloud: cloud)

        // Unlocked on a third device that then stays out of reach, and on the second, which locks it again afterwards.
        try await file(diary.id, on: c, at: locked.addingTimeInterval(30)) { $0.isLocked = false }
        try await file(diary.id, on: b, at: locked.addingTimeInterval(40)) { $0.isLocked = false }
        try await file(diary.id, on: b, at: relocked) {
            $0.isLocked = true
            $0.isFavorite = true
        }
        try await sync(b)
        XCTAssertEqual(try XCTUnwrap(syncedLibrary(diary.id).changedAt(.locked)).timeIntervalSince(relocked), 0, accuracy: 0.001)

        // The first device still has the lock under its first stamp, and changes something else.
        try await file(diary.id, on: a, at: relocked.addingTimeInterval(60)) { $0.tags = ["private"] }
        let report = try await sync(a)
        XCTAssertEqual(report.stateSent, [diary.id])
        XCTAssertEqual(try XCTUnwrap(syncedLibrary(diary.id).changedAt(.locked)).timeIntervalSince(relocked), 0, accuracy: 0.001,
                       "sending the tags doesn't put the lock's stamp back")

        _ = try await LibrarySync.run(root: c, cloud: cloud)
        try await sync(a)
        try await sync(b)
        for root in [a!, b!, c] {
            let state = try await library(diary.id, on: root)
            XCTAssertTrue(state.isLocked, "so an unlock from before the lock was put back doesn't take it off")
            XCTAssertEqual(state.tags, ["private"])
        }
    }

    func testWritingTheDeletingDeviceHadNotSeenComesOutOfRecentlyDeleted() async throws {
        let notes = try await makeNotebook("Notes", on: a), unread = try await makeNotebook("Unread", on: a)
        try await sync(a)
        try await sync(b)

        let trashed = Date.now
        for id in [notes.id, unread.id] { try await file(id, on: a, at: trashed) { $0.deletedAt = trashed } }
        try await sync(a)
        // Written in on a device that hasn't heard it was deleted.
        try await edit(notes.id, on: b, strokes: 4, after: 60)
        let report = try await sync(b)
        XCTAssertEqual(report.pushed, [notes.id])
        XCTAssertEqual(report.stateReceived, [unread.id], "a notebook nobody wrote in follows into Recently Deleted")
        let written = try await library(notes.id, on: b), untouched = try await library(unread.id, on: b)
        XCTAssertNil(written.deletedAt, "one just written in doesn't: writing wins, as it does over a permanent delete")
        XCTAssertNotNil(untouched.deletedAt)

        let back = try await sync(a)
        XCTAssertEqual(back.pulled, [notes.id])
        let restored = try await library(notes.id, on: a)
        XCTAssertNil(restored.deletedAt, "and it comes back out on the device that deleted it")
        let count = await strokes(notes, on: a)
        XCTAssertEqual(count, 4)
        try await settled()

        // Deleted again by a device that has the writing, it stays deleted.
        let again = Date.now.addingTimeInterval(120)
        try await file(notes.id, on: a, at: again) { $0.deletedAt = again }
        try await sync(a)
        try await sync(b)
        let gone = try await library(notes.id, on: b)
        XCTAssertNotNil(gone.deletedAt)
    }

    // MARK: A device whose clock runs fast

    func testAChangeIsStampedNowWhenNoStampIsAhead() throws {
        let now = Date.now
        var state = LibraryState()
        state.setChangedAt(now.addingTimeInterval(-60), for: .locked)
        let before = state
        state.isLocked = true
        state.isFavorite = true
        state.stamp(changesSince: before, at: now)
        XCTAssertEqual(try XCTUnwrap(state.changedAt(.locked)).timeIntervalSince(now), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(state.changedAt(.favorite)).timeIntervalSince(now), 0, accuracy: 0.001)
        XCTAssertNil(state.changedAt(.tags))

        state.setChangedAt(now.addingTimeInterval(8 * 60), for: .tags)
        let ahead = try XCTUnwrap(state.changedAt(.tags)), untagged = state
        state.tags = ["late"]
        state.stamp(changesSince: untagged, at: now)
        XCTAssertEqual(try XCTUnwrap(state.changedAt(.tags)).timeIntervalSince(ahead), 0.001, accuracy: 0.0001, "a stamp ahead of the clock is overtaken instead")
    }

    @MainActor
    func testALockMadeAfterSeeingAFastClockedUnlockWins() async throws {
        let diary = try await makeNotebook("Diary", on: a)
        try await file(diary.id, on: a, at: Date.now.addingTimeInterval(-60)) { $0.isLocked = true }
        try await sync(a)
        try await sync(b)
        let store = try device(a)
        await store.reloadFromDisk()

        // Unlocked on a device whose clock is eight minutes fast, and locked again here after that arrives.
        let fast = Date.now.addingTimeInterval(8 * 60)
        try await file(diary.id, on: b, at: fast) { $0.isLocked = false }
        try await sync(b)
        try await pass(store)
        let record = try XCTUnwrap(store.record(diary.id))
        XCTAssertFalse(record.isLocked)
        store.setLocked(true, for: [record])
        try await pass(store)
        try await sync(b)
        for root in [a!, b!] {
            let state = try await library(diary.id, on: root)
            XCTAssertTrue(state.isLocked, "the lock made last stands, whatever the other clock said")
        }
        try await settled()
    }

    @MainActor
    func testARestoreMadeAfterSeeingAFastClockedDeleteWinsAndIsNotPurged() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)

        // Forty days ago, deleted on a device whose clock was eight minutes fast, and restored here three minutes later.
        let deleted = Date.now.addingTimeInterval(-40 * 86_400), fast = deleted.addingTimeInterval(8 * 60)
        try await file(notes.id, on: b, at: fast) { $0.deletedAt = fast }
        try await sync(b)
        try await sync(a)
        let binned = try await library(notes.id, on: a)
        XCTAssertNotNil(binned.deletedAt)
        try await file(notes.id, on: a, at: deleted.addingTimeInterval(3 * 60)) { $0.deletedAt = nil }
        try await sync(a)
        try await sync(b)
        try await settled()
        for root in [a!, b!] {
            let state = try await library(notes.id, on: root)
            XCTAssertNil(state.deletedAt, "the restore stands")
            let store = try device(root)
            await store.reloadFromDisk()
            await store.purgeExpiredTrash()
            XCTAssertNotNil(store.record(notes.id), "so its 30 days never run out")
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.package(notes.id).path(percentEncoded: false)))
        }
    }

    // MARK: A synced copy that isn't the one this device knew

    private func fill(_ root: StorageRoot, folder: String = "Science", sticker: String = "cat.png") throws {
        var file = FolderFile.read(root)
        file.folders.append(FolderEntry(id: UUID(), name: folder, clothRaw: "jade", createdAt: .now, sortIndex: file.folders.count))
        try file.write(root)
        try FileManager.default.createDirectory(at: root.stickers, withIntermediateDirectories: true)
        try Data([1]).write(to: root.stickers.appending(path: sticker))
    }

    private func stickers(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
    }

    func testAnErasedCopyIsFilledAgainAndNothingIsDeleted() async throws {
        let physics = try await makeNotebook("Physics", on: a)
        try fill(a)
        let first = try await sync(a)
        XCTAssertFalse(first.startedAgain)
        try FileManager.default.removeItem(at: cloud.url)

        let report = try await sync(a)
        XCTAssertTrue(report.startedAgain)
        XCTAssertEqual(report.pushed, [physics.id])
        XCTAssertFalse(report.changedHere)
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name), ["Science"], "a folder missing from an erased copy was never deleted")
        XCTAssertEqual(stickers(in: a.stickers), ["cat.png"])
        XCTAssertEqual(stickers(in: cloud.stickers), ["cat.png"], "and the copy is filled again")
        let again = try await sync(a)
        XCTAssertEqual(again, SyncReport())
    }

    func testACopyRefilledByAnotherDeviceDeletesNothingHere() async throws {
        try fill(a)
        try await sync(a)
        try await sync(b)
        // Made here and synced, but the other device never saw them before the copy was erased.
        try fill(b, folder: "Art", sticker: "dog.png")
        try await sync(b)
        try FileManager.default.removeItem(at: cloud.url)
        try await sync(a)
        XCTAssertEqual(stickers(in: cloud.stickers), ["cat.png"])

        let report = try await sync(b)
        XCTAssertTrue(report.startedAgain, "the copy is not the one this device agreed with")
        XCTAssertEqual(FolderFile.read(b).folders.map(\.name).sorted(), ["Art", "Science"])
        XCTAssertEqual(stickers(in: b.stickers), ["cat.png", "dog.png"])
        try await sync(a)
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name).sorted(), ["Art", "Science"])
        XCTAssertEqual(stickers(in: a.stickers), ["cat.png", "dog.png"])
    }

    func testAnotherAccountsCopyIsOnlyAddedTo() async throws {
        let mine = try await makeNotebook("Mine", on: a)
        try fill(a)
        _ = try await LibrarySync.run(root: a, cloud: cloud, account: "one")
        XCTAssertEqual(SyncState.read(a).account, "one")
        XCTAssertEqual(SyncState.read(a).copy, try String(contentsOf: cloud.copyFile, encoding: .utf8))

        let other = CloudFolder(url: temporaryRoot(self).url)
        let theirs = try await makeNotebook("Theirs", on: b)
        _ = try await LibrarySync.run(root: b, cloud: other, account: "two")

        let report = try await LibrarySync.run(root: a, cloud: other, account: "two")
        XCTAssertTrue(report.startedAgain)
        XCTAssertEqual(report.pushed, [mine.id])
        XCTAssertEqual(report.pulled, [theirs.id])
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name), ["Science"], "nothing synced under the first account is taken as deleted")
        XCTAssertEqual(stickers(in: a.stickers), ["cat.png"])
        XCTAssertEqual(SyncState.read(a).account, "two")
    }

    func testADeviceThatSyncedBeforeCopiesWereNamedKeepsWhatItAgreed() async throws {
        let old = try await makeNotebook("Old", on: a)
        try fill(a)
        try await sync(a)
        try await sync(b)
        // As an older build left things: no name on the copy, none in either device's state.
        try FileManager.default.removeItem(at: cloud.copyFile)
        for root in [a!, b!] {
            var state = SyncState.read(root)
            state.copy = nil
            try state.write(root)
        }

        try FileManager.default.removeItem(at: b.package(old.id))
        var folders = FolderFile.read(b)
        folders.folders = []
        try folders.write(b)
        let removed = try await sync(b)
        XCTAssertFalse(removed.startedAgain)
        XCTAssertEqual(removed.removedThere, [old.id])
        let report = try await sync(a)
        XCTAssertFalse(report.startedAgain)
        XCTAssertEqual(report.removedHere, [old.id], "a notebook deleted on the other device still goes: its marker says so")
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name), ["Science"], "a folder is kept, since the copy could as well have been erased and filled again")
        XCTAssertEqual(SyncState.read(a).copy, SyncState.read(b).copy)
        try await sync(b)
        XCTAssertEqual(FolderFile.read(b).folders.map(\.name), ["Science"])
    }

    func testAnErasedCopyDeletesNothingOnADeviceFromBeforeCopiesWereNamed() async throws {
        let physics = try await makeNotebook("Physics", on: a)
        try fill(a)
        try await sync(a)
        // As an older build left the device, and then the copy in iCloud was erased.
        var state = SyncState.read(a)
        state.copy = nil
        try state.write(a)
        try FileManager.default.removeItem(at: cloud.url)

        let report = try await sync(a)
        XCTAssertTrue(report.startedAgain, "an empty copy that was never named isn't the one this device agreed with")
        XCTAssertEqual(report.pushed, [physics.id])
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name), ["Science"], "so its folders")
        XCTAssertEqual(stickers(in: a.stickers), ["cat.png"], "and stickers were never deleted")
        XCTAssertEqual(stickers(in: cloud.stickers), ["cat.png"])
    }

    func testACopyRefilledByAnotherDeviceDeletesNothingOnADeviceFromBeforeCopiesWereNamed() async throws {
        try fill(a)
        try await sync(a)
        try await sync(b)
        try fill(a, folder: "Art", sticker: "dog.png")
        try await sync(a)
        // As an older build left the first device. Then the copy was erased, and the second filled it again first.
        var state = SyncState.read(a)
        state.copy = nil
        try state.write(a)
        try FileManager.default.removeItem(at: cloud.url)
        try await sync(b)
        XCTAssertEqual(stickers(in: cloud.stickers), ["cat.png"])

        try await sync(a)
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name).sorted(), ["Art", "Science"], "a folder missing from a copy this device never agreed with was not deleted")
        XCTAssertEqual(stickers(in: a.stickers), ["cat.png", "dog.png"])
        try await sync(b)
        XCTAssertEqual(FolderFile.read(b).folders.map(\.name).sorted(), ["Art", "Science"])
        XCTAssertEqual(stickers(in: b.stickers), ["cat.png", "dog.png"])
    }

    func testAFreshStartIsSavedBeforeTheCopyIsNamed() async throws {
        try await makeNotebook("Physics", on: a)
        try fill(a)
        try await sync(a)
        var state = SyncState.read(a)
        state.copy = nil
        try state.write(a)
        // The copy was erased, and this pass gets no further than trying to name the new one.
        try FileManager.default.removeItem(at: cloud.url)
        for directory in [cloud.library, cloud.tombstones] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let container = cloud.url
        try permit(0o555, container)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path(percentEncoded: false)) }
        do {
            try await sync(a)
            XCTFail("the copy can't be named")
        } catch {}
        XCTAssertFalse(SyncState.read(a).holdsAnything, "what was agreed with the erased copy is forgotten before the new one has a name to be taken for it")
    }

    func testAFileStillOnItsWayDownIsWaitedForAndNotTakenAsMissing() async throws {
        try await makeNotebook("Physics", on: a)
        try fill(a)
        try await sync(a)
        try await sync(b)
        // iCloud lists a file it hasn't downloaded as ".<name>.icloud", with nothing under the name itself.
        for file in [cloud.copyFile, cloud.foldersFile] {
            let placeholder = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).icloud")
            try FileManager.default.moveItem(at: file, to: placeholder)
            do {
                try await sync(b)
                XCTFail("\(file.lastPathComponent) hasn't arrived")
            } catch {
                XCTAssertEqual(error as? SyncError, .stillArriving)
            }
            try FileManager.default.moveItem(at: placeholder, to: file)
        }
        XCTAssertEqual(FolderFile.read(b).folders.map(\.name), ["Science"], "a folder isn't deleted because its list was still coming down")
        let report = try await sync(b)
        XCTAssertEqual(report, SyncReport(), "and the copy is still the one this device knew")
    }

    func testACopyIDThatCannotBeReadIsWaitedForAndNotReplaced() async throws {
        try await makeNotebook("Physics", on: a)
        try await sync(a)
        try await sync(b)
        let name = try String(contentsOf: cloud.copyFile, encoding: .utf8)
        let copyFile = cloud.copyFile
        try permit(0o000, copyFile)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copyFile.path(percentEncoded: false)) }

        do {
            try await sync(a)
            XCTFail("a copy whose name can't be read yet isn't synced with")
        } catch {
            XCTAssertEqual(error as? SyncError, .stillArriving)
        }
        try permit(0o644, copyFile)
        XCTAssertEqual(try String(contentsOf: copyFile, encoding: .utf8), name, "and it isn't given a new name, which every device would take for another copy")
        let report = try await sync(b)
        XCTAssertFalse(report.startedAgain)
    }

    func testFoldersThatCannotBeReadAreWaitedForAndNotTakenAsDeleted() async throws {
        try fill(a)
        try await sync(a)
        try await sync(b)
        let foldersFile = cloud.foldersFile
        try permit(0o000, foldersFile)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: foldersFile.path(percentEncoded: false)) }

        do {
            try await sync(b)
            XCTFail("folders that can't be read yet aren't merged")
        } catch {
            XCTAssertEqual(error as? SyncError, .stillArriving)
        }
        XCTAssertEqual(FolderFile.read(b).folders.map(\.name), ["Science"], "a folder isn't deleted here because its list couldn't be read")
        try permit(0o644, foldersFile)
        try await sync(b)
        try await sync(a)
        XCTAssertEqual(FolderFile.read(a).folders.map(\.name), ["Science"])
    }

    func testAPullInterruptedByAQuitIsClearedAway() async throws {
        let physics = try await makeNotebook("Physics", on: a)
        try await sync(a)
        let stray = b.arriving.appending(path: "\(physics.id.uuidString)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: b.arriving, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: cloud.package(physics.id), to: stray)

        LibrarySync.sweepArriving(root: b)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: b.arriving.path(percentEncoded: false)), [])
        let report = try await sync(b)
        XCTAssertEqual(report.pulled, [physics.id], "and the next pull has somewhere to assemble")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: b.arriving.path(percentEncoded: false)), [])
    }

    func testTheLaunchSweepLeavesAPullThatIsUnderWay() async throws {
        let physics = try await makeNotebook("Physics", on: a)
        try await sync(a)
        try await sync(b)
        try await edit(physics.id, on: a, strokes: 3, after: 60)
        try await sync(a)
        let fileManager = FileManager.default
        let leftOver = b.arriving.appending(path: "\(UUID().uuidString)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: leftOver, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(50))
        let launched = Date.now
        try await Task.sleep(for: .milliseconds(50))

        // Another writer holds the synced notebook, so b's pull stops with its copy half-assembled in Arriving.
        let held = Shared(false), released = Shared(false)
        addTeardownBlock { released.value = true }
        let synced = cloud.package(physics.id)
        Thread.detachNewThread {
            NSFileCoordinator().coordinate(writingItemAt: synced, options: .forMerging, error: nil) { _ in
                held.value = true
                while !released.value { Thread.sleep(forTimeInterval: 0.005) }
            }
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date.now.addingTimeInterval(10)
            while !condition(), Date.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        }
        try await waitUntil { held.value }
        let device: StorageRoot = b, remote: CloudFolder = cloud
        let pulling = Task.detached { try await LibrarySync.run(root: device, cloud: remote) }
        func arriving() -> [String] { (try? fileManager.contentsOfDirectory(atPath: device.arriving.path(percentEncoded: false))) ?? [] }
        try await waitUntil { arriving().count == 2 }
        let underWay = arriving().filter { $0 != leftOver.lastPathComponent }
        XCTAssertEqual(underWay.count, 1, "the pull has begun")

        LibraryStore.sweepDeleted(root: device)
        LibrarySync.sweepArriving(root: device, untouchedSince: launched)
        LibraryStore.sweepUnfinished(root: device, untouchedSince: launched)
        XCTAssertEqual(arriving(), underWay, "only what a quit left before launch goes")
        XCTAssertEqual(device.packageIDs(), [physics.id])
        released.value = true
        let report = try await pulling.value
        XCTAssertEqual(report.pulled, [physics.id])
        let pulledStrokes = await strokes(physics, on: device)
        XCTAssertEqual(pulledStrokes, 3)
        XCTAssertEqual(arriving(), [])
    }

    func testADateIsTheSameHoweverOftenItIsRewritten() throws {
        for millisecond in 0..<1000 {
            let written = "2026-10-12T08:47:02.\(String(format: "%03d", millisecond))"
            var date = try XCTUnwrap(ManifestCodec.parseDate(written))
            for _ in 0..<5 { date = try XCTUnwrap(ManifestCodec.encodeDate(date).stringValue.flatMap(ManifestCodec.parseDate)) }
            XCTAssertEqual(ManifestCodec.encodeDate(date).stringValue, written)
        }
        let between = try XCTUnwrap(ManifestCodec.parseDate("2026-10-12T08:47:02.409")).addingTimeInterval(0.0006)
        XCTAssertEqual(ManifestCodec.encodeDate(between).stringValue, "2026-10-12T08:47:02.410", "a date is written to the nearest millisecond")
    }

    func testAPackageUnderTheOldNameInTheSyncedCopyIsLeftAlone() async throws {
        let physics = try await makeNotebook("Physics", on: a)
        try await sync(a)
        let synced = cloud.package(physics.id)
        try FileManager.default.moveItem(at: synced, to: synced.deletingPathExtension().appendingPathExtension(StorageRoot.legacyPackageExtension))

        let report = try await sync(b)
        XCTAssertEqual(report, SyncReport(), "a name the app never writes to the synced copy is neither pulled nor deleted")
        XCTAssertEqual(b.packageIDs(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.library.path(percentEncoded: false)).filter { $0.hasSuffix(".\(StorageRoot.legacyPackageExtension)") }.count, 1)
    }

    // MARK: A manifest that arrives ahead of its ink

    private enum Delivery: CaseIterable { case missing, stale, placeholder, asset }

    /// A's writing as B's copy of the synced copy has it so far: A's new manifest, and not yet the file it was written after.
    /// Returns where that file belongs and what it holds once it comes.
    private func manifestAhead(_ delivery: Delivery, title: String) async throws -> (notes: NotebookManifest, file: URL, contents: Data) {
        let notes = try await makeNotebook(title, on: a)
        try await sync(a)
        try await sync(b)
        let package = NotebookPackage(root: a, id: notes.id)
        var file = cloud.package(notes.id).appending(path: notes.pages[0].inkFile)
        if delivery == .asset {
            var manifest = try await package.readManifest().manifest
            let name = try await package.writeAsset(Data([1, 2, 3]), ext: "png")
            manifest.pages.append(NotebookPage(background: .image(file: name), paperColor: .white, size: PageSize.letter.points))
            manifest.modifiedAt = manifest.modifiedAt.addingTimeInterval(60)
            try await package.writeManifest(manifest)
            file = cloud.package(notes.id).appending(path: "assets/\(name)")
        } else {
            try await edit(notes.id, on: a, strokes: 5, after: 60)
        }
        try await sync(a)
        let contents = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        switch delivery {
        case .missing, .asset: break
        // Still the file B already has, date and all, as iCloud leaves it until the new one comes down.
        case .stale: try FileManager.default.copyItem(at: b.package(notes.id).appending(path: notes.pages[0].inkFile), to: file)
        case .placeholder: try Data().write(to: file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).icloud"))
        }
        return (notes, file, contents)
    }

    private func arrive(_ contents: Data, at file: URL) throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).icloud"))
        try? FileManager.default.removeItem(at: file)
        try contents.write(to: file)
    }

    /// The strokes on each page of the notebook with this title.
    private func pages(titled title: String, on root: StorageRoot) async throws -> [Int] {
        for id in root.packageIDs() {
            let manifest = try await NotebookPackage(root: root, id: id).readManifest().manifest
            guard manifest.title == title else { continue }
            var counts: [Int] = []
            for page in manifest.pages.indices { counts.append(await strokes(manifest, on: root, page: page)) }
            return counts
        }
        return []
    }

    func testAPullWaitsForWhatItsManifestNamesAndFinishesOnceItArrives() async throws {
        for delivery in Delivery.allCases {
            let title = "\(delivery)"
            let (notes, file, contents) = try await manifestAhead(delivery, title: title)
            let early = try await sync(b)
            XCTAssertEqual(early.waiting, [notes.id], title)
            XCTAssertEqual(early.pulled, [], "\(title): the notebook isn't swapped in without it")
            let agreed = try XCTUnwrap(SyncState.read(b).notebooks[notes.id])
            XCTAssertEqual(agreed.timeIntervalSince(notes.modifiedAt), 0, accuracy: 0.002, "\(title): nor is A's date taken as agreed")
            let kept = try await pages(titled: title, on: b)
            XCTAssertEqual(kept, [1, 0], "\(title): B keeps what it had")
            let again = try await sync(b)
            XCTAssertEqual(again.waiting, [notes.id], "\(title): and goes on waiting")

            try arrive(contents, at: file)
            let later = try await sync(b)
            XCTAssertEqual(later.pulled, [notes.id], "\(title): a later pass brings it in once it has arrived")
            let arrived = try await pages(titled: title, on: b)
            XCTAssertEqual(arrived, delivery == .asset ? [1, 0, 0] : [5, 0], title)
            if delivery == .asset {
                XCTAssertTrue(FileManager.default.fileExists(atPath: b.package(notes.id).appending(path: "assets/\(file.lastPathComponent)").path(percentEncoded: false)))
            }
            try await settled()
        }
    }

    func testAPageThatHasNotArrivedIsNeverSentBackOverTheWritingItMissed() async throws {
        for bWritesLater in [true, false] {
            let title = bWritesLater ? "Later" : "Earlier"
            let (notes, file, contents) = try await manifestAhead(.stale, title: title)
            let manifest = cloud.package(notes.id).appending(path: "manifest.json")
            let syncedManifest = try Data(contentsOf: manifest), stale = try Data(contentsOf: file)
            try await edit(notes.id, on: b, page: 1, strokes: 2, after: bWritesLater ? 120 : 30)
            let early = try await sync(b)
            XCTAssertEqual(early.waiting, [notes.id], title)
            XCTAssertEqual(early.pushed, [], title)
            XCTAssertEqual(try Data(contentsOf: manifest), syncedManifest, "\(title): nothing B wrote goes over A's while A's page is on its way")
            XCTAssertEqual(try Data(contentsOf: file), stale, title)

            try arrive(contents, at: file)
            try await sync(b)
            try await sync(b)
            try await sync(a)
            try await settled()
            for root in [a!, b!] {
                let original = try await pages(titled: title, on: root), copy = try await pages(titled: "\(title) (conflicted copy)", on: root)
                XCTAssertEqual(original, bWritesLater ? [1, 2] : [5, 0], "\(title): the newer version keeps the notebook's place")
                XCTAssertEqual(copy, bWritesLater ? [5, 0] : [1, 2], "\(title): and the other is kept beside it, A's page with it")
            }
        }
    }

    func testAStickerICloudHasEvictedIsNotTakenForDeleted() async throws {
        try fill(a)
        try await sync(a)
        try await sync(b)
        let fileManager = FileManager.default
        try fileManager.moveItem(at: cloud.stickers.appending(path: "cat.png"), to: cloud.stickers.appending(path: ".cat.png.icloud"))
        let evicted = try await sync(b)
        XCTAssertFalse(evicted.stickersChanged)
        XCTAssertEqual(stickers(in: b.stickers), ["cat.png"], "a sticker iCloud evicted from the synced copy isn't deleted here")
        try await sync(a)
        XCTAssertEqual(stickers(in: a.stickers), ["cat.png"])
        XCTAssertEqual(stickers(in: cloud.stickers), [".cat.png.icloud"], "nor sent again over its placeholder")

        try Data([3]).write(to: cloud.stickers.appending(path: ".dog.png.icloud"))
        let early = try await sync(b)
        XCTAssertFalse(early.stickersChanged)
        XCTAssertEqual(stickers(in: b.stickers), ["cat.png"], "a new sticker still on its way isn't copied as its placeholder")
        try fileManager.moveItem(at: cloud.stickers.appending(path: ".dog.png.icloud"), to: cloud.stickers.appending(path: "dog.png"))
        let arrived = try await sync(b)
        XCTAssertTrue(arrived.stickersChanged)
        XCTAssertEqual(stickers(in: b.stickers), ["cat.png", "dog.png"])

        try fileManager.removeItem(at: b.stickers.appending(path: "cat.png"))
        try await sync(b)
        XCTAssertEqual(stickers(in: cloud.stickers), ["dog.png"], "and one deleted here goes from the synced copy while evicted there")
    }

    func testThePreDownloadSaysWhatHadNotArrivedWhenItGaveUp() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        let ink = try inkFile(of: notes.id)
        try FileManager.default.moveItem(at: ink, to: ink.deletingLastPathComponent().appending(path: ".\(ink.lastPathComponent).icloud"))
        let left = await CloudFiles.download([ink], within: .milliseconds(200))
        XCTAssertEqual(left.map(\.lastPathComponent), [ink.lastPathComponent])
        let report = try await sync(b)
        XCTAssertEqual(report.waiting, [notes.id], "a notebook still coming down is left for later, not pulled part-way")
        XCTAssertEqual(b.packageIDs(), [])
    }

    func testANotebookIsDeclaredAPackage() throws {
        let type = try XCTUnwrap(UTType(filenameExtension: StorageRoot.packageExtension, conformingTo: .package))
        XCTAssertEqual(type.identifier, "com.owais.owlluna.notebook")
        XCTAssertTrue(type.conforms(to: .package))
    }

    // MARK: Flashcards

    private func card(_ question: String, image: String? = nil) -> Flashcard {
        Flashcard(front: CardSide(text: question, image: image), back: CardSide(text: "Answer"))
    }

    private var clipping: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func deck(_ id: UUID, on root: StorageRoot, cards: [Flashcard] = []) async -> FlashcardLibrary {
        let library = await FlashcardLibrary(root: root)
        await library.load()
        if !cards.isEmpty {
            await library.add(cards, to: id)
            await library.flush()
        }
        return library
    }

    private func cards(_ id: UUID, on root: StorageRoot) -> [String: Flashcard] {
        Dictionary(CardFiles.read(root.package(id)).cards.map { ($0.front.text, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func hasClipping(_ name: String, _ id: UUID, on root: StorageRoot) -> Bool {
        FileManager.default.fileExists(atPath: CardFiles.imageURL(name, in: root.package(id)).path(percentEncoded: false))
    }

    func testReviewsAndNewCardsMadeWithoutWritingSurviveAPullOfAnotherDevicesWriting() async throws {
        let biology = try await makeNotebook("Biology", on: a)
        let onA = await deck(biology.id, on: a, cards: (1...40).map { card("Question \($0)") })
        try await sync(a)
        try await sync(b)

        // 1. On A, forty cards are reviewed and a study guide's questions are saved as cards, one with a clipping. No page is written on.
        for each in await onA.cards(in: biology.id) { await onA.grade(each.id, in: biology.id, .good) }
        let clipped = try await onA.saveClipping(clipping, in: biology.id)
        await onA.add([card("From the guide"), card("Clipped", image: clipped)], to: biology.id)
        await onA.flush()
        try await sync(a)
        // 2. On B, one stroke goes into the notebook, and B sends its copy.
        try await edit(biology.id, on: b, strokes: 2, after: 60)
        try await sync(b)
        // 3. A has written nothing, so it takes B's pages.
        let report = try await sync(a)
        XCTAssertEqual(report.conflictCopies, [])
        let count = await strokes(biology, on: a)
        XCTAssertEqual(count, 2, "B's writing arrives")
        let kept = cards(biology.id, on: a)
        XCTAssertEqual(kept.count, 42, "and A's new cards are still there")
        XCTAssertEqual(kept.values.filter { $0.reviews == 1 }.count, 40, "with its reviews")
        XCTAssertTrue(hasClipping(clipped, biology.id, on: a))

        try await sync(b)
        let arrived = cards(biology.id, on: b)
        XCTAssertEqual(arrived.count, 42, "B gets them too")
        XCTAssertEqual(arrived.values.filter { $0.reviews == 1 }.count, 40)
        XCTAssertTrue(hasClipping(clipped, biology.id, on: b))
        try await settled()
    }

    func testAnswersGivenOnBothDevicesAreAllKept() async throws {
        let biology = try await makeNotebook("Biology", on: a)
        let questions = (1...4).map { card("Question \($0)") }
        let onA = await deck(biology.id, on: a, cards: questions)
        try await sync(a)
        try await sync(b)
        let onB = await deck(biology.id, on: b)
        let soon = Date.now.addingTimeInterval(60), later = soon.addingTimeInterval(60)

        await onA.grade(questions[0].id, in: biology.id, .good, now: soon)
        await onA.grade(questions[1].id, in: biology.id, .good, now: soon)
        await onA.remove([questions[3].id], from: biology.id, now: soon)
        await onB.grade(questions[2].id, in: biology.id, .good, now: soon)
        await onB.grade(questions[0].id, in: biology.id, .easy, now: later)
        await onA.flush()
        await onB.flush()
        let sent = try await sync(a)
        XCTAssertEqual(sent.cardsSent, [biology.id])
        XCTAssertEqual(sent.pushed, [], "the pages aren't sent again")
        let both = try await sync(b)
        XCTAssertEqual(both.cardsReceived, [biology.id])
        XCTAssertEqual(both.cardsSent, [biology.id])
        XCTAssertTrue(both.changedHere, "which has the decks read again")
        let back = try await sync(a)
        XCTAssertEqual(back.cardsReceived, [biology.id])
        for root in [a!, b!] {
            let kept = cards(biology.id, on: root)
            XCTAssertEqual(kept.keys.sorted(), ["Question 1", "Question 2", "Question 3"], "a card deleted on one iPad doesn't come back from the other")
            XCTAssertEqual(kept["Question 1"]?.interval, 4, "where both answered a card, the later answer stands")
            XCTAssertEqual(kept["Question 2"]?.reviews, 1)
            XCTAssertEqual(kept["Question 3"]?.reviews, 1, "and answers from both iPads are kept")
        }
        XCTAssertEqual(b.packageIDs().count, 1, "with no conflicted copy")
        try await settled()

        await onB.load()
        let loaded = await onB.cards(in: biology.id)
        XCTAssertEqual(loaded.count, 3, "the deck in memory takes what the sync brought")
    }

    func testANewCardOnOneDeviceAndAStrokeOnTheOtherAreBothKept() async throws {
        let biology = try await makeNotebook("Biology", on: a)
        _ = await deck(biology.id, on: a, cards: [card("Old")])
        try await sync(a)
        try await sync(b)

        let onA = await deck(biology.id, on: a)
        let clipped = try await onA.saveClipping(clipping, in: biology.id)
        await onA.add([card("New", image: clipped)], to: biology.id)
        await onA.flush()
        try await edit(biology.id, on: b, strokes: 3, after: 60)
        try await sync(b)

        let report = try await sync(a)
        XCTAssertEqual(report.pulled, [biology.id], "A has written nothing, so it takes B's pages")
        XCTAssertEqual(report.cardsSent, [biology.id], "and sends its card")
        XCTAssertEqual(report.conflictCopies, [])
        XCTAssertEqual(cards(biology.id, on: a).keys.sorted(), ["New", "Old"])
        XCTAssertTrue(hasClipping(clipped, biology.id, on: a))
        let pulled = await strokes(biology, on: a)
        XCTAssertEqual(pulled, 3)

        let received = try await sync(b)
        XCTAssertEqual(received.cardsReceived, [biology.id])
        XCTAssertEqual(cards(biology.id, on: b).keys.sorted(), ["New", "Old"])
        XCTAssertTrue(hasClipping(clipped, biology.id, on: b))
        try await settled()
    }

    func testAnAnswerGivenWhileAPullHasTheNotebookLandsOnWhatItBroughtIn() async throws {
        let biology = try await makeNotebook("Biology", on: a)
        let question = card("Question")
        let onA = await deck(biology.id, on: a, cards: [question])
        try await sync(a)
        try await sync(b)
        try await edit(biology.id, on: b, strokes: 4, after: 60)
        try await sync(b)

        let answered = Shared(false)
        let report = try await LibrarySync.run(root: a, cloud: cloud, take: { id in
            await MainActor.run {
                guard DocumentRegistry.shared.take(id) else { return false }
                // Answered once the pass has the notebook in hand, before it pulls.
                onA.grade(question.id, in: biology.id, .good)
                answered.value = true
                return true
            }
        }, release: { id in await MainActor.run { DocumentRegistry.shared.release(id) } })
        XCTAssertTrue(answered.value)
        XCTAssertEqual(report.pulled, [biology.id])
        await onA.flush()
        XCTAssertEqual(cards(biology.id, on: a)["Question"]?.reviews, 1, "the answer is written once the pull is done, onto what it brought in")
        let count = await strokes(biology, on: a)
        XCTAssertEqual(count, 4)

        try await sync(a)
        try await sync(b)
        XCTAssertEqual(cards(biology.id, on: b)["Question"]?.reviews, 1)
    }

    func testAConflictedCopysCardsAreCardsOfItsOwn() async throws {
        let biology = try await makeNotebook("Biology", on: a)
        _ = await deck(biology.id, on: a, cards: [card("One"), card("Two")])
        try await sync(a)
        try await sync(b)
        try await edit(biology.id, on: a, strokes: 3, after: 60)
        try await edit(biology.id, on: b, strokes: 5, after: 120)
        try await sync(a)
        let report = try await sync(b)
        let copy = try XCTUnwrap(report.conflictCopies.first)
        let original = CardFiles.read(b.package(biology.id)).cards, copied = CardFiles.read(b.package(copy)).cards
        XCTAssertEqual(copied.map(\.front.text), original.map(\.front.text), "the copy keeps the cards")
        XCTAssertTrue(Set(copied.map(\.id)).isDisjoint(with: original.map(\.id)), "under IDs of its own, so a sitting doesn't take them for the original's")

        try await sync(b)
        try await sync(a)
        XCTAssertEqual(CardFiles.read(a.package(copy)).cards.map(\.id), copied.map(\.id))
        try await settled()
    }

    // MARK: What a pass leaves, and why

    func testEachNotebookAPassLeavesIsListedWithWhy() async throws {
        let open = try await makeNotebook("Open", on: a), arriving = try await makeNotebook("Arriving", on: a)
        let damagedThere = try await makeNotebook("Damaged there", on: a), damagedHere = try await makeNotebook("Damaged here", on: a)
        try await sync(a)
        try FileManager.default.removeItem(at: cloud.package(arriving.id).appending(path: "manifest.json"))
        try Data().write(to: cloud.package(arriving.id).appending(path: ".manifest.json.icloud"))
        try Data("{".utf8).write(to: cloud.package(damagedThere.id).appending(path: "manifest.json"))
        try Data("{".utf8).write(to: a.package(damagedHere.id).appending(path: "manifest.json"))

        let report = try await sync(a, busy: [open.id])
        XCTAssertEqual(report.open, [open.id])
        XCTAssertEqual(report.arriving, [arriving.id], "a manifest iCloud hasn't brought down yet is waited for")
        XCTAssertEqual(Set(report.failed), [SyncFailure(id: damagedThere.id, reason: .unreadable(inICloud: true)),
                                            SyncFailure(id: damagedHere.id, reason: .unreadable(inICloud: false))],
                       "one that is there and won't read is a failure, and says which copy")
        XCTAssertEqual(Set(report.waiting), Set([open, arriving, damagedThere, damagedHere].map(\.id)))
    }

    func testACopyThatFailsIsListedWithItsErrorAndTriedAgain() async throws {
        let notes = try await makeNotebook("Notes", on: a, strokes: 2)
        let ink = try firstInk(of: notes.id, on: a)
        try permit(0o000, ink)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ink.path(percentEncoded: false)) }
        let failed = try await sync(a)
        XCTAssertEqual(failed.failed.map(\.id), [notes.id])
        XCTAssertEqual(failed.arriving, [], "it isn't taken for still arriving")
        guard case .other(let detail)? = failed.failed.first?.reason else { return XCTFail("a file that can't be read is said as the system says it") }
        XCTAssertFalse(detail.isEmpty)

        try permit(0o644, ink)
        let again = try await sync(a)
        XCTAssertEqual(again.failed, [])
        XCTAssertEqual(again.pushed, [notes.id])
    }

    func testANotebookICloudDriveWontHandOverIsListedAsSuch() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await edit(notes.id, on: a, strokes: 4, after: 60)
        let presenter = RefusingPresenter(cloud.package(notes.id))
        NSFileCoordinator.addFilePresenter(presenter)
        let failed = try await sync(a)
        NSFileCoordinator.removeFilePresenter(presenter)
        guard case .coordination? = failed.failed.first?.reason else { return XCTFail("got \(failed.failed)") }
        XCTAssertEqual(failed.failed.map(\.id), [notes.id])
        XCTAssertEqual(failed.pushed, [])

        let again = try await sync(a)
        XCTAssertEqual(again.pushed, [notes.id])
    }

    func testANotebookSavedByANewerVersionIsListedAsSuch() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await sync(a)
        try await sync(b)
        try await edit(notes.id, on: a, strokes: 3, after: 60)
        // The older of the two changes was saved by a newer OwlLuna, so no conflicted copy of it can be made here.
        let manifest = a.package(notes.id).appending(path: "manifest.json")
        guard case .object(var values) = try JSONValue.parse(Data(contentsOf: manifest)) else { return XCTFail() }
        values["schemaVersion"] = .number(Double(NotebookManifest.currentSchemaVersion + 1))
        try JSONValue.object(values).serialized().write(to: manifest)
        try await sync(a)
        try await edit(notes.id, on: b, strokes: 7, after: 120)

        let report = try await sync(b)
        XCTAssertEqual(report.failed, [SyncFailure(id: notes.id, reason: .newerVersion)])
        XCTAssertEqual(report.conflictCopies, [])
        let kept = await strokes(notes, on: b)
        XCTAssertEqual(kept, 7, "what was written here stays")
    }

    func testWhyACopyFailedIsReadFromItsError() {
        XCTAssertEqual(SyncFailure.Reason(CocoaError(.fileWriteOutOfSpace)), .noRoom)
        XCTAssertEqual(SyncFailure.Reason(POSIXError(.ENOSPC)), .noRoom)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC) as NSError])
        XCTAssertEqual(SyncFailure.Reason(wrapped), .noRoom, "no room, however deep it is said")
        let refused = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        XCTAssertEqual(SyncFailure.Reason(CoordinationError(underlying: refused)), .coordination(refused.localizedDescription))
        XCTAssertEqual(SyncFailure.Reason(CoordinationError(underlying: CocoaError(.fileWriteOutOfSpace) as NSError)), .noRoom)
        XCTAssertEqual(SyncFailure.Reason(PackageError.readOnly), .newerVersion)
        XCTAssertEqual(SyncFailure.Reason(PackageError.unreadable), .unreadable(inICloud: true))
        XCTAssertEqual(SyncFailure.Reason(PackageError.missing), .other(PackageError.missing.localizedDescription))
    }

    func testAPassAfterOneThatFailedReportsWhatThatOneLeft() {
        var report = SyncReport(open: [UUID()], failed: [SyncFailure(id: UUID(), reason: .noRoom)])
        let next = SyncReport(arriving: [UUID()])
        report.add(next)
        XCTAssertEqual(report.open, [])
        XCTAssertEqual(report.failed, [], "a notebook the next pass copied isn't still failing")
        XCTAssertEqual(report.waiting, next.arriving)
    }

    // MARK: The daily journal

    /// A device's library as the app keeps it: an index, and settings of its own, where it notes which notebook is its journal.
    @MainActor
    private func device(_ root: StorageRoot) throws -> LibraryStore {
        let container = try ModelContainer(for: LibraryIndex.schema, configurations: ModelConfiguration(schema: LibraryIndex.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        containers.append(container)
        let suite = "owlluna-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return LibraryStore(root: root, context: container.mainContext, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    /// What the app does at launch: the index read from the files, then the journal settled.
    @MainActor
    private func launch(_ store: LibraryStore) async {
        await LibraryIndex.refresh(root: store.root, context: store.context, full: true)
        await store.settleJournal()
    }

    /// A pass as `SyncCenter` runs one: changes still being written land first, and the library hears what it brought in.
    @MainActor
    @discardableResult
    private func pass(_ store: LibraryStore) async throws -> SyncReport {
        await store.finishWritingNotebooks()
        let report = try await LibrarySync.run(root: store.root, cloud: cloud)
        if report.changedHere { await store.reloadFromDisk(after: report) }
        return report
    }

    /// Passes on each device in turn until none has anything left to do. Returns the conflicted copies made on the way.
    @MainActor
    @discardableResult
    private func settle(_ stores: [LibraryStore], file: StaticString = #filePath, line: UInt = #line) async throws -> [UUID] {
        var copies: [UUID] = []
        for _ in 0..<6 {
            var quiet = true
            for store in stores {
                let report = try await pass(store)
                copies += report.conflictCopies
                if report != SyncReport() { quiet = false }
            }
            if quiet { return copies }
        }
        XCTFail("the devices never settled", file: file, line: line)
        return copies
    }

    /// A journal as a build from before journals were marked left it: an ordinary notebook, which only this device's settings name.
    @MainActor
    private func journalFromBeforeMarks(on store: LibraryStore, begun: Date) async throws -> UUID {
        let manifest = NotebookManifest(title: "Journal", createdAt: begun, defaults: paper, pages: [paper.newPage()])
        let package = NotebookPackage(root: store.root, id: manifest.id)
        try await package.create(manifest)
        let ink = PKDrawing(strokes: [stroke(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 200, y: 60))])
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: [manifest.pages[0].id: ink]))
        store.defaults.set(manifest.id.uuidString, forKey: SettingsKey.dailyJournalID)
        return manifest.id
    }

    /// Both devices hold both notebooks, the one begun first is the journal on each and marked so, and the other is kept
    /// under a name that tells them apart.
    @MainActor
    private func assertSettled(on stores: [LibraryStore], journal: UUID, setAside: UUID, file: StaticString = #filePath, line: UInt = #line) async throws {
        let begun = try XCTUnwrap(stores.first?.record(setAside)?.createdAt, file: file, line: line)
        for store in stores {
            XCTAssertEqual(store.dailyJournal?.id, journal, "the journal begun first is the journal everywhere", file: file, line: line)
            XCTAssertEqual(Set(store.root.packageIDs()), [journal, setAside], "nothing is merged or deleted", file: file, line: line)
            let kept = try await library(journal, on: store.root), other = try await library(setAside, on: store.root)
            XCTAssertTrue(kept.isJournal, file: file, line: line)
            XCTAssertFalse(other.isJournal, "the other is an ordinary notebook", file: file, line: line)
            XCTAssertEqual(store.record(journal)?.title, "Journal", file: file, line: line)
            XCTAssertEqual(store.record(setAside)?.title, "Journal (started \(begun.formatted(date: .abbreviated, time: .omitted)))",
                           "named so the two can be told apart", file: file, line: line)
            XCTAssertEqual(store.record(setAside)?.pageCount, 1, file: file, line: line)
            let today = try await store.journalForToday()
            XCTAssertEqual(today, journal, "⌘T opens the journal begun first", file: file, line: line)
        }
    }

    @MainActor
    func testADeviceWithoutAJournalTakesTheOneThatArrivesAndTodayOpensIt() async throws {
        let onA = try device(a), onB = try device(b)
        await launch(onA)
        await launch(onB)
        let journal = try await onA.createDailyJournal()
        try await settle([onA, onB])

        XCTAssertEqual(onB.dailyJournal?.id, journal, "the journal that arrives is this device's journal too")
        let marked = try await library(journal, on: b)
        XCTAssertTrue(marked.isJournal)
        let opened = try await onB.journalForToday()
        XCTAssertEqual(opened, journal, "so ⌘T opens it rather than starting another")
        let page = await onB.prepareTodayPage(opened)
        XCTAssertNotNil(page)
        XCTAssertEqual(b.packageIDs(), [journal])
        try await settle([onA, onB])
        XCTAssertEqual(a.packageIDs(), [journal], "and no second journal reaches the first device")
        XCTAssertEqual(onA.dailyJournal?.id, journal)
    }

    @MainActor
    func testJournalsStartedOnTwoDevicesBeforeTheyMetSettleOnTheOneBegunFirst() async throws {
        let onA = try device(a), onB = try device(b)
        let toldA = Shared<[UUID]>([]), toldB = Shared<[UUID]>([])
        onA.onJournalSetAside = { toldA.value.append($0) }
        onB.onJournalSetAside = { toldB.value.append($0) }
        let first = try await onA.createDailyJournal(now: .now.addingTimeInterval(-3600))
        let second = try await onB.createDailyJournal()

        let copies = try await settle([onA, onB])
        XCTAssertEqual(copies, [], "settling them never counts as writing on both devices")
        try await assertSettled(on: [onA, onB], journal: first, setAside: second)
        XCTAssertEqual(toldB.value, [second], "the device whose journal gave way says so, once")
        XCTAssertEqual(toldA.value, [])
        try await settle([onA, onB])
        XCTAssertEqual(toldB.value, [second])
    }

    @MainActor
    func testTwoJournalsFromBeforeTheyWereMarkedSettleOnTheOneBegunFirst() async throws {
        let onA = try device(a), onB = try device(b)
        let toldA = Shared<[UUID]>([]), toldB = Shared<[UUID]>([])
        onA.onJournalSetAside = { toldA.value.append($0) }
        onB.onJournalSetAside = { toldB.value.append($0) }
        // B was given A's journal as an ordinary notebook, and ⌘T there started a second one, which reached A in turn.
        let first = try await journalFromBeforeMarks(on: onA, begun: .now.addingTimeInterval(-30 * 86_400))
        try await sync(a)
        try await sync(b)
        let second = try await journalFromBeforeMarks(on: onB, begun: .now.addingTimeInterval(-86_400))
        try await sync(b)
        try await sync(a)
        XCTAssertEqual(Set(a.packageIDs()), [first, second])

        await launch(onA)
        await launch(onB)
        let copies = try await settle([onA, onB])
        XCTAssertEqual(copies, [])
        try await assertSettled(on: [onA, onB], journal: first, setAside: second)
        XCTAssertEqual(toldB.value, [second])
        XCTAssertEqual(toldA.value, [])
        for root in [a!, b!] {
            let pages = try await NotebookPackage(root: root, id: second).readManifest().manifest
            let ink = await strokes(pages, on: root)
            XCTAssertEqual(ink, 1, "what was written in the one set aside is all there")
        }
    }

    @MainActor
    func testAJournalChosenOrGivenUpOnOneDeviceIsChosenOrGivenUpOnTheOther() async throws {
        let onA = try device(a), onB = try device(b)
        let journal = try await onA.createDailyJournal()
        let diary = try await makeNotebook("Diary", on: a)
        await launch(onA)
        try await settle([onA, onB])
        XCTAssertEqual(onB.dailyJournal?.id, journal)

        onA.setDailyJournal(diary.id)
        try await settle([onA, onB])
        XCTAssertEqual(onB.dailyJournal?.id, diary.id, "a notebook chosen as the journal on one device is the journal on the other")
        let old = try await library(journal, on: b)
        XCTAssertFalse(old.isJournal)

        onB.setDailyJournal(nil)
        try await settle([onA, onB])
        XCTAssertNil(onA.dailyJournal, "and one given up on the other device is given up here")
        XCTAssertNil(onA.defaults.string(forKey: SettingsKey.dailyJournalID))
        for root in [a!, b!] {
            for id in root.packageIDs() {
                let state = try await library(id, on: root)
                XCTAssertFalse(state.isJournal)
            }
        }
    }

    func testTheJournalMarkIsAKeyThatOlderManifestsDoNotNeed() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        let manifestURL = a.package(notes.id).appending(path: "manifest.json")
        XCTAssertNil(try JSONValue.parse(Data(contentsOf: manifestURL))["library"]?["journal"], "as an older build writes it")
        let read = try await library(notes.id, on: a)
        XCTAssertFalse(read.isJournal, "a manifest without the key reads as no journal")
        XCTAssertNil(read.changedAt(.journal))
        try await sync(a)
        try await sync(b)
        let arrived = try await library(notes.id, on: b)
        XCTAssertFalse(arrived.isJournal)

        try await file(notes.id, on: a, at: .now) { $0.isJournal = true }
        let written = try JSONValue.parse(Data(contentsOf: manifestURL))
        XCTAssertEqual(written["library"]?["journal"]?.boolValue, true)
        XCTAssertNotNil(written["library"]?["changedAt"]?["journal"], "stamped, like a favourite")
        let sent = try await sync(a)
        XCTAssertEqual(sent.stateSent, [notes.id])
        XCTAssertEqual(sent.pushed, [], "it is filing, not writing")
        try await sync(b)
        let marked = try await library(notes.id, on: b)
        XCTAssertTrue(marked.isJournal)
        try await settled()
    }

    func testAConflictedCopyOfTheJournalIsNotAJournal() async throws {
        let journal = try await makeNotebook("Journal", on: a)
        try await file(journal.id, on: a, at: .now) { $0.isJournal = true }
        try await sync(a)
        try await sync(b)
        try await edit(journal.id, on: a, strokes: 3, after: 60)
        try await edit(journal.id, on: b, strokes: 7, after: 120)
        try await sync(a)
        let report = try await sync(b)
        let copy = try XCTUnwrap(report.conflictCopies.first)
        let kept = try await library(copy, on: b), original = try await library(journal.id, on: b)
        XCTAssertFalse(kept.isJournal, "the older pages are kept beside the journal as an ordinary notebook")
        XCTAssertTrue(original.isJournal)
    }

    // MARK: What a pass won't take as deleted

    private func folderNames(_ root: StorageRoot) -> [String] { FolderFile.read(root).folders.map(\.name).sorted() }

    func testAFolderListHereThatCannotBeReadDeletesNoFolderAnywhere() async throws {
        try fill(a)
        try fill(a, folder: "Art", sticker: "dog.png")
        try await sync(a)
        try await sync(b)
        let sent = try Data(contentsOf: cloud.foldersFile)

        try Data("{\"folders\": [".utf8).write(to: a.foldersFile)
        let damaged = try await sync(a)
        XCTAssertFalse(damaged.foldersChanged)
        XCTAssertEqual(try Data(contentsOf: cloud.foldersFile), sent, "nothing is sent from a list that can't be read")
        XCTAssertEqual(try String(contentsOf: a.foldersFile, encoding: .utf8), "{\"folders\": [", "and it is left as it is, not taken for an empty one")
        try await sync(b)
        XCTAssertEqual(folderNames(b), ["Art", "Science"], "so no folder goes from the other device")

        let foldersFile = a.foldersFile
        try sent.write(to: foldersFile)
        try permit(0o000, foldersFile)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: foldersFile.path(percentEncoded: false)) }
        let unreachable = try await sync(a)
        XCTAssertFalse(unreachable.foldersChanged)
        XCTAssertEqual(try Data(contentsOf: cloud.foldersFile), sent, "nor from one that can't be reached")
        try permit(0o644, foldersFile)
        try await settled()
        XCTAssertEqual(folderNames(a), ["Art", "Science"])
        XCTAssertEqual(folderNames(b), ["Art", "Science"])
    }

    @MainActor
    func testADamagedFolderListIsWrittenAgainFromTheIndex() async throws {
        let onA = try device(a)
        onA.createFolder(name: "Science", cloth: .jade)
        onA.createFolder(name: "Art", cloth: .rose)
        await onA.finishWritingShelves()
        try await sync(a)
        try await sync(b)

        try Data("damaged".utf8).write(to: a.foldersFile)
        await LibraryIndex.refresh(root: a, context: onA.context)
        XCTAssertEqual(onA.folderTree().ordered.count, 2, "the index keeps the folders a damaged list can't say")
        XCTAssertEqual(folderNames(a), ["Art", "Science"], "and the list is written again from it")
        XCTAssertEqual(try String(contentsOf: a.foldersFile.appendingPathExtension("corrupt"), encoding: .utf8), "damaged", "with the damaged one kept aside")

        try Data("damaged again".utf8).write(to: a.foldersFile)
        onA.createFolder(name: "Labs", cloth: .moss)
        await onA.finishWritingShelves()
        XCTAssertEqual(folderNames(a), ["Art", "Labs", "Science"], "a folder made over a damaged list writes every folder the index has")
        try await sync(a)
        try await sync(b)
        XCTAssertEqual(folderNames(b), ["Art", "Labs", "Science"])
    }

    func testAFolderListInTheSyncedCopyThatCannotBeReadIsSaidAndNotWrittenOver() async throws {
        try fill(a)
        try await sync(a)
        try await sync(b)
        let good = try Data(contentsOf: cloud.foldersFile)
        try fill(b, folder: "Art", sticker: "dog.png")
        try Data("{\"folders\": [".utf8).write(to: cloud.foldersFile)

        let report = try await sync(b)
        XCTAssertTrue(report.foldersUnreadable)
        XCTAssertFalse(report.foldersChanged)
        XCTAssertTrue(report.parts.contains("Folders aren't syncing"))
        XCTAssertEqual(try String(contentsOf: cloud.foldersFile, encoding: .utf8), "{\"folders\": [",
                       "a device doesn't write its own list over it, which would delete a folder only that list holds everywhere else")
        XCTAssertEqual(folderNames(b), ["Art", "Science"], "nothing is taken as deleted here")
        XCTAssertEqual(stickers(in: cloud.stickers), ["cat.png", "dog.png"], "and the rest still syncs")

        try good.write(to: cloud.foldersFile)
        let mended = try await sync(b)
        XCTAssertFalse(mended.foldersUnreadable)
        try await sync(a)
        XCTAssertEqual(folderNames(a), ["Art", "Science"], "a good list again, folders sync again")
    }

    private func syncedFolders() throws -> FolderFile { try XCTUnwrap(FolderFile(Data(contentsOf: cloud.foldersFile))) }

    func testADamagedFolderListReplacedByOneDeviceDeletesNoFolderOnTheOther() async throws {
        try fill(a)
        try await sync(a)
        try await sync(b)
        // The first device last wrote the list, with a folder the second never saw, before it was damaged.
        try fill(a, folder: "Art", sticker: "dog.png")
        try await sync(a)
        let damaged = Data("{\"folders\": [".utf8)
        try damaged.write(to: cloud.foldersFile)
        try fill(b, folder: "Labs", sticker: "owl.png")
        let stalled = try await sync(b)
        XCTAssertTrue(stalled.foldersUnreadable)

        let replaced = try await LibrarySync.run(root: b, cloud: cloud, replacingFolders: true)
        XCTAssertFalse(replaced.foldersUnreadable)
        let list = try syncedFolders()
        XCTAssertEqual(list.folders.map(\.name).sorted(), ["Labs", "Science"], "made again from this device's folders")
        XCTAssertNotNil(list.listID)
        XCTAssertNotEqual(list.listID, SyncState.read(a).folderList, "under a new name")
        XCTAssertEqual(SyncState.read(b).folderList, list.listID)
        XCTAssertEqual(try Data(contentsOf: b.library.appending(path: "icloud-folders.json.corrupt")), damaged, "the damaged one is kept aside")

        let report = try await sync(a)
        XCTAssertFalse(report.foldersUnreadable)
        XCTAssertEqual(folderNames(a), ["Art", "Labs", "Science"], "a folder only the damaged list held isn't taken as deleted")
        try await sync(b)
        XCTAssertEqual(folderNames(b), ["Art", "Labs", "Science"])
        let after = try syncedFolders()
        XCTAssertEqual(after.folders.map(\.name).sorted(), ["Art", "Labs", "Science"])
        XCTAssertEqual(after.listID, list.listID, "the list keeps its new name")
        XCTAssertEqual(SyncState.read(a).folderList, after.listID)

        _ = try await LibrarySync.run(root: a, cloud: cloud, replacingFolders: true)
        XCTAssertEqual(try syncedFolders(), after, "a list that reads is never replaced")
        var folders = FolderFile.read(a)
        folders.folders.removeAll { $0.name == "Labs" }
        try folders.write(a)
        try await sync(a)
        try await sync(b)
        XCTAssertEqual(folderNames(b), ["Art", "Science"], "once both have the new list, a delete carries over again")
    }

    func testTwoDevicesReplacingADamagedFolderListAtOnceLoseNoFolder() async throws {
        try fill(a)
        try await sync(a)
        try await sync(b)
        try fill(a, folder: "Art", sticker: "dog.png")
        try fill(b, folder: "Labs", sticker: "owl.png")
        let damaged = Data("damaged".utf8)
        try damaged.write(to: cloud.foldersFile)

        // Each replaces it before the other's has arrived, and iCloud keeps the second device's.
        _ = try await LibrarySync.run(root: a, cloud: cloud, replacingFolders: true)
        try damaged.write(to: cloud.foldersFile)
        _ = try await LibrarySync.run(root: b, cloud: cloud, replacingFolders: true)
        XCTAssertNotEqual(SyncState.read(a).folderList, SyncState.read(b).folderList)

        try await sync(a)
        try await sync(b)
        XCTAssertEqual(folderNames(a), ["Art", "Labs", "Science"])
        XCTAssertEqual(folderNames(b), ["Art", "Labs", "Science"])
        XCTAssertEqual(SyncState.read(a).folderList, try syncedFolders().listID)
    }

    func testAFolderListFromBeforeListsWereNamedIsNamedAndDeletesNothing() async throws {
        try fill(a)
        try fill(a, folder: "Art", sticker: "dog.png")
        try await sync(a)
        try await sync(b)
        // As an older build left things: a list without a name, and none in either device's state.
        var unnamed = try syncedFolders()
        unnamed.listID = nil
        try unnamed.encoded().write(to: cloud.foldersFile)
        for root in [a!, b!] {
            var state = SyncState.read(root)
            state.folderList = nil
            try state.write(root)
        }

        var folders = FolderFile.read(a)
        folders.folders.removeAll { $0.name == "Art" }
        try folders.write(a)
        try await sync(a)
        let named = try syncedFolders()
        XCTAssertEqual(named.folders.map(\.name), ["Science"], "a list without a name is the one a state without one agreed with")
        XCTAssertEqual(SyncState.read(a).folderList, try XCTUnwrap(named.listID), "and it is named")

        try await sync(b)
        XCTAssertEqual(folderNames(b), ["Art", "Science"], "a device that doesn't know the name can't tell the list from one made again, so it only adds")
        XCTAssertEqual(SyncState.read(b).folderList, named.listID)
        try await sync(a)
        folders = FolderFile.read(b)
        folders.folders.removeAll { $0.name == "Art" }
        try folders.write(b)
        try await sync(b)
        try await sync(a)
        XCTAssertEqual(folderNames(a), ["Science"], "once both know the name, a delete carries over")
        XCTAssertEqual(folderNames(b), ["Science"])
    }

    func testALibraryThatCannotBeListedDeletesNoNotebooks() async throws {
        let ids = sorted([try await makeNotebook("One", on: a), try await makeNotebook("Two", on: a)])
        try await sync(a)
        try await sync(b)
        let library = a.library
        try permit(0o000, library)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path(percentEncoded: false)) }
        do {
            try await sync(a)
            XCTFail("a library that can't be listed isn't synced")
        } catch {
            XCTAssertFalse(error is StoppedPass, "the pass stops before it looks at any notebook")
        }
        try permit(0o755, library)
        XCTAssertTrue(ids.allSatisfy(isSynced), "nothing is removed from the synced copy")
        XCTAssertFalse(ids.contains(where: marked), "and no delete is marked")
        try await settled()
        XCTAssertEqual(Set(b.packageIDs()), Set(ids))
    }

    func testTooManyNotebooksGoneAtOnceAreHeldRatherThanDeleted() async throws {
        var made: [NotebookManifest] = []
        for title in ["One", "Two", "Three", "Four", "Five"] { made.append(try await makeNotebook(title, on: a)) }
        let ids = sorted(made)
        try await sync(a)
        try await sync(b)
        for id in ids { try FileManager.default.removeItem(at: a.package(id)) }

        let report = try await sync(a)
        XCTAssertEqual(report.held, ids, "five going at once isn't taken for deletes")
        XCTAssertEqual(report.removedThere, [])
        XCTAssertEqual(report.waiting, ids)
        XCTAssertTrue(ids.allSatisfy(isSynced))
        XCTAssertFalse(ids.contains(where: marked))
        let other = try await sync(b)
        XCTAssertEqual(other, SyncReport(), "so the other device keeps them all")
        let again = try await sync(a)
        XCTAssertEqual(again.held, ids, "and they are held until they're wanted back")

        let kept = try await LibrarySync.run(root: a, cloud: cloud, keeping: Set(ids))
        XCTAssertEqual(kept.pulled, ids, "kept, they come back")
        try await settled()
    }

    func testTooManyDeletesFromAnotherDeviceAreHeldToo() async throws {
        var made: [NotebookManifest] = []
        for title in ["One", "Two", "Three", "Four"] { made.append(try await makeNotebook(title, on: a)) }
        let ids = sorted(made)
        try await sync(a)
        try await sync(b)
        // Marked as deleted by a device that had none of this pass's care.
        for id in ids {
            try DeleteMarker(modifiedAt: try XCTUnwrap(LibrarySync.stamp(ofPackage: cloud.package(id)))).encoded().write(to: cloud.tombstone(id))
            try FileManager.default.removeItem(at: cloud.package(id))
        }
        let report = try await sync(b)
        XCTAssertEqual(report.held, ids)
        XCTAssertEqual(report.removedHere, [])
        for id in ids {
            let state = try await library(id, on: b)
            XCTAssertNil(state.deletedAt, "none is touched here")
        }

        let kept = try await LibrarySync.run(root: b, cloud: cloud, keeping: Set(ids))
        XCTAssertEqual(kept.pushed, ids, "kept, they go back up")
        XCTAssertFalse(ids.contains(where: marked))
        XCTAssertTrue(ids.allSatisfy(isSynced))
    }

    func testNotebooksDeletedFromRecentlyDeletedAreNeverHeld() async throws {
        var made: [NotebookManifest] = []
        for title in ["One", "Two", "Three", "Four", "Five"] { made.append(try await makeNotebook(title, on: a)) }
        let ids = sorted(made)
        try await sync(a)
        try await sync(b)
        for id in ids { try await file(id, on: a, at: .now) { $0.deletedAt = .now } }
        try await sync(a)
        try await sync(b)
        for id in ids { try FileManager.default.removeItem(at: a.package(id)) }

        let report = try await sync(a)
        XCTAssertEqual(report.held, [])
        XCTAssertEqual(report.removedThere, ids, "emptying Recently Deleted carries over however many it held")
        let other = try await sync(b)
        XCTAssertEqual(other.removedHere, ids)
        XCTAssertEqual(b.packageIDs(), [], "for good, as they were in Recently Deleted there as well")
    }

    func testWhatCountsAsTooManyToDeleteAtOnce() {
        XCTAssertFalse(LibrarySync.isTooManyToDelete(3, of: 100))
        XCTAssertTrue(LibrarySync.isTooManyToDelete(4, of: 100), "more than a few")
        XCTAssertTrue(LibrarySync.isTooManyToDelete(2, of: 3), "or most of a small library")
        XCTAssertFalse(LibrarySync.isTooManyToDelete(2, of: 4))
        XCTAssertFalse(LibrarySync.isTooManyToDelete(1, of: 1), "one notebook is only ever one delete")
    }

    func testANotebookDeletedOnAnotherDeviceGoesIntoRecentlyDeletedHere() async throws {
        let notes = try await makeNotebook("Notes", on: a)
        try await makeNotebook("Other", on: a)
        try await sync(a)
        try await sync(b)
        try FileManager.default.removeItem(at: a.package(notes.id))
        let removed = try await sync(a)
        XCTAssertEqual(removed.removedThere, [notes.id])

        let report = try await sync(b)
        XCTAssertEqual(report.removedHere, [notes.id])
        let state = try await library(notes.id, on: b)
        XCTAssertNotNil(state.deletedAt, "it goes into Recently Deleted, not for good")
        let count = await strokes(notes, on: b)
        XCTAssertEqual(count, 1)
        try await settled()
        XCTAssertFalse(a.packageIDs().contains(notes.id), "and it doesn't come back to the device that deleted it")

        try await file(notes.id, on: b, at: .now) { $0.deletedAt = nil }
        let restored = try await sync(b)
        XCTAssertEqual(restored.pushed, [notes.id], "taken back out, it comes back everywhere")
        XCTAssertFalse(marked(notes.id))
        let back = try await sync(a)
        XCTAssertEqual(back.pulled, [notes.id])
        try await settled()
    }

    func testHeldDeletesLetGoAreCarriedOverAndNotHeldAgainElsewhere() async throws {
        var made: [NotebookManifest] = []
        for title in ["One", "Two", "Three", "Four", "Five"] { made.append(try await makeNotebook(title, on: a)) }
        let ids = sorted(made)
        try await sync(a)
        try await sync(b)
        for id in ids { try FileManager.default.removeItem(at: a.package(id)) }
        let held = try await sync(a)
        XCTAssertEqual(held.held, ids)

        let letGo = try await LibrarySync.run(root: a, cloud: cloud, lettingGo: Set(ids))
        XCTAssertEqual(letGo.held, [], "meant, they aren't held again")
        XCTAssertEqual(letGo.removedThere, ids)
        XCTAssertFalse(ids.contains(where: isSynced))
        XCTAssertTrue(try ids.allSatisfy { DeleteMarker(try Data(contentsOf: cloud.tombstone($0))).confirmed }, "and each marker says they were let go")

        let other = try await sync(b)
        XCTAssertEqual(other.held, [], "so the other device doesn't hold them again")
        XCTAssertEqual(other.removedHere, ids)
        for id in ids {
            let state = try await library(id, on: b)
            XCTAssertNotNil(state.deletedAt, "they go into Recently Deleted there")
        }
        try await settled()
        XCTAssertEqual(a.packageIDs(), [])
    }

    func testHeldDeletesFromAnotherDeviceLetGoGoIntoRecentlyDeleted() async throws {
        var made: [NotebookManifest] = []
        for title in ["One", "Two", "Three", "Four"] { made.append(try await makeNotebook(title, on: a)) }
        let ids = sorted(made)
        try await sync(a)
        try await sync(b)
        for id in ids {
            try DeleteMarker(modifiedAt: try XCTUnwrap(LibrarySync.stamp(ofPackage: cloud.package(id)))).encoded().write(to: cloud.tombstone(id))
            try FileManager.default.removeItem(at: cloud.package(id))
        }
        let held = try await sync(b)
        XCTAssertEqual(held.held, ids)

        let letGo = try await LibrarySync.run(root: b, cloud: cloud, lettingGo: Set(ids))
        XCTAssertEqual(letGo.removedHere, ids)
        for id in ids {
            let state = try await library(id, on: b)
            XCTAssertNotNil(state.deletedAt)
        }
        let again = try await sync(b)
        XCTAssertEqual(again, SyncReport(), "and stay there")
    }

    func testLettingHeldDeletesGoTakesNothingWrittenInSince() async throws {
        var made: [NotebookManifest] = []
        for title in ["One", "Two", "Three", "Four"] { made.append(try await makeNotebook(title, on: a)) }
        let ids = sorted(made)
        try await sync(a)
        try await sync(b)
        for id in ids { try FileManager.default.removeItem(at: a.package(id)) }
        let held = try await sync(a)
        XCTAssertEqual(held.held, ids)
        try await edit(ids[0], on: b, strokes: 3, after: 60)
        try await sync(b)

        let letGo = try await LibrarySync.run(root: a, cloud: cloud, lettingGo: Set(ids))
        XCTAssertEqual(letGo.removedThere, Array(ids.dropFirst()))
        XCTAssertEqual(letGo.pulled, [ids[0]], "one written in since comes back, as it would after a single delete")
        let other = try await sync(b)
        XCTAssertEqual(other.removedHere, Array(ids.dropFirst()))
        try await settled()
    }

    // MARK: Folders changed on two devices

    @MainActor
    private func folder(_ id: UUID, in store: LibraryStore) throws -> FolderRecord {
        try XCTUnwrap(try store.context.fetch(FetchDescriptor<FolderRecord>()).first { $0.id == id })
    }

    @MainActor
    func testAFolderChangedOfflineKeepsItsChangeOverANewerListFromTheOtherDevice() async throws {
        let onA = try device(a), onB = try device(b)
        let science = try XCTUnwrap(onA.createFolder(name: "Science", cloth: .jade))
        let labs = try XCTUnwrap(onA.createFolder(name: "Labs", cloth: .moss))
        await onA.finishWritingShelves()
        try await pass(onA)
        try await pass(onB)

        // Offline, the first device renames one folder and nests the other in it.
        onA.renameFolder(science, to: "Physics")
        XCTAssertTrue(onA.moveFolder(labs, into: science))
        await onA.finishWritingShelves()
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-600)], ofItemAtPath: a.foldersFile.path(percentEncoded: false))
        // The second recolours the first folder and adds one of its own, and syncs first.
        onB.setCloth(.rose, for: try folder(science.id, in: onB))
        onB.createFolder(name: "Art", cloth: .slate)
        await onB.finishWritingShelves()
        try await pass(onB)

        try await pass(onA)
        try await pass(onB)
        for store in [onA, onB] {
            let tree = store.folderTree()
            XCTAssertEqual(tree.path(of: labs.id), "Physics › Labs", "the rename and the move made offline both stand")
            XCTAssertEqual(try folder(science.id, in: store).clothRaw, ClothColor.rose.rawValue, "and so does the other device's colour")
            XCTAssertEqual(tree.ordered.map { tree.name(of: $0) }.sorted(), ["Art", "Labs", "Physics"])
        }
        let report = try await sync(a)
        XCTAssertFalse(report.foldersChanged, "and the two lists agree")
    }

    @MainActor
    func testAFolderMadeWhileAPassHasTheFoldersIsKept() async throws {
        let onA = try device(a)
        onA.createFolder(name: "Science", cloth: .jade)
        await onA.finishWritingShelves()
        try await sync(a)
        try await sync(b)
        try fill(b, folder: "Art", sticker: "dog.png")
        try await sync(b)

        // The pass has its turn with the folders, and hasn't read them yet, when a folder is made.
        let (turns, taken) = AsyncStream<Void>.makeStream(), go = DispatchSemaphore(value: 0)
        let root = a!, cloud = cloud!
        let running = Task.detached {
            try await LibrarySync.run(root: root, cloud: cloud, holdingFolders: { work in
                try await onA.holdingFolders {
                    taken.yield()
                    go.wait()
                    return try work()
                }
            })
        }
        var turn = turns.makeAsyncIterator()
        _ = await turn.next()
        onA.createFolder(name: "Labs", cloth: .moss)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FolderFile.read(a).folders.contains { $0.name == "Labs" }, "its write waits for the pass")
        go.signal()
        let report = try await running.value
        XCTAssertTrue(report.foldersChanged)

        // And one made before the library has read what the pass brought in.
        onA.createFolder(name: "Biology", cloth: .rose)
        await onA.finishWritingShelves()
        XCTAssertEqual(folderNames(a), ["Art", "Biology", "Labs", "Science"], "nothing the pass brought in or the library made is lost")
        try await sync(a)
        try await sync(b)
        XCTAssertEqual(folderNames(b), ["Art", "Biology", "Labs", "Science"])
    }

    @MainActor
    func testAFolderPutBackAfterADeleteIsBackOnTheOtherDeviceWithItsNotebook() async throws {
        let onA = try device(a), onB = try device(b)
        let science = try XCTUnwrap(onA.createFolder(name: "Science", cloth: .jade))
        let physics = try XCTUnwrap(onA.createFolder(name: "Physics", cloth: .moss, parent: science))
        let labs = try XCTUnwrap(onA.createFolder(name: "Labs", cloth: .rose, parent: physics))
        let physicsID = physics.id, mechanics = try await makeNotebook("Mechanics", on: a)
        onA.index(mechanics)
        onA.move([try XCTUnwrap(onA.record(mechanics.id))], to: physics)
        await onA.finishWritingShelves()
        try await pass(onA)
        try await pass(onB)
        XCTAssertEqual(onB.folderTree().path(of: labs.id), "Science › Physics › Labs")

        // Put back before a pass, the other device never sees it go.
        var deleted = onA.deleteFolder(physics)
        onA.restoreFolder(deleted)
        await onA.finishWritingShelves()
        try await pass(onA)
        try await pass(onB)
        XCTAssertEqual(onB.folderTree().path(of: labs.id), "Science › Physics › Labs")

        deleted = onA.deleteFolder(try folder(physicsID, in: onA))
        await onA.finishWritingShelves()
        try await pass(onA)
        try await pass(onB)
        XCTAssertEqual(onB.folderTree().path(of: labs.id), "Science › Labs", "the delete reaches the other device")
        XCTAssertEqual(onB.record(mechanics.id)?.folder?.id, science.id)

        onA.restoreFolder(deleted)
        await onA.finishWritingShelves()
        try await pass(onA)
        try await pass(onB)
        for store in [onA, onB] {
            XCTAssertEqual(store.folderTree().path(of: labs.id), "Science › Physics › Labs", "and so does putting it back, as the same folder")
            XCTAssertEqual(try folder(physicsID, in: store).clothRaw, ClothColor.moss.rawValue)
            XCTAssertEqual(store.record(mechanics.id)?.folder?.id, physicsID, "with its notebook in it")
        }
        let report = try await sync(a)
        XCTAssertFalse(report.foldersChanged, "and the two lists agree")
    }
}

/// Stands for another process holding a synced notebook, which won't let it be written.
private final class RefusingPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()

    init(_ url: URL) { presentedItemURL = url }

    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError))
    }
}
