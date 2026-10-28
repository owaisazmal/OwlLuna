import SwiftUI
import PencilKit

/// What the chrome needs from the page canvas, whatever its implementation.
@MainActor
protocol EditorCanvasControlling: AnyObject {
    func scrollToPage(_ index: Int, animated: Bool)
    func toolTrayDidChange()
    func setModalShowing(_ showing: Bool)
    func setDrawingPolicy(_ policy: PKCanvasViewDrawingPolicy)
    func fit(_ fit: PageFit)
    func setPresenting(_ presenting: Bool)
    func present(page index: Int)
    func setLaserColor(_ color: LaserColor)
    func visibleCenter(ofPage index: Int) -> CGPoint?
    func visibleRect(ofPage index: Int) -> CGRect?
    func select(_ selection: ItemSelection?)
    func editText()
    func beginCrop()
    func endCrop(keeping: Bool)
    func resetCrop()
    func linksDidChange()
    func showReplay(_ timeline: ReplayTimeline?, at time: TimeInterval)
    func paneBecameActive()
    func setSelectingInk(_ selecting: Bool)
    func catchInk(inside outline: [CGPoint])
    func keepHeldLoop()
    func duplicateInkSelection()
    func deleteInkSelection()
    func selectedInk() -> [PKDrawing]
    func selectedInkByPage() -> [(pageID: UUID, ink: PKDrawing)]
    func replaceInkSelection(with text: String) -> ItemSelection?
    func tapesDidChange()
    func setFinding(_ finding: Bool)
    func showFind(_ matches: [FindMatch], current: FindMatch?)
    func setZoomWindow(_ open: Bool)
    func setSelectingText(_ selecting: Bool)
    func selectAllText()
    func highlightSelectedText(_ color: HighlightColor)
}

struct ItemSelection: Equatable {
    let pageID: UUID
    let itemID: UUID
}

enum PageFit { case width, page }

/// Focus hides the chrome and leaves the tool tray; presenting hides both and turns the Pencil into a laser pointer;
/// replaying plays a recording while the ink written during it appears as it was written; selecting picks ink out
/// across pages to move, copy or delete; finding looks for words and marks them on the pages; selecting text picks
/// out a PDF page's own words to copy or highlight.
enum EditorMode: Equatable {
    case writing, focus, presenting, replaying, selecting, finding, selectingText

    /// What VoiceOver hears on entering the mode.
    var announcement: String {
        switch self {
        case .writing: String(localized: "Back to writing")
        case .focus: String(localized: "Focus mode. The toolbar is hidden.")
        case .presenting: String(localized: "Presenting. Drag on the page to point.")
        case .replaying: String(localized: "Replaying. Ink appears as it was written; tap ink to jump to that moment.")
        case .selecting: String(localized: "Selecting ink. Draw round ink on any page, then drag it.")
        case .finding: String(localized: "Find in notebook. Type what to look for.")
        case .selectingText: String(localized: "Selecting text. Drag across the words of a PDF page.")
        }
    }
}

