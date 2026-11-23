import SwiftUI

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
    @State private var strip: LiftStrip?
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
                ReviewFinished(session: session, all: all) { cards in
                    withAnimation(motion) { session = ReviewSession(cards: cards) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.desk.ignoresSafeArea())
        .background { shortcuts }
        .task(id: session.current?.id) { await loadImages() }
        .onChange(of: session.current?.id) { focusOnCard = true }
        .onChange(of: session.isRevealed) { _, revealed in if revealed { showAnswerToVoiceOver() } }
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
            Button(action: turnOver) { face(current) }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(spoken(current.card)))
            .accessibilityHint(Text(hint(current.card)))
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

    @ViewBuilder
    private func face(_ current: DeckCard) -> some View {
        let source = titles[current.notebook]
        if LiftStrip.lifts(current.card), let front, let back {
            CardFace(side: session.isRevealed ? current.card.back : current.card.front, isAnswer: session.isRevealed, source: source, hasClipping: true) {
                TapeLiftClipping(question: front, answer: back, strip: strip, lifted: session.isRevealed)
            }
        } else {
            ZStack {
                if session.isRevealed {
                    CardFace(side: current.card.back, image: back, isAnswer: true, source: source)
                        .transition(reduceMotion ? .opacity : .identity)
                } else {
                    CardFace(side: current.card.front, image: front, isAnswer: false, source: source)
                        .transition(reduceMotion ? .opacity : .identity)
                }
            }
            .rotation3DEffect(.degrees(tilt), axis: (x: 0, y: 1, z: 0), perspective: 0.12)
        }
    }

    /// The card swings edge-on, changes side, and swings back. With Reduce Motion the sides cross-fade. A tape card's
    /// tape lifts off instead, and its words change where they are.
    private func turnOver() {
        guard let current = session.current, tilt == 0 else { return }
        let revealed = !session.isRevealed
        if LiftStrip.lifts(current.card) {
            session.isRevealed = revealed
            return
        }
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

    private func hint(_ card: Flashcard) -> String {
        switch (LiftStrip.lifts(card), session.isRevealed) {
        case (true, false): String(localized: "Lifts the tape")
        case (true, true): String(localized: "Puts the tape back")
        case (false, false): String(localized: "Turns the card over")
        case (false, true): String(localized: "Turns back to the question")
        }
    }

    /// Show Answer goes once it is used, so VoiceOver is taken to the card, or told the answer if it is there already.
    private func showAnswerToVoiceOver() {
        guard let current = session.current else { return }
        if focusOnCard {
            AccessibilityNotification.Announcement(spoken(current.card)).post()
        } else {
            focusOnCard = true
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

    private func loadImages() async {
        front = nil
        back = nil
        strip = nil
        guard let current = session.current else { return }
        if titles[current.notebook] == nil {
            let title = store.record(current.notebook)?.title ?? ""
            titles[current.notebook] = title.orUntitled
        }
        async let first = library.image(current.card.front.image, in: current.notebook)
        async let second = library.image(current.card.back.image, in: current.notebook)
        let loaded = await (first, second)
        let found = await TapeFinder.strip(for: current.card, question: loaded.0, answer: loaded.1)
        guard !Task.isCancelled, session.current?.id == current.id else { return }
        front = loaded.0
        back = loaded.1
        strip = found
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
