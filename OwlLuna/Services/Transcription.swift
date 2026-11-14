import Foundation
import Speech
import AVFoundation

/// What was said in a recording, with when each word began.
struct Transcript: Codable, Sendable, Equatable {
    struct Word: Codable, Sendable, Equatable {
        var text: String
        var start: TimeInterval
        var duration: TimeInterval

        enum CodingKeys: String, CodingKey {
            case text = "t", start = "s", duration = "d"
        }
    }

    /// A sentence, or as much as was said in one breath: what the transcript is read and tapped by.
    struct Line: Identifiable, Sendable, Equatable {
        let id: Int
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    var locale: String
    var words: [Word]
    /// Set when the recogniser gave no times and the words were spread evenly over the recording.
    var untimed: Bool?

    var isEmpty: Bool { words.isEmpty }

    var text: String { lines.map(\.text).joined(separator: "\n") }

    /// What a shared transcript file holds: the lines Copy Transcript gives, each after when it was said if that is known.
    var fileText: String {
        guard untimed != true else { return text }
        return lines.map { "[\(RecordingStop.clock($0.start))] \($0.text)" }.joined(separator: "\n")
    }

    /// A new line begins after the end of a sentence, after a pause of a second, or after sixteen words.
    var lines: [Line] {
        var result: [Line] = [], current: [Word] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            result.append(Line(id: result.count, start: first.start, end: max(last.start + last.duration, first.start),
                               text: current.map(\.text).joined(separator: " ")))
            current = []
        }
        for word in words {
            if let last = current.last {
                let ended = last.text.last.map { ".?!…".contains($0) } ?? false
                if ended || word.start - (last.start + last.duration) >= 1 || current.count >= 16 { close() }
            }
            current.append(word)
        }
        close()
        return result
    }

    /// The line being said at `time`: the last one that has begun.
    static func line(at time: TimeInterval, in lines: [Line]) -> Int? {
        lines.last { $0.start <= time + 0.05 }?.id
    }

    /// Adds words the recogniser has settled on. It may send the whole recording again or only its latest stretch,
    /// so what is already held from the first new word's moment onward is replaced.
    mutating func merge(_ newer: [Word]) {
        guard let first = newer.map(\.start).min() else { return }
        words.removeAll { $0.start >= first - 0.01 }
        words += newer
        words.sort { $0.start < $1.start }
    }

    /// Words that came without their times are spread evenly over the recording.
    static func spread(_ texts: [String], over duration: TimeInterval) -> [Word] {
        guard !texts.isEmpty else { return [] }
        let step = max(duration, 0) / Double(texts.count)
        return texts.enumerated().map { Word(text: $1, start: Double($0) * step, duration: step * 0.8) }
    }
}

enum TranscriptionError: LocalizedError {
    case notAllowed, unavailable(String), nothingHeard, failed(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed:
            (Device.isMac
                ? String(localized: "Speech recognition is off for OwlLuna. Turn it on in System Settings › Privacy & Security › Speech Recognition.")
                : String(localized: "Speech recognition is off for OwlLuna. Turn it on in Settings › Privacy & Security › Speech Recognition."))
        case .unavailable(let language):
            (Device.isMac
                ? String(localized: "This Mac can't transcribe \(language) on the device. OwlLuna never sends a recording away to be transcribed, so it was left as it is.")
                : String(localized: "This iPad can't transcribe \(language) on the device. OwlLuna never sends a recording away to be transcribed, so it was left as it is."))
        case .nothingHeard:
            String(localized: "No speech was found in this recording.")
        case .failed(let reason):
            String(localized: "The recording couldn't be transcribed: \(reason)")
        }
    }
}

protocol SpeechTranscribing: Sendable {
    /// `progress` is the fraction of the recording that has been heard so far.
    func transcribe(_ url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript
}

enum Transcription {
    static var transcriber: any SpeechTranscribing {
        #if DEBUG
        if LaunchOptions.arguments.contains("-fakeTranscript") { return ScriptedTranscriber() }
        #endif
        return DeviceTranscriber()
    }

    /// The languages offered: the one chosen in Settings, the iPad's own, then the ones the app is written in.
    /// The first is what a transcription starts in.
    static var languages: [Locale] { languages(preferring: UserDefaults.standard.string(forKey: SettingsKey.transcriptLanguage) ?? "") }

