import SwiftUI

/// Rows of covers that fill the shelf's width with even gaps.
struct ShelfMetrics: Equatable {
    let columns: Int
    let coverWidth: CGFloat
    let gap: CGFloat

    var renderWidth: CGFloat { Self.renderWidth(for: coverWidth) }

    /// The cached cover width a cover of this size is drawn from.
    static func renderWidth(for coverWidth: CGFloat) -> CGFloat {
        coverWidth <= 180 ? CoverWidth.shelf : CoverWidth.spread
    }

    /// A single column takes the whole width; from two up, covers stay between 136 and 232 pt where they can.
    static func fit(width: CGFloat, gap: CGFloat = Space.x6, target: CGFloat = 176) -> ShelfMetrics {
        func cover(_ columns: Int) -> CGFloat { floor((width - gap * CGFloat(columns - 1)) / CGFloat(columns)) }
        guard width >= 280 else { return ShelfMetrics(columns: 1, coverWidth: max(1, floor(width)), gap: gap) }
        var columns = max(2, Int(((width + gap) / (target + gap)).rounded()))
        while cover(columns) > 232 { columns += 1 }
        while cover(columns) < 136, columns > 2 { columns -= 1 }
        return ShelfMetrics(columns: columns, coverWidth: cover(columns), gap: gap)
    }
}

/// The lip a row of covers stands on: a surface band with a hairline top edge and a baked shadow beneath.
struct ShelfLedge: View {
    static let height: CGFloat = 5
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Color.surface
                .frame(height: Self.height)
                .overlay(alignment: .top) { Color.hairline.frame(height: 1) }
            LinearGradient(colors: [.black.opacity(colorScheme == .dark ? 0.35 : 0.07), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 8)
        }
        .accessibilityHidden(true)
    }
}

/// One row of a shelf, standing on a ledge that overhangs it by 8 pt on each side.
struct ShelfRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let metrics: ShelfMetrics
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        HStack(alignment: .top, spacing: metrics.gap) {
            ForEach(items) { item in
                content(item).frame(width: metrics.coverWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            ShelfLedge()
                .padding(.horizontal, -8)
                .offset(y: metrics.coverWidth * 4 / 3)
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

extension Array where Element: Identifiable {
    /// A row is identified by everything on it: a lazy stack keeps a row with an unchanged ID as it was.
    var rowID: String { map { "\($0.id)" }.joined(separator: ",") }
}

/// Recency shelves: today, yesterday, this week, earlier this month, then one per month.
enum ShelfGrouping {
    static func bucket(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        if calendar.dateInterval(of: .weekOfYear, for: now)?.contains(date) == true { return "week" }
        if calendar.dateInterval(of: .month, for: now)?.contains(date) == true { return "month" }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)"
    }

    /// Favourites lead the shelf they stand on, and both they and the rest keep the order shown.
    /// Not in Favourites itself, where every notebook is one, nor in Recently Deleted.
    static func favouritesFirst(_ records: [NotebookRecord], in scope: LibraryScope) -> [NotebookRecord] {
        switch scope {
        case .favorites, .trash: records
        case .all, .folder, .tag, .smart: records.filter(\.isFavorite) + records.filter { !$0.isFavorite }
        }
    }
}
