import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct Shelf: Identifiable {
    let id: String
    let title: String
    let records: [NotebookRecord]
    var cloth: ClothColor?
}

struct ShelfView: View {
    let scope: LibraryScope
    let zoomNamespace: Namespace.ID
    let onOpen: (NotebookRecord) -> Void
    let onOpenPage: (NotebookRecord, UUID) -> Void
    let onOpenZoomed: (NotebookRecord, UUID?, String) -> Void
    let onCreate: () -> Void
    let onQuickNote: () -> Void
    let onWhiteboard: () -> Void
    let isCovered: Bool

    @Environment(LibraryStore.self) private var store
    @Environment(FlashcardLibrary.self) private var flashcards
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.undoManager) private var undoManager
    @Environment(LibraryChangeCenter.self) private var changes
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(ShelfRequests.self) private var requests: ShelfRequests?
    @Environment(\.verticalBar) private var verticalBar
    @Query private var records: [NotebookRecord]
    @Query(sort: \FolderRecord.sortIndex) private var folders: [FolderRecord]
    @AppStorage(SettingsKey.librarySort) private var sort: LibrarySortOrder = .opened
    @AppStorage(SettingsKey.librarySortReversed) private var sortReversed = false
    @AppStorage(SettingsKey.libraryLayout) private var layout: LibraryLayout = .shelf
    @AppStorage("libraryGrouping") private var grouping: LibraryGrouping = .recency
    @AppStorage(SettingsKey.dailyJournalID) private var journalID = ""
    @AppStorage(SettingsKey.trashLength) private var trashLength: TrashLength = .initial
    @State private var searchText = ""
    @State private var matches: Set<UUID>?
    @State private var pageHits = PageHits()
    @State private var hitsQuery = ""
    @State private var tagPages: [UUID: [PageHit]] = [:]
    @State private var tagging: NotebookRecord?
    @State private var taggingSelection: SelectionTags?
    @State private var searchPending = false
    @State private var export: ExportJob?
    @State private var editingCover: NotebookRecord?
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var importingPDF = false
    @State private var pdfImport: PDFImportRun?
    @State private var scanning = false
    @State private var renaming: NotebookRecord?
    @State private var renameText = ""
    @State private var confirmingEmptyTrash = false
    @State private var errorMessage: String?
    @State private var shelfWidth: CGFloat?
    @State private var listWidth: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    @State private var showsBarTitle = false
    @FocusState private var searchFocused: Bool
    @State private var barRoom = CGFloat.infinity
    @State private var actionsWidth: CGFloat = 0

    private var folder: FolderRecord? { scope.folder(in: folders) }

    private var title: String {
        switch scope {
        case .all: String(localized: "All notebooks")
        case .favorites: String(localized: "Favourites")
        case .trash: String(localized: "Recently deleted")
        case .folder: folder?.name ?? String(localized: "Folder")
        case .tag(let name): name
        case .smart(let id): store.smartShelves.first { $0.id == id }?.name ?? String(localized: "Smart Shelf")
        }
    }

    /// What a tag shelf or a smart shelf looks for. A smart shelf that has been deleted looks for nothing.
    private var rule: TagRule? {
        switch scope {
        case .tag(let name): TagRule(tags: [name])
        case .smart(let id): store.smartShelves.first { $0.id == id }?.rule ?? TagRule(tags: [])
        case .all, .favorites, .trash, .folder: nil
        }
    }

    private var tree: FolderTree { FolderTree(folders: folders) }

    private var filter: ShelfFilter { ShelfFilter(scope: scope, tree: tree, rule: rule, matches: matches, sort: sort, reversed: sortReversed) }

    private var visible: [NotebookRecord] { filter.shown(records) }

    /// Matches titles and handwriting on a background context, a moment after typing stops, so neither the
    /// keystroke nor a library full of PDF text ever scans on the main thread.
    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespaces), terms = SearchQuery(query).terms
        guard !terms.isEmpty else {
            matches = nil
            pageHits = PageHits()
            searchPending = false
            return
        }
        if query != hitsQuery { pageHits = PageHits() }
        searchPending = true
        defer { if !Task.isCancelled { searchPending = false } }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let container = context.container
        let found = await Task.detached(priority: .userInitiated) { () -> Set<UUID> in
            LibraryIndex.notebookIDs(matching: query, in: ModelContext(container))
        }.value
        guard !Task.isCancelled else { return }
        // What is written in a locked notebook isn't searched: only its title and its own tags can match.
        let locked = records.filter(\.isLocked)
        let hidden = Set(locked.filter { record in
            !terms.allSatisfy { term in
                record.title.localizedStandardContains(term) || record.tags.contains { $0.localizedStandardContains(Tags.normalized(term) ?? term) }
            }
        }.map(\.id))
        matches = found.subtracting(hidden)
        guard scope != .trash else { pageHits = PageHits(); return }
        let closed = Set(locked.map(\.id))
        let ordered = visible.map(\.id).filter { found.contains($0) && !closed.contains($0) }
        let hits = await PageSearch.hits(for: query, in: ordered, root: store.root)
        guard !Task.isCancelled else { return }
        withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) { pageHits = hits }
        hitsQuery = query
    }

    /// The tagged pages under a tag shelf. Manifests are read off the main thread, an open notebook's pages come from
    /// its document, and a locked notebook's pages are never listed.
    private func loadTagPages() async {
        guard let rule, !rule.tags.isEmpty else {
            if !tagPages.isEmpty { tagPages = [:] }
            return
        }
        let sources = records.filter { record in !record.isTrashed && !record.isLocked && rule.tags.contains { Tags.contains(record.pageTags, $0) } }
            .sorted(by: sort, reversed: sortReversed)
            .map { TagPages.Source(id: $0.id, tags: $0.tags, pages: DocumentRegistry.shared.document(for: $0.id)?.pages) }
        let hits = await TagPages.hits(for: rule, in: sources, root: store.root)
        guard !Task.isCancelled, hits != tagPages else { return }
        withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) { tagPages = hits }
    }

    /// Tagged pages show under their notebooks, but not while searching.
    private var showsTagPages: Bool { rule != nil && searchText.isEmpty && !tagPages.isEmpty }

    private var showsPageHits: Bool { !searchText.isEmpty && !pageHits.pages.isEmpty && scope != .trash }

    private var tagPagesKey: String {
        "\(scope)|\(store.indexVersion)|" + (rule.map { "\($0.match.rawValue)|\(Tags.joined($0.tags))" } ?? "")
    }

    var body: some View {
        let visible = visible
        Group {
            if layout == .list {
                list(visible)
            } else if dynamicTypeSize.isAccessibilitySize {
                ledger(visible)
            } else {
                shelves(visible)
            }
        }
        .background(Color.paper)
        .overlay { if visible.isEmpty, !showsTagPages, !searchPending { emptyState } }
        .safeAreaInset(edge: .top, spacing: 0) {
            if verticalBar != nil {
                HStack(spacing: Space.x2) {
                    searchField
                    railActions(visible)
                }
                .padding(.horizontal, Space.x4)
                .padding(.vertical, Space.x2)
                .background(Color.paper)
            } else if !searchInBar {
                searchField
                    .padding(.horizontal, Space.x8)
                    .padding(.bottom, Space.x2)
                    .background(Color.paper)
            }
        }
        .overlay(alignment: .top) { if let sync = app?.sync, sync.isEnabled { SyncThread(sync: sync) } }
        .onGeometryChange(for: CGFloat.self) { proxy in
            let frame = proxy.frame(in: .global)
            return frame.width - (frame.minX > 1 ? 0 : 130)
        } action: { barRoom = $0 }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .barGround(.paper)
        .background(SearchActivator(isSearching: searchFocused, isCovered: isCovered) { searchFocused = true })
        .toolbar { toolbar(visible) }
        .toolbar { if isSelecting { selectionBar(visible) } }
        .toolbar(verticalBar == nil ? .automatic : .hidden, for: .navigationBar)
        .fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            importPDFs(result)
        }
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner { images in
                scanning = false
                importScan(images)
            }
            .ignoresSafeArea()
        }
        .notice("Rename Notebook", isPresented: Binding(isPresent: $renaming)) {
            TextField("Title", text: $renameText)
        } actions: {
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let renaming { store.rename(renaming, to: renameText) } }
        }
        .notice("Delete all notebooks in Recently Deleted?", isPresented: $confirmingEmptyTrash, message: Text("This can't be undone.")) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) { store.deletePermanently(visible) }
        }
        .notice("Something went wrong", isPresented: Binding(get: { errorMessage != nil || store.lastError != nil || flashcards.lastError != nil },
                                                             set: { if !$0 { errorMessage = nil; store.clearError(); flashcards.clearError() } }),
                message: Text(errorMessage ?? store.lastError ?? flashcards.lastError ?? "")) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: scope) { _, _ in
            endSelection()
            tagPages = [:]
        }
        .onChange(of: sort) { _, _ in sortReversed = false }
        .task(id: "\(store.searchVersion)|\(records.count)|\(scope)|\(searchText)") { await runSearch() }
        .task(id: tagPagesKey) { await loadTagPages() }
        .sheet(item: $export) { job in ExportSheet(job: job).presentationCornerRadius(Radius.sheet) }
        .sheet(item: $editingCover) { record in CoverEditorView(record: record).presentationCornerRadius(Radius.sheet) }
        .sheet(item: $tagging) { record in
            TagSheet(subject: record.title.orUntitled, initial: record.tags) { tags in
                changes.setTags(tags, for: record, in: store, undoManager: undoManager)
            }
            .presentationCornerRadius(Radius.sheet)
        }
        .sheet(item: $taggingSelection) { tagging in
            TagSheet(subject: String(localized: "\(tagging.ids.count) notebooks"), initial: tagging.common, mixed: tagging.mixed) { tags, stillMixed in
                let edit = TagEdit(before: (tagging.common, tagging.mixed), tags: tags, stillMixed: stillMixed)
                changes.editTags(edit, for: records.filter { tagging.ids.contains($0.id) }, in: store, undoManager: undoManager)
                endSelection()
            }
            .presentationCornerRadius(Radius.sheet)
        }
        .notice(Text(permanentDeleteTitle), isPresented: Binding(get: { !changes.pendingPermanentDelete.isEmpty },
                                                                 set: { if !$0 { changes.pendingPermanentDelete = [] } }),
                message: Text("This can't be undone.")) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Permanently", role: .destructive) { confirmPermanentDelete() }
        }
        .overlay(alignment: .bottom) { slip }
        .task(id: changes.current?.id) {
            guard changes.current != nil, !voiceOver else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { changes.dismiss() }
        }
        .onChange(of: isCovered) { _, covered in if covered { changes.dismiss() } }
        .onChange(of: requests?.importPDF ?? false) { _, asked in
            guard asked else { return }
            requests?.importPDF = false
            importingPDF = true
        }
        .onChange(of: requests?.scan ?? false) { _, asked in
            guard asked else { return }
            requests?.scan = false
            startScan()
        }
    }

    // MARK: Shelves

    private func shelves(_ visible: [NotebookRecord]) -> some View {
        scroller {
            LazyVStack(alignment: .leading, spacing: Space.x6) {
                LibraryHeader(title: title, summary: subtitle(visible), showsRhythm: showsRhythm, onOpenPage: onOpenPage)
                if let recent = continueCandidate {
                    OpenBookSpread(record: recent, zoomNamespace: zoomNamespace) { onOpenZoomed(recent, nil, $0) }
                        .id("spread-\(recent.id.uuidString)")
                }
                if scope == .all, searchText.isEmpty, !isSelecting { DeskCards(records: records, zoomNamespace: zoomNamespace, onOpen: onOpenZoomed) }
                searchHits(visible)
                ForEach(groups(visible)) { shelf in
                    ShelfLabel(title: shelf.title, cloth: shelf.cloth)
                        .padding(.top, Space.x2)
                    if let shelfWidth {
                        let metrics = ShelfMetrics.fit(width: shelfWidth)
                        ForEach(shelf.records.chunked(into: metrics.columns), id: \.rowID) { row in
                            ShelfRow(items: row, metrics: metrics) { record in item(record, width: metrics.coverWidth) }
                                .padding(.bottom, Space.x2)
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 188), spacing: Space.x6, alignment: .top)],
                                  alignment: .leading, spacing: Space.x8) {
                            ForEach(shelf.records) { record in item(record, width: CoverWidth.shelf) }
                        }
                    }
                }
                taggedPagesSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shelfWidth = $0 }
        }
    }

    /// Rows on the paper under the shelves' own labels, with folder and tags beside each title where the pane has room.
    private func list(_ visible: [NotebookRecord]) -> some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let side = NotebookCatalogueRow.showsSide(width: listWidth, scale: textScale, isAccessibilitySize: isLarge)
        return scroller {
            LazyVStack(alignment: .leading, spacing: Space.x5) {
                LibraryHeader(title: title, summary: subtitle(visible), showsRhythm: showsRhythm, onOpenPage: onOpenPage)
                searchHits(visible)
                // At the accessibility sizes the tabs would stand as tall as the screen; the bar's Sort menu does the same.
                if !visible.isEmpty, !isLarge {
                    ShelfListSort(sort: $sort, reversed: $sortReversed)
                }
                ForEach(groups(visible)) { shelf in
                    LazyVStack(alignment: .leading, spacing: Space.x1) {
                        ShelfLabel(title: shelf.title, cloth: shelf.cloth)
                        ForEach(shelf.records) { record in
                            listRow(record) {
                                NotebookCatalogueRow(record: record, showsFolder: showsFolder, showsSide: side, isSelected: selection.contains(record.id)) {
                                    tap(record)
                                }
                            }
                        }
                    }
                }
                taggedPagesSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        }
    }

    /// The scroll view each layout sits in, which drops the keyboard and shows the bar's title once the header has gone by.
    private func scroller<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, Space.x8)
                .padding(.vertical, Space.x6)
        }
        .scrollDismissesKeyboard(.immediately)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 56 } action: { showsBarTitle = $1 }
    }

    /// Pages whose writing matches the search, above the notebooks.
    @ViewBuilder
    private func searchHits(_ visible: [NotebookRecord]) -> some View {
        if showsPageHits {
            PageHitsSection(records: visible, hits: pageHits.pages, more: pageHits.more, query: hitsQuery, zoomNamespace: zoomNamespace, onOpen: onOpenZoomed)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var taggedPagesSection: some View {
        if showsTagPages {
            PageHitsSection(records: taggedNotebooks, hits: tagPages, query: "", zoomNamespace: zoomNamespace, onOpen: onOpenZoomed)
                .padding(.top, Space.x2)
                .transition(.opacity)
        }
    }

    /// What every row of the list and the ledger does: opens or chooses its notebook, holds a menu and can be dragged.
    private func listRow<Row: View>(_ record: NotebookRecord, @ViewBuilder row: () -> Row) -> some View {
        held(record) {
            row()
                .accessibilityLabel(record.accessibilityDescription)
                .accessibilityHint(record.accessibilityHint(isSelecting: isSelecting))
                .accessibilityAddTraits(selection.contains(record.id) ? .isSelected : [])
                .accessibilityIdentifier("notebook.\(record.title)")
                .accessibilityActions { if !isSelecting { changes.trashActions(for: record, in: store, undoManager: undoManager) } }
        }
    }

    /// Gives a notebook its held menu and lets it be dragged out.
    private func held<Content: View>(_ record: NotebookRecord, @ViewBuilder content: () -> Content) -> some View {
        content()
            .heldMenu(Text(record.title), when: !isSelecting, draggable: true) { menu(for: record) }
            .onDrag { NotebookDrag.provider(for: record, root: store.root) } preview: { dragPreview(record) }
    }

    private func tap(_ record: NotebookRecord) {
        if isSelecting { toggle(record) } else if !record.isTrashed { onOpen(record) }
    }

    private func dragPreview(_ record: NotebookRecord) -> some View {
        Text(record.title).padding(Space.x2).background(Color.surface, in: RoundedRectangle.plate)
    }

    /// The notebook to reopen at the top of All notebooks: the last one opened.
    private var continueCandidate: NotebookRecord? {
        guard scope == .all, searchText.isEmpty, !isSelecting else { return nil }
        return records.filter { !$0.isTrashed && !$0.isLocked && $0.lastOpenedAt != nil && $0.id.uuidString != journalID }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    /// The notebooks whose pages a tag shelf lists, whether or not they are on the shelf themselves.
    private var taggedNotebooks: [NotebookRecord] { records.filter { tagPages[$0.id] != nil }.sorted(by: sort, reversed: sortReversed) }

    /// A view that mixes shelves says which shelf a notebook is on.
    private var showsFolder: Bool {
        switch scope {
        case .all, .favorites, .tag, .smart: true
        case .trash, .folder: false
        }
    }

    private func item(_ record: NotebookRecord, width: CGFloat) -> some View {
        held(record) {
            NotebookCoverItem(record: record, width: width, isSelecting: isSelecting, isSelected: selection.contains(record.id),
                              zoomNamespace: zoomNamespace, showsFolder: showsFolder) { tap(record) }
        }
    }

    /// The shelf at the accessibility text sizes: a board for what the shelf leads with, then a board for each run.
    private func ledger(_ visible: [NotebookRecord]) -> some View {
        scroller {
            LazyVStack(alignment: .leading, spacing: Space.x5) {
                LibraryHeader(title: title, summary: subtitle(visible), showsRhythm: false, onOpenPage: onOpenPage)
                Group(subviews: desk) { rows in
                    if !rows.isEmpty {
                        ShelfListBoard {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                row
                                    .padding(.horizontal, Space.x3)
                                    .padding(.vertical, Space.x2)
                                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                    .overlay(alignment: .top) { if index > 0 { ShelfRule() } }
                            }
                        }
                    }
                }
                if showsPageHits { pageBoard(visible, hits: pageHits.pages, more: pageHits.more, query: hitsQuery) }
                ForEach(groups(visible)) { shelf in
                    ShelfListBoard(title: shelf.title, cloth: shelf.cloth) {
                        ForEach(shelf.records) { record in
                            listRow(record) {
                                NotebookLedgerRow(record: record, showsFolder: showsFolder, isSelecting: isSelecting,
                                                  isSelected: selection.contains(record.id)) { tap(record) }
                            }
                        }
                    }
                }
                if showsTagPages { pageBoard(taggedNotebooks, hits: tagPages, query: "") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Continue writing, this week and the desk cards, each a row of the ledger's first board.
    @ViewBuilder
    private var desk: some View {
        if let recent = continueCandidate {
            Button { onOpen(recent) } label: {
                HStack(alignment: .top, spacing: Space.x3) {
                    RecordCover(record: recent, width: CoverWidth.row, showsShadow: false).frame(width: min(48 * textScale, CoverWidth.row))
                    VStack(alignment: .leading, spacing: Space.x1) {
                        Text("Continue writing").eyebrowStyle(Color.accentColor)
                        Text(recent.title).font(.headline).foregroundStyle(Color.ink)
                        Text("Page \(recent.currentPage + 1) of \(recent.pageCount)").font(.subheadline).foregroundStyle(Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(Text("Continue writing \(recent.title), page \(recent.currentPage + 1) of \(recent.pageCount)"))
            .accessibilityHint(Text("Opens at this page"))
        }
        if showsRhythm { WeekSummaryRow(onOpenPage: onOpenPage) }
        if scope == .all, searchText.isEmpty, !isSelecting { DeskCards(records: records, zoomNamespace: zoomNamespace, asRows: true, onOpen: onOpenZoomed) }
    }

    private func pageBoard(_ records: [NotebookRecord], hits: [UUID: [PageHit]], more: [UUID: Int] = [:], query: String) -> some View {
        ShelfListBoard(title: String(localized: "Pages")) {
            ForEach(records.filter { hits[$0.id] != nil }) { record in
                ForEach(hits[record.id] ?? []) { hit in
                    Button { onOpenPage(record, hit.page.id) } label: {
                        VStack(alignment: .leading, spacing: Space.x1) {
                            Text(hit.title(in: record.title)).font(.headline).foregroundStyle(Color.ink)
                            Text(PageSearch.highlighted(hit.snippet, query: query)).font(.subheadline).foregroundStyle(Color.textSecondary)
                        }
                    }
                    .buttonStyle(ShelfListRowStyle(isSelected: false))
                    .overlay(alignment: .top) { ShelfRule() }
                    .hoverEffect(.highlight)
                    .accessibilityLabel(Text(hit.label(in: record.title)))
                    .accessibilityHint(Text("Opens the notebook at this page"))
                }
                if let count = more[record.id] {
                    let line = String(localized: "\(count) more matches")
                    Text(line)
                        .metaStyle(.subheadline)
                        .padding(.horizontal, Space.x3)
                        .padding(.vertical, Space.x2)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .overlay(alignment: .top) { ShelfRule() }
                        .accessibilityLabel(Text("\(record.title), \(line)"))
                }
            }
        }
    }

    private func subtitle(_ visible: [NotebookRecord]) -> String {
        if isSelecting { return String(localized: "Select notebooks, then pick an action below") }
        if scope == .trash { return String(localized: "Deleted notebooks stay here for \(trashLength.days) days") }
        let count = visible.count
        let notebooks = String(localized: "\(count) notebooks")
        // On a tag shelf the pages counted are the tagged ones it lists, not every page of its notebooks.
        if rule != nil {
            let tagged = tagPages.values.reduce(0) { $0 + $1.count }
            let order = sort.summary(reversed: sortReversed)
            return tagged == 0 ? "\(notebooks) · \(order)" : "\(notebooks) · \(String(localized: "\(tagged) pages")) · \(order)"
        }
        let pageCount = visible.reduce(0) { $0 + $1.pageCount }
        let pages = String(localized: "\(pageCount) pages")
        return "\(notebooks) · \(pages) · \(sort.summary(reversed: sortReversed))"
    }

    /// This week's writing shows at the top of All notebooks, but not while searching or selecting.
    private var showsRhythm: Bool { scope == .all && searchText.isEmpty && !isSelecting }

    private func groups(_ visible: [NotebookRecord]) -> [Shelf] {
        guard !visible.isEmpty else { return [] }
        if !searchText.isEmpty { return [Shelf(id: "results", title: String(localized: "Results"), records: visible)] }
        if scope == .trash || sort == .title {
            return [Shelf(id: "all", title: sort == .title ? sort.directionName(reversed: sortReversed) : title, records: visible)]
        }
        let tree = tree
        var root: UUID?
        if case .folder(let id) = scope { root = id }
        // Inside a folder with nothing but its own notebooks, shelves by folder would be one shelf: recency says more.
        if grouping == .folder, root == nil || visible.contains(where: { $0.folder?.id != root }) {
            let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var shelves: [Shelf] = tree.ordered.compactMap { id in
                guard let folder = byID[id] else { return nil }
                let items = visible.filter { $0.folder?.id == id }
                return items.isEmpty ? nil : Shelf(id: id.uuidString, title: id == root ? folder.name : tree.path(of: id, from: root), records: items, cloth: folder.cloth)
            }
            let loose = visible.filter { $0.folder == nil }
            if !loose.isEmpty { shelves.append(Shelf(id: "loose", title: String(localized: "Not on a shelf"), records: loose)) }
            return shelves
        }
        let calendar = Calendar.current
        let now = Date.now
        var buckets: [(key: String, date: Date, records: [NotebookRecord])] = []
        var positions: [String: Int] = [:]
        for record in visible {
            let date = sort.date(of: record)
            let key = ShelfGrouping.bucket(for: date, now: now, calendar: calendar)
            if let index = positions[key] {
                buckets[index].records.append(record)
            } else {
                positions[key] = buckets.count
                buckets.append((key, date, [record]))
            }
        }
        return buckets.map { bucket in
            let title = switch bucket.key {
            case "today": String(localized: "Today")
            case "yesterday": String(localized: "Yesterday")
            case "week": String(localized: "This week")
            case "month": String(localized: "Earlier this month")
            default: bucket.date.formatted(.dateTime.month(.wide).year())
            }
            return Shelf(id: bucket.key, title: title, records: bucket.records)
        }
    }

    // MARK: Selection

    private func toggle(_ record: NotebookRecord) {
        if selection.contains(record.id) { selection.remove(record.id) } else { selection.insert(record.id) }
    }

    private func endSelection() {
        isSelecting = false
        selection = []
    }

    private func selected(_ visible: [NotebookRecord]) -> [NotebookRecord] { visible.filter { selection.contains($0.id) } }

    @ToolbarContentBuilder
    private func selectionBar(_ visible: [NotebookRecord]) -> some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            if scope == .trash {
                Button("Restore") { changes.restore(selected(visible), in: store, undoManager: undoManager); endSelection() }
                    .buttonStyle(.owlLuna(.secondary, inBar: true))
                    .disabled(selection.isEmpty)
                Spacer()
                BarGroup {
                    Button(role: .destructive) { changes.requestPermanentDelete(selected(visible).map(\.id)) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .disabled(selection.isEmpty)
            } else {
                let chosen = selected(visible)
                BarGroup {
                    Button { changes.setFavorite(true, for: chosen, in: store, undoManager: undoManager); endSelection() } label: {
                        Label("Favourite", systemImage: "star")
                    }
                    .accessibilityIdentifier("library.selection.favourite")
                    Button { tagSelection(chosen) } label: { Label("Tags…", systemImage: "tag") }
                        .disabled(!chosen.contains { !$0.isReadOnly })
                        .accessibilityIdentifier("library.selection.tags")
                    OwlLunaMenu {
                        Button("Not on a shelf") { move(chosen, to: nil); endSelection() }
                        ForEach(folders) { folder in Button(tree.path(of: folder.id)) { move(chosen, to: folder); endSelection() } }
                    } label: { Label("Move", systemImage: "folder") }
                    .accessibilityIdentifier("library.selection.move")
                    Button { lockSelection(chosen) } label: { Label("Lock", systemImage: "lock") }
                        .disabled(!chosen.contains { !$0.isLocked && !$0.isReadOnly })
                        .accessibilityIdentifier("library.selection.lock")
                    Button { exportSelection(chosen) } label: { Label("Export as PDFs", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("library.selection.export")
                }
                .disabled(chosen.isEmpty)
                Spacer()
                BarGroup {
                    Button(role: .destructive) { changes.moveToTrash(chosen, in: store, undoManager: undoManager); endSelection() } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .accessibilityIdentifier("library.selection.delete")
                }
                .disabled(chosen.isEmpty)
            }
        }
        .boardBackground()
    }

    /// The tags every chosen notebook has are on, the ones only some have are shown as mixed.
    private func tagSelection(_ chosen: [NotebookRecord]) {
        let writable = chosen.filter { !$0.isReadOnly }
        let shared = TagEdit.shared(writable.map(\.tags))
        taggingSelection = SelectionTags(ids: writable.map(\.id), common: shared.common, mixed: shared.mixed)
    }

    private func lockSelection(_ chosen: [NotebookRecord]) {
        Task {
            if let failure = await store.lock(chosen) { errorMessage = failure } else { endSelection() }
        }
    }

    private func exportSelection(_ chosen: [NotebookRecord]) {
        Task {
            do {
                export = try await ExportJob.pdfs(of: chosen, root: store.root, choosing: true)
                endSelection()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Toolbar and menus

    private var searchField: some View {
        OwlLunaSearchField("Search", text: $searchText, capsTextSize: searchInBar, identifier: "library.search", focus: $searchFocused)
    }

    /// A bar without room for the search field would drop it into the overflow menu, so there it sits under the bar.
    private var searchInBar: Bool { barRoom >= actionsWidth + 308 && !dynamicTypeSize.isAccessibilitySize }

    /// In a narrow bar, as beside the sidebar on an 11-inch iPad held upright, Sort and New show just their symbols so the title has room.
    private var compactActions: Bool { barRoom < 600 }

    @ViewBuilder
    private func selectingButtons(_ visible: [NotebookRecord]) -> some View {
        let count = selected(visible).count, everything = !visible.isEmpty && count == visible.count
        Button(everything ? String(localized: "Deselect All") : String(localized: "Select All")) {
            selection = everything ? [] : filter.selectingAll(records)
        }
        .buttonStyle(.owlLuna(.secondary, inBar: true))
        .disabled(visible.isEmpty)
        .accessibilityIdentifier("library.selectAll")
        Button("Done") { endSelection() }
            .buttonStyle(.owlLuna(.primary, inBar: true))
            .accessibilityLabel(count == 0 ? String(localized: "Done") : String(localized: "\(count) selected, done"))
    }

    /// Sort, and with `withLayout` Shelf or List as well, for a bar with no room for the layout's own control.
    private func sortMenu(withLayout: Bool) -> some View {
        OwlLunaMenu {
            if withLayout {
                OwlLunaPicker("View As", selection: $layout) {
                    ForEach(LibraryLayout.allCases) { Text($0.displayName).tag($0) }
                }
            }
            OwlLunaPicker("Sort By", selection: $sort) {
                ForEach(LibrarySortOrder.allCases) { Text($0.displayName).tag($0) }
            }
            OwlLunaPicker("Order", selection: $sortReversed) {
                ForEach([false, true], id: \.self) { Text(sort.directionName(reversed: $0)).tag($0) }
            }
            OwlLunaPicker("Group By", selection: $grouping) {
                ForEach(LibraryGrouping.allCases) { Text($0.displayName).tag($0) }
            }
        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
    }

    /// Beside the search field on a folded iPhone Duo, whose bar is a rail of places with New at its head.
    private func railActions(_ visible: [NotebookRecord]) -> some View {
        HStack(spacing: Space.x2) {
            if isSelecting {
                selectingButtons(visible)
            } else {
                if let sync = app?.sync, !sync.news.isEmpty { SyncNoticeButton(sync: sync, onOpen: onOpen) }
                if scope == .trash {
                    Button("Empty") { confirmingEmptyTrash = true }.disabled(visible.isEmpty)
                } else {
                    sortMenu(withLayout: true).symbolOnly(true)
                }
                Button("Select") { isSelecting = true }.disabled(visible.isEmpty)
            }
        }
        .buttonStyle(.owlLuna(.secondary, inBar: true))
        .labelStyle(.titleAndIcon)
        .fixedSize()
    }

    @ToolbarContentBuilder
    private func toolbar(_ visible: [NotebookRecord]) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            let label = Text(title)
                .font(.headline)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.6 : 1)
            label
                .hidden()
                .overlay { if showsBarTitle { label.transition(.opacity) } }
                .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: showsBarTitle)
        }
        ToolbarItem(placement: .primaryAction) {
            if isSelecting {
                HStack(spacing: Space.x2) { selectingButtons(visible) }
            } else {
                HStack(spacing: Space.x2) {
                    if let sync = app?.sync, !sync.news.isEmpty { SyncNoticeButton(sync: sync, onOpen: onOpen) }
                    OwlLunaSegmentedPicker("Layout", selection: $layout, options: LibraryLayout.allCases, inBar: true,
                                           identifier: { "library.layout.\($0.rawValue)" }) { option in
                        Label(option.displayName, systemImage: option.symbol).labelStyle(.iconOnly)
                    }
                    if scope == .trash {
                        Button("Empty") { confirmingEmptyTrash = true }.disabled(visible.isEmpty)
                    } else {
                        sortMenu(withLayout: false).symbolOnly(compactActions)
                    }
                    Button("Select") { isSelecting = true }.disabled(visible.isEmpty)
                    if scope != .trash {
                        OwlLunaMenu {
                            Button { onCreate() } label: { Label("New Notebook", systemImage: "book.closed") }
                            Button { onQuickNote() } label: { Label("Quick Note", systemImage: "square.and.pencil") }
                            Button { onWhiteboard() } label: { Label("Whiteboard", systemImage: "scribble.variable") }
                                .accessibilityIdentifier("library.new.board")
                            Button { importingPDF = true } label: { Label("Import PDF…", systemImage: "doc.richtext") }
                            if DocumentScan.isAvailable {
                                Button(action: startScan) { Label("Scan Documents…", systemImage: "doc.viewfinder") }
                            }
                        } label: {
                            Label("New", systemImage: "plus").symbolOnly(compactActions)
                        } primaryAction: {
                            onCreate()
                        }
                        .buttonStyle(.owlLuna(.primary, inBar: true))
                    }
                }
                .buttonStyle(.owlLuna(.secondary, inBar: true))
                .labelStyle(.titleAndIcon)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { actionsWidth = $0 }
            }
        }
        .boardBackground()
        if searchInBar {
            ToolbarItem(placement: .primaryAction) { searchField.frame(width: 260) }
                .boardBackground()
        }
        if isSelecting {
            ToolbarItem(placement: .status) {
                Text("\(selected(visible).count) selected")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.ink)
            }
            .boardBackground()
        }
    }

    @ViewBuilder
    private func menu(for record: NotebookRecord) -> some View {
        if record.isTrashed {
            Button { changes.restore([record], in: store, undoManager: undoManager) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { changes.requestPermanentDelete([record.id]) } label: { Label("Delete Permanently", systemImage: "trash") }
        } else if record.isReadOnly {
            Button { onOpen(record) } label: { Label("Open", systemImage: "book") }
            exportButtons(for: record)
            MenuBreak()
            deleteButton(for: record)
                .accessibilityIdentifier("notebook.menu.delete")
            Text("Made with a newer version of OwlLuna, so it can only be read here.")
                .font(.footnote)
                .foregroundStyle(Color.textSecondary)
                .padding(Space.x3)
        } else {
            Button { onOpen(record) } label: { Label("Open", systemImage: "book") }
            Button { renameText = record.title; renaming = record } label: { Label("Rename", systemImage: "pencil") }
            Button { changes.setFavorite(!record.isFavorite, for: [record], in: store, undoManager: undoManager) } label: {
                Label(record.isFavorite ? "Unfavourite" : "Favourite", systemImage: record.isFavorite ? "star.slash" : "star")
            }
            OwlLunaMenu {
                Button { move([record], to: nil) } label: { Label("Not on a shelf", systemImage: record.folder == nil ? "checkmark" : "tray") }
                ForEach(folders) { folder in
                    Button { move([record], to: folder) } label: {
                        Label(tree.path(of: folder.id), systemImage: record.folder?.id == folder.id ? "checkmark" : "folder")
                    }
                }
            } label: { Label("Move to Shelf", systemImage: "folder") }
            Button {
                Task { do { try await store.duplicate(record) } catch { errorMessage = error.localizedDescription } }
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button { changeCover(record) } label: { Label("Change Cover…", systemImage: "book.closed") }
            Button { tagging = record } label: { Label("Tags…", systemImage: "tag") }
            exportButtons(for: record)
            Toggle(isOn: Binding(get: { journalID == record.id.uuidString }, set: { store.setDailyJournal($0 ? record.id : nil) })) {
                Label("Use as Daily Journal", systemImage: "calendar")
            }
            Button { toggleLock(record) } label: {
                Label(record.isLocked ? "Remove Lock…" : "Lock…", systemImage: record.isLocked ? "lock.open" : "lock")
            }
            MenuBreak()
            deleteButton(for: record)
        }
    }

    @ViewBuilder
    private func exportButtons(for record: NotebookRecord) -> some View {
        Button { startExport(record, as: .pdf) } label: { Label("Export as PDF", systemImage: "square.and.arrow.up") }
        Button { startExport(record, as: .images) } label: { Label("Export as Images", systemImage: "photo.on.rectangle") }
        Button { startExport(record, as: .text) } label: { Label("Export as Text", systemImage: "doc.plaintext") }
    }

    private func deleteButton(for record: NotebookRecord) -> some View {
        Button(role: .destructive) { changes.moveToTrash([record], in: store, undoManager: undoManager) } label: { Label("Delete", systemImage: "trash") }
    }

    private func startExport(_ record: NotebookRecord, as format: ExportJob.Format) {
        let id = record.id, title = record.title, locked = record.isLocked
        Task {
            if locked, !(await NotebookLock.shared.confirm(String(localized: "Export “\(title)”"))) { return }
            do { export = try await ExportJob.forNotebook(id, root: store.root, format: format, choosing: true) } catch { errorMessage = error.localizedDescription }
        }
    }

    /// The cover editor can show a notebook's first page, so a locked notebook asks first.
    private func changeCover(_ record: NotebookRecord) {
        guard record.isLocked else { return editingCover = record }
        let title = record.title
        Task { if await NotebookLock.shared.confirm(String(localized: "Unlock “\(title)”")) { editingCover = record } }
    }

    private func toggleLock(_ record: NotebookRecord) {
        Task { if let failure = await store.toggleLock(record) { errorMessage = failure } }
    }

    // MARK: Safety net

    private func move(_ records: [NotebookRecord], to folder: FolderRecord?) {
        changes.move(records, to: folder, in: store, undoManager: undoManager)
    }

    private var permanentDeleteTitle: String {
        let ids = changes.pendingPermanentDelete
        guard let first = ids.first else { return "" }
        if ids.count > 1 { return String(localized: "Delete \(ids.count) notebooks permanently?") }
        let title = records.first { $0.id == first }?.title ?? ""
        return String(localized: "Delete “\(title)” permanently?")
    }

    private func confirmPermanentDelete() {
        let ids = Set(changes.pendingPermanentDelete)
        changes.confirmPermanentDelete(in: store)
        selection.subtract(ids)
        if isSelecting, selection.isEmpty { endSelection() }
    }

    private var slip: some View {
        VStack(spacing: 0) {
            if let pdfImport { PDFImportStatus(run: pdfImport) { self.pdfImport = nil }.id(ObjectIdentifier(pdfImport)) }
            ZStack {
                if let change = changes.current {
                    LibrarySlipView(change: change) { changes.dismiss() }
                        .padding(.bottom, Space.x4)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: changes.current?.id)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            EmptyShelf(title: String(localized: "Nothing found for “\(searchText)”"), message: String(localized: "Check the spelling, or try other words."))
        } else if scope == .trash {
            EmptyShelf(title: String(localized: "Nothing in the bin"), message: String(localized: "Deleted notebooks stay here for \(trashLength.days) days."))
        } else if scope == .favorites {
            EmptyShelf(title: String(localized: "No favourites yet"), message: String(localized: "Touch and hold a notebook, then choose Favourite."),
                       illustration: { RibbonIllustration() })
        } else if case .tag(let name) = scope {
            EmptyShelf(title: String(localized: "Nothing tagged “\(name)”."),
                       message: String(localized: "Tag a notebook or a page with it and it stands here."),
                       illustration: { ShelfIllustration(cloth: nil) })
        } else if case .smart = scope {
            EmptyShelf(title: String(localized: "Nothing on this shelf yet."),
                       message: String(localized: "Notebooks and pages stand here once their tags match the shelf's."),
                       illustration: { ShelfIllustration(cloth: nil) })
        } else if case .folder = scope, let name = folder?.name {
            EmptyShelf(title: String(localized: "Nothing on \(name) yet."),
                       message: String(localized: "Drag notebooks onto \(name) in the sidebar, or start one here.")) {
                Button("New Notebook", action: onCreate).buttonStyle(.owlLuna(.primary))
            } illustration: {
                ShelfIllustration(cloth: nil)
            }
        } else {
            EmptyShelf(title: String(localized: "Your shelf is ready."),
                       message: String(localized: "Create a notebook to start writing, or import a PDF to annotate.")) {
                Button("New Notebook", action: onCreate).buttonStyle(.owlLuna(.primary))
                Button("Import PDF") { importingPDF = true }.buttonStyle(.owlLuna)
            } illustration: {
                ShelfIllustration()
            }
        }
    }

    private func startScan() {
        #if DEBUG
        if LaunchOptions.arguments.contains("-fakeScan") { return importScan(DocumentScan.samples()) }
        #endif
        scanning = true
    }

    private func importScan(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        Task {
            do {
                try await store.importScan(images, folder: folder)
                AccessibilityNotification.Announcement(String(localized: "\(images.count) pages scanned into a new notebook")).post()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Each PDF comes in on its own, after any still coming in, and into the folder on show when it was chosen.
    private func importPDFs(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get(), folder = folder, store = store
            guard !urls.isEmpty else { return }
            let run = pdfImport.flatMap { $0.isFinished ? nil : $0 } ?? PDFImportRun()
            pdfImport = run
            run.add(urls) { url, password, progress in
                try await store.importPDF(from: url, folder: folder, password: password, progress: progress)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension LibrarySortOrder {
    func date(of record: NotebookRecord) -> Date {
        switch self {
        case .opened: record.lastOpenedAt ?? record.modifiedAt
        case .modified, .title: record.modifiedAt
        case .created: record.createdAt
        }
    }
}

extension Array where Element == NotebookRecord {
    /// Reads each record's sort key once, rather than twice per comparison. Turned round, the oldest come first, or Z.
    func sorted(by order: LibrarySortOrder, reversed: Bool = false) -> [NotebookRecord] {
        switch order {
        case .title:
            let first: ComparisonResult = reversed ? .orderedDescending : .orderedAscending
            return map { ($0, $0.title) }.sorted { $0.1.localizedStandardCompare($1.1) == first }.map(\.0)
        default:
            return map { ($0, order.date(of: $0)) }.sorted { reversed ? $0.1 < $1.1 : $0.1 > $1.1 }.map(\.0)
        }
    }
}

private extension View {
    /// Just the symbol, its name still read out, when `on`.
    @ViewBuilder func symbolOnly(_ on: Bool) -> some View {
        if on { labelStyle(.iconOnly) } else { self }
    }
}
