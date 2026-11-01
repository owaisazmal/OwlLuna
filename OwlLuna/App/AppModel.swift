import SwiftUI
import SwiftData
import os

/// Process-wide state shared by every window: storage and the library index.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase: Equatable { case starting, ready }

    let root: StorageRoot
    let container: ModelContainer
    let library: LibraryStore
    let activity: WritingActivity
    let flashcards: FlashcardLibrary
    let sync: SyncCenter
    let spotlight: SpotlightIndexer
    let trash: TrashPurge
    private let shortcutParameters = ShortcutParameters()
    private(set) var phase: Phase = .starting
    /// Set by a shortcut; the front window's library takes it and carries it out.
    var pendingAction: AppAction?
    @ObservationIgnored private let indexWasRecovered: Bool
    @ObservationIgnored private var started = false
    @ObservationIgnored private let signposter = OSSignposter(category: "app")

    init(root: StorageRoot = LaunchOptions.storageRoot) {
        OwlLunaFonts.register()
        self.root = root
        let (container, recovered) = LibraryIndex.makeContainer(root: root)
        self.container = container
        indexWasRecovered = recovered
        library = LibraryStore(root: root, context: container.mainContext)
        activity = WritingActivity(root: root)
        flashcards = FlashcardLibrary(root: root)
        sync = SyncCenter(root: root)
        spotlight = SpotlightIndexer(container: container)
        trash = TrashPurge(library: library, sync: sync)
        library.onPermanentlyDeleted = { [activity, flashcards] in
            activity.forget(notebooks: $0)
            flashcards.forget(notebooks: $0)
        }
        sync.take = { DocumentRegistry.shared.take($0) }
        sync.release = { DocumentRegistry.shared.release($0) }
        sync.holdFolders = { [library] in try await library.holdingFolders($0) }
        sync.holdShelves = { [library] in try await library.holdingShelves($0) }
        sync.pens = { Toolbox.shared.shelf.synced }
        sync.onPensArrived = { Toolbox.shared.takePens($0, since: $1) }
        sync.editors = .shared
        library.onShelvesSaved = { [sync] in sync.schedule() }
        Toolbox.shared.shelf.onChanged = { [sync] in sync.schedule() }
        // What a sync brought in (a lock, a deletion) reaches Spotlight and the widgets as a change made here would.
        sync.onLibraryChanged = { [weak self, library, flashcards, spotlight] report in
            await library.reloadFromDisk(after: report)
            await flashcards.load()
            spotlight.schedule(library, after: .zero)
            if let self { await WidgetBridge.update(self) }
        }
        library.onIndexSaved = { [sync, spotlight, flashcards, weak library] in
            Task { await flashcards.loadNewNotebooks() }
            sync.schedule()
            if let library { spotlight.schedule(library) }
        }
        library.onSearchTextChanged = { [spotlight] in spotlight.noteTextChanged($0) }
        library.onJournalSetAside = { [sync] in sync.noteJournalSetAside($0) }
        flashcards.onSaved = { [sync] in sync.schedule() }
    }

    /// A Control Center button was pressed: what it asked for becomes the pending action.
    func takeControlAction() {
        guard let name = ControlRelay.take(), let url = URL(string: "\(AppAction.scheme)://\(name)"), let action = AppAction(url: url) else { return }
        pendingAction = action
    }

    /// Safe to call from anywhere: later callers wait for the first one to finish.
    func start() async {
        guard !started else {
            while phase != .ready { try? await Task.sleep(for: .milliseconds(50)) }
            return
        }
        started = true
        let interval = signposter.beginInterval("Launch")
        let launched = Date.now
        root.adoptLegacyPackages()
        #if DEBUG
        if root.packageIDs().isEmpty {
            if let count = LaunchOptions.value("-seedLibrary").flatMap(Int.init) { await LibrarySeed.write(count: count, root: root) }
            if LaunchOptions.arguments.contains("-seedLongPDF") { await LibrarySeed.writeLongPDF(root: root) }
            if LaunchOptions.arguments.contains("-seedReplay") { await ReplaySeed.write(root: root) }
            if LaunchOptions.arguments.contains("-seedHandwriting") { await HandwritingSeed.write(root: root) }
            if LaunchOptions.arguments.contains("-seedStudy") { await StudySeed.write(root: root) }
            await DailyJournal.seedForTests(root: root)
        }
        if LaunchOptions.arguments.contains("-seedActivity") { await WritingActivity.seedForTests(root: root) }
        if LaunchOptions.arguments.contains("-seedPaper") { PaperSeed.write(root: root) }
        if LaunchOptions.arguments.contains("-increaseContrast") {
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes { scene.traitOverrides.accessibilityContrast = .high }
        }
        #endif
        let root = root
        let sweep = Task.detached(priority: .utility) {
            LibraryStore.sweepDeleted(root: root)
            LibrarySync.sweepArriving(root: root, untouchedSince: launched)
            LibraryStore.sweepUnfinished(root: root, untouchedSince: launched)
        }
        // An index made by an older build reads every manifest once, for what that build didn't keep.
        let indexSchema = UserDefaults.standard.integer(forKey: SettingsKey.indexSchema)
        await LibraryIndex.refresh(root: root, context: container.mainContext, full: indexWasRecovered || indexSchema < LibraryIndex.schemaNumber)
        if indexSchema != LibraryIndex.schemaNumber { UserDefaults.standard.set(LibraryIndex.schemaNumber, forKey: SettingsKey.indexSchema) }
        await library.settleJournal()
        await library.loadSmartShelves()
        await activity.load()
        await flashcards.load()
        phase = .ready
        spotlight.schedule(library)
        shortcutParameters.start(library)
        Task {
            await sweep.value
            await sync.resolve()
            await sync.syncNow()
            await trash.launchSyncTried()
            // A notebook reopened before its newer version could be brought in catches up now.
            await sync.catchUp(open: .shared)
        }
        Task.detached(priority: .background) {
            CoverCache.shared.sweepDisk()
            ExportFolder.sweep(madeBefore: launched)
        }
        signposter.endInterval("Launch", interval)
    }

    func flushOpenDocuments() {
        let documents = DocumentRegistry.shared.openDocuments.filter(\.hasUnsavedChanges)
        guard !documents.isEmpty || sync.hasWaitingSends else { return }
        UIApplication.shared.withBackgroundTime("Save notebooks") { [activity, sync] in
            for document in documents { await document.flush() }
            activity.flush()
            await sync.sendWaiting()
            await sync.syncNow()
        }
    }
}

