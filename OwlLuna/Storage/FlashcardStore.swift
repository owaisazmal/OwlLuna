import UIKit
import os

/// The files flashcards live in: `cards.json` beside a notebook's manifest and clippings in its `cards/` folder,
/// so they are copied, backed up, synced and deleted with the notebook. Thread-safe.
enum CardFiles {
    struct Deck: Sendable, Equatable {
        var cards: [Flashcard] = []
        /// When each deleted card was deleted.
        var removed: [UUID: Date] = [:]
        /// Written by a newer version, or set aside as damaged: shown, never written over.
        var isReadOnly = false

        /// The clippings its cards name.
        var clippings: Set<String> { Set(cards.flatMap { [$0.front.image, $0.back.image] }.compactMap { $0 }) }

        /// Both copies' cards, each as it was last changed, less those deleted since: the same rule as a page, where
        /// writing wins over a delete. This copy's order is kept, with cards only the other has after it.
        func merged(with other: Deck) -> Deck {
            let removed = removed.merging(other.removed, uniquingKeysWith: max)
            let theirs = Dictionary(other.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ours = Set(cards.map(\.id))
            var cards = cards.map { card in
                guard let their = theirs[card.id], their.stamp > card.stamp || (their.stamp == card.stamp && their.reviews > card.reviews) else { return card }
                return their
            }
            cards += other.cards.filter { !ours.contains($0.id) }
            cards.removeAll { card in removed[card.id].map { $0 >= card.stamp } ?? false }
            return Deck(cards: cards, removed: removed)
        }
    }

    static func file(in package: URL) -> URL { package.appending(path: "cards.json") }
    static func directory(in package: URL) -> URL { package.appending(path: "cards", directoryHint: .isDirectory) }
    static func imageURL(_ name: String, in package: URL) -> URL { directory(in: package).appending(path: name) }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func read(_ package: URL) -> Deck {
        let url = file(in: package)
        guard let data = try? Data(contentsOf: url) else { return Deck() }
        return deck(from: data) ?? Deck(isReadOnly: (try? Quarantine.move(url)) == nil)
    }

    /// Nil for a file that can't be read.
    static func deck(from data: Data) -> Deck? {
        guard let decoded = try? decoder.decode(FlashcardFile.self, from: data) else { return nil }
        let removed = (decoded.removed ?? [:]).reduce(into: [UUID: Date]()) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
        return Deck(cards: decoded.cards, removed: removed, isReadOnly: decoded.version > FlashcardFile.currentVersion)
    }

    /// Never brings back a notebook that was deleted while a review was going on. A deck whose cards were all deleted
    /// keeps a file for as long as it says so.
    static func write(_ deck: Deck, to package: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: package.appending(path: NotebookPackage.manifestFile).path(percentEncoded: false)) else { throw PackageError.missing }
        let url = file(in: package)
        if deck.cards.isEmpty, deck.removed.isEmpty {
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) { try fileManager.removeItem(at: url) }
            try? fileManager.removeItem(at: directory(in: package))
            return
        }
        let removed = Dictionary(uniqueKeysWithValues: deck.removed.map { ($0.key.uuidString, FlashcardFile.second($0.value)) })
        try encoder.encode(FlashcardFile(cards: deck.cards, removed: removed.isEmpty ? nil : removed)).write(to: url, options: .atomic)
        let kept = deck.clippings, folder = directory(in: package)
        // A clipping is written before the card that names it, and a deleted card may be put back, so only ones left over for a while are cleared.
        let stale = Date.now.addingTimeInterval(-600)
        for image in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where !kept.contains(image.lastPathComponent) {
            let written = image.contentModificationDate ?? .distantPast
            if written < stale { try? fileManager.removeItem(at: image) }
        }
        if deck.cards.isEmpty, (try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?.isEmpty == true {
            try? fileManager.removeItem(at: folder)
        }
    }

    /// Writes `deck` card by card over what the file holds now, so cards a sync or a restore brought in meanwhile stay.
    static func save(_ deck: Deck, to package: URL) throws {
        let current = read(package)
        guard !current.isReadOnly else { throw PackageError.readOnly }
        let merged = deck.merged(with: current)
        guard merged != current else { return }
        // A clipping no card names any more counts as left over from now, so an undone delete still finds it.
        for name in current.clippings.subtracting(merged.clippings) {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: imageURL(name, in: package).path(percentEncoded: false))
        }
        try write(merged, to: package)
    }

    /// Gives every card in a copied notebook an ID of its own, so the copy's cards are never taken for the original's.
    static func renew(in package: URL) throws {
        let deck = read(package)
        guard !deck.isReadOnly, !deck.cards.isEmpty || !deck.removed.isEmpty else { return }
        try write(Deck(cards: deck.cards.map { card in
            var card = card
            card.id = UUID()
            return card
        }), to: package)
    }

    static func writeImage(_ png: Data, in package: URL) throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: package.appending(path: NotebookPackage.manifestFile).path(percentEncoded: false)) else { throw PackageError.missing }
        let folder = directory(in: package)
        if !fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let name = "\(UUID().uuidString).png"
        try png.write(to: folder.appending(path: name), options: .atomic)
        return name
    }
}

