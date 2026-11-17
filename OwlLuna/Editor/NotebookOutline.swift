import SwiftUI
import PDFKit

extension NotebookPage {
    /// The bookmark's name, empty when it hasn't been given one; nil when the page isn't bookmarked.
    var bookmark: String? {
        get { extra["bookmark"]?.stringValue }
        set { extra["bookmark"] = newValue.map(JSONValue.string) }
    }

    /// What a bookmark is called in lists: its name, the journal date, or the page number.
    func bookmarkTitle(number: Int) -> String {
        if let bookmark, !bookmark.isEmpty { return bookmark }
        if let spoken = day.flatMap(DailyJournal.spokenDay) { return spoken }
        return String(localized: "Page \(number)")
    }
}

extension NotebookDocument {
    /// One undo step for any change to a page's pictures and stickers.
    func updateItems(onPage pageID: UUID, actionName: String, _ change: (inout [PageItem]) -> Void) {
        guard let index = index(of: pageID) else { return }
        var items = pages[index].items
        change(&items)
        guard items != pages[index].items else { return }
        updatePage(pageID, actionName: actionName) { $0.items = items }
    }

    /// Whether any page is a page of an imported PDF, whose text can be selected.
    var hasPDFPages: Bool {
        pages.contains { if case .pdf = $0.background { true } else { false } }
    }

    func setBookmark(_ name: String?, forPage pageID: UUID) {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = index(of: pageID), pages[index].bookmark != name else { return }
        updatePage(pageID, actionName: name == nil ? String(localized: "Remove Bookmark") : String(localized: "Bookmark")) { $0.bookmark = name }
    }
}

struct OutlineEntry: Identifiable, Hashable, Sendable {
    /// Its place in the list.
    let id: Int
    let title: String
    let level: Int
    let pageID: UUID
    /// The entry this one is listed under.
    var parent: Int?
}

/// The table of contents an imported PDF came with, mapped onto the notebook's pages.
enum PDFOutlineReader {
    static func entries(pages: [NotebookPage], assets: URL) -> [OutlineEntry] {
        var pageIDs: [String: [Int: UUID]] = [:]
        var files: [String] = []
        for page in pages {
            guard case .pdf(let file, let index) = page.background else { continue }
            if pageIDs[file] == nil { files.append(file) }
            pageIDs[file, default: [:]][index] = page.id
        }
        var entries: [OutlineEntry] = []
        for file in files {
            guard let pdf = PDFDocument(url: assets.appending(path: file)), let root = pdf.outlineRoot, let ids = pageIDs[file] else { continue }
            collect(root, depth: 0, under: nil, in: pdf, ids: ids, into: &entries)
        }
        return entries
    }

    /// An entry whose own page is gone is left out, and what was under it moves up to the nearest entry still listed.
    private static func collect(_ node: PDFOutline, depth: Int, under parent: OutlineEntry?, in pdf: PDFDocument, ids: [Int: UUID],
                                into entries: inout [OutlineEntry]) {
        for index in 0..<node.numberOfChildren {
            guard let child = node.child(at: index), entries.count < 2000 else { continue }
            let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var listed = parent
            if !title.isEmpty, let page = child.destination?.page, let pageID = ids[pdf.index(for: page)] {
                let entry = OutlineEntry(id: entries.count, title: title, level: min(parent.map { $0.level + 1 } ?? 0, 4), pageID: pageID, parent: parent?.id)
                entries.append(entry)
                listed = entry
            }
            if depth < 6 { collect(child, depth: depth + 1, under: listed, in: pdf, ids: ids, into: &entries) }
        }
    }
}

/// A PDF's contents with chapters that fold: which entries are on show, and which one a page falls under.
struct OutlineFolds: Equatable {
    private(set) var entries: [OutlineEntry] = []
    private(set) var folded: Set<Int> = []
    private var parents: Set<Int> = []

    /// Every entry with others under it starts folded.
    init(_ entries: [OutlineEntry] = []) {
        self.entries = entries
        parents = Set(entries.compactMap(\.parent))
        folded = parents
    }

    func hasParts(_ entry: OutlineEntry) -> Bool { parents.contains(entry.id) }
    func isFolded(_ entry: OutlineEntry) -> Bool { folded.contains(entry.id) }

    /// The entries with nothing folded over them, in order.
    var shown: [OutlineEntry] {
        var hidden = Set<Int>()
        return entries.filter { entry in
            guard let parent = entry.parent, folded.contains(parent) || hidden.contains(parent) else { return true }
            hidden.insert(entry.id)
            return false
        }
    }

    mutating func toggle(_ entry: OutlineEntry) {
        guard hasParts(entry) else { return }
        if folded.remove(entry.id) == nil { folded.insert(entry.id) }
    }

