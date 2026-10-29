import SwiftUI
import SwiftData

/// The window's editor, or two side by side (one above the other when the window is taller than it is wide),
/// under a bar of tabs when several notebooks are open. Going back to the library from the first closes
/// everything; the second has its own Close, and each tab its own.
struct EditorPanes: View {
    let primary: OpenNotebook
    let sceneID: String?
    let onClose: () -> Void
    @Environment(EditorWindow.self) private var window
    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var size = CGSize.zero
    @State private var dragOrigin: CGFloat?
    @State private var leaving: OpenNotebook?

    static let dividerWidth: CGFloat = 14
    /// Narrower than this a pane's bar keeps to the essentials, and a window has no room for a second pane.
    static let narrowWidth: CGFloat = 620
    /// `-splitSideBySide` lets a test see the narrow panes of a landscape window while the simulator stays upright.
    private var stacked: Bool {
        #if DEBUG
        if LaunchOptions.arguments.contains("-splitSideBySide") { return false }
        #endif
        return size.height > size.width
    }

    /// The tab on show; a notebook on its own is the one the library opened. On the way out it is still the notebook that was on show.
    private var current: OpenNotebook { leaving ?? window.tabs.first { $0.id == window.selected } ?? primary }

    private var showsTabs: Bool { window.tabs.count > 1 && !window.hidesChrome }

    /// A tab can move beside the first pane wherever the title menu would offer to open a notebook there.
    private var hasRoomBeside: Bool { window.beside == nil && sizeClass != .compact && size.width >= Self.narrowWidth && !Device.isPhone }

    var body: some View {
        @Bindable var window = window
        VStack(spacing: 0) {
            if showsTabs {
                TabStrip(select: selectTab, close: closeTab, closeOthers: closeOtherTabs, openBeside: hasRoomBeside ? { openBeside($0) } : nil)
                    .disabled(window.isLeaving)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            panes
        }
        .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: showsTabs)
        .background(Color.desk.ignoresSafeArea())
        .sheet(isPresented: $window.pickingTab) {
            BesidePicker(current: current.id, title: "Open in a Tab", exclude: Set(window.tabs.map(\.id) + (window.beside.map { [$0.id] } ?? [])),
                         emptyMessage: "Every other notebook is already open.") { id in
                guard !window.goesToItsWindow(id) else { return }
                window.show(OpenNotebook(id: id))
                window.active = id
            }
            .presentationCornerRadius(Radius.sheet)
        }
        .onReceive(NotificationCenter.default.publisher(for: .owlLunaSelectTab)) { note in
            guard let id = note.object as? UUID, id != window.beside?.id, !window.isLeaving else { return }
            window.select(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { note in
            guard (note.object as? UIScene)?.session.persistentIdentifier == sceneID else { return }
            let shown = current.id
            putAway(park().filter { $0.id != shown })
        }
    }

    private var panes: some View {
        let split = window.beside != nil && size != .zero
        let length = ((stacked ? size.height : size.width) - Self.dividerWidth) * window.split
        let current = current
        return (stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))) {
            EditorScreen(notebookID: current.id, initialPageID: current.pageID, sceneID: sceneID, beforeClose: beforeClose) { closed(current.id) }
                .id(current.id)
                .environment(\.editorPane, window.beside == nil ? .single : .primary)
                .frame(width: split && !stacked ? length : nil, height: split && stacked ? length : nil)
            if let beside = window.beside {
                divider
                EditorScreen(notebookID: beside.id, initialPageID: beside.pageID, sceneID: sceneID) {
                    window.beside = nil
                    window.active = self.current.id
                }
                .id(beside.id)
                .environment(\.editorPane, .secondary)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    }

    // MARK: Tabs

    private func selectTab(_ id: UUID) {
        if !window.goesToItsWindow(id) { window.select(id) }
    }

    /// The tab on show is closed by its own editor, which can say so if saving fails; one behind the bar is saved
    /// and closed here.
    private func closeTab(_ id: UUID) {
        guard window.tabs.count > 1, !window.isLeaving else { return }
        if id == current.id {
            // With no other tab this window can show, closing the one on show is going back to the library.
            window.letGoOfTabsOpenElsewhere()
            window.closing = window.tabs.count > 1 ? .tab : .library
            NotificationCenter.default.post(name: .owlLunaCloseEditor, object: id)
        } else {
            window.removeTab(id)
            putAway(window.release(id).map { [$0] } ?? [])
        }
    }

    /// Every tab but one goes: those behind the bar at once, and the one on show, if it isn't the one staying, by its own editor.
    private func closeOtherTabs(_ id: UUID) {
        guard !window.goesToItsWindow(id) else { return }
        let shown = current.id
        for tab in window.tabs where tab.id != id && tab.id != shown { closeTab(tab.id) }
        if shown != id { closeTab(shown) }
    }

    /// A tab leaves the bar for the pane beside the first. Its document, if it is open, goes with it, undo history and all.
    private func openBeside(_ id: UUID) {
        guard !window.goesToItsWindow(id) else { return }
        window.letGoOfTabsOpenElsewhere()
        guard window.beside == nil, window.tabs.count > 1, !window.isLeaving else { return }
        window.removeTab(id)
        window.beside = OpenNotebook(id: id)
        window.active = id
    }

    private func putAway(_ documents: [NotebookDocument]) {
        for document in documents { Task { await EditorScreen.putAway(document, store: store) } }
    }

    /// On the way back to the library the notebook beside this one and the tabs behind the bar are saved and closed first.
    private func beforeClose() async -> Bool {
        guard window.closing == .library else { return true }
        window.isLeaving = true
        guard await closeBeside() else {
            window.isLeaving = false
            return false
        }
        let shown = current.id
        for document in window.documents.values where document.id != shown {
            await EditorScreen.putAway(document, store: store)
            window.release(document.id)
        }
        return true
    }

    /// The editor on show has saved and closed: its tab goes, or the whole editor does.
    private func closed(_ id: UUID) {
        let closing = window.closing
        window.closing = .library
        window.release(id)
        window.letGoOfTabsOpenElsewhere()
        if closing == .tab, window.tabs.count > 1 { return window.removeTab(id) }
        // A notebook still beside was never asked to close: the editor is leaving some other way than Back to Library.
        if let beside = window.beside, let document = DocumentRegistry.shared.document(for: beside.id) { putAway([document]) }
        putAway(park())
        onClose()
    }

    /// Parks the tabs with the pane still on the notebook it showed; with a lone tab forgotten it would turn to the one the library first opened.
    private func park() -> [NotebookDocument] {
        leaving = current
        return window.park()
    }

    private var divider: some View {
        Color.desk
            .frame(width: stacked ? nil : Self.dividerWidth, height: stacked ? Self.dividerWidth : nil)
            .overlay { Rectangle().fill(Color.hairline).frame(width: stacked ? nil : 1, height: stacked ? 1 : nil) }
            .overlay { RoundedRectangle(cornerRadius: 1.5).fill(Color.textSecondary).frame(width: stacked ? 40 : 5, height: stacked ? 5 : 40) }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragOrigin ?? window.split
                    dragOrigin = start
                    let total = max(stacked ? size.height : size.width, 1)
                    window.split = min(max(start + (stacked ? value.translation.height : value.translation.width) / total, 0.3), 0.7)
                }
                .onEnded { _ in dragOrigin = nil })
            .accessibilityHidden(true)
            // VoiceOver's handle is a full-size target laid over the strip; it takes no touches, so the panes' edges stay theirs.
            .overlay {
                Color.clear
                    .frame(minWidth: 44, minHeight: 44)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(Text("Divider between the notebooks"))
                    .accessibilityValue(Text(window.split, format: .percent.precision(.fractionLength(0))))
                    .accessibilityAdjustableAction { direction in
                        window.split = min(max(window.split + (direction == .increment ? 0.05 : -0.05), 0.3), 0.7)
                    }
                    .accessibilityIdentifier("editor.split.divider")
            }
    }

