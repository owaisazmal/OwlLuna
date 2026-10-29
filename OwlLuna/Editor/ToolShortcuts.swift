import SwiftUI

/// ⌘1, ⌘2 and ⌘3 take up the pen last in hand, the eraser and the lasso. The editor keeps them hidden behind the
/// page; holding ⌘ lists them by name.
struct ToolShortcuts: View {
    let session: EditorSession
    /// This pane has the keyboard and nothing covers it.
    let isActive: Bool

    var body: some View {
        if isActive, session.mode == .writing || session.mode == .focus, !session.document.isReadOnly, !session.isEditingText {
            Button("Pen") { Toolbox.shared.takePen() }.keyboardShortcut("1", modifiers: .command)
            Button("Eraser") { Toolbox.shared.take(.eraser) }.keyboardShortcut("2", modifiers: .command)
            Button("Lasso") { Toolbox.shared.take(.lasso) }.keyboardShortcut("3", modifiers: .command)
        }
    }
}
