import Foundation

/// The words for what sync asks, in the library's notice and in Settings.
enum SyncQuestion {
    static func title(_ question: SyncCenter.Question) -> String {
        switch question {
        case .firstSync: String(localized: "Keep a copy of your notebooks in iCloud?")
        case .accountChanged: String(localized: "A different Apple Account is signed in")
        }
    }

    static func message(_ question: SyncCenter.Question) -> String {
        switch question {
        case .firstSync:
            String(localized: "OwlLuna can copy every notebook, folder and sticker to your private iCloud storage, so your other devices have them. Nothing is copied until you choose to, and Settings › iCloud in OwlLuna can change it later.")
        case .accountChanged: accountChangedMessage
        }
    }

    static var accountChangedMessage: String {
        (Device.isMac
            ? String(localized: "This Mac's notebooks were last synced with another account's iCloud. Syncing with this account copies them to its iCloud storage and brings in the notebooks it holds.")
            : String(localized: "This iPad's notebooks were last synced with another account's iCloud. Syncing with this account copies them to its iCloud storage and brings in the notebooks it holds."))
    }

    static func allow(_ question: SyncCenter.Question) -> String {
        switch question {
        case .firstSync: String(localized: "Sync with iCloud")
        case .accountChanged: String(localized: "Sync with This Account")
        }
    }

    static func refuse(_ question: SyncCenter.Question) -> String {
        switch question {
        case .firstSync: String(localized: "Not Now")
        case .accountChanged: String(localized: "Turn Off Sync")
        }
    }
}

extension SyncReport {
    /// What the pass did and left, a phrase each, a notebook whose lock, folder or cards alone went counted too.
    var parts: [String] {
        var parts: [String] = []
        let sent = Set(pushed).union(stateSent).union(cardsSent).count, received = Set(pulled).union(stateReceived).union(cardsReceived).count
        let deletions = removedHere.count + removedThere.count
        if sent > 0 { parts.append(String(localized: "\(sent) notebooks sent")) }
        if received > 0 { parts.append(String(localized: "\(received) notebooks received")) }
        if deletions > 0 { parts.append(String(localized: "\(deletions) deletions carried over")) }
        if conflictCopies.count > 0 { parts.append(String(localized: "\(conflictCopies.count) conflicted copies kept")) }
        if open.count > 0 { parts.append(String(localized: "\(open.count) notebooks waiting until they're closed")) }
        if arriving.count > 0 { parts.append(String(localized: "\(arriving.count) notebooks still downloading from iCloud")) }
        if failed.count > 0 { parts.append(String(localized: "\(failed.count) notebooks didn't sync")) }
        if held.count > 0 { parts.append(String(localized: "\(held.count) deletions held back")) }
        if foldersUnreadable { parts.append(String(localized: "Folders aren't syncing")) }
        return parts
    }

    var summary: String { parts.isEmpty ? String(localized: "Everything is up to date") : parts.joined(separator: ", ") }
}

extension SyncFailure.Reason {
    var message: String {
        switch self {
        case .noRoom: (Device.isMac
            ? String(localized: "There isn't enough room on this Mac.")
            : String(localized: "There isn't enough room on this iPad."))
        case .unreadable(inICloud: true): String(localized: "Its copy in iCloud can't be read.")
        case .unreadable(inICloud: false): (Device.isMac
            ? String(localized: "Its copy on this Mac can't be read.")
            : String(localized: "Its copy on this iPad can't be read."))
        case .newerVersion: (Device.isMac
            ? String(localized: "It was saved by a newer version of OwlLuna. Update OwlLuna on this Mac to sync it.")
            : String(localized: "It was saved by a newer version of OwlLuna. Update OwlLuna on this iPad to sync it."))
        case .coordination(let detail): String(localized: "iCloud Drive didn't let OwlLuna reach its files: \(detail)")
        case .other(let detail): detail
        }
    }
}

/// What iCloud still has to upload from the synced copy, and what is stopping it.
struct CloudUploads: Sendable, Equatable {
    enum Problem: Sendable, Equatable {
        case full
        case unreachable
        case other(String)

        var message: String {
            switch self {
            case .full:
                (Device.isMac
                    ? String(localized: "Your iCloud storage is full, so changes made on this Mac can't be uploaded. Free up space, or choose a bigger plan in System Settings › your name › iCloud.")
                    : String(localized: "Your iCloud storage is full, so changes made on this iPad can't be uploaded. Free up space, or choose a bigger plan in Settings › your name › iCloud."))
            case .unreachable: (Device.isMac
                ? String(localized: "iCloud can't be reached right now. Changes made on this Mac will upload when it's back.")
                : String(localized: "iCloud can't be reached right now. Changes made on this iPad will upload when it's back."))
            case .other(let detail): String(localized: "iCloud couldn't upload some files: \(detail)")
            }
        }
    }

