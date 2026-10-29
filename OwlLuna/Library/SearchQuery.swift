import Foundation

/// What a search looks for: every word, and each quoted part as one phrase, all of them needed for a match.
struct SearchQuery: Sendable, Hashable {
    let terms: [String]
    /// The whole query, quotes taken out, which a snippet shows first when the text has it.
    let phrase: String

    private static let quotes: Set<Character> = ["\"", "“", "”", "„", "«", "»"]

    init(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        phrase = Self.collapsed(trimmed.filter { !Self.quotes.contains($0) })
        // Typed the way a tag is written, the query is one tag name, spaces and all.
        guard !trimmed.hasPrefix("#") else {
            terms = [trimmed]
            return
        }
        let parsed = trimmed.split(omittingEmptySubsequences: false, whereSeparator: Self.quotes.contains).enumerated().flatMap { index, part in
            index.isMultiple(of: 2)
                ? part.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }
                : [Self.collapsed(part)]
        }
        var seen = Set<String>()
        terms = parsed.filter { !$0.isEmpty && seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted }
    }

    var isEmpty: Bool { terms.isEmpty }

    /// Runs of white space and line breaks as one space.
    static func collapsed(_ text: some StringProtocol) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A page's or a transcript's text on one line, without the "#ink:" stamp: what a query is matched against.
    static func searchable(_ text: String) -> String {
        collapsed(text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#ink:") }.joined(separator: " "))
    }

    func matches(_ text: String) -> Bool {
        !terms.isEmpty && terms.allSatisfy { text.localizedStandardContains($0) }
    }

    /// The whole query where the text has it, or else the first place its longest term is.
    func focus(in text: String) -> Range<String.Index>? {
        if !phrase.isEmpty, let range = text.localizedStandardRange(of: phrase) { return range }
        return terms.max { $0.count < $1.count }.flatMap { text.localizedStandardRange(of: $0) }
    }

    /// The whole query wherever it is, and each term where it begins a word, in reading order.
    func highlights(in text: String) -> [Range<String.Index>] {
        var starts = Set<String.Index>()
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, word, _, _ in
            starts.insert(word.lowerBound)
        }
        return ([phrase] + terms).filter { !$0.isEmpty }.flatMap { Self.ranges(of: $0, in: text) }
            .filter { starts.contains($0.lowerBound) || !text[$0.lowerBound].isLetter && !text[$0.lowerBound].isNumber }
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    static func ranges(of term: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let match = text[start...].localizedStandardRange(of: term), !match.isEmpty {
            found.append(match)
            start = match.upperBound
        }
        return found
    }
}
