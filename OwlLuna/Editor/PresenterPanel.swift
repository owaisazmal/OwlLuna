import SwiftUI

extension NotebookPage {
    /// What the presenter means to say on this page. Never drawn on the page or exported; shown beside it while presenting.
    var notes: String {
        get { extra["notes"]?.stringValue ?? "" }
        set { extra["notes"] = newValue.isEmpty ? nil : .string(newValue) }
    }
}

extension NotebookDocument {
    func setNotes(_ notes: String, forPage pageID: UUID) {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = index(of: pageID), pages[index].notes != trimmed else { return }
        updatePage(pageID, actionName: String(localized: "Presenter Notes")) { $0.notes = trimmed }
    }
}

/// Beside the page while presenting: the time, the page that comes next, and the notes for this one.
/// The audience's screen only ever shows the page.
struct PresenterPanel: View {
    let session: EditorSession
    let since: Date
    /// The side of the editor it stands on; its rule is on the page's side.
    var side = HorizontalEdge.trailing
    let editNotes: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var document: NotebookDocument { session.document }

    private var next: NotebookPage? {
        document.pages.indices.contains(session.currentPage + 1) ? document.pages[session.currentPage + 1] : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x5) {
                clock
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text("Next").metaStyle(.footnote).accessibilityAddTraits(.isHeader)
                    nextPage
                }
                VStack(alignment: .leading, spacing: Space.x2) {
                    HStack {
                        Text("Notes").metaStyle(.footnote).accessibilityAddTraits(.isHeader)
                        Spacer()
                        if !document.isReadOnly {
                            Button(action: editNotes) { Label("Edit Notes", systemImage: "square.and.pencil") }
                                .buttonStyle(.barIcon)
                                .accessibilityIdentifier("presenter.notes.edit")
                        }
                    }
                    notes
                }
            }
            .padding(Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.surface)
        .overlay(alignment: Alignment(horizontal: side.other.alignment, vertical: .center)) {
            Rectangle().fill(Color.hairline).frame(width: 1).ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Presenter view"))
        .accessibilityIdentifier("presenter.panel")
    }

    private var clock: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(since)))
            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x1))
                                                 : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Space.x3))) {
                Text(RecordingStop.clock(TimeInterval(elapsed)))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.ink)
                    .fixedSize()
                    .accessibilityLabel(Text("Presenting for \(Duration.seconds(elapsed).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))"))
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var nextPage: some View {
        if let next {
            Button { session.step(1) } label: {
                PresenterThumbnail(document: document, page: next)
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.plain)
            .hoverEffect(.lift)
            .accessibilityLabel(Text("Next page, page \(session.currentPage + 2)"))
            .accessibilityHint(Text("Shows it"))
            .accessibilityIdentifier("presenter.next")
        } else {
            Text("This is the last page.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .accessibilityIdentifier("presenter.last")
        }
    }

    @ViewBuilder
    private var notes: some View {
        let text = session.shownPage?.notes ?? ""
        if text.isEmpty {
            Text("No notes for this page.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .accessibilityIdentifier("presenter.notes.empty")
        } else {
            Text(text)
                .font(.title3)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("presenter.notes")
        }
    }
}

private struct PresenterThumbnail: View {
    let document: NotebookDocument
    let page: NotebookPage
    @State private var image: UIImage?
    @AppStorage(SettingsKey.evenHighlights) private var evenHighlights = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Rectangle().fill(Color(uiColor: PageRenderer.paperColor(page.effectivePaperColor)))
            }
        }
        .aspectRatio(page.shownSize.width / max(page.shownSize.height, 1), contentMode: .fit)
        .overlay { Rectangle().strokeBorder(Color.hairline, lineWidth: 1) }
        .task(id: "\(page.id)-\(page.inkHash ?? "")-\(page.appearanceKey)-\(evenHighlights)") { image = await document.thumbnail(for: page) }
    }
}

/// Writes the notes for one page.
struct PresenterNotesSheet: View {
    let document: NotebookDocument
    let pageID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var number: Int { (document.index(of: pageID) ?? 0) + 1 }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .foregroundStyle(Color.ink)
                .scrollContentBackground(.hidden)
                .padding(Space.x2)
                .focused($focused)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What you want to say on this page. Only you see it, beside the page, while you present.")
                            .foregroundStyle(Color.textSecondary)
                            .padding(Space.x2)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .well(in: RoundedRectangle.plate, focused: focused)
                .padding(Space.x4)
                .background(Color.surface)
                .accessibilityLabel(Text("Notes for page \(number)"))
                .accessibilityIdentifier("presenter.notes.editor")
                .navigationTitle("Notes for Page \(number)")
                .barGround(.surface)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    CancelToolbarItem { dismiss() }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            document.setNotes(text, forPage: pageID)
                            dismiss()
                        }
                        .buttonStyle(.owlLuna(.primary, inBar: true))
                        .accessibilityIdentifier("presenter.notes.done")
                    }
                    .boardBackground()
                }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.surface)
        .onAppear {
            text = document.index(of: pageID).map { document.pages[$0].notes } ?? ""
            focused = true
        }
    }
}
