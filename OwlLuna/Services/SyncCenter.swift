import Foundation
import Observation
import CryptoKit
import os

/// Runs the library's sync with iCloud: finds the container, decides when to sync, and tells the library what changed.
/// Nothing is copied until it has been allowed once on this device, and it is unavailable in a build without the
/// iCloud capability.
@MainActor
@Observable
final class SyncCenter {
    enum Availability: Equatable {
        case checking
        case unavailable(String)
        case available
    }

    /// What has to be answered before anything is copied.
    enum Question: Equatable {
        /// This device has never synced.
        case firstSync
        /// The Apple Account signed in isn't the one this library was last synced with.
        case accountChanged
    }

    private(set) var availability = Availability.checking
    private(set) var question: Question?
    private(set) var isSyncing = false
    /// When a pass last finished, kept across launches.
    private(set) var lastSynced: Date? {
        didSet { defaults.set(lastSynced, forKey: SettingsKey.lastSynced) }
    }
    private(set) var lastError: String?
    private(set) var lastReport: SyncReport?
    /// How far the pass under way has got through the notebooks it moves; nil while none is under way.
    private(set) var progress: SyncProgress?
    /// What iCloud still has to upload from the synced copy, as last looked at.
    private(set) var uploads = CloudUploads()
    /// How many of the notebooks iCloud has been uploading since it last had none to upload are up; nil with none left.
    private(set) var uploading: SyncProgress?
    /// What the library shows about sync: failures, and conflicted copies made since it was last put away.
    private(set) var news = SyncNews()
    /// The switch in Settings. It can be set while iCloud is unavailable, and takes effect once it isn't.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: SettingsKey.syncsWithICloud)
            guard isEnabled else {
                // Turning sync off is an answer to whatever was being asked.
                question = nil
                return halt()
            }
            Task {
                await review()
                schedule(after: .zero)
            }
        }
    }

    @ObservationIgnored private let root: StorageRoot
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let hadSynced: Bool
    @ObservationIgnored private var cloud: CloudFolder?
    @ObservationIgnored private var account: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var identityObserver: NSObjectProtocol?
    @ObservationIgnored private var wantsAnotherPass = false
    @ObservationIgnored private var running: Task<SyncReport, Error>?
    @ObservationIgnored private var reviewing = 0
    /// Pulls for an editor waiting or under way, and whether one is under way.
    @ObservationIgnored private var pulls = 0
    @ObservationIgnored private var isPulling = false
    @ObservationIgnored private var uploadCheck: Task<Void, Never>?
    @ObservationIgnored private var uploadBatch: Set<UUID> = []
    /// Open notebooks saved since they were last sent, each with when the first of those saves was.
    @ObservationIgnored private var sends: [UUID: (task: Task<Void, Never>, since: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var stopped: String?
    /// Conflicted copies the library hasn't shown yet, kept across launches so a quit doesn't lose them.
    @ObservationIgnored private var newCopies: [UUID] = [] {
        didSet { defaults.set(newCopies.map(\.uuidString), forKey: SettingsKey.syncConflictCopies) }
    }
    /// This device's journals that gave way to one begun earlier on another device, not yet shown.
    @ObservationIgnored private var setAsideJournals: [UUID] = [] {
        didSet { defaults.set(setAsideJournals.map(\.uuidString), forKey: SettingsKey.syncSetAsideJournals) }
    }
    @ObservationIgnored private var putAway = SyncNews()
    /// Notebooks a pass held back that were asked to be kept, which the next pass brings back.
    @ObservationIgnored private var keeping: Set<UUID> = []
    /// Notebooks a pass held back whose deletes were meant, which the next pass lets through.
    @ObservationIgnored private var lettingGo: Set<UUID> = []
    /// The folder list in iCloud that can't be read is to be made again from this device's, which the next pass does.
    @ObservationIgnored private var replacingFolders = false
    @ObservationIgnored private let log = Logger(category: "sync")
    /// Reads what iCloud has still to upload. A test stands in for iCloud here.
    @ObservationIgnored var readUploads: @Sendable (CloudFolder) -> CloudUploads = { $0.isUbiquitous ? CloudUploads.read($0) : CloudUploads() }
    /// Called after a sync that changed the library on this device, so the index can be brought up to date. A pass
    /// that stopped part-way is reported too, with what it had done by then.
    @ObservationIgnored var onLibraryChanged: (@MainActor (SyncReport) async -> Void)?
    /// Called after every pass that finished, once the library has heard what it changed.
    @ObservationIgnored var onSynced: (@MainActor (SyncReport) async -> Void)?
    /// A pass takes each notebook in hand just before it touches it, and lets it go after. One that is open in an
    /// editor can't be taken, and is left for next time.
    @ObservationIgnored var take: @MainActor (UUID) -> Bool = { _ in true }
    @ObservationIgnored var release: @MainActor (UUID) -> Void = { _ in }
    /// A pass settles the folders inside this, which the library uses to keep its own folder writes out of the way.
    @ObservationIgnored var holdFolders: @MainActor (@escaping @Sendable () throws -> FolderPass?) async throws -> FolderPass? = { try $0() }
    /// And the smart shelves inside this.
    @ObservationIgnored var holdShelves: @MainActor (@escaping @Sendable () throws -> FolderPass?) async throws -> FolderPass? = { try $0() }
    /// This device's pens, read as a pass begins; nil leaves them out.
    @ObservationIgnored var pens: @MainActor () -> SyncedPens? = { nil }
    /// Called with pens another device changed, and the stamp this device's had when the pass read them.
    @ObservationIgnored var onPensArrived: (@MainActor (SyncedPens, Date?) -> Void)?
    /// The open notebooks: sent while they are written in, and brought up to date after every pass.
    @ObservationIgnored var editors: DocumentRegistry?

    init(root: StorageRoot, defaults: UserDefaults = .standard) {
        self.root = root
        self.defaults = defaults
        // A device that synced before there was a question to answer has already been syncing: it carries on.
        hadSynced = FileManager.default.fileExists(atPath: SyncState.file(root).path(percentEncoded: false))
        isEnabled = defaults.object(forKey: SettingsKey.syncsWithICloud) == nil ? hadSynced : defaults.bool(forKey: SettingsKey.syncsWithICloud)
        lastSynced = defaults.object(forKey: SettingsKey.lastSynced) as? Date
        newCopies = defaults.stringArray(forKey: SettingsKey.syncConflictCopies)?.compactMap(UUID.init(uuidString:)) ?? []
        setAsideJournals = defaults.stringArray(forKey: SettingsKey.syncSetAsideJournals)?.compactMap(UUID.init(uuidString:)) ?? []
        news.conflictCopies = newCopies
        news.journals = setAsideJournals
    }

    /// The library settled two journals that met, and this device's gave way: the notice says so until it is put away.
    func noteJournalSetAside(_ id: UUID) {
        guard !setAsideJournals.contains(id) else { return }
        setAsideJournals.append(id)
        refreshNews()
    }

    private var isDecided: Bool { hadSynced || defaults.object(forKey: SettingsKey.syncsWithICloud) != nil }

    /// Whether a pass may run: sync is on, the copy is found, and nothing is being asked or worked out.
    var canSync: Bool { isEnabled && question == nil && availability == .available && reviewing == 0 && cloud != nil }

    /// A marker for an Apple Account: a digest of the token iPadOS gives the app for it. It tells one account from
    /// another and nothing else.
    nonisolated static func marker(for token: (any NSCoding & NSCopying & NSObjectProtocol)?) -> String? {
        guard let token else { return nil }
        let data = (token as? NSData).map { $0 as Data } ?? (try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false))
        return data.map { SHA256.hash(data: $0).hex }
    }

    /// Finds where the synced copy lives. A test can stand a plain folder in for iCloud with `-cloudFolder <name>`,
    /// and a name in for the account with `-cloudAccount <name>`.
    func resolve() async {
        #if DEBUG
        if let name = LaunchOptions.value("-cloudFolder") {
            guard let url = LaunchOptions.testFolder(named: "cloud-\(name)") else { preconditionFailure("-cloudFolder takes a plain folder name, not \(name)") }
            if LaunchOptions.arguments.contains("-resetCloud") { try? FileManager.default.removeItem(at: url) }
            return await use(CloudFolder(url: url), account: LaunchOptions.value("-cloudAccount"))
        }
        #endif
        let signedOut = (Device.isMac
            ? String(localized: "iCloud isn't available. Sign in to iCloud and turn on iCloud Drive in System Settings; this copy of OwlLuna also has to be built with the iCloud capability.")
            : String(localized: "iCloud isn't available. Sign in to iCloud and turn on iCloud Drive in Settings; this copy of OwlLuna also has to be built with the iCloud capability."))
        // A test's storage root never syncs with real iCloud.
        guard !LaunchOptions.usesTestStorage else { return leave(signedOut) }
        if identityObserver == nil {
            identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.identityChanged() }
            }
        }
        guard let token = FileManager.default.ubiquityIdentityToken else { return leave(signedOut) }
        let container = await Task.detached(priority: .utility) { FileManager.default.url(forUbiquityContainerIdentifier: nil) }.value
        guard let container else {
            return leave(String(localized: "This copy of OwlLuna was built without the iCloud capability, so it can't sync."))
        }
        await use(CloudFolder(url: container.appending(path: "Sync", directoryHint: .isDirectory), isUbiquitous: true), account: Self.marker(for: token))
    }

    /// The synced copy has been found. What has to be asked first is worked out before sync is said to be
    /// available, so no pass touches the copy in between.
    func use(_ cloud: CloudFolder, account: String?) async {
        if cloud != self.cloud || account != self.account { halt() }
        availability = .checking
        self.cloud = cloud
        self.account = account
        await review()
        availability = .available
        if canSync { startWatching() }
    }

    private func leave(_ reason: String) {
        halt()
        cloud = nil
        account = nil
        question = nil
        availability = .unavailable(reason)
    }

    /// Signing out of iCloud, or in with another account, moves the container out from under the app. Nothing
    /// syncs until the account now signed in has been looked at.
    private func identityChanged() {
        halt()
        cloud = nil
        availability = .checking
        Task {
            await resolve()
            await syncNow()
        }
    }

    /// Works out what has to be asked. No pass starts while it does.
    private func review() async {
        guard cloud != nil else { return }
        reviewing += 1
        defer { reviewing -= 1 }
        let root = root
        let known = await Task.detached(priority: .utility) { SyncState.read(root).account }.value
        // Another account only matters while sync is on: with it off nothing is copied, and a refusal stands.
        if isEnabled, let account, let known, known != account {
            question = .accountChanged
        } else if !isDecided {
            question = .firstSync
        } else {
            question = nil
        }
    }

    /// The answer to `question`. Saying no turns sync off; turning it on again in Settings asks again while another
    /// account is still signed in.
    func answer(_ allowed: Bool) async {
        guard let asked = question else { return }
        guard allowed else {
            question = nil
            if isEnabled { isEnabled = false } else { defaults.set(false, forKey: SettingsKey.syncsWithICloud) }
            return
        }
        if asked == .accountChanged {
            // Only the marker moves. Whether what was agreed still holds is for the copy's own ID to say.
            let root = root, account = account
            await Task.detached(priority: .utility) {
                var state = SyncState.read(root)
                state.account = account
                try? state.write(root)
            }.value
        }
        question = nil
        if isEnabled {
            startWatching()
            await syncNow()
        } else {
            isEnabled = true
        }
    }

    /// Syncs a little later, so a burst of changes becomes one sync.
    func schedule(after delay: Duration = .seconds(4)) {
        guard canSync else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard canSync else { return }
        guard !isSyncing else { wantsAnotherPass = true; return }
        isSyncing = true
        defer {
            isSyncing = false
            progress = nil
        }
        repeat {
            wantsAnotherPass = false
            var done: SyncReport?, failure: (any Error)?
            do {
                // A second pass uploads the copies a conflict left behind.
                guard let first = try await pass() else { break }
                done = first
                if !first.conflictCopies.isEmpty, let again = try await pass() { done?.add(again) }
            } catch let stopped as StoppedPass {
                if done == nil { done = stopped.report } else { done?.add(stopped.report) }
                failure = stopped.reason
            } catch {
                failure = error
            }
            if failure == nil {
                lastReport = done
                lastSynced = .now
                lastError = nil
                stopped = nil
            }
            newCopies += done?.conflictCopies ?? []
            // What a pass did before it stopped is on disk all the same, so the library hears of that as well.
            if let done, done.changedHere { await onLibraryChanged?(done) }
            switch failure {
            case nil:
                if let done { await onSynced?(done) }
                // A notebook open here was left alone: one with nothing unsaved takes a newer version in place.
                if let done, let editors, !done.open.isEmpty { await catchUp(open: editors, only: Set(done.open)) }
                await checkUploads()
            case is CancellationError:
                // Stopped part-way because sync was turned off or the copy moved. Whoever stopped it decides what follows.
                break
            case let error? where error as? SyncError == .accountChanged:
                identityChanged()
            case let error?:
                lastError = error.localizedDescription
                // Waiting for iCloud to finish a download isn't something the library needs to hear about.
                stopped = error as? SyncError == .stillArriving ? nil : error.localizedDescription
                log.error("sync failed: \(error.localizedDescription)")
            }
            refreshNews()
        } while wantsAnotherPass
        if canSync { startWatching() }
    }

    /// One pass, or nil when sync may no longer run. That is asked before every pass, since the account may have
    /// changed or sync been turned off during the one before, and a ubiquitous pass asks the account again as it goes.
    private func pass() async throws -> SyncReport? {
        // A pull for an editor goes first: it is quick, and gives up after a few seconds.
        while pulls > 0 { try? await Task.sleep(for: .milliseconds(20)) }
        guard canSync, let cloud else { return nil }
        let root = root, account = account, keeping = keeping, lettingGo = lettingGo, replacing = replacingFolders
        let take = take, release = release, holdFolders = holdFolders, holdShelves = holdShelves, pens = pens()
        let signedIn: @Sendable () -> String? = { SyncCenter.marker(for: FileManager.default.ubiquityIdentityToken) }
        let advance: @Sendable (SyncProgress) -> Void = { [weak self] step in Task { @MainActor in self?.advance(step) } }
        progress = nil
        let task = Task.detached(priority: .utility) {
            try await LibrarySync.run(root: root, cloud: cloud, account: account, keeping: keeping, lettingGo: lettingGo, replacingFolders: replacing,
                                      take: { await take($0) }, release: { await release($0) },
                                      holdingFolders: { try await holdFolders($0) }, signedIn: cloud.isUbiquitous ? signedIn : nil,
                                      pens: pens, holdingShelves: { try await holdShelves($0) }, progress: advance)
        }
        running = task
        defer { running = nil }
        let report: SyncReport, stopped: StoppedPass?
        do {
            report = try await task.value
            stopped = nil
        } catch let error as StoppedPass {
            report = error.report
            stopped = error
        }
        if let received = report.pensReceived { onPensArrived?(received, pens?.changedAt) }
        self.keeping.subtract(keeping)
        if let stopped {
            // What was agreed was saved, kept notebooks and all.
            self.lettingGo.subtract(report.removedHere + report.removedThere)
            throw stopped
        }
        // One the pass left for later is still let go when it comes back to it.
        self.lettingGo.subtract(lettingGo.subtracting(report.waiting))
        if replacing { replacingFolders = false }
        return report
    }

    /// Steps can reach the main actor out of order: one behind the last shown is dropped.
    private func advance(_ step: SyncProgress) {
        guard isSyncing else { return }
        if let progress, progress.total == step.total, progress.done > step.done { return }
        progress = step
    }

    /// The notebooks the last pass wouldn't take as deleted are wanted after all: the next pass brings them back
    /// wherever they're gone.
    func keepHeld() async {
        keeping.formUnion(news.held)
        refreshNews()
        await syncNow()
    }

    /// The deletes the last pass held back were meant: the next pass lets them through, as it would one at a time.
    func letHeldGo() async {
        lettingGo.formUnion(news.held)
        refreshNews()
        await syncNow()
    }

    /// The folder list in iCloud can't be read: the next pass puts a new one made from this device's folders in its
    /// place, and every other device adds its own to it.
    func replaceFolders() async {
        replacingFolders = true
        refreshNews()
        await syncNow()
    }

    /// How long a window waits at launch for the notebook it reopens to be brought up to date.
    static let reopenLimit: Duration = .seconds(4)

    /// Brings in the synced copy's newer version of notebooks an editor is about to open, or has open (`take` then lets
    /// go of it), without waiting for a whole pass. Gives up after `limit`, and returns at once with sync off. It waits
    /// for a pass under way, and a pass for it, so the two never settle a notebook at once.
    @discardableResult
    func pullNewer(_ ids: [UUID], within limit: Duration, take: (@MainActor (UUID) -> Bool)? = nil) async -> [UUID: LibrarySync.Newer] {
        guard isEnabled, !ids.isEmpty else { return [:] }
        let deadline = ContinuousClock.now + limit
        return await inTurn(by: deadline) { cloud in
            let root = root, take = take ?? self.take, release = release
            var outcome: [UUID: LibrarySync.Newer] = [:]
            for id in ids {
                let left = deadline - ContinuousClock.now
                guard left > .zero, canSync else { break }
                let newer = try? await Task.detached(priority: .userInitiated) {
                    try await LibrarySync.pullNewer(id, root: root, cloud: cloud, timeout: left, take: { await take($0) }, release: { await release($0) })
                }.value
                outcome[id] = newer ?? LibrarySync.Newer.none
            }
            let pulled = ids.filter { outcome[$0] == .pulled }
            if !pulled.isEmpty { await onLibraryChanged?(SyncReport(pulled: pulled)) }
            return outcome
        } ?? [:]
    }

    /// Runs `work` in a turn taken by `deadline`, as a pull for an editor, and puts the turn back after. Nil when none was given.
    @discardableResult
    private func inTurn<T>(by deadline: ContinuousClock.Instant, _ work: @MainActor (CloudFolder) async -> T) async -> T? {
        pulls += 1
        defer { pulls -= 1 }
        guard let cloud = await takeTurn(by: deadline) else { return nil }
        defer { isPulling = false }
        return await work(cloud)
    }

    /// Waits until no pass or other pull is under way, up to `deadline`, and takes the turn: `isPulling` is then the
    /// caller's to put back. Nil when sync can't run, or time ran out.
    private func takeTurn(by deadline: ContinuousClock.Instant) async -> CloudFolder? {
        while isEnabled, availability == .checking || reviewing > 0 || running != nil || isPulling, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard canSync, let cloud, running == nil, !isPulling else { return nil }
        isPulling = true
        return cloud
    }

    /// Notebooks open in an editor that another device has written in since: one with nothing unsaved takes that version
    /// and its editor opens it again, and one with writing of its own is told that a newer version is waiting. `only`
    /// limits it to those notebooks.
    func catchUp(open registry: DocumentRegistry, within limit: Duration = .seconds(10), only: Set<UUID>? = nil) async {
        let ids = registry.openNotebooks.filter { only?.contains($0) ?? true }
        guard isEnabled, !ids.isEmpty else { return }
        // Saved first, so what is on the device says whether it was written in here.
        for id in ids { await registry.document(for: id)?.flush() }
        let outcome = await pullNewer(ids, within: limit) { registry.takeOpen($0) }
        for (id, newer) in outcome where newer == .waiting { registry.document(for: id)?.noteNewerVersion() }
    }

    /// How long an open notebook waits after a save before it is sent, and the longest that writing on can put it off.
    static let sendDelay: Duration = .seconds(5)
    static let sendLatency: Duration = .seconds(30)

    /// A notebook open here was saved: it is sent once writing pauses, and every half minute while it doesn't, so
    /// another device with it open can take it in place.
    func sendSoon(_ id: UUID) {
        guard canSync, editors != nil else { return }
        let now = ContinuousClock.now, since = sends[id]?.since ?? now
        let deadline = min(now + Self.sendDelay, since + Self.sendLatency)
        sends[id]?.task.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            sends[id] = nil
            await sendOpen(id)
        }
        sends[id] = (task, since)
    }

    /// Whether an open notebook is waiting for writing to pause before it is sent.
    var hasWaitingSends: Bool { !sends.isEmpty }

    /// Sends at once the open notebooks waiting for writing to pause, as the app leaves the front.
    func sendWaiting() async {
        for id in Array(sends.keys) {
            sends.removeValue(forKey: id)?.task.cancel()
            await sendOpen(id)
        }
    }

    /// Sends a notebook open here that was written in since it last agreed with the synced copy. One another device
    /// wrote in as well is told that a newer version is waiting.
    func sendOpen(_ id: UUID) async {
        guard let editors, canSync else { return }
        await inTurn(by: .now + .seconds(30)) { cloud in
            let root = root, release = release
            let hold: @MainActor (UUID) -> NotebookPackage? = { editors.takeToSend($0) }
            let outcome = try? await Task.detached(priority: .utility) {
                try await LibrarySync.pushNewer(id, root: root, cloud: cloud, timeout: .seconds(10), hold: { await hold($0) }, release: { await release($0) })
            }.value
            switch outcome?.sent {
            case .sent?:
                if outcome?.cardsReceived == true { await onLibraryChanged?(SyncReport(cardsReceived: [id])) }
                await checkUploads()
            case .waiting?:
                editors.document(for: id)?.noteNewerVersion()
            default:
                break
            }
        }
    }

    /// Keeps both versions of a notebook open here that another device wrote in too, as closing it would: the older as
    /// a conflicted copy. The editor stays on this device's version when it is the newer, and opens the other's when
    /// that is. False when it can't be done yet: sync is off, a save or recording is under way, or the other version
    /// hasn't all come down.
    @discardableResult
    func keepBoth(_ id: UUID) async -> Bool {
        guard let editors, let document = editors.document(for: id), canSync else { return false }
        await document.flush()
        return await inTurn(by: .now + .seconds(30)) { cloud in
            let root = root, release = release
            let take: @MainActor (UUID, Bool) -> NotebookPackage? = { id, replacing in
                replacing ? (editors.takeOpen(id) ? NotebookPackage(root: root, id: id) : nil) : editors.takeToSend(id)
            }
            let outcome = try? await Task.detached(priority: .userInitiated) {
                try await LibrarySync.keepBoth(id, root: root, cloud: cloud, timeout: .seconds(20), take: { await take($0, $1) }, release: { await release($0) })
            }.value
            guard let kept = outcome ?? nil else { return false }
            newCopies.append(kept.copy)
            refreshNews()
            await onLibraryChanged?(SyncReport(pushed: kept.pulled ? [] : [id], pulled: kept.pulled ? [id] : [], conflictCopies: [kept.copy]))
            let title = (try? await NotebookPackage(root: root, id: kept.copy).readManifest().manifest.title) ?? ""
            editors.noteKeptCopy(kept.pulled ? String(localized: "This is the newer version, from another device. Yours is kept in your library as “\(title)”.")
                                             : String(localized: "The version from another device is kept in your library as “\(title)”."), in: id)
            schedule(after: .zero)
            return true
        } ?? false
    }

    /// Whether a notebook has something iCloud hasn't uploaded yet.
    func isUploading(_ id: UUID) -> Bool { isEnabled && uploads.pending.contains(id) }

    /// Notebooks, flashcards and stickers arriving from another device show up as changes to the container's files.
    private func startWatching() {
        guard query == nil, cloud?.isUbiquitous == true else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        // Ink, text, pictures, recordings and transcripts too, since a pull waits for files that come down after the
        // manifest, and the package as one item, as iCloud may list it. Manifests, cards and the folder list are JSON.
        let kinds = ["*.\(StorageRoot.packageExtension)", "*.json", "*.pkdrawing", "*.txt", "*.png", "*.jpg", "*.pdf", "*.m4a", "*.\(RecordingFile.recordingExtension)"]
        query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: kinds.map { NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, $0) })
        for name in [Notification.Name.NSMetadataQueryDidUpdate, .NSMetadataQueryDidFinishGathering] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        query.start()
        self.query = query
    }

    /// Looks at what iCloud still has to upload, and again a little later while anything is left.
    private func checkUploads() async {
        uploadCheck?.cancel()
        guard let cloud else { return }
        let read = readUploads
        let fresh = await Task.detached(priority: .utility) { read(cloud) }.value
        // Set only when it changed, so the covers that show it aren't drawn again for nothing.
        if fresh != uploads { uploads = fresh }
        if uploads.pending.isEmpty { uploadBatch = [] } else { uploadBatch.formUnion(uploads.pending) }
        let count = uploads.pending.isEmpty ? nil : SyncProgress(done: uploadBatch.count - uploads.pending.count, total: uploadBatch.count)
        if count != uploading { uploading = count }
        refreshNews()
        guard !uploads.isClear else { return }
        // Looked at more often while notebooks are going up, so the count moves.
        let wait: Duration = uploads.pending.isEmpty || uploads.problem != nil ? .seconds(20) : .seconds(5)
        uploadCheck = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.checkUploads()
        }
    }

    /// Whether the last pass finished with nothing left behind, and iCloud holds everything it sent.
    var isUpToDate: Bool {
        lastError == nil && lastReport?.waiting.isEmpty == true && lastReport?.foldersUnreadable == false && uploads.isClear
    }

    /// "15 Oct, 14:05": the day as well as the time, since the last sync may be days ago.
    nonisolated static func formatted(_ date: Date, now: Date = .now) -> String {
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute()
        return date.formatted(Calendar.current.isDate(date, equalTo: now, toGranularity: .year) ? style : style.year())
    }

    /// How far iCloud is through uploading two or more notebooks, while nothing is stopping it.
    var uploadCount: SyncProgress? {
        guard let uploading, uploading.total > 1, uploads.problem == nil else { return nil }
        return uploading
    }

    /// The Settings line for the last pass: what it did, what it left, and what iCloud still has to upload, unless
    /// that is counted beside it.
    var status: String? {
        guard let lastReport else { return nil }
        let parts = lastReport.parts + (uploadCount == nil ? uploads.parts : [])
        guard !parts.isEmpty else { return uploadCount == nil ? String(localized: "Everything is up to date") : nil }
        return parts.joined(separator: ", ")
    }

    /// What is shown now, less what was put away and hasn't changed since.
    private func refreshNews() {
        let failed = lastReport?.failed ?? [], held = (lastReport?.held ?? []).filter { !keeping.contains($0) && !lettingGo.contains($0) }
        let foldersUnreadable = lastReport?.foldersUnreadable == true && !replacingFolders
        putAway.failed.removeAll { !failed.contains($0) }
        if Set(putAway.held) != Set(held) { putAway.held = [] }
        if putAway.uploadProblem != uploads.problem { putAway.uploadProblem = nil }
        if putAway.stopped != stopped { putAway.stopped = nil }
        if !foldersUnreadable { putAway.foldersUnreadable = false }
        let fresh = SyncNews(failed: failed.filter { !putAway.failed.contains($0) }, held: putAway.held.isEmpty ? held : [],
                             conflictCopies: newCopies, journals: setAsideJournals,
                             uploadProblem: uploads.problem == putAway.uploadProblem ? nil : uploads.problem,
                             stopped: stopped == putAway.stopped ? nil : stopped,
                             foldersUnreadable: foldersUnreadable && !putAway.foldersUnreadable)
        if fresh != news { news = fresh }
    }

    /// The library's notice was closed: what it said stays away until it changes.
    func putAwayNews() {
        putAway.failed += news.failed
        if !news.held.isEmpty { putAway.held = news.held }
        putAway.uploadProblem = uploads.problem
        putAway.stopped = stopped
        if news.foldersUnreadable { putAway.foldersUnreadable = true }
        newCopies = []
        setAsideJournals = []
        refreshNews()
    }

    /// Stops watching the container, and a pass that is part-way.
    private func halt() {
        pending?.cancel()
        running?.cancel()
        uploadCheck?.cancel()
        sends.values.forEach { $0.task.cancel() }
        sends = [:]
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