@MainActor
@Observable
final class EditorSession {
    let document: NotebookDocument
    let recorder: NotebookRecorder
    let finder: NotebookFinder
    var currentPage: Int
    /// Whether the tools are out. The tray itself also waits on the mode, see `showsToolTray`.
    var showsTools = true
    /// Whether anything can be undone or redone now. Nothing is while presenting or replaying.
    var canUndo = false
    var canRedo = false
    /// While a box is typed in, only a change of its style can be undone or redone from the bar.
    var undoesStyle = false
    var redoesStyle = false
    /// The picture, sticker, text box or link being arranged. The canvas owns it; it's mirrored here for the chrome.
    var selection: ItemSelection?
    var isEditingText = false
    /// What is kept of the selected picture while it is being cropped. The canvas owns it; it's mirrored here for the chrome.
    var crop: CGRect?
    /// The whiteboard that is open on its own, if one is. The canvas owns it; it's mirrored here for the chrome.
    var openBoard: UUID?
    /// The page being written on is Chalkboard, where ink is light: the tray's pens show it so.
    var inkIsLight = false
    /// The page being written on is light paper shown dark, where ink is light too.
    var paperIsNight = false
    /// How far the zoom window stands above the foot of the editor's safe area, for the tray to stand on it.
    var zoomPanelLift: CGFloat = 0
    /// Where the ink dish is out, in the page view's points: at the Pencil's tip when it was squeezed. Nil while it is put away.
    var dish: CGPoint?
    /// The words selected on a PDF page, while its text is being selected. The canvas owns the selection.
    var selectedText: String?
    /// The page a link was followed from, while the page it opened is still showing.
    private(set) var linkReturn: UUID?
    private(set) var mode = EditorMode.writing
    /// How many strokes the lasso across pages has caught.
    var inkSelectionCount = 0
    /// Whether the round loop that started the selection can still be kept as the circle it reads as.
    var canKeepHeldLoop = false
    /// The study tape that is lifted for now. It isn't saved: every strip is back in place when the notebook is opened again.
    private(set) var liftedTapes: Set<UUID> = []
    /// The recording being replayed with its ink, and what was said in it if it has been transcribed.
    private(set) var replay: ReplayTimeline?
    private(set) var replayLines: [Transcript.Line] = []
    /// Where the position slider is held while it is dragged: the page follows it, not the sound, until it is let go.
    private(set) var scrubbing: TimeInterval?
    /// The zoom window: a magnified strip at the foot of the editor for writing small and neat.
    private(set) var isZoomWindowOpen = false
    @ObservationIgnored private var replayPage: UUID?
    var laserColor = LaserColor.red {
        didSet { canvas?.setLaserColor(laserColor) }
    }
    var drawingInput: DrawingInput {
        didSet {
            UserDefaults.standard.set(drawingInput.rawValue, forKey: SettingsKey.drawingInput)
            canvas?.setDrawingPolicy(drawingInput.policy)
            if drawingInput != .pencilOnly { document.dismissNotices(.onlyPencilDraws) }
        }
    }
    @ObservationIgnored weak var canvas: EditorCanvasControlling?
    /// The titles of the notebooks this one links to. Nil until they've been looked up.
    @ObservationIgnored var notebookTitles: [UUID: String]? {
        didSet { if notebookTitles != oldValue { canvas?.linksDidChange() } }
    }
    /// Called when a touch lands on the pages, so a window showing two notebooks knows which one is being worked on.
    @ObservationIgnored var onTouchDown: (() -> Void)?
    /// Whether this is the pane being worked in: a double-tap of the Pencil reaches both panes of a window.
    @ObservationIgnored var isActivePane: () -> Bool = { true }
    @ObservationIgnored var openURL: (URL) -> Void = { UIApplication.shared.open($0) }
    /// Opens another notebook, at a page if the link names one; the last value is the page the link sits on.
    @ObservationIgnored var openNotebook: ((UUID, UUID?, UUID) -> Void)?
    /// The last page that isn't a whiteboard, for leaving a whiteboard by.
    @ObservationIgnored private var lastPage: UUID?

    init(document: NotebookDocument, initialPageID: UUID? = nil) {
        self.document = document
        recorder = NotebookRecorder(document: document)
        finder = NotebookFinder(document: document)
        let saved = document.manifest.library.currentPage
        currentPage = max(0, min(initialPageID.flatMap(document.index(of:)) ?? saved, document.pages.count - 1))
        drawingInput = UserDefaults.standard.string(forKey: SettingsKey.drawingInput).flatMap(DrawingInput.init(rawValue:)) ?? .initial
        finder.startPage = { [weak self] in self?.currentPage ?? 0 }
        finder.onChange = { [weak self] in
            guard let self else { return }
            self.canvas?.showFind(self.finder.matches, current: self.finder.current)
        }
        notePage(currentPage)
    }

    func pageDidChange(_ index: Int) {
        guard index != currentPage else { return }
        currentPage = index
        linkReturn = nil
        document.noteCurrentPage(index)
        notePage(index)
    }

