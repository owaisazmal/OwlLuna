import SwiftUI

/// The flashcards that are due, on the desk beside today's page. Cards in locked notebooks stay out of it.
struct StudyCard: View {
    let records: [NotebookRecord]
    var asRow = false
    /// Opens a notebook at the page a card was made on.
    let onOpenPage: (UUID, UUID) -> Void
    @Environment(FlashcardLibrary.self) private var library
    @State private var reviewing: ReviewDeck?

    static func notebooks(in records: [NotebookRecord]) -> [UUID] {
        records.filter { !$0.isTrashed && !$0.isLocked }.map(\.id)
    }

    var body: some View {
        let notebooks = Self.notebooks(in: records)
        let due = library.due(in: notebooks), decks = Set(due.map(\.notebook)).count
        let next = due.isEmpty ? library.nextDue(in: notebooks).flatMap { ActivityFile.date(forKey: $0, calendar: .current) } : nil
        let detail = due.isEmpty ? next.map { String(localized: "Next on \($0.formatted(.dateTime.weekday(.wide)))") } ?? String(localized: "Nothing is due")
                                 : String(localized: "From \(decks) notebooks")
        Button {
            reviewing = ReviewDeck(due: due, all: library.all(in: notebooks))
        } label: {
            DeskCardLayout(asRow: asRow) {
                ZStack {
                    MiniCard(width: asRow ? 40 : 50).rotationEffect(.degrees(-7)).offset(x: -3, y: 3)
                    MiniCard(width: asRow ? 40 : 50).rotationEffect(.degrees(4))
                }
                .frame(width: asRow ? 48 : 60, height: asRow ? 40 : 48)
            } text: {
                Text("Flashcards")
                    .eyebrowStyle(Color.accentColor)
                Text(due.isEmpty ? String(localized: "All caught up") : String(localized: "\(due.count) cards to review"))
                    .modifier(DeskTitle(asRow: asRow, lines: 1))
                Text(detail)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.textSecondary)
            } accessory: {
                DeskAccessory(systemName: due.isEmpty ? "checkmark" : "arrow.forward")
            }
        }
        .buttonStyle(DeskCardButtonStyle())
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(due.isEmpty ? Text("Flashcards: all caught up. \(detail)") : Text("Flashcards: \(due.count) cards to review"))
        .accessibilityHint(Text("Opens the cards to study"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("desk.study")
        .fullScreenCover(item: $reviewing) { deck in
            CardReview(due: deck.due, all: deck.all) { notebook, page in
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    onOpenPage(notebook, page)
                }
            }
            .appModels()
        }
    }
}
