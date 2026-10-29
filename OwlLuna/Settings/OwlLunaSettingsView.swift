import SwiftUI

struct OwlLunaSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var store
    @Environment(WritingActivity.self) private var activity
    @Environment(AppModel.self) private var app: AppModel?
    @AppStorage(SettingsKey.drawingInput) private var drawingInput: DrawingInput = .initial
    @AppStorage(SettingsKey.defaultTemplate) private var template: PaperTemplate = .narrowRuled
    @AppStorage(SettingsKey.defaultPaperColor) private var color: PaperColor = .white
    @AppStorage(SettingsKey.defaultPageSize) private var size: PageSize = .letter
    @AppStorage(SettingsKey.defaultPaper) private var ownPaper = ""
    @State private var ownPaperName: String?
    @AppStorage(SettingsKey.darkPaper) private var darkPaper = true
    @AppStorage(SettingsKey.dailyJournalID) private var journalID = ""
    @AppStorage(SettingsKey.showsOnThisDay) private var showsOnThisDay = true
    @AppStorage(SettingsKey.snapsShapes) private var snapsShapes = true
    @AppStorage(SettingsKey.snapsHighlighter) private var snapsHighlighter = true
    @AppStorage(SettingsKey.scribbleErases) private var scribbleErases = true
    @AppStorage(SettingsKey.circleSelects) private var circleSelects = true
    @AppStorage(SettingsKey.pencilDoubleTap) private var pencilDoubleTap: PencilAction = .system
    @AppStorage(SettingsKey.pencilSqueeze) private var pencilSqueeze: PencilAction = .system
    @AppStorage(SettingsKey.pencilSeen) private var pencilSeen = false

    /// An iPhone shows the Pencil's choices once a Pencil has touched it.
    private var hasPencil: Bool { !Device.isPhone || pencilSeen }
    @AppStorage(SettingsKey.journalAgenda) private var printsAgenda = false
    @AppStorage(SettingsKey.spotlight) private var showsInSpotlight = true
    @AppStorage(SettingsKey.appearance) private var appearance: AppAppearance = .initial
    @AppStorage(SettingsKey.leftHanded) private var leftHanded = false
    @AppStorage(SettingsKey.trashLength) private var trashLength: TrashLength = .initial
    @AppStorage(SettingsKey.transcriptLanguage) private var transcriptLanguage = ""
    @State private var transcriptLanguages: [Locale] = []
    @State private var toolbox = Toolbox.shared
    @State private var confirmingPenReset = false
    @State private var agendaMessage: String?
    @State private var confirmingHistoryClear = false
    @State private var backupWork: BackupWork?
    @State private var backingUp: Task<Void, Never>?
    @State private var lastBackup: URL?
    @State private var sharedBackup: SharedFile?
    @State private var choosingBackup = false
    @State private var backupMessage: String?

    private enum BackupWork { case backingUp, restoring }

    private struct SharedFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    private let repository = URL(string: "https://github.com/owaisazmal/OwlLuna")!
    private let author = URL(string: "https://github.com/owaisazmal")!
    private let website = URL(string: "https://owaisazmal.github.io/OwlLuna")!

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.x8) {
                appearanceSection
                inputSection
                pencilSection
                penTraySection
                paperSection
                if UIApplication.shared.supportsAlternateIcons {
                    SettingsSection("App Icon") { AppIconPicker().settingsRow() }
                }
                recordingsSection
                journalSection
                historySection
                trashSection
                searchSection
                syncSection
                backupSection
                aboutSection
            }
            .settingsPage("Settings")
            .toggleStyle(.owlLuna)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.buttonStyle(.owlLuna(.primary, inBar: true))
                }
                .boardBackground()
            }
        }
        .tint(Color.accentColor)
        .presentationSizing(.page)
        .sheet(item: $sharedBackup) { file in ShareSheet(items: [file.url]).presentationCornerRadius(Radius.sheet) }
        // The backup is kept to share again while Settings is open.
        .onDisappear {
            backingUp?.cancel()
            if let lastBackup { ExportFolder.discard([lastBackup]) }
        }
        .fileImporter(isPresented: $choosingBackup, allowedContentTypes: [.owlLunaBackup, .legacyBackup, .appleArchive]) { result in
            if case .success(let url) = result { restore(url) }
        }
        .notice("Backup", message: $backupMessage)
    }

    private var appearanceSection: some View {
        SettingsSection("Appearance", note: "“System” follows the iPad's Light or Dark appearance. With Keep Paper Light on, pages, paper colours and templates stay light in Dark Mode, and ink looks as it does on light paper. A PDF, a photo and everything you export keep their own colours.") {
            OwlLunaSegmentedPicker("Appearance", selection: $appearance, options: AppAppearance.allCases,
                                   identifier: { "settings.appearance.\($0.rawValue)" }) { Text($0.displayName) }
                .accessibilityIdentifier("settings.appearance")
                .padding(.vertical, Space.x2)
                .settingsRow()
            Toggle("Keep Paper Light", isOn: Binding(get: { !darkPaper }, set: { darkPaper = !$0 }))
                .accessibilityIdentifier("settings.appearance.paperLight")
                .settingsRow()
        }
    }

    /// An iPhone that has never had a Pencil on it draws with a finger, so there is nothing to choose.
    private var inputSection: some View {
        SettingsSection("Input", note: !hasPencil
                        ? "With Left-Handed on, the page ribbon, the zoom window's buttons and the panels beside the page are on the left."
                        : "“System Setting” follows Settings › Apple Pencil › Only Draw with Apple Pencil. With Left-Handed on, the page ribbon, the zoom window's buttons and the panels beside the page are on the left.") {
            if hasPencil {
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text("Draw With")
                    OwlLunaSegmentedPicker("Draw With", selection: $drawingInput, options: DrawingInput.allCases) { Text($0.displayName) }
                }
                .padding(.vertical, Space.x2)
                .settingsRow()
            }
            Toggle("Left-Handed", isOn: $leftHanded)
                .accessibilityIdentifier("settings.input.leftHanded")
                .settingsRow()
        }
    }

    private var penTraySection: some View {
        SettingsSection("Pen Tray") {
            SettingsActionRow(title: "Reset Pen Tray…", systemImage: "arrow.counterclockwise", role: .destructive) { confirmingPenReset = true }
                .disabled(toolbox.shelf.isAsItStarted)
                .accessibilityIdentifier("settings.pens.reset")
                .notice("Reset the pen tray?", isPresented: $confirmingPenReset,
                        message: Text("It goes back to the four it started with: a black, a blue and a red pen and a yellow highlighter. Pens you added or changed are taken off it.")) {
                    Button("Cancel", role: .cancel) {}
                    Button("Reset Pen Tray", role: .destructive) { toolbox.resetPens() }
                }
        }
    }

    private var recordingsSection: some View {
        let chosen = transcriptLanguage.isEmpty ? nil : Locale(identifier: transcriptLanguage)
        return SettingsSection("Recordings", note: "Recordings are transcribed on this iPad, in this language unless you pick another for one. Only the languages this iPad can transcribe without sending a recording away are listed.") {
            SettingsChoiceRow(title: "Transcription Language", value: chosen.map(Transcription.name(of:)) ?? String(localized: "Same as iPad"),
                              selection: $transcriptLanguage) {
                Section { Text("Same as iPad").tag("") }
                if !transcriptLanguages.isEmpty {
                    Section {
                        ForEach(transcriptLanguages, id: \.identifier) { Text(Transcription.name(of: $0)).tag($0.identifier(.bcp47)) }
                    }
                }
            }
            .accessibilityIdentifier("settings.transcription.language")
        }
        .task { transcriptLanguages = await Task.detached(priority: .userInitiated) { Transcription.onDeviceLanguages() }.value }
    }

    private var trashSection: some View {
        SettingsSection("Recently Deleted", note: "Notebooks in Recently Deleted are deleted for good once they have been there this long. Each device keeps to its own setting: with iCloud sync on, a notebook whose time runs out here stays on another device set to keep it longer, until its time there runs out too.") {
            VStack(alignment: .leading, spacing: Space.x2) {
                Text("Keep Deleted Notebooks For")
                OwlLunaSegmentedPicker("Keep Deleted Notebooks For", selection: $trashLength, options: TrashLength.allCases,
                                       identifier: { "settings.trash.\($0.days)" }) { Text($0.displayName) }
                    .accessibilityIdentifier("settings.trash.length")
            }
            .padding(.vertical, Space.x2)
            .settingsRow()
            .onChange(of: trashLength) { _, _ in
                if let app { Task { await app.trash.lengthChanged() } }
            }
        }
    }

    /// Without a Pencil the same gestures are drawn with a finger, and there is nothing to double-tap or squeeze.
    private var pencilSection: some View {
        SettingsSection(hasPencil ? "Apple Pencil" : "Drawing", note: !hasPencil
                        ? "Draw a line, arrow, circle, rectangle or triangle and hold still before lifting to straighten it, or draw a loop round ink and hold still to select it. Scribble back and forth over ink with a pen to erase it; Undo brings it back. A highlighter drawn along a line of a PDF's text is laid straight over that line."
                        : "Draw a line, arrow, circle, rectangle or triangle and hold still before lifting to straighten it, or draw a loop round ink and hold still to select it. Scribble back and forth over ink with a pen to erase it; Undo brings it back. A highlighter drawn along a line of a PDF's text is laid straight over that line. For Double-Tap and Squeeze, “System Setting” follows Settings › Apple Pencil.") {
            Toggle("Straighten Shapes", isOn: $snapsShapes).settingsRow()
            Toggle("Snap Highlighter to PDF Text", isOn: $snapsHighlighter).settingsRow()
            Toggle("Circle and Hold to Select", isOn: $circleSelects)
                .accessibilityIdentifier("settings.pencil.circle")
                .settingsRow()
            Toggle("Scribble to Erase", isOn: $scribbleErases)
                .accessibilityIdentifier("settings.pencil.scribble")
                .settingsRow()
            if hasPencil {
                SettingsChoiceRow(title: "Double-Tap", value: pencilDoubleTap.displayName, selection: $pencilDoubleTap) {
                    ForEach(PencilAction.allCases) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("settings.pencil.doubleTap")
                SettingsChoiceRow(title: "Squeeze", value: pencilSqueeze.displayName, selection: $pencilSqueeze) {
                    ForEach(PencilAction.allCases) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("settings.pencil.squeeze")
            }
        }
    }

    private var paperSection: some View {
        SettingsSection("New Notebooks") {
            SettingsChoiceRow(title: "Template", value: ownPaperName ?? template.displayName,
                              selection: Binding(get: { template }, set: { template = $0; ownPaper = "" })) {
                ForEach(PaperFamily.allCases) { family in
                    Section(family.displayName) {
                        ForEach(family.templates) { Text($0.displayName).tag($0) }
                    }
                }
            }
            .task(id: ownPaper) {
                let id = ownPaper, root = store.root
                ownPaperName = id.isEmpty ? nil : await Task.detached(priority: .userInitiated) { PaperShelf.paper(id, in: root)?.name }.value
            }
            SettingsChoiceRow(title: "Paper Colour", value: color.displayName, selection: $color) {
                ForEach(PaperColor.allCases) { Text($0.displayName).tag($0) }
            }
            SettingsChoiceRow(title: "Page Size", value: size.displayName, selection: $size) {
                ForEach(PageSize.allCases) { Text($0.displayName).tag($0) }
            }
        }
    }

    private var journalSection: some View {
        let journal = journalID.isEmpty ? nil : store.dailyJournal
        return SettingsSection("Daily Journal", note: "Touch and hold a notebook, then choose Use as Daily Journal. Press ⌘T in the library to open today's page. With Print Today's Events on, each new day's page starts with that day's events from your calendar, as text you can move or delete. They are read on this iPad.") {
            SettingsValueRow(title: "Journal", value: journal?.title ?? String(localized: "None"))
            Toggle("Show On This Day", isOn: $showsOnThisDay).settingsRow()
            Toggle("Print Today's Events", isOn: Binding(get: { printsAgenda }, set: setPrintsAgenda))
                .accessibilityIdentifier("settings.journal.agenda")
                .settingsRow()
            if journal != nil {
                SettingsActionRow(title: "Stop Using Daily Journal", systemImage: "calendar.badge.minus") { store.setDailyJournal(nil) }
            }
        }
        .notice("Calendar", message: $agendaMessage)
    }

    private var historySection: some View {
        SettingsSection("Writing History", note: "OwlLuna keeps a list of the days you wrote and which pages. It is not synced, but it is part of every backup you make.") {
            Toggle("Keep Writing History", isOn: Bindable(activity).isEnabled).settingsRow()
            SettingsActionRow(title: "Clear Writing History…", systemImage: "trash", role: .destructive) { confirmingHistoryClear = true }
                .disabled(!activity.hasHistory)
                .notice("Clear your writing history?", isPresented: $confirmingHistoryClear,
                        message: Text("The week strip and calendar start afresh. Your notebooks and pages aren't affected.")) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear Writing History", role: .destructive) { Task { await activity.clear() } }
                }
        }
    }

    private var searchSection: some View {
        SettingsSection("Search", note: "Notebooks can be found from the Home Screen by their title or by the words in them. That index is kept by iPadOS on this iPad. Locked notebooks are never in it.") {
            Toggle("Find Notebooks in Spotlight", isOn: $showsInSpotlight)
                .accessibilityIdentifier("settings.spotlight")
                .settingsRow()
                .onChange(of: showsInSpotlight) { _, _ in
                    if let app { app.spotlight.schedule(app.library, after: .zero) }
                }
        }
    }

    @ViewBuilder
    private var syncSection: some View {
        if let sync = app?.sync {
            SettingsSection("iCloud", note: "Each notebook is copied whole to your private iCloud storage and from there to your other devices, with your folders, smart shelves, stickers and pens. A notebook open here is sent a few seconds after you stop writing, and one open on another device then shows the newer version, unless it has changes of its own. If one was changed on two devices before they could sync, the newer version is kept and the older is saved beside it as a conflicted copy. Writing history is not synced. Turning sync off leaves the copy in iCloud. To remove it, turn sync off on every device, then delete OwlLuna's data in Settings › your name › iCloud.") {
                Toggle("Sync with iCloud", isOn: Bindable(sync).isEnabled)
                    .accessibilityIdentifier("settings.sync.toggle")
                    .settingsRow()
                if case .unavailable(let reason) = sync.availability {
                    Text(reason).syncStatusRow("settings.sync.unavailable")
                } else if sync.question == .accountChanged {
                    Text(SyncQuestion.accountChangedMessage).syncStatusRow("settings.sync.account")
                    SettingsActionRow(title: "Sync with This Account", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await sync.answer(true) }
                    }
                    .accessibilityIdentifier("settings.sync.account.allow")
                    SettingsActionRow(title: "Turn Off Sync", systemImage: "icloud.slash") {
                        Task { await sync.answer(false) }
                    }
                    .accessibilityIdentifier("settings.sync.account.refuse")
                } else if sync.isEnabled {
                    SettingsActionRow(title: "Sync Now", systemImage: "arrow.triangle.2.circlepath", isBusy: sync.isSyncing) {
                        Task { await sync.syncNow() }
                    }
                    .disabled(sync.isSyncing)
                    .accessibilityIdentifier("settings.sync.now")
                    if sync.isSyncing, let progress = sync.progress, progress.total > 1 {
                        SyncTicks(title: Text("Syncing \(min(progress.done + 1, progress.total)) of \(progress.total) notebooks"), progress: progress)
                            .accessibilityIdentifier("settings.sync.progress")
                            .settingsRow()
                    }
                    if let count = sync.uploadCount {
                        SyncTicks(title: Text("Uploading \(min(count.done + 1, count.total)) of \(count.total) notebooks to iCloud"), progress: count)
                            .accessibilityIdentifier("settings.sync.uploading")
                            .settingsRow()
                    }
                    if let date = sync.lastSynced {
                        let when = SyncCenter.formatted(date)
                        // What a pass did is shown once one has finished since launch, and not beside an error.
                        if let status = sync.status, sync.lastError == nil {
                            Text("\(status). Last synced \(when).").syncStatusRow("settings.sync.status")
                        } else {
                            Text("Last synced \(when).").syncStatusRow("settings.sync.last")
                        }
                    }
                    if let error = sync.lastError {
                        Text(error).syncStatusRow("settings.sync.error", color: .tomato)
                    }
                    if let problem = sync.uploads.problem {
                        Text(problem.message).syncStatusRow("settings.sync.uploads", color: .tomato)
                    }
                    ForEach(sync.lastReport?.failed ?? [], id: \.id) { failure in
                        SyncFailureRow(failure: failure, title: store.record(failure.id)?.title)
                    }
                }
            }
        }
    }

    private var backupSection: some View {
        SettingsSection("Backup", note: "A backup is one file holding your whole library: every notebook, locked or recently deleted ones included, with your folders, smart shelves, stickers and writing history. It is not encrypted, so keep it somewhere you trust. Restoring adds what is missing and never replaces a notebook: one that differs from the backup comes back beside yours as a copy.") {
            SettingsActionRow(title: "Back Up Library…", systemImage: "externaldrive", isBusy: backupWork == .backingUp, action: backUp)
                .accessibilityIdentifier("settings.backup.create")
            if let lastBackup {
                SettingsActionRow(title: "Share the Backup Again", systemImage: "square.and.arrow.up") { shareAgain(lastBackup) }
                    .accessibilityIdentifier("settings.backup.share")
            }
            SettingsActionRow(title: "Restore from a Backup…", systemImage: "arrow.counterclockwise", isBusy: backupWork == .restoring) {
                choosingBackup = true
            }
            .accessibilityIdentifier("settings.backup.restore")
        }
        .disabled(backupWork != nil)
    }

    private var aboutSection: some View {
        SettingsSection("About") {
            Colophon(author: author)
            SettingsLinkRow(title: "Privacy Policy", systemImage: "hand.raised",
                            destination: website.appending(path: "privacy", directoryHint: .isDirectory))
                .accessibilityIdentifier("settings.about.privacy")
            SettingsLinkRow(title: "Support", systemImage: "lifepreserver",
                            destination: website.appending(path: "support", directoryHint: .isDirectory))
                .accessibilityIdentifier("settings.about.support")
            SettingsLinkRow(title: "Source Code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right", destination: repository)
            SettingsLinkRow(title: "Report a Problem or Request a Feature", systemImage: "exclamationmark.bubble",
                            destination: repository.appendingPathComponent("issues"))
            SettingsLinkRow(title: "MIT License", systemImage: "doc.text", destination: repository.appendingPathComponent("blob/main/LICENSE"))
            NavigationLink {
                AcknowledgementsView()
            } label: {
                HStack(spacing: Space.x3) {
                    Label("Acknowledgements", systemImage: "text.book.closed")
                    Spacer(minLength: 0)
                    SettingsRowGlyph(systemName: "chevron.forward")
                }
            }
            .buttonStyle(.settingsRow)
        }
    }

    /// Turning it on asks for the calendar there and then, so a new day's page never has to.
    private func setPrintsAgenda(_ on: Bool) {
        printsAgenda = on
        guard on else { return }
        Task {
            do {
                _ = try await Agenda.calendar.events(on: .now, calendar: .current)
            } catch {
                printsAgenda = false
                agendaMessage = error.localizedDescription
            }
        }
    }

    private func backUp() {
        backupWork = .backingUp
        backingUp = Task {
            defer { backupWork = nil }
            do {
                guard let url = try await store.backupToShare() else { return }
                guard !Task.isCancelled else { return ExportFolder.discard([url]) }
                if let lastBackup { ExportFolder.discard([lastBackup]) }
                lastBackup = url
                sharedBackup = SharedFile(url: url)
            } catch {
                backupMessage = error.localizedDescription
            }
        }
    }

    private func shareAgain(_ made: URL) {
        Task {
            do {
                if let url = try await store.backupToShare(made) { sharedBackup = SharedFile(url: url) }
            } catch {
                backupMessage = error.localizedDescription
            }
        }
    }

    private func restore(_ url: URL) {
        backupWork = .restoring
        Task {
            defer { backupWork = nil }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try await store.restoreBackup(from: url)
                await activity.load()
                await AppModel.shared.flashcards.load()
                backupMessage = summary.message
            } catch {
                backupMessage = error.localizedDescription
            }
        }
    }
}

