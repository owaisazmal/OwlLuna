import SwiftUI

/// A card open on the page for ink: on what the lasso caught, or where bare paper was tapped to paste.
struct InkMenu: Equatable {
    /// What it opens beside, in the page view's points.
    var rect: CGRect
    /// Where in the page stack to paste. Nil on caught ink, which the card cuts, copies, duplicates or deletes.
    var pastePoint: CGPoint?
}

/// Lies clear over the pages and hangs the ink's card where the page stack says the ink or the tap is.
struct InkCard: View {
    let session: EditorSession
    /// Kept while the card closes, so its rows stay as they were until it has gone.
    @State private var last: InkMenu?

    var body: some View {
        Color.clear
            .cardMenu(Text("Ink"), isPresented: Binding(get: { session.inkMenu != nil }, set: { if !$0 { session.inkMenu = nil } }),
                      under: (session.inkMenu ?? last)?.rect ?? .zero) { rows }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: session.inkMenu) { _, menu in if let menu { last = menu } }
    }

    @ViewBuilder
    private var rows: some View {
        if let point = (session.inkMenu ?? last)?.pastePoint {
            Button { session.canvas?.pasteInk(at: point) } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .accessibilityIdentifier("editor.ink.paste")
        } else {
            Button { session.canvas?.cutInkSelection() } label: { Label("Cut", systemImage: "scissors") }
                .accessibilityIdentifier("editor.ink.cut")
            Button { session.canvas?.copyInkSelection() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .accessibilityIdentifier("editor.ink.copy")
            Button { session.canvas?.duplicateInkSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .accessibilityIdentifier("editor.ink.duplicate")
            Button(role: .destructive) { session.canvas?.deleteInkSelection() } label: { Label("Delete", systemImage: "trash") }
                .accessibilityIdentifier("editor.ink.delete")
        }
    }
}
