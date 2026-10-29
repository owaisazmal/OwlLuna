import SwiftUI
import SwiftData

/// What the rail asks of the shelf on show, which is where importing and scanning live.
@Observable @MainActor
final class ShelfRequests {
    var importPDF = false
    var scan = false
}

/// The library's places down the vertical bar of a folded iPhone Duo, cut like a dictionary's thumb index: a tab for
/// each place, the chosen one in cloth and standing out from the edge, New at the head and Settings at the foot.
/// A folder's folders show under it while it, or one inside it, is chosen.
struct ThumbIndex: View {
    @Binding var scope: LibraryScope?
    let bar: VerticalBar
    let onCreate: () -> Void
    let onQuickNote: () -> Void
    let onWhiteboard: () -> Void
    let onShelves: () -> Void
    let onSettings: () -> Void
    @Environment(LibraryStore.self) private var store
    @Environment(ShelfRequests.self) private var requests
    @Query(sort: \FolderRecord.sortIndex) private var folders: [FolderRecord]
    @Query(filter: #Predicate<NotebookRecord> { $0.deletedAt == nil }) private var notebooks: [NotebookRecord]

    /// How far the chosen tab stands out over the shelf.
    private static let standOut: CGFloat = 8
    private static let tabHeight: CGFloat = 38

    var body: some View {
        let tree = FolderTree(folders: folders)
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: Space.x2) {
            newMenu
                .padding(.trailing, bar.margin)
            ScrollView {
                VStack(spacing: Space.x1) {
                    tab(.all, title: String(localized: "All notebooks"), short: String(localized: "All"), icon: "books.vertical")
                    tab(.favorites, title: String(localized: "Favourites"), icon: "star")
                    ForEach(tree.children(of: nil), id: \.self) { id in folderTabs(id, depth: 0, tree: tree, byID: byID) }
                    ForEach(store.smartShelves) { shelf in
                        tab(.smart(shelf.id), title: shelf.name, icon: "line.3.horizontal.decrease.circle")
                    }
                    ForEach(Tags.counts(notebooks)) { tag in tab(.tag(tag.name), title: tag.name, icon: "tag") }
                    tab(.trash, title: String(localized: "Recently deleted"), short: String(localized: "Deleted"), icon: "trash")
                }
                .padding(.vertical, Space.x1)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: Space.x2) {
                Button(action: onShelves) { Label("Shelves", systemImage: "sidebar.leading") }
                    .accessibilityHint(Text("Shows every shelf, to add, rename or move them"))
                    .accessibilityIdentifier("index.shelves")
                Button(action: onSettings) { Label("Settings", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
                    .accessibilityIdentifier("index.settings")
            }
            .buttonStyle(.plateIcon)
            .padding(.trailing, bar.margin)
        }
        .frame(width: bar.width + Self.standOut, alignment: .trailing)
        .dynamicTypeSize(...barTextLimit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Shelves"))
    }

    private var newMenu: some View {
        OwlLunaMenu {
            Button(action: onCreate) { Label("New Notebook", systemImage: "book.closed") }
            Button(action: onQuickNote) { Label("Quick Note", systemImage: "square.and.pencil") }
            Button(action: onWhiteboard) { Label("Whiteboard", systemImage: "scribble.variable") }
            Button { requests.importPDF = true } label: { Label("Import PDF…", systemImage: "doc.richtext") }
            if DocumentScan.isAvailable {
                Button { requests.scan = true } label: { Label("Scan Documents…", systemImage: "doc.viewfinder") }
            }
        } label: {
            Label("New", systemImage: "plus").labelStyle(.iconOnly)
        } primaryAction: {
            onCreate()
        }
        .buttonStyle(.owlLuna(.primary, inBar: true))
        .accessibilityIdentifier("index.new")
    }

    /// A folder's tab, then those of the folders inside it while the chosen place is somewhere among them.
    private func folderTabs(_ id: UUID, depth: Int, tree: FolderTree, byID: [UUID: FolderRecord]) -> AnyView {
        guard let folder = byID[id] else { return AnyView(EmptyView()) }
        let opens: Bool = if case .folder(let chosen) = scope { tree.subtree(id).contains(chosen) } else { false }
        return AnyView(Group {
            tab(.folder(id), title: folder.name, cloth: folder.cloth, depth: depth)
            if opens {
                ForEach(tree.children(of: id), id: \.self) { child in folderTabs(child, depth: depth + 1, tree: tree, byID: byID) }
            }
        })
    }

    private func tab(_ place: LibraryScope, title: String, short: String? = nil, icon: String? = nil, cloth: ClothColor? = nil,
                     depth: Int = 0) -> some View {
        let chosen = scope == place
        let indent = chosen ? 0 : Self.standOut + CGFloat(min(depth, 2)) * Space.x2
        return Button { scope = place } label: {
            HStack(spacing: Space.x1) {
                if let cloth {
                    SpineChip(cloth: cloth).scaleEffect(0.8)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(chosen ? Color.onPrimaryCloth : Color.sidebarTint)
                }
                Text(short ?? title)
                    .font(depth > 0 ? .caption2.weight(.medium) : .caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .foregroundStyle(chosen ? Color.onPrimaryCloth : Color.ink)
            .padding(.leading, Space.x2)
            .frame(height: depth > 0 ? Self.tabHeight - 6 : Self.tabHeight)
            .frame(maxWidth: .infinity)
            .background { if chosen { IndexCloth() } }
            .plate(in: Self.shape, fill: chosen ? .clear : Color.surface, flat: chosen)
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .padding(.leading, indent)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("index.\(title)")
    }

    /// Cut square on the side that runs off the screen.
    private static let shape = UnevenRoundedRectangle(topLeadingRadius: Radius.plate, bottomLeadingRadius: Radius.plate, style: .continuous)
}

/// The cobalt cloth of the chosen tab, woven and edged like the sidebar's chosen row.
private struct IndexCloth: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: Radius.plate, bottomLeadingRadius: Radius.plate, style: .continuous)
        shape.fill(Color.primaryCloth)
            .overlay {
                if contrast != .increased {
                    shape.fill(ImagePaint(image: ClothWeave.tile, scale: 1))
                    shape.strokeBorder(ClothWeave.bevel, lineWidth: 1)
                }
            }
    }
}
