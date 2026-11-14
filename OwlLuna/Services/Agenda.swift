import Foundation
import EventKit

struct AgendaEvent: Sendable, Equatable {
    var title: String
    var start: Date
    var isAllDay = false
}

enum AgendaError: LocalizedError {
    case notAllowed

    var errorDescription: String? {
        (Device.isMac
            ? String(localized: "OwlLuna isn't allowed to read your calendar. Allow it in System Settings › Privacy & Security › Calendars.")
            : String(localized: "OwlLuna isn't allowed to read your calendar. Allow it in Settings › Privacy & Security › Calendars."))
    }
}

protocol CalendarReading: Sendable {
    /// The events of the day `date` falls on. Throws when the calendar may not be read.
    func events(on date: Date, calendar: Calendar) async throws -> [AgendaEvent]
}

/// Reads the iPad's calendars. The events are read on the device and only ever written onto a page.
struct DeviceCalendar: CalendarReading {
    func events(on date: Date, calendar: Calendar) async throws -> [AgendaEvent] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { throw AgendaError.notAllowed }
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { $0.status != .canceled }
            .map { AgendaEvent(title: $0.title ?? "", start: $0.startDate, isAllDay: $0.isAllDay) }
    }
}

#if DEBUG
/// `-fakeCalendar` stands this in for the iPad's calendars, which a test can't fill or be allowed to read.
struct ScriptedCalendar: CalendarReading {
    func events(on date: Date, calendar: Calendar) async throws -> [AgendaEvent] {
        let day = calendar.startOfDay(for: date)
        return [AgendaEvent(title: "Lab group", start: day.addingTimeInterval(13.5 * 3600)),
                AgendaEvent(title: "Library books due", start: day, isAllDay: true),
                AgendaEvent(title: "Lecture: Cell Biology", start: day.addingTimeInterval(9 * 3600))]
    }
}
#endif

/// Today's events, printed on a page as a text box: all-day events first, then the rest by the clock.
enum Agenda {
    static let limit = 10

    static var calendar: any CalendarReading {
        #if DEBUG
        if LaunchOptions.arguments.contains("-fakeCalendar") { return ScriptedCalendar() }
        #endif
        return DeviceCalendar()
    }

    static func ordered(_ events: [AgendaEvent]) -> [AgendaEvent] {
        events.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
    }

    /// One event to a line, under `heading` if there is one. Past ten, the rest are counted.
    static func text(for events: [AgendaEvent], heading: String? = nil, timeZone: TimeZone = .current) -> String {
        let events = ordered(events)
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.timeZone = timeZone
        var lines = events.prefix(limit).map { event in
            "\(event.isAllDay ? String(localized: "All day") : event.start.formatted(time))  \(event.title.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        if events.count > limit { lines.append(String(localized: "+ \(events.count - limit) more")) }
        return ((heading.map { [$0] } ?? []) + lines).joined(separator: "\n")
    }

    /// The box for a journal page: small, below the date, against the right-hand margin.
    static func item(for events: [AgendaEvent], on page: NotebookPage) -> PageItem? {
        guard !ordered(events).isEmpty else { return nil }
        var box = TextBox(string: text(for: events))
        box.fontSize = 11
        let unit = page.size.width / 800
        let width = min(max(page.size.width * 0.34, 150), 230)
        let size = CGSize(width: width, height: box.height(width: width))
        let head = page.template.flatMap { PageMasthead.baselines(for: $0, size: page.size) }.map { ($0.date + 26) * unit } ?? 48 * unit
        let right = page.size.width - 96 * unit
        var item = PageItem(content: .text(box), center: CGPoint(x: (right - width / 2).rounded(), y: (head + size.height / 2).rounded()), size: size)
        item.raw["agenda"] = .string(box.string)
        return item
    }

    /// What a new journal page is printed with: today's events when that is switched on and the calendar may be read.
    static func forJournal(now: Date = .now, calendar: Calendar = .current) async -> [AgendaEvent] {
        guard UserDefaults.standard.bool(forKey: SettingsKey.journalAgenda) else { return [] }
        return (try? await self.calendar.events(on: now, calendar: calendar)) ?? []
    }
}

extension PageItem {
    /// The events a journal page was printed with, as opposed to anything placed on it by hand. A mark that holds the
    /// printed words stops counting once they are typed over, even by a build that doesn't know to take it off.
    var isPrintedAgenda: Bool { raw["agenda"].map { $0.stringValue.map { $0 == text?.string } ?? true } ?? false }
}
