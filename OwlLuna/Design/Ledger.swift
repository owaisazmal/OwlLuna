import SwiftUI

private struct LedgerFlushKey: ContainerValueKey {
    static let defaultValue = false
}

extension ContainerValues {
    fileprivate var isLedgerFlush: Bool {
        get { self[LedgerFlushKey.self] }
        set { self[LedgerFlushKey.self] = newValue }
    }
}

private enum LedgerMetrics {
    static let inset = EdgeInsets(top: Space.x2, leading: Space.x3, bottom: Space.x2, trailing: Space.x3)
    static let outset = EdgeInsets(top: -Space.x2, leading: -Space.x3, bottom: -Space.x2, trailing: -Space.x3)
}

/// A list in the app's own hand: each run of rows is one board ruled apart in ink, under a band if the run has a name.
struct Ledger<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x5) {
                Group(sections: content) { sections in
                    ForEach(sections) { section in
                        let rows = Array(section.content)
                        if !rows.isEmpty || !section.header.isEmpty {
                            VStack(alignment: .leading, spacing: Space.x2) {
                                board(rows, under: section.header)
                                if !section.footer.isEmpty {
                                    section.footer
                                        .font(.footnote)
                                        .foregroundStyle(Color.textSecondary)
                                        .padding(.horizontal, Space.x3)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Space.x4)
        }
        .buttonStyle(LedgerRowButtonStyle())
    }

    private func board(_ rows: [Subview], under header: SubviewsCollection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !header.isEmpty {
                header
                    .sectionBand()
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let flush = row.containerValues.isLedgerFlush
                row
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(flush ? EdgeInsets() : LedgerMetrics.inset)
                    .frame(minHeight: 44)
                    .overlay(alignment: .top) { if index > 0 || !header.isEmpty { HairlineRule() } }
            }
        }
        .clipShape(RoundedRectangle.plate)
        .plate(in: RoundedRectangle.plate, fill: .board)
    }
}

/// A Hairline ruled between rows, in a ledger or a menu.
struct HairlineRule: View {
    var body: some View {
        Rectangle().fill(Color.hairline).frame(height: 1).allowsHitTesting(false)
    }
}

extension View {
    /// A ledger row that reaches the board's edges and insets itself: one with more than one thing in it to touch.
    func ledgerFlush() -> some View { containerValue(\.isLedgerFlush, true) }

    /// The band over a named run of rows in a ledger or a menu: small semibold words on a well.
    func sectionBand() -> some View {
        font(.caption.weight(.semibold))
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Space.x3)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.well)
    }
}

/// A row that is a button is touched across its whole width, and darkens under the finger.
private struct LedgerRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LedgerMetrics.inset)
            .background { if configuration.isPressed { Color.well } }
            .contentShape(Rectangle())
            .padding(LedgerMetrics.outset)
    }
}

extension View {
    /// What a ledger's row uncovers when it is pulled aside: its buttons, the one that destroys in tomato. VoiceOver
    /// has them as the row's actions.
    func ledgerSwipe<Actions: View>(@ViewBuilder actions: @escaping () -> Actions) -> some View {
        modifier(LedgerSwipe(actions: actions))
    }
}

private struct LedgerSwipe<Actions: View>: ViewModifier {
    @ViewBuilder var actions: () -> Actions
    @State private var pulled: CGFloat = 0
    @State private var start: CGFloat?
    @State private var passes = false
    @State private var width: CGFloat = 0
    @Environment(\.layoutDirection) private var direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let turn: CGFloat = direction == .rightToLeft ? -1 : 1
        content
            // A pull is not a tap: the row's own button lets go as soon as it is pulled.
            .disabled(start != nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LedgerMetrics.inset)
            .frame(minHeight: 44)
            .background(Color.board)
            .overlay { if pulled > 0 { Color.clear.contentShape(Rectangle()).onTapGesture { settle(open: false) } } }
            .offset(x: -pulled * turn)
            .background(alignment: .trailing) {
                HStack(spacing: 0) { actions() }
                    .buttonStyle(LedgerActionStyle { settle(open: false) })
                    .labelStyle(.iconOnly)
                    .frame(maxHeight: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                    .accessibilityHidden(true)
            }
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 18).onChanged { pull($0, turn: turn) }.onEnded { _ in release() })
            .accessibilityActions { actions() }
            .containerValue(\.isLedgerFlush, true)
    }

    /// A pull that starts up or down is the list being scrolled, and is left to it.
    private func pull(_ drag: DragGesture.Value, turn: CGFloat) {
        guard width > 0, !passes else { return }
        if start == nil {
            guard abs(drag.translation.width) > abs(drag.translation.height) else { return passes = true }
            start = pulled
        }
        pulled = min(max((start ?? 0) - drag.translation.width * turn, 0), width)
    }

    private func release() {
        if start != nil { settle(open: pulled > width / 2) }
        start = nil
        passes = false
    }

    private func settle(open: Bool) {
        withAnimation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion)) { pulled = open ? width : 0 }
    }
}

/// A block of cloth as tall as its row: tomato for what destroys, cobalt for the rest.
private struct LedgerActionStyle: PrimitiveButtonStyle {
    let close: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        let destroys = configuration.role == .destructive
        Button {
            close()
            configuration.trigger()
        } label: {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(destroys ? Color.onDestructiveCloth : Color.onPrimaryCloth)
                .frame(minWidth: 56, maxHeight: .infinity)
                .background(destroys ? Color.destructiveCloth : Color.primaryCloth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
