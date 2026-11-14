import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What a study guide is written from.
enum StudyScope: Hashable, Sendable {
    case page(UUID)
    case notebook
    case recording(UUID)
}

struct StudyGuideRequest: Identifiable {
    let id = UUID()
    var scope: StudyScope
}

struct QuizItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    var question: String
    var answer: String
}

enum StudyGuideError: LocalizedError, Equatable {
    case nothingToRead
    case tooLong
    case declined
    case language

    var errorDescription: String? {
        switch self {
        case .nothingToRead: String(localized: "There isn't enough writing here to study from yet.")
        case .tooLong: (Device.isMac
            ? String(localized: "These notes are too long for the model on this Mac to read at once.")
            : String(localized: "These notes are too long for the model on this iPad to read at once."))
        case .declined: (Device.isMac
            ? String(localized: "The model on this Mac wouldn't write about these notes.")
            : String(localized: "The model on this iPad wouldn't write about these notes."))
        case .language: (Device.isMac
            ? String(localized: "The model on this Mac can't read the language of these notes yet.")
            : String(localized: "The model on this iPad can't read the language of these notes yet."))
        }
    }
}

/// Whether this iPad has a language model of its own to write with.
enum StudyModelStatus: Equatable {
    case ready
    /// The system is older than the one the model came with.
    case needsUpdate
    case notEligible
    case turnedOff
    case preparing
}

/// Reads notes and writes about them. The app's own is Apple's on-device model; tests use a scripted one.
protocol StudyModel: Sendable {
    func keyPoints(in text: String, atMost limit: Int) async throws -> [String]
    func questions(about text: String, count: Int) async throws -> [QuizItem]
}

/// Summaries and practice questions written on the device from a notebook's words. Nothing is sent anywhere.
enum StudyGuide {
    /// About as much as the model can take in with room left to answer.
    static let chunkLimit = 3200
    /// Longer notes are summarised from this many pieces, spread evenly through them.
    static let summaryPieces = 24
    static let minimumText = 40

    static var status: StudyModelStatus {
        #if DEBUG
        if LaunchOptions.arguments.contains("-fakeModel") { return .ready }
        if LaunchOptions.arguments.contains("-noModel") { return .turnedOff }
        #endif
        #if canImport(FoundationModels)
        guard #available(iOS 26, *) else { return .needsUpdate }
        switch SystemLanguageModel.default.availability {
        case .available: return .ready
        case .unavailable(.deviceNotEligible): return .notEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .turnedOff
        case .unavailable(.modelNotReady): return .preparing
        @unknown default: return .preparing
        }
        #else
        return .needsUpdate
        #endif
    }

    static func model() -> (any StudyModel)? {
        #if DEBUG
        if LaunchOptions.arguments.contains("-fakeModel") { return ScriptedStudyModel() }
        #endif
        #if canImport(FoundationModels)
        if #available(iOS 26, *), status == .ready { return AppleStudyModel() }
        #endif
        return nil
    }

    /// A page's text file without the stamp on its first line.
    static func body(ofPageText text: String) -> String {
        guard text.hasPrefix("#ink:"), let end = text.firstIndex(of: "\n") else { return text.hasPrefix("#ink:") ? "" : text }
        return String(text[text.index(after: end)...])
    }