    /// The first notebook only closes once the one beside it has saved and closed.
    private func closeBeside() async -> Bool {
        guard let beside = window.beside else { return true }
        NotificationCenter.default.post(name: .owlLunaCloseEditor, object: beside.id)
        for _ in 0..<100 where window.beside != nil { try? await Task.sleep(for: .milliseconds(100)) }
        return window.beside == nil
    }
}

/// Chooses the notebook to open beside the one being written in, or in a tab.
struct BesidePicker: View {
    let current: UUID
    var title: LocalizedStringKey = "Open Beside"
    /// Notebooks that are already open in this window in some other way.
    var exclude: Set<UUID> = []
    var emptyMessage: LocalizedStringKey = "Once you have another notebook, you can open it beside this one."
    let pick: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<NotebookRecord> { $0.deletedAt == nil }, sort: \NotebookRecord.title) private var records: [NotebookRecord]

    var body: some View {
        // A notebook open in another window stays there: one editor writes each notebook.
        let others = records.filter {
            $0.id != current && !exclude.contains($0.id) && DocumentRegistry.shared.document(for: $0.id) == nil && !DocumentRegistry.shared.isOpening($0.id)
        }
        NavigationStack {
            Ledger {
                ForEach(others) { record in
                    Button {
                        pick(record.id)
                        dismiss()
                    } label: {
                        HStack(spacing: Space.x4) {
                            RecordCover(record: record, width: CoverWidth.row, showsShadow: false).frame(width: 40)
                            VStack(alignment: .leading, spacing: Space.x1) {
                                Text(record.title).font(.headline).foregroundStyle(Color.ink)
                                Text("\(record.pageCount) pages")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("beside.notebook.\(record.title)")
                }
            }
            .background(Color.desk)
            .overlay {
                if others.isEmpty {
                    EmptyPlate("No Other Notebooks", systemImage: "books.vertical", message: Text(emptyMessage))
                }
            }
            .navigationTitle(title)
            .barGround(.desk)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                CancelToolbarItem { dismiss() }
            }
        }
    }
}
