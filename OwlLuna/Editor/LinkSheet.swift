import SwiftUI
import SwiftData

/// Picks what a new link opens: a page of this notebook, another notebook or one of its pages, or a web address.
struct LinkSheet: View {
    let session: EditorSession
    let pick: (PageLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.pages

    enum Tab: Hashable { case pages, notebooks, web }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .pages: LinkPagePicker(session: session, choose: choose)
                case .notebooks: LinkNotebookPicker(current: session.document.id, choose: choose)
                case .web: LinkAddressForm(choose: choose)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                OwlLunaSegmentedPicker("Link to", selection: $tab, options: [Tab.pages, .notebooks, .web]) { tab in
                    switch tab {
                    case .pages: Text("This Notebook")
                    case .notebooks: Text("Another Notebook")
                    case .web: Text("Web")
                    }
                }
                .accessibilityIdentifier("link.tabs")
                .padding(.horizontal, Space.x5)
                .padding(.top, Space.x2)
                .padding(.bottom, Space.x1)
                .background(Color.desk)
            }
            .background(Color.desk)
            .navigationTitle("Add a Link")
            .navigationBarTitleDisplayMode(.inline)
            .barGround(Color.desk)
            .toolbar {
                CancelToolbarItem { dismiss() }
            }
        }
    }

    private func choose(_ link: PageLink) {
        pick(link)
        dismiss()
    }
}

private struct LinkPagePicker: View {
    let session: EditorSession
    let choose: (PageLink) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var document: NotebookDocument { session.document }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x4) {
                    Text("The link sits on page \(session.currentPage + 1). Tap it there to open the page you choose.")
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                    if dynamicTypeSize.isAccessibilitySize {
                        LazyVStack(spacing: Space.x3) { cells }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: Space.x5, alignment: .top)], spacing: Space.x6) { cells }
                    }
                }
                .padding(Space.x5)
            }
            .onAppear { if let page = session.shownPage { proxy.scrollTo(page.id, anchor: .center) } }
        }
        .accessibilityIdentifier("link.picker")
    }

    private var cells: some View {
        ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
            let isCurrent = index == session.currentPage
            Button { choose(PageLink(target: page.id)) } label: {
                PageThumbnailCell(document: document, page: page, index: index, isCurrent: isCurrent)
            }
            .buttonStyle(PageCellButtonStyle())
            .hoverEffect(.lift, isEnabled: !isCurrent)
            .disabled(isCurrent)
            .accessibilityLabel(Text(isCurrent ? "Page \(index + 1), this page" : "Page \(index + 1)"))
            .accessibilityValue(Text(page.bookmark.flatMap { $0.isEmpty ? nil : $0 } ?? ""))
            .accessibilityHint(isCurrent ? Text(verbatim: "") : Text("Links to this page"))
            .accessibilityIdentifier("link.page.\(index + 1)")
            .id(page.id)
        }
    }
}

