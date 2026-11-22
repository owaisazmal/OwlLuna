import SwiftUI
import SwiftData

/// PDFs from another app waiting to be told where they go, and the pages going into a notebook once one is chosen.
@MainActor
@Observable
final class IncomingPDFDesk {
    /// Where the pages went, for the slip.
    struct Added: Identifiable {
        let id = UUID()
        let notebook: UUID
        let message: String
        let firstPage: UUID?
    }

    /// The PDFs the Card asks about, in the order they came.
    private(set) var asking: [URL] = []
    /// The file names the Card is named after, kept while it closes.
    private(set) var names: [String] = []
    var showsCard = false
    private(set) var showsList = false
    private(set) var run: PDFImportRun?
    var added: Added?
    /// Another Notebook… was chosen: the PDFs wait for the list.
    private var listing = false

    /// Hands PDFs to the shelf, which makes a notebook of each in the folder on show.
    @ObservationIgnored var toShelf: ([URL]) -> Void = { _ in }
    /// Opens a notebook at a page, or goes to the page if the notebook is on show.
    @ObservationIgnored var open: (UUID, UUID?) -> Void = { _, _ in }
    @ObservationIgnored var isOnShow: (UUID) -> Bool = { _ in false }

    /// Whether the Card waits for the screen in front to be free. Not while pages from the last are still going in.
    var waits: Bool { !asking.isEmpty && !showsCard && !showsList && !listing && run?.isFinished != false }

    /// PDFs shared in, opened from Files or dropped on the icon. With no notebook to take them they become notebooks without asking.
    func receive(_ urls: [URL], store: LibraryStore) {
        guard !urls.isEmpty else { return }
        if asking.isEmpty, Self.offer(in: store).isEmpty { return toShelf(urls) }
        if asking.isEmpty { names = [] }
        asking += urls
        names += urls.map(\.lastPathComponent)
    }

    /// New Notebook: what a shared PDF always did.
    func makeNotebooks() {
        toShelf(take())
    }

    /// Adds every waiting PDF's pages after the notebook's last page, in the order they came.
    func add(to id: UUID, title: String, store: LibraryStore) {
        let urls = take()
        guard !urls.isEmpty else { return }
        let run = PDFImportRun(), tally = Tally()
        self.run = run
        run.add(urls) { url, password, progress in
            defer { IncomingPDFs.discard(url) }
            tally.pages += try await store.addPDF(from: url, to: id, password: password, progress: progress)
        }
        Task {
            await run.finish()
            added(tally.pages, to: id, title: store.record(id)?.title ?? title)
        }
    }

    func chooseAnother() {
        listing = true
    }

    func openList() {
        listing = false
        showsList = !asking.isEmpty
    }

    /// The Card has closed. Tapped away or Escape, nothing comes in and the copies made for the app go.
    func cardClosed() {
        showsCard = false
        if !listing { discard() }
    }

    func listClosed() {
        showsList = false
        discard()
    }

    func endRun(_ ended: PDFImportRun) {
        if run === ended { run = nil }
    }

    private func take() -> [URL] {
        defer { asking = [] }
        return asking
    }

    private func discard() {
        for url in take() { IncomingPDFs.discard(url) }
    }

    private func added(_ pages: [UUID], to id: UUID, title: String) {
        guard !pages.isEmpty else { return }
        let message = String(localized: "Added \(pages.count) pages to “\(title.orUntitled)”")
        AccessibilityNotification.Announcement(message).post()
        if isOnShow(id) {
            open(id, pages.first)
        } else {
            added = Added(notebook: id, message: message, firstPage: pages.first)
        }
    }

    @MainActor
    private final class Tally {
        var pages: [UUID] = []
    }

    // MARK: What is offered

    static func offer(_ records: [NotebookRecord], store: LibraryStore) -> IncomingPDFOffer {
        IncomingPDFOffer(records.map { IncomingPDFOffer.Notebook($0, takesPages: store.takesPages($0)) })
    }

