import SwiftUI

/// What a shelf shows: its scope, narrowed by a search, in the order chosen.
struct ShelfFilter {
    var scope: LibraryScope
    var tree: FolderTree
    /// What a tag shelf or a smart shelf looks for.
    var rule: TagRule?
    /// The notebooks a search found; nil when nothing is searched for.
    var matches: Set<UUID>?
    var sort: LibrarySortOrder
    var reversed = false

    /// A folder shows what is in it and in the folders inside it.
    func shown(_ records: [NotebookRecord]) -> [NotebookRecord] {
        let inside: Set<UUID> = if case .folder(let id) = scope { tree.subtree(id) } else { [] }
        let scoped = records.filter { record in
            switch scope {
            case .all: !record.isTrashed
            case .favorites: !record.isTrashed && record.isFavorite
            case .trash: record.isTrashed
            case .folder: !record.isTrashed && record.folder.map { inside.contains($0.id) } ?? false
            case .tag, .smart: !record.isTrashed && rule?.matches(notebook: record.tags) == true
            }
        }
        let searched = matches.map { found in scoped.filter { found.contains($0.id) } } ?? scoped
        return searched.sorted(by: sort, reversed: reversed)
    }

    /// Select All takes what is shown, and nothing the scope or the search leaves out.
    func selectingAll(_ records: [NotebookRecord]) -> Set<UUID> { Set(shown(records).map(\.id)) }
}

/// Over the list: the orders it can be sorted by, as tabs, and which way round beside them.
struct ShelfListSort: View {
    @Binding var sort: LibrarySortOrder
    @Binding var reversed: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.x3) {
                Text("Sort").metaStyle(.footnote).accessibilityHidden(true)
                tabs
                order(worded: true)
            }
            HStack(spacing: Space.x3) {
                tabs
                order(worded: true)
            }
            HStack(spacing: Space.x3) {
                tabs
                order(worded: false)
            }
            // A phone's width: the tabs close up before any name has to break.
            HStack(spacing: Space.x2) {
                picker(padding: Space.x2).fixedSize()
                order(worded: false)
            }
            // Measured at its names' own width, so it is only chosen where none of them breaks, then spans the row.
            VStack(alignment: .leading, spacing: Space.x2) {
                picker(padding: Space.x2)
                order(worded: true)
            }
            // Narrower still, the tabs take the whole width and their names wrap.
            VStack(alignment: .leading, spacing: Space.x2) {
                picker()
                order(worded: true)
            }
        }
    }

    private var tabs: some View { picker().fixedSize() }

    private func picker(padding: CGFloat = Space.x4) -> some View {
        OwlLunaSegmentedPicker("Sort By", selection: $sort, options: LibrarySortOrder.allCases,
                               identifier: { "library.list.sort.\($0.rawValue)" }, padding: padding) { Text($0.shortName) }
    }

    private func order(worded: Bool) -> some View {
        let name = sort.directionName(reversed: reversed)
        let up = (sort == .title) != reversed
        return Button { reversed.toggle() } label: {
            Label(name, systemImage: up ? "arrow.up" : "arrow.down")
                .labelStyle(OrderLabelStyle(worded: worded))
        }
        .buttonStyle(.owlLuna(.secondary, compact: true))
        .fixedSize()
        .accessibilityLabel(Text("Order"))
        .accessibilityValue(Text(name))
        .accessibilityIdentifier("library.list.order")
    }
}

private struct OrderLabelStyle: LabelStyle {
    let worded: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.x1) {
            configuration.icon
            if worded { configuration.title }
        }
    }
}

/// One notebook in the list, on the paper as the shelves are: its cover, its title in the display face, pages and the
/// last change in small caps, and its folder and tags beside it where there is room or under it where there is not.
struct NotebookCatalogueRow: View {
    let record: NotebookRecord
    let showsFolder: Bool
    let showsSide: Bool
    let isSelected: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let coverWidth: CGFloat = 44
    static let titleMinimum: CGFloat = 240
    static let sideWidth: CGFloat = 300
    /// The cover, the gaps and the row's own margins, which don't grow with the text.
    static let fixed: CGFloat = coverWidth + Space.x4 * 2 + Space.x2 * 2

    /// Folder and tags take a column of their own when the title keeps its room beside it.
    static func showsSide(width: CGFloat, scale: CGFloat, isAccessibilitySize: Bool) -> Bool {
        !isAccessibilitySize && width >= fixed + (titleMinimum + sideWidth) * scale
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.x4) {
                RecordCover(record: record, width: CoverWidth.row, showsShadow: false)
                    .frame(width: min(Self.coverWidth * scale, CoverWidth.row))
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected { SelectionBox(isSelected: true).offset(x: Space.x2, y: Space.x2) }
                    }
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(record.title.orUntitled)
                        .displayFont(20, relativeTo: .body)
                        .foregroundStyle(Color.ink)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    Text(record.metaLine).metaStyle(.footnote)
                    UploadMark(id: record.id)
                    if !showsSide { filing }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsSide {
                    filing.frame(width: Self.sideWidth * scale, alignment: .leading)
                }
            }
        }
        .buttonStyle(CatalogueRowStyle(isSelected: isSelected))
        .overlay(alignment: .bottom) { ShelfRule() }
        .hoverEffect(.highlight)
    }

    private var filing: some View {
        NotebookFiling.of(record, showsFolder: showsFolder, folderWidth: showsSide ? 120 * scale : nil)
    }
}

