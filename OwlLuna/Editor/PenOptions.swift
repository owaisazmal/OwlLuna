import SwiftUI
import PencilKit

/// A pen's kind, colour, width and opacity, changed where it stands in the tray.
struct PenOptions: View {
    let id: UUID
    let toolbox: Toolbox
    let onDark: Bool
    let turned: Bool
    let remove: () -> Void
    @State private var mixing = false
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.colorScheme) private var scheme

    private static let cell: CGFloat = 44
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 6)

    var body: some View {
        if let pen = toolbox.shelf.usable.first(where: { $0.id == id }), let ink = pen.inkType {
            content(pen, ink)
                .frame(width: 304 + Space.x4 * 2)
        }
    }

    private func content(_ pen: ToolPreset, _ ink: PKInkingTool.InkType) -> some View {
        let width = pen.width.formatted(.number.precision(.fractionLength(0...(pen.width < 1 ? 2 : 1))))
        let night = scheme == .dark && !onDark
        // The label shows the ink as faint as it is set; the tools of the roll and the bars are drawn at full strength.
        let colour = ToolSwatch.ink(pen, onDark: onDark, night: night, turned: turned)
        let solid = ToolSwatch.ink(pen, onDark: onDark, solid: true, turned: turned)
        let paper = ToolSwatch.paper(onDark: onDark, night: night), faintest = ToolPreset.leastOpacity
        // At the largest text sizes the name goes under the label, where it has the whole width.
        let stacked = textSize.isAccessibilitySize
        let header = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x2)) : AnyLayout(HStackLayout(spacing: Space.x3))
        return VStack(alignment: .leading, spacing: Space.x3) {
            header {
                InkLabel(kind: ink, breadth: pen.widthTravel, ink: colour, paper: paper, night: night)
                VStack(alignment: .leading, spacing: 0) {
                    Text(pen.kindName).font(.headline).foregroundStyle(Color.ink)
                    Text(pen.opacity < 1 ? "\(pen.colorName), \(pen.opacityName)" : pen.colorName).font(.footnote).foregroundStyle(Color.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            PenRoll(kind: Binding(get: { ink }, set: { kind in
                toolbox.changePen(id) { $0.ink = kind.rawValue; $0.width = Double(kind.defaultWidth) }
            }), ink: solid, paper: paper, night: night)
                .accessibilityIdentifier("editor.tools.pen.kind")
            LazyVGrid(columns: Self.columns, spacing: 0) {
                ForEach(ToolPreset.palette(for: ink), id: \.self) { color in colourButton(color, chosen: pen.tint == color) }
                mixButton(pen)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Colour"))
            WidthBar(travel: Binding(get: { pen.widthTravel }, set: { travel in
                toolbox.changePen(id) { $0.width = ToolPreset.width(at: travel, of: ink) }
            }), ink: solid, paper: paper, night: night, value: width, identifier: "editor.tools.pen.width")
            // Opacity moves in steps of a twentieth, so the figure beside it is a round one.
            WidthBar(measure: .opacity, travel: Binding(get: { (pen.opacity - faintest) / (1 - faintest) }, set: { travel in
                toolbox.changePen(id) { $0.opacity = ((faintest + (1 - faintest) * travel) * 20).rounded() / 20 }
            }), ink: solid, paper: paper, night: night, turned: turned, value: pen.opacityName, identifier: "editor.tools.pen.opacity")
            place(pen)
        }
        .padding(Space.x4)
    }

    /// Where the pen stands among the others, and the way off the tray.
    private func place(_ pen: ToolPreset) -> some View {
        let pens = toolbox.shelf.usable, index = pens.firstIndex { $0.id == id } ?? 0
        return HStack(spacing: 0) {
            Button { toolbox.shelf.move(id, by: -1) } label: { Label("Move Left", systemImage: "arrow.left") }
                .disabled(index == 0)
                .accessibilityIdentifier("editor.tools.pen.left")
            Button { toolbox.shelf.move(id, by: 1) } label: { Label("Move Right", systemImage: "arrow.right") }
                .disabled(index >= pens.count - 1)
                .accessibilityIdentifier("editor.tools.pen.right")
            Spacer(minLength: 0)
            Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") }
                .disabled(pens.count < 2)
                .accessibilityIdentifier("editor.tools.pen.remove")
        }
        .buttonStyle(.barIcon)
        .padding(.top, Space.x1)
        .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
    }

    /// The last blot of the palette is a colour of your own: it opens the strips it is mixed on.
    private func mixButton(_ pen: ToolPreset) -> some View {
        let own = !ToolPreset.palette(for: pen.inkType ?? .pen).contains(pen.tint)
        return Button { mixing = true } label: {
            Circle()
                .fill(own ? Color(uiColor: ToolPreset.uiColor(pen.tint)) : Color.board)
                .overlay { Circle().strokeBorder(AngularGradient(colors: InkMixer.hues, center: .center), lineWidth: 4) }
                .frame(width: 28, height: 28)
                .padding(4)
                .overlay { if own { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
                .frame(maxWidth: .infinity, minHeight: Self.cell)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel("Custom Colour", isPresented: $mixing) {
            InkMixer(color: ToolPreset.uiColor(pen.tint)) { color in toolbox.changePen(id) { $0.setTint(ToolPreset.bytes(of: color)) } }
        }
        .accessibilityLabel(Text("Custom Colour"))
        .accessibilityAddTraits(own ? .isSelected : [])
        .accessibilityIdentifier("editor.tools.pen.custom")
    }

    private func colourButton(_ color: UInt32, chosen: Bool) -> some View {
        Button { toolbox.changePen(id) { $0.setTint(color) } } label: {
            Circle()
                .fill(Color(uiColor: ToolPreset.uiColor(color)))
                .overlay { Circle().strokeBorder(Color.ink.opacity(scheme == .dark ? 0.45 : 0.25), lineWidth: 1) }
                .frame(width: 28, height: 28)
                .padding(4)
                .overlay { if chosen { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
                .frame(maxWidth: .infinity, minHeight: Self.cell)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ToolPreset.colorName(color)))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A colour mixed on two strips: its hue on one, and on the other how far it is let down to white or deepened to black.
private struct InkMixer: View {
    let mix: (UIColor) -> Void
    @State private var hue: Double
    @State private var shade: Double

    static let hues: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 0.85, brightness: 0.95) }

    init(color: UIColor, mix: @escaping (UIColor) -> Void) {
        self.mix = mix
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        _hue = State(initialValue: h)
        _shade = State(initialValue: b < 0.99 ? 0.5 + (1 - b) / 2 : s / 2)
    }

    /// Half way along the shade strip the hue is at its fullest; before it there is white in it, after it black.
    private static func color(hue: Double, shade: Double) -> UIColor {
        UIColor(hue: hue, saturation: min(1, shade * 2), brightness: min(1, (1 - shade) * 2), alpha: 1)
    }

    var body: some View {
        let color = Self.color(hue: hue, shade: shade)
        HStack(spacing: Space.x4) {
            RoundedRectangle.plate
                .fill(Color(uiColor: color))
                .frame(width: 44, height: 44)
                .plate(in: RoundedRectangle.plate)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                MixStrip(title: "Hue", value: $hue, colors: Self.hues)
                MixStrip(title: "Shade", value: $shade, colors: [.white, Color(uiColor: Self.color(hue: hue, shade: 0.5)), .black])
            }
        }
        .padding(Space.x4)
        .frame(width: 304 + Space.x4 * 2)
        .onChange(of: hue) { _, _ in mix(Self.color(hue: hue, shade: shade)) }
        .onChange(of: shade) { _, _ in mix(Self.color(hue: hue, shade: shade)) }
    }
}

/// A strip of colour with a square knob on it. It is read the same way in every language, so it never turns round.
private struct MixStrip: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let colors: [Color]
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - StripKnob.width, 1)
            ZStack(alignment: .leading) {
                RoundedRectangle.thumb
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .overlay { RoundedRectangle.thumb.strokeBorder(plateEdge(contrast), lineWidth: 1) }
                    .frame(height: 16)
                StripKnob().offset(x: travel * value)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value = min(max(($0.location.x - StripKnob.width / 2) / travel, 0), 1) })
        }
        .frame(height: 44)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityRepresentation { Slider(value: $value) { Text(title) } }
    }
}

