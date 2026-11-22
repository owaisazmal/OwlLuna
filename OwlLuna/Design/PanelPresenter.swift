import SwiftUI

/// Closes the panel a control stands in, then does what was asked for once it has gone.
struct PanelClose {
    fileprivate let close: (_ then: (() -> Void)?) -> Void

    func callAsFunction(then action: (() -> Void)? = nil) { close(action) }
}

extension EnvironmentValues {
    /// Set inside a panel, so what it holds can close it.
    @Entry var panelClose: PanelClose?
    /// The least height a card's control is taken to have. A title in a bar is short; with this its card hangs as low as the bar's others.
    @Entry var panelAnchorHeight: CGFloat = 0
    /// Set down a rail at the screen's side, where a card opens beside its control rather than under it.
    @Entry var panelsOpenBeside = false
}

// MARK: Opening

/// The view behind a control that says where it stands. It holds what to do when it has moved, so that goes when the control does.
final class PanelMarker: UIView {
    var moved: (() -> Void)?
}

/// Where a control stands in its window. A bar making its buttons again has two markers for a moment, so the one on show is asked.
@MainActor
final class PanelSpot {
    private struct Kept { weak var marker: PanelMarker? }
    private var markers: [Kept] = []
    private var observer: CFRunLoopObserver?
    private var seen: CGRect?

    func keep(_ marker: PanelMarker) {
        markers.removeAll { $0.marker == nil }
        if !markers.contains(where: { $0.marker === marker }) { markers.append(Kept(marker: marker)) }
    }

    var isInWindow: Bool { markers.contains { $0.marker?.window != nil } }

    /// The control's frame in its window, from the newest marker that is in one and laid out; nil while none is.
    var frame: CGRect? {
        let marker = markers.last { $0.marker?.window != nil && $0.marker?.bounds.isEmpty == false }?.marker
        return marker.map { $0.convert($0.bounds, to: nil) }
    }

    /// While `on`, tells the newest marker when the frame has changed by the time the main thread rests, which is after layout.
    func watch(_ on: Bool) {
        guard on != (observer != nil) else { return }
        if let observer {
            CFRunLoopObserverInvalidate(observer)
            self.observer = nil
            return
        }
        seen = frame
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, .max) { [weak self] observer, _ in
            MainActor.assumeIsolated {
                if let self { self.look() } else { CFRunLoopObserverInvalidate(observer) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func look() {
        let now = frame
        guard now != seen else { return }
        seen = now
        // The run loop is about to rest, so what this sets off starts a turn of its own.
        Task { markers.last { $0.marker != nil }?.marker?.moved?() }
    }

    /// What a card hangs from: `within` its control when given, taken as at least `least` tall. Nil while the control is not on show.
    static func anchor(for frame: CGRect?, within: CGRect?, least: CGFloat) -> CGRect? {
        guard let frame else { return nil }
        let place = within.map { $0.offsetBy(dx: frame.minX, dy: frame.minY) } ?? frame
        return place.insetBy(dx: 0, dy: min(0, (place.height - least) / 2))
    }
}

private struct PanelProbe: UIViewRepresentable {
    let spot: PanelSpot
    let moved: () -> Void

    func makeUIView(context: Context) -> PanelMarker {
        let marker = PanelMarker()
        marker.isUserInteractionEnabled = false
        spot.keep(marker)
        return marker
    }

    func updateUIView(_ marker: PanelMarker, context: Context) {
        marker.moved = moved
        spot.keep(marker)
    }
}

/// What a card is asked for: whether it is wanted, and what of its control it hangs from.
private struct PanelAsk: Equatable {
    let shown: Bool
    let within: CGRect?
    let least: CGFloat
}

/// Covers the window with a clear layer and stands the panel on it, with no animation of the system's.
struct PanelPresenter<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    var beside = false
    /// A menu opened from a row of another closes that one with it.
    var chained = false
    /// A notice stands in the middle of the screen. Its button's work is done before its binding is put back, as an alert's is.
    var notice = false
    /// The part of the view the panel hangs from, in the view's own points; all of it when nil.
    var within: CGRect?
    @ViewBuilder var panel: () -> Panel
    @State private var spot = PanelSpot()
    @State private var covering = false
    @State private var anchor = CGRect.zero
    @State private var pending: (() -> Void)?
    @Environment(\.panelClose) private var outer
    @Environment(\.panelAnchorHeight) private var least
    @Environment(\.panelsOpenBeside) private var opensBeside

    func body(content: Content) -> some View {
        content.background {
            PanelProbe(spot: spot, moved: settle)
                .fullScreenCover(isPresented: Binding(get: { covering }, set: { if !$0 { covering = false; if !notice { isPresented = false } } }),
                                 onDismiss: finish) {
                    stage
                        .environment(\.panelClose, PanelClose(close: close))
                        .appModels()
                        .presentationBackground(.clear)
                }
                .transaction { $0.disablesAnimations = true }
                .onChange(of: PanelAsk(shown: isPresented, within: within, least: least), initial: true) { settle() }
        }
    }

    /// Opens the card under its control, keeps it there as the control moves, and closes it. With no control on show it waits.
    private func settle() {
        if notice {
            if isPresented, !spot.isInWindow { Task { cover(isPresented) } } else { cover(isPresented) }
            return
        }
        spot.watch(isPresented)
        guard isPresented else { return cover(false) }
        guard let place = PanelSpot.anchor(for: spot.frame, within: within, least: least) else { return }
        if place != anchor { anchor = place }
        cover(true)
    }

    private func cover(_ shown: Bool) {
        guard shown != covering else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { covering = shown }
    }

    @ViewBuilder
    private var stage: some View {
        if notice { NoticeStage(panel: panel) } else { PanelStage(anchor: anchor, beside: beside || opensBeside, close: close, panel: panel) }
    }

    private func close(then action: (() -> Void)?) {
        pending = action
        if notice { cover(false) } else { isPresented = false }
    }

    private func finish() {
        let action = pending
        pending = nil
        if chained, let outer { outer(then: action) } else { action?() }
        if notice { isPresented = false }
    }
}

private struct PanelStage<Panel: View>: View {
    let anchor: CGRect
    let beside: Bool
    let close: (_ then: (() -> Void)?) -> Void
    @ViewBuilder var panel: () -> Panel
    @State private var shown = false
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        GeometryReader { proxy in
            PanelPlacement(anchor: place(in: proxy), beside: beside) {
                panel().opacity(shown ? 1 : 0)
            }
        }
        .background {
            Button { close(nil) } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in close(nil) })
                .accessibilityLabel(Text("Close"))
                .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { close(nil) }
        .onAppear { withAnimation(Motion.quick) { shown = true } }
    }

