import SwiftUI
import Combine
import PhotosUI
import PencilKit
import UniformTypeIdentifiers

struct EditorView: View {
    let document: NotebookDocument
    let initialPageID: UUID?
    /// True while a locked notebook is behind its lock screen.
    var isCovered = false
    let close: () -> Void
    @State private var slot = SessionSlot()

    init(document: NotebookDocument, initialPageID: UUID? = nil, isCovered: Bool = false, close: @escaping () -> Void) {
        self.document = document
        self.initialPageID = initialPageID
        self.isCovered = isCovered
        self.close = close
    }

    var body: some View {
        EditorContent(session: slot.session { EditorSession(document: document, initialPageID: initialPageID) }, isCovered: isCovered, close: close)
    }
}

/// Makes the editor's session once: the screen around the editor makes its view again each time it is redrawn.
@MainActor
private final class SessionSlot {
    private var made: EditorSession?

    func session(_ make: () -> EditorSession) -> EditorSession {
        if let made { return made }
        let session = make()
        made = session
        return session
    }
}

/// Only this button reads the recording's time, so the timer redraws it and not the editor around it.
private struct RecordButton: View {
    let recorder: NotebookRecorder
    let isCompact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if recorder.isRecording {
            let seconds = Int(recorder.elapsed)
            Button { recorder.stopRecording() } label: {
                HStack(spacing: Space.x2) {
                    Image(systemName: "stop.fill")
                        .symbolEffect(.breathe, options: .repeating, isActive: !reduceMotion)
                    if !isCompact {
                        Text(PlaybackScrubber.clock(recorder.elapsed))
                            .monospacedDigit()
                            .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(seconds)))
                            .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: seconds)
                    }
                }
            }
            .buttonStyle(.owlLuna(.destructive, compact: true, inBar: true))
            .padding(.horizontal, Space.x1)
            .accessibilityLabel(Text("Stop Recording"))
            .accessibilityValue(Text(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))))
            .accessibilityIdentifier("editor.record")
        } else {
            Button { recorder.startRecording() } label: { Label("Record Audio", systemImage: "mic") }
                .disabled(recorder.isReadOnly)
                .accessibilityIdentifier("editor.record")
        }
    }
}

