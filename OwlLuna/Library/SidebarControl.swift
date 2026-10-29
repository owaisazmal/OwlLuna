import SwiftUI

/// Shows and hides the sidebar the way the system's button does: over the shelves in portrait, beside them in landscape.
@MainActor
final class SidebarControl {
    weak var anchor: UIView?

    func toggle() {
        var responder: UIResponder? = anchor
        while let current = responder, !(current is UISplitViewController) { responder = current.next }
        guard let split = responder as? UISplitViewController, !split.isCollapsed else { return }
        if split.displayMode == .secondaryOnly { split.show(.primary) } else { split.hide(.primary) }
    }
}

struct SidebarAnchor: UIViewRepresentable {
    let control: SidebarControl

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        control.anchor = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { control.anchor = view }
}

/// On iPadOS 26 and later the system's sidebar button is a glass bubble; this puts a plate in its place.
struct BoardSidebarToggle: ViewModifier {
    let shows: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    if shows {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: action) { Label("Show Sidebar", systemImage: "sidebar.leading") }
                                .buttonStyle(.plateIcon)
                                .accessibilityIdentifier("ToggleSidebar")
                        }
                        .boardBackground()
                    }
                }
        } else {
            content
        }
    }
}

/// On an iPhone the folded-up sidebar's back button is the system's glass bubble; this puts a plate in its place.
/// It goes back by clearing the chosen place, so the same place can be chosen again.
struct PlateBack: ViewModifier {
    let shows: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if shows {
            content
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: action) { Label("Shelves", systemImage: "chevron.backward") }
                            .buttonStyle(.plateIcon)
                            .accessibilityIdentifier("library.back")
                    }
                    .boardBackground()
                }
        } else {
            content
        }
    }
}
