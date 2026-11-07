import Foundation
import UniformTypeIdentifiers

/// PDFs that arrive from outside the app: shared from Files or another app, dropped on the shelf, or dropped on the
/// app's icon. Each is a copy the system or the drop made for the app, so it is thrown away once the import has ended.
enum IncomingPDFs {
    /// Whether a URL the app was opened with is a PDF to import, rather than a link to follow.
    static func isPDF(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .pdf) { return true }
        return (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true
    }

    /// Where the system copies a file it opens the app with: Documents/Inbox, or on recent iOS a folder in tmp named
    /// after the app. The copy is the app's to remove.
    static let inboxes = [URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory),
                          URL.temporaryDirectory.appending(path: "\(Bundle.main.bundleIdentifier ?? "OwlLuna")-Inbox", directoryHint: .isDirectory)]

    /// Where dropped files are kept until they are in.
    static let holding = URL.temporaryDirectory.appending(path: "Incoming", directoryHint: .isDirectory)

    /// Whether `url` is a copy made for the app, in an inbox or in `holding`.
    static func isCopy(_ url: URL, inboxes: [URL] = inboxes, holding: URL = holding) -> Bool {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return (inboxes + [holding]).contains { path.hasPrefix($0.standardizedFileURL.path(percentEncoded: false)) }
    }

    /// Removes the copy once it is in or has been missed, with the folder it was dropped in; a file anywhere else is left alone.
    static func discard(_ url: URL, inboxes: [URL] = inboxes, holding: URL = holding) {
        guard isCopy(url, inboxes: inboxes, holding: holding) else { return }
        try? FileManager.default.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL.path(percentEncoded: false).hasPrefix(holding.standardizedFileURL.path(percentEncoded: false)),
           parent.standardizedFileURL != holding.standardizedFileURL,
           (try? FileManager.default.contentsOfDirectory(atPath: parent.path(percentEncoded: false)))?.isEmpty == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    /// Copies each dropped PDF into `holding` under its own name, so the import can read it after the drop is over.
    /// Anything that isn't a PDF, or can't be read, is left out.
    @MainActor
    static func receive(_ providers: [NSItemProvider], holding: URL = holding) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            if let url = await copy(provider, into: holding) { urls.append(url) }
        }
        return urls
    }

    @MainActor
    private static func copy(_ provider: NSItemProvider, into holding: URL) async -> URL? {
        let name = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { source, _ in
                guard let source else { return continuation.resume(returning: nil) }
                let file = name.flatMap { $0.isEmpty ? nil : $0 } ?? source.deletingPathExtension().lastPathComponent
                let folder = holding.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                let destination = folder.appending(path: (file as NSString).pathExtension.lowercased() == "pdf" ? file : "\(file).pdf")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
