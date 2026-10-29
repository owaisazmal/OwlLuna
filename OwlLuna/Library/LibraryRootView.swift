import SwiftUI
import SwiftData

struct OpenNotebook: Identifiable, Hashable {
    let id: UUID
    var pageID: UUID?
    /// What the editor zooms out of and back into: the cover unless the open started somewhere else.
    var zoomSource: String

    init(id: UUID, pageID: UUID? = nil, zoomSource: String? = nil) {
        self.id = id
        self.pageID = pageID
        self.zoomSource = zoomSource ?? "cover-\(id.uuidString)"
    }
}

struct LibraryRootView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \FolderRecord.sortIndex) private var folders: [FolderRecord]
    @State private var scope: LibraryScope? = .all
    @State private var open: OpenNotebook?
    @State private var showingSettings = false
    @State private var creating = false
    @State private var quickNoteError: String?
    @State private var creatingQuickNote = false
    @Environment(AppModel.self) private var app
    @Environment(LaunchCurtain.self) private var curtain: LaunchCurtain?
    @State private var sceneID: String?
    @State private var changes = LibraryChangeCenter()
    @State private var openingToday = false
    @State private var triedRestore = false
    @State private var performingAction = false
    /// A link that came before the app was ready or while the launch splash was up, carried out once it can be.
    @State private var heldAction: AppAction?
    /// What sync is waiting to be told, shown once the library is in front.
    @State private var syncQuestion: SyncCenter.Question?
    @State private var window = EditorWindow()
    @SceneStorage(WindowMemory.openNotebookKey) private var restoredNotebook = ""
    @SceneStorage("owlluna.besideNotebook") private var restoredBeside = ""
    @Namespace private var zoom
    @State private var sidebar = SidebarControl()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var rootWidth: CGFloat = 0
    @State private var detailWidth: CGFloat = 0
    @State private var verticalBar: VerticalBar?
    @State private var showingShelves = false
    @State private var shelfRequests = ShelfRequests()

    /// With Reduce Motion the editor cross-fades in over the library instead of zooming out of the cover.
    private var usesZoom: Bool { !reduceMotion }

    private var folder: FolderRecord? { scope?.folder(in: folders) }

    /// A folded iPhone Duo keeps the library's places in its vertical bar instead of a sidebar.
    private var railBar: VerticalBar? { sizeClass == .compact ? verticalBar : nil }

    private var shelf: some View {
        ShelfView(scope: scope ?? .all, zoomNamespace: zoom, onOpen: { openNotebook($0.id) },
                  onOpenPage: { openNotebook($0.id, pageID: $1) },
                  onOpenZoomed: { openNotebook($0.id, pageID: $1, zoomSource: $2) }, onCreate: { creating = true },
                  onQuickNote: quickNote, onWhiteboard: newWhiteboard, isCovered: open != nil || creating || showingSettings || showingShelves)
    }

    @ViewBuilder
    private var library: some View {
        if let railBar {
            NavigationStack { shelf }
                .overlay {
                    ThumbIndex(scope: $scope, bar: railBar, onCreate: { creating = true }, onQuickNote: quickNote, onWhiteboard: newWhiteboard,
                               onShelves: { showingShelves = true }, onSettings: { showingSettings = true })
                        .padding(.top, railBar.top)
                        .padding(.bottom, railBar.bottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: railBar.edge == .leading ? .leading : .trailing)
                        .ignoresSafeArea()
                }
                .environment(\.verticalBar, railBar)
                .environment(shelfRequests)
                .sheet(isPresented: $showingShelves) {
                    NavigationStack {
                        LibrarySidebar(scope: $scope, showingSettings: Binding(get: { false }, set: { if $0 { openSettingsFromShelves() } }),
                                       hideSidebar: { showingShelves = false })
                    }
                    .environment(changes)
                    .presentationCornerRadius(Radius.sheet)
                }
                .onChange(of: scope) { showingShelves = false }
        } else {
            NavigationSplitView {
                LibrarySidebar(scope: $scope, showingSettings: $showingSettings, hideSidebar: hidesSidebar ? { sidebar.toggle() } : nil)
            } detail: {
                NavigationStack {
                    shelf.modifier(BoardSidebarToggle(shows: sizeClass == .regular && !sidebarBeside) { sidebar.toggle() })
                        .modifier(PlateBack(shows: Device.isPhone && sizeClass == .compact) { scope = nil })
                }
                .background(SidebarAnchor(control: sidebar))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
            }
        }
    }

    /// The shelves sheet goes before Settings comes up in its place.
    private func openSettingsFromShelves() {
        showingShelves = false
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            showingSettings = true
        }
    }

    var body: some View {
        ZStack {
            AnyView(library)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rootWidth = $0 }
            .tint(Color.accentColor)
            .environment(changes)
            .accessibilityHidden(editorCoversLibrary)
            .disabled(editorCoversLibrary)

            if !usesZoom, let open {
                EditorPanes(primary: open, sceneID: sceneID) { self.open = nil }
                    .environment(window)
                    .environment(\.verticalBar, verticalBar)
                    .id(open.id)
                    .accessibilityAddTraits(.isModal)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: open)
        .fullScreenCover(item: Binding(get: { usesZoom ? open : nil }, set: { open = $0 })) { item in
            EditorPanes(primary: item, sceneID: sceneID) { open = nil }
                .environment(window)
                .environment(\.verticalBar, verticalBar)
                .navigationTransition(.zoom(sourceID: item.zoomSource, in: zoom))
                // A sideways finger drag on the page would otherwise pull the editor shut without its save-and-close.
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $creating) {
            NewNotebookView(folder: folder) { id in
                openNotebook(id)
            }
            .presentationCornerRadius(Radius.sheet)
        }
        .sheet(isPresented: $showingSettings) {
            OwlLunaSettingsView()
                .presentationCornerRadius(Radius.sheet)
        }
        .notice("The note couldn't be created", message: $quickNoteError)
        .onChange(of: app.sync.question, initial: true) { _, question in syncQuestion = question }
        .notice(Text(SyncQuestion.title(syncQuestion ?? .firstSync)),
                // Taken down because something came in front of the library, the question still stands for when it is back.
                isPresented: Binding(get: { syncQuestion != nil && libraryInFront }, set: { if !$0, libraryInFront { syncQuestion = nil } }),
                message: Text(SyncQuestion.message(syncQuestion ?? .firstSync))) {
            Button(SyncQuestion.refuse(syncQuestion ?? .firstSync), role: .cancel) { Task { await app.sync.answer(false) } }
                .accessibilityIdentifier("sync.question.refuse")
            Button(SyncQuestion.allow(syncQuestion ?? .firstSync)) { Task { await app.sync.answer(true) } }
                .accessibilityIdentifier("sync.question.allow")
        }
        .background(SceneReader {
            sceneID = $0
            window.scene = $0
        })
        .background(VerticalBarReader { verticalBar = $0 })
        .keyboardShortcut(for: { creating = true }, enabled: libraryInFront)
        .background {
            if libraryInFront {
                Group {
                    Button("Quick Note", action: quickNote).keyboardShortcut("n", modifiers: [.command, .shift])
                    Button("Today's Page", action: openToday).keyboardShortcut("t", modifiers: .command)
                    if #available(iOS 26, *), sizeClass == .regular {
                        Button(sidebarBeside ? "Hide Sidebar" : "Show Sidebar") { sidebar.toggle() }
                            .keyboardShortcut("s", modifiers: [.command, .control])
                    }
                }
                .hidden()
                .accessibilityHidden(true)
            }
        }
        .onChange(of: open) {
            if $1 == nil {
                window.beside = nil
                window.active = nil
            }
            rememberWindow()
        }
        .onChange(of: window.selected) { rememberWindow() }
        .onChange(of: window.tabs.map(\.id)) { rememberWindow() }
        .onChange(of: window.beside?.id) {
            restoredBeside = open == nil ? "" : $1?.uuidString ?? ""
            rememberWindow()
        }
        .onChange(of: sceneID) { Task { await restoreOpenNotebook() } }
        .onAppear { window.openNotebook = { id, page in Task { await perform(.open(id, page: page)) } } }
        .task(id: app.phase) { await openWhatWaits() }
        .onChange(of: app.pendingAction) { takePendingAction() }
        .onChange(of: curtain?.isUp) { Task { await openWhatWaits() } }
        .onOpenURL(perform: follow)
    }

    /// The notebook on show in the editor's first pane: the tab on show, when there are tabs.
    private var shownID: UUID? { open == nil ? nil : window.selected ?? open?.id }

    /// Before iPadOS 26 the system's own button does this.
    private var hidesSidebar: Bool {
        if #available(iOS 26, *) { sizeClass == .regular } else { false }
    }

    /// The sidebar stands beside the shelves only when they are narrower than the window.
    private var sidebarBeside: Bool { rootWidth - detailWidth > 1 }

    /// A link is carried out at once, unless the app is still starting or the launch splash is up.
    private func follow(_ url: URL) {
        guard let action = AppAction(url: url) else { return }
        if app.phase == .ready, curtain?.isUp != true {
            Task { await perform(action) }
        } else {
            hold(action)
        }
    }

    /// Keeps a link for later; saying so sends the launch splash away, or keeps it from coming.
    private func hold(_ action: AppAction) {
        heldAction = action
        curtain?.hurry()
    }

    /// Once the app is ready and the launch splash has gone: what a link or a shortcut asked for, or else the notebook the window had open.
    private func openWhatWaits() async {
        await restoreOpenNotebook()
        takePendingAction()
        guard app.phase == .ready, let action = heldAction, curtain?.holds() != true else { return }
        heldAction = nil
        await perform(action)
    }

    private func takePendingAction() {
        guard app.phase == .ready, let action = app.pendingAction, curtain?.holds() != true else { return }
        app.pendingAction = nil
        Task { await perform(action) }
    }

    /// Carries out a widget link or shortcut from wherever this window is: sheets are put away, and an editor
    /// showing another notebook saves and closes first.
    private func perform(_ action: AppAction) async {
        await app.start()
        if curtain?.holds() == true { return hold(action) }
        guard !performingAction else { return }
        performingAction = true
        defer { performingAction = false }
        if creating || showingSettings {
            creating = false
            showingSettings = false
            try? await Task.sleep(for: .milliseconds(600))
        }
        do {
            let id: UUID
            var page: UUID?
            switch action {
            case .today:
                (id, page) = try await todayPage()
            case .quickNote:
                id = try await store.createQuickNote(folder: nil)
            case .continueWriting:
                guard let last = store.lastOpenedNotebook else { return }
                id = last.id
            case .open(let notebook, let linked):
                guard let record = store.record(notebook), !record.isTrashed else { return }
                id = notebook
                page = linked
            }
            if let current = shownID, current != id, window.beside?.id != id {
                if window.goesToItsWindow(id, page: page) { return }
                // With tabs open the notebook gets a tab; a notebook on its own makes way for it.
                if window.tabs.count > 1 { return window.show(OpenNotebook(id: id, pageID: page)) }
                window.closing = .library
                NotificationCenter.default.post(name: .owlLunaCloseEditor, object: current)
                for _ in 0..<100 where open != nil { try? await Task.sleep(for: .milliseconds(100)) }
                guard open == nil else { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if open != nil {
                if window.beside?.id == id { window.active = id }
                if let page { NotificationCenter.default.post(name: .owlLunaShowPage, object: id, userInfo: ["page": page]) }
            } else {
                openNotebook(id, pageID: page)
            }
        } catch {
            quickNoteError = error.localizedDescription
        }
    }

    /// ⌘T, starting a journal first if there isn't one.
    private func openToday() {
        guard libraryInFront, !openingToday else { return }
        openingToday = true
        Task {
            defer { openingToday = false }
            do {
                let (id, page) = try await todayPage()
                openNotebook(id, pageID: page, zoomSource: scope == .all ? "today-\(id.uuidString)" : nil)
            } catch {
                quickNoteError = error.localizedDescription
            }
        }
    }

    /// The daily journal, started first if there isn't one, and today's page in it.
    private func todayPage() async throws -> (id: UUID, page: UUID?) {
        let id = try await store.journalForToday()
        return (id, await store.prepareTodayPage(id))
    }

    private func rememberWindow() {
        restoredNotebook = shownID?.uuidString ?? ""
        guard let sceneID else { return }
        WindowMemory.remember(shownID, beside: window.beside?.id, tabs: window.tabs.count > 1 ? window.tabs.map(\.id) : [], in: sceneID)
    }

    /// Skipped once if this window's last restore crashed.
    private func restoreOpenNotebook() async {
        guard app.phase == .ready, open == nil, !triedRestore, let sceneID else { return }
        if WindowMemory.reopens(in: sceneID, fallback: restoredNotebook), curtain?.holds() == true { return }
        triedRestore = true
        WindowMemory.keep(only: Set(UIApplication.shared.openSessions.map(\.persistentIdentifier)))
        if WindowMemory.restoreCrashed(in: sceneID) {
            restoredNotebook = ""
            return
        }
        let remembered = WindowMemory.remembered(in: sceneID) ?? (UUID(uuidString: restoredNotebook), UUID(uuidString: restoredBeside), [])
        // A newer version from another device is brought in first, for a few seconds at most, so the window doesn't start from an older copy.
        await app.sync.pullNewer([remembered.notebook, remembered.beside].compactMap { $0 }, within: SyncCenter.reopenLimit)
        guard open == nil else { return }
        window.restore(remembered.tabs.filter { store.record($0).map { !$0.isTrashed } ?? false }.map { OpenNotebook(id: $0) })
        guard let id = remembered.notebook, let record = store.record(id), !record.isTrashed else { return rememberWindow() }
        // What a link or a shortcut asked for is shown in place of the notebook the window had.
        guard !window.isOpenElsewhere(id), app.pendingAction == nil, heldAction == nil else { return }
        let beside = remembered.beside.flatMap(store.record)
        WindowMemory.setRestoring(true, in: sceneID)
        openNotebook(id)
        if let beside, beside.id != id, !beside.isTrashed, open?.id == id, !window.isOpenElsewhere(beside.id) { window.beside = OpenNotebook(id: beside.id) }
        try? await Task.sleep(for: .seconds(3))
        WindowMemory.setRestoring(false, in: sceneID)
    }

    /// Library shortcuts only act when nothing else is in front of the library.
    private var libraryInFront: Bool {
        open == nil && !creating && !showingSettings && !creatingQuickNote && app.phase == .ready && curtain?.isUp != true
    }

    private func quickNote() { createAndOpen { try await store.createQuickNote(folder: folder) } }

    private func newWhiteboard() { createAndOpen { try await store.createWhiteboard(folder: folder) } }

    private func createAndOpen(_ create: @escaping () async throws -> UUID) {
        guard libraryInFront else { return }
        creatingQuickNote = true
        Task {
            defer { creatingQuickNote = false }
            do {
                openNotebook(try await create())
            } catch {
                quickNoteError = error.localizedDescription
            }
        }
    }

    /// Without the zoom transition the editor is drawn over the library, which then must not be reachable.
    private var editorCoversLibrary: Bool { !usesZoom && open != nil }

    /// Only one editor per window: while one is open, the library can't switch it to another notebook.
    private func openNotebook(_ id: UUID, pageID: UUID? = nil, zoomSource: String? = nil) {
        guard open == nil else { return }
        if window.linkReturn?.destination != id { window.linkReturn = nil }
        if window.goesToItsWindow(id, page: pageID) { return }
        let notebook = OpenNotebook(id: id, pageID: pageID, zoomSource: zoomSource)
        // A locked notebook asks before it opens; the editor asks again if it is reached some other way.
        guard let record = store.record(id), record.isLocked, !NotebookLock.shared.isUnlocked(id), NotebookLock.shared.isAvailable else {
            return show(notebook)
        }
        let title = record.title.orUntitled
        Task {
            guard await NotebookLock.shared.unlock(id, title: title), open == nil else { return }
            show(notebook)
        }
    }

    /// Opens the editor on a notebook. Tabs left open the last time take it in among them.
    private func show(_ notebook: OpenNotebook) {
        guard !window.goesToItsWindow(notebook.id, page: notebook.pageID) else { return }
        window.show(notebook)
        open = notebook
    }
}

extension View {
    /// ⌘N: new notebook, from anywhere in the library. Off while an editor is open, which has its own ⌘N.
    func keyboardShortcut(for newNotebook: @escaping () -> Void, enabled: Bool) -> some View {
        background {
            if enabled {
                Button("New Notebook", action: newNotebook)
                    .keyboardShortcut("n", modifiers: .command)
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
    }
}

