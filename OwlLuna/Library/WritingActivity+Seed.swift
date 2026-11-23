#if DEBUG
import Foundation

extension WritingActivity {
    /// A lived-in log for screenshots and audits: three days this week, a scatter of earlier days, a month and a year ago, and
    /// cards studied on some days of this week, one of them with no writing.
    static func seedForTests(root: StorageRoot) async {
        guard !FileManager.default.fileExists(atPath: root.activityFile.path(percentEncoded: false)) else { return }
        var notebooks: [(title: String, id: UUID, pages: [UUID])] = []
        for id in root.packageIDs() {
            guard let manifest = try? await NotebookPackage(root: root, id: id).readManifest().manifest,
                  manifest.library.deletedAt == nil, !manifest.pages.isEmpty else { continue }
            notebooks.append((manifest.title, id, manifest.pages.map(\.id)))
        }
        guard !notebooks.isEmpty else { return }
        notebooks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let calendar = Calendar.current
        let now = Date.now
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now) ?? now }
        func key(_ date: Date) -> String { ActivityFile.dayKey(for: date, calendar: calendar) }

        var cursor = 0
        func pages(_ count: Int) -> [UUID: Set<UUID>] {
            var chosen: [UUID: Set<UUID>] = [:]
            var remaining = count
            while remaining > 0, chosen.count < notebooks.count {
                let notebook = notebooks[cursor % notebooks.count]
                cursor += 1
                let taken = notebook.pages.prefix(remaining)
                chosen[notebook.id, default: []].formUnion(taken)
                remaining -= taken.count
            }
            return chosen
        }

        let thisWeek = [0, -1, -3, -2].filter { day($0) >= weekStart }.prefix(3)
        let earlier = [-4, -6, -7, -8, -11, -13, -15, -16, -20, -22, -23, -27, -31, -34, -38, -43].filter { day($0) < weekStart }
        let counts = [2, 1, 4, 1, 3, 6, 2, 1, 5, 2, 3, 1, 2, 4, 1, 2, 3, 1, 2]
        var log = ActivityLog()
        for (index, offset) in (Array(thisWeek) + earlier).enumerated() {
            log.days[key(day(offset))] = DayActivity(notebooks: pages(counts[index % counts.count]))
        }
        if let deleted = [-18, -25, -36].first(where: { day($0) < weekStart && log.days[key(day($0))] == nil }) {
            log.days[key(day(deleted))] = DayActivity(otherPages: 2)
        }
        for date in [calendar.date(byAdding: .month, value: -1, to: now), calendar.date(byAdding: .year, value: -1, to: now)].compactMap({ $0 }) {
            var entry = log.days[key(date)] ?? DayActivity()
            for notebook in notebooks.prefix(2) { entry.notebooks[notebook.id, default: []].insert(notebook.pages[0]) }
            log.days[key(date)] = entry
        }
        for (offset, cards) in [(-1, 6), (-2, 3), (-4, 9)] where day(offset) >= weekStart {
            var entry = log.days[key(day(offset))] ?? DayActivity()
            entry.cardsStudied = cards
            log.days[key(day(offset))] = entry
        }
        try? ActivityFile.write(log, to: root)
    }
}
#endif