    /// Pieces of at most `limit` characters, cut between lines where it can and between words where it can't.
    static func chunks(of text: String, limit: Int = chunkLimit) -> [String] {
        var chunks: [String] = [], current = ""
        func close() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(trimmed) }
            current = ""
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var rest = Substring(line.trimmingCharacters(in: .whitespaces))
            while rest.count > limit {
                close()
                let end = rest.index(rest.startIndex, offsetBy: limit)
                let cut = rest[..<end].lastIndex(of: " ") ?? end
                chunks.append(String(rest[..<cut]))
                rest = rest[cut...].drop { $0 == " " }
            }
            if current.count + rest.count + 1 > limit { close() }
            if !rest.isEmpty { current += (current.isEmpty ? "" : "\n") + rest }
        }
        close()
        return chunks
    }

    /// The main points of the text, with long notes read a piece at a time and the pieces' points boiled down.
    static func summary(of text: String, using model: any StudyModel, limit: Int = 7, rounds: Int = 2,
                        progress: @MainActor @Sendable (Double) -> Void = { _ in }) async throws -> [String] {
        let pieces = spread(try chunksToRead(text), atMost: summaryPieces)
        var points: [String] = []
        for (index, piece) in pieces.enumerated() {
            points += try await keyPoints(in: piece, atMost: pieces.count == 1 ? limit : 5, using: model)
            await progress(Double(index + 1) / Double(pieces.count + (pieces.count > 1 ? 1 : 0)))
        }
        points = distinct(points)
        if pieces.count > 1, points.count > limit {
            let listed = points.map { "- \($0)" }.joined(separator: "\n")
            if listed.count <= chunkLimit {
                points = distinct(try await keyPoints(in: listed, atMost: limit, using: model))
            } else if rounds > 0 {
                points = try await summary(of: listed, using: model, limit: limit, rounds: rounds - 1)
            } else {
                points = spread(points, atMost: limit)
            }
        }
        await progress(1)
        guard !points.isEmpty else { throw StudyGuideError.nothingToRead }
        return Array(points.prefix(limit))
    }

    /// Practice questions with their answers, spread over the whole of the text.
    static func quiz(of text: String, using model: any StudyModel, count: Int = 8,
                     progress: @MainActor @Sendable (Double) -> Void = { _ in }) async throws -> [QuizItem] {
        let pieces = spread(try chunksToRead(text), atMost: count)
        let each = Int((Double(count) / Double(pieces.count)).rounded(.up))
        var items: [QuizItem] = [], asked: Set<String> = []
        for (index, piece) in pieces.enumerated() {
            for item in try await questions(about: piece, count: each, using: model) {
                let question = item.question.trimmingCharacters(in: .whitespacesAndNewlines), answer = item.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !question.isEmpty, !answer.isEmpty, asked.insert(question.lowercased()).inserted else { continue }
                items.append(QuizItem(question: question, answer: answer))
            }
            await progress(Double(index + 1) / Double(pieces.count))
        }
        guard !items.isEmpty else { throw StudyGuideError.nothingToRead }
        return Array(items.prefix(count))
    }

    /// The text's pieces, or `nothingToRead` when there is too little of it to study from.
    private static func chunksToRead(_ text: String) throws -> [String] {
        let pieces = chunks(of: text)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumText, !pieces.isEmpty else { throw StudyGuideError.nothingToRead }
        return pieces
    }

    /// At most `count` of the items, one from the middle of each of `count` equal stretches.
    private static func spread<Item>(_ items: [Item], atMost count: Int) -> [Item] {
        guard items.count > count else { return items }
        let step = Double(items.count) / Double(count)
        return (0..<count).map { items[Int((Double($0) + 0.5) * step)] }
    }

    private static func keyPoints(in text: String, atMost limit: Int, using model: any StudyModel) async throws -> [String] {
        try await read(text, asking: limit, perHalf: max(limit / 2, 2)) { try await model.keyPoints(in: $0, atMost: $1) }
    }

    private static func questions(about text: String, count: Int, using model: any StudyModel) async throws -> [QuizItem] {
        try await read(text, asking: count, perHalf: max(count / 2, 1)) { try await model.questions(about: $0, count: $1) }
    }

    /// A piece the model found too long is read as two halves. Once the task is cancelled the model isn't asked again.
    private static func read<Item>(_ text: String, asking whole: Int, perHalf half: Int,
                                   _ ask: (String, Int) async throws -> [Item]) async throws -> [Item] {
        do {
            try Task.checkCancellation()
            return try await ask(text, whole)
        } catch StudyGuideError.tooLong {
            let halves = chunks(of: text, limit: max(text.count / 2, 200))
            guard halves.count > 1 else { throw StudyGuideError.tooLong }
            var results: [Item] = []
            for piece in halves {
                try Task.checkCancellation()
                results += try await ask(piece, half)
            }
            return results
        }
    }

    private static func distinct(_ points: [String]) -> [String] {
        var seen: Set<String> = []
        return points.compactMap { point in
            let trimmed = point.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-•*")))
            return !trimmed.isEmpty && seen.insert(trimmed.lowercased()).inserted ? trimmed : nil
        }
    }

    /// The points as lines of a text box.
    static func listed(_ points: [String]) -> String {
        points.map { "• \($0)" }.joined(separator: "\n")
    }
}

