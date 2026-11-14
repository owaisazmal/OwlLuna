import SwiftUI

struct CalendarChoice: Hashable {
    let notebookID: UUID
    let pageID: UUID
}

/// A month of writing laid out like a printed diary. Each day opens to the pages written on it.
struct WritingCalendarView: View {
    let onChoose: (CalendarChoice) -> Void

    @Environment(WritingActivity.self) private var activity
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var selected: String?
    @State private var detail: DayDetail?
    @State private var forward = true
    @State private var width: CGFloat = 0
    @State private var detailRequest = 0

    private var calendar: Calendar { .current }
    private var log: ActivityLog { activity.log }
    private var todayKey: String { key(.now) }
    private func key(_ date: Date) -> String { ActivityFile.dayKey(for: date, calendar: calendar) }
    private func pageCount(on dayKey: String) -> Int { log.days[dayKey]?.pageCount ?? 0 }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .id(key(month))
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 28 : -28)),
                                                                           removal: .opacity))
                        .padding(Space.x6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                }
                .accessibilityIdentifier("writing.calendar")
                .onChange(of: detailRequest) {
                    withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) { proxy.scrollTo("day-detail", anchor: .top) }
                }
            }
            .background(Color.surface)
            .navigationTitle("Writing Calendar")
            .barGround(.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BarGroup {
                        Button { step(-1) } label: { Label("Previous Month", systemImage: "chevron.backward") }
                            .keyboardShortcut("[", modifiers: .command)
                            .disabled(!canGoBack)
                        Button { step(1) } label: { Label("Next Month", systemImage: "chevron.forward") }
                            .keyboardShortcut("]", modifiers: .command)
                            .disabled(!canGoForward)
                    }
                }
                .boardBackground()
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.buttonStyle(.owlLuna(.primary, inBar: true))
                }
                .boardBackground()
            }
            .onAppear { if selected == nil { selected = defaultSelection(in: month) } }
            .task(id: selected) { await loadDetail() }
        }
    }

    // MARK: Layout

    private var content: some View {
        let sideBySide = width >= 860 && !dynamicTypeSize.isAccessibilitySize
        let layout = sideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: Space.x8))
                                : AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x8))
        return VStack(alignment: .leading, spacing: Space.x6) {
            monthHeader
            layout {
                VStack(alignment: .leading, spacing: Space.x6) {
                    if dynamicTypeSize.isAccessibilitySize { writtenDays } else { grid }
                    if sideBySide { yearFooter }
                }
                .frame(maxWidth: sideBySide ? width * 0.58 : .infinity)
                dayDetail.frame(maxWidth: .infinity, alignment: .leading).id("day-detail")
            }
            if !sideBySide { yearFooter }
        }
    }

    private var monthHeader: some View {
        let interval = calendar.dateInterval(of: .month, for: month) ?? DateInterval(start: month, duration: 0)
        let totals = ActivityStats.totals(in: interval, log: log, calendar: calendar)
        return VStack(alignment: .leading, spacing: Space.x1) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .displayFont(34, relativeTo: .largeTitle)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Text(totals.pages == 0 ? String(localized: "A quiet month") : "\(pagesText(totals.pages)) · \(daysText(totals.days))")
                .metaStyle(.footnote)
        }
    }

    private var grid: some View {
        let cells = ActivityStats.monthGrid(containing: month, calendar: calendar)
        let symbols = calendar.shortStandaloneWeekdaySymbols
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
            ForEach(0..<7, id: \.self) { column in
                Text(symbols[(column + calendar.firstWeekday - 1) % 7])
                    .metaStyle(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.x2)
                    .padding(.bottom, Space.x2)
                    .accessibilityHidden(true)
            }
            ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                cell(date)
                    .overlay(alignment: .top) { Color.hairline.frame(height: 1) }
            }
        }
    }

    @ViewBuilder
    private func cell(_ date: Date?) -> some View {
        if let date {
            let dayKey = key(date)
            let pages = pageCount(on: dayKey)
            let isSelected = selected == dayKey
            let label = HStack(alignment: .center, spacing: Space.x2) {
                numeral(date, isToday: dayKey == todayKey, isFuture: dayKey > todayKey)
                if pages > 0 { InkBlot(seed: calendar.component(.day, from: date)).fill(Color.ink).frame(width: blotSize(pages), height: blotSize(pages)) }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            .padding(.horizontal, Space.x2)
            .padding(.top, Space.x2)
            if dayKey > todayKey {
                label.accessibilityElement(children: .ignore).accessibilityLabel(date.formatted(.dayName))
            } else {
                Button { select(dayKey) } label: {
                    label
                        .overlay {
                            if isSelected { RoundedRectangle.plate.strokeBorder(Color.accentColor, lineWidth: 2).padding(3) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel(dayLabel(date, pages: pages))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        } else {
            Color.clear.frame(minHeight: 56).accessibilityHidden(true)
        }
    }

    private func numeral(_ date: Date, isToday: Bool, isFuture: Bool) -> some View {
        Text(date.formatted(.dateTime.day()))
            .font(isToday ? .body.weight(.bold).monospacedDigit() : .body.monospacedDigit())
            .underline(isToday)
            .foregroundStyle(isFuture ? Color.textSecondary : Color.ink)
            .lineLimit(1)
            .fixedSize()
    }

    private func blotSize(_ pages: Int) -> CGFloat {
        switch pages {
        case 1: 8
        case 2...4: 12
        default: 16
        }
    }

    /// At accessibility sizes the grid becomes a list of the days with writing.
    private var writtenDays: some View {
        let days = ActivityStats.monthGrid(containing: month, calendar: calendar).compactMap { $0 }
            .filter { pageCount(on: key($0)) > 0 }
        return VStack(alignment: .leading, spacing: Space.x3) {
            ForEach(days, id: \.self) { date in
                let dayKey = key(date)
                let pages = pageCount(on: dayKey)
                Button {
                    select(dayKey)
                    detailRequest += 1
                } label: {
                    VStack(alignment: .leading, spacing: Space.x1) {
                        Text(date.formatted(.dayName)).font(.headline).foregroundStyle(Color.ink)
                        Text(pagesText(pages)).font(.subheadline).foregroundStyle(Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.x4)
                    .background(Color.paper, in: RoundedRectangle.plate)
                    .overlay {
                        if selected == dayKey { RoundedRectangle.plate.strokeBorder(Color.accentColor, lineWidth: 2) }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dayLabel(date, pages: pages))
                .accessibilityAddTraits(selected == dayKey ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    // MARK: The selected day

    @ViewBuilder
    private var dayDetail: some View {
        if let selected, let date = ActivityFile.date(forKey: selected, calendar: calendar) {
            let totals = ActivityStats.totals(for: selected, in: log)
            let resolved = detail?.key == selected ? detail : nil
            VStack(alignment: .leading, spacing: Space.x5) {
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(date.formatted(.dayName))
                        .displayFont(24, relativeTo: .title2)
                        .foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(summary(pages: totals.pages, notebooks: totals.notebooks)).metaStyle(.footnote)
                }
                if let resolved {
                    ForEach(resolved.notebooks) { notebook in
                        VStack(alignment: .leading, spacing: Space.x3) {
                            HStack(spacing: Space.x2) {
                                SpineChip(cloth: notebook.cloth)
                                Text(notebook.title).font(.headline).foregroundStyle(Color.ink)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 132 : 80), spacing: Space.x4, alignment: .top)],
                                      alignment: .leading, spacing: Space.x4) {
                                ForEach(notebook.pages) { entry in
                                    CalendarPageCard(notebookID: notebook.id, title: notebook.title, entry: entry, isLocked: notebook.isLocked) {
                                        onChoose(CalendarChoice(notebookID: notebook.id, pageID: entry.page.id))
                                    }
                                }
                            }
                        }
                    }
                    if let note = missingNote(total: totals.pages, shown: resolved.shownPages, key: selected) {
                        Text(note).font(.subheadline).foregroundStyle(Color.textSecondary)
                    }
                }
            }
            .transition(.opacity)
        } else {
            Text("Choose a day to see what you wrote.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var yearFooter: some View {
        let year = calendar.component(.year, from: month)
        let interval = calendar.dateInterval(of: .year, for: month)
        let totals = ActivityStats.yearTotals(year: year, in: log, calendar: calendar)
        let run = ActivityStats.longestRun(in: log, calendar: calendar, within: interval)
        let name = year == calendar.component(.year, from: .now) ? String(localized: "This year") : month.formatted(.dateTime.year())
        var line = String(localized: "\(name): \(pagesText(totals.pages)) on \(daysText(totals.days))")
        if run > 1 { line += " · " + String(localized: "longest run \(run) days") }
        return VStack(alignment: .leading, spacing: Space.x3) {
            if totals.pages > 0 {
                Color.hairline.frame(height: 1).accessibilityHidden(true)
                Text(line).metaStyle(.footnote)
            }
        }
    }

    // MARK: Words

    private func pagesText(_ pages: Int) -> String {
        String(localized: "\(pages) pages")
    }

    private func daysText(_ days: Int) -> String {
        String(localized: "\(days) days")
    }

    private func summary(pages: Int, notebooks: Int) -> String {
        switch (pages, notebooks) {
        case (0, _): String(localized: "Nothing written")
        case (_, 0): pagesText(pages)
        default: String(localized: "\(pagesText(pages)) in \(notebooks) notebooks")
        }
    }

    private func dayLabel(_ date: Date, pages: Int) -> String {
        let name = date.formatted(.dayName)
        return pages == 0 ? String(localized: "\(name), nothing written") : "\(name), \(pagesText(pages))"
    }

    private func missingNote(total: Int, shown: Int, key: String) -> String? {
        let missing = total - shown
        guard missing > 0 else { return nil }
        if shown == 0 {
            return key < ActivityFile.compactionCutoff(now: .now, calendar: calendar)
                ? String(localized: "Pages from this long ago are kept as a count only.")
                : String(localized: "Written in notebooks since deleted.")
        }
        return String(localized: "\(missing) more pages have since been deleted.")
    }

    // MARK: Navigation

    private var currentMonth: Date { calendar.dateInterval(of: .month, for: .now)?.start ?? .now }

    private var earliestMonth: Date {
        let first = log.days.filter { $0.value.pageCount > 0 }.keys.min().flatMap { ActivityFile.date(forKey: $0, calendar: calendar) }
        return first.flatMap { calendar.dateInterval(of: .month, for: $0)?.start } ?? currentMonth
    }

    private var canGoBack: Bool { month > earliestMonth }
    private var canGoForward: Bool { month < currentMonth }

    private func step(_ months: Int) {
        guard let target = calendar.date(byAdding: .month, value: months, to: month) else { return }
        forward = months > 0
        withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) {
            month = target
            selected = defaultSelection(in: target)
        }
    }

    private func select(_ dayKey: String) {
        withAnimation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion)) { selected = dayKey }
    }

    /// The last day with writing in the month, or today in the current month.
    private func defaultSelection(in month: Date) -> String? {
        let keys = ActivityStats.monthGrid(containing: month, calendar: calendar).compactMap { $0.map(key) }
        let written = keys.filter { $0 <= todayKey && pageCount(on: $0) > 0 }
        return written.max() ?? (keys.contains(todayKey) ? todayKey : nil)
    }

    private func loadDetail() async {
        guard let selected, let day = log.days[selected] else { detail = nil; return }
        let notebooks = await Self.resolve(day, root: store.root)
        guard !Task.isCancelled else { return }
        withAnimation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion)) { detail = DayDetail(key: selected, notebooks: notebooks) }
    }

    /// Reads manifests off the main thread, skipping trashed notebooks and missing pages; duplicates share page IDs, so match both.
    nonisolated private static func resolve(_ day: DayActivity, root: StorageRoot) async -> [DayDetail.Notebook] {
        var notebooks: [DayDetail.Notebook] = []
        for (id, pageIDs) in day.notebooks {
            if Task.isCancelled { break }
            guard let manifest = try? await NotebookPackage(root: root, id: id).readManifest().manifest,
                  manifest.library.deletedAt == nil else { continue }
            let entries = manifest.pages.enumerated().filter { pageIDs.contains($0.element.id) }.map { DayDetail.Entry(index: $0.offset, page: $0.element) }
            if !entries.isEmpty {
                notebooks.append(DayDetail.Notebook(id: id, title: manifest.title, cloth: manifest.cover.cloth, pages: entries, isLocked: manifest.library.isLocked))
            }
        }
        return notebooks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

private struct DayDetail: Equatable {
    struct Entry: Identifiable, Equatable {
        let index: Int
        let page: NotebookPage
        var id: UUID { page.id }
    }

    struct Notebook: Identifiable, Equatable {
        let id: UUID
        let title: String
        let cloth: ClothColor
        let pages: [Entry]
        var isLocked = false
    }

    let key: String
    let notebooks: [Notebook]
    var shownPages: Int { notebooks.reduce(0) { $0 + $1.pages.count } }
}

/// A page's thumbnail as a button, with its number beneath and outside it: the audit reads text beside a light page as low contrast.
private struct CalendarPageCard: View {
    let notebookID: UUID
    let title: String
    let entry: DayDetail.Entry
    /// A locked notebook's pages are listed, but what is on them isn't shown.
    var isLocked = false
    let action: () -> Void
    @Environment(LibraryStore.self) private var store
    @State private var image: UIImage?
    @PaperNight private var night

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Button(action: action) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().transition(.opacity)
                    } else {
                        Rectangle().fill(Color(uiColor: entry.page.paperShown(night: night)))
                    }
                }
                .aspectRatio(entry.page.shownSize.width / max(entry.page.shownSize.height, 1), contentMode: .fit)
                .overlay { Rectangle().strokeBorder(Color.hairline, lineWidth: 1) }
                .overlay { if isLocked { LockBadge(diameter: 28) } }
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.lift)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(title), page \(entry.index + 1)"))
            .accessibilityHint(Text("Opens the notebook at this page"))
            .accessibilityAddTraits(.isButton)
            Text("Page \(entry.index + 1)")
                .metaStyle(.caption)
                .accessibilityHidden(true)
                .onTapGesture(perform: action)
        }
        .task(id: "\(entry.page.thumbnailKey)|\(isLocked)|\(night)") {
            guard !isLocked else { return image = nil }
            let loaded = await PageThumbnailer.thumbnail(package: NotebookPackage(root: store.root, id: notebookID), page: entry.page, night: night)
            withAnimation(Motion.quick) { image = loaded }
        }
    }
}

/// An ink drop: a round blot with a slightly uneven edge, different for each day.
struct InkBlot: Shape {
    let seed: Int

    func path(in rect: CGRect) -> Path {
        let reach: [CGFloat] = [1, 0.86, 0.97, 0.9, 1, 0.84, 0.95, 0.88]
        let radius = min(rect.width, rect.height) / 2
        let turn = Double(seed % 7) * 0.4
        let points = reach.indices.map { index -> CGPoint in
            let angle = Double(index) / Double(reach.count) * 2 * .pi + turn
            let distance = radius * reach[(index + seed) % reach.count]
            return CGPoint(x: rect.midX + distance * cos(angle), y: rect.midY + distance * sin(angle))
        }
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var path = Path()
        path.move(to: middle(points[points.count - 1], points[0]))
        for index in points.indices {
            path.addQuadCurve(to: middle(points[index], points[(index + 1) % points.count]), control: points[index])
        }
        path.closeSubpath()
        return path
    }
}