    static func offer(in store: LibraryStore) -> IncomingPDFOffer {
        let records = (try? store.context.fetch(FetchDescriptor<NotebookRecord>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        return offer(records, store: store)
    }
}

extension View {
    /// The Card for PDFs from another app, its list and the pages going in, over this screen while it is in front, centred beside `leading`.
    func incomingPDFs(_ desk: IncomingPDFDesk, active: Bool, leading: CGFloat = 0, clearsSearch: Bool = false,
                      edge: VerticalEdge = .bottom) -> some View {
        modifier(IncomingPDFStage(desk: desk, active: active, leading: leading, clearsSearch: clearsSearch, edge: edge))
    }
}

/// With no button to hang from, the Card hangs from the foot of the bar, or of the shelf's search, in the middle of what is on show.
private struct IncomingPDFStage: ViewModifier {
    let desk: IncomingPDFDesk
    let active: Bool
    let leading: CGFloat
    let clearsSearch: Bool
    let edge: VerticalEdge
    @State private var front = FrontSpot()
    @State private var size = CGSize.zero

    static let cardWidth: CGFloat = 380
    private static let barFoot: CGFloat = 56
    private static let searchFoot: CGFloat = 104

    func body(content: Content) -> some View {
        content
            .background {
                Color.clear
                    .background(FrontProbe(spot: front))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                    .cardMenu(title, isPresented: Binding(get: { active && desk.showsCard }, set: { if !$0 { desk.cardClosed() } }),
                              under: place) {
                        IncomingPDFRows(desk: desk)
                    }
            }
            .overlay(alignment: edge == .top ? .top : .bottom) {
                if active {
                    IncomingPDFNews(desk: desk, edge: edge)
                        .padding(.leading, leading)
                        .padding(.top, edge == .top ? Self.barFoot : 0)
                }
            }
            .sheet(isPresented: Binding(get: { active && desk.showsList }, set: { if !$0 { desk.listClosed() } })) {
                IncomingPDFList(desk: desk)
                    .presentationCornerRadius(Radius.sheet)
                    .appModels()
            }
            .task(id: active && desk.waits) { await askOnceInFront() }
    }

    /// A name too long for the band is cut in the middle, keeping its end, so it doesn't widen the Card off the middle.
    private var title: Text {
        let names = desk.names
        guard names.count == 1 else { return Text("Import \(names.count) PDFs") }
        let name = names[0], room = Self.cardWidth - Space.x3 * 2
        let plain = UIFont.preferredFont(forTextStyle: .subheadline)
        let font = UIFont(descriptor: plain.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]]),
                          size: 0)
        var shown = name, kept = name.count
        while (String(localized: "Import “\(shown)”") as NSString).size(withAttributes: [.font: font]).width > room, kept > 8 {
            kept -= 2
            shown = "\(name.prefix(kept / 2))…\(name.suffix(kept - kept / 2))"
        }
        return Text("Import “\(shown)”").accessibilityLabel(Text("Import “\(name)”"))
    }

    private var place: CGRect {
        let room = max(size.width - leading, 0), width = min(Self.cardWidth, max(room - 16, 0))
        return CGRect(x: leading + (room - width) / 2, y: min(clearsSearch ? Self.searchFoot : Self.barFoot, size.height / 4), width: width, height: 0)
    }

    /// Nothing else is put away for the Card: a sheet or a card already up is finished with first.
    private func askOnceInFront() async {
        while active, desk.waits, !Task.isCancelled {
            if front.isFront {
                desk.showsCard = true
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

/// Whether the screen a view stands on is in front, with nothing presented over it.
@MainActor
private final class FrontSpot {
    weak var view: UIView?

    var isFront: Bool {
        guard let view, var top = view.window?.rootViewController else { return false }
        while let presented = top.presentedViewController {
            if presented.isBeingDismissed { return false }
            top = presented
        }
        return view.isDescendant(of: top.view)
    }
}

private struct FrontProbe: UIViewRepresentable {
    let spot: FrontSpot

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        spot.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { spot.view = view }
}

/// New Notebook, then the notebooks opened last; a row hands the PDFs on before the Card closes, so that isn't taken for a tap away.
private struct IncomingPDFRows: View {
    let desk: IncomingPDFDesk
    @Environment(\.panelClose) private var close
    @Environment(LibraryStore.self) private var store
    @Query(filter: #Predicate<NotebookRecord> { $0.deletedAt == nil }) private var records: [NotebookRecord]
    /// Grows with the rows' words, so a symbol stays inside it and every row's words start in one line.
    @ScaledMetric(relativeTo: .callout) private var iconColumn: CGFloat = 28

    var body: some View {
        let offer = IncomingPDFDesk.offer(records, store: store)
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let notebooks = offer.onCard.compactMap { byID[$0] }
        VStack(alignment: .leading, spacing: 0) {
            Button { choose(desk.makeNotebooks) } label: {
                row { Image(systemName: "book.closed") } text: { Text("New Notebook") }
            }
            .menuChosen(true)
            .environment(\.panelClose, nil)
            .accessibilityIdentifier("incomingPDF.new")
            if !notebooks.isEmpty {
                Text("Add to a Notebook")
                    .sectionBand()
                    .overlay(alignment: .top) { HairlineRule() }
                    .overlay(alignment: .bottom) { HairlineRule() }
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(notebooks.enumerated()), id: \.element.id) { index, record in
                    Button { choose { desk.add(to: record.id, title: record.title, store: store) } } label: {
                        row {
                            RecordCover(record: record, width: max(CoverWidth.row, iconColumn), showsShadow: false).accessibilityHidden(true)
                        } text: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.title.orUntitled).lineLimit(2)
                                Text(record.pageCountText)
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                    }
                    .environment(\.panelClose, nil)
                    .overlay(alignment: .top) { if index > 0 { HairlineRule() } }
                    .accessibilityHint(Text("Adds the pages after its last page."))
                    .accessibilityIdentifier("incomingPDF.notebook.\(record.title)")
                }
                if offer.hasMore {
                    Button {
                        desk.chooseAnother()
                        close?(then: desk.openList)
                    } label: {
                        row { Image(systemName: "books.vertical") } text: { Text("Another Notebook…") }
                    }
                    .environment(\.panelClose, nil)
                    .overlay(alignment: .top) { HairlineRule() }
                    .accessibilityIdentifier("incomingPDF.another")
                }
            }
        }
        .frame(minWidth: 0, idealWidth: IncomingPDFStage.cardWidth + Space.x5, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("incomingPDF.card")
    }

    private func choose(_ action: () -> Void) {
        action()
        close?()
    }

    /// A small cover or a symbol in one column, the words beside it.
    private func row<Icon: View, Words: View>(@ViewBuilder icon: () -> Icon, @ViewBuilder text: () -> Words) -> some View {
        HStack(spacing: Space.x3) {
            icon().frame(width: iconColumn)
            text()
        }
    }
}

/// Over the screen in front: the pages going in, then the slip saying where they went.
private struct IncomingPDFNews: View {
    let desk: IncomingPDFDesk
    let edge: VerticalEdge
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let run = desk.run { PDFImportStatus(run: run, edge: edge) { desk.endRun(run) }.id(ObjectIdentifier(run)) }
            ZStack {
                if let added = desk.added {
                    IncomingPDFSlip(added: added) {
                        desk.added = nil
                        desk.open(added.notebook, added.firstPage)
                    } dismiss: {
                        desk.added = nil
                    }
                    .padding(edge == .bottom ? .bottom : .top, Space.x4)
                    .transition(reduceMotion ? .opacity : .move(edge: edge == .bottom ? .bottom : .top).combined(with: .opacity))
                }
            }
            .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: desk.added?.id)
        }
        .task(id: desk.added?.id) {
            guard desk.added != nil, !voiceOver, !LaunchOptions.keepsUndoVisible else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { desk.added = nil }
        }
    }
}

/// The library's slip for pages added to a notebook, with Open in place of Undo.
private struct IncomingPDFSlip: View {
    let added: IncomingPDFDesk.Added
    let open: () -> Void
    let dismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x2)) : AnyLayout(HStackLayout(spacing: Space.x3))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: Space.x3) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
                Text(added.message)
                    .font(.subheadline)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            HStack(spacing: Space.x1) {
                Button("Open", action: open)
                    .buttonStyle(.owlLuna(.primary, compact: true))
                    .accessibilityIdentifier("incomingPDF.slip.open")
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.textSecondary)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.leading, Space.x4)
        .padding(.trailing, Space.x1)
        .padding(.vertical, stacked ? Space.x3 : Space.x1)
        .frame(maxWidth: 520)
        .board(in: RoundedRectangle.bar)
        .padding(.horizontal, Space.x4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("incomingPDF.slip")
    }
}
