import XCTest
import AVFoundation
import PencilKit
import SwiftData
@testable import OwlLuna

/// Recordings by name, played faster or slower, shared on their own and exported with the notebook's PDF.
@MainActor
final class RecordingsTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func recording(_ file: String = "talk.wav", at offset: TimeInterval = 0, duration: TimeInterval = 20) -> RecordingEntry {
        var entry = RecordingEntry(id: UUID(), file: file, createdAt: start.addingTimeInterval(offset + duration), duration: duration)
        entry.startedAt = start.addingTimeInterval(offset)
        return entry
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition(), Date.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func defaults() -> UserDefaults {
        let name = "recordings-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// A notebook with silent recordings in its assets, opened.
    private func notebook(_ title: String = "Talk", recordings: [RecordingEntry], ink: [Int: PKDrawing] = [:]) async throws -> NotebookDocument {
        let root = temporaryRoot(self)
        var manifest = NotebookManifest(title: title, defaults: paper, pages: [paper.newPage(), paper.newPage()])
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        try FileManager.default.createDirectory(at: package.assetsDirectory, withIntermediateDirectories: true)
        for entry in recordings { try ReplaySeed.silence(seconds: entry.duration).write(to: package.assetURL(entry.file)) }
        manifest.recordings = recordings.map {
            var entry = $0
            entry.inkedPages = manifest.pages.map(\.id)
            return entry
        }
        var drawings: [UUID: PKDrawing] = [:]
        for (index, drawing) in ink { drawings[manifest.pages[index].id] = drawing }
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: drawings))
        return try await NotebookDocument.open(manifest.id, root: root)
    }

    private func script() -> Transcript {
        Transcript(locale: "en-US", words: [
            .init(text: "Today", start: 1, duration: 0.3), .init(text: "we", start: 1.4, duration: 0.2), .init(text: "begin.", start: 1.7, duration: 0.4),
            .init(text: "Cells", start: 5.2, duration: 0.4), .init(text: "divide.", start: 5.7, duration: 0.5),
        ])
    }

    // MARK: Names

    func testANameIsKeptInTheManifestAndAnOlderBuildWritesItBack() throws {
        var entry = recording()
        entry.title = "Cell biology"
        let encoded = ManifestCodec.encodeRecording(entry)
        XCTAssertEqual(encoded.objectValue?["title"], .string("Cell biology"), "kept beside the entry's other keys")
        XCTAssertEqual(ManifestCodec.decodeRecording(encoded)?.name, "Cell biology")

        // An older build reads the name as a key it doesn't know and writes it back with whatever it changed.
        var older = try XCTUnwrap(ManifestCodec.decodeRecording(encoded))
        older.extra["transcript"] = .string("words.json")
        older.duration = 21
        let rewritten = ManifestCodec.encodeRecording(older)
        XCTAssertEqual(rewritten.objectValue?["title"], .string("Cell biology"))
        XCTAssertEqual(rewritten.objectValue?["duration"], .number(21))

        var manifest = NotebookManifest(title: "Biology", defaults: paper, pages: [paper.newPage()])
        manifest.recordings = [entry, recording("plain.m4a", at: 60)]
        let reread = try ManifestCodec.decode(ManifestCodec.encode(manifest), fallbackID: UUID()).manifest
        XCTAssertEqual(reread.recordings.map(\.title), ["Cell biology", nil])
        XCTAssertEqual(try ManifestCodec.encode(reread), try ManifestCodec.encode(manifest), "the whole manifest round-trips unchanged")

        let odd = try XCTUnwrap(ManifestCodec.decodeRecording(.object(["id": .string(UUID().uuidString), "file": .string("a.m4a"),
                                                                     "createdAt": ManifestCodec.encodeDate(start),
                                                                     "title": .object(["en": .string("Cells")])])))
        XCTAssertNil(odd.title, "a name in a shape a newer build might use is not read as one")
        XCTAssertEqual(ManifestCodec.encodeRecording(odd).objectValue?["title"], .object(["en": .string("Cells")]), "and is written back as it was")

        entry.title = ""
        XCTAssertNil(entry.title)
        XCTAssertNil(ManifestCodec.encodeRecording(entry).objectValue?["title"], "an empty name is no name")
    }

    func testAnUnnamedRecordingIsCalledByWhenItBeganAndKeepsThatName() async throws {
        let first = recording("a.wav"), second = recording("b.wav", at: 3600), third = recording("c.wav", at: 7200)
        let document = try await notebook(recordings: [first, second, third])
        let names = document.manifest.recordings.map(\.name)
        XCTAssertEqual(names, [first, second, third].map { $0.startedAt.formatted(date: .abbreviated, time: .shortened) })
        XCTAssertEqual(Set(names).count, 3)

        document.removeRecording(first.id)
        XCTAssertEqual(document.manifest.recordings.map(\.name), Array(names.dropFirst()), "deleting one renames none of the others")

        document.renameRecording(third.id, to: "  Mitosis  ")
        XCTAssertEqual(document.manifest.recordings.last?.name, "Mitosis", "trimmed")
        XCTAssertEqual(document.undoManager.undoActionName, "Rename Recording")
        document.undoManager.undo()
        XCTAssertNil(document.manifest.recordings.last?.title, "one undo takes the name off")
        XCTAssertEqual(document.manifest.recordings.last?.name, names[2])
        document.undoManager.redo()
        XCTAssertEqual(document.manifest.recordings.last?.title, "Mitosis")
        document.renameRecording(third.id, to: " ")
        XCTAssertEqual(document.manifest.recordings.last?.name, names[2], "nothing typed goes back to when it began")
        document.undoManager.undo()
        XCTAssertEqual(document.manifest.recordings.last?.title, "Mitosis")

        var alike = [recording("x.wav"), recording("y.wav", at: 60), recording("z.m4a", at: 120)]
        alike[0].title = "Lecture"
        alike[1].title = "lecture"
        alike[2].title = "Lecture: Part 1"
        let files = RecordingExport.names(for: alike)
        XCTAssertEqual(alike.map { files[$0.id]?.number }, ["", " 2", ""], "named alike, the later one is numbered so neither file replaces the other")
    }

    // MARK: Deleting

    func testDeletingARecordingIsOneUndoStepThatBringsItBackWithItsTranscript() async throws {
        var lecture = recording("lecture.wav", at: 600, duration: 4)
        lecture.title = "Cells"
        let first = recording("a.wav"), last = recording("c.wav", at: 1200)
        let document = try await notebook(recordings: [first, lecture, last])
        let recorder = NotebookRecorder(document: document, defaults: defaults())
        let package = document.package
        let file = try await package.writeTranscript(script(), recordingID: lecture.id)
        document.setTranscript(file, forRecording: lecture.id)
        var changes = 0
        recorder.onTranscriptChange = { changes += 1 }
        func searchable() -> Bool { LibraryIndex.searchText(in: package.textDirectory).contains("Cells divide") }
        XCTAssertTrue(searchable())
        XCTAssertFalse(document.undoManager.canUndo)

        recorder.delete(try XCTUnwrap(recorder.recordings.first { $0.id == lecture.id }))
        XCTAssertEqual(recorder.recordings.map(\.id), [first.id, last.id])
        XCTAssertEqual(document.undoManager.undoActionName, "Delete Recording")
        await waitUntil { changes == 1 }
        XCTAssertFalse(searchable(), "its words leave search")

        document.undoManager.undo()
        XCTAssertEqual(recorder.recordings.map(\.id), [first.id, lecture.id, last.id], "Undo puts it back in its place")
        let back = try XCTUnwrap(recorder.recordings.first { $0.id == lecture.id })
        XCTAssertEqual(back.title, "Cells")
        XCTAssertEqual(back.transcriptFile, file)
        XCTAssertEqual(recorder.transcript(for: back)?.text, script().text)
        XCTAssertFalse(document.undoManager.canUndo, "it was one step")
        await waitUntil { changes == 2 }
        XCTAssertTrue(searchable(), "and its words are found again")
        _ = await document.save()
        let hits = await PageSearch.hits(for: "divide", in: [document.id], root: package.root)
        XCTAssertEqual(hits.pages[document.id]?.first?.recording?.id, lecture.id)

        XCTAssertEqual(document.undoManager.redoActionName, "Delete Recording")
        document.undoManager.redo()
        XCTAssertEqual(recorder.recordings.map(\.id), [first.id, last.id], "Redo deletes it again")
        await waitUntil { changes == 3 }
        XCTAssertFalse(searchable())
        document.undoManager.undo()
        await waitUntil { changes == 4 }
        XCTAssertEqual(recorder.recordings.map(\.id), [first.id, lecture.id, last.id])
        XCTAssertTrue(searchable())
    }

    func testADeletedRecordingsAudioOutlastsASaveAndASyncSoUndoCanStillBringItBack() async throws {
        let document = try await notebook(recordings: [recording(duration: 3)])
        document.updateLibraryState { $0.isLocked = true }
        let recorder = NotebookRecorder(document: document, defaults: defaults())
        addTeardownBlock { @MainActor in recorder.shutdown() }
        let entry = try XCTUnwrap(recorder.recordings.first)
        let package = document.package, audio = package.assetURL(entry.file)
        let cloud = CloudFolder(url: temporaryRoot(self).url)
        func synced() throws -> NotebookManifest {
            try ManifestCodec.decode(Data(contentsOf: cloud.package(document.id).appending(path: "manifest.json")), fallbackID: document.id).manifest
        }

        recorder.delete(entry)
        let saved = await document.save()
        XCTAssertTrue(saved)
        let written = try await package.readManifest().manifest
        XCTAssertEqual(written.recordings, [], "saved without it")
        XCTAssertTrue(exists(audio), "while its audio stays until the editor closes")
        _ = try await LibrarySync.run(root: package.root, cloud: cloud)
        XCTAssertTrue(exists(audio), "a sync pass leaves it too")
        XCTAssertEqual(try synced().recordings, [])

        document.undoManager.undo()
        XCTAssertEqual(recorder.recordings.map(\.id), [entry.id])
        let resaved = await document.save()
        XCTAssertTrue(resaved)
        let rewritten = try await package.readManifest().manifest
        XCTAssertEqual(rewritten.recordings.map(\.id), [entry.id])
        _ = try await LibrarySync.run(root: package.root, cloud: cloud)
        let there = try synced()
        XCTAssertEqual(there.recordings.map(\.id), [entry.id], "the next pass sends it back")
        XCTAssertTrue(exists(cloud.package(document.id).appending(path: "assets/\(entry.file)")), "with its audio")
        XCTAssertTrue(there.library.isLocked, "and the notebook stays locked")
        recorder.togglePlayback(try XCTUnwrap(recorder.recordings.first))
        await waitUntil { recorder.playingID != nil }
        XCTAssertEqual(recorder.playingID, entry.id, "it plays as before")
    }

    func testDeletingARecordingStopsItPlayingAndOneDeletedAsItStartsNeverSounds() async throws {
        let document = try await notebook(recordings: [recording(duration: 20)])
        let recorder = NotebookRecorder(document: document, defaults: defaults())
        let session = AudioSessionOwner.shared
        addTeardownBlock { @MainActor in recorder.shutdown() }
        let entry = try XCTUnwrap(recorder.recordings.first)
        recorder.togglePlayback(entry)
        await waitUntil { recorder.playingID != nil }
        XCTAssertEqual(recorder.playingID, entry.id)

        recorder.delete(entry)
        XCTAssertNil(recorder.playingID, "it stops as it is deleted")
        XCTAssertFalse(session.isPlaying(recorder))
        document.undoManager.undo()
        XCTAssertNil(recorder.playingID, "and doesn't start again when Undo brings it back")
        recorder.togglePlayback(try XCTUnwrap(recorder.recordings.first))
        await waitUntil { recorder.playingID != nil }
        XCTAssertEqual(recorder.playingID, entry.id, "its audio is still there to play")
        document.undoManager.redo()
        XCTAssertNil(recorder.playingID, "Redo stops it too")

        document.undoManager.undo()
        recorder.togglePlayback(try XCTUnwrap(recorder.recordings.first))
        recorder.delete(entry)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(recorder.playingID, "one deleted while its playback is starting never sounds")
        XCTAssertFalse(session.isPlaying(recorder), "and lets go of the session")
    }

    /// Waits until let go, then hears two words. A cancel takes a moment to stop it and ends in an error, as the recogniser's does.
    private final class HeldTranscriber: SpeechTranscribing, @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var stops = 0

        func letGo() { lock.withLock { open = true } }
        var stopped: Int { lock.withLock { stops } }

        func transcribe(_ url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
            while !lock.withLock({ open }) {
                if Task.isCancelled {
                    await withCheckedContinuation { done in DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { done.resume() } }
                    lock.withLock { stops += 1 }
                    throw TranscriptionError.failed("Recognition request was canceled")
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return Transcript(locale: "en-US", words: [.init(text: "Cells", start: 1, duration: 0.4), .init(text: "divide.", start: 1.5, duration: 0.4)])
        }
    }

    func testARecordingDeletedWhileBeingTranscribedComesBackUntranscribedAndCanBeTranscribedAgain() async throws {
        let entry = recording(duration: 4)
        let document = try await notebook(recordings: [entry])
        let recorder = NotebookRecorder(document: document, defaults: defaults())
        let held = HeldTranscriber()
        recorder.transcriber = held
        recorder.transcribe(entry, locale: Locale(identifier: "en-US"))
        XCTAssertNotNil(recorder.transcribing[entry.id])

        recorder.delete(entry)
        XCTAssertNil(recorder.transcribing[entry.id], "deleting it stops the transcription")
        document.undoManager.undo()
        let back = try XCTUnwrap(recorder.recordings.first)
        XCTAssertNil(back.transcriptFile, "Undo brings it back untranscribed")
        recorder.transcribe(back, locale: Locale(identifier: "en-US"))
        await waitUntil { held.stopped == 1 }
        await waitUntil(1) { recorder.transcribing[entry.id] == nil }
        XCTAssertNotNil(recorder.transcribing[entry.id], "the transcription that was stopped doesn't clear the one started since")
        XCTAssertNil(recorder.errorMessage, "and its stopping isn't told as a failure")

        held.letGo()
        await waitUntil { recorder.recordings.first?.transcriptFile != nil }
        XCTAssertNotNil(recorder.recordings.first?.transcriptFile)
        XCTAssertNil(recorder.transcribing[entry.id])
        XCTAssertTrue(LibraryIndex.searchText(in: document.package.textDirectory).contains("Cells divide"))
    }

    func testARecordingBeingMadeCantBeDeletedAndStoppingItLeavesNothingToUndo() async throws {
        let document = try await notebook(recordings: [])
        let recorder = NotebookRecorder(document: document, defaults: defaults())
        let page = document.pages[0].id
        _ = await document.ink(page)
        document.canvasDidChangeInk(page, to: PKDrawing(strokes: [stroke(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 200, y: 60))]))
        XCTAssertEqual(document.undoManager.undoActionName, "Ink")
        var entry = RecordingEntry(id: UUID(), file: "\(UUID().uuidString).aac", createdAt: start, duration: 0)
        entry.startedAt = start
        let audio = document.package.assetURL(entry.file)
        try FileManager.default.moveItem(at: try cutOff(try scratchFolder().appending(path: "a.aac"), seconds: 2), to: audio)

        document.beginRecording(entry)
        XCTAssertEqual(recorder.recordings, [], "while it is being made it isn't in the list to delete")
        recorder.delete(entry)
        XCTAssertEqual(document.manifest.unfinishedRecordings.map(\.id), [entry.id], "and asking anyway changes nothing")
        XCTAssertEqual(document.undoManager.undoActionName, "Ink")

        entry.duration = 2
        document.finishRecording(entry)
        await document.finishPendingWork()
        XCTAssertEqual(recorder.recordings.map(\.id), [entry.id])
        XCTAssertEqual(document.undoManager.undoActionName, "Ink", "Stop is no undo step, so an Undo meant for the stroke can't take the recording")
        document.undoManager.undo()
        XCTAssertEqual(recorder.recordings.map(\.id), [entry.id])
        XCTAssertEqual(document.loadedInk(page)?.strokes.count, 0)
        XCTAssertFalse(document.undoManager.canUndo)
    }

    func testClosingTheEditorStillClearsAwayADeletedRecordingAndNothingIsLeftToUndo() async throws {
        let entry = recording(duration: 3)
        let document = try await notebook(recordings: [entry])
        let package = document.package
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = LibraryStore(root: package.root, context: container.mainContext)
        let registry = DocumentRegistry.shared
        registry.register(document, scene: nil)
        let recorder = NotebookRecorder(document: document, defaults: defaults())
        let file = try await package.writeTranscript(script(), recordingID: entry.id)
        document.setTranscript(file, forRecording: entry.id)

        recorder.delete(try XCTUnwrap(recorder.recordings.first))
        await waitUntil { !exists(package.transcriptTextURL(entry.id)) }
        await EditorScreen.putAway(document, store: store)
        XCTAssertNil(registry.document(for: document.id))
        XCTAssertFalse(exists(package.assetURL(entry.file)), "closing clears away its audio, as before")
        XCTAssertFalse(exists(package.assetURL(file)), "and its transcript")

        let again = try await registry.open(document.id, root: package.root, scene: nil) { _ in }
        addTeardownBlock { @MainActor in registry.unregister(again.id, document: again) }
        XCTAssertFalse(again === document)
        XCTAssertEqual(again.manifest.recordings, [])
        XCTAssertFalse(again.undoManager.canUndo, "opened again, there is no undo step left to bring it back")
        withExtendedLifetime((container, recorder)) {}
    }

    // MARK: Speed

    func testPlaybackSpeedIsAppliedAndTheReplayKeepsToTheSoundAtTwice() async throws {
        let entry = recording(duration: 30)
        let ink = PKDrawing(strokes: [2, 6, 10, 14, 18, 22].enumerated().map { ReplaySeed.stroke(y: 100 + CGFloat($0) * 60, at: start.addingTimeInterval($1)) })
        let document = try await notebook(recordings: [entry], ink: [0: ink])
        let session = EditorSession(document: document)
        let store = defaults()
        session.recorder.defaults = store
        let controller = PageStackController(session: session)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where !(controller.canvas(forPage: 0)?.isLoaded ?? false) { try await Task.sleep(for: .milliseconds(50)) }

        XCTAssertEqual(PlaybackSpeed.saved(in: store), 1, "a recording plays as it was made until another speed is chosen")
        session.recorder.setSpeed(2)
        session.recorder.setSpeed(3)
        XCTAssertEqual(session.recorder.speed, 2, "only the speeds offered are taken")
        XCTAssertEqual(store.double(forKey: SettingsKey.playbackSpeed), 2)
        let began = await session.beginReplay(document.manifest.recordings[0])
        XCTAssertTrue(began)
        XCTAssertEqual(session.recorder.playerRate, 2, "the player plays at the speed chosen")
        let timeline = try XCTUnwrap(session.replay), page = document.pages[0].id
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0))
        func shows(_ time: TimeInterval) -> Bool {
            canvas.drawing.strokes.map { $0.ink.color.cgColor.alpha < 0.5 }
                == ReplayInk.drawing(ink, pending: timeline.pending(onPage: page, at: time)).strokes.map { $0.ink.color.cgColor.alpha < 0.5 }
        }

        session.seekReplay(to: 9)
        XCTAssertEqual(session.recorder.currentTime, 9, accuracy: 0.01, "a seek lands on the recording's own time at any speed")
        XCTAssertTrue(shows(9))
        let from = session.recorder.currentTime, wall = Date.now
        try await Task.sleep(for: .milliseconds(1200))
        let moved = session.recorder.currentTime - from, took = Date.now.timeIntervalSince(wall)
        if moved > 0 {
            XCTAssertGreaterThan(moved / took, 1.6, "the sound runs at twice its speed: \(moved) s in \(took) s")
            XCTAssertLessThan(moved / took, 2.4)
        }
        XCTAssertTrue(shows(session.recorder.currentTime), "the ink is where the sound is, at \(session.recorder.currentTime) s")

        session.scrubReplay(to: 4)
        XCTAssertTrue(shows(4))
        session.seekReplay(to: 4)
        XCTAssertEqual(session.recorder.currentTime, 4, accuracy: 0.01)
        XCTAssertEqual(session.recorder.playerRate, 2, "seeking keeps the speed")
        session.recorder.pause()
        session.recorder.resume()
        XCTAssertEqual(session.recorder.playerRate, 2, "and so do pausing and going on")

        session.recorder.setSpeed(0.75)
        XCTAssertEqual(session.recorder.playerRate, 0.75, "a change while playing takes at once")
        session.enter(.writing)
        XCTAssertEqual(PlaybackSpeed.saved(in: store), 0.75, "the speed is kept for the next playback")
        XCTAssertEqual(PlaybackSpeed.label(1.5), 1.5.formatted(.number.precision(.fractionLength(0...2))) + "×")
        XCTAssertEqual(PlaybackScrubber.step(in: 30), 3)
        XCTAssertEqual(PlaybackScrubber.step(in: 3600), 10)
    }

    // MARK: Sharing

    func testATranscriptFileHasItsTimesWhenTheWordsCameWithThem() throws {
        let timed = script()
        XCTAssertEqual(timed.fileText, "[0:01] Today we begin.\n[0:05] Cells divide.")
        var untimed = timed
        untimed.untimed = true
        XCTAssertEqual(untimed.fileText, timed.text, "words spread over the recording go as Copy Transcript gives them, without made-up times")
        XCTAssertEqual(untimed.fileText, "Today we begin.\nCells divide.")
        let long = Transcript(locale: "en-US", words: [.init(text: "Late.", start: 3723, duration: 0.5)])
        XCTAssertEqual(long.fileText, "[1:02:03] Late.")

        let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(untimed))
        XCTAssertEqual(decoded.untimed, true)
        let older = try JSONDecoder().decode(Transcript.self, from: Data(#"{"locale":"en-US","words":[{"t":"Hi.","s":1,"d":0.2}]}"#.utf8))
        XCTAssertNil(older.untimed, "a transcript from before is taken to have its times")
    }

    func testARecordingAndItsTranscriptAreSharedAsFilesNamedAfterIt() async throws {
        var named = recording(duration: 4)
        named.title = "Week 3: Cells"
        let document = try await notebook(recordings: [named, recording("quiet.wav", at: 600, duration: 2)])
        let recorder = NotebookRecorder(document: document, defaults: defaults())
        let file = try await document.package.writeTranscript(script(), recordingID: named.id)
        document.setTranscript(file, forRecording: named.id)
        let entry = try XCTUnwrap(recorder.recordings.first)

        let audio = try await shared(.audio, of: entry, by: recorder)
        XCTAssertEqual(audio.map(\.lastPathComponent), ["Week 3- Cells.wav"])
        XCTAssertTrue(audio[0].deletingLastPathComponent().lastPathComponent.hasPrefix("export-"), "in an export folder of its own")
        XCTAssertEqual(try Data(contentsOf: audio[0]), try Data(contentsOf: document.package.assetURL(entry.file)))

        let text = try await shared(.transcript, of: entry, by: recorder)
        XCTAssertEqual(text.map(\.lastPathComponent), ["Week 3- Cells.txt"])
        XCTAssertEqual(try String(contentsOf: text[0], encoding: .utf8), "[0:01] Today we begin.\n[0:05] Cells divide.\n")
        let quiet = try XCTUnwrap(recorder.recordings.last)
        let none = try await recorder.files(sharing: .transcript, of: quiet)
        XCTAssertNil(none, "nothing to share before it is transcribed")
        let dated = try await shared(.audio, of: quiet, by: recorder)
        let stem = quiet.startedAt.formatted(date: .abbreviated, time: .shortened).replacingOccurrences(of: ":", with: ".")
        XCTAssertEqual(dated[0].lastPathComponent, stem.replacingOccurrences(of: "\u{202F}", with: " ") + ".wav", "named for when it began, the time written with a point")

        for url in audio + text + dated {
            ExportFolder.discard([url])
            await waitUntil { !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path(percentEncoded: false)) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path(percentEncoded: false)), "cleaned up as exports are")
        }
    }

    private func shared(_ part: NotebookRecorder.Part, of entry: RecordingEntry, by recorder: NotebookRecorder,
                        file: StaticString = #filePath, line: UInt = #line) async throws -> [URL] {
        let urls = try await recorder.files(sharing: part, of: entry)
        return try XCTUnwrap(urls, file: file, line: line)
    }

    func testALockedNotebookIsUnlockedBeforeItsRecordingsAreShared() async throws {
        let document = try await notebook(recordings: [recording(duration: 2)])
        document.updateLibraryState { $0.isLocked = true }
        let recorder = NotebookRecorder(document: document, defaults: defaults())
        let lock = NotebookLock.shared, usual = lock.authenticator
        addTeardownBlock { @MainActor in
            lock.authenticator = usual
            lock.lock(document.id)
        }
        lock.lock(document.id)
        lock.authenticator = ScriptedAuthenticator(passes: 0)
        let refused = try await recorder.files(sharing: .audio, of: recorder.recordings[0])
        XCTAssertNil(refused, "nothing is written while it stays locked")
        lock.authenticator = ScriptedAuthenticator(passes: 1)
        let shared = try await recorder.files(sharing: .audio, of: recorder.recordings[0])
        XCTAssertEqual(shared?.count, 1)
        XCTAssertTrue(lock.isUnlocked(document.id))
        ExportFolder.discard(shared ?? [])
    }

    // MARK: Cut off

    /// Writes `seconds` of a tone as a recording does, and returns a copy taken before the file was closed, as an app that quits leaves it.
    private func cutOff(_ url: URL, seconds: Int) throws -> URL {
        let copy = url.deletingLastPathComponent().appending(path: "cut-" + url.lastPathComponent)
        let file = try AVAudioFile(forWriting: url, settings: RecordingFile.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<44_100 { samples[index] = sin(Float(index) * 0.05) * 0.3 }
        for _ in 0..<seconds { try file.write(from: buffer) }
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "recordings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    func testARecordingCutOffBeforeItsFileIsClosedPlaysAsADTSButNotAsM4A() throws {
        let folder = try scratchFolder()
        let m4a = try cutOff(folder.appending(path: "talk.m4a"), seconds: 3)
        XCTAssertThrowsError(try AVAudioFile(forReading: m4a), "an .m4a says where its sound is only once it is closed")

        let adts = try cutOff(folder.appending(path: "lecture.aac"), seconds: 3)
        XCTAssertEqual(try XCTUnwrap(RecordingFile.duration(of: adts)), 3, accuracy: 0.3, "every frame has its header, so what was written plays")
        var chopped = try Data(contentsOf: adts)
        chopped.removeLast(37)
        let torn = folder.appending(path: "torn.aac")
        try chopped.write(to: torn)

        for source in [adts, torn] {
            let finished = try XCTUnwrap(RecordingFile.finish(source), "\(source.lastPathComponent)")
            XCTAssertEqual(finished.url.pathExtension, "m4a", "made an .m4a once it ends, like every recording before")
            XCTAssertEqual(finished.duration, 3, accuracy: 0.3)
            let player = try AVAudioPlayer(contentsOf: finished.url)
            XCTAssertEqual(player.duration, finished.duration, accuracy: 0.05, "the player knows its length")
        }

        let empty = folder.appending(path: "empty.aac")
        try Data().write(to: empty)
        XCTAssertNil(RecordingFile.finish(empty), "nothing written, nothing to play")
        XCTAssertFalse(exists(folder.appending(path: "empty.m4a")))
    }

    func testARecordingIsNamedAsItStartsSoClearingUpKeepsItsAudio() async throws {
        let document = try await notebook(recordings: [])
        document.saveDelay = .seconds(600)
        document.maxSaveLatency = .seconds(600)
        let package = document.package
        var entry = RecordingEntry(id: UUID(), file: "\(UUID().uuidString).aac", createdAt: start, duration: 0)
        entry.startedAt = start
        let audio = package.assetURL(entry.file), stray = package.assetURL("stray.aac")
        try FileManager.default.moveItem(at: try cutOff(try scratchFolder().appending(path: "a.aac"), seconds: 2), to: audio)
        try Data(repeating: 1, count: 64).write(to: stray)

        let before = document.manifest.modifiedAt
        document.beginRecording(entry)
        await waitUntil(2) { !document.hasUnsavedChanges }
        XCTAssertFalse(document.hasUnsavedChanges, "saved at once, not after the usual pause")
        XCTAssertGreaterThan(document.manifest.modifiedAt, before, "a change of its own, so a sync never takes another version over it unseen")
        for file in [audio, stray] {
            try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: file.path(percentEncoded: false))
        }
        await document.collectGarbage()
        XCTAssertTrue(exists(audio), "the audio being written is named in the manifest, so clearing up keeps it")
        XCTAssertFalse(exists(stray), "while a file nothing names goes")
        XCTAssertEqual(NotebookRecorder(document: document, defaults: defaults()).recordings, [], "it isn't in the list until it ends")
        let saved = try await package.readManifest().manifest
        XCTAssertEqual(saved.unfinishedRecordings.map(\.id), [entry.id])
        XCTAssertEqual(saved.unfinishedRecordings.first?.device, package.root.deviceID, "marked as being made on this iPad")
        XCTAssertEqual(saved.recordings, [], "an older build sees no recording, only a key it keeps")

        entry.duration = 1.5
        document.finishRecording(entry)
        await document.finishPendingWork()
        XCTAssertEqual(document.manifest.unfinishedRecordings, [])
        let finished = try XCTUnwrap(document.manifest.recordings.first)
        XCTAssertEqual(finished.id, entry.id)
        XCTAssertEqual(finished.file, entry.file.replacingOccurrences(of: ".aac", with: ".m4a"))
        XCTAssertEqual(finished.duration, 2, accuracy: 0.3, "timed from what was written")
        XCTAssertNil(finished.device)
        XCTAssertTrue(document.hasUnsavedChanges)
        _ = await document.flush()
        await document.collectGarbage()
        XCTAssertTrue(exists(package.assetURL(finished.file)))
        XCTAssertFalse(exists(audio), "the file it was recorded into goes once the .m4a is saved in its place")
    }

    func testARecordingTheAppQuitDuringJoinsTheListWhenTheNotebookOpens() async throws {
        let root = temporaryRoot(self)
        var manifest = NotebookManifest(title: "Lecture", defaults: paper, pages: [paper.newPage()])
        let package = NotebookPackage(root: root, id: manifest.id)
        try await package.create(manifest)
        func cut(_ name: String, on device: String? = nil) -> RecordingEntry {
            var entry = RecordingEntry(id: UUID(), file: "\(name).aac", createdAt: start, duration: 0)
            entry.startedAt = start
            entry.device = device ?? root.deviceID
            return entry
        }
        let lecture = cut("lecture"), empty = cut("empty"), missing = cut("missing"), elsewhere = cut("elsewhere", on: UUID().uuidString)
        let folder = try scratchFolder()
        try FileManager.default.moveItem(at: try cutOff(folder.appending(path: "a.aac"), seconds: 4), to: package.assetURL(lecture.file))
        try FileManager.default.moveItem(at: try cutOff(folder.appending(path: "b.aac"), seconds: 2), to: package.assetURL(elsewhere.file))
        try Data().write(to: package.assetURL(empty.file))
        manifest.unfinishedRecordings = [lecture, empty, missing, elsewhere]
        _ = try await package.write(SaveSnapshot(manifest: manifest, ink: [:]))
        let written = try await package.readManifest().manifest.modifiedAt

        let document = try await NotebookDocument.open(manifest.id, root: root)
        XCTAssertEqual(document.manifest.recordings.map(\.id), [lecture.id], "one with nothing playable is dropped")
        XCTAssertEqual(document.manifest.unfinishedRecordings, [elsewhere], "another iPad's may still be being made there, so it is left for that iPad")
        XCTAssertTrue(exists(package.assetURL(elsewhere.file)))
        let adopted = document.manifest.recordings[0]
        XCTAssertEqual(adopted.file, "lecture.m4a")
        XCTAssertEqual(adopted.duration, 4, accuracy: 0.3, "as long as what was written")
        XCTAssertEqual(adopted.startedAt.timeIntervalSince(start), 0, accuracy: 0.001)
        XCTAssertEqual(adopted.createdAt.timeIntervalSince(start), adopted.duration, accuracy: 0.002, "it ended where its sound does")
        XCTAssertFalse(exists(package.assetURL(empty.file)), "and goes with its file")
        XCTAssertEqual(document.notices.map(\.kind), [.recordingStopped])
        XCTAssertEqual(document.notices.first?.message, RecordingStop.quit.message(at: adopted.duration))

        _ = await document.flush()
        let saved = try await package.readManifest().manifest
        XCTAssertEqual(saved.recordings.map(\.file), ["lecture.m4a"], "saved finished")
        XCTAssertEqual(saved.unfinishedRecordings.map(\.id), [elsewhere.id])
        XCTAssertGreaterThan(saved.modifiedAt, written, "dated, so it syncs out like any recording and a pull can't take it back")
        let again = try await NotebookDocument.open(manifest.id, root: root)
        XCTAssertEqual(again.notices, [], "told once")
        await again.collectGarbage()
        XCTAssertTrue(exists(package.assetURL(elsewhere.file)), "and its audio is kept")
    }

    func testAStopTheUserDidntAskForIsToldWithTheTimeItCameAt() async throws {
        XCTAssertEqual(RecordingStop.clock(41 * 60 + 12), "41:12")
        XCTAssertEqual(RecordingStop.clock(5.9), "0:05")
        XCTAssertEqual(RecordingStop.clock(3725), "1:02:05", "an hour or more shows the hours")
        XCTAssertEqual(RecordingStop.locked.message(at: 2472), "Recording stopped at 41:12 when the notebook locked.")
        XCTAssertEqual(RecordingStop.coverClosed.message(at: 2472), Device.isPhone ? "Recording stopped at 41:12 when the microphone was muted."
                                                                                   : "Recording stopped at 41:12 when the iPad's cover was closed.")
        XCTAssertEqual(RecordingStop.interrupted.message(at: 2472), "Recording stopped at 41:12 when another app needed the microphone.")
        XCTAssertEqual(RecordingStop.failed.message(at: 2472), "Recording stopped at 41:12 because the audio couldn't be written. What came before is kept.")
        XCTAssertEqual(RecordingStop.quit.message(at: 2472), "Recording stopped at 41:12 when OwlLuna quit. What came before is kept.")

        let document = try await notebook(recordings: [])
        document.noteRecordingStopped(RecordingStop.locked.message(at: 60))
        document.noteRecordingStopped(RecordingStop.interrupted.message(at: 90))
        XCTAssertEqual(document.notices.map(\.message), [RecordingStop.interrupted.message(at: 90)], "only the latest stop is shown")
    }

    func testARecordingCarriesOnInTheBackgroundButNotBehindANotebooksLock() {
        XCTAssertNil(BackgroundRecording.stop(locked: false, inBackground: true), "the iPad locking or another app coming to the front leaves it recording")
        XCTAssertNil(BackgroundRecording.stop(locked: false, inBackground: false))
        XCTAssertEqual(BackgroundRecording.stop(locked: true, inBackground: true), .locked, "leaving the screen locks the notebook, and nothing is recorded behind its lock")
        XCTAssertNil(BackgroundRecording.stop(locked: true, inBackground: false), "a notebook locked while it is in front stays open until it is closed, and so does its recording")
        XCTAssertFalse(BackgroundRecording.keepsAwake(locked: false), "locking doesn't stop it, so the iPad locks as it usually would")
        XCTAssertTrue(BackgroundRecording.keepsAwake(locked: true), "locking would stop it, so the iPad stays awake")
    }

    func testPlaybackWaitsBehindANotebooksLockAndOtherwisePlaysOnInTheBackground() async throws {
        let document = try await notebook(recordings: [recording(duration: 20)])
        let recorder = NotebookRecorder(document: document, defaults: defaults())
        let session = AudioSessionOwner.shared
        addTeardownBlock { @MainActor in recorder.shutdown() }
        recorder.togglePlayback(recorder.recordings[0])
        await waitUntil { recorder.playingID != nil }
        XCTAssertNotNil(recorder.playingID)
        XCTAssertTrue(session.isPlaying(recorder))

        recorder.noteWindow(inBackground: true)
        XCTAssertFalse(recorder.isPaused, "with no lock it plays on with the iPad locked")
        document.updateLibraryState { $0.isLocked = true }
        XCTAssertTrue(recorder.isPaused, "locked from another window while this one is in the background, it waits")
        XCTAssertFalse(session.isPlaying(recorder), "and lets go of the session, so other apps' sound can come back")

        recorder.noteWindow(inBackground: false)
        recorder.resume()
        await waitUntil { !recorder.isPaused }
        XCTAssertFalse(recorder.isPaused, "back in front it takes the session again and plays on")
        XCTAssertTrue(session.isPlaying(recorder))
        recorder.noteWindow(inBackground: true)
        XCTAssertTrue(recorder.isPaused, "and leaving the screen locks it")

        recorder.stopPlayback()
        recorder.togglePlayback(recorder.recordings[0])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(recorder.playingID, "a playback started behind the lock never sounds")
        XCTAssertFalse(session.isPlaying(recorder))
    }

    func testOneAudioSessionServesEveryWindow() async throws {
        final class Uses: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [AudioSessionOwner.Use] = []
            func append(_ use: AudioSessionOwner.Use) { lock.withLock { list.append(use) } }
            var all: [AudioSessionOwner.Use] { lock.withLock { list } }
        }
        @MainActor final class Window: AudioSessionUser {
            var gaveWay = false
            func giveWayToRecording() { gaveWay = true }
        }
        let uses = Uses()
        let owner = AudioSessionOwner { uses.append($0) }
        let a = Window(), b = Window(), c = Window()

        let recording = try await owner.claimRecording(for: a)
        XCTAssertTrue(recording)
        let second = try await owner.claimRecording(for: b)
        XCTAssertFalse(second, "one recording at a time, in any window")
        let played = try await owner.claimPlayback(for: b)
        XCTAssertFalse(played, "what played would be recorded too")
        owner.releaseRecording(by: b)
        owner.releasePlayback(by: b)
        await owner.settled()
        XCTAssertEqual(uses.all, [.recording], "nothing switches the session away from the recording or lets it go")
        XCTAssertTrue(owner.isRecording(a))

        owner.releaseRecording(by: a)
        await owner.settled()
        XCTAssertEqual(uses.all, [.recording, .idle], "let go once nothing records or plays")

        let first = try await owner.claimPlayback(for: a)
        let other = try await owner.claimPlayback(for: b)
        XCTAssertTrue(first && other, "two windows can play at once")
        owner.releasePlayback(by: a)
        await owner.settled()
        XCTAssertEqual(owner.use, .playback, "kept while the other plays")

        let lecture = try await owner.claimRecording(for: c)
        XCTAssertTrue(lecture)
        XCTAssertTrue(b.gaveWay, "playback in another window pauses rather than be recorded")
        XCTAssertFalse(a.gaveWay)
        owner.releasePlayback(by: b)
        owner.releaseRecording(by: c)
        await owner.settled()
        XCTAssertEqual(uses.all, [.recording, .idle, .playback, .playback, .recording, .idle])

        var gone: Window? = Window()
        _ = try await owner.claimPlayback(for: try XCTUnwrap(gone))
        gone = nil
        owner.refresh()
        await owner.settled()
        XCTAssertEqual(uses.all.last, .idle, "a recorder that went away without stopping doesn't keep the session")

        let failing = AudioSessionOwner { if $0 == .recording { throw CocoaError(.featureUnsupported) } }
        do {
            _ = try await failing.claimRecording(for: a)
            XCTFail("a session that won't switch to recording says so")
        } catch {}
        XCTAssertFalse(failing.isRecording(a), "and nothing is left claimed")
        XCTAssertEqual(failing.use, .idle)
    }

    func testARecordingStoppedAsItsWindowWentAwayIsToldWhenTheNotebookNextOpens() async throws {
        XCTAssertEqual(RecordingStop.windowClosed.message(at: 2472), "Recording stopped at 41:12 when its window was closed.")
        let schema = LibraryIndex.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let store = LibraryStore(root: temporaryRoot(self), context: container.mainContext)
        let manifest = NotebookManifest(title: "Lecture", defaults: paper, pages: [paper.newPage()])
        try await NotebookPackage(root: store.root, id: manifest.id).create(manifest)
        store.index(manifest)
        let registry = DocumentRegistry.shared
        let document = try await registry.open(manifest.id, root: store.root, scene: nil) { _ in }
        let recorder = NotebookRecorder(document: document, defaults: defaults())
        document.noteRecordingStopped(RecordingStop.windowClosed.message(at: 90))
        await EditorScreen.putAway(document, store: store, because: .windowClosed)
        XCTAssertNil(registry.document(for: manifest.id))

        let again = try await registry.open(manifest.id, root: store.root, scene: nil) { _ in }
        addTeardownBlock { @MainActor in registry.unregister(manifest.id, document: again) }
        XCTAssertFalse(again === document)
        XCTAssertEqual(again.notices.map(\.message), [RecordingStop.windowClosed.message(at: 90)], "the stop is told when the notebook next opens")
        withExtendedLifetime((container, recorder)) {}
    }

    func testTheIPadStaysAwakeWhileAnythingHoldsIt() throws {
        final class Screen { var awake = false }
        let screen = Screen(), idle = IdleTimer { screen.awake = $0 }
        let presenting = NSObject(), recording = NSObject()
        idle.hold(true, by: presenting)
        idle.hold(true, by: recording)
        idle.hold(false, by: presenting)
        XCTAssertTrue(screen.awake, "presenting ends while a recording is being made")
        idle.hold(true, by: presenting)
        idle.hold(false, by: recording)
        XCTAssertTrue(screen.awake, "a recording ends while presenting")
        idle.hold(false, by: presenting)
        XCTAssertFalse(screen.awake)
        idle.hold(false, by: recording)
        XCTAssertFalse(idle.isHeld, "letting go twice is harmless")

        var gone: NSObject? = NSObject()
        idle.hold(true, by: try XCTUnwrap(gone))
        gone = nil
        idle.refresh()
        XCTAssertFalse(screen.awake, "a hold goes with whatever took it")
    }

    // MARK: Export

    func testAnExportedPDFTakesTheRecordingsOnlyWhenAsked() async throws {
        var lecture = recording("lecture.wav", duration: 3)
        lecture.title = "Lecture"
        let other = recording("other.m4a", at: 900, duration: 2)
        let document = try await notebook("Biology", recordings: [lecture, other])
        let file = try await document.package.writeTranscript(script(), recordingID: lecture.id)
        document.setTranscript(file, forRecording: lecture.id)

        let job = ExportJob(document: document)
        await waitUntil(10) { if case .finished = job.state { true } else { false } }
        guard case .finished(let urls) = job.state, let pdf = urls.first else { return XCTFail("\(job.state)") }
        XCTAssertEqual(job.recordingCount, 2)
        XCTAssertFalse(job.includesRecordings, "off unless asked")
        XCTAssertEqual(job.shared, [pdf])

        job.includeRecordings(true)
        XCTAssertEqual(job.bundle, .making)
        XCTAssertEqual(job.shared, [], "nothing to share until the zip is made")
        await waitUntil(10) { if case .made = job.bundle { true } else { false } }
        guard case .made(let zip) = job.bundle else { return XCTFail("\(String(describing: job.bundle))") }
        XCTAssertEqual(job.shared, [zip])
        XCTAssertEqual(zip.lastPathComponent, "Biology.zip")
        XCTAssertEqual(zip.deletingLastPathComponent(), pdf.deletingLastPathComponent(), "in the export's own folder")
        let folder = try FileManager.default.contentsOfDirectory(atPath: pdf.deletingLastPathComponent().path(percentEncoded: false))
        XCTAssertEqual(Set(folder), ["Biology.pdf", "Biology.zip"], "nothing else is left beside them")
        let otherFile = RecordingExport.fileName(RecordingExport.fileStem(of: other), extension: "m4a")
        XCTAssertEqual(try zipEntries(zip), ["Biology/Biology.pdf", "Biology/Recordings/Lecture.txt", "Biology/Recordings/Lecture.wav",
                                             "Biology/Recordings/\(otherFile)"])

        job.includeRecordings(false)
        XCTAssertEqual(job.shared, [pdf], "turned off, the PDF goes alone")
        job.includeRecordings(true)
        XCTAssertEqual(job.shared, [zip], "and the zip already made is used again")

        job.close()
        let gone = pdf.deletingLastPathComponent().path(percentEncoded: false)
        await waitUntil { !FileManager.default.fileExists(atPath: gone) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone), "closing the sheet takes the zip with the PDF")

        let images = ExportJob(document: document, format: .images)
        XCTAssertEqual(images.recordingCount, 0, "only a PDF takes them")
        images.close()
    }

    /// The names in a zip's central directory, its folders left out.
    private func zipEntries(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        func number(_ offset: Int, _ size: Int) -> Int {
            (0..<size).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << (8 * $1) }
        }
        let end = try XCTUnwrap(stride(from: data.count - 22, through: 0, by: -1).first { number($0, 4) == 0x0605_4b50 })
        var offset = number(end + 16, 4), names: [String] = []
        for _ in 0..<number(end + 10, 2) {
            XCTAssertEqual(number(offset, 4), 0x0201_4b50)
            let length = number(offset + 28, 2), extra = number(offset + 30, 2), comment = number(offset + 32, 2)
            let name = String(decoding: data[(data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + length)], as: UTF8.self)
            if !name.hasSuffix("/") { names.append(name) }
            offset += 46 + length + extra + comment
        }
        return names.sorted()
    }
}
