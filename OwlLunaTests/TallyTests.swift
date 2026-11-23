import XCTest
@testable import OwlLuna

private func calendar(firstWeekday: Int = 1, zone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.firstWeekday = firstWeekday
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, in calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

/// What a sitting counts for the slip that ends it, and the days of study the writing log keeps.
@MainActor
final class TallyTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)

    private func makeLibrary(cards: Int) async throws -> (FlashcardLibrary, UUID) {
        let root = temporaryRoot(self)
        let manifest = NotebookManifest(title: "Biology", defaults: paper, pages: [paper.newPage()])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let library = FlashcardLibrary(root: root)
        await library.load()
        library.add((1...cards).map { Flashcard(front: CardSide(text: "Q\($0)"), back: CardSide(text: "A\($0)")) }, to: manifest.id)
        return (library, manifest.id)
    }

    private func makeActivity(_ root: StorageRoot) -> WritingActivity {
        let suite = "TallyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let activity = WritingActivity(root: root, defaults: defaults)
        activity.writeDelay = .milliseconds(10)
        return activity
    }

    // MARK: The sitting

    func testASittingWhereEveryCardIsKnownCountsThemAllFirstTime() async throws {
        let (library, notebook) = try await makeLibrary(cards: 3)
        let session = ReviewSession(cards: library.all(in: [notebook]))
        XCTAssertEqual([session.studied, session.firstTime, session.cameRound], [0, 0, 0])
        session.answer(.good, in: library)
        session.answer(.easy, in: library)
        session.answer(.good, in: library)
        XCTAssertNil(session.current)
        XCTAssertEqual([session.studied, session.firstTime, session.cameRound], [3, 3, 0])
    }

    func testACardAnsweredAgainCountsOnceAsHavingComeRound() async throws {
        let (library, notebook) = try await makeLibrary(cards: 3)
        let session = ReviewSession(cards: library.all(in: [notebook]))
        session.answer(.again, in: library)
        session.answer(.good, in: library)
        session.answer(.good, in: library)
        XCTAssertEqual([session.studied, session.firstTime, session.cameRound], [2, 2, 0], "a card still to come round isn't studied yet")
        session.answer(.again, in: library)
        session.answer(.again, in: library)
        session.answer(.good, in: library)
        XCTAssertNil(session.current)
        XCTAssertEqual([session.studied, session.firstTime, session.cameRound], [3, 2, 1], "answered Again twice, it is still one card")
        XCTAssertEqual(session.studied, session.firstTime + session.cameRound)
    }

    func testACardDeletedMidSittingLeavesTheCounts() async throws {
        let (library, notebook) = try await makeLibrary(cards: 4)
        let session = ReviewSession(cards: library.all(in: [notebook]))
        session.answer(.good, in: library)
        session.answer(.again, in: library)
        session.dropCurrent()
        XCTAssertEqual([session.studied, session.firstTime, session.cameRound], [1, 1, 0], "a card that was never answered")
        session.answer(.again, in: library)
        session.answer(.good, in: library)
        XCTAssertEqual([session.studied, session.firstTime, session.cameRound], [2, 1, 1])
        session.dropCurrent()
        XCTAssertNil(session.current)
        XCTAssertEqual([session.studied, session.firstTime, session.cameRound], [2, 1, 1])

        let again = ReviewSession(cards: library.all(in: [notebook]))
        again.answer(.again, in: library)
        again.answer(.again, in: library)
        again.answer(.again, in: library)
        again.answer(.again, in: library)
        again.dropCurrent()
        XCTAssertEqual([again.studied, again.firstTime, again.cameRound], [0, 0, 0], "a card forgotten and then deleted leaves too")
        again.answer(.good, in: library)
        XCTAssertEqual([again.studied, again.firstTime, again.cameRound], [1, 0, 1])
    }

    func testGoingThroughThemAllAgainCountsAfresh() async throws {
        let (library, notebook) = try await makeLibrary(cards: 2)
        let all = library.all(in: [notebook])
        let first = ReviewSession(cards: all)
        first.answer(.again, in: library)
        first.answer(.good, in: library)
        first.answer(.good, in: library)
        XCTAssertEqual([first.studied, first.firstTime, first.cameRound], [2, 1, 1])

        let second = ReviewSession(cards: library.refreshed(all))
        XCTAssertEqual([second.studied, second.firstTime, second.cameRound], [0, 0, 0])
        second.answer(.good, in: library)
        second.answer(.good, in: library)
        XCTAssertEqual([second.studied, second.firstTime, second.cameRound], [2, 2, 0], "the first sitting's Again isn't carried over")
        XCTAssertEqual([first.studied, first.firstTime, first.cameRound], [2, 1, 1])
    }

    // MARK: The record

    func testEachAnswerIsRecordedAgainstItsDayThroughTheHook() async throws {
        let (library, notebook) = try await makeLibrary(cards: 3)
        let activity = makeActivity(library.root)
        await activity.load()
        library.onGraded = { [activity] _, date in activity.recordStudy(at: date) }

        let now = Date.now
        let session = ReviewSession(cards: library.all(in: [notebook]))
        session.answer(.again, in: library, now: now)
        session.answer(.good, in: library, now: now)
        session.answer(.good, in: library, now: now)
        session.answer(.good, in: library, now: now)
        let today = ActivityFile.dayKey(for: now, calendar: .current)
        XCTAssertEqual(activity.log.days[today]?.cardsStudied, 4, "each answer counts, so the card answered Again counts twice")
        XCTAssertEqual(activity.log.days.count, 1)
        XCTAssertEqual(activity.studyWeek(now: now).dayCount, 1)

        let later = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        activity.recordStudy(at: later)
        XCTAssertEqual(activity.log.days[ActivityFile.dayKey(for: later, calendar: .current)]?.cardsStudied, 1)

        await activity.flush().value
        XCTAssertEqual(ActivityFile.read(library.root).days[today]?.cardsStudied, 4)
        let reloaded = makeActivity(library.root)
        await reloaded.load()
        XCTAssertEqual(reloaded.log.days[today]?.cardsStudied, 4)
    }

    func testNothingIsRecordedWhileHistoryIsOff() async throws {
        let (library, notebook) = try await makeLibrary(cards: 1)
        let activity = makeActivity(library.root)
        await activity.load()
        library.onGraded = { [activity] _, date in activity.recordStudy(at: date) }
        activity.isEnabled = false
        ReviewSession(cards: library.all(in: [notebook])).answer(.good, in: library)
        XCTAssertTrue(activity.log.days.isEmpty)
        XCTAssertFalse(activity.hasRecord)
        await activity.flush().value
        XCTAssertTrue(ActivityFile.read(library.root).days.isEmpty)
    }

    func testClearingTheHistoryClearsTheStudyDaysToo() async throws {
        let root = temporaryRoot(self)
        let activity = makeActivity(root)
        await activity.load()
        activity.recordStudy(at: .now)
        XCTAssertTrue(activity.hasRecord)
        XCTAssertFalse(activity.hasHistory, "cards alone are not writing")
        await activity.flush().value
        XCTAssertTrue(ActivityFile.read(root).hasStudy)

        await activity.clear()
        XCTAssertFalse(activity.hasRecord)
        XCTAssertEqual(activity.studyWeek().dayCount, 0)
        XCTAssertTrue(ActivityFile.read(root).days.isEmpty)
    }

    func testAnUnreadableDayIsLeftAloneByStudying() async throws {
        let root = temporaryRoot(self)
        let today = ActivityFile.dayKey(for: .now, calendar: .current)
        try FileManager.default.createDirectory(at: root.library, withIntermediateDirectories: true)
        try Data(#"{"version": 1, "days": {"\#(today)": {"notebooks": "garbage"}}}"#.utf8).write(to: root.activityFile)
        let activity = makeActivity(root)
        await activity.load()
        activity.recordStudy(at: .now)
        XCTAssertNotNil(activity.log.opaqueDays[today])
        XCTAssertNil(activity.log.days[today])
    }

    func testTheCountSurvivesAWriteAndARead() throws {
        let root = temporaryRoot(self)
        let calendar = calendar()
        let now = date(2026, 11, 20, in: calendar)
        var log = ActivityLog()
        log.days["2026-11-19"] = DayActivity(notebooks: [UUID(): [UUID()]])
        log.days["2026-11-19"]?.cardsStudied = 7
        log.days["2026-11-20"] = DayActivity()
        log.days["2026-11-20"]?.cardsStudied = 12
        try ActivityFile.write(log, to: root, now: now, calendar: calendar)

        let read = ActivityFile.read(root)
        XCTAssertEqual(read.days["2026-11-19"]?.cardsStudied, 7)
        XCTAssertEqual(read.days["2026-11-19"]?.pageCount, 1)
        XCTAssertEqual(read.days["2026-11-20"]?.cardsStudied, 12)
        XCTAssertEqual(read, log)
    }

    func testTheCountIsAPlainKeyOnItsDaySoAnOlderBuildWritesItBack() throws {
        let raw = #"{"version": 1, "days": {"2026-11-20": {"notebooks": {}, "otherPages": 2, "cardsStudied": 5}}}"#
        let log = try XCTUnwrap(ActivityFile.decode(Data(raw.utf8)))
        let day = try XCTUnwrap(log.days["2026-11-20"])
        XCTAssertEqual(day.extra, ["cardsStudied": .number(5)], "a build without the property reads it as one of the day's other keys")
        XCTAssertEqual(day.cardsStudied, 5)
        XCTAssertEqual(day.pageCount, 2)

        let rewritten = try XCTUnwrap(JSONValue.parse(ActivityFile.encode(log)).objectValue)
        XCTAssertEqual(rewritten["days"]?.objectValue?["2026-11-20"]?.objectValue?["cardsStudied"], .number(5))

        var counted = DayActivity()
        counted.cardsStudied = 3
        XCTAssertEqual(counted.extra, ["cardsStudied": .number(3)])
        counted.cardsStudied = 0
        XCTAssertTrue(counted.extra.isEmpty, "no count is no key")
    }

    func testAFileFromBeforeStudyDaysStillReads() throws {
        let notebook = UUID(), page = UUID()
        let raw = """
        {"version": 1, "days": {"2026-09-29": {"notebooks": {"\(notebook.uuidString)": ["\(page.uuidString)"]}, "otherPages": 2}}}
        """
        let log = try XCTUnwrap(ActivityFile.decode(Data(raw.utf8)))
        XCTAssertEqual(log.days["2026-09-29"]?.pageCount, 3)
        XCTAssertEqual(log.days["2026-09-29"]?.cardsStudied, 0)
        XCTAssertFalse(log.hasStudy)
        let encoded = try XCTUnwrap(JSONValue.parse(ActivityFile.encode(log)).objectValue)
        XCTAssertNil(encoded["days"]?.objectValue?["2026-09-29"]?.objectValue?["cardsStudied"], "no count is written for a day with none")

        for odd in [#""many""#, "-4", "2.5", "null"] {
            let strange = #"{"version": 1, "days": {"2026-09-29": {"cardsStudied": \#(odd)}}}"#
            XCTAssertEqual(ActivityFile.decode(Data(strange.utf8))?.days["2026-09-29"]?.cardsStudied, 0, "\(odd) is no count")
        }
    }

    func testMergeAndCompactionKeepTheCount() {
        var loaded = ActivityLog()
        loaded.days["2026-11-19"] = DayActivity()
        loaded.days["2026-11-19"]?.cardsStudied = 4
        var before = ActivityLog()
        before.days["2026-11-19"] = DayActivity()
        before.days["2026-11-19"]?.cardsStudied = 2
        before.days["2026-11-20"] = DayActivity(notebooks: [UUID(): [UUID()]])
        before.days["2026-11-20"]?.cardsStudied = 9
        before.days["2026-11-21"] = DayActivity()
        before.days["2026-11-21"]?.cardsStudied = 1
        loaded.merge(before)
        XCTAssertEqual(loaded.days["2026-11-19"]?.cardsStudied, 4, "merging the same day twice doesn't add it twice")
        XCTAssertEqual(loaded.days["2026-11-20"]?.cardsStudied, 9)
        XCTAssertEqual(loaded.days["2026-11-20"]?.pageCount, 1)
        XCTAssertEqual(loaded.days["2026-11-21"]?.cardsStudied, 1)

        var old = ActivityLog()
        old.days["2025-01-05"] = DayActivity(notebooks: [UUID(): [UUID(), UUID()]], otherPages: 1)
        old.days["2025-01-05"]?.cardsStudied = 8
        old.days["2025-01-06"] = DayActivity()
        old.days["2025-01-06"]?.cardsStudied = 3
        old.compact(before: "2026-01-01")
        XCTAssertEqual(old.days["2025-01-05"]?.cardsStudied, 8)
        XCTAssertEqual(old.days["2025-01-05"]?.pageCount, 3)
        XCTAssertTrue(old.days["2025-01-05"]?.notebooks.isEmpty == true)
        XCTAssertEqual(old.days["2025-01-06"]?.cardsStudied, 3)
    }

    func testADayOfStudyWithNoWritingIsNotADayWritten() async throws {
        let calendar = calendar()
        let now = date(2026, 11, 18, in: calendar)
        var log = ActivityLog()
        log.days["2026-11-17"] = DayActivity()
        log.days["2026-11-17"]?.cardsStudied = 10
        log.days["2026-11-18"] = DayActivity(notebooks: [UUID(): [UUID()]])
        log.days["2026-11-18"]?.cardsStudied = 5

        let week = WeekSummary(log: log, now: now, calendar: calendar)
        XCTAssertEqual(week.days.map(\.pages), [0, 0, 0, 1, 0, 0, 0])
        XCTAssertEqual(week.pageCount, 1)
        XCTAssertEqual(week.dayCount, 1, "the day of study isn't counted")
        XCTAssertEqual(ActivityStats.totals(in: calendar.dateInterval(of: .weekOfYear, for: now)!, log: log, calendar: calendar).days, 1)
        XCTAssertEqual(ActivityStats.longestRun(in: log, calendar: calendar), 1)
        XCTAssertEqual(ActivityStats.totals(for: "2026-11-17", in: log).pages, 0)

        var studyOnly = ActivityLog()
        studyOnly.days["2026-11-17"] = log.days["2026-11-17"]
        XCTAssertFalse(studyOnly.hasPages)
        XCTAssertTrue(studyOnly.hasStudy)

        let activity = makeActivity(temporaryRoot(self))
        await activity.load()
        activity.recordStudy(at: .now)
        XCTAssertFalse(activity.hasHistory)
        XCTAssertEqual(activity.week.pageCount, 0)
        XCTAssertEqual(activity.week.dayCount, 0)
        XCTAssertEqual(activity.week, WeekSummary(log: ActivityLog(), now: .now, calendar: .current), "the week strip's summary is what it was")
    }

    func testTheStudyWeekFollowsTheCalendarsFirstWeekday() {
        var log = ActivityLog()
        for (key, cards) in [("2026-11-15", 3), ("2026-11-16", 1), ("2026-11-18", 12), ("2026-11-21", 2), ("2026-11-22", 5)] {
            log.days[key] = DayActivity()
            log.days[key]?.cardsStudied = cards
        }
        let sunday = calendar(firstWeekday: 1)
        let fromSunday = StudyWeek(log: log, now: date(2026, 11, 18, in: sunday), calendar: sunday)
        XCTAssertEqual(fromSunday.days.map(\.cards), [3, 1, 0, 12, 0, 0, 2])
        XCTAssertEqual(fromSunday.dayCount, 4)
        XCTAssertTrue(fromSunday.includesToday)

        let monday = calendar(firstWeekday: 2)
        let fromMonday = StudyWeek(log: log, now: date(2026, 11, 18, in: monday), calendar: monday)
        XCTAssertEqual(fromMonday.days.map(\.cards), [1, 0, 12, 0, 0, 2, 5])
        XCTAssertEqual(fromMonday.dayCount, 4)

        let quiet = StudyWeek(log: log, now: date(2026, 11, 19, in: sunday), calendar: sunday)
        XCTAssertEqual(quiet.dayCount, 4)
        XCTAssertFalse(quiet.includesToday, "Thursday has none")
        XCTAssertEqual(StudyWeek(log: ActivityLog(), now: .now, calendar: .current).dayCount, 0)
    }

    func testTheWeekTheClocksGoBackStillHasSevenStudyDays() {
        let newYork = calendar(firstWeekday: 1, zone: "America/New_York")
        var log = ActivityLog()
        log.days["2026-11-01"] = DayActivity()
        log.days["2026-11-01"]?.cardsStudied = 2
        let week = StudyWeek(log: log, now: date(2026, 11, 3, in: newYork), calendar: newYork)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.first?.cards, 2)
    }

    // MARK: The slip's words

    private func week(_ studied: [Int], today: Int) -> StudyWeek {
        let calendar = calendar()
        let sunday = date(2026, 11, 15, in: calendar)
        var log = ActivityLog()
        for index in studied {
            let key = ActivityFile.dayKey(for: calendar.date(byAdding: .day, value: index, to: sunday)!, calendar: calendar)
            log.days[key] = DayActivity()
            log.days[key]?.cardsStudied = 3
        }
        return StudyWeek(log: log, now: calendar.date(byAdding: .day, value: today, to: sunday)!, calendar: calendar)
    }

    func testTheSlipReadsAsPlainWordsWithPluralFormsForEachCount() {
        XCTAssertEqual(TallySlip.spokenLabel(studied: 12, firstTime: 9, cameRound: 3, week: week([0, 2, 3, 6], today: 6)),
                       "12 cards studied. 9 remembered first time. 3 came round again. Studied on 4 days this week, including today.")
        XCTAssertEqual(TallySlip.spokenLabel(studied: 1, firstTime: 1, cameRound: 0, week: week([6], today: 6)),
                       "1 card studied. 1 remembered first time. Studied on 1 day this week, including today.")
        XCTAssertEqual(TallySlip.spokenLabel(studied: 2, firstTime: 0, cameRound: 1, week: week([1, 2], today: 4)),
                       "2 cards studied. 1 came round again. Studied on 2 days this week.")
    }

    func testTheSlipHasNoWeekWhenNoStudyDaysAreKept() {
        XCTAssertEqual(TallySlip.spokenLabel(studied: 4, firstTime: 4, cameRound: 0, week: nil), "4 cards studied. 4 remembered first time.")
        XCTAssertEqual(TallySlip.spokenLabel(studied: 4, firstTime: 4, cameRound: 0, week: StudyWeek()), "4 cards studied. 4 remembered first time.")
    }
}