/// The square knob on a strip of colour.
struct StripKnob: View {
    static let width: CGFloat = 14

    var body: some View {
        RoundedRectangle.thumb
            .fill(Color.board)
            .overlay { RoundedRectangle.thumb.strokeBorder(Color.ink, lineWidth: 1.5) }
            .frame(width: Self.width, height: 28)
            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
    }
}

/// What the eraser takes, and how wide it is when it takes part of a stroke.
struct EraserOptions: View {
    let toolbox: Toolbox
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let eraser = toolbox.eraser, night = scheme == .dark
        let width = eraser.width.formatted(.number.precision(.fractionLength(0)))
        VStack(alignment: .leading, spacing: Space.x3) {
            OwlLunaSegmentedPicker("Eraser", selection: Binding(get: { eraser.kind }, set: { kind in
                var changed = eraser
                changed.kind = kind
                toolbox.setEraser(changed)
            }), options: Eraser.Kind.allCases) { Text($0.displayName) }
            if eraser.kind == .part {
                let widths = Eraser.widths, span = widths.upperBound - widths.lowerBound
                WidthBar(travel: Binding(get: { (eraser.width - widths.lowerBound) / span }, set: { travel in
                    var changed = eraser
                    changed.width = widths.lowerBound + span * travel
                    toolbox.setEraser(changed)
                }), ink: night ? Color.textSecondary : Color.labelInkSecondary, paper: ToolSwatch.paper(onDark: false, night: night), night: night,
                         value: width, identifier: "editor.tools.eraser.width")
            }
        }
        .padding(Space.x4)
        .frame(width: 344)
    }
}

