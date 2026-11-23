import SwiftUI

/// One sitting with the cards: each is shown, turned over and answered, and one that was forgotten comes round again.
@MainActor
@Observable
final class ReviewSession {
    private(set) var queue: [DeckCard]
    private(set) var position = 0
    /// Cards that have been remembered in this sitting.
    private(set) var finished = 0
    private(set) var total: Int
    var isRevealed = false
    /// Cards answered Again at some point in this sitting, and cards remembered in it.
    private var forgotten: Set<UUID> = []
    private var remembered: Set<UUID> = []

    init(cards: [DeckCard]) {
        queue = cards
        total = cards.count
    }

    var current: DeckCard? { queue.indices.contains(position) ? queue[position] : nil }
    var remaining: Int { queue.count - position }
    /// Cards studied in this sitting, each counted once however many goes it took.
    var studied: Int { remembered.count }
    /// Cards remembered without once being answered Again in this sitting.
    var firstTime: Int { remembered.subtracting(forgotten).count }
    /// Cards that needed more than one go.
    var cameRound: Int { remembered.intersection(forgotten).count }

    func answer(_ grade: CardGrade, in library: FlashcardLibrary, now: Date = .now) {
        guard let current else { return }
        let updated = library.grade(current.id, in: current.notebook, grade, now: now) ?? current.card
        if grade == .again {
            forgotten.insert(current.id)
            queue.append(DeckCard(notebook: current.notebook, card: updated))
        } else {
            remembered.insert(current.id)
            finished += 1
        }
        position += 1
        isRevealed = false
    }

    /// The card in hand was deleted: it leaves the sitting, along with any later turn it had.
    func dropCurrent() {
        guard let current else { return }
        let earlier = queue[..<position].filter { $0.id == current.id }.count
        queue.removeAll { $0.id == current.id }
        forgotten.remove(current.id)
        remembered.remove(current.id)
        total = max(total - 1, finished)
        position = min(position - earlier, queue.count)
        isRevealed = false
    }
}
