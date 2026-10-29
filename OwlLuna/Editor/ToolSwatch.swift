import SwiftUI
import PencilKit

/// One pen: its ink as a blot on a paper label, as large as the pen is wide, under the mark of its kind.
/// Like a cover's label, the paper stays cream at night, so the ink is seen as it is on a page.
struct ToolSwatch: View {
    let preset: ToolPreset
    var inUse = false
    /// On Chalkboard the label is the board's green, and the ink as light as it is written there.
    var onDark = false
    /// On paper that Dark Mode shows dark the ink is as light as it is there, on the well.
    var turned = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    static let side: CGFloat = 32
    static let shape = RoundedRectangle.plate
    private static let chalkboard = Color(red: PaperColor.chalkboard.rgb.0, green: PaperColor.chalkboard.rgb.1, blue: PaperColor.chalkboard.rgb.2)

    /// What a pen's ink is shown on: paper by day, a well as dark as the tray at night, Chalkboard's green on a Chalkboard page.
    static func paper(onDark: Bool, night: Bool = false) -> Color { onDark ? chalkboard : night ? Color.well : Color.labelCream }

    /// The light rim that tells ink from the dark it is shown on at night.
    static func rim(_ contrast: ColorSchemeContrast) -> Color { Color.ink.opacity(contrast == .increased ? 0.9 : 0.55) }

    /// The edge of a pen's ink on its label: the light rim at night, a faint one on paper and on Chalkboard.
    static func labelRim(night: Bool, onDark: Bool, contrast: ColorSchemeContrast) -> Color {
        night ? rim(contrast) : (onDark ? Color.white : Color.labelInk).opacity(contrast == .increased ? 0.6 : 0.22)
    }

    /// The check on the pen in hand, standing `offset` out from the corner.
    static func inUseBadge(offset: CGFloat) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(Color.onPrimaryCloth)
            .frame(width: 14, height: 14)
            .background(Color.primaryCloth, in: Circle())
            .offset(x: offset, y: offset)
    }

    /// The ink as it is on the page, as faint as the pen is set unless `solid` asks for it at full strength. At
    /// `night` a faint ink lies on a dark well, not on paper, so it is shown as pale as a page would make it. Where
    /// the page has `turned` dark, the well is what it is written on.
    static func ink(_ preset: ToolPreset, onDark: Bool, solid: Bool = false, night: Bool = false, turned: Bool = false) -> Color {
        if night, !onDark, !turned, !solid, preset.opacity < 1 { return onPaper(ToolPreset.uiColor(preset.tint), at: preset.opacity) }
        let color = solid ? ToolPreset.uiColor(preset.tint) : preset.uiColor
        return Color(uiColor: onDark || turned ? PKInkingTool.convertColor(color, from: .light, to: .dark) : color)
    }

    /// A colour as it shows on white paper at `opacity`, with nothing left to show through it.
    static func onPaper(_ color: UIColor, at opacity: Double) -> Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let rest = 1 - opacity
        return Color(red: red * opacity + rest, green: green * opacity + rest, blue: blue * opacity + rest)
    }

    var body: some View {
        let shape = Self.shape
        let blot = 9 + 11 * preset.widthFraction
        // At night the label is a well in the tray, as dark as the rest of it, and the ink is told from it by its rim.
        let night = scheme == .dark && !onDark
        let rim = Self.labelRim(night: night, onDark: onDark, contrast: contrast)
        ZStack {
            shape.fill(Self.paper(onDark: onDark, night: night))
            Circle()
                .fill(Self.ink(preset, onDark: onDark, night: night, turned: turned))
                .overlay { Circle().strokeBorder(rim, lineWidth: 1) }
                .frame(width: blot, height: blot)
                .offset(x: 3, y: 3)
            Image(systemName: preset.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(night ? Color.textSecondary : onDark ? Color.white.opacity(0.8) : Color.labelInkSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(3)
        }
        .frame(width: Self.side, height: Self.side)
        .overlay { shape.strokeBorder(inUse ? Color.accentColor : Color.hairline, lineWidth: inUse ? 2 : 1) }
        .overlay(alignment: .bottomTrailing) { if inUse { Self.inUseBadge(offset: 3) } }
        .accessibilityHidden(true)
    }
}

struct ToolSwatchButtonStyle: ButtonStyle {
    /// In a column, a slot is as wide as a button and as tall as a slot is wide.
    var turned = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .frame(width: turned ? ToolTray.button : ToolTray.slot, height: turned ? ToolTray.slot : ToolTray.button)
            .contentShape(Rectangle())
            .contentShape(.hoverEffect, RoundedRectangle.plate.inset(by: 1))
            .hoverEffect(.highlight)
    }
}

/// An icon in the tray. The tool in hand, and a helper that is on, wears the frame the pen in hand does.
struct TrayIconStyle: ButtonStyle {
    var isOn = false
    var width = ToolTray.button

    func makeBody(configuration: Configuration) -> some View {
        Icon(configuration: configuration, isOn: isOn, width: width)
    }

    private struct Icon: View {
        let configuration: Configuration
        let isOn: Bool
        let width: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityShowBorders) private var showBorders

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .imageScale(.large)
                .foregroundStyle(Color.ink)
                .opacity(isEnabled ? 1 : 0.35)
                .frame(width: ToolSwatch.side, height: ToolSwatch.side)
                .background { if isOn || (configuration.isPressed && isEnabled) || showBorders { ToolSwatch.shape.fill(Color.well) } }
                .overlay { if isOn { ToolSwatch.shape.strokeBorder(Color.accentColor, lineWidth: 2) } }
                .frame(width: width, height: ToolTray.button)
                .contentShape(Rectangle())
                .contentShape(.hoverEffect, RoundedRectangle.plate.inset(by: 1))
                .hoverEffect(.highlight)
                // The tray stays one height; its options, opened from here, grow with the text size.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityShowsLargeContentViewer { configuration.label.labelStyle(.titleAndIcon) }
        }
    }
}