/// Writes decks one after another, so a quick run of answers lands on disk in the order it was given.
private actor CardWriter {
    func write(_ deck: CardFiles.Deck, to package: URL) -> (any Error)? {
        do {
            try CardFiles.save(deck, to: package)
            return nil
        } catch {
            return error
        }
    }

    func writeImage(_ png: Data, in package: URL) throws -> String {
        try CardFiles.writeImage(png, in: package)
    }
}

/// A card and the notebook it belongs to.
struct DeckCard: Identifiable, Equatable, Sendable {
    let notebook: UUID
    var card: Flashcard
    var id: UUID { card.id }
}

/// Every notebook's flashcards, read once at launch and kept in step with the files.
@MainActor
@Observable
final class FlashcardLibrary {
    let root: StorageRoot
    private(set) var decks: [UUID: [Flashcard]] = [:]
    private(set) var readOnly: Set<UUID> = []
    private(set) var isLoaded = false
    /// Set when changes to the cards couldn't be written. They stay here and go with the next change that can be.
    private(set) var lastError: String?
    /// Called after every write, so a sync can follow it.
    @ObservationIgnored var onSaved: (() -> Void)?
    /// Cards deleted here, kept so a write never takes one back from the file.
    @ObservationIgnored private var removals: [UUID: [UUID: Date]] = [:]
    @ObservationIgnored private let writer = CardWriter()
    @ObservationIgnored private let log = Logger(category: "flashcards")
    @ObservationIgnored private let images = LRUCache<PageThumbnailer.SharedUIImage>(capacity: 40)

    init(root: StorageRoot) {
        self.root = root
    }

    func clearError() { lastError = nil }

    private func deck(_ notebook: UUID) -> CardFiles.Deck {
        CardFiles.Deck(cards: decks[notebook] ?? [], removed: removals[notebook] ?? [:])
    }

    /// Reads every notebook's cards. Called at launch and after a sync or a restore changed the library on disk.
    /// A change made here that isn't written yet is kept: each card goes by when it was last changed.
    func load() async {
        let root = root, held = Set(decks.keys).union(removals.keys)
        let (found, gone) = await Task.detached(priority: .utility) {
            var decks: [UUID: CardFiles.Deck] = [:]
            let ids = root.packageIDs()
            for id in ids {
                let deck = CardFiles.read(root.package(id))
                if !deck.cards.isEmpty || !deck.removed.isEmpty || deck.isReadOnly { decks[id] = deck }
            }
            return (decks, held.subtracting(ids))
        }.value
        var decks: [UUID: [Flashcard]] = [:], removals: [UUID: [UUID: Date]] = [:]
        for id in Set(found.keys).union(self.decks.keys).union(self.removals.keys) where !gone.contains(id) {
            let read = found[id] ?? CardFiles.Deck()
            let deck = read.isReadOnly ? read : self.deck(id).merged(with: read)
            if !deck.cards.isEmpty { decks[id] = deck.cards }
            if !deck.removed.isEmpty { removals[id] = deck.removed }
        }
        self.decks = decks
        self.removals = removals
        readOnly = Set(found.filter(\.value.isReadOnly).keys)
        isLoaded = true
    }

    /// Picks up notebooks that appeared since the last load: a duplicate carries its cards with it.
    func loadNewNotebooks() async {
        guard isLoaded else { return }
        let root = root, known = Set(decks.keys).union(removals.keys).union(readOnly)
        let found = await Task.detached(priority: .utility) {
            var decks: [UUID: CardFiles.Deck] = [:]
            for id in root.packageIDs() where !known.contains(id) {
                guard FileManager.default.fileExists(atPath: CardFiles.file(in: root.package(id)).path(percentEncoded: false)) else { continue }
                decks[id] = CardFiles.read(root.package(id))
            }
            return decks
        }.value
        for (id, deck) in found where decks[id] == nil && removals[id] == nil {
            if !deck.cards.isEmpty { decks[id] = deck.cards }
            if !deck.removed.isEmpty { removals[id] = deck.removed }
            if deck.isReadOnly { readOnly.insert(id) }
        }
    }

    func forget(notebooks: [UUID]) {
        for id in notebooks {
            decks[id] = nil
            removals[id] = nil
            readOnly.remove(id)
        }
    }

    // MARK: Reading

    func cards(in notebook: UUID) -> [Flashcard] { decks[notebook] ?? [] }

    func canChange(_ notebook: UUID) -> Bool { !readOnly.contains(notebook) }

    func card(for tape: UUID, in notebook: UUID) -> Flashcard? { decks[notebook]?.first { $0.tapeID == tape } }

    /// The cards to go through today, the longest overdue first.
    func due(in notebooks: some Sequence<UUID>, on day: String = ActivityFile.dayKey(for: .now, calendar: .current)) -> [DeckCard] {
        notebooks.flatMap { id in cards(in: id).filter { $0.isDue(on: day) }.map { DeckCard(notebook: id, card: $0) } }
            .sorted { ($0.card.due, $0.card.createdAt) < ($1.card.due, $1.card.createdAt) }
    }

