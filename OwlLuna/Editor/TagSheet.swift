import SwiftUI

extension NotebookDocument {
    /// One undo step for any change to a page's tags.
    func setTags(_ tags: [String], forPage pageID: UUID) {
        let tags = Tags.merged(tags)
        guard let index = index(of: pageID), pages[index].tags != tags else { return }
        updatePage(pageID, actionName: String(localized: "Tag Page")) { $0.tags = tags }
    }
}

/// The tags of one notebook or one page: add by typing, take off with a tap, or pick from the tags the library already has.
/// Nothing is changed until the sheet is done, so a visit is one change to undo.
struct TagSheet: View {
    /// What is being tagged: the notebook's title, or "Page 3".
    let subject: String
    let initial: [String]
    /// Tags the index may not have heard of yet, offered beside the library's.
    var known: [String] = []
    private let initialMixed: [String]
    private let onDone: ([String], [String]) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [String] = []
    @State private var mixed: [String] = []
    @State private var library: [String] = []
    @State private var draft = ""
    @State private var loaded = false
    @State private var finished = false
    @FocusState private var focused: Bool

    private var suggestions: [String] { library.filter { !Tags.contains(tags, $0) && !Tags.contains(mixed, $0) } }

    init(subject: String, initial: [String], known: [String] = [], onDone: @escaping ([String]) -> Void) {
        self.subject = subject
        self.initial = initial
        self.known = known
        initialMixed = []
        self.onDone = { tags, _ in onDone(tags) }
    }

