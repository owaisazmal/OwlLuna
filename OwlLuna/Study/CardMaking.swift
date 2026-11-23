import UIKit
import PencilKit

/// A flashcard being written or changed. A side's clipping is either already in the notebook or still only a picture.
struct CardDraft: Identifiable {
    struct Side {
        var text = ""
        var imageName: String?
        var newImage: UIImage?
        /// What the clipping reads as, kept with it.
        var imageText: String?
        /// On a tape card, whether this is the clipping with the tape lifted. It goes with the side when they are swapped.
        var isLifted = false

        var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && imageName == nil && newImage == nil }
    }

    let id = UUID()
    /// The card being changed; nil for a new one.
    var card: Flashcard?
    var front = Side()
    var back = Side()
    var pageID: UUID?
    /// What a tape card's clippings were cut from.
    var clip: CardClip?

    var isComplete: Bool { !front.isEmpty && !back.isEmpty }

    init(pageID: UUID? = nil, answer: UIImage? = nil, answerText: String? = nil) {
        self.pageID = pageID
        back.newImage = answer
        back.imageText = answerText
    }

    init(editing card: Flashcard) {
        self.card = card
        front = Side(text: card.front.text, imageName: card.front.image, imageText: card.front.imageText)
        back = Side(text: card.back.text, imageName: card.back.image, imageText: card.back.imageText)
        back.isLifted = card.tapeID != nil
        pageID = card.pageID
        clip = card.clip
    }

    /// Takes a tape card's clippings as they were cut again. A side that has lost its clipping stays without one.
    mutating func recut(_ cut: CardClipping.TapeCut) {
        func take(_ side: inout Side) {
            guard side.imageName != nil || side.newImage != nil else { return }
            side.newImage = side.isLifted ? cut.back : cut.front
            side.imageName = nil
            side.imageText = side.isLifted ? cut.backText : cut.frontText
        }
        take(&front)
        take(&back)
        clip = cut.clip
    }

    mutating func swapSides() {
        swap(&front, &back)
    }
}

extension FlashcardLibrary {
    /// Keeps a draft as a card of `notebook`: a new card is due today, a changed one keeps its place in the schedule.
    @discardableResult
    func save(_ draft: CardDraft, in notebook: UUID) async throws -> Flashcard {
        func side(_ side: CardDraft.Side) async throws -> CardSide {
            var name = side.imageName
            if let image = side.newImage { name = try await saveClipping(image, in: notebook) }
            return CardSide(text: side.text.trimmingCharacters(in: .whitespacesAndNewlines), image: name, imageText: name == nil ? nil : side.imageText)
        }
        let front = try await side(draft.front), back = try await side(draft.back)
        if var card = draft.card {
            card.front = front
            card.back = back
            card.clip = front.image == nil && back.image == nil ? nil : draft.clip
            update(card, in: notebook)
            return card
        }
        let card = Flashcard(front: front, back: back, pageID: draft.pageID)
        guard add([card], to: notebook) else { throw PackageError.readOnly }
        return card
    }
}

extension EditorSession {
    /// Strips of study tape that no card has been made from yet, in page order.
    func tapesWithoutCards(in library: FlashcardLibrary) -> [(page: NotebookPage, tape: PageItem)] {
        let made = Set(library.cards(in: document.id).compactMap(\.tapeID))
        return document.pages.filter(\.hasItems).flatMap { page in
            page.items.filter { $0.tape != nil && !made.contains($0.id) }.map { (page, $0) }
        }
    }

    /// A card whose question is the page with the tape on and whose answer is the page with it lifted. It keeps a record
    /// of the part of the page it was cut from.
    @discardableResult
    func makeCard(from tape: PageItem, on page: NotebookPage, in library: FlashcardLibrary) async throws -> Flashcard {
        let ink = await document.ink(page.id), assets = document.package.assetsDirectory
        let cut = await Task.detached(priority: .userInitiated) {
            await CardClipping.cut(tape, on: page, ink: ink, assets: assets,
                                   region: CardClipping.startingRegion(around: tape, on: page, ink: ink, assets: assets))
        }.value
        let front = try await library.saveClipping(cut.front, in: document.id)
        let back = try await library.saveClipping(cut.back, in: document.id)
        var card = Flashcard(front: CardSide(image: front, imageText: cut.frontText), back: CardSide(image: back, imageText: cut.backText),
                             pageID: page.id, tapeID: tape.id)
        card.clip = cut.clip
        guard library.add([card], to: document.id) else { throw PackageError.readOnly }
        return card
    }

    /// The selected handwriting as it looks on its page, and what it reads as, ready to be one side of a card.
    func inkClipping() async -> (image: UIImage, text: String?, pageID: UUID)? {
        guard let pieces = canvas?.selectedInkByPage(), let first = pieces.first else { return nil }
        let pages = pieces.compactMap { piece in document.pages.first { $0.id == piece.pageID }.map { (page: $0, ink: piece.ink) } }
        let assets = document.package.assetsDirectory
        async let read = InkText.recognizeInBackground(pages.prefix(3).map(\.ink))
        guard let image = await Task.detached(priority: .userInitiated, operation: { CardClipping.inkImage(pages, assets: assets) }).value else { return nil }
        let text = await read?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (image, text?.isEmpty == false ? text : nil, first.pageID)
    }
}