    private func notePage(_ index: Int) {
        guard document.pages.indices.contains(index), !document.pages[index].isBoard else { return }
        lastPage = document.pages[index].id
    }

    /// The page being written on, nil only while the notebook has none.
    var shownPage: NotebookPage? {
        document.pages.indices.contains(currentPage) ? document.pages[currentPage] : nil
    }

    /// Where leaving the open whiteboard goes: the page it was opened from, or the nearest page before or after it.
    var pageBehindBoard: Int? {
        guard let board = openBoard.flatMap(document.index(of:)) else { return nil }
        let pages = document.pages
        if let index = lastPage.flatMap(document.index(of:)), !pages[index].isBoard { return index }
        return pages[..<board].lastIndex { !$0.isBoard } ?? pages[board...].firstIndex { !$0.isBoard }
    }

    func leaveBoard() {
        guard let index = pageBehindBoard else { return }
        go(to: index)
    }

    func go(to index: Int, animated: Bool = true) {
        guard document.pages.indices.contains(index) else { return }
        canvas?.scrollToPage(index, animated: animated)
        pageDidChange(index)
    }

    func enter(_ newMode: EditorMode) {
        guard newMode != mode, newMode != .replaying || replay != nil else { return }
        guard newMode != .selecting || !document.isReadOnly else { return }
        guard newMode != .selectingText || document.hasPDFPages else { return }
        if mode == .replaying { stopReplay() }
        if mode == .selecting { canvas?.setSelectingInk(false) }
        if mode == .selectingText { canvas?.setSelectingText(false) }
        if mode == .finding {
            finder.clear()
            canvas?.setFinding(false)
        }
        if newMode != .writing, newMode != .focus { setZoomWindow(false) }
        mode = newMode
        canvas?.setPresenting(newMode == .presenting)
        if newMode == .selecting { canvas?.setSelectingInk(true) }
        if newMode == .finding { canvas?.setFinding(true) }
        if newMode == .selectingText { canvas?.setSelectingText(true) }
        refreshUndoState()
    }

    /// Circle and hold: starts selecting with the ink inside `outline`, given in the page stack's points, already caught.
    func selectInk(inside outline: [CGPoint]) {
        guard mode == .writing || mode == .focus else { return }
        enter(.selecting)
        if mode == .selecting { canvas?.catchInk(inside: outline) }
    }

    // MARK: Zoom window

    func setZoomWindow(_ open: Bool) {
        guard open != isZoomWindowOpen, !open || (!document.isReadOnly && (mode == .writing || mode == .focus)) else { return }
        isZoomWindowOpen = open
        canvas?.setZoomWindow(open)
        AccessibilityNotification.Announcement(open ? String(localized: "Zoom window open. Write in the strip at the bottom.")
                                                    : String(localized: "Zoom window closed")).post()
    }

    /// The canvas closed it itself: its page was deleted, or its close button was pressed.
    func zoomWindowDidClose() {
        guard isZoomWindowOpen else { return }
        isZoomWindowOpen = false
        AccessibilityNotification.Announcement(String(localized: "Zoom window closed")).post()
    }

    // MARK: Replaying a recording

    /// Plays a recording from its start with the page as it was: ink written later in the recording is faint until
    /// the sound reaches it. Reads the pages written on during the recording, or every page for an older recording.
    func beginReplay(_ recording: RecordingEntry, at time: TimeInterval = 0) async -> Bool {
        guard mode != .presenting, mode != .replaying, !recorder.isRecording else { return false }
        let ids = recording.inkedPages?.filter { document.index(of: $0) != nil } ?? document.pages.map(\.id)
        var drawings: [UUID: PKDrawing] = [:]
        for id in ids { drawings[id] = await document.ink(id) }
        guard mode != .presenting, mode != .replaying, await recorder.beginReplay(recording) else { return false }
        guard mode != .presenting, mode != .replaying else {
            recorder.stopPlayback()
            return false
        }
        replay = ReplayTimeline(recording: recording, drawings: drawings)
        replayLines = recorder.transcript(for: recording)?.lines ?? []
        replayPage = nil
        recorder.onPlaybackTime = { [weak self] time in
            guard let self, self.scrubbing == nil else { return }
            self.showReplay(at: time)
        }
        enter(.replaying)
        showReplay(at: 0)
        if time > 0 { recorder.seek(to: time) }
        return true
    }

