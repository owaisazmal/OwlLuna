import SwiftUI
import Combine
import PencilKit

/// Today's page (or the offer to start a journal) and On This Day, under Continue writing.
struct DeskCards: View {
    let records: [NotebookRecord]
    let zoomNamespace: Namespace.ID
    var asRows = false
    let onOpen: (NotebookRecord, UUID?, String) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(FlashcardLibrary.self) private var flashcards
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.dailyJournalID) private var journalID = ""
    @AppStorage(SettingsKey.dailyJournalPromptHidden) private var promptHidden = false
    @AppStorage(SettingsKey.showsOnThisDay) private var showsOnThisDay = true
    @AppStorage(SettingsKey.onThisDayHiddenDay) private var hiddenDay = ""
    @State private var today = DailyJournal.dayKey(for: .now)
    @State private var manifest: NotebookManifest?
    @State private var resurfaced: Resurfaced?
    @State private var width: CGFloat = 0
    @State private var newJournalID = UUID()
    @State private var failure: String?
    @State private var isOpening = false

    private var journal: NotebookRecord? {
        guard let id = UUID(uuidString: journalID) else { return nil }
        return records.first { $0.id == id && !$0.isTrashed }
    }

    var body: some View {
        let journal = journal
        let offersJournal = journal == nil && !promptHidden && records.contains { !$0.isTrashed }
        let memory = memory(journal: journal)
        let studies = !StudyCard.notebooks(in: records).allSatisfy { flashcards.cards(in: $0).isEmpty }
        if asRows {
            todaySlot(journal, offersJournal: offersJournal).listRowBackground(Color.surface)
            if let memory { memoryCard(memory).listRowBackground(Color.surface) }
            if studies { studyCard.listRowBackground(Color.surface) }
        } else if journal != nil || offersJournal || memory != nil || studies {
            let sideBySide = sizeClass == .regular && !dynamicTypeSize.isAccessibilitySize && width >= 680
            let layout = sideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: Space.x4))
                                    : AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x3))
            let others = (journal != nil || offersJournal ? 1 : 0) + (memory != nil ? 1 : 0)
            // Two cards share a row; a third starts a row of its own, and one alone stays card-sized.
            let ownRow = studies && others == 2
            VStack(alignment: .leading, spacing: sideBySide ? Space.x4 : Space.x3) {
                layout {
                    todaySlot(journal, offersJournal: offersJournal)
                    if let memory { memoryCard(memory) }
                    if studies, !ownRow { studyCard }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: others + (studies && !ownRow ? 1 : 0) >= 2 ? .infinity : 520, alignment: .leading)
                if ownRow {
                    layout {
                        studyCard
                        if sideBySide { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }

    private var studyCard: some View {
        StudyCard(records: records, asRow: asRows) { notebook, page in
            guard let record = records.first(where: { $0.id == notebook && !$0.isTrashed }) else { return }
            onOpen(record, page, "cover-\(notebook.uuidString)")
        }
    }

    @ViewBuilder
    private func todaySlot(_ journal: NotebookRecord?, offersJournal: Bool) -> some View {
        if let journal {
            TodayCard(record: journal, manifest: manifest?.id == journal.id ? manifest : nil, today: today,
                      zoomNamespace: zoomNamespace, asRow: asRows) { openToday(journal) }
                .task(id: "\(journal.id)|\(journal.modifiedAt.timeIntervalSince1970)|\(journal.pageCount)|\(today)|\(records.count)") {
                    await load(journal)
                }
                .keepsDayCurrent($today, scenePhase: scenePhase)
        } else if offersJournal {
            StartJournalCard(today: today, zoomID: "today-\(newJournalID.uuidString)", zoomNamespace: zoomNamespace, asRow: asRows,
                             action: startJournal) { promptHidden = true }
                .keepsDayCurrent($today, scenePhase: scenePhase)
                .notice("The journal couldn't be created", message: $failure)
        }
    }

    private func memoryCard(_ memory: DeskMemory) -> some View {
        OnThisDayCard(memory: memory, zoomNamespace: zoomNamespace, asRow: asRows) {
            onOpen(memory.record, memory.page?.id, "onthisday-\(memory.record.id.uuidString)")
        } onHide: {
            hiddenDay = DailyJournal.dayKey(for: .now)
        } onTurnOff: {
            showsOnThisDay = false
        }
    }

    /// Without a journal there's nothing to read, so anniversaries are found here.
    private func memory(journal: NotebookRecord?) -> DeskMemory? {
        guard showsOnThisDay, hiddenDay != DailyJournal.dayKey(for: .now) else { return nil }
        let found = journal == nil ? Resurfaced.candidate(today: .now, calendar: .current, journal: nil, notebooks: notebooks) : resurfaced
        guard let found, let record = records.first(where: { $0.id == found.notebookID && !$0.isTrashed && !$0.isLocked }) else { return nil }
        guard let pageID = found.pageID else { return DeskMemory(resurfaced: found, record: record, page: nil, number: nil) }
        guard let manifest, manifest.id == record.id, let index = manifest.pages.firstIndex(where: { $0.id == pageID }) else { return nil }
        return DeskMemory(resurfaced: found, record: record, page: manifest.pages[index], number: index + 1)
    }

    private var notebooks: [(id: UUID, createdAt: Date, isTrashed: Bool)] {
        records.map { ($0.id, $0.createdAt, $0.isTrashed) }
    }

    private func load(_ journal: NotebookRecord) async {
        let package = NotebookPackage(root: store.root, id: journal.id)
        guard let loaded = try? await package.readManifest().manifest, !Task.isCancelled else { return }
        if loaded != manifest { manifest = loaded }
        let found = Resurfaced.candidate(today: .now, calendar: .current, journal: (journal.id, loaded.pages), notebooks: notebooks)
        if found != resurfaced { resurfaced = found }
    }

    private func openToday(_ journal: NotebookRecord) {
        guard !isOpening else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            let page = await store.prepareTodayPage(journal.id)
            onOpen(journal, page, "today-\(journal.id.uuidString)")
        }
    }

    private func startJournal() {
        guard !isOpening else { return }
        isOpening = true
        let id = newJournalID
        Task {
            defer { isOpening = false }
            do {
                try await store.createDailyJournal(id: id)
                guard let journal = store.record(id) else { return }
                onOpen(journal, journal.firstPageID, "today-\(id.uuidString)")
                newJournalID = UUID()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

struct DeskMemory {
    let resurfaced: Resurfaced
    let record: NotebookRecord
    let page: NotebookPage?
    let number: Int?
}

struct TodayCard: View {
    let record: NotebookRecord
    let manifest: NotebookManifest?
    let today: String
    let zoomNamespace: Namespace.ID
    var asRow = false
    let action: () -> Void
    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @PaperNight private var night
    @AppStorage(SettingsKey.evenHighlights) private var evenHighlights = false

    private var title: String { record.title.orUntitled }
    private var todayIndex: Int? { manifest?.pages.lastIndex { $0.day == today } }
    private var date: Date { DailyJournal.date(fromKey: today) ?? .now }
    private var dayText: String { date.formatted(.dayName) }

    /// Today's page, or the one tapping will add.
    private var preview: NotebookPage? {
        guard let manifest else { return nil }
        if let todayIndex { return manifest.pages[todayIndex] }
        return DailyJournal.makeTodayPage(after: manifest.pages, defaults: manifest.defaults, key: today, id: record.id)
    }

    private var isWritten: Bool { todayIndex.flatMap { manifest?.pages[$0].inkHash } != nil }

    private var place: String {
        guard let todayIndex else { return String(localized: "\(title) · a fresh page") }
        return isWritten ? String(localized: "\(title) · page \(todayIndex + 1) · written") : String(localized: "\(title) · page \(todayIndex + 1)")
    }

    var body: some View {
        let preview = preview
        Button(action: action) {
            DeskCardLayout(asRow: asRow) {
                DeskPage(image: image, page: preview, ribbon: record.cloth, width: asRow ? 44 : 56)
                    .zoomSource(id: "today-\(record.id.uuidString)", in: zoomNamespace)
            } text: {
                Text("Today")
                    .eyebrowStyle(Color.accentColor)
                Text(dayText)
                    .modifier(DeskTitle(asRow: asRow, lines: 1))
                Text(place)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.textSecondary)
            } accessory: {
                DeskAccessory(systemName: isWritten ? "checkmark" : "pencil.line")
            }
        }
        .buttonStyle(DeskCardButtonStyle())
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(todayIndex == nil ? Text("Start today's page in \(title)")
                            : isWritten ? Text("Today's page in \(title), \(dayText), written") : Text("Today's page in \(title), \(dayText)"))
        .accessibilityHint(Text("Opens the notebook at today's page"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("desk.today")
        .task(id: "\(preview?.id.uuidString ?? "")|\(preview?.thumbnailKey ?? "")|\(record.isLocked)|\(night)|\(evenHighlights)") { await loadImage(preview) }
    }

    private func loadImage(_ page: NotebookPage?) async {
        guard let page else { return }
        let loaded = todayIndex == nil || record.isLocked
            ? await BlankPages.image(page, night: night)
            : await PageThumbnailer.thumbnail(package: NotebookPackage(root: store.root, id: record.id), page: page, night: night, even: evenHighlights)
        guard !Task.isCancelled, let loaded else { return }
        withAnimation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion)) { image = loaded }
    }
}

struct StartJournalCard: View {
    let today: String
    let zoomID: String
    let zoomNamespace: Namespace.ID
    var asRow = false
    let action: () -> Void
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @PaperNight private var night

    private var preview: NotebookPage {
        var page = NotebookPage.template(NotebookStarter.journal.template, color: NotebookStarter.journal.paperColor, size: .letter)
        page.day = today
        return page
    }

    var body: some View {
        let preview = preview
        Button(action: action) {
            DeskCardLayout(asRow: asRow, quiet: true) {
                DeskPage(image: image, page: preview, ribbon: .moss, width: asRow ? 44 : 56)
                    .zoomSource(id: zoomID, in: zoomNamespace)
            } text: {
                Text("Start a daily journal")
                    .modifier(DeskTitle(asRow: asRow))
                Text("A page printed with each day's date, one tap away.")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            } accessory: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .overlay { RoundedRectangle.plate.strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1) }
            }
        }
        .buttonStyle(DeskCardButtonStyle())
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Start a daily journal"))
        .accessibilityHint(Text("Creates a journal and opens today's page"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Don't Show Again"), onDismiss)
        .heldMenu(Text("Daily Journal")) {
            Button(action: onDismiss) { Label("Don't Show Again", systemImage: "eye.slash") }
        }
        .task(id: "\(preview.thumbnailKey)|\(night)") {
            let loaded = await BlankPages.image(preview, night: night)
            withAnimation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion)) { image = loaded }
        }
    }
}

struct DeskCardLayout<Thumbnail: View, Content: View, Accessory: View>: View {
    var asRow: Bool
    var quiet = false
    @ViewBuilder var thumbnail: Thumbnail
    @ViewBuilder var text: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Space.x4) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) { text }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !asRow {
                Spacer(minLength: Space.x2)
                accessory
            }
        }
        .padding(.vertical, asRow ? Space.x1 : Space.x2 + 2)
        .padding(.leading, asRow ? 0 : Space.x3)
        .padding(.trailing, asRow ? 0 : Space.x4)
        .frame(maxWidth: asRow ? nil : .infinity, maxHeight: asRow ? nil : .infinity, alignment: .leading)
        .background {
            if !asRow {
                let shape = RoundedRectangle.plate
                if quiet {
                    shape.strokeBorder(Color.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                } else {
                    shape.fill(Color.surface).overlay { shape.strokeBorder(Color.hairline, lineWidth: 1) }
                }
            }
        }
        .contentShape(RoundedRectangle.plate)
    }
}

