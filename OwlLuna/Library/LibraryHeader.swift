import SwiftUI

/// The library's heading: today's date over the Fraunces title and summary, with this week's writing beside or below.
struct LibraryHeader: View {
    let title: String
    let summary: String
    let showsRhythm: Bool
    let onOpenPage: (NotebookRecord, UUID) -> Void

    @Environment(WritingActivity.self) private var activity
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0

    var body: some View {
        let wide = width >= 600 && !dynamicTypeSize.isAccessibilitySize
        let layout = wide ? AnyLayout(HStackLayout(alignment: .bottom, spacing: Space.x8))
                          : AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x5))
        layout {
            VStack(alignment: .leading, spacing: Space.x1) {
                eyebrow
                Text(title)
                    .displayFont(40, relativeTo: .largeTitle)
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(summary).metaStyle(.footnote)
            }
            .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
            if showsRhythm, activity.isEnabled, activity.hasHistory {
                WeekStrip(week: activity.week, onOpenPage: onOpenPage)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var eyebrow: some View {
        TimelineView(.periodic(from: .now, by: 900)) { context in
            Text(context.date.formatted(.dayName))
                .metaStyle(.footnote)
                .onChange(of: Calendar.current.startOfDay(for: context.date)) { activity.refresh(now: context.date) }
        }
    }
}

/// Seven small sheets for this week, inked on the days you wrote, with today underlined. Opens the writing calendar.
struct WeekStrip: View {
    let week: WeekSummary
    let onOpenPage: (NotebookRecord, UUID) -> Void
    @State private var showingCalendar = false

    var body: some View {
        Button { showingCalendar = true } label: {
            HStack(alignment: .bottom, spacing: Space.x4) {
                HStack(spacing: Space.x2) {
                    ForEach(Array(week.days.enumerated()), id: \.element.date) { index, day in
                        VStack(spacing: Space.x1) {
                            DaySheet(pages: day.pages, seed: index)
                            letter(for: day)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(week.pagesLine)
                        .font(.footnote.weight(.semibold).smallCaps().monospacedDigit())
                        .tracking(0.6)
                        .foregroundStyle(Color.ink)
                    if week.pageCount > 0 { Text(week.daysLine).metaStyle(.caption) }
                }
                .fixedSize()
                .padding(.bottom, 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(week.accessibilityLabel)
        .accessibilityHint(Text("Opens your writing calendar"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("writing.week")
        .writingCalendar(isPresented: $showingCalendar, onOpenPage: onOpenPage)
    }

    private func letter(for day: WeekSummary.Day) -> some View {
        let calendar = Calendar.current
        let isToday = day.date == week.today
        return Text(calendar.veryShortStandaloneWeekdaySymbols[calendar.component(.weekday, from: day.date) - 1])
            .font(isToday ? .caption.weight(.heavy) : .caption.weight(.semibold))
            .underline(isToday)
            .foregroundStyle(isToday ? Color.ink : Color.textSecondary)
            .frame(width: DaySheet.size.width)
    }
}

/// A tiny page: plain paper with a hairline edge, or two or three short lines of ink on a day you wrote.
private struct DaySheet: View {
    static let size = CGSize(width: 24, height: 31)
    let pages: Int
    let seed: Int
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.surface)
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Color.hairline, lineWidth: 1) }
            .overlay {
                if pages > 0 {
                    InkLines(count: pages > 1 ? 3 : 2, seed: seed)
                        .stroke(Color.ink.opacity(contrast == .increased ? 1 : 0.72), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                        .padding(EdgeInsets(top: 7, leading: 5, bottom: 7, trailing: 5))
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .shadow(color: .black.opacity(pages > 0 ? 0.1 : 0.04), radius: 1, y: 1)
    }
}

/// Short, slightly wavering lines of handwriting, the last one shorter.
struct InkLines: Shape {
    let count: Int
    let seed: Int

    func path(in rect: CGRect) -> Path {
        let lengths: [CGFloat] = [1, 0.74, 0.9, 0.82, 0.66, 0.96, 0.78]
        let spacing = rect.height / 3
        var path = Path()
        for line in 0..<count {
            let y = rect.minY + spacing * (CGFloat(line) + 0.5)
            let length = rect.width * lengths[(seed * 3 + line) % lengths.count] * (line == count - 1 ? 0.6 : 1)
            let wobble: CGFloat = (seed + line).isMultiple(of: 2) ? 0.45 : -0.45
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addQuadCurve(to: CGPoint(x: rect.minX + length / 2, y: y), control: CGPoint(x: rect.minX + length / 4, y: y - wobble))
            path.addQuadCurve(to: CGPoint(x: rect.minX + length, y: y), control: CGPoint(x: rect.minX + length * 3 / 4, y: y + wobble))
        }
        return path
    }
}

/// This week as a row of the shelf's ledger at the accessibility sizes, where the strip would be.
struct WeekSummaryRow: View {
    let onOpenPage: (NotebookRecord, UUID) -> Void
    @Environment(WritingActivity.self) private var activity
    @State private var showingCalendar = false

    var body: some View {
        if activity.isEnabled, activity.hasHistory {
            Button { showingCalendar = true } label: {
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text("This week").eyebrowStyle(Color.accentColor)
                    Text(activity.week.headline).font(.headline).foregroundStyle(Color.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(activity.week.accessibilityLabel)
            .accessibilityHint(Text("Opens your writing calendar"))
            .accessibilityIdentifier("writing.week")
            .writingCalendar(isPresented: $showingCalendar, onOpenPage: onOpenPage)
        }
    }
}

extension WeekSummary {
    var pagesLine: String {
        pageCount == 0 ? String(localized: "A fresh week") : String(localized: "\(pageCount) pages")
    }

    var daysLine: String {
        String(localized: "this week · \(dayCount) days")
    }

    var headline: String {
        pageCount == 0 ? String(localized: "A fresh week") : String(localized: "\(pageCount) pages on \(dayCount) days")
    }

    var accessibilityLabel: String {
        guard pageCount > 0 else { return String(localized: "This week: no pages written") }
        let names = days.filter { $0.pages > 0 }.map { $0.date.formatted(.dateTime.weekday(.wide)) }.formatted(.list(type: .and))
        let pages = String(localized: "\(pageCount) pages")
        return String(localized: "This week: \(pages), on \(names)")
    }
}

extension View {
    /// Presents the writing calendar. A page chosen there opens once the sheet has gone.
    func writingCalendar(isPresented: Binding<Bool>, onOpenPage: @escaping (NotebookRecord, UUID) -> Void) -> some View {
        modifier(WritingCalendarPresenter(isPresented: isPresented, onOpenPage: onOpenPage))
    }
}

private struct WritingCalendarPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let onOpenPage: (NotebookRecord, UUID) -> Void
    @Environment(LibraryStore.self) private var store
    @State private var chosen: CalendarChoice?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: openChosen) {
            WritingCalendarView { choice in
                chosen = choice
                isPresented = false
            }
            .presentationCornerRadius(Radius.sheet)
            .appModels()
            .presentationSizing(.page)
        }
    }

    private func openChosen() {
        guard let choice = chosen else { return }
        chosen = nil
        if let record = store.record(choice.notebookID), !record.isTrashed { onOpenPage(record, choice.pageID) }
    }
}
