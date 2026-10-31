import Foundation

/// One side of a flashcard: words, a clipping from a page, or both.
struct CardSide: Codable, Equatable, Sendable {
    var text = ""
    /// A PNG in the notebook's `cards/` folder.
    var image: String?
    /// The words read from the clipping when it was cut. Older cards have none.
    var imageText: String?

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && image == nil }

    init(text: String = "", image: String? = nil, imageText: String? = nil) {
        self.text = text
        self.image = image
        self.imageText = imageText
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        image = try values.decodeIfPresent(String.self, forKey: .image)
        imageText = try values.decodeIfPresent(String.self, forKey: .imageText)
    }

    /// What VoiceOver says for the side: its own words, then what its clipping reads as.
    var spoken: String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard image != nil else { return words }
        let read = imageText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if read.isEmpty { return words.isEmpty ? String(localized: "A clipping from the page") : words }
        return words.isEmpty ? read : "\(words)\n\(read)"
    }
}

/// How well a card was remembered.
enum CardGrade: Int, CaseIterable, Sendable {
    case again, good, easy
}

/// A question and its answer, kept with the notebook it came from and shown again when it is about to be forgotten.
struct Flashcard: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var front = CardSide()
    var back = CardSide()
    /// The page it was made on, and the strip of study tape it was made from.
    var pageID: UUID?
    var tapeID: UUID?
    var createdAt = Date.now
    /// The day it is next shown, as a day key ("2026-10-03").
    var due: String
    /// Days between the last review and the next. Zero until it has been remembered once.
    var interval = 0
    var ease = CardSchedule.startingEase
    var reviews = 0
    var lapses = 0
    var lastReviewed: Date?
    /// When it was last answered or rewritten. Older builds leave it out.
    var changedAt: Date?

    init(front: CardSide, back: CardSide, pageID: UUID? = nil, tapeID: UUID? = nil, now: Date = .now, calendar: Calendar = .current) {
        self.front = front
        self.back = back
        self.pageID = pageID
        self.tapeID = tapeID
        createdAt = now
        due = ActivityFile.dayKey(for: now, calendar: calendar)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        front = try values.decodeIfPresent(CardSide.self, forKey: .front) ?? CardSide()
        back = try values.decodeIfPresent(CardSide.self, forKey: .back) ?? CardSide()
        pageID = try values.decodeIfPresent(UUID.self, forKey: .pageID)
        tapeID = try values.decodeIfPresent(UUID.self, forKey: .tapeID)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        due = try values.decodeIfPresent(String.self, forKey: .due) ?? ActivityFile.dayKey(for: createdAt, calendar: .current)
        interval = max(try values.decodeIfPresent(Int.self, forKey: .interval) ?? 0, 0)
        ease = max(try values.decodeIfPresent(Double.self, forKey: .ease) ?? CardSchedule.startingEase, CardSchedule.minimumEase)
        reviews = try values.decodeIfPresent(Int.self, forKey: .reviews) ?? 0
        lapses = try values.decodeIfPresent(Int.self, forKey: .lapses) ?? 0
        lastReviewed = try values.decodeIfPresent(Date.self, forKey: .lastReviewed)
        changedAt = try values.decodeIfPresent(Date.self, forKey: .changedAt)
    }

    func isDue(on day: String) -> Bool { due <= day }

    /// When it last changed, to the second as `cards.json` keeps it. Two copies of a card are settled by it.
    var stamp: Date { FlashcardFile.second(max(createdAt, changedAt ?? createdAt, lastReviewed ?? createdAt)) }
}

/// Spaced repetition in the manner of SM-2: each time a card is remembered the wait before it comes back grows,
/// and a card that was forgotten starts again.
enum CardSchedule {
    static let startingEase = 2.5
    static let minimumEase = 1.3
    static let longestInterval = 365

    /// Days until the card is shown again. Zero means later in the same sitting.
    static func interval(after grade: CardGrade, for card: Flashcard, now: Date = .now, calendar: Calendar = .current) -> Int {
        if grade != .again, let early = daysEarly(card, now: now, calendar: calendar) {
            let elapsed = Double(max(card.interval - early, 0))
            let grown = Int((elapsed * card.ease * (grade == .easy ? 1.3 : 1)).rounded())
            return min(max(grown, card.interval, early), longestInterval)
        }
        return switch grade {
        case .again: 0
        case .good:
            switch card.interval {
            case 0: 1
            case 1: 3
            default: min(Int((Double(card.interval) * card.ease).rounded()), longestInterval)
            }
        case .easy:
            card.interval == 0 ? 4 : min(max(Int((Double(card.interval) * card.ease * 1.3).rounded()), card.interval + 1), longestInterval)
        }
    }

    static func graded(_ card: Flashcard, _ grade: CardGrade, now: Date = .now, calendar: Calendar = .current) -> Flashcard {
        var next = card
        next.interval = interval(after: grade, for: card, now: now, calendar: calendar)
        let early = daysEarly(card, now: now, calendar: calendar)
        switch grade {
        case .again where card.interval > 0 && (early ?? 0) < card.interval:
            next.ease = max(card.ease - 0.2, minimumEase)
            next.lapses += 1
        case .easy where early == nil:
            next.ease = card.ease + 0.15
        default: break
        }
        next.reviews += 1
        next.lastReviewed = now
        next.changedAt = now
        let day = calendar.date(byAdding: .day, value: next.interval, to: now) ?? now
        next.due = ActivityFile.dayKey(for: day, calendar: calendar)
        return next
    }

    /// Days still to go before a learned card's day, or nil when it is due or its day can't be read.
    private static func daysEarly(_ card: Flashcard, now: Date, calendar: Calendar) -> Int? {
        let gmt = ActivityFile.gregorian(.gmt)
        guard card.interval > 0,
              let today = ActivityFile.date(forKey: ActivityFile.dayKey(for: now, calendar: calendar), calendar: gmt),
              let due = ActivityFile.date(forKey: card.due, calendar: gmt),
              let days = gmt.dateComponents([.day], from: today, to: due).day, days > 0 else { return nil }
        return days
    }
}

/// `cards.json` in a notebook's package.
struct FlashcardFile: Codable, Sendable {
    static let currentVersion = 1

    var version = FlashcardFile.currentVersion
    var cards: [Flashcard] = []
    /// When each deleted card was deleted, by ID, so a copy that still has it doesn't bring it back.
    var removed: [String: Date]?

    static func second(_ date: Date) -> Date { Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down)) }
}
