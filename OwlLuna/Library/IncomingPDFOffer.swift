import Foundation

/// The notebooks a PDF from another app is offered to: those that take its pages, opened last first, the first few on the Card.
struct IncomingPDFOffer: Equatable {
    struct Notebook: Equatable {
        let id: UUID
        let title: String
        let lastOpenedAt: Date?
        let modifiedAt: Date
        var isTrashed = false
        /// False for one the store won't add pages to.
        var takesPages = true
    }

    static let cardLimit = 4

    /// Every notebook that can take the pages, for Another Notebook….
    let all: [UUID]

    init(_ notebooks: [Notebook]) {
        all = notebooks.filter { !$0.isTrashed && $0.takesPages }
            .map { ($0, $0.lastOpenedAt ?? $0.modifiedAt) }
            .sorted { first, second in
                if first.1 != second.1 { return first.1 > second.1 }
                let titles = first.0.title.localizedStandardCompare(second.0.title)
                return titles == .orderedSame ? first.0.id.uuidString < second.0.id.uuidString : titles == .orderedAscending
            }
            .map(\.0.id)
    }

    var onCard: [UUID] { Array(all.prefix(Self.cardLimit)) }

    /// Whether there are notebooks the Card has no room for, which Another Notebook… lists.
    var hasMore: Bool { all.count > Self.cardLimit }

    /// With nothing to offer, the PDFs become notebooks without asking.
    var isEmpty: Bool { all.isEmpty }
}

extension IncomingPDFOffer.Notebook {
    init(_ record: NotebookRecord, takesPages: Bool) {
        self.init(id: record.id, title: record.title, lastOpenedAt: record.lastOpenedAt, modifiedAt: record.modifiedAt,
                  isTrashed: record.isTrashed, takesPages: takesPages)
    }
}
