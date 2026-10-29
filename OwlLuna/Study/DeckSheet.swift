import SwiftUI

/// What is being studied: the cards due, and all of them for going through anyway.
struct ReviewDeck: Identifiable {
    let id = UUID()
    let due: [DeckCard]
    let all: [DeckCard]
}

/// A notebook's flashcards: study them, look through them, write one, or make them from the study tape on its pages.
struct DeckSheet: View {
    let session: EditorSession
    @Environment(FlashcardLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var draft: CardDraft?
    @State private var reviewing: ReviewDeck?
    @State private var isMaking = false
    @State private var failure: String?
    @State private var changes = LibraryChangeCenter()

    private var notebook: UUID { session.document.id }
    private var cards: [Flashcard] { library.cards(in: notebook) }
    private var today: String { ActivityFile.dayKey(for: .now, calendar: .current) }
    private var canChange: Bool { library.canChange(notebook) && !session.document.isReadOnly }

    var body: some View {
        let cards = cards, tapes = canChange ? session.tapesWithoutCards(in: library).count : 0
        NavigationStack {
            Group {
                if cards.isEmpty { empty(tapes: tapes) } else { list(cards, tapes: tapes) }
            }
            .background(Color.surface)
            .navigationTitle("Flashcards")
            .barGround(.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.owlLuna(.secondary, inBar: true))
                        .accessibilityIdentifier("deck.done")
                }
                .boardBackground()
                if canChange {
                    ToolbarItem(placement: .primaryAction) {
                        Button { draft = CardDraft(pageID: session.shownPage?.id) } label: { Label("New Flashcard", systemImage: "plus") }
                            .buttonStyle(.plateIcon)
                            .accessibilityIdentifier("deck.new")
                    }
                    .boardBackground()
                }
            }
        }
        .overlay(alignment: .bottom) { slip }
        .task(id: changes.current?.id) {
            guard changes.current != nil, !voiceOver else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { changes.dismiss() }
        }
        .onChange(of: draft != nil || reviewing != nil) { _, covered in if covered { changes.dismiss() } }
        .presentationBackground(Color.surface)
        .sheet(item: $draft) { draft in CardComposer(notebook: notebook, draft: draft).presentationCornerRadius(Radius.sheet) }
        .fullScreenCover(item: $reviewing) { deck in
            CardReview(due: deck.due, all: deck.all) { _, page in
                dismiss()
                if let index = session.document.index(of: page) { session.go(to: index) }
            }
        }
        .notice("Something went wrong", isPresented: Binding(get: { failure != nil || library.lastError != nil },
                                                             set: { if !$0 { failure = nil; library.clearError() } }),
                message: Text(failure ?? library.lastError ?? "")) {
            Button("OK", role: .cancel) {}
        }
    }

    private func study() {
        reviewing = ReviewDeck(due: library.due(in: [notebook]), all: library.all(in: [notebook]))
    }

    /// The slip's Undo puts the card back in its place, with its schedule.
    private func delete(_ card: Flashcard) {
        let index = cards.firstIndex { $0.id == card.id } ?? 0, notebook = notebook, library = library
        library.remove([card.id], from: notebook)
        changes.post(String(localized: "Deleted a flashcard"), symbol: "trash") { library.restore(card, at: index, in: notebook) }
    }

    private var slip: some View {
        ZStack {
            if let change = changes.current {
                LibrarySlipView(change: change) { changes.dismiss() }
                    .padding(.bottom, Space.x4)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: changes.current?.id)
    }

    // MARK: The cards

    private func list(_ cards: [Flashcard], tapes: Int) -> some View {
        let due = cards.filter { $0.isDue(on: today) }.count
        return Ledger {
            Section {
                summary(count: cards.count, due: due)
                if tapes > 0 { tapeRow(tapes) }
            }
            Section {
                ForEach(cards) { card in
                    DeckRow(card: card, notebook: notebook, page: card.pageID.flatMap(session.document.index(of:)).map { $0 + 1 }, today: today) {
                        if canChange { draft = CardDraft(editing: card) }
                    }
                    .ledgerSwipe {
                        if canChange {
                            Button(role: .destructive) { delete(card) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    .heldMenu(Text("Flashcard")) {
                        if let page = card.pageID, let index = session.document.index(of: page) {
                            Button {
                                dismiss()
                                session.go(to: index)
                            } label: { Label("Open Its Page", systemImage: "book") }
                        }
                        if canChange {
                            Button(role: .destructive) { delete(card) } label: { Label("Delete Flashcard", systemImage: "trash") }
                        }
                    }
                }
            } header: {
                Text("Cards")
            }
        }
    }

    private func summary(count: Int, due: Int) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x3))
                                                         : AnyLayout(HStackLayout(spacing: Space.x4))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) cards")
                    .displayFont(26, relativeTo: .title2)
                    .foregroundStyle(Color.ink)
                Text(due > 0 ? String(localized: "\(due) due today") : String(localized: "None due today"))
                    .metaStyle(.footnote)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("deck.summary")
            Spacer(minLength: 0)
            Button(action: study) { Label(due > 0 ? "Study" : "Study Anyway", systemImage: "rectangle.on.rectangle.angled") }
                .buttonStyle(.owlLuna(.primary))
                .accessibilityIdentifier("deck.study")
        }
        .padding(.vertical, Space.x2)
    }

    private func tapeRow(_ tapes: Int) -> some View {
        Button(action: makeTapeCards) {
            HStack(spacing: Space.x3) {
                TapeStrip(color: .mustard)
                    .frame(width: 56, height: 16)
                    .rotationEffect(.degrees(-4))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Make Cards from Study Tape").font(.body.weight(.medium)).foregroundStyle(Color.ink)
                    Text("\(tapes) strips of tape have no card yet").font(.footnote).foregroundStyle(Color.textSecondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if isMaking { ProgressView().controlSize(.small) }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isMaking)
        .accessibilityIdentifier("deck.tape")
    }

    private func makeTapeCards() {
        guard !isMaking else { return }
        isMaking = true
        Task {
            defer { isMaking = false }
            var made = 0
            for (page, tape) in session.tapesWithoutCards(in: library) {
                do {
                    try await session.makeCard(from: tape, on: page, in: library)
                    made += 1
                } catch {
                    failure = error.localizedDescription
                    break
                }
            }
            if made > 0 { AccessibilityNotification.Announcement(String(localized: "\(made) flashcards made")).post() }
        }
    }

    // MARK: No cards yet

    private func empty(tapes: Int) -> some View {
        ScrollView {
            VStack(spacing: Space.x3) {
                CardStackIllustration()
                    .padding(.bottom, Space.x2)
                Text("No flashcards yet.")
                    .displayFont(26, relativeTo: .title2)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("Cover an answer with study tape and make a card from the strip, select handwriting and turn it into one, or write a card yourself. Each comes back when it is time to see it again.")
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if canChange {
                    VStack(spacing: Space.x3) {
                        Button { draft = CardDraft(pageID: session.shownPage?.id) } label: { Label("Write a Card", systemImage: "square.and.pencil").frame(maxWidth: 260) }
                            .buttonStyle(.owlLuna(.primary))
                            .accessibilityIdentifier("deck.write")
                        if tapes > 0 {
                            Button(action: makeTapeCards) {
                                Label("Make Cards from Study Tape", systemImage: "rectangle.dashed").frame(maxWidth: 260)
                            }
                            .buttonStyle(.owlLuna)
                            .disabled(isMaking)
                            .accessibilityIdentifier("deck.tape")
                        }
                    }
                    .padding(.top, Space.x3)
                }
            }
            .padding(Space.x8)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("deck.empty")
    }
}

private struct DeckRow: View {
    let card: Flashcard
    let notebook: UUID
    let page: Int?
    let today: String
    let edit: () -> Void
    @Environment(FlashcardLibrary.self) private var library
    @State private var image: UIImage?

    var body: some View {
        let due = card.dueText(today: today)
        Button(action: edit) {
            HStack(spacing: Space.x3) {
                MiniCard(image: image, width: 62)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.summary(pageNumber: page))
                        .font(.body)
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                    Text(page.map { String(localized: "Page \($0) · \(due)") } ?? due)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Color.textSecondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: card.front.image) { image = await library.image(card.front.image, in: notebook) }
        .accessibilityIdentifier("deck.card")
    }
}

/// Writing or changing a card: the question over the answer, and a way to turn the card round.
struct CardComposer: View {
    let notebook: UUID
    /// Called with the card once it is kept.
    var onSave: ((Flashcard) -> Void)?
    @Environment(FlashcardLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CardDraft
    @State private var frontImage: UIImage?
    @State private var backImage: UIImage?
    @State private var isSaving = false
    @State private var failure: String?
    @FocusState private var focus: Field?

    private enum Field { case front, back }

    init(notebook: UUID, draft: CardDraft, onSave: ((Flashcard) -> Void)? = nil) {
        self.notebook = notebook
        self.onSave = onSave
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x3) {
                    side("Question", prompt: "What the card asks", side: $draft.front, image: frontImage, field: .front)
                    HStack {
                        Rectangle().fill(Color.hairline).frame(height: 1)
                        Button { draft.swapSides() } label: { Label("Swap Question and Answer", systemImage: "arrow.up.arrow.down") }
                            .buttonStyle(.plateIcon)
                            .accessibilityIdentifier("composer.swap")
                        Rectangle().fill(Color.hairline).frame(height: 1)
                    }
                    side("Answer", prompt: "What it answers", side: $draft.back, image: backImage, field: .back)
                }
                .padding(Space.x4)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.surface)
            .navigationTitle(draft.card == nil ? "New Flashcard" : "Edit Flashcard")
            .barGround(.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                CancelToolbarItem { dismiss() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .buttonStyle(.owlLuna(.primary, inBar: true))
                        .disabled(!draft.isComplete || isSaving)
                        .accessibilityIdentifier("composer.save")
                }
                .boardBackground()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.surface)
        .task(id: draft.front.imageName) { frontImage = await library.image(draft.front.imageName, in: notebook) }
        .task(id: draft.back.imageName) { backImage = await library.image(draft.back.imageName, in: notebook) }
        .onAppear { if draft.card == nil { focus = draft.front.isEmpty ? .front : .back } }
        .notice("The card couldn't be saved", message: $failure)
    }

    private func side(_ title: LocalizedStringKey, prompt: LocalizedStringKey, side: Binding<CardDraft.Side>, image: UIImage?, field: Field) -> some View {
        let clipping = side.wrappedValue.newImage ?? (side.wrappedValue.imageName == nil ? nil : image)
        return VStack(alignment: .leading, spacing: Space.x2) {
            Text(title)
                .eyebrowStyle(Color.textSecondary)
                .accessibilityAddTraits(.isHeader)
            if let clipping {
                HStack(alignment: .top, spacing: Space.x2) {
                    CardClippingView(image: clipping, showsTape: false)
                        .frame(maxHeight: 150)
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        side.wrappedValue.newImage = nil
                        side.wrappedValue.imageName = nil
                    } label: { Label("Remove Clipping", systemImage: "xmark") }
                        .buttonStyle(.barIcon)
                }
            }
            TextField(prompt, text: side.text, prompt: Text(clipping == nil ? prompt : "Add words, if you like").foregroundStyle(Color.textSecondary), axis: .vertical)
                .lineLimit(clipping == nil ? 2...6 : 1...4)
                .padding(.vertical, Space.x2)
                .focused($focus, equals: field)
                .accessibilityLabel(Text(title))
                .accessibilityIdentifier(field == .front ? "composer.front" : "composer.back")
                .owlLunaField(focused: focus == field) { focus = field }
        }
    }

    private func save() {
        guard draft.isComplete, !isSaving else { return }
        isSaving = true
        let draft = draft
        Task {
            defer { isSaving = false }
            do {
                let card = try await library.save(draft, in: notebook)
                onSave?(card)
                AccessibilityNotification.Announcement(String(localized: "Flashcard saved")).post()
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
