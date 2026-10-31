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

    init(cards: [DeckCard]) {
        queue = cards
        total = cards.count
    }

    var current: DeckCard? { queue.indices.contains(position) ? queue[position] : nil }
    var remaining: Int { queue.count - position }

    func answer(_ grade: CardGrade, in library: FlashcardLibrary, now: Date = .now) {
        guard let current else { return }
        let updated = library.grade(current.id, in: current.notebook, grade, now: now) ?? current.card
        if grade == .again {
            queue.append(DeckCard(notebook: current.notebook, card: updated))
        } else {
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
        total = max(total - 1, finished)
        position = min(position - earlier, queue.count)
        isRevealed = false
    }
}

/// Studying flashcards: the desk, one index card on a small pile, and the answer buttons under it.
struct CardReview: View {
    /// What is due, and everything there is for when nothing is due.
    let due: [DeckCard]
    let all: [DeckCard]
    /// Opens the page a card was made on, once this has closed.
    var openPage: ((UUID, UUID) -> Void)?

    @Environment(FlashcardLibrary.self) private var library
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var scheme
    @State private var session: ReviewSession
    @State private var front: UIImage?
    @State private var back: UIImage?
    @State private var confirmingDelete = false
    @State private var tilt = 0.0
    @State private var titles: [UUID: String] = [:]
    @AccessibilityFocusState private var focusOnCard: Bool

    init(due: [DeckCard], all: [DeckCard], openPage: ((UUID, UUID) -> Void)? = nil) {
        self.due = due
        self.all = all
        self.openPage = openPage
        _session = State(initialValue: ReviewSession(cards: due))
    }