/// The book's last page: the mark, the name, what it costs and who made it.
private struct Colophon: View {
    let author: URL

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–" }

    var body: some View {
        VStack(spacing: Space.x3) {
            OwlLunaMark()
                .frame(width: 72, height: 72)
                .accessibilityLabel("OwlLuna")
                .accessibilityAddTraits(.isImage)
            VStack(spacing: Space.x1) {
                Text(verbatim: "OwlLuna").displayFont(28, relativeTo: .title)
                Text(verbatim: "\(String(localized: "Version")) \(version)").metaStyle()
            }
            .accessibilityElement(children: .combine)
            Text("OwlLuna is free and open source. No ads, no subscriptions, no tracking. Your notes stay on your iPad, and in your own iCloud if you turn sync on.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: author) {
                HStack(spacing: Space.x1) {
                    Text("Built by \(Text(verbatim: "Owais Khan").fontWeight(.semibold).foregroundStyle(Color.accentColor))")
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
                .foregroundStyle(Color.ink)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .hoverEffect(.highlight)
            .accessibilityIdentifier("settings.about.author")
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.x5)
        .padding(.top, Space.x6)
        .padding(.bottom, Space.x3)
    }
}

struct AcknowledgementsView: View {
    private struct Entry: Identifiable {
        let id: String
        let name: String
        let use: String
        let license: String
    }

    private var entries: [Entry] {
        [("Fraunces", String(localized: "Library headings, cloth labels and empty states"), "OFL-Fraunces"),
         ("Bricolage Grotesque", String(localized: "Print cover titles"), "OFL-BricolageGrotesque"),
         ("Archivo", String(localized: "The opening screen"), "OFL-Archivo")].map { name, use, file in
            let url = Bundle.main.url(forResource: file, withExtension: "txt")
            return Entry(id: file, name: name, use: use, license: url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x8) {
            ForEach(entries) { entry in
                SettingsSection(title: Text(verbatim: entry.name)) {
                    Text(entry.use).foregroundStyle(Color.textSecondary).settingsRow()
                    DisclosureGroup("SIL Open Font License 1.1") {
                        Text(entry.license)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Space.x2)
                    }
                    .settingsRow()
                }
            }
        }
        .settingsPage("Acknowledgements")
    }
}

private extension View {
    /// A page of Settings: one column no wider than a page, scrolled on paper under a bar the paper's colour.
    func settingsPage(_ title: LocalizedStringKey) -> some View {
        ScrollView {
            self.frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Space.x5)
                .padding(.top, Space.x4)
                .padding(.bottom, Space.x10)
        }
        .foregroundStyle(Color.ink)
        .background(Color.paper)
        .navigationTitle(title)
        .barGround(.paper)
    }
}

@MainActor private extension Text {
    func syncStatusRow(_ identifier: String, color: Color = .textSecondary) -> some View {
        font(.subheadline).foregroundStyle(color).accessibilityIdentifier(identifier).settingsRow()
    }
}

/// A notebook the last sync couldn't copy, and why.
struct SyncFailureRow: View {
    let failure: SyncFailure
    let title: String?

    var body: some View {
        HStack(spacing: Space.x3) {
            Image(systemName: "exclamationmark.triangle").rowTile(tint: .tomato)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title ?? String(localized: "A notebook from iCloud")) didn't sync")
                Text(failure.reason.message).font(.subheadline).foregroundStyle(Color.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .settingsRow()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.sync.failed")
    }
}