    /// The control's place on the stage. Right to left the stage is laid out mirrored, so its place is mirrored too.
    private func place(in proxy: GeometryProxy) -> CGRect {
        let stage = proxy.frame(in: .global)
        var place = anchor.offsetBy(dx: -stage.minX, dy: -stage.minY)
        if direction == .rightToLeft { place.origin.x = stage.width - place.maxX }
        return place
    }
}

/// Dims what is behind a notice and holds the notice in the middle of what the keyboard leaves.
private struct NoticeStage<Panel: View>: View {
    @ViewBuilder var panel: () -> Panel
    @State private var shown = false

    var body: some View {
        panel()
            .padding(Space.x4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(shown ? 1 : 0)
            .background { Color.black.opacity(shown ? 0.35 : 0).ignoresSafeArea() }
            .accessibilityElement(children: .contain)
            .onAppear { withAnimation(Motion.quick) { shown = true } }
    }
}

/// Puts a panel under the control it opened from, or over it, and keeps all of it on the screen.
private struct PanelPlacement: Layout {
    let anchor: CGRect
    let beside: Bool

    private static let margin: CGFloat = 8
    private static let gap: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let panel = subviews.first else { return }
        let margin = Self.margin, gap = Self.gap
        let width = min(panel.sizeThatFits(.unspecified).width, bounds.width - margin * 2)
        var height = min(panel.sizeThatFits(ProposedViewSize(width: width, height: nil)).height, bounds.height - margin * 2)
        var x = anchor.minX, y = anchor.maxY + gap
        if beside {
            x = anchor.maxX - Space.x2
            if x + width > bounds.width - margin { x = anchor.minX + Space.x2 - width }
            y = anchor.minY
        } else {
            if x + width > bounds.width - margin { x = anchor.maxX - width }
            let below = bounds.height - margin - y, above = anchor.minY - gap - margin
            if height > below {
                if height <= above || above > below, above >= 200 {
                    height = min(height, above)
                    y = anchor.minY - gap - height
                } else if below >= 200 {
                    height = below
                }
            }
        }
        x = min(max(x, margin), bounds.width - margin - width)
        y = min(max(y, margin), bounds.height - margin - height)
        panel.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(width: width, height: height))
    }
}

extension UIView {
    /// The root view of the screen this view is on: that of the nearest view controller up its responder chain.
    var hostScreen: UIView? {
        var responder = next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        return (responder as? UIViewController)?.viewIfLoaded
    }
}

// MARK: The card

/// What menus and popovers are cut from: a board ruled in ink, under a cloth band that names it.
struct PanelChrome<Title: View, Content: View>: View {
    var fill = Color.surface
    /// A large panel has a way out on its band as well as round it.
    var done: (() -> Void)?
    @ViewBuilder var title: Title
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.x3) {
                title
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                if let done {
                    Button("Done", action: done)
                        .buttonStyle(.plain)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .padding(.vertical, -Space.x3)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("panel.done")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.onPrimaryCloth)
            .padding(.horizontal, Space.x3)
            .padding(.vertical, 7)
            .background { Rectangle().fill(Color.primaryCloth).clothWeave(in: Rectangle()) }
            content
        }
        .clipShape(RoundedRectangle.plate)
        .plate(in: RoundedRectangle.plate, fill: fill)
        .contentShape(Rectangle())
    }
}

extension View {
    /// Opens a card under this view while `isPresented` is true. One that `adapts` has Done on its band, and is a sheet
    /// where there is no room beside things.
    func panel<Content: View>(_ title: LocalizedStringKey, isPresented: Binding<Bool>, adapts: Bool = false,
                              @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(AdaptingPanel(title: Text(title), isPresented: isPresented, adapts: adapts, content: content))
    }

    func panel<Item: Identifiable, Content: View>(_ title: LocalizedStringKey, item: Binding<Item?>, adapts: Bool = false,
                                                  @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        panel(title, isPresented: Binding(isPresent: item), adapts: adapts) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}

private struct AdaptingPanel<Panel: View>: ViewModifier {
    let title: Text
    @Binding var isPresented: Bool
    let adapts: Bool
    @ViewBuilder var content: () -> Panel
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content anchor: Content) -> some View {
        if adapts, sizeClass == .compact {
            anchor.sheet(isPresented: $isPresented) {
                content().presentationBackground(Color.surface).presentationCornerRadius(Radius.sheet).appModels()
            }
        } else {
            anchor.modifier(PanelPresenter(isPresented: $isPresented) {
                PanelChrome(done: adapts ? { isPresented = false } : nil) { title } content: { content() }
            })
        }
    }
}