    private var motion: Animation { Motion.adaptive(.spring(response: 0.42, dampingFraction: 0.82), reduceMotion: reduceMotion) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let current = session.current {
                Spacer(minLength: Space.x4)
                pile(current)
                    .padding(.horizontal, Space.x6)
                Spacer(minLength: Space.x4)
                answers(for: current.card)
                    .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: session.isRevealed)
                    .padding(.horizontal, Space.x6)
                    .padding(.bottom, Space.x6)
            } else {
                finishedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.desk.ignoresSafeArea())
        .background { shortcuts }
        .task(id: session.current?.id) { await loadImages() }
        .onChange(of: session.current?.id) { focusOnCard = true }
        .notice("Delete this flashcard?", isPresented: $confirmingDelete, message: Text("The page it was made from stays as it is.")) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Flashcard", role: .destructive, action: deleteCurrent)
        }
        .notice("Something went wrong", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.clearError() } }),
                message: Text(library.lastError ?? "")) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Header

    private var header: some View {
        let shown = min(session.finished + 1, max(session.total, 1))
        return ZStack {
            if let current = session.current {
                VStack(spacing: Space.x2) {
                    Text("Card \(shown) of \(session.total)")
                        .metaStyle(.footnote)
                        .accessibilityIdentifier("review.progress")
                    ReviewProgress(value: Double(session.finished) / Double(max(session.total, 1)))
                        .frame(width: 180)
                }
                .accessibilityElement(children: .combine)
                HStack {
                    Spacer()
                    OwlLunaMenu {
                        if let page = current.card.pageID, let openPage {
                            Button {
                                dismiss()
                                openPage(current.notebook, page)
                            } label: { Label("Open Its Page", systemImage: "book") }
                        }
                        if library.canChange(current.notebook) {
                            Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete Flashcard…", systemImage: "trash") }
                        }
                    } label: {
                        Label("Card Options", systemImage: "ellipsis")
                    }
                    .buttonStyle(.plateIcon)
                    .accessibilityIdentifier("review.options")
                }
            }
            HStack {
                Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
                    .buttonStyle(.plateIcon)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("review.close")
                Spacer()
            }
        }
        .padding(.horizontal, Space.x5)
        .padding(.top, Space.x4)
    }

    // MARK: The card

    private func pile(_ current: DeckCard) -> some View {
        let under = min(session.remaining - 1, 2)
        return ZStack {
            if under >= 2 { CardPaper().rotationEffect(.degrees(reduceMotion ? 0 : 2.4)).offset(y: 10).opacity(0.9) }
            if under >= 1 { CardPaper().rotationEffect(.degrees(reduceMotion ? 0 : -1.6)).offset(y: 5) }
            Button(action: turnOver) {
                ZStack {
                    if session.isRevealed {
                        CardFace(side: current.card.back, image: back, isAnswer: true, source: titles[current.notebook])
                            .transition(reduceMotion ? .opacity : .identity)
                    } else {
                        CardFace(side: current.card.front, image: front, isAnswer: false, source: titles[current.notebook])
                            .transition(reduceMotion ? .opacity : .identity)
                    }
                }
                .rotation3DEffect(.degrees(tilt), axis: (x: 0, y: 1, z: 0), perspective: 0.12)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(spoken(current.card)))
            .accessibilityHint(Text(session.isRevealed ? "Turns back to the question" : "Turns the card over"))
            .accessibilityFocused($focusOnCard)
            .accessibilityIdentifier("review.card")
            .id("\(current.id)-\(session.position)")
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                                              removal: .move(edge: .trailing).combined(with: .opacity)))
        }
        .frame(maxWidth: 620)
        .aspectRatio(dynamicTypeSize.isAccessibilitySize ? 1.1 : 1.5, contentMode: .fit)
        .shadow(color: Elevation.shade(scheme == .dark).opacity(scheme == .dark ? 0.5 : 0.16), radius: 14, y: 8)
        .shadow(color: Elevation.shade(scheme == .dark).opacity(scheme == .dark ? 0.4 : 0.10), radius: 1, y: 1)
    }

    /// The card swings edge-on, changes side, and swings back. With Reduce Motion the sides cross-fade.
    private func turnOver() {
        guard session.current != nil, tilt == 0 else { return }
        let revealed = !session.isRevealed
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.18)) { session.isRevealed = revealed }
            return
        }
        withAnimation(.easeIn(duration: 0.14)) {
            tilt = revealed ? 90 : -90
        } completion: {
            session.isRevealed = revealed
            tilt = revealed ? -90 : 90
            withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) { tilt = 0 }
        }
    }

    private func spoken(_ card: Flashcard) -> String {
        let side = session.isRevealed ? card.back : card.front
        let name = session.isRevealed ? String(localized: "Answer") : String(localized: "Question")
        return "\(name). \(side.spoken)"
    }

    // MARK: Answers

    @ViewBuilder
    private func answers(for card: Flashcard) -> some View {
        if session.isRevealed {
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Space.x3)) : AnyLayout(HStackLayout(spacing: Space.x3))
            layout {
                answerButton(.again, "Again", card).buttonStyle(.owlLuna)
                answerButton(.good, "Good", card).buttonStyle(.owlLuna(.primary))
                answerButton(.easy, "Easy", card).buttonStyle(.owlLuna)
            }
            .frame(maxWidth: 520)
            .transition(.opacity)
        } else {
            Button(action: turnOver) { Text("Show Answer").frame(maxWidth: 280) }
            .buttonStyle(.owlLuna(.primary))
            .accessibilityIdentifier("review.show")
            .transition(.opacity)
        }
    }

    private func answerButton(_ grade: CardGrade, _ title: LocalizedStringKey, _ card: Flashcard) -> some View {
        let wait = CardSchedule.waitText(CardSchedule.interval(after: grade, for: card))
        return Button { answer(grade) } label: {
            VStack(spacing: 0) {
                Text(title)
                Text(wait).font(.caption.weight(.regular))
            }
            .padding(.vertical, Space.x1)
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text("Comes back: \(wait)"))
        .accessibilityIdentifier("review.\(grade)")
    }

    private func answer(_ grade: CardGrade) {
        guard session.current != nil, session.isRevealed else { return }
        withAnimation(motion) { session.answer(grade, in: library) }
        if session.current == nil {
            AccessibilityNotification.Announcement(String(localized: "All caught up")).post()
        }
    }

    private func deleteCurrent() {
        guard let current = session.current else { return }
        library.remove([current.id], from: current.notebook)
        withAnimation(motion) { session.dropCurrent() }
    }

    private var shortcuts: some View {
        Group {
            Button("Turn Card Over", action: turnOver).keyboardShortcut(.space, modifiers: [])
            Button("Again") { answer(.again) }.keyboardShortcut("1", modifiers: [])
            Button("Good") { answer(.good) }.keyboardShortcut("2", modifiers: [])
            Button("Easy") { answer(.easy) }.keyboardShortcut("3", modifiers: [])
        }
        .disabled(session.current == nil)
        .hidden()
        .accessibilityHidden(true)
    }

    // MARK: Nothing left

    private var finishedView: some View {
        let studied = session.total > 0
        let visible = Set(all.map(\.notebook))
        let next = library.nextDue(in: visible).flatMap { ActivityFile.date(forKey: $0, calendar: .current) }
        return ScrollView {
            VStack(spacing: Space.x4) {
                CardStackIllustration(isDone: true, width: 132)
                    .padding(.bottom, Space.x2)
                Text(studied ? "All caught up." : "Nothing is due.")
                    .displayFont(34)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("review.done.title")
                Group {
                    if let next {
                        Text("The next cards come back on \(next.formatted(.dayName)).")
                    } else if studied {
                        Text("Every card has been through your hands today.")
                    } else {
                        Text("Cards come back here when it is time to see them again.")
                    }
                }
                .font(.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: Space.x3) {
                    Button { dismiss() } label: { Text("Done").frame(maxWidth: 240) }
                        .buttonStyle(.owlLuna(.primary))
                        .accessibilityIdentifier("review.done")
                    if !library.refreshed(all).isEmpty {
                        Button {
                            withAnimation(motion) { session = ReviewSession(cards: library.refreshed(all)) }
                        } label: {
                            Text(studied ? "Go Through Them All Again" : "Study Them Anyway").frame(maxWidth: 240)
                        }
                        .buttonStyle(.owlLuna)
                        .accessibilityIdentifier("review.all")
                    }
                }
                .padding(.top, Space.x3)
            }
            .padding(Space.x8)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity)
    }

    private func loadImages() async {
        front = nil
        back = nil
        guard let current = session.current else { return }
        if titles[current.notebook] == nil {
            let title = store.record(current.notebook)?.title ?? ""
            titles[current.notebook] = title.orUntitled
        }
        async let first = library.image(current.card.front.image, in: current.notebook)
        async let second = library.image(current.card.back.image, in: current.notebook)
        let loaded = await (first, second)
        guard !Task.isCancelled, session.current?.id == current.id else { return }
        front = loaded.0
        back = loaded.1
    }
}

/// How far through the sitting: a well with the cloth filling it.
private struct ReviewProgress: View {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.primaryCloth)
                .frame(width: max(proxy.size.width * min(max(value, 0), 1), value > 0 ? 6 : 0))
                .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: value)
        }
        .frame(height: 6)
        .well(in: RoundedRectangle(cornerRadius: 2))
        .accessibilityHidden(true)
    }
}
