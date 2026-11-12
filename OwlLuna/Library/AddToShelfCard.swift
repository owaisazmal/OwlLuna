import SwiftUI
import SwiftData

extension View {
    /// Opens the card of notebooks that aren't on `folder` under this view, to move the ones checked onto it.
    func addToShelf(_ folder: FolderRecord?, isPresented: Binding<Bool>, move: @escaping ([NotebookRecord]) -> Void) -> some View {
        panel("Add to \(folder?.name ?? "")", isPresented: isPresented) {
            if let folder { AddToShelfCard(folder: folder, move: move) }
        }
    }
}

/// Every notebook not on a shelf already, those on no shelf first, each run most recently opened first. A search narrows
/// them by title, tag or shelf; what is checked stays checked while it is searched away, and moves together.
struct AddToShelfCard: View {
    let folder: FolderRecord
    let move: ([NotebookRecord]) -> Void
    @Environment(\.panelClose) private var close
    @Query(filter: #Predicate<NotebookRecord> { $0.deletedAt == nil }) private var notebooks: [NotebookRecord]
    @Query(sort: \FolderRecord.sortIndex) private var folders: [FolderRecord]
    @State private var chosen: Set<UUID> = []
    @State private var search = ""
    @FocusState private var searching: Bool
    @ScaledMetric(relativeTo: .callout) private var rowHeight: CGFloat = 60
    @ScaledMetric(relativeTo: .caption) private var bandHeight: CGFloat = 28

    var body: some View {
        let tree = FolderTree(folders: folders), inside = tree.subtree(folder.id)
        let candidates = notebooks.filter { !$0.isReadOnly && !($0.folder.map { inside.contains($0.id) } ?? false) }.sorted(by: .opened)
        let loose = candidates.filter { $0.folder == nil }, shelved = candidates.filter { $0.folder != nil }
        VStack(spacing: 0) {
            if candidates.isEmpty {
                Text("Every notebook is on \(folder.name) already.")
                    .font(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .padding(Space.x3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                OwlLunaSearchField("Search", text: $search, capsTextSize: false, identifier: "addToShelf.search", focus: $searching)
                    .padding(.horizontal, Space.x3)
                    .padding(.vertical, Space.x2)
                HairlineRule()
                // As tall as every notebook would need, so a search doesn't move the card.
                let groups = (loose.isEmpty ? 0 : 1) + (shelved.isEmpty ? 0 : 1)
                let height = min(CGFloat(groups) * bandHeight + CGFloat(candidates.count) * rowHeight, 420)
                list(loose: matching(loose, tree: tree), shelved: matching(shelved, tree: tree), tree: tree)
                    .frame(minHeight: 0, idealHeight: height, maxHeight: height)
                HairlineRule()
                footer(candidates.filter { chosen.contains($0.id) })
            }
        }
        .frame(minWidth: 280, idealWidth: 360, maxWidth: 380)
    }

    private func list(loose: [NotebookRecord], shelved: [NotebookRecord], tree: FolderTree) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if loose.isEmpty, shelved.isEmpty {
                    Text("No notebooks match “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(Color.textSecondary)
                        .padding(Space.x3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                group(String(localized: "Not on a Shelf"), loose, first: true, tree: tree)
                group(String(localized: "On Other Shelves"), shelved, first: loose.isEmpty, tree: tree)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func group(_ title: String, _ records: [NotebookRecord], first: Bool, tree: FolderTree) -> some View {
        if !records.isEmpty {
            Section {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    row(record, tree: tree)
                        .overlay(alignment: .top) { if index > 0 { HairlineRule() } }
                }
            } header: {
                band(title, records: records)
                    .overlay(alignment: .top) { if !first { HairlineRule() } }
                    .overlay(alignment: .bottom) { HairlineRule() }
            }
        }
    }

    /// A run's name, with a way to check or clear all of it that a search has left.
    private func band(_ title: String, records: [NotebookRecord]) -> some View {
        let ids = Set(records.map(\.id)), all = ids.isSubset(of: chosen)
        return HStack {
            Text(title).accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.x2)
            Button(all ? String(localized: "Deselect All") : String(localized: "Select All")) {
                if all { chosen.subtract(ids) } else { chosen.formUnion(ids) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.vertical, Space.x2)
            .contentShape(Rectangle())
            .padding(.vertical, -Space.x2)
        }
        .sectionBand()
    }

    private func row(_ record: NotebookRecord, tree: FolderTree) -> some View {
        let picked = chosen.contains(record.id), title = record.title.orUntitled
        let shelf = record.folder.map { tree.path(of: $0.id) }
        return Button {
            if picked { chosen.remove(record.id) } else { chosen.insert(record.id) }
        } label: {
            HStack(spacing: Space.x3) {
                SelectionBox(isSelected: picked)
                RecordCover(record: record, width: CoverWidth.row, showsShadow: false)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.ink)
                    if let folder = record.folder, let shelf {
                        HStack(spacing: Space.x1) {
                            SpineChip(cloth: folder.cloth).scaleEffect(0.6).frame(width: 5, height: 12)
                            Text(shelf)
                        }
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                    } else {
                        Text(record.metaLine)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Space.x3)
            .padding(.vertical, Space.x2)
            .frame(minHeight: 44)
            .background { if picked { Color.mustard.opacity(0.1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(CardRowStyle())
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("addToShelf.\(record.title)")
    }

    private func footer(_ picked: [NotebookRecord]) -> some View {
        HStack(spacing: Space.x2) {
            Spacer(minLength: 0)
            Button("Cancel") { close?() }
                .buttonStyle(.owlLuna(.secondary, compact: true))
                .accessibilityIdentifier("addToShelf.cancel")
            Button(picked.isEmpty ? String(localized: "Move Here") : String(localized: "Move \(picked.count) Here")) {
                if let close { close(then: { move(picked) }) } else { move(picked) }
            }
            .buttonStyle(.owlLuna(.primary, compact: true))
            .disabled(picked.isEmpty)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("addToShelf.move")
        }
        .padding(Space.x3)
    }

    /// Those whose title, tags or shelf hold every word typed.
    private func matching(_ records: [NotebookRecord], tree: FolderTree) -> [NotebookRecord] {
        let terms = SearchQuery(search).terms
        guard !terms.isEmpty else { return records }
        return records.filter { record in
            let shelf = record.folder.map { tree.path(of: $0.id) } ?? ""
            return terms.allSatisfy { term in
                record.title.localizedStandardContains(term) || shelf.localizedStandardContains(term)
                    || record.tags.contains { $0.localizedStandardContains(Tags.normalized(term) ?? term) }
            }
        }
    }
}

/// A row darkens under the finger, as a menu's does.
private struct CardRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { if configuration.isPressed { Color.well } }
            .hoverEffect(.highlight)
    }
}