/// Test-only launch arguments. A Release build reads none of them.
enum LaunchOptions {
    #if DEBUG
    static let arguments = ProcessInfo.processInfo.arguments

    static func value(_ key: String) -> String? {
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// UI-test libraries never reach the widgets, Spotlight or iCloud.
    static let usesTestStorage = value("-storageRoot") != nil

    /// Accessibility audits can take longer than the slip's dismissal timer.
    static let keepsUndoVisible = usesTestStorage && arguments.contains("-keepUndoVisible")

    /// `-storageRoot <name>` keeps UI tests in their own folder; `-resetStorage` empties it first.
    static let storageRoot: StorageRoot = {
        guard let name = value("-storageRoot") else { return .live }
        guard let url = testFolder(named: name) else { preconditionFailure("-storageRoot takes a plain folder name, not \(name)") }
        if arguments.contains("-resetStorage") { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return StorageRoot(url: url)
    }()

    /// A `-resetStorage` UI test, and the app hosting unit tests, start without the settings saved on the simulator; arguments still set any.
    static func forgetSavedSettings(arguments: [String] = arguments, hostingUnitTests: Bool = NSClassFromString("XCTestCase") != nil,
                                    defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) {
        guard arguments.contains("-storageRoot") ? arguments.contains("-resetStorage") : hostingUnitTests, let domain else { return }
        defaults.removePersistentDomain(forName: domain)
    }

    static let testingDirectory = URL.applicationSupportDirectory.appending(path: "UITesting", directoryHint: .isDirectory)

    /// The folder a test names for itself, always directly inside `base`; nil for a name that could reach anywhere else.
    static func testFolder(named name: String, in base: URL = testingDirectory) -> URL? {
        guard !name.isEmpty, name != ".", !name.contains(".."), !name.contains("/") else { return nil }
        return base.appending(path: name, directoryHint: .isDirectory)
    }
    #else
    static let usesTestStorage = false
    static let keepsUndoVisible = false
    static let storageRoot = StorageRoot.live
    static func forgetSavedSettings() {}
    #endif
}

extension UIApplication {
    /// Runs `work` with background time asked for it, given back when the work ends or iPadOS calls time.
    @discardableResult
    func withBackgroundTime(_ name: String, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        var task = UIBackgroundTaskIdentifier.invalid
        task = beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        return Task {
            await work()
            if task != .invalid { endBackgroundTask(task) }
        }
    }
}