/// Where a notebook is filed: its folder's spine and name, then its tags as paper labels, wrapping as they need.
struct NotebookFiling: View {
    let folder: FolderRecord?
    let tags: [String]
    var folderWidth: CGFloat?

    /// A notebook's filing, when it has a folder to show or any tags.
    @ViewBuilder
    static func of(_ record: NotebookRecord, showsFolder: Bool, folderWidth: CGFloat? = nil) -> some View {
        let folder = showsFolder ? record.folder : nil
        if folder != nil || !record.tags.isEmpty {
            NotebookFiling(folder: folder, tags: record.tags, folderWidth: folderWidth)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.x3) {
            if let folder {
                HStack(spacing: Space.x2) {
                    SpineChip(cloth: folder.cloth).scaleEffect(0.8)
                    Text(folder.name).font(.subheadline).foregroundStyle(Color.textSecondary)
                }
                .frame(width: folderWidth, alignment: .leading)
                .frame(minHeight: 32)
            }
            if !tags.isEmpty {
                FlowLayout(spacing: Space.x2) {
                    ForEach(tags, id: \.self) { TagChip(name: $0) }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A row is touched across its whole width and darkens under the finger. Chosen, it is stitched in mustard, as a
/// chosen cover is on the shelf.
private struct CatalogueRowStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Space.x2)
            .padding(.vertical, Space.x3)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background { if configuration.isPressed { Color.well } }
            .overlay {
                if isSelected {
                    RoundedRectangle.track
                        .strokeBorder(Color.mustard, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(.vertical, 3)
                }
            }
            .contentShape(Rectangle())
    }
}

/// A run of rows on one board, ruled apart in ink under a well band naming the run, as a ledger is.
struct ShelfListBoard<Rows: View>: View {
    var title: String?
    var cloth: ClothColor?
    @ViewBuilder var rows: Rows

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: Space.x2) {
                    if let cloth { SpineChip(cloth: cloth).scaleEffect(0.7) }
                    Text(title)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Space.x3)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.well)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            rows
        }
        .clipShape(RoundedRectangle.plate)
        .plate(in: RoundedRectangle.plate, fill: .board)
    }
}

/// One notebook in the ledger the shelf becomes at the accessibility text sizes: its cover, growing with the text,
/// its title, pages and last change, then its folder and tags.
struct NotebookLedgerRow: View {
    let record: NotebookRecord
    let showsFolder: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var coverWidth: CGFloat = 32

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.x3) {
                if isSelecting { SelectionBox(isSelected: isSelected) }
                RecordCover(record: record, width: CoverWidth.row, showsShadow: false)
                    .frame(width: min(coverWidth, CoverWidth.row))
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(record.title.orUntitled)
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                    Text(record.metaLine)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Color.textSecondary)
                    UploadMark(id: record.id)
                    NotebookFiling.of(record, showsFolder: showsFolder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(ShelfListRowStyle(isSelected: isSelected))
        .overlay(alignment: .top) { ShelfRule() }
        .hoverEffect(.highlight)
    }
}

/// A row is touched across its whole width and darkens under the finger. Chosen, it has a mustard edge.
struct ShelfListRowStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Space.x3)
            .padding(.vertical, Space.x2)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background { if configuration.isPressed || isSelected { Color.well } }
            .overlay(alignment: .leading) { if isSelected { Rectangle().fill(Color.mustard).frame(width: 3) } }
            .contentShape(Rectangle())
    }
}

/// The ink rule between rows.
struct ShelfRule: View {
    var body: some View {
        Rectangle().fill(Color.hairline).frame(height: 1).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A square box, ticked in mustard when its row is chosen: never colour alone.
private struct SelectionBox: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle.thumb
                .fill(isSelected ? Color.mustard : Color.clear)
            RoundedRectangle.thumb
                .strokeBorder(isSelected ? Color.mustard : Color.textSecondary, lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Color.onMustard)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

extension LibrarySortOrder {
    /// The order's name on the list's tabs, where four must fit side by side.
    var shortName: String {
        switch self {
        case .opened: String(localized: "Opened")
        case .modified: String(localized: "Edited")
        case .created: String(localized: "Created")
        case .title: String(localized: "Title")
        }
    }
}

/// The chosen notebooks the tag sheet is open over, with the tags all of them carry and those only some do.
struct SelectionTags: Identifiable {
    let id = UUID()
    let ids: [UUID]
    let common: [String]
    let mixed: [String]
}