    /// Shows the ink as it was at `time`, and turns to the page being written on when that changes.
    func showReplay(at time: TimeInterval) {
        guard let replay else { return }
        canvas?.showReplay(replay, at: time)
        guard let page = replay.page(at: time), page != replayPage, let index = document.index(of: page) else { return }
        replayPage = page
        if index != currentPage { go(to: index) }
    }

    /// The position slider moved under a finger. The sound plays on; `seekReplay` takes it there once the slider is let go.
    func scrubReplay(to time: TimeInterval) {
        guard replay != nil else { return }
        scrubbing = time
        showReplay(at: time)
    }

    func seekReplay(to time: TimeInterval) {
        guard replay != nil else { return }
        scrubbing = nil
        recorder.seek(to: time)
    }

    private func stopReplay() {
        recorder.onPlaybackTime = nil
        recorder.stopPlayback()
        scrubbing = nil
        replay = nil
        replayLines = []
        canvas?.showReplay(nil, at: 0)
    }

    /// A page forward or back. While presenting, each page is shown whole.
    func step(_ delta: Int) {
        let index = min(max(currentPage + delta, 0), document.pages.count - 1)
        guard index != currentPage else { return }
        show(index)
    }

    // MARK: Links

    func addLink(to target: UUID) { addLink(PageLink(target: target)) }

    func addLink(_ link: PageLink) {
        let title = LinkTitles(pages: document.pages, notebooks: notebookTitles).title(for: link)
        addItem(.link(link), size: PageLinkArt.size(for: title), actionName: String(localized: "Add Link"))
    }

    /// Opens what a link points at. For a page of this notebook it remembers where it was followed from.
    func follow(_ link: PageLink, from origin: UUID) {
        switch link.destination {
        case .page(let target):
            guard let index = document.index(of: target) else {
                AccessibilityNotification.Announcement(String(localized: "The page this link opened was deleted")).post()
                return
            }
            canvas?.select(nil)
            show(index)
            linkReturn = document.index(of: origin) == index ? nil : origin
        case .web(let url):
            canvas?.select(nil)
            openURL(url)
        case .notebook(let notebook, let page, _):
            canvas?.select(nil)
            openNotebook?(notebook, page, origin)
        }
    }

    func goBack() {
        guard let index = linkReturn.flatMap(document.index(of:)) else { return dismissLinkReturn() }
        show(index)
    }

    func dismissLinkReturn() { linkReturn = nil }

    private func show(_ index: Int) {
        if mode == .presenting {
            canvas?.present(page: index)
        } else {
            go(to: index)
        }
    }

    func setLinkLabel(_ label: String) {
        updateSelectedItem(actionName: String(localized: "Rename Link")) { item in
            guard var link = item.link else { return }
            link.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            item.content = .link(link)
        }
    }

    /// One undo step for a change to the selected item.
    private func updateSelectedItem(actionName: String, _ change: (inout PageItem) -> Void) {
        guard let selection else { return }
        document.updateItems(onPage: selection.pageID, actionName: actionName) { items in
            guard let index = items.firstIndex(where: { $0.id == selection.itemID }) else { return }
            change(&items[index])
        }
    }

    // MARK: Study tape

    func addTape() {
        let last = UserDefaults.standard.string(forKey: SettingsKey.tapeColor).flatMap(TapeColor.init(rawValue:)) ?? .mustard
        addItem(.tape(last), size: TapeArt.defaultSize, actionName: String(localized: "Add Study Tape"))
    }

    func toggleTape(_ id: UUID) {
        if liftedTapes.remove(id) == nil { liftedTapes.insert(id) }
        canvas?.tapesDidChange()
        AccessibilityNotification.Announcement(liftedTapes.contains(id) ? String(localized: "Tape lifted") : String(localized: "Tape put back")).post()
    }

