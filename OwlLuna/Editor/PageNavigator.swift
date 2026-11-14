import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

extension UTType {
    static let pageReference = UTType(exportedAs: "com.owais.owlluna.page-reference")
}

struct PageReference: Codable, Transferable, Hashable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pageReference)
    }
}

struct PageNavigator: View {
    let session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingDelete: UUID?
    @State private var goToPage = ""
    @State private var dragging: UUID?
    @State private var dropTarget: UUID?
    @FocusState private var goToFocused: Bool
    @State private var tab = Tab.pages
    @State private var barRoom = CGFloat.infinity
    @State private var tabsWidth: CGFloat = 0
    @State private var doneWidth: CGFloat = 0
    @State private var tagging: TagTarget?

    enum Tab { case pages, outline }

    private var document: NotebookDocument { session.document }
    private var currentPage: Int { session.currentPage }
    /// Larger text, longer words and narrow windows leave no room for the field beside the tabs, so there it sits under the bar.
    private var goToFitsBar: Bool { dynamicTypeSize <= .large && barRoom >= goToWidth + tabsWidth + doneWidth + 92 }
    private let goToWidth: CGFloat = 176

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .pages: grid
                case .outline:
                    NotebookOutline(session: session) { index in
                        dismiss()
                        session.go(to: index)
                    }
                }
            }
            .background(Color.desk)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barRoom = $0 }
            .sensoryFeedback(.alignment, trigger: dropTarget) { _, target in target != nil }
            .navigationTitle(Text(document.pageCountText))
            .navigationBarTitleDisplayMode(.inline)
            .barGround(Color.desk)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: Space.x2) {
                        if tab == .pages {
                            Button { session.addPage(after: document.pages.count - 1) } label: {
                                Label("Add Page", systemImage: "plus")
                            }
                            .buttonStyle(.plateIcon)
                            .disabled(document.isReadOnly)
                        }
                        Button("Done") { dismiss() }
                            .buttonStyle(.owlLuna(.primary, inBar: true))
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { doneWidth = $0 }
                    }
                }
                .boardBackground()
                ToolbarItem(placement: .principal) {
                    OwlLunaSegmentedPicker("Show", selection: $tab, options: [Tab.pages, .outline], inBar: true) { tab in
                        switch tab {
                        case .pages: Text("Pages")
                        case .outline: Text("Outline")
                        }
                    }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
                    .accessibilityIdentifier("navigator.tabs")
                }
                .boardBackground()
                if tab == .pages, goToFitsBar {
                    ToolbarItem(placement: .topBarLeading) {
                        OwlLunaSearchField(prompt: "Go to page", text: $goToPage, systemImage: "number", isSearch: false, clears: false, identifier: "navigator.goto",
                                          focus: $goToFocused) {
                            if pageNumber != nil {
                                Button(action: go) {
                                    Image(systemName: "arrow.right")
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(Color.onPrimaryCloth)
                                        .frame(width: 28, height: 28)
                                        .background(Color.primaryCloth, in: RoundedRectangle.thumb)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("Go"))
                                .accessibilityIdentifier("navigator.go")
                            }
                        }
                        .keyboardType(.numbersAndPunctuation)
                        .onSubmit(go)
                        .frame(width: goToWidth)
                    }
                    .boardBackground()
                }
            }
            .notice("Delete this page?", isPresented: Binding(isPresent: $pendingDelete),
                    message: Text("You can undo this.")) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Page", role: .destructive) { if let pendingDelete { document.removePages([pendingDelete]) } }
            }
            .sheet(item: $tagging) { target in
                EditorTagSheet(document: document, target: target)
                    .presentationCornerRadius(Radius.sheet)
                    .appModels()
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Color.surface)
            }
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if dynamicTypeSize.isAccessibilitySize {
                    LazyVStack(spacing: Space.x3) { cells }
                        .padding(Space.x4)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: Space.x5, alignment: .top)],
                              spacing: Space.x6) { cells }
                        .padding(Space.x5)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { if !goToFitsBar { goToRow } }
            .onAppear { if let page = session.shownPage { proxy.scrollTo(page.id, anchor: .center) } }
        }
    }

    private var goToRow: some View {
        HStack(spacing: Space.x3) {
            TextField("Go to page", text: $goToPage, prompt: Text("Go to page").foregroundStyle(Color.textSecondary))
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.go)
                .focused($goToFocused)
                .onSubmit(go)
                .accessibilityLabel(Text("Go to page"))
                .accessibilityIdentifier("navigator.goto")
                .padding(.vertical, Space.x2)
                .owlLunaField(focused: goToFocused) { goToFocused = true }
            Button("Go", action: go)
                .accessibilityIdentifier("navigator.go")
                .buttonStyle(.owlLuna(.primary))
                .disabled(pageNumber == nil)
        }
        .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? Space.x4 : Space.x5)
        .padding(.vertical, Space.x2)
        .background(Color.desk)
    }

    private var cells: some View {
        ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
            cell(page, at: index)
        }
    }

    private func cell(_ page: NotebookPage, at index: Int) -> some View {
        let isCurrent = index == currentPage
        return Button {
            dismiss()
            session.go(to: index)
        } label: {
            PageThumbnailCell(document: document, page: page, index: index, isCurrent: isCurrent)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .overlay { if dropTarget == page.id { insertionBar(after: dropsAfter(index)) } }
        .heldMenu(Text("Page \(index + 1)"), when: !document.isReadOnly, draggable: true) { menu(for: page, at: index) }
        .onDrag {
            dragging = page.id
            let provider = NSItemProvider()
            provider.register(PageReference(id: page.id))
            return provider
        }
        .dropDestination(for: PageReference.self) { items, _ in
            dropTarget = nil
            guard !document.isReadOnly, let item = items.first, let destination = document.index(of: page.id) else { return false }
            return move(item.id, to: destination)
        } isTargeted: { targeted in
            if targeted { dropTarget = page.id } else if dropTarget == page.id { dropTarget = nil }
        }
        .accessibilityLabel(isCurrent ? Text("Page \(index + 1) of \(document.pages.count), current") : Text("Page \(index + 1) of \(document.pages.count)"))
        .accessibilityValue(Text([page.isBoard ? String(localized: "Whiteboard") : nil, page.bookmark == nil ? nil : String(localized: "Bookmarked"),
                                  page.tags.isEmpty ? nil : String(localized: "tagged \(page.tags.formatted(.list(type: .and)))")]
            .compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(Text("Opens this page"))
        .accessibilityActions {
            if !document.isReadOnly, index > 0 { Button("Move earlier") { move(page.id, to: index - 1) } }
            if !document.isReadOnly, index < document.pages.count - 1 { Button("Move later") { move(page.id, to: index + 1) } }
        }
        .id(page.id)
    }

    /// A page dropped on a later page takes its place and lands after it; on an earlier one, before it.
    private func dropsAfter(_ index: Int) -> Bool {
        guard let dragging, let from = document.index(of: dragging) else { return false }
        return from < index
    }

    /// Sits in the gap on the side the page will land.
    private func insertionBar(after: Bool) -> some View {
        let vertical = !dynamicTypeSize.isAccessibilitySize
        let shift = ((vertical ? Space.x5 : Space.x3) / 2 + 1.5) * (after ? 1 : -1)
        let alignment: Alignment = vertical ? (after ? .trailing : .leading) : (after ? .bottom : .top)
        return InsertionRule(vertical: vertical)
            .stroke(Color.mustard, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 5]))
            .frame(width: vertical ? 3 : nil, height: vertical ? nil : 3)
            .offset(x: vertical ? shift : 0, y: vertical ? 0 : shift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @discardableResult
    private func move(_ pageID: UUID, to destination: Int) -> Bool {
        guard !document.isReadOnly, let from = document.index(of: pageID), from != destination,
              document.pages.indices.contains(destination) else { return false }
        withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) {
            document.movePage(from: from, to: destination)
        }
        AccessibilityNotification.Announcement(String(localized: "Moved to page \(destination + 1)")).post()
        return true
    }

    private var pageNumber: Int? {
        guard let number = Int(goToPage.trimmingCharacters(in: .whitespaces)), (1...max(document.pages.count, 1)).contains(number) else { return nil }
        return number
    }

    private func go() {
        guard let number = pageNumber else { return }
        dismiss()
        session.go(to: number - 1)
    }

    @ViewBuilder
    private func menu(for page: NotebookPage, at index: Int) -> some View {
        if !document.isReadOnly {
            Button { session.addPage(after: index) } label: {
                Label("Insert Page After", systemImage: "doc.badge.plus")
            }
            Button { Task { await session.duplicatePage(at: index) } } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            if page.bookmark == nil {
                Button { document.setBookmark("", forPage: page.id) } label: { Label("Bookmark", systemImage: "bookmark") }
            } else {
                Button { document.setBookmark(nil, forPage: page.id) } label: { Label("Remove Bookmark", systemImage: "bookmark.slash") }
            }
            Button { tagging = .page(page.id) } label: { Label("Tags…", systemImage: "tag") }
            if index > 0 {
                Button { move(page.id, to: index - 1) } label: { Label("Move Earlier", systemImage: "arrow.backward") }
            }
            if index < document.pages.count - 1 {
                Button { move(page.id, to: index + 1) } label: { Label("Move Later", systemImage: "arrow.forward") }
            }
            MenuBreak()
            Button(role: .destructive) { pendingDelete = page.id } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

/// The dashed rule marking where a dragged page, or a dragged tab, will land.
struct InsertionRule: Shape {
    let vertical: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: vertical ? CGPoint(x: rect.midX, y: rect.minY) : CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: vertical ? CGPoint(x: rect.midX, y: rect.maxY) : CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// A grid tile, or a row at accessibility sizes; the current page is stitched and wears the notebook's ribbon.
struct PageThumbnailCell: View {
    let document: NotebookDocument
    let page: NotebookPage
    let index: Int
    let isCurrent: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @PaperNight private var night
    @State private var image: UIImage?
    @State private var ribbonDropped = false

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize { row } else { tile }
        }
        .contentShape(Rectangle())
        .task(id: "\(page.id)-\(page.inkHash ?? "")-\(page.appearanceKey)-\(night)") {
            image = await document.thumbnail(for: page, night: night)
        }
    }

    private var tile: some View {
        VStack(spacing: Space.x2) {
            thumbnail
            VStack(spacing: 0) {
                Text(index + 1, format: .number)
                    .font(.caption.weight(isCurrent ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.ink : Color.textSecondary)
                if isCurrent { Text("Current").metaStyle(.caption) }
                if page.isBoard { Text("Whiteboard").metaStyle(.caption) }
            }
        }
    }

    private var row: some View {
        HStack(spacing: Space.x4) {
            thumbnail.frame(width: 80)
            VStack(alignment: .leading, spacing: Space.x1) {
                Text("Page \(index + 1) of \(document.pages.count)")
                    .font(.headline.weight(isCurrent ? .bold : .semibold))
                    .foregroundStyle(Color.ink)
                if isCurrent { Text("Current").metaStyle(.subheadline) }
                Text(paperName).font(.subheadline).foregroundStyle(Color.textSecondary)
                if !page.tags.isEmpty { Text(Tags.line(page.tags)).font(.subheadline).foregroundStyle(Color.textSecondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.x3)
        .background(Color.surface, in: RoundedRectangle.plate)
    }

    private var thumbnail: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Rectangle().fill(Color(uiColor: page.paperShown(night: night)))
            }
        }
        .aspectRatio(page.shownSize.width / max(page.shownSize.height, 1), contentMode: .fit)
        .overlay { Rectangle().strokeBorder(Color.hairline, lineWidth: 1) }
        .overlay { if isCurrent { StitchedSelection() } }
        .overlay(alignment: .topTrailing) { if isCurrent { ribbon } }
        .overlay(alignment: .topLeading) { if page.bookmark != nil { bookmarkFlag } }
        .overlay(alignment: .bottomLeading) { if !page.tags.isEmpty { TagMark().padding(6) } }
        .padding(4)
    }

    private var ribbon: some View {
        let cloth = document.manifest.cover.cloth
        return RibbonShape()
            .fill(cloth.color)
            .overlay { RibbonShape().stroke(Color.labelCream, lineWidth: contrast == .increased ? 1.5 : 0) }
            .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
            .frame(width: 12, height: 30)
            .padding(.trailing, 10)
            .offset(y: ribbonDropped || reduceMotion ? -4 : -22)
            .opacity(ribbonDropped || reduceMotion ? 1 : 0)
            .onAppear { withAnimation(Motion.ribbon.delay(0.2)) { ribbonDropped = true } }
    }

    private var bookmarkFlag: some View {
        RibbonShape()
            .fill(Color.mustard)
            .overlay { RibbonShape().stroke(Color.onMustard.opacity(contrast == .increased ? 0.8 : 0.25), lineWidth: 1) }
            .frame(width: 12, height: 24)
            .padding(.leading, 10)
            .offset(y: -4)
            .accessibilityHidden(true)
    }

    private var paperName: String {
        switch page.background {
        case .template where page.isBoard: String(localized: "Whiteboard, \(page.paperColor.displayName)")
        case .template: "\(page.template?.displayName ?? PaperTemplate.blank.displayName), \(page.paperColor.displayName)"
        case .pdf: String(localized: "PDF page")
        case .image: String(localized: "Photo")
        case .unknown: String(localized: "Page")
        }
    }
}

extension NotebookDocument {
    /// "1 page", "12 pages".
    var pageCountText: String {
        String(localized: "\(pages.count) pages")
    }

    /// Thumbnail reflecting unsaved ink when the page is in memory, otherwise the cached saved one.
    func thumbnail(for page: NotebookPage, night: Bool = false) async -> UIImage? {
        if hasUnsavedInk(page.id), let ink = loadedInk(page.id) {
            let assets = package.assetsDirectory
            return await Task.detached(priority: .utility) { PageThumbnailer.render(page: page, ink: ink, assets: assets, night: night) }.value
        }
        return await PageThumbnailer.thumbnail(package: package, page: page, night: night)
    }
}