    func all(in notebooks: some Sequence<UUID>) -> [DeckCard] {
        notebooks.flatMap { id in cards(in: id).map { DeckCard(notebook: id, card: $0) } }
            .sorted { ($0.card.due, $0.card.createdAt) < ($1.card.due, $1.card.createdAt) }
    }

    /// The same cards as they stand now, without any deleted since.
    func refreshed(_ cards: [DeckCard]) -> [DeckCard] {
        cards.compactMap { old in decks[old.notebook]?.first { $0.id == old.id }.map { DeckCard(notebook: old.notebook, card: $0) } }
    }

    /// The first day after `day` on which a card comes due.
    func nextDue(in notebooks: some Sequence<UUID>, after day: String = ActivityFile.dayKey(for: .now, calendar: .current)) -> String? {
        notebooks.flatMap { cards(in: $0).map(\.due) }.filter { $0 > day }.min()
    }

    func imageURL(_ name: String, in notebook: UUID) -> URL { CardFiles.imageURL(name, in: root.package(notebook)) }

    func image(_ name: String?, in notebook: UUID) async -> UIImage? {
        guard let name else { return nil }
        let url = imageURL(name, in: notebook), key = url.path(percentEncoded: false)
        if let hit = images.value(key, create: { nil }) { return hit.image }
        let loaded = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: key).map { PageThumbnailer.SharedUIImage(image: $0.preparingForDisplay() ?? $0) }
        }.value
        guard let loaded else { return nil }
        return images.value(key) { loaded }?.image
    }

    // MARK: Changing

    @discardableResult
    func add(_ cards: [Flashcard], to notebook: UUID) -> Bool {
        guard canChange(notebook), !cards.isEmpty else { return false }
        decks[notebook, default: []].append(contentsOf: cards)
        save(notebook)
        return true
    }

    func update(_ card: Flashcard, in notebook: UUID, now: Date = .now) {
        guard canChange(notebook), let index = decks[notebook]?.firstIndex(where: { $0.id == card.id }) else { return }
        var card = card
        card.changedAt = now
        decks[notebook]?[index] = card
        save(notebook)
    }

    func remove(_ ids: Set<UUID>, from notebook: UUID, now: Date = .now) {
        guard canChange(notebook), decks[notebook] != nil else { return }
        decks[notebook]?.removeAll { ids.contains($0.id) }
        if decks[notebook]?.isEmpty == true { decks[notebook] = nil }
        for id in ids { removals[notebook, default: [:]][id] = FlashcardFile.second(now) }
        save(notebook)
    }

    /// Puts a deleted card back at `index`, as it was. It is stamped after its delete, so the delete gives way to it on every iPad.
    func restore(_ card: Flashcard, at index: Int, in notebook: UUID, now: Date = .now) {
        guard canChange(notebook), decks[notebook]?.contains(where: { $0.id == card.id }) != true else { return }
        var card = card
        let deleted = removals[notebook]?[card.id] ?? .distantPast
        card.changedAt = max(FlashcardFile.second(now), deleted.addingTimeInterval(1))
        var cards = decks[notebook] ?? []
        cards.insert(card, at: min(max(index, 0), cards.count))
        decks[notebook] = cards
        save(notebook)
    }

    /// Records an answer and returns the card as it now stands.
    @discardableResult
    func grade(_ id: UUID, in notebook: UUID, _ grade: CardGrade, now: Date = .now, calendar: Calendar = .current) -> Flashcard? {
        guard let card = decks[notebook]?.first(where: { $0.id == id }) else { return nil }
        let next = CardSchedule.graded(card, grade, now: now, calendar: calendar)
        update(next, in: notebook, now: now)
        return canChange(notebook) ? next : card
    }

    /// Keeps a clipping in the notebook, ready to be named by a card.
    func saveClipping(_ image: UIImage, in notebook: UUID) async throws -> String {
        guard canChange(notebook) else { throw PackageError.readOnly }
        guard let png = image.pngData() else { throw ImportError.unreadable }
        return try await writer.writeImage(png, in: root.package(notebook))
    }

    /// Waits until everything changed so far is on disk.
    func flush() async {
        await pending?.value
    }

    @ObservationIgnored private var pending: Task<Void, Never>?

    /// Until the deck is written a sync leaves the notebook alone, and one that has it in hand finishes first, so an
    /// answer given during a pull lands on what the pull brought in.
    private func save(_ notebook: UUID) {
        let deck = deck(notebook), package = root.package(notebook), writer = writer, previous = pending, registry = DocumentRegistry.shared
        registry.willChange(notebook)
        pending = Task { [weak self] in
            await previous?.value
            await registry.whenReleased(notebook)
            let failure = await writer.write(deck, to: package)
            registry.didChange(notebook)
            guard let self else { return }
            switch failure {
            case nil: onSaved?()
            // The notebook was deleted while its cards were open.
            case PackageError.missing?: break
            case let error?:
                log.error("flashcards for \(notebook.uuidString) couldn't be saved: \(error.localizedDescription)")
                lastError = String(localized: "Flashcards couldn't be saved: \(error.localizedDescription)")
            }
        }
    }
}
