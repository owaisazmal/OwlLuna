import SwiftUI
import SwiftData
import LocalAuthentication

protocol Authenticating: Sendable {
    /// Whether this iPad can ask for Face ID, Touch ID or a passcode at all.
    func isAvailable() -> Bool
    func authenticate(reason: String) async -> Bool
}

/// Face ID or Touch ID, falling back to the iPad's passcode.
struct DeviceAuthenticator: Authenticating {
    func isAvailable() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { passed, _ in continuation.resume(returning: passed) }
        }
    }
}

#if DEBUG
/// Stands in for Face ID, which a test can't present: `-fakeUnlock` always passes, `-fakeUnlockOnce` passes the
/// first time it is asked and never again, `-fakeUnlockFails` never passes.
final class ScriptedAuthenticator: Authenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int?

    init(passes: Int?) { remaining = passes }

    func isAvailable() -> Bool { true }

    func authenticate(reason: String) async -> Bool {
        try? await Task.sleep(for: .milliseconds(150))
        return lock.withLock {
            guard let left = remaining else { return true }
            remaining = max(left - 1, 0)
            return left > 0
        }
    }
}
#endif

/// Which locked notebooks are open for now. Nothing here is saved: a notebook is locked again when it is closed
/// and when the app leaves the screen.
@MainActor
@Observable
final class NotebookLock {
    static let shared = NotebookLock()

    private(set) var unlocked: Set<UUID> = []
    @ObservationIgnored var authenticator: any Authenticating = NotebookLock.standardAuthenticator
    @ObservationIgnored private var asking: Task<Bool, Never>?

    private static var standardAuthenticator: any Authenticating {
        #if DEBUG
        if LaunchOptions.arguments.contains("-fakeUnlock") { return ScriptedAuthenticator(passes: nil) }
        if LaunchOptions.arguments.contains("-fakeUnlockOnce") { return ScriptedAuthenticator(passes: 1) }
        if LaunchOptions.arguments.contains("-fakeUnlockFails") { return ScriptedAuthenticator(passes: 0) }
        #endif
        return DeviceAuthenticator()
    }

    var isAvailable: Bool { authenticator.isAvailable() }

    func isUnlocked(_ id: UUID) -> Bool { unlocked.contains(id) }

    @discardableResult
    func unlock(_ id: UUID, title: String) async -> Bool {
        if unlocked.contains(id) { return true }
        guard await confirm(String(localized: "Unlock “\(title)”")) else { return false }
        unlocked.insert(id)
        return true
    }

    /// Asks who is holding the iPad. One question at a time: a second caller waits for the first one's answer.
    func confirm(_ reason: String) async -> Bool {
        if let asking { return await asking.value }
        let authenticator = authenticator
        let task = Task { await authenticator.authenticate(reason: reason) }
        asking = task
        let passed = await task.value
        asking = nil
        return passed
    }

    func keepOpen(_ id: UUID) { unlocked.insert(id) }
    func lock(_ id: UUID) { unlocked.remove(id) }

    static let unavailableMessage = (Device.isMac
        ? String(localized: "To lock notebooks, set a login password for this Mac in System Settings first.")
        : String(localized: "To lock notebooks, set a passcode on this iPad in Settings first."))
}

extension LibraryStore {
    /// Whether any notebook is locked, ones in Recently Deleted included: a backup holds those too.
    var hasLockedNotebooks: Bool {
        ((try? context.fetch(FetchDescriptor<NotebookRecord>(predicate: #Predicate { $0.isLocked }))) ?? []).isEmpty == false
    }

    /// Locks a notebook, or takes its lock off, once whoever is holding the iPad has shown it is theirs.
    /// Returns what went wrong, if the iPad can't ask.
    func toggleLock(_ record: NotebookRecord) async -> String? {
        let lock = NotebookLock.shared
        guard lock.isAvailable else { return NotebookLock.unavailableMessage }
        let title = record.title.orUntitled, locking = !record.isLocked
        guard await lock.confirm(locking ? String(localized: "Lock “\(title)”") : String(localized: "Remove the lock from “\(title)”")) else { return nil }
        // A notebook locked while it is being written in stays open until it is closed.
        if locking, DocumentRegistry.shared.document(for: record.id) != nil { lock.keepOpen(record.id) }
        setLocked(locking, for: [record])
        AccessibilityNotification.Announcement(locking ? String(localized: "“\(title)” is locked") : String(localized: "Lock removed from “\(title)”")).post()
        return nil
    }

    /// Locks every notebook in `records` that isn't locked yet, asking once for all of them. Returns what went wrong, if the iPad can't ask.
    func lock(_ records: [NotebookRecord]) async -> String? {
        let ids = records.filter { !$0.isLocked && !$0.isReadOnly && !$0.isTrashed }.map(\.id)
        guard !ids.isEmpty else { return nil }
        let lock = NotebookLock.shared
        guard lock.isAvailable else { return NotebookLock.unavailableMessage }
        let title = records.first { $0.id == ids[0] }.map { $0.title.orUntitled } ?? ""
        let reason = ids.count == 1 ? String(localized: "Lock “\(title)”") : String(localized: "Lock \(ids.count) notebooks")
        guard await lock.confirm(reason) else { return nil }
        let locking = ids.compactMap(record).filter { !$0.isLocked }
        guard !locking.isEmpty else { return nil }
        for record in locking where DocumentRegistry.shared.document(for: record.id) != nil { lock.keepOpen(record.id) }
        setLocked(true, for: locking)
        AccessibilityNotification.Announcement(String(localized: "\(locking.count) notebooks locked")).post()
        return nil
    }
}

