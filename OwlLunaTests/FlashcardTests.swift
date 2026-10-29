import XCTest
import PencilKit
@testable import OwlLuna

/// Flashcards: when they come back, how they are kept with their notebook, and how they are cut from a page.
@MainActor
final class FlashcardTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }
    private var monday: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))! }

    private func makeNotebook(_ root: StorageRoot, pages: [NotebookPage]? = nil) async throws -> NotebookManifest {
        let manifest = NotebookManifest(title: "Biology", defaults: paper, pages: pages ?? [paper.newPage()])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        return manifest
    }

    private func card(_ question: String, _ answer: String) -> Flashcard {
        Flashcard(front: CardSide(text: question), back: CardSide(text: answer), now: monday, calendar: calendar)
    }

    private var tenDayCard: Flashcard {
        var card = card("Q", "A")
        card.interval = 10
        card.due = "2026-10-15"
        return card
    }

    func testACardComesBackLaterEachTimeItIsRemembered() {
        var card = card("Powerhouse of the cell?", "Mitochondria")
        XCTAssertEqual(card.due, "2026-10-05", "a new card is due the day it is made")
        var day = monday, waits: [Int] = []
        for _ in 0..<4 {
            card = CardSchedule.graded(card, .good, now: day, calendar: calendar)
            waits.append(card.interval)
            day = calendar.date(byAdding: .day, value: card.interval, to: day)!
        }
        XCTAssertEqual(waits, [1, 3, 8, 20])
        XCTAssertEqual(card.due, "2026-11-06")
        XCTAssertEqual(card.reviews, 4)
        XCTAssertEqual(card.ease, CardSchedule.startingEase)
    }

    func testAForgottenCardStartsAgainAndAnEasyOneWaitsLonger() {
        var learned = card("Q", "A")
        learned.interval = 20
        let forgotten = CardSchedule.graded(learned, .again, now: monday, calendar: calendar)
        XCTAssertEqual(forgotten.interval, 0)
        XCTAssertEqual(forgotten.due, "2026-10-05", "it is shown again the same day")
        XCTAssertEqual(forgotten.lapses, 1)
        XCTAssertEqual(forgotten.ease, 2.3, accuracy: 0.001)
        XCTAssertEqual(CardSchedule.graded(forgotten, .good, now: monday, calendar: calendar).due, "2026-10-06")

        var hard = learned
        hard.ease = 1.35
        XCTAssertEqual(CardSchedule.graded(hard, .again, now: monday, calendar: calendar).ease, CardSchedule.minimumEase, "ease never falls below its floor")
        XCTAssertEqual(CardSchedule.graded(card("Q", "A"), .again, now: monday, calendar: calendar).lapses, 0, "a card not yet learned can't lapse")
        let missed = CardSchedule.graded(CardSchedule.graded(card("Q", "A"), .again, now: monday, calendar: calendar), .again, now: monday, calendar: calendar)
        XCTAssertEqual(missed.ease, CardSchedule.startingEase, "or lose ease before its first wait")

        let easy = CardSchedule.graded(learned, .easy, now: monday, calendar: calendar)
        XCTAssertEqual(easy.interval, 65)
        XCTAssertEqual(easy.ease, 2.65, accuracy: 0.001)
        XCTAssertEqual(CardSchedule.interval(after: .easy, for: card("Q", "A")), 4)
        var old = learned
        old.interval = 300
        XCTAssertEqual(CardSchedule.interval(after: .easy, for: old, now: monday, calendar: calendar), CardSchedule.longestInterval, "no wait is longer than a year")
    }

    func testCrammingACardBeforeItIsDueDoesNotPushItAway() {
        let evening = monday.addingTimeInterval(11 * 3600)
        var crammed = tenDayCard
        for _ in 0..<3 { crammed = CardSchedule.graded(crammed, .good, now: evening, calendar: calendar) }
        XCTAssertEqual(crammed.interval, 10)
        XCTAssertEqual(crammed.due, "2026-10-15", "going over it again the day it was learned leaves its day where it was")
        XCTAssertEqual(crammed.ease, CardSchedule.startingEase)
        XCTAssertEqual(crammed.reviews, 3)

        let sunday = calendar.date(byAdding: .day, value: 6, to: monday)!
        let early = CardSchedule.graded(tenDayCard, .good, now: sunday, calendar: calendar)
        XCTAssertEqual(early.interval, 15, "it grows from the six days it waited, not the ten it was given")
        XCTAssertEqual(early.due, "2026-10-26")
        XCTAssertEqual(early.ease, CardSchedule.startingEase)
        XCTAssertEqual(CardSchedule.graded(early, .good, now: sunday, calendar: calendar).due, "2026-10-26", "and a second pass that evening leaves it there")

        var farOff = tenDayCard
        farOff.due = "2026-10-17"
        XCTAssertEqual(CardSchedule.graded(farOff, .good, now: monday, calendar: calendar).due, "2026-10-17", "an early answer never brings its day nearer")
    }

    func testAnEarlyEasyGrowsFromTheDaysWaitedAndLeavesTheEase() {
        let friday = calendar.date(byAdding: .day, value: 4, to: monday)!
        let easy = CardSchedule.graded(tenDayCard, .easy, now: friday, calendar: calendar)
        XCTAssertEqual(easy.interval, 13)
        XCTAssertEqual(easy.due, "2026-10-22")
        XCTAssertEqual(easy.ease, CardSchedule.startingEase, "answering early can't raise the ease")
        let twice = CardSchedule.graded(easy, .easy, now: friday, calendar: calendar)
        XCTAssertEqual(twice.interval, 13)
        XCTAssertEqual(twice.due, "2026-10-22")
        XCTAssertEqual(twice.ease, CardSchedule.startingEase)
    }

    func testForgettingACardIsALapseOnlyOnceItHasWaitedADay() {
        let sameDay = CardSchedule.graded(tenDayCard, .again, now: monday, calendar: calendar)
        XCTAssertEqual(sameDay.interval, 0)
        XCTAssertEqual(sameDay.due, "2026-10-05")
        XCTAssertEqual(sameDay.lapses, 0, "missed the day it was given its wait")
        XCTAssertEqual(sameDay.ease, CardSchedule.startingEase)

        let friday = calendar.date(byAdding: .day, value: 4, to: monday)!
        let forgotten = CardSchedule.graded(tenDayCard, .again, now: friday, calendar: calendar)
        XCTAssertEqual(forgotten.interval, 0)
        XCTAssertEqual(forgotten.due, "2026-10-09")
        XCTAssertEqual(forgotten.lapses, 1, "missed four days into its wait")
        XCTAssertEqual(forgotten.ease, 2.3, accuracy: 0.001)
        let twice = CardSchedule.graded(CardSchedule.graded(forgotten, .good, now: friday, calendar: calendar), .again, now: friday, calendar: calendar)
        XCTAssertEqual(twice.lapses, 1, "relearned and missed again in the same sitting isn't another lapse")
        XCTAssertEqual(twice.ease, 2.3, accuracy: 0.001)

        let evening = monday.addingTimeInterval(11 * 3600)
        var crammed = card("Q", "A")
        for _ in 0..<3 {
            crammed = CardSchedule.graded(crammed, .again, now: evening, calendar: calendar)
            crammed = CardSchedule.graded(crammed, .good, now: evening, calendar: calendar)
        }
        XCTAssertEqual(crammed.ease, CardSchedule.startingEase, "three passes in one evening don't wear a new card's ease down")
        XCTAssertEqual(crammed.lapses, 0)
    }

    func testACardDueTomorrowIsEarlyWhereTheClocksSkipMidnight() {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago")!
        let noon = santiago.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!
        var card = tenDayCard
        card.due = "2026-09-07"
        let early = CardSchedule.graded(card, .good, now: noon, calendar: santiago)
        XCTAssertEqual(early.interval, 23, "it grows from the nine days it waited, not as a card that has come due")
        XCTAssertEqual(early.due, "2026-09-29")
        XCTAssertEqual(early.ease, CardSchedule.startingEase)
    }

    func testCardsAreKeptInTheNotebookAndReadBack() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root)
        let library = FlashcardLibrary(root: root)
        await library.load()
        XCTAssertTrue(library.cards(in: manifest.id).isEmpty)

        var first = card("Capital of France?", "Paris")
        first.pageID = manifest.pages[0].id
        XCTAssertTrue(library.add([first, card("2 + 2", "4")], to: manifest.id))
        library.grade(first.id, in: manifest.id, .good, now: monday, calendar: calendar)
        await library.flush()

        let file = CardFiles.file(in: root.package(manifest.id))
        XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("\"version\":1"))
        let reread = FlashcardLibrary(root: root)
        await reread.load()
        let cards = reread.cards(in: manifest.id)
        XCTAssertEqual(cards.map(\.front.text), ["Capital of France?", "2 + 2"])
        XCTAssertEqual(cards[0].due, "2026-10-06")
        XCTAssertEqual(cards[0].pageID, manifest.pages[0].id)
        XCTAssertEqual(reread.due(in: [manifest.id], on: "2026-10-05").map(\.card.front.text), ["2 + 2"])
        XCTAssertEqual(reread.due(in: [manifest.id], on: "2026-10-06").count, 2)
        XCTAssertEqual(reread.nextDue(in: [manifest.id], after: "2026-10-05"), "2026-10-06")

        reread.remove(Set(cards.map(\.id)), from: manifest.id)
        await reread.flush()
        let left = CardFiles.read(root.package(manifest.id))
        XCTAssertEqual(left.cards, [])
        XCTAssertEqual(Set(left.removed.keys), Set(cards.map(\.id)), "what is left says they were deleted, so another iPad's copy doesn't bring them back")
    }

    func testADeletedCardPutBackKeepsItsPlaceItsScheduleAndItsClipping() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root)
        let library = FlashcardLibrary(root: root)
        await library.load()
        let clipped = try await library.saveClipping(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }, in: manifest.id)
        var two = card("Two", "2")
        two.back.image = clipped
        library.add([card("One", "1"), two, card("Three", "3")], to: manifest.id)
        let graded = try XCTUnwrap(library.grade(two.id, in: manifest.id, .easy, now: monday, calendar: calendar))
        await library.flush()
        let clipping = library.imageURL(clipped, in: manifest.id)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: clipping.path(percentEncoded: false))

        library.remove([two.id], from: manifest.id)
        await library.flush()
        XCTAssertEqual(CardFiles.read(root.package(manifest.id)).cards.map(\.front.text), ["One", "Three"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: clipping.path(percentEncoded: false)), "a clipping its card has only just let go is kept a while")

        library.restore(graded, at: 1, in: manifest.id)
        await library.flush()
        let deck = CardFiles.read(root.package(manifest.id))
        XCTAssertEqual(deck.cards.map(\.front.text), ["One", "Two", "Three"], "back in its place, though the file still says it was deleted")
        var expected = graded
        expected.changedAt = deck.cards[1].changedAt
        XCTAssertEqual(deck.cards[1], expected, "with its schedule")
        XCTAssertNotNil(deck.removed[two.id])
        let elsewhere = CardFiles.Deck(removed: deck.removed).merged(with: deck)
        XCTAssertTrue(elsewhere.cards.contains { $0.id == two.id }, "an iPad that saw the delete takes it back too")
        let reread = FlashcardLibrary(root: root)
        await reread.load()
        XCTAssertEqual(reread.cards(in: manifest.id).map(\.front.text), ["One", "Two", "Three"])
        let image = await reread.image(clipped, in: manifest.id)
        XCTAssertNotNil(image)
    }

    func testTheLastCardPutBackInTheSameSecondItWasDeletedStays() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root)
        let library = FlashcardLibrary(root: root)
        await library.load()
        let clipped = try await library.saveClipping(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }, in: manifest.id)
        var only = card("Only", "1")
        only.front.image = clipped
        library.add([only], to: manifest.id)
        await library.flush()
        let now = Date.now

        library.remove([only.id], from: manifest.id, now: now)
        await library.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(clipped, in: manifest.id).path(percentEncoded: false)),
                      "an empty deck keeps the clipping of the card just deleted")
        library.restore(only, at: 0, in: manifest.id, now: now)
        library.restore(only, at: 0, in: manifest.id, now: now)
        await library.flush()
        XCTAssertEqual(library.cards(in: manifest.id).map(\.id), [only.id], "put back once")
        XCTAssertEqual(CardFiles.read(root.package(manifest.id)).cards.map(\.id), [only.id], "a delete never wins over the card put back after it")
    }

    func testTwoCopiesOfADeckAreSettledCardByCard() {
        let base = [card("One", "1"), card("Two", "2"), card("Three", "3"), card("Four", "4")]
        let minute = monday.addingTimeInterval(60)
        var mine = CardFiles.Deck(cards: base), theirs = CardFiles.Deck(cards: base)
        mine.cards[0] = CardSchedule.graded(base[0], .good, now: minute, calendar: calendar)
        mine.cards.removeAll { $0.id == base[2].id || $0.id == base[3].id }
        mine.removed = [base[2].id: minute, base[3].id: minute]
        mine.cards.append(card("Five", "5"))
        theirs.cards[0] = CardSchedule.graded(base[0], .easy, now: minute.addingTimeInterval(60), calendar: calendar)
        theirs.cards[1] = CardSchedule.graded(base[1], .good, now: minute, calendar: calendar)
        theirs.cards[3].back.text = "Four, rewritten"
        theirs.cards[3].changedAt = minute.addingTimeInterval(120)

        let merged = mine.merged(with: theirs)
        XCTAssertEqual(merged.cards.map(\.front.text), ["One", "Two", "Five", "Four"], "this copy's order, then what only the other has")
        XCTAssertEqual(merged.cards[0], theirs.cards[0], "the later answer stands")
        XCTAssertEqual(merged.cards[1].reviews, 1, "answers given on either side are kept")
        XCTAssertEqual(merged.cards[3].back.text, "Four, rewritten", "a card changed after it was deleted elsewhere comes back, as writing does")
        XCTAssertEqual(Set(merged.removed.keys), [base[2].id, base[3].id])
        let other = theirs.merged(with: mine)
        XCTAssertEqual(other.cards.sorted { $0.front.text < $1.front.text }, merged.cards.sorted { $0.front.text < $1.front.text }, "both sides come to the same cards")
        XCTAssertEqual(mine.merged(with: mine), mine)
    }

    func testAWriteAndALoadKeepCardsFromBothTheFileAndThisIPad() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root)
        let library = FlashcardLibrary(root: root)
        await library.load()
        let one = card("One", "1"), two = card("Two", "2")
        library.add([one, two], to: manifest.id)
        await library.flush()
        // A sync brings in a card made on another iPad.
        var file = CardFiles.read(root.package(manifest.id))
        file.cards.append(card("From the other iPad", "3"))
        try CardFiles.write(file, to: root.package(manifest.id))

        library.grade(one.id, in: manifest.id, .good)
        library.remove([two.id], from: manifest.id)
        await library.flush()
        let written = CardFiles.read(root.package(manifest.id)).cards
        XCTAssertEqual(written.map(\.front.text), ["One", "From the other iPad"], "a write changes only what was changed here")
        XCTAssertEqual(written.first?.reviews, 1)

        library.grade(one.id, in: manifest.id, .good)
        await library.load()
        XCTAssertEqual(library.cards(in: manifest.id).map(\.front.text), ["One", "From the other iPad"], "a load brings in what arrived")
        XCTAssertEqual(library.cards(in: manifest.id).first?.reviews, 2, "and keeps an answer that may not be written yet")
        await library.flush()
    }

    func testACardWriteThatFailsIsShownAndGoesWithTheNextChange() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root)
        let library = FlashcardLibrary(root: root)
        await library.load()
        let package = root.package(manifest.id).path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package) }

        library.add([card("Lost?", "No")], to: manifest.id)
        await library.flush()
        XCTAssertEqual(library.lastError?.hasPrefix("Flashcards couldn't be saved"), true, library.lastError ?? "nothing was said")
        library.clearError()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package)
        library.add([card("Next", "Card")], to: manifest.id)
        await library.flush()
        XCTAssertNil(library.lastError)
        XCTAssertEqual(CardFiles.read(root.package(manifest.id)).cards.map(\.front.text), ["Lost?", "Next"])
    }

    func testCardsLeaveWithADeletedNotebookAndNeverBringItBack() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root)
        let library = FlashcardLibrary(root: root)
        await library.load()
        library.add([card("Q", "A")], to: manifest.id)
        await library.flush()
        try FileManager.default.removeItem(at: root.package(manifest.id))
        library.grade(library.cards(in: manifest.id)[0].id, in: manifest.id, .good)
        await library.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.package(manifest.id).path(percentEncoded: false)))
        XCTAssertNil(library.lastError, "a notebook deleted meanwhile isn't a failure to save")
        library.forget(notebooks: [manifest.id])
        XCTAssertTrue(library.cards(in: manifest.id).isEmpty)
    }

    func testADamagedOrNewerCardsFileIsNeverWrittenOver() async throws {
        let root = temporaryRoot(self)
        let damaged = try await makeNotebook(root), newer = try await makeNotebook(root)
        try Data("{ not json".utf8).write(to: CardFiles.file(in: root.package(damaged.id)))
        try Data(#"{"version":9,"cards":[{"id":"\#(UUID().uuidString)","front":{"text":"Q"},"back":{"text":"A"},"shiny":true}]}"#.utf8)
            .write(to: CardFiles.file(in: root.package(newer.id)))
        let library = FlashcardLibrary(root: root)
        await library.load()

        XCTAssertTrue(library.canChange(damaged.id), "the damaged file was set aside, so a fresh one can be started")
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.package(damaged.id).path(percentEncoded: false))
        XCTAssertTrue(kept.contains("cards.json.corrupt"))

        XCTAssertEqual(library.cards(in: newer.id).map(\.front.text), ["Q"], "a newer file's cards can still be studied")
        XCTAssertFalse(library.canChange(newer.id))
        XCTAssertFalse(library.add([card("Mine", "Lost?")], to: newer.id))
        library.grade(library.cards(in: newer.id)[0].id, in: newer.id, .good)
        await library.flush()
        XCTAssertTrue(String(decoding: try Data(contentsOf: CardFiles.file(in: root.package(newer.id))), as: UTF8.self).contains("shiny"))
    }

    func testADuplicatedNotebookBringsItsCards() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root)
        let library = FlashcardLibrary(root: root)
        await library.load()
        library.add([card("Q", "A")], to: manifest.id)
        await library.flush()
        let copy = UUID()
        try FileManager.default.copyItem(at: root.package(manifest.id), to: root.package(copy))
        await library.loadNewNotebooks()
        XCTAssertEqual(library.cards(in: copy).map(\.front.text), ["Q"])
    }

    func testATapeCardShowsTheTapeOnOneSideAndTheAnswerOnTheOther() async throws {
        let root = temporaryRoot(self)
        var page = paper.newPage()
        let tape = PageItem(content: .tape(.mustard), center: CGPoint(x: 300, y: 200), size: CGSize(width: 240, height: 40))
        let other = PageItem(content: .tape(.sage), center: CGPoint(x: 300, y: 240), size: CGSize(width: 240, height: 30))
        page.items = [tape, other]
        let manifest = try await makeNotebook(root, pages: [page])
        let ink = PKDrawing(strokes: [stroke(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 400, y: 200), width: 8),
                                      stroke(from: CGPoint(x: 200, y: 240), to: CGPoint(x: 400, y: 240), width: 8)])
        _ = try await NotebookPackage(root: root, id: manifest.id).write(SaveSnapshot(manifest: manifest, ink: [page.id: ink]))
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let session = EditorSession(document: document)
        let library = FlashcardLibrary(root: root)
        await library.load()

        XCTAssertEqual(session.tapesWithoutCards(in: library).map(\.tape.id), [tape.id, other.id])
        let made = try await session.makeCard(from: tape, on: document.pages[0], in: library)
        XCTAssertEqual(made.tapeID, tape.id)
        XCTAssertEqual(made.pageID, page.id)
        XCTAssertEqual(session.tapesWithoutCards(in: library).map(\.tape.id), [other.id])
        XCTAssertEqual(library.card(for: tape.id, in: manifest.id)?.id, made.id)

        let region = CardClipping.region(around: tape, on: page)
        XCTAssertTrue(region.contains(CGRect(x: 180, y: 180, width: 240, height: 40)), "the clipping holds the tape and some of what is round it")
        let front = try XCTUnwrap(UIImage(contentsOfFile: library.imageURL(try XCTUnwrap(made.front.image), in: manifest.id).path(percentEncoded: false)))
        let back = try XCTUnwrap(UIImage(contentsOfFile: library.imageURL(try XCTUnwrap(made.back.image), in: manifest.id).path(percentEncoded: false)))
        XCTAssertEqual(front.size.width * front.scale, region.width * CardClipping.scale, accuracy: 1)
        let onTape = CGPoint(x: (250 - region.minX) * CardClipping.scale, y: (200 - region.minY) * CardClipping.scale)
        let onOther = CGPoint(x: (250 - region.minX) * CardClipping.scale, y: (240 - region.minY) * CardClipping.scale)
        XCTAssertGreaterThan(try pixel(front, at: onTape).r, 150, "the question still has the tape on")
        XCTAssertLessThan(try pixel(back, at: onTape).r, 110, "the answer shows the ink under it")
        XCTAssertGreaterThan(try pixel(back, at: onOther).r, 100, "other strips stay where they are, so only this answer is given away")
    }

    func testSelectedInkIsCutOutOnItsOwnPaper() throws {
        var page = PageDefaults(template: .blank, paperColor: .chalkboard, pageSize: .letter).newPage()
        page.items = [PageItem(content: .tape(.mustard), center: CGPoint(x: 200, y: 200), size: CGSize(width: 240, height: 40))]
        let ink = PKDrawing(strokes: [stroke(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 300, y: 200), width: 6)])
        let image = try XCTUnwrap(CardClipping.inkImage([(page, ink)], assets: FileManager.default.temporaryDirectory))
        XCTAssertEqual(image.size.width, ink.bounds.width + 36, accuracy: 2, "the ink with a little room round it")
        let corner = try pixel(image, at: CGPoint(x: 3, y: 3))
        let chalk = PageRenderer.paperColor(.chalkboard).cgColor.components ?? []
        XCTAssertEqual(Double(corner.g) / 255, Double(chalk[1]), accuracy: 0.06, "on the page's own paper, with nothing else that was on the page")
        XCTAssertNil(CardClipping.inkImage([(page, PKDrawing())], assets: FileManager.default.temporaryDirectory))
    }

    func testADraftKeepsItsScheduleWhenACardIsChanged() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root)
        let library = FlashcardLibrary(root: root)
        await library.load()
        var draft = CardDraft(pageID: manifest.pages[0].id, answer: UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image { _ in })
        XCTAssertFalse(draft.isComplete, "a card needs a question as well")
        draft.front.text = "  What is drawn?  "
        let saved = try await library.save(draft, in: manifest.id)
        XCTAssertEqual(saved.front.text, "What is drawn?")
        XCTAssertNotNil(saved.back.image)
        let clipping = await library.image(saved.back.image, in: manifest.id)
        XCTAssertNotNil(clipping)

        let graded = try XCTUnwrap(library.grade(saved.id, in: manifest.id, .easy, now: monday, calendar: calendar))
        var edit = CardDraft(editing: graded)
        edit.swapSides()
        edit.back.text = "Now the answer"
        let changed = try await library.save(edit, in: manifest.id)
        XCTAssertEqual(changed.id, saved.id)
        XCTAssertEqual(changed.front.image, saved.back.image)
        XCTAssertEqual(changed.due, graded.due)
        XCTAssertEqual(library.cards(in: manifest.id).count, 1)
    }

    func testASittingBringsAForgottenCardRoundAgain() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root)
        let library = FlashcardLibrary(root: root)
        await library.load()
        library.add([card("One", "1"), card("Two", "2")], to: manifest.id)
        let session = ReviewSession(cards: library.due(in: [manifest.id], on: "2026-10-05"))
        XCTAssertEqual(session.total, 2)
        session.isRevealed = true
        session.answer(.again, in: library, now: monday)
        XCTAssertFalse(session.isRevealed)
        XCTAssertEqual(session.current?.card.front.text, "Two")
        session.answer(.good, in: library, now: monday)
        XCTAssertEqual(session.current?.card.front.text, "One", "the forgotten card comes back at the end")
        XCTAssertEqual(session.finished, 1)
        session.answer(.good, in: library, now: monday)
        XCTAssertNil(session.current)
        XCTAssertEqual(session.finished, 2)
        XCTAssertEqual(library.cards(in: manifest.id).map(\.reviews), [2, 1])

        let dropping = ReviewSession(cards: library.all(in: [manifest.id]))
        dropping.answer(.again, in: library, now: monday)
        dropping.answer(.again, in: library, now: monday)
        dropping.dropCurrent()
        XCTAssertEqual(dropping.remaining, 1)
        XCTAssertEqual(dropping.total, 1)
    }

    func testGoingThroughThemAllAgainTakesTheCardsAsTheyNowStand() async throws {
        let root = temporaryRoot(self)
        let manifest = try await makeNotebook(root)
        let library = FlashcardLibrary(root: root)
        await library.load()
        library.add([card("One", "1"), card("Two", "2"), card("Three", "3")], to: manifest.id)
        let all = library.all(in: [manifest.id])
        let first = ReviewSession(cards: all)
        while first.current != nil { first.answer(.good, in: library, now: monday) }
        library.remove([all[2].id], from: manifest.id)

        let again = ReviewSession(cards: library.refreshed(all))
        XCTAssertEqual(again.queue.map(\.id), all.prefix(2).map(\.id), "a card deleted since doesn't come round")
        let current = try XCTUnwrap(again.current)
        XCTAssertEqual(current.card, library.cards(in: manifest.id).first { $0.id == current.id })
        let shown = CardSchedule.interval(after: .easy, for: current.card, now: monday, calendar: .current)
        XCTAssertEqual(shown, 1, "not the four days a new card would get")
        again.answer(.easy, in: library, now: monday)
        XCTAssertEqual(library.cards(in: manifest.id).first { $0.id == current.id }?.interval, shown, "the button's wait is the wait it gets")
    }

    func testWaitsAreSaidInDaysThenMonths() {
        XCTAssertEqual(CardSchedule.waitText(0), "Today")
        XCTAssertEqual(CardSchedule.waitText(1), "Tomorrow")
        XCTAssertEqual(CardSchedule.waitText(8), "In 8 days")
        XCTAssertEqual(CardSchedule.waitText(65), "In 2 months")
        var card = card("", "A")
        XCTAssertEqual(card.summary(pageNumber: 3), "Clipping from page 3")
        card.tapeID = UUID()
        XCTAssertEqual(card.summary(pageNumber: nil), "Study tape")
        XCTAssertEqual(card.dueText(today: "2026-10-05"), "New")
        card.due = "2026-10-08"
        XCTAssertEqual(card.dueText(today: "2026-10-05"), "In 3 days")
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> (r: Int, g: Int, b: Int) {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: -point.x, y: point.y - CGFloat(cgImage.height) + 1, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}