/// Pressed like a plain button, but the page the link sits on isn't dimmed while it can't be chosen, so its number stays readable.
private struct PageCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private struct LinkNotebookPicker: View {
    let current: UUID
    let choose: (PageLink) -> Void
    @Query(filter: #Predicate<NotebookRecord> { $0.deletedAt == nil }, sort: \NotebookRecord.title) private var records: [NotebookRecord]

    var body: some View {
        let others = records.filter { $0.id != current }
        Ledger {
            Section {
                ForEach(others) { record in
                    NavigationLink {
                        LinkNotebookPages(record: record, choose: choose)
                    } label: {
                        HStack(spacing: Space.x4) {
                            RecordCover(record: record, width: CoverWidth.row, showsShadow: false).frame(width: 40)
                            VStack(alignment: .leading, spacing: Space.x1) {
                                Text(record.title).font(.headline).foregroundStyle(Color.ink)
                                Text("\(record.pageCount) pages")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.textSecondary)
                            }
                            Spacer(minLength: Space.x3)
                            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(Color.textSecondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityIdentifier("link.notebook.\(record.title)")
                }
            } footer: {
                Text("Tapping the link saves this notebook, puts it away and opens the other one.")
            }
        }
        .overlay {
            if others.isEmpty {
                EmptyPlate("No Other Notebooks", systemImage: "books.vertical",
                           message: Text("Once you have another notebook, you can link to it from here."))
            }
        }
    }
}

/// The other notebook's pages, read from its files or from its open editor in another window.
private struct LinkNotebookPages: View {
    let record: NotebookRecord
    let choose: (PageLink) -> Void
    @Environment(LibraryStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pages: [NotebookPage] = []
    @State private var loaded = false

    private var package: NotebookPackage { NotebookPackage(root: store.root, id: record.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x4) {
                Button { choose(link(to: nil)) } label: {
                    Label("The Whole Notebook", systemImage: "book.closed")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.owlLuna(.primary))
                .accessibilityHint(Text("The link opens the notebook where you left it"))
                .accessibilityIdentifier("link.notebook.whole")
                if record.isLocked {
                    Text("This notebook is locked, so its pages aren't shown here.").font(.footnote).foregroundStyle(Color.textSecondary)
                } else {
                    Text("Or choose the page it opens at.").font(.footnote).foregroundStyle(Color.textSecondary)
                    if dynamicTypeSize.isAccessibilitySize {
                        LazyVStack(spacing: Space.x3) { cells }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: Space.x5, alignment: .top)], spacing: Space.x6) { cells }
                    }
                    if !loaded { ProgressView().frame(maxWidth: .infinity) }
                }
            }
            .padding(Space.x5)
        }
        .background(Color.desk)
        .navigationTitle(record.title)
        .barGround(.desk)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: record.id) {
            guard !record.isLocked else { return }
            if let open = DocumentRegistry.shared.document(for: record.id) {
                pages = open.pages
            } else {
                pages = (try? await package.readManifest().manifest.pages) ?? []
            }
            loaded = true
        }
    }

    private func link(to page: UUID?) -> PageLink {
        PageLink(.notebook(record.id, page: page, name: record.title))
    }

    private var cells: some View {
        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
            Button { choose(link(to: page.id)) } label: {
                VStack(spacing: Space.x2) {
                    SavedPageThumbnail(package: package, page: page)
                    Text(index + 1, format: .number).font(.caption.monospacedDigit()).foregroundStyle(Color.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .hoverEffect(.lift)
            .accessibilityLabel(Text("Page \(index + 1)"))
            .accessibilityValue(Text(page.bookmark.flatMap { $0.isEmpty ? nil : $0 } ?? ""))
            .accessibilityHint(Text("The link opens the notebook at this page"))
            .accessibilityIdentifier("link.notebook.page.\(index + 1)")
        }
    }
}

/// A page of a notebook that isn't open, as last saved.
struct SavedPageThumbnail: View {
    let package: NotebookPackage
    let page: NotebookPage
    @State private var image: UIImage?
    @PaperNight private var night

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Rectangle().fill(Color(uiColor: page.paperShown(night: night)))
            }
        }
        .aspectRatio(page.size.width / max(page.size.height, 1), contentMode: .fit)
        .overlay { Rectangle().strokeBorder(Color.hairline, lineWidth: 1) }
        .task(id: "\(page.id)-\(page.thumbnailKey)-\(night)") { image = await PageThumbnailer.thumbnail(package: package, page: page, night: night) }
    }
}

private struct LinkAddressForm: View {
    let choose: (PageLink) -> Void
    @State private var address = ""
    @State private var label = ""
    @FocusState private var field: Field?

    private enum Field { case address, name }

    private var url: URL? { WebAddress.url(from: address) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x5) {
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text("Address").metaStyle(.footnote).accessibilityHidden(true)
                    TextField("Address", text: $address, prompt: Text("example.com").foregroundStyle(Color.textSecondary))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($field, equals: .address)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .accessibilityLabel(Text("Address"))
                        .accessibilityIdentifier("link.web.address")
                        .padding(.vertical, Space.x2)
                        .owlLunaField(focused: field == .address) { field = .address }
                }
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text("Name").metaStyle(.footnote).accessibilityHidden(true)
                    TextField("Name", text: $label, prompt: Text("Optional").foregroundStyle(Color.textSecondary))
                        .focused($field, equals: .name)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .accessibilityLabel(Text("Name"))
                        .accessibilityIdentifier("link.web.name")
                        .padding(.vertical, Space.x2)
                        .owlLunaField(focused: field == .name) { field = .name }
                    Text("Tapping the link opens the address in your browser. Without a name, the link shows the address.")
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Add Link", action: add)
                    .buttonStyle(.owlLuna(.primary))
                    .disabled(url == nil)
                    .accessibilityIdentifier("link.web.add")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(Space.x5)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { field = .address }
    }

    private func add() {
        guard let url else { return }
        choose(PageLink(.web(url), label: label.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
