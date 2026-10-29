import SwiftUI

/// The column iOS 27.1 keeps down one side of a folded iPhone Duo for the status bar and bar buttons.
/// Where there is one, the library and the editor put their own controls in it as a rail.
struct VerticalBar: Equatable {
    var edge: HorizontalEdge
    /// The column's width: the window's safe area on that side.
    var width: CGFloat
    /// What the rail keeps clear of: the screen's edge beside it, the status bar above and the home indicator below.
    var margin: CGFloat
    var top: CGFloat
    var bottom: CGFloat

    /// The rail's own width, inside the column.
    var railWidth: CGFloat { width - margin }
}

extension EnvironmentValues {
    @Entry var verticalBar: VerticalBar?
}

extension View {
    /// Stands `rail` in the vertical bar's column, clear of the status bar, over this view.
    func verticalRail<Rail: View>(_ bar: VerticalBar?, @ViewBuilder rail: () -> Rail) -> some View {
        overlay {
            if let bar {
                rail()
                    .frame(width: bar.railWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, bar.top)
                    .padding(.bottom, bar.bottom)
                    .padding(bar.edge == .leading ? .leading : .trailing, bar.margin)
                    .frame(maxWidth: .infinity, alignment: bar.edge == .leading ? .leading : .trailing)
                    .ignoresSafeArea()
            }
        }
    }
}

/// Reads the window's vertical bar for whatever it sits behind.
struct VerticalBarReader: UIViewRepresentable {
    let onChange: (VerticalBar?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) { view.onChange = onChange }

    final class ReaderView: UIView {
        var onChange: ((VerticalBar?) -> Void)?
        private var last: VerticalBar??

        override func didMoveToWindow() {
            super.didMoveToWindow()
            read()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            read()
        }

        private func read() {
            let bar = current()
            guard last != .some(bar) else { return }
            last = .some(bar)
            let onChange = onChange
            Task { @MainActor in onChange?(bar) }
        }

        private func current() -> VerticalBar? {
            guard #available(iOS 27.1, *), let window else { return nil }
            let edge: HorizontalEdge
            switch window.traitCollection.verticalBarEdge {
            case .leading: edge = .leading
            case .trailing: edge = .trailing
            default: return nil
            }
            let onRight = (edge == .trailing) != (window.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            let width = onRight ? window.safeAreaInsets.right : window.safeAreaInsets.left
            guard width > 0 else { return nil }
            // The system's own region for a bar as wide as the column: its insets keep clear of the camera and the corners.
            let region = window.edgeInsets(for: .bar(onEdge: onRight ? .right : .left, extent: width))
            let margin = onRight ? region.right : region.left
            guard width - margin >= ToolTray.button else { return nil }
            return VerticalBar(edge: edge, width: width, margin: margin, top: region.top, bottom: region.bottom)
        }
    }
}