/// A width, as a stroke that swells along a strip of paper with a knob to slide on it; the knob holds a blot as
/// large as the stroke is where it stands. An opacity is a wash over ruled lines that covers more of them as it
/// goes, and the knob's blot is as faint as the ink is set.
private struct WidthBar: View {
    enum Measure { case width, opacity }

    var measure = Measure.width
    /// How far along the knob is, from 0 to 1.
    @Binding var travel: Double
    let ink: Color
    let paper: Color
    /// At night the strip is a well, and the stroke and the blot wear a light rim.
    var night = false
    /// The page is dark as well, so a faint ink is faint over the dark.
    var turned = false
    let value: String
    let identifier: String
    @State private var isDragging = false
    @Environment(\.colorSchemeContrast) private var contrast

    private static let height: CGFloat = 44
    private static let knob: CGFloat = 32
    private static let shape = RoundedRectangle.track

    var body: some View {
        let name = title.font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
        let figure = Text(value).font(.subheadline.monospacedDigit()).foregroundStyle(Color.textSecondary)
        return VStack(spacing: Space.x2) {
            // At the largest text sizes "Opacity" and its figure don't fit side by side; the figure goes under it.
            ViewThatFits(in: .horizontal) {
                HStack {
                    name.lineLimit(1)
                    Spacer(minLength: Space.x2)
                    figure.lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 0) {
                    name
                    figure
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityHidden(true)
            strip
        }
    }

    private var title: Text { measure == .width ? Text("Width") : Text("Opacity") }

    private var strip: some View {
        GeometryReader { proxy in
            let run = max(proxy.size.width - Self.knob - Space.x2 * 2, 1)
            ZStack(alignment: .leading) {
                Self.shape.fill(paper)
                Group {
                    switch measure {
                    case .width:
                        Swell()
                            .fill(ink)
                            .overlay { if night { Swell().stroke(ToolSwatch.rim(contrast), lineWidth: 1) } }
                            .frame(height: 20)
                    case .opacity:
                        wash
                    }
                }
                .padding(.horizontal, Space.x2 + Self.knob / 2)
                knob.offset(x: Space.x2 + run * travel)
            }
            .overlay { Self.shape.strokeBorder(Color.hairline, lineWidth: 1) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    isDragging = true
                    travel = min(max((drag.location.x - Space.x2 - Self.knob / 2) / run, 0), 1)
                }
                .onEnded { _ in isDragging = false })
        }
        .frame(height: Self.height)
        .accessibilityRepresentation {
            Slider(value: $travel)
                .accessibilityLabel(title)
                .accessibilityValue(Text(value))
                .accessibilityIdentifier(identifier)
        }
    }

    /// The ink at `strength`. At night it isn't paper it lies on, so it is as pale as it would be on a page.
    private func faint(_ strength: Double) -> Color {
        night && !turned ? ToolSwatch.onPaper(UIColor(ink), at: strength) : ink.opacity(strength)
    }

    /// The lines of a page with the ink washed over them, from as faint as a pen can be to full strength: the
    /// stronger the ink, the less of the lines shows through.
    private var wash: some View {
        let band = RoundedRectangle.thumb
        let lines = VStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { _ in Rectangle().fill(night ? Color.black.opacity(0.4) : Color.ink.opacity(0.35)).frame(height: 1) }
        }
        return ZStack {
            if !night { lines }
            band.fill(LinearGradient(colors: [faint(ToolPreset.leastOpacity), ink], startPoint: .leading, endPoint: .trailing))
            if night { lines.mask(LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)) }
        }
        .frame(height: 16)
        .clipShape(band)
        .overlay { band.strokeBorder(night ? ToolSwatch.rim(contrast) : Color.ink.opacity(0.18), lineWidth: 1) }
        .frame(height: 20)
    }

    private var knob: some View {
        let blot = measure == .width ? 4 + 16 * travel : 16
        let strength = measure == .width ? 1 : ToolPreset.leastOpacity + (1 - ToolPreset.leastOpacity) * travel
        return Circle()
            .fill(night ? Color.surface : paper)
            .overlay { if measure == .opacity { Rectangle().fill(Color.ink.opacity(night ? 0.5 : 0.35)).frame(width: 22, height: 1) } }
            .overlay {
                Circle()
                    .fill(faint(strength))
                    .overlay { if night || measure == .opacity { Circle().strokeBorder(ToolSwatch.rim(contrast).opacity(night ? 1 : 0.5), lineWidth: 1) } }
                    .frame(width: blot, height: blot)
            }
            .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 2) }
            .frame(width: Self.knob, height: Self.knob)
            .shadow(color: .black.opacity(0.22), radius: isDragging ? 4 : 1.5, y: 1)
            .scaleEffect(isDragging ? 1.08 : 1)
            .animation(Motion.quick, value: isDragging)
    }

    /// A stroke that begins as a hairline and ends as broad as the strip allows, round at both ends.
    private struct Swell: Shape {
        func path(in rect: CGRect) -> Path {
            let thin: CGFloat = 1, broad = rect.height / 2
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + thin, y: rect.midY - thin))
            path.addLine(to: CGPoint(x: rect.maxX - broad, y: rect.midY - broad))
            path.addArc(center: CGPoint(x: rect.maxX - broad, y: rect.midY), radius: broad, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + thin, y: rect.midY + thin))
            path.addArc(center: CGPoint(x: rect.minX + thin, y: rect.midY), radius: thin, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            path.closeSubpath()
            return path
        }
    }
}