fileprivate struct EditorContent: View {
    @Bindable var session: EditorSession
    var isCovered = false
    let close: () -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(FlashcardLibrary.self) private var flashcards
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(EditorWindow.self) private var window: EditorWindow?
    @Environment(\.editorPane) private var pane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var paneWidth: CGFloat = 1024
    @State private var pickingBeside = false
    @State private var showingRecordingsSheet = false
    @State private var showingPages = false
    @State private var showingRecordings = false
    @State private var importingPDF = false
    @State private var showingPhotoPicker = false
    @State fileprivate var photoItem: PhotosPickerItem?
    @State private var export: ExportJob?
    @State private var confirmingDelete = false
    @State private var goToPage = false
    @State private var goToText = ""
    @State private var renaming = false
    @State private var titleText = ""
    @State fileprivate var errorMessage: String?
    @State private var ribbonWidth: CGFloat = 44
    @State private var paperMode: PaperDrawer.Mode?
    @State private var editingCover: NotebookRecord?
    @State private var knownPages: Set<UUID> = []
    @State private var photoBecomesPage = true
    @State private var showingStickers = false
    @State private var pickingLink = false
    @State private var renamingLink = false
    @State private var linkLabel = ""
    @State private var namingBookmark: UUID?
    @State private var bookmarkName = ""
    @State private var editingNotes: NotesTarget?
    @State private var presenterPanel: Bool?
    @State private var presentingSince = Date.now
    @State private var readingInk: InkToRead?
    @State private var hidesTranscript = false
    @State private var scanning = false
    @State private var takingPhotos = false
    @State private var showingDeck = false
    @State private var cardDraft: CardDraft?
    @State private var studyGuide: StudyGuideRequest?
    @State private var showingBoardGuide = false
    @State private var tagging: TagTarget?
    @AppStorage(SettingsKey.whiteboardTipSeen) private var boardTipSeen = false
    @AppStorage(SettingsKey.leftHanded) private var leftHanded = false
    @State private var highlightColor = HighlightColor.last
    @State private var findText = ""
    @FocusState private var findFocused: Bool
    @ScaledMetric(relativeTo: .body) private var findWidth: CGFloat = 260
    @ScaledMetric(relativeTo: .body) private var compactFindWidth: CGFloat = 190
    @State private var undoGroupWidth: CGFloat = 96
    @State private var buttonGroupWidth: CGFloat = 232
    @State private var leaveBoardWidth: CGFloat = 150

    private struct NotesTarget: Identifiable {
        let id: UUID
    }

    private struct InkToRead: Identifiable {
        let id = UUID()
        let ink: [PKDrawing]
    }

    /// Notes and the next page sit beside the page while a second screen shows it, or when asked for.
    private var showsPresenterPanel: Bool {
        session.mode == .presenting && !isCompact && (presenterPanel ?? ExternalDisplay.shared.isShowing)
    }

    /// What was said sits beside the page while a transcribed recording is replayed.
    private var showsTranscriptPanel: Bool {
        session.mode == .replaying && !isCompact && !session.replayLines.isEmpty && !hidesTranscript
    }

    /// A pane beside another notebook has about half a window: its bar keeps the essentials and the rest move into More.
    private var isNarrow: Bool { paneWidth < EditorPanes.narrowWidth }
    /// Bold, Italic and Underline stand in a text box's bar only where the bar still clears the page ribbons.
    private var textBarIsRoomy: Bool {
        !(isCompact || dynamicTypeSize.isAccessibilitySize) && paneWidth >= (dynamicTypeSize > .large ? 820 : 760)
    }
    private var isCompact: Bool { sizeClass == .compact || isNarrow }

    /// An open whiteboard has its own button in the bar, where there is room for one.
    private var showsBoardMenu: Bool { session.openBoard != nil && !isNarrow }
    private var showsLeaveBoard: Bool { showsBoardMenu && session.pageBehindBoard != nil }

    /// With two notebooks in the window, keyboard shortcuts go to the one last touched.
    private var isActivePane: Bool { pane == .single || window?.active == nil || window?.active == document.id }

    private func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers = .command, always: Bool = false) -> KeyboardShortcut? {
        isActivePane && (always || !isPresentingModal) ? KeyboardShortcut(key, modifiers: modifiers) : nil
    }

    fileprivate var document: NotebookDocument { session.document }
    private var cloth: ClothColor { document.manifest.cover.cloth }

    var body: some View {
        // The layout is a 20 KB value and every modifier below would copy it onto the stack, more than an iPad's main thread has.
        studySheets(sheets(AnyView(layout)))
    }

    private var layout: some View {
        NavigationStack {
            HStack(spacing: 0) {
                if side == .leading { AnyView(sidePanels) }
                pageStack
                if side == .trailing { AnyView(sidePanels) }
            }
            .background(Color.desk.ignoresSafeArea())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(session.mode == .writing ? .visible : .hidden, for: .navigationBar)
        }
        .statusBarHidden(session.mode != .writing)
        .persistentSystemOverlays(session.mode == .writing ? .automatic : .hidden)
    }

    /// The side the ribbons and the panels beside the page keep to.
    private var side: HorizontalEdge { .editorSide(leftHanded: leftHanded) }

    @ViewBuilder
    private var sidePanels: some View {
        if showsPresenterPanel {
            PresenterPanel(session: session, since: presentingSince, side: side) {
                if let page = session.shownPage { editingNotes = NotesTarget(id: page.id) }
            }
            .frame(width: 300)
            .transition(.move(edge: side.edge))
        }
        if showsTranscriptPanel {
            TranscriptPanel(session: session, side: side)
                .frame(width: 300)
                .transition(.move(edge: side.edge))
        }
    }

    private var pageStack: some View {
        PageStack(session: session)
            .ignoresSafeArea(edges: .bottom)
            .background {
                Group {
                    Button("Page After Current") { session.addPage(after: session.currentPage) }
                        .keyboardShortcut(shortcut("n", always: true))
                        .disabled(document.isReadOnly || [.replaying, .selecting, .finding, .selectingText].contains(session.mode))
                    Button("Find in Notebook") { enter(.finding) }
                        .keyboardShortcut(shortcut("f"))
                    if session.mode == .finding {
                        Button("Next Match") { session.finder.step(1) }.keyboardShortcut(shortcut("g", always: true))
                        Button("Previous Match") { session.finder.step(-1) }.keyboardShortcut(shortcut("g", [.command, .shift], always: true))
                    }
                    Button("Focus Mode") { enter(session.mode == .focus ? .writing : .focus) }
                        .keyboardShortcut(shortcut("f", [.command, .control], always: true))
                    Button("Present") { enter(session.mode == .presenting ? .writing : .presenting) }
                        .keyboardShortcut(shortcut(.return, [.command, .option], always: true))
                    if session.mode != .writing {
                        Button("Done") { enter(.writing) }.keyboardShortcut(shortcut(.escape, [], always: true))
                    }
                }
                .hidden()
                .accessibilityHidden(true)
            }
            .overlay(alignment: side.topCorner) {
                switch session.mode {
                case .writing: ribbons
                case .focus: focusExit
                case .presenting, .replaying, .selecting, .finding, .selectingText: EmptyView()
                }
            }
            .overlay(alignment: .top) { banners }
            .overlay(alignment: .top) {
                if session.mode == .selecting {
                    inkBar
                } else if session.mode == .finding {
                    findBar
                } else if session.mode == .selectingText {
                    textBar
                } else if session.crop != nil {
                    AnyView(cropBar)
                } else if session.selection != nil, session.mode != .presenting {
                    arrangeBar
                } else {
                    VStack(spacing: 0) {
                        returnBar
                        if session.mode == .writing, session.openBoard != nil, !boardTipSeen { boardTip }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if session.mode == .presenting {
                    presentationBar
                } else if session.mode == .replaying {
                    ReplayBar(session: session, room: paneWidth - (showsTranscriptPanel ? 300 : 0),
                              transcript: isCompact || session.replayLines.isEmpty ? nil : !hidesTranscript,
                              toggleTranscript: { withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) { hidesTranscript.toggle() } },
                              done: { enter(.writing) })
                        .floatingBar()
                        .padding(.bottom, Space.x5)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if session.showsToolTray, !isCovered {
                    // The tray keeps its place when a keyboard comes up; it is put away while a text box is typed in.
                    ToolTray(session: session, room: paneWidth, use: use)
                        .padding(.bottom, ToolTray.gap + session.zoomPanelLift)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay {
                if let point = session.dish, session.mode == .writing || session.mode == .focus, !isCovered {
                    InkDish(session: session, point: point)
                }
            }
            .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: session.showsToolTray)
            .onChange(of: session.showsToolTray) { session.canvas?.toolTrayDidChange() }
            .onChange(of: session.mode) { session.dish = nil }
    }

    /// A shortcut in the tool tray: the same things the Add and More menus do.
    private func use(_ extra: ToolExtra) {
        switch extra {
        case .picture:
            photoBecomesPage = false
            showingPhotoPicker = true
        case .text: session.addText()
        case .sticker: showingStickers = true
        case .link: pickingLink = true
        case .tape: session.addTape()
        case .ruler: Toolbox.shared.isRulerActive.toggle()
        case .typing:
            Toolbox.shared.typesHandwriting.toggle()
            AccessibilityNotification.Announcement(Toolbox.shared.typesHandwriting
                ? String(localized: "Handwriting to Text on. What you write with a pen is set as text when you pause.")
                : String(localized: "Handwriting to Text off")).post()
        case .zoomWindow: session.setZoomWindow(!session.isZoomWindowOpen)
        case .shapes:
            let toolbox = Toolbox.shared
            toolbox.setShapesOut(toolbox.shape == nil)
            AccessibilityNotification.Announcement(toolbox.shape.map { String(localized: "Shapes: \($0.title). Drag on the page to draw it.") }
                ?? String(localized: "Shapes put away")).post()
        }
    }

    /// The editor's sheets, alerts and observers, kept apart from the layout so each stays quick to type-check.
    private func sheets<Content: View>(_ content: Content) -> some View {
        content
        .sheet(item: $editingNotes) { target in PresenterNotesSheet(document: document, pageID: target.id).presentationCornerRadius(Radius.sheet) }
        .sheet(item: $readingInk) { target in
            InkTextSheet(ink: target.ink) { text in
                guard let placed = session.canvas?.replaceInkSelection(with: text) else { return }
                session.enter(.writing)
                session.canvas?.select(placed)
                announce(String(localized: "Handwriting replaced with text"))
            }
            .presentationCornerRadius(Radius.sheet)
        }
        .sheet(isPresented: $pickingBeside) {
            BesidePicker(current: document.id, exclude: Set(window?.tabs.map(\.id) ?? [])) { id in
                guard window?.goesToItsWindow(id) != true else { return }
                window?.beside = OpenNotebook(id: id)
                window?.active = id
            }
            .presentationCornerRadius(Radius.sheet)
        }
        .sheet(isPresented: $showingRecordingsSheet) {
            recordingList { showingRecordingsSheet = false }
                .presentationDetents([.medium, .large])
                .presentationBackground(Color.surface)
                .presentationCornerRadius(Radius.sheet)
        }
        .sheet(isPresented: $showingPages) {
            PageNavigator(session: session)
                .presentationCornerRadius(Radius.sheet)
        }
        .sheet(isPresented: Binding(get: { showingBoardGuide && !showsBoardMenu }, set: { showingBoardGuide = $0 })) {
            WhiteboardGuide().presentationBackground(Color.surface)
                .presentationCornerRadius(Radius.sheet)
        }
        .sheet(item: $export) { job in ExportSheet(job: job).presentationCornerRadius(Radius.sheet) }
        .sheet(item: $editingCover) { record in CoverEditorView(record: record).presentationCornerRadius(Radius.sheet) }
        .fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
            let position = session.currentPage + 1
            document.perform { await insertPDF(result, at: position) }
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner { images in
                scanning = false
                insertScan(images)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $takingPhotos, onDismiss: { session.endPhotos() }) {
            PhotoCamera { data in
                document.perform { await addPhoto(data) }
            } done: {
                takingPhotos = false
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            let position = session.currentPage + 1
            let asPage = photoBecomesPage
            document.perform { if asPage { await insertPhoto(item, at: position) } else { await addPicture(item) } }
        }
        .sheet(isPresented: $showingStickers) {
            StickerDrawer { sticker in
                session.addItem(.sticker(sticker.rawValue), size: sticker.defaultSize)
                announce(String(localized: "\(sticker.displayName) added to the page"))
            } onPickOwn: { sticker in
                document.perform { await addSticker(sticker) }
            }
            .presentationCornerRadius(Radius.sheet)
        }
        .sheet(isPresented: $pickingLink) {
            LinkSheet(session: session) { link in
                session.addLink(link)
                refreshNotebookTitles()
                announce(String(localized: "Link added to the page"))
            }
            .presentationCornerRadius(Radius.sheet)
        }
        .notice("Rename Link", isPresented: $renamingLink, message: Text("Leave it empty to name the link after what it opens.")) {
            TextField("Name", text: $linkLabel)
        } actions: {
            Button("Cancel", role: .cancel) {}
            Button("Save") { session.setLinkLabel(linkLabel) }
        }
        .notice("Delete page \(session.currentPage + 1)?", isPresented: $confirmingDelete, message: Text("You can undo this.")) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Page", role: .destructive) {
                if let page = session.shownPage { document.removePages([page.id]) }
            }
        }
        .notice("Go to Page", isPresented: $goToPage, message: Text("1 to \(document.pages.count)")) {
            TextField("Page", text: $goToText).keyboardType(.numberPad)
        } actions: {
            Button("Cancel", role: .cancel) {}
            Button("Go") { if let number = Int(goToText) { session.go(to: number - 1) } }
        }
        .notice("Name Bookmark", isPresented: Binding(isPresent: $namingBookmark)) {
            TextField("Name", text: $bookmarkName)
        } actions: {
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let namingBookmark { document.setBookmark(bookmarkName, forPage: namingBookmark) } }
        }
        .notice("Rename Notebook", isPresented: $renaming) {
            TextField("Title", text: $titleText)
        } actions: {
            Button("Cancel", role: .cancel) {}
            Button("Save") { document.rename(titleText) }
        }
        .notice("Something went wrong", isPresented: Binding(get: { errorMessage != nil || session.recorder.errorMessage != nil || flashcards.lastError != nil },
                                                             set: { if !$0 { errorMessage = nil; session.recorder.errorMessage = nil; flashcards.clearError() } }),
                message: Text(errorMessage ?? session.recorder.errorMessage ?? flashcards.lastError ?? "")) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: isPresentingModal) { _, presenting in session.canvas?.setModalShowing(presenting) }
        .onChange(of: session.recorder.isRecording) { _, recording in
            announce(recording ? String(localized: "Recording started") : String(localized: "Recording saved"))
        }
        .onChange(of: document.pages.count) { old, new in announcePages(from: old, to: new) }
        .onAppear {
            knownPages = Set(document.pages.map(\.id))
            document.noteCurrentPage(session.currentPage)
            connectSession()
            // A notebook coming back from behind the tab bar still has its undo history.
            session.refreshUndoState()
            refreshNotebookTitles()
        }
        .onChange(of: window?.active) { if pane != .single, window?.active == document.id { session.canvas?.paneBecameActive() } }
        .onChange(of: session.mode, initial: true) { if pane != .secondary { window?.hidesChrome = session.mode != .writing } }
        .onChange(of: store.indexVersion) { refreshNotebookTitles() }
        .onReceive(Publishers.Merge3(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup),
                                     NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange),
                                     NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange))) { _ in session.refreshUndoState() }
        .onDisappear {
            session.recorder.shutdown()
            disconnectSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .owlLunaShowPage)) { note in
            guard (note.object as? UUID) == document.id, let page = note.userInfo?["page"] as? UUID, let index = document.index(of: page) else { return }
            session.go(to: index)
        }
    }

    /// Flashcards and the study guide.
    private func studySheets<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $showingDeck) { DeckSheet(session: session).presentationCornerRadius(Radius.sheet) }
        .sheet(item: $cardDraft) { draft in
            CardComposer(notebook: document.id, draft: draft) { _ in announce(String(localized: "Flashcard saved")) }
                .presentationCornerRadius(Radius.sheet)
        }
        .sheet(item: $studyGuide) { request in
            StudyGuideSheet(session: session, request: request)
                .presentationCornerRadius(Radius.sheet)
        }
        .sheet(item: $tagging) { target in EditorTagSheet(document: document, target: target).presentationCornerRadius(Radius.sheet) }
    }

    private func makeCardFromInk() {
        document.perform {
            guard let clipping = await session.inkClipping() else { return }
            cardDraft = CardDraft(pageID: clipping.pageID, answer: clipping.image)
        }
    }

    private func makeCard(from tape: PageItem) {
        guard let page = document.pages.first(where: { $0.id == session.selection?.pageID }) else { return }
        document.perform {
            do {
                try await session.makeCard(from: tape, on: page, in: flashcards)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                announce(String(localized: "Flashcard made from the tape"))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var isPresentingModal: Bool {
        showingPages || showingBoardGuide || showingRecordings || showingRecordingsSheet || pickingBeside || export != nil || importingPDF || showingPhotoPicker || renaming || goToPage || paperMode != nil
            || editingCover != nil || namingBookmark != nil || showingStickers || pickingLink || renamingLink || editingNotes != nil || readingInk != nil
            || isCovered || scanning || takingPhotos || showingDeck || cardDraft != nil || studyGuide != nil || (pane != .secondary && window?.pickingTab == true) || tagging != nil
    }

    private func enter(_ mode: EditorMode) {
        guard !isPresentingModal else { return }
        if mode == .presenting {
            presentingSince = .now
            presenterPanel = nil
        }
        withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) { session.enter(mode) }
        if mode == .finding { findText = "" }
        announce(mode.announcement)
    }

    fileprivate func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    private func announcePages(from old: Int, to new: Int) {
        let ids = document.pages.map(\.id), total = document.pageCountText
        if new == old + 1, let added = ids.firstIndex(where: { !knownPages.contains($0) }) {
            announce(String(localized: "Page \(added + 1) added. \(total)"))
        } else if new > old {
            announce(String(localized: "\(new - old) pages added. \(total)"))
        } else if new == old - 1 {
            announce(String(localized: "Page deleted. \(total)"))
        } else if new < old {
            announce(String(localized: "\(old - new) pages deleted. \(total)"))
        }
        knownPages = Set(ids)
    }

    // MARK: Chrome

    /// Each menu is a value of several kilobytes and the bar is built deep in the stack, so they go in behind `AnyView`.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                session.canvas?.select(nil)
                session.recorder.shutdown()
                if window?.linkReturn?.destination == document.id { window?.linkReturn = nil }
                if pane != .secondary { window?.closing = .library }
                close()
            } label: {
                if pane == .secondary { Label("Close", systemImage: "xmark") } else { Label("Library", systemImage: "chevron.backward") }
            }
            .buttonStyle(.plateIcon)
            // With tabs open, ⌘W closes the tab on show; the tab bar has it.
            .keyboardShortcut(pane != .secondary && (window?.tabs.count ?? 0) > 1 ? nil : shortcut("w", always: true))
            .accessibilityIdentifier(pane == .secondary ? "editor.close.pane" : "editor.back")
        }
        .boardBackground()
        if showsLeaveBoard {
            ToolbarItem(placement: .topBarLeading) {
                leaveBoardButton
                    .buttonStyle(.owlLuna(.secondary, inBar: true))
                    .labelStyle(.titleAndIcon)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leaveBoardWidth = $0 }
            }
            .boardBackground()
        }
        ToolbarItem(placement: .principal) { AnyView(titleMenu.environment(\.panelAnchorHeight, 44)) }
        if isNarrow {
            ToolbarItem(placement: .topBarTrailing) {
                BarGroup {
                    undoButtons
                    AnyView(addMenu)
                    if session.recorder.isRecording { recordButton }
                    AnyView(moreMenu)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { buttonGroupWidth = $0 }
            }
            .boardBackground()
        } else {
            if showsBoardMenu {
                ToolbarItem(placement: .topBarTrailing) {
                    BarGroup { AnyView(boardMenu) }
                }
                .boardBackground()
            }
            ToolbarItem(placement: .topBarTrailing) {
                BarGroup { undoButtons }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { undoGroupWidth = $0 }
            }
            .boardBackground()
            ToolbarItem(placement: .topBarTrailing) {
                BarGroup {
                    AnyView(addMenu)
                    if PhotoCamera.isAvailable { cameraButton }
                    recordButton
                    recordingsButton
                    toolsButton
                    AnyView(moreMenu)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { buttonGroupWidth = $0 }
            }
            .boardBackground()
        }
    }

    @ViewBuilder
    private var undoButtons: some View {
        Button { document.undoManager.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            .keyboardShortcut(session.isEditingText ? nil : shortcut("z"))
            .disabled(!session.canUndoFromBar)
            .accessibilityIdentifier("editor.undo")
        Button { document.undoManager.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            .keyboardShortcut(session.isEditingText ? nil : shortcut("z", [.command, .shift]))
            .disabled(!session.canRedoFromBar)
            .accessibilityIdentifier("editor.redo")
    }

    /// The bar lets a long title run under the buttons, so the title is given what they leave.
    private var titleRoom: CGFloat {
        let buttons = isNarrow ? buttonGroupWidth : undoGroupWidth + buttonGroupWidth + Space.x4 + (showsBoardMenu ? 52 + Space.x4 : 0)
        return max(paneWidth - buttons - 90 - (showsLeaveBoard ? leaveBoardWidth + Space.x2 : 0), 44)
    }

    private var toolsButton: some View {
        Button { session.toggleTools() } label: {
            Label(session.showsTools ? "Hide Tools" : "Show Tools",
                  systemImage: session.showsTools ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
        }
        .disabled(document.isReadOnly)
    }

    private var titleMenu: some View {
        OwlLunaMenu(Text(document.title)) {
            Button { titleText = document.title; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                .disabled(document.isReadOnly)
            if !document.isReadOnly {
                Button { editingCover = store.record(document.id) } label: { Label("Change Cover…", systemImage: "book.closed") }
                let locked = document.manifest.library.isLocked
                Button { toggleLock() } label: { Label(locked ? "Remove Lock…" : "Lock…", systemImage: locked ? "lock.open" : "lock") }
                Button { tagging = .notebook } label: { Label("Tags…", systemImage: "tag") }
            }
            OwlLunaMenu {
                let here = session.shownPage == nil ? nil : session.currentPage
                Button { export = ExportJob(document: document, choosing: true, current: here) } label: {
                    Label("Notebook as a PDF…", systemImage: "doc.richtext")
                }
                if session.shownPage != nil {
                    Button { export = ExportJob(document: document, choosing: true, current: here, thisPage: true) } label: {
                        Label("This Page as a PDF…", systemImage: "doc")
                    }
                }
                Button { export = ExportJob(document: document, format: .images, choosing: true, current: here) } label: {
                    Label("Every Page as an Image…", systemImage: "photo.on.rectangle")
                }
                if let page = session.shownPage {
                    Button { export = ExportJob(document: document, format: .images, pages: [page]) } label: { Label("This Page as an Image…", systemImage: "photo") }
                    Button { export = ExportJob(document: document, format: .timelapse, pages: [page]) } label: {
                        Label("This Page as a Time-lapse Video…", systemImage: "film")
                    }
                    .disabled(document.loadedInk(page.id)?.strokes.isEmpty ?? (page.inkHash == nil))
                }
                Button { export = ExportJob(document: document, format: .text, choosing: true, current: here) } label: {
                    Label("Notebook as Text…", systemImage: "doc.plaintext")
                }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            if let window, pane != .secondary {
                MenuBreak()
                Button { window.pickingTab = true } label: { Label("Open Another Notebook in a Tab…", systemImage: "plus.rectangle.on.rectangle") }
                    .disabled(window.tabs.count >= EditorWindow.tabLimit)
                if pane == .single, !isNarrow, sizeClass != .compact {
                    Button { pickingBeside = true } label: { Label("Open Another Notebook Beside…", systemImage: "rectangle.split.2x1") }
                        .disabled(window.beside != nil)
                } else if pane == .primary, let beside = window.beside {
                    Button { NotificationCenter.default.post(name: .owlLunaCloseEditor, object: beside.id) } label: {
                        Label("Close the Other Notebook", systemImage: "rectangle")
                    }
                }
            }
        } label: {
            HStack(spacing: Space.x2) {
                SpineChip(cloth: cloth)
                Text(document.title).font(.headline).foregroundStyle(Color.ink).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: titleRoom)
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityLabel(Text("\(document.title), notebook options"))
        .accessibilityIdentifier("editor.title")
    }

    private var cameraButton: some View {
        Button(action: startPhotos) { Label("Take Photos", systemImage: "camera") }
            .disabled(document.isReadOnly)
            .accessibilityIdentifier("editor.camera")
    }

    private var recordingsButton: some View {
        Button { showingRecordings = true } label: { Label("Recordings", systemImage: "waveform") }
            .panel("Recordings", isPresented: $showingRecordings, adapts: true) {
                recordingList { showingRecordings = false }
                    .frame(minWidth: 460, idealWidth: 460, minHeight: 440, idealHeight: 520)
            }
    }

    private func recordingList(dismiss: @escaping () -> Void) -> some View {
        RecordingList(recorder: session.recorder) { recording, time in
            dismiss()
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                if await session.beginReplay(recording, at: time) { announce(EditorMode.replaying.announcement) }
            }
        }
    }

    private func toggleBookmark() {
        guard let page = session.shownPage, !document.isReadOnly else { return }
        document.setBookmark(page.bookmark == nil ? "" : nil, forPage: page.id)
        announce(page.bookmark == nil ? String(localized: "Page bookmarked") : String(localized: "Bookmark removed"))
    }

    /// The page's own ribbon keeps to the edge.
    private var ribbons: some View {
        HStack(alignment: .top, spacing: Space.x1) {
            if side == .trailing { AnyView(bookmarkRibbon) }
            ribbon
            if side == .leading { AnyView(bookmarkRibbon) }
        }
        .padding(Edge.Set(side.edge), Space.x8)
    }

    /// A slim ribbon beside the page number: mustard once the page is bookmarked.
    private var bookmarkRibbon: some View {
        let page = session.shownPage, marked = page?.bookmark != nil
        return Button(action: toggleBookmark) {
            Image(systemName: marked ? "bookmark.fill" : "bookmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(marked ? Color.onMustard : Color.textSecondary)
                .frame(width: 28)
                .padding(.top, Space.x2)
                .padding(.bottom, Space.x2 + 28 * RibbonShape.notch)
                .background { marked ? Color.mustard : Color.surface }
                .clipShape(RibbonShape())
                .overlay { if !marked { RibbonShape().stroke(Color.hairline, lineWidth: 1) } }
                .shadow(color: .black.opacity(marked ? 0.15 : 0.06), radius: 1, y: 1)
                .frame(width: 44, height: 44, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(document.isReadOnly)
        .keyboardShortcut(shortcut("d"))
        .heldMenu(Text("Bookmark"), when: page != nil && marked && !document.isReadOnly) {
            if let page, marked, !document.isReadOnly {
                Button { bookmarkName = page.bookmark ?? ""; namingBookmark = page.id } label: { Label("Name Bookmark…", systemImage: "pencil") }
                Button(role: .destructive) { document.setBookmark(nil, forPage: page.id) } label: { Label("Remove Bookmark", systemImage: "bookmark.slash") }
            }
        }
        .animation(Motion.adaptive(Motion.ribbon, reduceMotion: reduceMotion), value: marked)
        .accessibilityLabel(Text(marked ? "Remove Bookmark" : "Bookmark Page"))
        .accessibilityValue(Text(marked ? (page?.bookmarkTitle(number: session.currentPage + 1) ?? "") : ""))
        .accessibilityIdentifier("editor.bookmark")
    }

    private var ribbon: some View {
        let page = min(session.currentPage + 1, document.pages.count), count = document.pages.count
        return Button { showingPages = true } label: {
            VStack(spacing: 0) {
                Text(page, format: .number)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(page)))
                Text("of \(count)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(count)))
            }
            .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: page)
            .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: count)
            .foregroundStyle(cloth.onCloth)
            .padding(.horizontal, Space.x2)
            .padding(.top, Space.x2)
            .frame(minWidth: 44)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { ribbonWidth = $0 }
            .padding(.bottom, Space.x2 + ribbonWidth * RibbonShape.notch)
            .background { cloth.color }
            .clipShape(RibbonShape())
            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut("p", [.command, .shift]))
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in goToText = ""; goToPage = true })
        .accessibilityLabel(Text("Page \(session.currentPage + 1) of \(document.pages.count)"))
        .accessibilityHint(Text("Opens the page navigator. Touch and hold to go to a page."))
        .accessibilityAction(named: Text("Go to page")) { goToText = ""; goToPage = true }
        .accessibilityIdentifier("editor.ribbon")
    }

    private var focusExit: some View {
        Button { enter(.writing) } label: { Label("Exit Focus Mode", systemImage: "arrow.down.right.and.arrow.up.left") }
            .buttonStyle(.plateIcon(lifted: true))
            .padding(Edge.Set(side.edge), Space.x8)
            .padding(.top, Space.x2)
            .accessibilityIdentifier("editor.focus.exit")
    }

    /// Shown while something on the page is selected. A text box and a link add their own controls in front.
    private var arrangeBar: some View {
        let item = session.selectedItem
        return HStack(spacing: 0) {
            if let box = item?.text {
                arrangeButton("Edit Text", "keyboard") { session.canvas?.editText() }
                    .disabled(session.isEditingText)
                    .accessibilityIdentifier("editor.arrange.edit")
                AnyView(TextStyleControls(session: session, box: box, roomy: textBarIsRoomy,
                                          shortcuts: isActivePane && !isPresentingModal))
            }
            if let link = item?.link {
                arrangeButton("Open Link", "arrow.turn.down.right") {
                    if let page = session.selection?.pageID { session.follow(link, from: page) }
                }
                .disabled(link.target.map { document.index(of: $0) == nil } ?? false)
                .accessibilityIdentifier("editor.arrange.open")
                arrangeButton("Rename Link", "pencil") { linkLabel = link.label; renamingLink = true }
            }
            if item?.assetFile != nil {
                arrangeButton("Crop", "crop") { session.canvas?.beginCrop() }
                    .accessibilityIdentifier("editor.arrange.crop")
            }
            if let tape = item?.tape, let id = item?.id {
                let lifted = session.liftedTapes.contains(id)
                arrangeButton(lifted ? "Put Tape Back" : "Lift Tape", lifted ? "eye.slash" : "eye") { session.toggleTape(id) }
                    .accessibilityIdentifier("editor.arrange.lift")
                tapeColorMenu(tape)
                if let item, flashcards.canChange(document.id) {
                    let made = flashcards.card(for: id, in: document.id) != nil
                    arrangeButton(made ? "Flashcard Made" : "Make Flashcard", "rectangle.on.rectangle.angled") { makeCard(from: item) }
                        .symbolVariant(made ? .fill : .none)
                        .disabled(made)
                        .accessibilityIdentifier("editor.arrange.card")
                }
                arrangeButton("Duplicate", "plus.square.on.square") { session.duplicateSelection() }
            } else if isCompact, item?.text != nil || item?.link != nil || item?.assetFile != nil {
                OwlLunaMenu {
                    Button { session.duplicateSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button { session.moveSelection(forward: true) } label: { Label("Bring Forward", systemImage: "square.2.layers.3d.top.filled") }
                    Button { session.moveSelection(forward: false) } label: { Label("Send Backward", systemImage: "square.2.layers.3d.bottom.filled") }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            } else {
                arrangeButton("Duplicate", "plus.square.on.square") { session.duplicateSelection() }
                arrangeButton("Bring Forward", "square.2.layers.3d.top.filled") { session.moveSelection(forward: true) }
                arrangeButton("Send Backward", "square.2.layers.3d.bottom.filled") { session.moveSelection(forward: false) }
            }
            arrangeButton("Delete", "trash", role: .destructive) { session.deleteSelection() }
            barRule
            barDone { session.canvas?.select(nil) }
                .accessibilityIdentifier("editor.arrange.done")
        }
        .floatingBar()
        .padding(.top, Space.x2)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Arrange"))
        .accessibilityIdentifier("editor.arrange.bar")
    }

    /// While a picture is being cropped: back to the whole of it, or leave with the crop kept or as it was.
    private var cropBar: some View {
        let says = !(isCompact || dynamicTypeSize.isAccessibilitySize)
        return HStack(spacing: 0) {
            if says {
                Text("Drag an edge or corner")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .padding(.trailing, Space.x2)
            }
            arrangeButton("Reset Crop", "arrow.counterclockwise") { session.canvas?.resetCrop() }
                .disabled(session.crop.map(PageItem.isWhole) ?? true)
                .accessibilityIdentifier("editor.crop.reset")
            barRule
            Button("Cancel") { session.canvas?.endCrop(keeping: false) }
                .buttonStyle(.owlLuna(.secondary, compact: true))
                .fixedSize()
                .accessibilityIdentifier("editor.crop.cancel")
            barDone { session.canvas?.endCrop(keeping: true) }
                .accessibilityIdentifier("editor.crop.done")
        }
        .floatingBar(leading: says ? Space.x5 : Space.x1)
        .padding(.top, Space.x2)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Crop"))
        .accessibilityIdentifier("editor.crop.bar")
    }

    private func tapeColorMenu(_ current: TapeColor) -> some View {
        OwlLunaMenu {
            OwlLunaPicker(selection: Binding(get: { current }, set: { session.setTapeColor($0) })) {
                ForEach(TapeColor.allCases) { Text($0.displayName).tag($0) }
            }
        } label: {
            Label("Tape Colour", systemImage: "paintpalette")
        }
        .accessibilityValue(Text(current.displayName))
        .accessibilityIdentifier("editor.arrange.tape")
    }

    /// While ink is being selected across pages: what to do, then what can be done with what was caught.
    private var inkBar: some View {
        let count = session.inkSelectionCount
        // With ink caught, the buttons need the room in a narrow pane and at the largest text sizes.
        let says = count == 0 || !(isCompact || dynamicTypeSize.isAccessibilitySize)
        return HStack(spacing: 0) {
            if says {
                Text(count == 0 ? String(localized: "Draw round ink on any page")
                                : String(localized: "\(count) strokes. Drag them to move them."))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .padding(.trailing, Space.x2)
                    .accessibilityIdentifier("editor.ink.status")
            }
            if count > 0, session.canKeepHeldLoop {
                Button("Keep Circle") { session.canvas?.keepHeldLoop() }
                    .buttonStyle(.owlLuna(.secondary, compact: true))
                    .fixedSize()
                    .padding(.trailing, Space.x1)
                    .accessibilityIdentifier("editor.ink.keep")
            }
            if count > 0 {
                arrangeButton("Turn into Text", "text.viewfinder") {
                    if let ink = session.canvas?.selectedInk(), !ink.isEmpty { readingInk = InkToRead(ink: ink) }
                }
                .accessibilityIdentifier("editor.ink.text")
                if flashcards.canChange(document.id) {
                    arrangeButton("Make Flashcard", "rectangle.on.rectangle.angled", action: makeCardFromInk)
                        .accessibilityIdentifier("editor.ink.card")
                }
                arrangeButton("Duplicate", "plus.square.on.square") { session.canvas?.duplicateInkSelection() }
                    .accessibilityIdentifier("editor.ink.duplicate")
                arrangeButton("Delete", "trash", role: .destructive) { session.canvas?.deleteInkSelection() }
                    .accessibilityIdentifier("editor.ink.delete")
            }
            arrangeButton("Undo", "arrow.uturn.backward") { document.undoManager.undo() }
                .disabled(!session.canUndo)
                .accessibilityIdentifier("editor.ink.undo")
            barRule
            barDone { enter(.writing) }
                .accessibilityIdentifier("editor.ink.done")
        }
        .floatingBar(leading: says ? Space.x5 : Space.x1)
        .padding(.top, Space.x2)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Select Ink"))
        .accessibilityIdentifier("editor.ink.bar")
    }

    /// While the notebook is being searched: what to look for, how many times it was found, and the way from one to the next.
    private var findBar: some View {
        let finder = session.finder, count = finder.matches.count
        let asked = !finder.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let status = count > 0 ? String(localized: "\((finder.position ?? 0) + 1) of \(count)")
                               : asked && !finder.isSearching ? String(localized: "No matches") : ""
        return HStack(spacing: 0) {
            OwlLunaSearchField("Find in Notebook", text: $findText, handlesEscape: false, capsTextSize: false, identifier: "editor.find.field",
                              focus: $findFocused)
                .fontWeight(.regular)
                .onSubmit {
                    finder.step(1)
                    findFocused = true
                }
                .onChange(of: findText) { _, text in finder.search(text) }
                .frame(width: isCompact || dynamicTypeSize.isAccessibilitySize ? min(compactFindWidth, 240) : min(findWidth, 340))
                .padding(.vertical, 2)
                .padding(.trailing, Space.x1)
            if finder.isSearching, count == 0 {
                ProgressView().controlSize(.small).padding(.horizontal, Space.x2)
            } else if !status.isEmpty {
                Text(status)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .padding(.horizontal, Space.x2)
                    .accessibilityIdentifier("editor.find.status")
            }
            arrangeButton("Previous Match", "chevron.up") { finder.step(-1) }
                .disabled(count == 0)
                .accessibilityIdentifier("editor.find.previous")
            arrangeButton("Next Match", "chevron.down") { finder.step(1) }
                .disabled(count == 0)
                .accessibilityIdentifier("editor.find.next")
            barRule
            barDone { enter(.writing) }
                .accessibilityIdentifier("editor.find.done")
        }
        .floatingBar()
        .padding(.top, Space.x2)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Find in Notebook"))
        .accessibilityIdentifier("editor.find.bar")
        .onAppear { findFocused = true }
    }

    /// While a PDF page's text is being selected: what to do, then what can be done with the words that are selected.
    private var textBar: some View {
        let text = session.selectedText
        let says = text == nil && !(isCompact || dynamicTypeSize.isAccessibilitySize)
        return HStack(spacing: 0) {
            if says {
                Text("Drag across the words of a PDF page")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .padding(.trailing, Space.x2)
                    .accessibilityIdentifier("editor.text.status")
            }
            arrangeButton("Select All on This Page", "text.justify.leading") { session.canvas?.selectAllText() }
                .accessibilityIdentifier("editor.text.all")
            if let text {
                arrangeButton("Copy", "doc.on.doc") {
                    UIPasteboard.general.string = text
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    announce(String(localized: "Copied"))
                }
                .accessibilityValue(Text("\(text.split(whereSeparator: \.isWhitespace).count) words"))
                .accessibilityIdentifier("editor.text.copy")
                if !document.isReadOnly {
                    arrangeButton("Highlight", "highlighter") { session.canvas?.highlightSelectedText(highlightColor) }
                        .accessibilityValue(Text(highlightColor.displayName))
                        .accessibilityIdentifier("editor.text.highlight")
                    OwlLunaMenu {
                        OwlLunaPicker(selection: Binding(get: { highlightColor }, set: { highlightColor = $0; HighlightColor.last = $0 })) {
                            ForEach(HighlightColor.allCases) { Text($0.displayName).tag($0) }
                        }
                    } label: {
                        Label {
                            Text("Highlight Colour")
                        } icon: {
                            Circle()
                                .fill(Color(uiColor: highlightColor.uiColor))
                                .frame(width: 18, height: 18)
                                .overlay { Circle().strokeBorder(Color.ink.opacity(0.35)) }
                        }
                    }
                    .accessibilityValue(Text(highlightColor.displayName))
                    .accessibilityIdentifier("editor.text.colour")
                }
            }
            barRule
            barDone { enter(.writing) }
                .accessibilityIdentifier("editor.text.done")
        }
        .floatingBar(leading: says ? Space.x5 : Space.x1)
        .padding(.top, Space.x2)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Select Text"))
        .accessibilityIdentifier("editor.text.bar")
    }

    /// After a link was followed: the way back to the page it was on, or to the notebook it was in.
    @ViewBuilder
    private var returnBar: some View {
        if let index = session.linkReturn.flatMap(document.index(of:)) {
            returnBar(String(localized: "Back to Page \(index + 1)"), back: { session.goBack() }, dismiss: { session.dismissLinkReturn() })
        } else if let origin = window?.linkReturn, origin.destination == document.id, session.mode == .writing {
            returnBar(String(localized: "Back to \(origin.title)"), back: {
                window?.linkReturn = nil
                window?.openNotebook?(origin.origin, origin.page)
            }, dismiss: { window?.linkReturn = nil })
        }
    }

    private func returnBar(_ title: String, back: @escaping () -> Void, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button(action: back) {
                HStack(spacing: Space.x2) {
                    Image(systemName: "arrow.uturn.backward").accessibilityHidden(true)
                    Text(title)
                }
                .font(.subheadline.weight(.semibold))
                .imageScale(.medium)
                .padding(.horizontal, Space.x1)
            }
            .accessibilityIdentifier("editor.link.back")
            barRule
            Button(action: dismiss) { Label("Dismiss", systemImage: "xmark").imageScale(.medium) }
        }
        .frame(maxWidth: 420)
        .floatingBar(leading: Space.x1, trailing: Space.x1)
        .padding(.top, Space.x2)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Whiteboard

    /// An open whiteboard's own controls, behind one button in the bar: they take nothing from the board.
    private var boardMenu: some View {
        OwlLunaMenu {
            boardActions
        } label: {
            Label("Whiteboard", systemImage: "scribble.variable")
        }
        .panel("Whiteboard Guide", isPresented: Binding(get: { showingBoardGuide && showsBoardMenu }, set: { showingBoardGuide = $0 }), adapts: true) {
            WhiteboardGuide()
        }
        .accessibilityHint(Text("Fits the whiteboard, shows the pages and opens the guide"))
        .accessibilityIdentifier("editor.board.menu")
    }

    private var leaveBoardButton: some View {
        Button { session.leaveBoard() } label: { Label("Back to Pages", systemImage: "book.pages") }
            .accessibilityHint(Text("Closes the whiteboard and goes back to the page you were on"))
            .accessibilityIdentifier("editor.board.leave")
    }

    @ViewBuilder
    private var boardActions: some View {
        Button { session.canvas?.fit(.page) } label: { Label("Show Everything", systemImage: "arrow.up.left.and.arrow.down.right") }
            .accessibilityIdentifier("editor.board.everything")
        Button { session.canvas?.fit(.width) } label: { Label("Actual Size", systemImage: "1.magnifyingglass") }
            .accessibilityIdentifier("editor.board.actual")
        Button { showingPages = true } label: { Label("Pages", systemImage: "rectangle.stack") }
            .accessibilityIdentifier("editor.board.pages")
        Button { showingBoardGuide = true } label: { Label("Whiteboard Guide", systemImage: "questionmark.circle") }
            .accessibilityIdentifier("editor.board.guide")
    }

    /// Shown over a whiteboard until it is put away once.
    private var boardTip: some View {
        WhiteboardTip(showGuide: { showingBoardGuide = true }, dismiss: {
            withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) { boardTipSeen = true }
        })
        // Keeps clear of the ribbons, and stays in the middle.
        .padding(.horizontal, Space.x8 + 100)
        .padding(.top, Space.x2)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Cloth, like the library slip's Undo.
    private func barDone(_ action: @escaping () -> Void) -> some View {
        Button("Done", action: action)
            .buttonStyle(.owlLuna(.primary, compact: true))
            .fixedSize()
            .padding(.leading, Space.x1)
    }

    private var barRule: some View {
        Rectangle().fill(Color.hairline).frame(width: 1, height: 24).padding(.horizontal, Space.x2)
    }

    private func arrangeButton(_ title: LocalizedStringKey, _ symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) { Label(title, systemImage: symbol) }
    }

    private var presentationBar: some View {
        let page = min(session.currentPage + 1, document.pages.count), count = document.pages.count
        return HStack(spacing: 0) {
            Button { session.step(-1) } label: { Label("Previous Page", systemImage: "chevron.up") }
                .disabled(page <= 1)
            Text("Page \(page) of \(count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Space.x1)
            Button { session.step(1) } label: { Label("Next Page", systemImage: "chevron.down") }
                .disabled(page >= count)
                .accessibilityIdentifier("editor.present.next")
            barRule
            if ExternalDisplay.shared.isShowing {
                Image(systemName: "tv")
                    .font(.body.weight(.medium))
                    .imageScale(.large)
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(Text("Showing on the second screen"))
                    .accessibilityIdentifier("editor.present.screen")
            }
            if !isCompact {
                Button {
                    let shows = showsPresenterPanel
                    withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) { presenterPanel = !shows }
                } label: {
                    Label("Notes and Next Page", systemImage: side == .leading ? "sidebar.leading" : "sidebar.trailing")
                        .symbolVariant(showsPresenterPanel ? .fill : .none)
                }
                .accessibilityValue(Text(showsPresenterPanel ? "Showing" : "Hidden"))
                .accessibilityIdentifier("editor.present.notes")
            }
            Button {
                session.laserColor = session.laserColor == .red ? .green : .red
            } label: {
                Circle()
                    .fill(Color(uiColor: session.laserColor.uiColor))
                    .frame(width: 18, height: 18)
                    .overlay { Circle().strokeBorder(Color.ink.opacity(0.35)) }
            }
            .accessibilityLabel(Text("Laser Colour"))
            .accessibilityValue(Text(session.laserColor.displayName))
            barDone { enter(.writing) }
                .accessibilityIdentifier("editor.present.done")
        }
        .floatingBar()
        .padding(.bottom, Space.x5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.present.bar")
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: Space.x2) {
            ForEach(document.notices) { notice in
                NoticeBanner(notice: notice, action: bannerAction(notice.kind)) { document.dismissNotice(notice) }
            }
        }
        .padding(.top, Space.x2)
        .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: document.notices)
    }

    private func bannerAction(_ kind: DocumentNotice.Kind) -> NoticeBanner.Action? {
        switch kind {
        case .onlyPencilDraws:
            NoticeBanner.Action(title: "Let Fingers Draw") { session.drawingInput = .anyInput }
        case .newerVersion where app != nil && document.recorder?.isRecording != true:
            NoticeBanner.Action(title: "Keep Both") {
                let document = document, sync = app?.sync
                // Said again when both can't be kept yet, so closing still does it.
                Task { if await sync?.keepBoth(document.id) != true { document.noteNewerVersion() } }
            }
        default:
            nil
        }
    }

    private var recordButton: some View {
        RecordButton(recorder: session.recorder, isCompact: isCompact)
    }

    private var addMenu: some View {
        OwlLunaMenu {
            Button { session.addPage(after: session.currentPage) } label: { Label("Page After Current", systemImage: "doc.badge.plus") }
            Button { session.addPage() } label: { Label("Page at End", systemImage: "arrow.down.doc") }
            Button { paperMode = .add(after: session.currentPage) } label: { Label("Choose Paper…", systemImage: "square.grid.3x3") }
            Button { session.addBoard(after: session.currentPage) } label: { Label("Whiteboard", systemImage: "scribble.variable") }
                .accessibilityIdentifier("editor.add.board")
            MenuBreak()
            Button { importingPDF = true } label: { Label("Insert PDF…", systemImage: "doc.richtext") }
            Button { photoBecomesPage = true; showingPhotoPicker = true } label: { Label("Insert Photo…", systemImage: "photo") }
            if DocumentScan.isAvailable {
                Button(action: startScan) { Label("Scan Documents…", systemImage: "doc.viewfinder") }
            }
            MenuBreak()
            if PhotoCamera.isAvailable {
                Button(action: startPhotos) { Label("Take Photos…", systemImage: "camera") }
            }
            Button { photoBecomesPage = false; showingPhotoPicker = true } label: { Label("Picture on This Page…", systemImage: "photo.on.rectangle.angled") }
            Button { showingStickers = true } label: { Label("Sticker…", systemImage: "seal") }
            Button { session.addText() } label: { Label("Text Box", systemImage: "character.textbox") }
            Button { pickingLink = true } label: { Label("Link…", systemImage: "link") }
            Button { session.addTape() } label: { Label("Study Tape", systemImage: "rectangle.dashed") }
            Button(action: addAgenda) { Label("Today's Events", systemImage: "calendar") }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .disabled(document.isReadOnly)
        .panel("Paper", item: Binding(get: { paperMode?.isAdding == true ? paperMode : nil }, set: { paperMode = $0 }), adapts: true) { mode in
            PaperDrawer(session: session, mode: mode)
        }
    }

    private var moreMenu: some View {
        OwlLunaMenu {
            let current = session.shownPage
            if isNarrow {
                if !session.recorder.isRecording {
                    Button { session.recorder.startRecording() } label: { Label("Record Audio", systemImage: "mic") }
                        .disabled(document.isReadOnly)
                }
                Button { showingRecordingsSheet = true } label: { Label("Recordings", systemImage: "waveform") }
                Button { session.toggleTools() } label: {
                    Label(session.showsTools ? "Hide Tools" : "Show Tools", systemImage: "pencil.tip.crop.circle")
                }
                .disabled(document.isReadOnly)
                MenuBreak()
            }
            if let current, current.template != nil || current.notebookPaper != nil, !document.isReadOnly {
                Button { paperMode = .change(pageID: current.id) } label: { Label("Change Paper…", systemImage: "paintpalette") }
            }
            Group {
                if let current, current.bookmark != nil {
                    Button { bookmarkName = current.bookmark ?? ""; namingBookmark = current.id } label: { Label("Name Bookmark…", systemImage: "bookmark") }
                } else {
                    Button(action: toggleBookmark) { Label("Bookmark Page", systemImage: "bookmark") }
                }
                if let current { Button { tagging = .page(current.id) } label: { Label("Tag Page…", systemImage: "tag") } }
                Button { Task { await session.duplicatePage(at: session.currentPage) } } label: {
                    Label("Duplicate Page", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete Page", systemImage: "trash") }
            }
            .disabled(document.isReadOnly)
            MenuBreak()
            if session.openBoard != nil {
                // In a narrow pane the whiteboard has no button of its own in the bar.
                if !showsBoardMenu {
                    if session.pageBehindBoard != nil { leaveBoardButton }
                    boardActions
                }
            } else {
                Button { session.canvas?.fit(.width) } label: { Label("Fit Width", systemImage: "arrow.left.and.right") }
                Button { session.canvas?.fit(.page) } label: { Label("Fit Page", systemImage: "arrow.up.and.down") }
            }
            MenuBreak()
            if !document.isReadOnly {
                Button { enter(.selecting) } label: { Label("Select Ink Across Pages", systemImage: "lasso") }
            }
            if !session.liftedTapes.isEmpty {
                Button { session.coverAllTapes() } label: { Label("Put All Tape Back", systemImage: "eye.slash") }
            }
            Button { enter(.finding) } label: { Label("Find in Notebook…", systemImage: "magnifyingglass") }
            if document.hasPDFPages {
                Button { enter(.selectingText) } label: { Label("Select PDF Text", systemImage: "text.cursor") }
            }
            if !document.isReadOnly {
                Button { session.setZoomWindow(!session.isZoomWindowOpen) } label: {
                    Label(session.isZoomWindowOpen ? "Close Zoom Window" : "Zoom Window", systemImage: "plus.magnifyingglass")
                }
            }
            MenuBreak()
            Button { showingDeck = true } label: { Label("Flashcards…", systemImage: "rectangle.on.rectangle.angled") }
            Button { studyGuide = StudyGuideRequest(scope: .notebook) } label: { Label("Study Guide…", systemImage: "text.badge.star") }
            MenuBreak()
            Button { enter(.focus) } label: { Label("Focus Mode", systemImage: "arrow.up.left.and.arrow.down.right") }
            Button { enter(.presenting) } label: { Label("Present", systemImage: "play.rectangle") }
            if let current, !document.isReadOnly {
                Button { editingNotes = NotesTarget(id: current.id) } label: { Label("Presenter Notes…", systemImage: "note.text") }
            }
            MenuBreak()
            OwlLunaMenu {
                OwlLunaPicker(selection: $session.drawingInput) {
                    ForEach(DrawingInput.allCases) { Text($0.displayName).tag($0) }
                }
            } label: { Label("Draw With", systemImage: "hand.draw") }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .panel("Paper", item: Binding(get: { paperMode?.isAdding == false ? paperMode : nil }, set: { paperMode = $0 }), adapts: true) { mode in
            PaperDrawer(session: session, mode: mode)
        }
    }

    // MARK: Import

    private func insertPDF(_ result: Result<URL, Error>, at position: Int) async {
        do {
            let url = try result.get()
            let file = try await document.package.importAsset(from: url, ext: "pdf")
            let assetURL = document.package.assetURL(file)
            let pages = try await Task.detached(priority: .userInitiated) { try PDFImport.pages(at: assetURL, file: file) }.value
            session.insert(pages, at: position, actionName: String(localized: "Insert PDF"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func insertPhoto(_ item: PhotosPickerItem, at position: Int) async {
        await loadPhoto(item) { data in
            let (jpeg, size) = try await Task.detached(priority: .userInitiated) { try PhotoImport.normalize(data) }.value
            let file = try await document.package.writeAsset(jpeg, ext: "jpg")
            let width = PageSize.letter.points.width
            let page = NotebookPage(background: .image(file: file), paperColor: .white,
                                    size: CGSize(width: width, height: (width * size.height / size.width).rounded()))
            session.insert([page], at: position, actionName: String(localized: "Insert Photo"))
        }
    }
}

extension EditorContent {
    /// Looks up the notebooks this one links to, so their links carry the current titles and grey out once a notebook is gone.
    fileprivate func refreshNotebookTitles() {
        var titles: [UUID: String] = [:]
        for page in document.pages where page.hasItems {
            for item in page.items {
                guard case .notebook(let id, _, _)? = item.link?.destination, titles[id] == nil,
                      let record = store.record(id), !record.isTrashed else { continue }
                titles[id] = record.title
            }
        }
        session.notebookTitles = titles
    }

    /// Asks for the calendar the first time, then prints today's events on the page.
    fileprivate func addAgenda() {
        document.perform {
            do {
                let events = Agenda.ordered(try await Agenda.calendar.events(on: .now, calendar: .current))
                guard !events.isEmpty else {
                    errorMessage = String(localized: "There is nothing in your calendar today.")
                    return
                }
                session.addAgenda(events)
                announce(String(localized: "\(events.count) events added to the page"))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    fileprivate func startScan() {
        #if DEBUG
        if LaunchOptions.arguments.contains("-fakeScan") { return insertScan(DocumentScan.samples()) }
        #endif
        scanning = true
    }

    fileprivate func startPhotos() {
        session.canvas?.select(nil)
        session.beginPhotos()
        takingPhotos = true
    }

    fileprivate func addPhoto(_ data: Data) async {
        do {
            try await session.addPhoto(data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Each scanned sheet becomes a page after the current one, as one undo step.
    fileprivate func insertScan(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let position = session.currentPage + 1
        document.perform {
            do {
                let pages = try await DocumentScan.pages(from: images, in: document.package)
                session.insert(pages, at: position, actionName: String(localized: "Scan Documents"))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    fileprivate func toggleLock() {
        guard let record = store.record(document.id) else { return }
        Task { if let failure = await store.toggleLock(record) { errorMessage = failure } }
    }

    /// What the session and its recorder call back into. None of it holds this view, which holds the session.
    fileprivate func connectSession() {
        let id = document.id, directory = document.package.textDirectory, failure = $errorMessage
        session.openNotebook = { [weak session, weak store, weak window] notebook, page, origin in
            guard let session, let store else { return }
            guard let record = store.record(notebook), !record.isTrashed else {
                failure.wrappedValue = String(localized: "The notebook this link opened is no longer in your library.")
                return
            }
            guard let window, let open = window.openNotebook, !window.goesToItsWindow(notebook, page: page) else { return }
            window.linkReturn = NotebookReturn(origin: id, page: origin, title: session.document.title, destination: notebook)
            open(notebook, page)
        }
        session.onTouchDown = { [weak window] in window?.touched(id) }
        session.isActivePane = { [weak window] in window?.isActive(id) ?? true }
        session.recorder.onTranscriptChange = { [weak store] in
            Task {
                let text = await Task.detached(priority: .utility) { LibraryIndex.searchText(in: directory) }.value
                store?.updateSearchText(text, for: id)
            }
        }
    }

    fileprivate func disconnectSession() {
        session.openNotebook = nil
        session.onTouchDown = nil
        session.isActivePane = { true }
        session.recorder.onTranscriptChange = nil
    }

    fileprivate func addSticker(_ sticker: CustomSticker) async {
        do {
            try await session.addSticker(sticker)
            announce(String(localized: "Sticker added to the page"))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Places a picture on the current page as something that can be moved, rather than as a new page.
    fileprivate func addPicture(_ item: PhotosPickerItem) async {
        await loadPhoto(item) { data in
            try await session.addPicture(data)
            announce(String(localized: "Picture added to the page"))
        }
    }

    /// Reads the picked photo and hands it to `use`; what goes wrong is shown, and the picker is cleared either way.
    fileprivate func loadPhoto(_ item: PhotosPickerItem, then use: (Data) async throws -> Void) async {
        defer { photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ImportError.unreadable }
            try await use(data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension View {
    /// The board that floats over the page: the presenter's controls and the arrange bar.
    func floatingBar(leading: CGFloat = Space.x1, trailing: CGFloat = Space.x2) -> some View {
        fontWeight(.semibold)
            .buttonStyle(.barIcon)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .padding(.vertical, 2)
            .fixedSize()
            .board(in: RoundedRectangle.bar)
    }
}

