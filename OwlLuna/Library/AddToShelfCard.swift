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

/// Every notebook not on a shelf already, most recently opened first, with where it is now. Rows are checked, then moved together.
struct AddToShelfCard: View {
    let folder: FolderRecord
    let move: ([NotebookRecord]) -> Void
    @Environment(\.panelClose) private var close
    @Query(filter: #Predicate<NotebookRecord> { $0.deletedAt == nil }) private var notebooks: [NotebookRecord]
    @Query(sort: \FolderRecord.sortIndex) private var folders: [FolderRecord]
    @State private var chosen: Set<UUID> = []

    var body: some View {
        let tree = FolderTree(folders: folders), inside = tree.subtree(folder.id)
        let others = notebooks.filter { !$0.isReadOnly && !($0.folder.map { inside.contains($0.id) } ?? false) }.sorted(by: .opened)
        VStack(spacing: 0) {
            if others.isEmpty {
                Text("Every notebook is on \(folder.name) already.")
                    .font(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .padding(Space.x3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(others.enumerated()), id: \.element.id) { index, record in
                            row(record, place: record.folder.map { String(localized: "On \(tree.path(of: $0.id))") } ?? String(localized: "Not on a shelf"))
                                .overlay(alignment: .top) { if index > 0 { HairlineRule() } }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                HairlineRule()
                let picked = others.filter { chosen.contains($0.id) }
                Button(picked.isEmpty ? String(localized: "Move Here") : String(localized: "Move \(picked.count) Here")) {
                    if let close { close(then: { move(picked) }) } else { move(picked) }
                }
                .buttonStyle(.owlLuna(.primary, compact: true))
                .disabled(picked.isEmpty)
                .accessibilityIdentifier("addToShelf.move")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(Space.x3)
            }
        }
        .frame(minWidth: 260, idealWidth: 340, maxWidth: 380)
    }

    private func row(_ record: NotebookRecord, place: String) -> some View {
        let picked = chosen.contains(record.id)
        return Button {
            if picked { chosen.remove(record.id) } else { chosen.insert(record.id) }
        } label: {
            HStack(spacing: Space.x3) {
                SpineChip(cloth: record.cloth, width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title.orUntitled)
                        .font(.callout.weight(picked ? .semibold : .regular))
                        .foregroundStyle(Color.ink)
                    Text(place)
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if picked {
                    Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Space.x3)
            .padding(.vertical, Space.x2)
            .frame(minHeight: 44)
            .overlay(alignment: .leading) { if picked { Rectangle().fill(Color.accentColor).frame(width: 3) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(CardRowStyle())
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("addToShelf.\(record.title)")
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