    static func languages(preferring chosen: String, supported: Set<String> = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier(.bcp47) })) -> [Locale] {
        var seen = Set<String>(), result: [Locale] = []
        for identifier in [chosen, Locale.current.identifier(.bcp47), "en-US", "es-ES", "fr-FR", "de-DE"] where supported.contains(identifier) && seen.insert(identifier).inserted {
            result.append(Locale(identifier: identifier))
        }
        return result.isEmpty ? [Locale(identifier: "en-US")] : result
    }

    /// Every language this iPad can transcribe without sending a recording away, by name.
    static func onDeviceLanguages() -> [Locale] {
        var seen = Set<String>()
        return SFSpeechRecognizer.supportedLocales()
            .filter { seen.insert($0.identifier(.bcp47)).inserted && SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
            .sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
    }

    static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

/// Transcribes with the system's recogniser, on the device only: a recording is never sent away to be transcribed.
struct DeviceTranscriber: SpeechTranscribing {
    /// What one run has gathered. The recogniser calls back on its own queue, so everything here is behind a lock.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var transcript = Transcript(locale: "", words: [])
        private var loose: [String] = []
        private var task: SFSpeechRecognitionTask?
        private var finished = false
        private var cancelled = false

        /// A cancel that came before the task existed stops it as soon as it does.
        func hold(_ task: SFSpeechRecognitionTask) {
            let stop = lock.withLock {
                self.task = task
                return cancelled
            }
            if stop { task.cancel() }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                return task
            }?.cancel()
        }

        /// Returns how far into the recording the words now reach.
        func add(_ words: [Transcript.Word], loose: [String]) -> TimeInterval {
            lock.withLock {
                if words.isEmpty { self.loose = loose } else { transcript.merge(words) }
                return transcript.words.last.map { $0.start + $0.duration } ?? 0
            }
        }

        /// The words gathered and whether they came with their times, the first time it is asked; nil after that.
        func finish(duration: TimeInterval) -> (words: [Transcript.Word], timed: Bool)? {
            lock.withLock {
                guard !finished else { return nil }
                finished = true
                return transcript.words.isEmpty ? (Transcript.spread(loose, over: duration), false) : (transcript.words, true)
            }
        }
    }

    func transcribe(_ url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.notAllowed }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.unavailable(Transcription.name(of: locale))
        }
        let duration = ((try? await AVURLAsset(url: url).load(.duration))?.seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let run = Run()
        let (words, timed): ([Transcript.Word], Bool) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        let segments = result.bestTranscription.segments
                        // Only a settled stretch carries its times; what comes before is a running guess.
                        let timed = result.isFinal || result.speechRecognitionMetadata != nil
                        let words = timed && segments.contains(where: { $0.timestamp > 0 || $0.duration > 0 })
                            ? segments.map { Transcript.Word(text: $0.substring, start: $0.timestamp, duration: $0.duration) } : []
                        let reached = run.add(words, loose: result.isFinal ? segments.map(\.substring) : [])
                        if duration > 0 { progress(min(reached / duration, 1)) }
                        guard result.isFinal, let heard = run.finish(duration: duration) else { return }
                        continuation.resume(returning: heard)
                    } else if let heard = run.finish(duration: duration) {
                        // The recogniser ends a recording that trails off into silence with an error; what it heard still counts.
                        if heard.words.isEmpty, let error { continuation.resume(throwing: TranscriptionError.failed(error.localizedDescription)) }
                        else { continuation.resume(returning: heard) }
                    }
                }
                run.hold(task)
            }
        } onCancel: {
            run.cancel()
        }
        try Task.checkCancellation()
        guard !words.isEmpty else { throw TranscriptionError.nothingHeard }
        return Transcript(locale: locale.identifier(.bcp47), words: words, untimed: timed ? nil : true)
    }
}

#if DEBUG
/// `-fakeTranscript` stands this in for the recogniser, which a simulator doesn't have.
struct ScriptedTranscriber: SpeechTranscribing {
    static let script = "Today we cover the cell membrane. It keeps the cell together. Proteins carry signals across it."

    func transcribe(_ url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        var words: [Transcript.Word] = [], time: TimeInterval = 1
        for (index, word) in Self.script.split(separator: " ").enumerated() {
            words.append(Transcript.Word(text: String(word), start: time, duration: 0.4))
            time += word.hasSuffix(".") ? 3 : 0.5
            progress(Double(index + 1) / 16)
        }
        try await Task.sleep(for: .milliseconds(400))
        return Transcript(locale: locale.identifier(.bcp47), words: words)
    }
}
#endif