    /// Over several notebooks: `initial` are on every one and `mixed` on only some. Done hands back the tags now on
    /// every one, and the mixed ones left where they were.
    init(subject: String, initial: [String], mixed: [String], onDone: @escaping (_ tags: [String], _ stillMixed: [String]) -> Void) {
        self.subject = subject
        self.initial = initial
        initialMixed = mixed
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x5) {
                    field
                    section(subject) {
                        if tags.isEmpty {
                            Text("No tags yet.").font(.subheadline).foregroundStyle(Color.textSecondary).frame(minHeight: 44)
                        } else {
                            FlowLayout(spacing: Space.x1) {
                                ForEach(tags, id: \.self) { tag in
                                    TagChipButton(name: tag, symbol: "xmark") { remove(tag) }
                                        .accessibilityHint(Text("Removes this tag"))
                                        .accessibilityIdentifier("tags.chip.\(tag)")
                                }
                            }
                        }
                    }
                    if !mixed.isEmpty {
                        section(String(localized: "On some of them")) {
                            FlowLayout(spacing: Space.x1) {
                                ForEach(mixed, id: \.self) { tag in
                                    TagChipButton(name: tag, isMixed: true, symbol: "plus") { add(tag) }
                                        .accessibilityValue(Text("On some notebooks"))
                                        .accessibilityHint(Text("Adds this tag to every notebook"))
                                        .accessibilityAction(named: Text("Remove from All")) { removeMixed(tag) }
                                        .accessibilityIdentifier("tags.mixed.\(tag)")
                                }
                            }
                        }
                    }
                    if !suggestions.isEmpty {
                        section(String(localized: "Other tags")) {
                            FlowLayout(spacing: Space.x1) {
                                ForEach(suggestions, id: \.self) { tag in
                                    TagChipButton(name: tag, symbol: "plus") { add(tag) }
                                        .accessibilityHint(Text("Adds this tag"))
                                        .accessibilityIdentifier("tags.suggestion.\(tag)")
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.x5)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.surface)
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .barGround(.surface)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        finish()
                        dismiss()
                    }
                    .buttonStyle(.owlLuna(.primary, inBar: true))
                    .accessibilityIdentifier("tags.done")
                }
                .boardBackground()
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            tags = Tags.merged(initial)
            mixed = Tags.merged(initialMixed).filter { !Tags.contains(tags, $0) }
            library = Tags.merged(store.tagCounts().map(\.name) + known)
        }
        .onDisappear(perform: finish)
    }

    private var field: some View {
        HStack(spacing: Space.x3) {
            TextField("Add a tag", text: $draft, prompt: Text("Add a tag").foregroundStyle(Color.textSecondary))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit {
                    addDraft()
                    focused = true
                }
                .accessibilityLabel(Text("Add a tag"))
                .accessibilityIdentifier("tags.field")
                .padding(.vertical, Space.x2)
                .owlLunaField(focused: focused) { focused = true }
            Button("Add", action: addDraft)
                .buttonStyle(.owlLuna)
                .disabled(Tags.normalized(draft) == nil)
                .accessibilityIdentifier("tags.add")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(title).metaStyle(.footnote).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// A name the library already spells one way keeps that spelling.
    private func add(_ name: String) {
        guard let name = Tags.normalized(name), !Tags.contains(tags, name) else { return }
        let spelled = library.first { Tags.key($0) == Tags.key(name) } ?? name
        tags = Tags.merged(tags + [spelled])
        mixed.removeAll { Tags.key($0) == Tags.key(name) }
        AccessibilityNotification.Announcement(String(localized: "Added \(spelled)")).post()
    }

    private func addDraft() {
        add(draft)
        draft = ""
    }

    private func remove(_ name: String) {
        tags.removeAll { Tags.key($0) == Tags.key(name) }
        AccessibilityNotification.Announcement(String(localized: "Removed \(name)")).post()
    }

    private func removeMixed(_ name: String) {
        mixed.removeAll { Tags.key($0) == Tags.key(name) }
        AccessibilityNotification.Announcement(String(localized: "Removed \(name)")).post()
    }

    /// Done, or the sheet pulled down: what is still in the field counts, and the change is handed over once.
    private func finish() {
        guard !finished else { return }
        finished = true
        addDraft()
        onDone(tags, mixed)
    }
}

/// What the editor's tag sheet is for.
enum TagTarget: Identifiable, Hashable {
    case notebook
    case page(UUID)

    var id: String {
        switch self {
        case .notebook: "notebook"
        case .page(let id): id.uuidString
        }
    }
}

/// The tag sheet for an open notebook or one of its pages. A page's tags are an undo step; the notebook's go through the library.
struct EditorTagSheet: View {
    let document: NotebookDocument
    let target: TagTarget
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let known = document.manifest.library.tags + document.manifest.pageTags
        switch target {
        case .notebook:
            TagSheet(subject: document.title, initial: document.manifest.library.tags, known: known) { tags in
                if let record = store.record(document.id) {
                    store.setTags(tags, for: [record])
                } else {
                    document.updateLibraryState { $0.tags = tags }
                }
            }
        case .page(let id):
            let index = document.index(of: id)
            TagSheet(subject: String(localized: "Page \((index ?? 0) + 1)"), initial: index.map { document.pages[$0].tags } ?? [], known: known) { tags in
                document.setTags(tags, forPage: id)
            }
        }
    }
}

/// The Outline tab's list of pages that carry tags.
struct TaggedPagesSection: View {
    let pages: [(index: Int, page: NotebookPage)]
    let open: (Int) -> Void

    var body: some View {
        Section {
            ForEach(pages, id: \.page.id) { item in
                let tags = item.page.tags
                Button { open(item.index) } label: {
                    HStack(spacing: Space.x3) {
                        Image(systemName: "tag").foregroundStyle(Color.textSecondary).accessibilityHidden(true)
                        Text(Tags.line(tags)).foregroundStyle(Color.ink)
                        Spacer(minLength: Space.x3)
                        Text(item.index + 1, format: .number).monospacedDigit().foregroundStyle(Color.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("\(tags.formatted(.list(type: .and))), page \(item.index + 1)"))
                .accessibilityHint(Text("Opens this page"))
            }
        } header: {
            Text("Tagged Pages")
        }
    }
}