    func coverAllTapes() {
        guard !liftedTapes.isEmpty else { return }
        liftedTapes = []
        canvas?.tapesDidChange()
    }

    func setTapeColor(_ color: TapeColor) {
        guard selection != nil else { return }
        UserDefaults.standard.set(color.rawValue, forKey: SettingsKey.tapeColor)
        updateSelectedItem(actionName: String(localized: "Tape Colour")) { item in
            if item.tape != nil { item.content = .tape(color) }
        }
    }

    // MARK: Today's events

    /// Prints the day's events on the current page as a text box, which can then be moved, restyled or deleted.
    func addAgenda(_ events: [AgendaEvent], on day: Date = .now) {
        guard !document.isReadOnly, let page = shownPage else { return }
        var box = TextBox(string: Agenda.text(for: events, heading: page.day == nil ? day.formatted(.dayName) : nil))
        box.fontSize = 13
        let width = min(max(box.naturalWidth(limit: page.sheetSize.width * 0.6), 150), page.sheetSize.width * 0.6)
        addItem(.text(box), size: CGSize(width: width, height: box.height(width: width)), actionName: String(localized: "Add Today's Events"))
    }

    // MARK: Text boxes

    static let addTextAction = String(localized: "Add Text Box")

    /// Places an empty text box and starts typing in it.
    func addText() {
        guard !document.isReadOnly, let page = shownPage else { return }
        let box = TextBox(string: "")
        let width = min(280, (page.sheetSize.width * 0.6).rounded())
        addItem(.text(box), size: CGSize(width: width, height: box.height(width: width)), actionName: Self.addTextAction)
        canvas?.editText()
    }

    func updateText(_ change: (inout TextBox) -> Void) {
        updateSelectedItem(actionName: String(localized: "Text Style")) { item in
            guard var box = item.text else { return }
            let before = box
            change(&box)
            guard box != before else { return }
            item.content = .text(box)
            item = item.fittedToText()
            item.raw["agenda"] = nil
        }
    }

    var selectedItem: PageItem? {
        guard let selection, let page = document.pages.first(where: { $0.id == selection.pageID }) else { return nil }
        return page.items.first { $0.id == selection.itemID }
    }

    // MARK: Pictures and stickers

    /// Places a new item and selects it: where it was dropped, or in the middle of what's showing of the current page.
    func addItem(_ content: PageItem.Content, size: CGSize, onPage index: Int? = nil, at point: CGPoint? = nil,
                 actionName: String = String(localized: "Add to Page"), source: String? = nil) {
        let index = index ?? currentPage
        guard !document.isReadOnly, document.pages.indices.contains(index) else { return }
        let page = document.pages[index]
        // A whiteboard is opened first, so the new thing lands in the part of it that is looked at.
        if page.isBoard { go(to: index, animated: false) }
        var centre = point ?? canvas?.visibleCenter(ofPage: index) ?? CGPoint(x: page.size.width / 2, y: page.size.height / 2)
        // Never exactly on top of the last one placed.
        let taken = page.items.map(\.center)
        while taken.contains(where: { abs($0.x - centre.x) < 6 && abs($0.y - centre.y) < 6 }), centre.y + 28 < page.size.height {
            centre = CGPoint(x: min(centre.x + 28, page.size.width), y: centre.y + 28)
        }
        var item = PageItem(content: content, center: centre, size: size)
        item.source = source
        document.updateItems(onPage: page.id, actionName: actionName) { $0.append(item) }
        canvas?.select(ItemSelection(pageID: page.id, itemID: item.id))
    }

    /// Stores a picture in the notebook and places it on a page, sized to sit comfortably on it.
    func addPicture(_ data: Data) async throws {
        guard let image = UIImage(data: data) else { throw ImportError.unreadable }
        try await addPicture(image)
    }

