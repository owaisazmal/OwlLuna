import SwiftUI

/// What a control stands on: a plate in a bar, a board where it has to stand clear of what is under it.
private struct Ground: ViewModifier {
    enum Kind { case none, plate, board }

    let kind: Kind
    let shape: RoundedRectangle
    let pressed: Bool
    let flat: Bool

    func body(content: Content) -> some View {
        switch kind {
        case .none: content
        case .plate: content.plate(in: shape, pressed: pressed, flat: flat)
        case .board: content.board(in: shape, pressed: pressed, flat: flat)
        }
    }
}

struct OwlLunaButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, destructive }

    var role: Role = .secondary
    var compact = false
    var inBar = false

    func makeBody(configuration: Configuration) -> some View {
        OwlLunaButton(configuration: configuration, role: role, compact: compact, inBar: inBar)
    }

    private struct OwlLunaButton: View {
        let configuration: Configuration
        let role: Role
        let compact: Bool
        let inBar: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        private let shape = RoundedRectangle.plate
        private var height: CGFloat { compact ? 34 : (inBar ? BarMetrics.height : 44) }

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            let cloth = role != .secondary
            let wraps = !inBar && dynamicTypeSize.isAccessibilitySize
            configuration.label
                .font(.system(compact ? .subheadline : (inBar ? .callout : .body), weight: cloth ? .semibold : .medium))
                .lineLimit(wraps ? 3 : 1)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: inBar, vertical: true)
                .foregroundStyle(foreground)
                .padding(.horizontal, compact || inBar ? Space.x3 : Space.x4)
                .padding(.vertical, wraps ? Space.x2 : 0)
                .frame(minWidth: 44, minHeight: height)
                .fixedSize(horizontal: inBar, vertical: false)
                .background { if cloth { filled(pressed: pressed) } }
                .modifier(Ground(kind: cloth ? .none : (inBar ? .plate : .board), shape: shape, pressed: pressed, flat: !isEnabled))
                .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
                .contentShape([.hoverEffect, .accessibility], shape)
                .hoverEffect(.highlight)
                .padding(.vertical, (44 - height) / 2)
                .contentShape(Rectangle())
                .animation(Motion.quick, value: pressed)
                .modifier(BarLimit(active: inBar))
        }

        private var foreground: Color {
            guard isEnabled else { return .textSecondary }
            switch role {
            case .primary: return .onPrimaryCloth
            case .secondary: return .ink
            case .destructive: return .onDestructiveCloth
            }
        }

        @ViewBuilder
        private func filled(pressed: Bool) -> some View {
            if !isEnabled {
                shape.fill(Color.well)
            } else {
                ClothFill(role: role, pressed: pressed, shape: shape)
            }
        }
    }
}

/// The woven cloth under a filled button, with its shadow and bevel: cobalt, or tomato for a destructive one.
struct ClothFill: View {
    var role: OwlLunaButtonStyle.Role = .primary
    var pressed = false
    var shape = RoundedRectangle.plate
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = scheme == .dark
        shape
            .fill(role == .destructive ? Color.destructiveCloth : Color.primaryCloth)
            .shadow(color: Elevation.shade(dark).opacity(pressed ? 0 : (dark ? 0.22 : 0.10)), radius: 4, y: 2)
            .shadow(color: Elevation.shade(dark).opacity(dark ? 0.40 : 0.12), radius: 0.5, y: 0.5)
            .clothWeave(in: shape)
            .overlay { if pressed { shape.fill(.black.opacity(dark ? 0.12 : 0.16)) } }
            .overlay { if contrast != .increased { shape.strokeBorder(ClothWeave.bevel, lineWidth: 1) } }
    }
}

extension ButtonStyle where Self == OwlLunaButtonStyle {
    /// A board button: Ink on Board. In a bar it is a plate.
    static var owlLuna: OwlLunaButtonStyle { OwlLunaButtonStyle() }

    static func owlLuna(_ role: OwlLunaButtonStyle.Role, compact: Bool = false, inBar: Bool = false) -> OwlLunaButtonStyle {
        OwlLunaButtonStyle(role: role, compact: compact, inBar: inBar)
    }
}

private extension View {
    /// An icon button's glyph: the icon alone, medium and large.
    func iconGlyph() -> some View {
        labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .imageScale(.large)
    }