extension StudyGuide {
    /// The words of the pages or recording in `scope`, with handwriting read first where it hasn't been yet.
    @MainActor
    static func text(for scope: StudyScope, in document: NotebookDocument,
                     progress: @MainActor @Sendable (Double) -> Void = { _ in }) async throws -> String {
        switch scope {
        case .recording(let id):
            guard let file = document.manifest.recordings.first(where: { $0.id == id })?.transcriptFile else { return "" }
            return document.package.readTranscript(file)?.text ?? ""
        case .page, .notebook:
            _ = await document.flush()
            var pages = document.pages
            if case .page(let id) = scope { pages = pages.filter { $0.id == id } }
            let package = document.package
            await HandwritingIndexer.shared.index(HandwritingIndexer.Job(package: package, pages: pages)) { await progress($0) }
            var parts: [String] = []
            for page in pages {
                try Task.checkCancellation()
                guard let text = await package.readText(page.id) else { continue }
                let body = body(ofPageText: text).trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { parts.append(body) }
            }
            progress(1)
            return parts.joined(separator: "\n\n")
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26, *)
@Generable
struct GeneratedStudyPoints {
    @Guide(description: "The most important facts and ideas in the notes. Each is one short sentence that makes sense on its own.")
    var points: [String]
}

@available(iOS 26, *)
@Generable
struct GeneratedQuestion {
    @Guide(description: "A question that one fact in the notes answers.")
    var question: String
    @Guide(description: "The answer from the notes, in a few words or one short sentence.")
    var answer: String
}

@available(iOS 26, *)
@Generable
struct GeneratedQuiz {
    @Guide(description: "Practice questions about the notes, each about a different fact.")
    var questions: [GeneratedQuestion]
}

/// Apple's language model, running on the iPad.
@available(iOS 26, *)
struct AppleStudyModel: StudyModel {
    private static let instructions = """
        You help a student study their own notes. The notes were read from handwriting by a machine, so a word may be \
        misread or lines may be out of order: take the meaning that makes sense and never mention the reading mistakes. \
        Use only what the notes say and add nothing from elsewhere. Write in the language the notes are written in.
        """

    func keyPoints(in text: String, atMost limit: Int) async throws -> [String] {
        try await answering {
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = "List the \(limit) most important points of these notes, the most important first.\n\nNotes:\n\(text)"
            return Array(try await session.respond(to: prompt, generating: GeneratedStudyPoints.self).content.points.prefix(limit))
        }
    }

    func questions(about text: String, count: Int) async throws -> [QuizItem] {
        try await answering {
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = "Write \(count) practice questions about these notes. Give each its answer in a few words, not a whole sentence.\n\nNotes:\n\(text)"
            return try await session.respond(to: prompt, generating: GeneratedQuiz.self).content.questions.prefix(count)
                .map { QuizItem(question: $0.question, answer: $0.answer) }
        }
    }

    private func answering<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw StudyGuideError.tooLong
            case .guardrailViolation, .refusal: throw StudyGuideError.declined
            case .unsupportedLanguageOrLocale: throw StudyGuideError.language
            default: throw error
            }
        } catch {
            if #available(iOS 27, *), let known = error as? LanguageModelError {
                switch known {
                case .contextSizeExceeded: throw StudyGuideError.tooLong
                case .guardrailViolation, .refusal: throw StudyGuideError.declined
                case .unsupportedLanguageOrLocale: throw StudyGuideError.language
                default: throw error
                }
            }
            throw error
        }
    }
}
#endif

#if DEBUG
/// Stands in for the model in tests (`-fakeModel`): the notes' own lines come back as points and as answers.
struct ScriptedStudyModel: StudyModel {
    func keyPoints(in text: String, atMost limit: Int) async throws -> [String] {
        Array(lines(text).prefix(limit))
    }

    func questions(about text: String, count: Int) async throws -> [QuizItem] {
        lines(text).prefix(count).map { line in
            let subject = line.split(separator: " ").prefix(2).joined(separator: " ")
            return QuizItem(question: "What do the notes say about \(subject)?", answer: line)
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
#endif
