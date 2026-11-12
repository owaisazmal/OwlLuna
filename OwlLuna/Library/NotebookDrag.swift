import UIKit
import UniformTypeIdentifiers

/// What a notebook carries when it is dragged: a reference that the sidebar's folders take, and a PDF for Files, Mail
/// or another app, written only when a drop asks for it. A locked notebook, or one in Recently Deleted, carries no PDF.
enum NotebookDrag {
    /// The notebook lifted last, so a shelf can turn down one of its own while it is dragged across it.
    @MainActor static var lifted: UUID?

    @MainActor
    static func provider(for record: NotebookRecord, root: StorageRoot) -> NSItemProvider {
        let provider = NSItemProvider(), id = record.id
        lifted = id
        provider.register(NotebookReference(id: id))
        guard offersPDF(record) else { return provider }
        provider.suggestedName = record.title.orUntitled
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { done in
            let progress = Progress(totalUnitCount: 100)
            let work = Task.detached(priority: .userInitiated) {
                do {
                    let input = try await NotebookExporter.input(for: id, root: root)
                    let url = try await NotebookExporter.export(input) { value in progress.completedUnitCount = Int64(value * 100) }
                    done(url, false, nil)
                } catch {
                    done(nil, false, error)
                }
            }
            progress.cancellationHandler = { work.cancel() }
            return progress
        }
        return provider
    }

    private static func offersPDF(_ record: NotebookRecord) -> Bool { !record.isLocked && !record.isTrashed }
}