    func addPicture(_ image: UIImage, onPage index: Int? = nil, at point: CGPoint? = nil) async throws {
        let picture = try await Task.detached(priority: .userInitiated) { try PhotoImport.picture(image) }.value
        let file = try await document.package.writeAsset(picture.data, ext: picture.ext)
        let index = index ?? currentPage
        guard document.pages.indices.contains(index) else { return }
        let page = document.pages[index].sheetSize
        let fit = min(page.width * 0.55 / picture.size.width, page.height * 0.4 / picture.size.height)
        addItem(.image(file: file), size: CGSize(width: (picture.size.width * fit).rounded(), height: (picture.size.height * fit).rounded()),
                onPage: index, at: point)
    }

    /// Places one of the user's own stickers. The notebook keeps its own copy, and one copy serves every placement.
    func addSticker(_ sticker: CustomSticker) async throws {
        guard document.pages.indices.contains(currentPage) else { return }
        let placed = document.pages.lazy.filter(\.hasItems).flatMap(\.items).first { $0.source == sticker.id && $0.assetFile != nil }
        var file = placed?.assetFile, shape = placed?.cropped(to: nil).size
        if let name = file, !FileManager.default.fileExists(atPath: document.package.assetURL(name).path(percentEncoded: false)) { file = nil }
        if file == nil {
            let url = sticker.url
            let picture = try await Task.detached(priority: .userInitiated) {
                guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) else { throw ImportError.unreadable }
                return try PhotoImport.picture(image)
            }.value
            file = try await document.package.writeAsset(picture.data, ext: picture.ext)
            shape = picture.size
        }
        guard let file, let shape, let page = shownPage?.sheetSize else { return }
        let fit = min(150, page.width * 0.4) / max(shape.width, shape.height, 1)
        addItem(.image(file: file), size: CGSize(width: (shape.width * fit).rounded(), height: (shape.height * fit).rounded()), source: sticker.id)
    }

    // MARK: Photos from the camera

    @ObservationIgnored private var photoRun: (id: UUID, pageID: UUID, run: PhotoRun)?
    @ObservationIgnored private var photoQueue: Task<Void, Never>?

    /// Lays out what the camera takes from here on, sized to what is showing of the current page.
    func beginPhotos() {
        guard !document.isReadOnly, document.pages.indices.contains(currentPage) else { return }
        let page = document.pages[currentPage]
        let visible = canvas?.visibleRect(ofPage: currentPage) ?? CGRect(origin: .zero, size: page.sheetSize)
        let bounds = page.isBoard
            ? CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: page.size.height - visible.minY)
            : CGRect(origin: .zero, size: page.size)
        photoRun = (UUID(), page.id, PhotoRun(visible: visible, bounds: bounds.insetBy(dx: PhotoRun.margin, dy: PhotoRun.margin)))
    }

    /// Stores a photo and places it after the one before, in the order they were taken.
    func addPhoto(_ data: Data) async throws {
        let previous = photoQueue
        let placing = Task { @MainActor in
            await previous?.value
            try await placePhoto(data)
        }
        photoQueue = Task { _ = try? await placing.value }
        try await placing.value
    }

    /// Once the last photo is placed, shows the page it went on.
    func endPhotos() {
        guard let id = photoRun?.id else { return }
        let queue = photoQueue
        Task { @MainActor in
            await queue?.value
            guard let run = photoRun, run.id == id else { return }
            photoRun = nil
            if let index = document.pages.firstIndex(where: { $0.id == run.pageID }), index != currentPage { go(to: index) }
        }
    }

    private func placePhoto(_ data: Data) async throws {
        guard photoRun != nil else { return }
        let picture = try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { throw ImportError.unreadable }
            return try PhotoImport.picture(image, longSide: 2400)
        }.value
        let file = try await document.package.writeAsset(picture.data, ext: picture.ext)
        guard var current = photoRun, var index = document.pages.firstIndex(where: { $0.id == current.pageID }) else { return }
        let size = current.run.size(for: picture.size)
        var frame = current.run.place(size)
        if frame == nil {
            document.insertPages([document.newPage(after: index)], at: index + 1)
            index += 1
            current.run.turnPage(to: CGRect(origin: .zero, size: document.pages[index].size).insetBy(dx: PhotoRun.margin, dy: PhotoRun.margin))
            frame = current.run.place(size)
        }
        current.pageID = document.pages[index].id
        photoRun = current
        guard let frame else { return }
        addItem(.image(file: file), size: size, onPage: index, at: CGPoint(x: frame.midX, y: frame.midY), actionName: String(localized: "Take Photo"))
    }

    func deleteSelection() {
        guard let selection else { return }
        canvas?.select(nil)
        document.updateItems(onPage: selection.pageID, actionName: String(localized: "Delete")) { $0.removeAll { $0.id == selection.itemID } }
    }

    func duplicateSelection() {
        guard let selection, let page = document.pages.first(where: { $0.id == selection.pageID }),
              var copy = page.items.first(where: { $0.id == selection.itemID }) else { return }
        copy.id = UUID()
        copy.raw["agenda"] = nil
        copy.center = CGPoint(x: min(copy.center.x + 24, page.size.width), y: min(copy.center.y + 24, page.size.height))
        document.updateItems(onPage: selection.pageID, actionName: String(localized: "Duplicate")) { $0.append(copy) }
        canvas?.select(ItemSelection(pageID: selection.pageID, itemID: copy.id))
    }

    /// One step forward or back in the page's stack of pictures and stickers.
    func moveSelection(forward: Bool) {
        guard let selection else { return }
        document.updateItems(onPage: selection.pageID, actionName: forward ? String(localized: "Bring Forward") : String(localized: "Send Backward")) { items in
            guard let index = items.firstIndex(where: { $0.id == selection.itemID }) else { return }
            let target = index + (forward ? 1 : -1)
            if items.indices.contains(target) { items.swapAt(index, target) }
        }
    }

    /// The tool tray is at the foot of the editor while the page can be written on and nothing is being typed.
    var showsToolTray: Bool {
        showsTools && (mode == .writing || mode == .focus) && !document.isReadOnly && !isEditingText
    }

    /// The bar's Undo and Redo. While a box is typed in, its words are the text view's to undo.
    var canUndoFromBar: Bool { canUndo && (!isEditingText || undoesStyle) }
    var canRedoFromBar: Bool { canRedo && (!isEditingText || redoesStyle) }

    func toggleTools() {
        showsTools.toggle()
        canvas?.toolTrayDidChange()
    }

    func refreshUndoState() {
        let held = mode == .presenting || mode == .replaying
        canUndo = !held && document.undoManager.canUndo
        canRedo = !held && document.undoManager.canRedo
        undoesStyle = canUndo && document.undoManager.undoActionName == String(localized: "Text Style")
        redoesStyle = canRedo && document.undoManager.redoActionName == String(localized: "Text Style")
    }

    /// Inserts after `index` (or at the end) and makes the new page current.
    func addPage(after index: Int? = nil) {
        guard !document.isReadOnly else { return }
        let position = (index ?? document.pages.count - 1) + 1
        document.insertPages([document.newPage(after: index)], at: position)
        go(to: position)
    }

    /// Inserts at `position`, kept within the notebook, and makes the first new page current.
    func insert(_ pages: [NotebookPage], at position: Int, actionName: String = String(localized: "Add Page")) {
        let position = min(max(position, 0), document.pages.count)
        document.insertPages(pages, at: position, actionName: actionName)
        go(to: position)
    }

    func duplicatePage(at index: Int) async {
        if let position = await document.duplicatePage(at: index) { go(to: position) }
    }

    /// Inserts a whiteboard after `index` (or at the end) and opens it. It takes the colour of the page before it.
    func addBoard(after index: Int? = nil) {
        guard !document.isReadOnly else { return }
        let position = (index ?? document.pages.count - 1) + 1
        let paper = document.newPage(after: index)
        document.insertPages([.board(template: .dotted, color: paper.paperColor)], at: position, actionName: String(localized: "Add Whiteboard"))
        go(to: position)
    }
}
