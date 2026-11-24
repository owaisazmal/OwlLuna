import SwiftUI

/// Segments on a well, the chosen one a board that slides under it. Each is a button VoiceOver reads as a selected tab.
struct OwlLunaSegmentedPicker<Value: Hashable, Label: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [Value]
    var inBar: Bool
    var identifier: ((Value) -> String)?
    var padding: CGFloat
    @ViewBuilder var label: (Value) -> Label
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: LocalizedStringKey, selection: Binding<Value>, options: [Value], inBar: Bool = false,
         identifier: ((Value) -> String)? = nil, padding: CGFloat = Space.x4, @ViewBuilder label: @escaping (Value) -> Label) {
        self.title = title
        self._selection = selection
        self.options = options
        self.inBar = inBar
        self.identifier = identifier
        self.padding = padding
        self.label = label
    }

    var body: some View {
        let wraps = !inBar && dynamicTypeSize.isAccessibilitySize
        let layout = wraps ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(EqualWidthHStack())
        layout {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    label(option)
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.ink : Color.textSecondary)
                        .lineLimit(wraps ? 3 : (inBar ? 1 : 2))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, padding)
                        .padding(.vertical, wraps ? Space.x3 : (inBar ? 0 : Space.x1))
                        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .contentShape(.hoverEffect, RoundedRectangle.thumb.inset(by: inBar ? BarMetrics.inset + 3 : 4))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .matchedGeometryEffect(id: option, in: thumb)
                .modifier(BarLimit(active: inBar))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(identifier?(option) ?? "", isEnabled: identifier != nil)
            }
        }
        .background { if options.contains(selection) { thumbView.matchedGeometryEffect(id: selection, in: thumb, isSource: false) } }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: selection)
        .background { Color.clear.well(in: RoundedRectangle.track).padding(.vertical, inBar ? BarMetrics.inset : 0) }
        .fixedSize(horizontal: inBar, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .accessibilityLabel(Text(title))
    }

    private var thumbView: some View {
        let shape = RoundedRectangle.thumb
        return Color.clear
            .board(in: shape)
            .overlay { if scheme == .dark { shape.fill(Color.ink.opacity(0.10)) } }
            .overlay { if contrast == .increased { shape.strokeBorder(Color.inkSecondary, lineWidth: 1) } }
            .padding(.horizontal, inBar ? 3 : 4)
            .padding(.vertical, inBar ? BarMetrics.inset + 3 : 4)
    }
}

/// Lays its children out in equal widths: the widest one's when it may choose, an even share of what it's offered otherwise.
private struct EqualWidthHStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let unit = unitWidth(proposal, subviews)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: unit, height: proposal.height)).height }.max() ?? 0
        return CGSize(width: unit * CGFloat(subviews.count), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let unit = bounds.width / CGFloat(max(subviews.count, 1))
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + unit * CGFloat(index), y: bounds.minY),
                          proposal: ProposedViewSize(width: unit, height: bounds.height))
        }
    }

    private func unitWidth(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        if let width = proposal.width, width.isFinite { return width / CGFloat(subviews.count) }
        return subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }
}