    /// An icon button's hover plate, its cap on text size, and its whole label for the Large Content Viewer.
    func iconFinish(showing label: ButtonStyleConfiguration.Label) -> some View {
        contentShape(.hoverEffect, RoundedRectangle.plate.inset(by: BarMetrics.inset))
            .hoverEffect(.highlight)
            .dynamicTypeSize(...barTextLimit)
            .accessibilityShowsLargeContentViewer { label.labelStyle(.titleAndIcon) }
    }
}

/// An icon or a short word inside a bar: at least 44 points, ink, pressed into a small well.
struct BarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BarIcon(configuration: configuration)
    }

    private struct BarIcon: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityShowBorders) private var showBorders

        var body: some View {
            configuration.label
                .iconGlyph()
                .lineLimit(1)
                .foregroundStyle(configuration.role == .destructive ? Color.tomato : Color.ink)
                .opacity(isEnabled ? 1 : 0.35)
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 44)
                .background {
                    if (configuration.isPressed && isEnabled) || showBorders {
                        RoundedRectangle.thumb.fill(Color.well)
                            .padding(.horizontal, 3)
                            .padding(.vertical, BarMetrics.inset + 3)
                    }
                }
                .contentShape(Rectangle())
                .iconFinish(showing: configuration.label)
        }
    }
}

extension ButtonStyle where Self == BarIconButtonStyle {
    static var barIcon: BarIconButtonStyle { BarIconButtonStyle() }
}

/// A run of icons on one plate with a rule between each, the way toolbar groups are drawn.
struct BarGroup<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 0) {
            Group(subviews: content) { cells in
                ForEach(cells) { cell in
                    if cell.id != cells.first?.id {
                        Rectangle().fill(plateEdge(contrast)).frame(width: 1).padding(.vertical, BarMetrics.inset)
                    }
                    cell
                }
            }
        }
        .buttonStyle(.barIcon)
        .background { Color.clear.plate(in: RoundedRectangle.plate).padding(.vertical, BarMetrics.inset) }
        .fixedSize()
        .dynamicTypeSize(...barTextLimit)
    }
}

/// A single icon on a plate of its own: the way back, settings, the sidebar. Lifted, it stands on a board over a page.
struct PlateIconButtonStyle: ButtonStyle {
    var lifted = false

    func makeBody(configuration: Configuration) -> some View {
        PlateIcon(configuration: configuration, lifted: lifted)
    }

    private struct PlateIcon: View {
        let configuration: Configuration
        let lifted: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .iconGlyph()
                .foregroundStyle(Color.ink)
                .opacity(isEnabled ? 1 : 0.35)
                .frame(width: BarMetrics.height, height: BarMetrics.height)
                .modifier(Ground(kind: lifted ? .board : .plate, shape: .plate, pressed: configuration.isPressed && isEnabled, flat: !isEnabled))
                .padding(BarMetrics.inset)
                .contentShape([.interaction, .accessibility], Rectangle())
                .iconFinish(showing: configuration.label)
        }
    }
}

extension ButtonStyle where Self == PlateIconButtonStyle {
    static var plateIcon: PlateIconButtonStyle { PlateIconButtonStyle() }

    static func plateIcon(lifted: Bool) -> PlateIconButtonStyle { PlateIconButtonStyle(lifted: lifted) }
}

extension ToolbarContent {
    /// Takes away the system's glass so the item can wear its own plate.
    @ToolbarContentBuilder
    func boardBackground() -> some ToolbarContent {
        if #available(iOS 26, *) { sharedBackgroundVisibility(.hidden) } else { self }
    }
}

/// A sheet's Cancel, on its own plate in the bar.
struct CancelToolbarItem: ToolbarContent {
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: action).buttonStyle(.owlLuna(.secondary, inBar: true))
        }
        .boardBackground()
    }
}

extension View {
    /// Keeps a bar the colour of its ground when content scrolls under it, in place of the system's material band.
    @ViewBuilder
    func barGround(_ ground: Color) -> some View {
        if #available(iOS 26, *) {
            toolbarBackground(ground, for: .navigationBar, .bottomBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar, .bottomBar)
                .scrollEdgeEffectHidden(true, for: .top)
                .scrollEdgeEffectStyle(.hard, for: .bottom)
        } else {
            toolbarBackground(ground, for: .navigationBar, .bottomBar)
        }
    }
}
