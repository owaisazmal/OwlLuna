import Foundation

/// Undo registrations whose target is not the document are dropped, so PencilKit's own per-canvas undo
/// never lands on the shared stack and nothing on the stack points at a canvas that may be recycled.
final class DocumentUndoManager: UndoManager {
    private(set) var droppedRegistrations = 0
    /// Goes up with every step taken on, an undo's and a redo's too, so a run of changes can tell nothing has come since its own.
    private(set) var registrations = 0

    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        guard target is NotebookDocument else { droppedRegistrations += 1; return }
        registrations += 1
        super.registerUndo(withTarget: target, selector: selector, object: anObject)
    }

    override func __registerUndoWithTarget(_ target: Any, handler undoHandler: @escaping @MainActor (Any) -> Void) {
        guard target is NotebookDocument else { droppedRegistrations += 1; return }
        registrations += 1
        super.__registerUndoWithTarget(target, handler: undoHandler)
    }

    override func prepare(withInvocationTarget target: Any) -> Any {
        guard target is NotebookDocument else {
            droppedRegistrations += 1
            discarded.removeAllActions()
            if discarded.groupingLevel == 0 { discarded.beginUndoGrouping() }
            return discarded.prepare(withInvocationTarget: target)
        }
        registrations += 1
        return super.prepare(withInvocationTarget: target)
    }

    private lazy var discarded: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 1
        return manager
    }()
}

/// Undo steps hold whole-page drawings, so the heavier the pages being edited, the fewer steps are kept.
enum UndoBudget {
    static let bytes = 48 << 20
    static let levels = 20...200

    static func levels(forPageBytes pageBytes: Int) -> Int {
        min(max(bytes / max(pageBytes, 1), levels.lowerBound), levels.upperBound)
    }
}