/// The tinted symbol at the end of a desk card, which swaps when what the card says changes.
struct DeskAccessory: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 36, height: 36)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle.plate)
            .contentTransition(.symbolEffect(.replace))
    }
}

struct DeskTitle: ViewModifier {
    let asRow: Bool
    var lines = 2

    func body(content: Content) -> some View {
        Group {
            if asRow {
                content.font(.headline)
            } else {
                content.displayFont(21, relativeTo: .title3).lineLimit(lines).minimumScaleFactor(lines == 1 ? 0.75 : 0.85)
            }
        }
        .foregroundStyle(Color.ink)
    }
}

struct DeskPage: View {
    let image: UIImage?
    let page: NotebookPage?
    var ribbon: ClothColor?
    var width: CGFloat = 56
    @PaperNight private var night

    var body: some View {
        let aspect = page.map { $0.shownSize.width / max($0.shownSize.height, 1) } ?? PageSize.letter.points.width / PageSize.letter.points.height
        let height = min((width / aspect).rounded(), 76)
        let pageWidth = min(width, (height * aspect).rounded())
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
            } else {
                Color(uiColor: page?.paperShown(night: night) ?? PageRenderer.paperColor(.ivory, night: night))
            }
        }
        .frame(width: pageWidth, height: height)
        .clipped()
        .overlay { Rectangle().strokeBorder(Color.hairline, lineWidth: 1) }
        .overlay(alignment: .topTrailing) {
            if let ribbon {
                RibbonShape()
                    .fill(ribbon.color)
                    .overlay { RibbonShape().stroke(Color.labelCream, lineWidth: 1) }
                    .frame(width: 9, height: height * 0.46)
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                    .padding(.trailing, Space.x2)
                    .offset(y: -2)
            }
        }
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                leaf.offset(x: 4, y: 4)
                leaf.offset(x: 2, y: 2)
            }
        }
        .padding(.trailing, 4)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
    }

    private var leaf: some View {
        Color.labelCream.overlay { Rectangle().strokeBorder(Color.hairline, lineWidth: 1) }
    }
}

struct DeskCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

enum BlankPages {
    private static let images = LRUCache<PageThumbnailer.SharedUIImage>(capacity: 8)

    static func image(_ page: NotebookPage, night: Bool = false) async -> UIImage? {
        let key = PageThumbnailer.key(for: page, night: night, even: false) + page.appearanceKey
        if let hit = images.value(key, create: { nil }) { return hit.image }
        let image = await Task.detached(priority: .utility) {
            PageThumbnailer.render(page: page, ink: PKDrawing(), assets: FileManager.default.temporaryDirectory, night: night, even: false)
        }.value
        return images.value(key) { PageThumbnailer.SharedUIImage(image: image) }?.image
    }
}

private extension View {
    /// Moves `today` on at midnight and when the app comes back to the front.
    func keepsDayCurrent(_ today: Binding<String>, scenePhase: ScenePhase) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in
            today.wrappedValue = DailyJournal.dayKey(for: .now)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { today.wrappedValue = DailyJournal.dayKey(for: .now) }
        }
    }
}
