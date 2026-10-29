import SwiftUI
import SwiftData

/// The window's library changes: each one is undoable (the slip, ⌘Z), and permanent deletes wait for a confirmation.
@MainActor
@Observable
final class LibraryChangeCenter {
    struct Change: Identifiable {
        let id = UUID()
        let message: String
        let symbol: String
        let undo: @MainActor () -> Void
    }

    private(set) var current: Change?
    var pendingPermanentDelete: [UUID] = []
    private(set) var trashBumps = 0

    func post(_ message: String, symbol: String = "arrow.uturn.backward", isTrash: Bool = false, undo: @escaping @MainActor () -> Void) {
        current = Change(message: message, symbol: symbol, undo: undo)
        if isTrash { trashBumps += 1 }
        AccessibilityNotification.Announcement(message).post()
    }

    func dismiss() {
        current = nil
    }

    func requestPermanentDelete(_ ids: [UUID]) {
        pendingPermanentDelete = ids
    }

    func confirmPermanentDelete(in store: LibraryStore) {
        let ids = pendingPermanentDelete
        pendingPermanentDelete = []
        store.deletePermanently(ids.compactMap(store.record))
    }

    // MARK: Changes

    func moveToTrash(_ records: [NotebookRecord], in store: LibraryStore, undoManager: UndoManager?) {
        perform(records, includingReadOnly: true, in: store, undoManager: undoManager, action: String(localized: "Delete"), symbol: "trash", isTrash: true,
                message: { $0.count == 1 ? String(localized: "Moved “\($0[0].title)” to Recently Deleted")
                                         : String(localized: "Moved \($0.count) notebooks to Recently Deleted") },
                apply: { store.moveToTrash($0) }, inverse: { store.restore($0) })
    }

    func restore(_ records: [NotebookRecord], in store: LibraryStore, undoManager: UndoManager?) {
        perform(records, includingReadOnly: true, in: store, undoManager: undoManager, action: String(localized: "Restore"), symbol: "arrow.uturn.backward",
                message: { $0.count == 1 ? String(localized: "Restored “\($0[0].title)”") : String(localized: "Restored \($0.count) notebooks") },
                apply: { store.restore($0) }, inverse: { store.moveToTrash($0) })
    }

    func setFavorite(_ favorite: Bool, for records: [NotebookRecord], in store: LibraryStore, undoManager: UndoManager?) {
        let previous = Dictionary(records.map { ($0.id, $0.isFavorite) }, uniquingKeysWith: { first, _ in first })
        let message: ([NotebookRecord]) -> String = { records in
            switch (favorite, records.count) {
            case (true, 1): String(localized: "Added “\(records[0].title)” to Favourites")
            case (true, _): String(localized: "Added \(records.count) notebooks to Favourites")
            case (false, 1): String(localized: "Removed “\(records[0].title)” from Favourites")
            case (false, _): String(localized: "Removed \(records.count) notebooks from Favourites")
            }
        }
        perform(records, in: store, undoManager: undoManager, action: favorite ? String(localized: "Favourite") : String(localized: "Unfavourite"),
                symbol: favorite ? "star" : "star.slash", message: message,
                apply: { store.setFavorite(favorite, for: $0) },
                inverse: { records in
                    for value in [true, false] {
                        let group = records.filter { previous[$0.id] == value }
                        if !group.isEmpty { store.setFavorite(value, for: group) }
                    }
                })
    }

    /// Undo gives the notebook the tags it had.
    func setTags(_ tags: [String], for record: NotebookRecord, in store: LibraryStore, undoManager: UndoManager?) {
        let tags = Tags.merged(tags), previous = record.tags
        guard tags != previous else { return }
        perform([record], in: store, undoManager: undoManager, action: String(localized: "Change Tags"), symbol: "tag",
                message: { String(localized: "Changed the tags of “\($0[0].title)”") },
                apply: { store.setTags(tags, for: $0) }, inverse: { store.setTags(previous, for: $0) })
    }

    /// Tags added to and taken off several notebooks at once. Undo gives each one the tags it had.
    func editTags(_ edit: TagEdit, for records: [NotebookRecord], in store: LibraryStore, undoManager: UndoManager?) {
        let previous = Dictionary(records.map { ($0.id, $0.tags) }, uniquingKeysWith: { first, _ in first })
        perform(records.filter { edit.applied(to: $0.tags) != $0.tags }, in: store, undoManager: undoManager, action: String(localized: "Change Tags"),
                symbol: "tag",
                message: { $0.count == 1 ? String(localized: "Changed the tags of “\($0[0].title)”") : String(localized: "Changed the tags of \($0.count) notebooks") },
                apply: { store.editTags(edit, for: $0) },
                inverse: { records in
                    for (tags, group) in Dictionary(grouping: records, by: { previous[$0.id] ?? [] }) { store.setTags(tags, for: group) }
                })
    }

    /// Undo returns each notebook to the shelf it was on, or off the shelves if that shelf has since been deleted.
    func move(_ records: [NotebookRecord], to folder: FolderRecord?, in store: LibraryStore, undoManager: UndoManager?) {
        let previous = Dictionary(records.map { ($0.id, $0.folder?.id) }, uniquingKeysWith: { first, _ in first })
        let folderID = folder?.id, name = folder?.name ?? ""
        let message: ([NotebookRecord]) -> String = { records in
            switch (folderID == nil, records.count) {
            case (false, 1): String(localized: "Moved “\(records[0].title)” to \(name)")
            case (false, _): String(localized: "Moved \(records.count) notebooks to \(name)")
            case (true, 1): String(localized: "Took “\(records[0].title)” off its shelf")
            case (true, _): String(localized: "Took \(records.count) notebooks off their shelves")
            }
        }
        perform(records.filter { $0.folder?.id != folderID }, in: store, undoManager: undoManager, action: String(localized: "Move to Shelf"),
                symbol: "folder", message: message,
                apply: { store.move($0, to: Self.folder(folderID, in: store)) },
                inverse: { records in
                    for (id, group) in Dictionary(grouping: records, by: { previous[$0.id] ?? nil }) {
                        store.move(group, to: Self.folder(id, in: store))
                    }
                })
    }

