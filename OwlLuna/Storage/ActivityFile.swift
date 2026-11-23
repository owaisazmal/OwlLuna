import Foundation

/// One day of writing: the pages written in each notebook, plus a bare count for pages no longer listed by ID.
struct DayActivity: Sendable, Hashable {
    static let cardsStudiedKey = "cardsStudied"

    var notebooks: [UUID: Set<UUID>] = [:]
    var otherPages = 0
    var extra: [String: JSONValue] = [:]

    var pageCount: Int { notebooks.values.reduce(otherPages) { $0 + $1.count } }

    /// Flashcards answered on this day. Kept in `extra`, so a build that doesn't know it writes it back as it found it.
    var cardsStudied: Int {
        get { max(extra[Self.cardsStudiedKey]?.intValue ?? 0, 0) }
        set { extra[Self.cardsStudiedKey] = newValue > 0 ? .number(Double(newValue)) : nil }
    }
}

struct ActivityLog: Sendable, Hashable {
    var version = ActivityFile.currentVersion
    var days: [String: DayActivity] = [:]
    var extra: [String: JSONValue] = [:]
    var undecoded: [String: UndecodedField] = [:]
    var opaqueDays: [String: JSONValue] = [:]

    /// A log from a newer build is read but never rewritten, like a newer manifest.
    var isNewerThanSupported: Bool { version > ActivityFile.currentVersion }

    var hasPages: Bool { days.values.contains { $0.pageCount > 0 } }

    var hasStudy: Bool { days.values.contains { $0.cardsStudied > 0 } }

    /// Days recorded before the file was read are kept alongside what it held.
    mutating func merge(_ other: ActivityLog) {
        for (key, day) in other.days {
            var merged = days[key] ?? DayActivity(extra: day.extra)
            for (notebook, pages) in day.notebooks { merged.notebooks[notebook, default: []].formUnion(pages) }
            merged.otherPages = max(merged.otherPages, day.otherPages)
            merged.cardsStudied = max(merged.cardsStudied, day.cardsStudied)
            days[key] = merged
            opaqueDays[key] = nil
        }
    }

    /// Days before `cutoff` (a day key) keep only their page count, and the cards studied on them.
    mutating func compact(before cutoff: String) {
        for (key, day) in days where key < cutoff && !day.notebooks.isEmpty {
            days[key] = DayActivity(otherPages: day.pageCount, extra: day.extra)
        }
    }
}

/// `Library/activity.json`, the private writing log: which pages were written on which day, and how many cards were studied. Never synced; a backup holds it.
enum ActivityFile {
    static let currentVersion = 1
    static let detailedDays = 400

    static func read(_ root: StorageRoot) -> ActivityLog {
        Quarantine.read(root.activityFile, decode) ?? ActivityLog()
    }

    static func write(_ log: ActivityLog, to root: StorageRoot, now: Date = .now, calendar: Calendar = .current) throws {
        var log = log
        log.compact(before: compactionCutoff(now: now, calendar: calendar))
        try root.writeLibraryFile(root.activityFile) { try encode(log) }
    }

    static func compactionCutoff(now: Date, calendar: Calendar) -> String {
        dayKey(for: calendar.date(byAdding: .day, value: -detailedDays, to: now) ?? now, calendar: calendar)
    }

    /// Nil when the file isn't a JSON object or its days aren't one; a day this build can't read is kept verbatim.
    static func decode(_ data: Data) -> ActivityLog? {
        guard let object = (try? JSONValue.parse(data))?.objectValue else { return nil }
        var reader = ObjectReader(object)
        var log = ActivityLog()
        log.version = reader.int("version", default: currentVersion)
        if let raw = reader.take("days"), raw != .null {
            guard let days = raw.objectValue else { return nil }
            for (key, value) in days {
                if date(forKey: key, calendar: gregorian(.gmt)) != nil, let day = decodeDay(value) {
                    log.days[key] = day
                } else {
                    log.opaqueDays[key] = value
                }
            }
        }
        log.extra = reader.remaining
        log.undecoded = reader.undecoded
        return log
    }

    static func encode(_ log: ActivityLog) throws -> Data {
        var days = log.opaqueDays
        for (key, day) in log.days { days[key] = encodeDay(day) }
        var writer = ObjectWriter(base: log.extra, undecoded: log.undecoded)
        writer.set("version", .number(Double(log.version)))
        writer.set("days", .object(days))
        return try JSONValue.object(writer.values).serialized()
    }

    private static func decodeDay(_ raw: JSONValue) -> DayActivity? {
        guard let object = raw.objectValue else { return nil }
        var reader = ObjectReader(object)
        var day = DayActivity()
        if let notebooks = reader.take("notebooks"), notebooks != .null {
            guard let entries = notebooks.objectValue else { return nil }
            for (key, value) in entries {
                guard let id = UUID(uuidString: key), let pages = value.arrayValue else { return nil }
                let ids = pages.compactMap { $0.uuidValue }
                guard ids.count == pages.count else { return nil }
                day.notebooks[id, default: []].formUnion(ids)
            }
        }
        if let other = reader.take("otherPages"), other != .null {
            guard let count = other.intValue, count >= 0 else { return nil }
            day.otherPages = count
        }
        day.extra = reader.remaining
        return day
    }

    private static func encodeDay(_ day: DayActivity) -> JSONValue {
        var values = day.extra
        values["notebooks"] = .object(Dictionary(uniqueKeysWithValues: day.notebooks.map { id, pages in
            (id.uuidString, JSONValue.array(pages.map(\.uuidString).sorted().map(JSONValue.string)))
        }))
        values["otherPages"] = .number(Double(day.otherPages))
        return .object(values)
    }

    // MARK: Day keys

    /// "2026-09-29" for the day `date` falls on in the calendar's time zone. Always Gregorian, whatever the user's calendar.
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        WidgetSnapshot.dayKey(for: date, calendar: calendar)
    }

    /// The start of the day a key names, or nil for anything that isn't a real date.
    static func date(forKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard key.count == 10, parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        let reference = gregorian(calendar.timeZone)
        guard let date = reference.date(from: DateComponents(year: year, month: month, day: day)),
              dayKey(for: date, calendar: reference) == key else { return nil }
        return date
    }

    static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