    /// Notebooks with a file iCloud hasn't uploaded yet.
    var pending: Set<UUID> = []
    /// Folders, stickers or deletions iCloud hasn't uploaded yet.
    var othersPending = false
    var problem: Problem?

    var isClear: Bool { pending.isEmpty && !othersPending && problem == nil }

    var parts: [String] {
        if !pending.isEmpty {
            return [problem == nil ? String(localized: "\(pending.count) notebooks still uploading to iCloud")
                                   : String(localized: "\(pending.count) notebooks not uploaded to iCloud")]
        }
        return othersPending ? [String(localized: "Still uploading to iCloud")] : []
    }

    /// Looks at every file in the synced copy. `values` stands in for iCloud's word on one file in tests.
    static func read(_ cloud: CloudFolder, values: (URL) -> (uploaded: Bool?, error: (any Error)?) = uploadValues) -> CloudUploads {
        var result = CloudUploads()
        let base = cloud.url.standardizedFileURL.path(percentEncoded: false)
        let keys: [URLResourceKey] = [.isRegularFileKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey]
        let enumerator = FileManager.default.enumerator(at: cloud.url, includingPropertiesForKeys: keys)
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            // A placeholder stands for a file that is in iCloud already; an upload under way is assembled before it counts.
            if name.hasSuffix(".icloud") || name.hasSuffix(".part") || name.hasSuffix(".\(CloudFolder.uploadExtension)") {
                enumerator?.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let (uploaded, error) = values(url)
            if let error { result.problem = worse(result.problem, Problem(error)) }
            guard uploaded == false || error != nil else { continue }
            let path = url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count).split(separator: "/")
            if path.count > 2, path[0] == "Library", path[1].hasSuffix(".\(StorageRoot.packageExtension)"),
               let id = UUID(uuidString: String(path[1].dropLast(StorageRoot.packageExtension.count + 1))) {
                result.pending.insert(id)
            } else {
                result.othersPending = true
            }
        }
        return result
    }

    static func uploadValues(_ url: URL) -> (uploaded: Bool?, error: (any Error)?) {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
        return (values?.ubiquitousItemIsUploaded, values?.ubiquitousItemUploadingError)
    }

    private static func worse(_ a: Problem?, _ b: Problem) -> Problem {
        switch (a, b) {
        case (.full?, _), (_, .full): .full
        case (.unreachable?, _), (_, .unreachable): .unreachable
        default: a ?? b
        }
    }
}

extension CloudUploads.Problem {
    init(_ error: any Error) {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, NSUbiquitousFileNotUploadedDueToQuotaError): self = .full
        case (NSCocoaErrorDomain, NSUbiquitousFileUbiquityServerNotAvailable): self = .unreachable
        default: self = .other(error.localizedDescription)
        }
    }
}

/// What the library shows about sync until it is put away.
struct SyncNews: Equatable {
    var failed: [SyncFailure] = []
    /// Notebooks gone from one side that sync didn't take as deleted, since too many went at once.
    var held: [UUID] = []
    /// Conflicted copies made since the notice was last put away.
    var conflictCopies: [UUID] = []
    /// This device's journals that gave way to one begun earlier on another device.
    var journals: [UUID] = []
    var uploadProblem: CloudUploads.Problem?
    /// Why the last pass stopped part-way.
    var stopped: String?
    /// The folder list in iCloud can't be read, so folders aren't syncing.
    var foldersUnreadable = false

    var isEmpty: Bool { !isTrouble && conflictCopies.isEmpty && journals.isEmpty }
    /// Something went wrong, as opposed to a conflicted copy, which is only worth knowing about.
    var isTrouble: Bool { !failed.isEmpty || !held.isEmpty || uploadProblem != nil || stopped != nil || foldersUnreadable }
    var count: Int {
        failed.count + (held.isEmpty ? 0 : 1) + conflictCopies.count + journals.count + (uploadProblem == nil ? 0 : 1) + (stopped == nil ? 0 : 1)
            + (foldersUnreadable ? 1 : 0)
    }

    func keeping(copies kept: (UUID) -> Bool) -> SyncNews {
        var news = self
        news.conflictCopies.removeAll { !kept($0) }
        news.journals.removeAll { !kept($0) }
        return news
    }
}