    /// Undo puts the folder back where it was, holding the notebooks and folders it held.
    func deleteFolder(_ folder: FolderRecord, in store: LibraryStore, undoManager: UndoManager?) {
        let id = folder.id, deletion = FolderDeletion()
        perform(String(localized: "Deleted the folder “\(folder.name)”"), symbol: "folder.badge.minus", undoManager: undoManager,
                action: String(localized: "Delete Folder"), apply: { deletion.deleted = store.deleteFolder(folder) },
                undo: { [weak store] in if let deleted = deletion.deleted { store?.restoreFolder(deleted) } },
                redo: { [weak store] in
                    guard let store, let folder = Self.folder(id, in: store) else { return }
                    deletion.deleted = store.deleteFolder(folder)
                })
    }

    private static func folder(_ id: UUID?, in store: LibraryStore) -> FolderRecord? {
        guard let id else { return nil }
        return try? store.context.fetch(FetchDescriptor<FolderRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func perform(_ records: [NotebookRecord], includingReadOnly: Bool = false, in store: LibraryStore, undoManager: UndoManager?, action: String,
                         symbol: String, isTrash: Bool = false, message: ([NotebookRecord]) -> String,
                         apply: @escaping @MainActor ([NotebookRecord]) -> Void, inverse: @escaping @MainActor ([NotebookRecord]) -> Void) {
        let records = includingReadOnly ? records : records.filter { !$0.isReadOnly }
        guard !records.isEmpty else { return }
        let ids = records.map(\.id)
        perform(message(records), symbol: symbol, isTrash: isTrash, undoManager: undoManager, action: action, apply: { apply(records) },
                undo: { [weak store] in if let store { inverse(ids.compactMap(store.record)) } },
                redo: { [weak store] in if let store { apply(ids.compactMap(store.record)) } })
    }

    private func perform(_ text: String, symbol: String, isTrash: Bool = false, undoManager: UndoManager?, action: String, apply: () -> Void,
                         undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void) {
        let token = UndoToken(undoManager: undoManager)
        apply()
        if let undoManager { register(token: token, undoManager: undoManager, action: action, undo: undo, redo: redo) }
        post(text, symbol: symbol, isTrash: isTrash) { [weak self, weak undoManager] in
            guard !token.isUndone else { return }
            if let undoManager, !token.isBuried, undoManager.canUndo {
                undoManager.undo()
            } else {
                undoManager?.removeAllActions(withTarget: token)
                token.isUndone = true
                self?.dismiss()
                undo()
            }
        }
    }

    /// One change's undo target. Once anything else is registered after it, the slip undoes just this change.
    @MainActor
    private final class UndoToken: NSObject {
        var isUndone = false
        private(set) var isBuried = false
        private var groups = 0

        init(undoManager: UndoManager?) {
            super.init()
            guard let undoManager else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(groupClosed), name: .NSUndoManagerDidCloseUndoGroup, object: undoManager)
        }

        @objc nonisolated private func groupClosed(_ note: Notification) {
            MainActor.assumeIsolated {
                groups += 1
                if groups > 1 { isBuried = true }
            }
        }
    }

    /// Undo registers the redo, which registers the undo again, as NotebookDocument's page operations do.
    private func register(token: UndoToken, undoManager: UndoManager, action: String,
                          undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void) {
        undoManager.registerUndo(withTarget: token) { [weak self, weak undoManager, token] _ in
            self?.dismiss()
            token.isUndone.toggle()
            undo()
            guard let self, let undoManager else { return }
            self.register(token: token, undoManager: undoManager, action: action, undo: redo, redo: undo)
        }
        undoManager.setActionName(action)
    }

    /// What the last delete of a folder took away, which its undo puts back.
    @MainActor
    private final class FolderDeletion {
        var deleted: LibraryStore.DeletedFolder?
    }
}

extension LibraryChangeCenter {
    /// Restore and Delete Permanently, the accessibility actions of a notebook in the bin.
    @ViewBuilder
    func trashActions(for record: NotebookRecord, in store: LibraryStore, undoManager: UndoManager?) -> some View {
        if record.isTrashed {
            Button("Restore") { self.restore([record], in: store, undoManager: undoManager) }
            Button("Delete Permanently") { self.requestPermanentDelete([record.id]) }
        }
    }
}

/// A paper slip at the foot of the library naming the last change, with Undo.
struct LibrarySlipView: View {
    let change: LibraryChangeCenter.Change
    let dismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x2)) : AnyLayout(HStackLayout(spacing: Space.x3))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: Space.x3) {
                Image(systemName: change.symbol)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
                Text(change.message)
                    .font(.subheadline)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            HStack(spacing: Space.x1) {
                Button("Undo", action: undo)
                    .buttonStyle(.owlLuna(.primary, compact: true))
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.textSecondary)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.leading, Space.x4)
        .padding(.trailing, Space.x1)
        .padding(.vertical, stacked ? Space.x3 : Space.x1)
        .frame(maxWidth: 520)
        .board(in: RoundedRectangle.bar)
        .padding(.horizontal, Space.x4)
        .accessibilityElement(children: .contain)
    }

    private func undo() {
        change.undo()
        dismiss()
    }
}