    /// Unfolds `entry` and everything it is listed under.
    mutating func open(to entry: OutlineEntry) {
        folded.remove(entry.id)
        for above in chain(above: entry) { folded.remove(above.id) }
    }

    /// The entry a page falls under: the last one that begins on that page or before it.
    func entry(holding page: Int, places: [UUID: Int]) -> OutlineEntry? {
        var found: (entry: OutlineEntry, start: Int)?
        for entry in entries {
            guard let start = places[entry.pageID], start <= page, start >= found?.start ?? 0 else { continue }
            found = (entry, start)
        }
        return found?.entry
    }

    /// The row to mark for a page: the entry it falls under, or the folded one that entry is put away in.
    func mark(for page: Int, places: [UUID: Int]) -> OutlineEntry? {
        guard let entry = entry(holding: page, places: places) else { return nil }
        return chain(above: entry).last { folded.contains($0.id) } ?? entry
    }

    /// What `entry` is listed under, the nearest first.
    private func chain(above entry: OutlineEntry) -> [OutlineEntry] {
        var chain: [OutlineEntry] = [], below = entry
        while let id = below.parent, id < below.id, let above = entries.first(where: { $0.id == id }) {
            chain.append(above)
            below = above
        }
        return chain
    }
}

extension NotebookDocument {
    /// Where each page is in the notebook.
    var places: [UUID: Int] {
        Dictionary(pages.enumerated().map { ($0.element.id, $0.offset) }) { first, _ in first }
    }
}

/// The navigator's second tab: the pages you bookmarked, then the pages you tagged.
struct NotebookBookmarks: View {
    let session: EditorSession
    let open: (Int) -> Void
    @State private var renaming: UUID?
    @State private var name = ""

    private var document: NotebookDocument { session.document }

    private func pages(where include: (NotebookPage) -> Bool) -> [(index: Int, page: NotebookPage)] {
        document.pages.enumerated().filter { include($0.element) }.map { (index: $0.offset, page: $0.element) }
    }

    var body: some View {
        let bookmarks = pages(where: { $0.bookmark != nil }), tagged = pages(where: { !$0.tags.isEmpty })
        Group {
            if bookmarks.isEmpty, tagged.isEmpty {
                ScrollView {
                    EmptyPlate("No Bookmarks Yet", systemImage: "bookmark",
                               message: Text("Tap the small ribbon beside the page number to bookmark a page. Bookmarks and tagged pages are listed here."))
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                Ledger {
                    if !bookmarks.isEmpty {
                        Section {
                            ForEach(bookmarks, id: \.page.id) { item in bookmarkRow(item.page, at: item.index) }
                        } header: {
                            Text("Bookmarks")
                        }
                    }
                    if !tagged.isEmpty { TaggedPagesSection(pages: tagged, open: open) }
                }
            }
        }
        .notice("Name Bookmark", isPresented: Binding(isPresent: $renaming)) {
            TextField("Name", text: $name)
        } actions: {
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let renaming { document.setBookmark(name, forPage: renaming) } }
        }
        .accessibilityIdentifier("navigator.bookmarks")
    }

    private func bookmarkRow(_ page: NotebookPage, at index: Int) -> some View {
        Button { open(index) } label: {
            HStack(spacing: Space.x3) {
                Image(systemName: "bookmark.fill").foregroundStyle(Color.mustard).accessibilityHidden(true)
                Text(page.bookmarkTitle(number: index + 1)).foregroundStyle(Color.ink)
                Spacer(minLength: Space.x3)
                Text(index + 1, format: .number).monospacedDigit().foregroundStyle(Color.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("\(page.bookmarkTitle(number: index + 1)), page \(index + 1)"))
        .accessibilityHint(Text("Opens this page"))
        .ledgerSwipe {
            if !document.isReadOnly {
                Button(role: .destructive) { removeBookmark(page) } label: { Label("Remove", systemImage: "bookmark.slash") }
                Button { rename(page) } label: { Label("Rename", systemImage: "pencil") }
            }
        }
        .heldMenu(Text("Bookmark"), when: !document.isReadOnly) {
            if !document.isReadOnly {
                Button { rename(page) } label: { Label("Rename…", systemImage: "pencil") }
                Button(role: .destructive) { removeBookmark(page) } label: { Label("Remove Bookmark", systemImage: "bookmark.slash") }
            }
        }
    }

    private func rename(_ page: NotebookPage) {
        name = page.bookmark ?? ""
        renaming = page.id
    }

    private func removeBookmark(_ page: NotebookPage) {
        document.setBookmark(nil, forPage: page.id)
    }
}
