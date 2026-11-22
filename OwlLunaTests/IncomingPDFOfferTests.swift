import XCTest
@testable import OwlLuna

/// Which notebooks the Card offers a PDF from another app to, in what order, and when it needs Another Notebook….
final class IncomingPDFOfferTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func notebook(_ title: String, opened hoursAgo: Double?, edited editedHoursAgo: Double = 1000, trashed: Bool = false,
                          takes: Bool = true) -> IncomingPDFOffer.Notebook {
        IncomingPDFOffer.Notebook(id: UUID(), title: title, lastOpenedAt: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) },
                                  modifiedAt: now.addingTimeInterval(-editedHoursAgo * 3600), isTrashed: trashed, takesPages: takes)
    }

    func testTheMostRecentlyOpenedComeFirstAndTheCardHoldsFour() {
        let notebooks = [notebook("Physics", opened: 30), notebook("Biology", opened: 1), notebook("Recipes", opened: 300),
                         notebook("Chemistry", opened: 5), notebook("History", opened: 12), notebook("Art", opened: 48)]
        let offer = IncomingPDFOffer(notebooks)
        let titles = Dictionary(uniqueKeysWithValues: notebooks.map { ($0.id, $0.title) })
        XCTAssertEqual(offer.all.compactMap { titles[$0] }, ["Biology", "Chemistry", "History", "Physics", "Art", "Recipes"])
        XCTAssertEqual(offer.onCard.compactMap { titles[$0] }, ["Biology", "Chemistry", "History", "Physics"])
        XCTAssertTrue(offer.hasMore, "two more wait under Another Notebook…")
    }

    func testANotebookNeverOpenedGoesByWhenItWasLastEdited() {
        let fresh = notebook("Imported", opened: nil, edited: 2), old = notebook("Old", opened: 50), recent = notebook("Recent", opened: 1)
        XCTAssertEqual(IncomingPDFOffer([old, fresh, recent]).all, [recent.id, fresh.id, old.id])
    }

    func testTrashedNotebooksAndOnesThatRefuseArentOffered() {
        let kept = notebook("Biology", opened: 3)
        let offer = IncomingPDFOffer([notebook("Deleted", opened: 1, trashed: true), kept, notebook("Read-only", opened: 2, takes: false)])
        XCTAssertEqual(offer.all, [kept.id])
        XCTAssertEqual(offer.onCard, [kept.id])
        XCTAssertFalse(offer.hasMore)
    }

    func testFourNotebooksFitTheCardWithNothingMore() {
        let offer = IncomingPDFOffer((1...4).map { notebook("Notebook \($0)", opened: Double($0)) })
        XCTAssertEqual(offer.onCard.count, 4)
        XCTAssertFalse(offer.hasMore, "Another Notebook… would only list the same four")
        XCTAssertTrue(IncomingPDFOffer((1...5).map { notebook("Notebook \($0)", opened: Double($0)) }).hasMore)
    }

    func testWithNothingToTakeThePagesThereIsNoQuestion() {
        XCTAssertTrue(IncomingPDFOffer([]).isEmpty)
        XCTAssertTrue(IncomingPDFOffer([notebook("Deleted", opened: 1, trashed: true), notebook("Locked", opened: 2, takes: false)]).isEmpty)
        XCTAssertFalse(IncomingPDFOffer([notebook("Biology", opened: 1)]).isEmpty)
    }

    func testNotebooksOpenedAtTheSameMomentGoByTitle() {
        let zoology = notebook("Zoology", opened: 4), algebra = notebook("algebra", opened: 4), biology = notebook("Biology", opened: 4)
        XCTAssertEqual(IncomingPDFOffer([zoology, algebra, biology]).all, [algebra.id, biology.id, zoology.id])
    }
}
