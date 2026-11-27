import SwiftUI
import PencilKit

/// How the ink card names and shows what is caught.
enum InkStyle {
    /// "2.4 pt", or "1.2–3 pt" when the lines differ.
    static func widthName(_ widths: ClosedRange<Double>) -> String {
        func figure(_ width: Double) -> String { width.formatted(.number.precision(.fractionLength(0...1))) }
        let low = figure(widths.lowerBound), high = figure(widths.upperBound)
        return low == high ? String(localized: "\(low) pt") : String(localized: "\(low)–\(high) pt")
    }

    /// The colour's name, or "Several colours".
    static func colourName(_ tints: [UInt32]) -> String {
        tints.count == 1 ? ToolPreset.colorName(tints[0]) : String(localized: "Several colours")
    }

    /// Where the page shows ink light, Chalkboard or paper Dark Mode turns dark, the blots are as light as the ink is there.
    @MainActor
    static func inkIsLight(_ session: EditorSession) -> Bool { session.inkIsLight || session.paperIsNight }

    static func shown(_ tint: UInt32, light: Bool) -> Color {
        let color = ToolPreset.uiColor(tint)
        return Color(uiColor: light ? PKInkingTool.convertColor(color, from: .light, to: .dark) : color)
    }

    /// What light ink is shown on: Chalkboard's green, or the dark well a page is at night. Nil where ink shows as it is.
    @MainActor
    static func ground(_ session: EditorSession) -> Color? {
        session.inkIsLight ? ToolSwatch.paper(onDark: true) : session.paperIsNight ? ToolSwatch.paper(onDark: false, night: true) : nil
    }
}

/// The card's Colour row: the ink's colour as a blot, opening the colours beside it.
struct InkColourRow: View {
    let session: EditorSession
    let look: InkLook

    var body: some View {
        OwlLunaMenu(Text("Colour")) {
            InkColourDrawer(session: session)
        } label: {
            Label {
                RowTitle(name: Text("Colour")) {
                    InkBlots(tints: Array(look.tints.prefix(3)), light: InkStyle.inkIsLight(session), ground: InkStyle.ground(session))
                }
            } icon: {
                Image(systemName: "paintpalette")
            }
        }
        .accessibilityLabel(Text("Colour"))
        .accessibilityValue(Text(InkStyle.colourName(look.tints)))
        .accessibilityIdentifier("editor.ink.colour")
    }
}

/// The card's Width row: how broad the lines are, opening the strip beside it.
struct InkWidthRow: View {
    let session: EditorSession
    let look: InkLook

    var body: some View {
        let width = InkStyle.widthName(look.widths)
        OwlLunaMenu(Text("Width")) {
            InkWidthDrawer(session: session)
        } label: {
            Label {
                RowTitle(name: Text("Width")) {
                    Text(width).monospacedDigit().foregroundStyle(Color.textSecondary)
                }
            } icon: {
                Image(systemName: "lineweight")
            }
        }
        .accessibilityLabel(Text("Width"))
        .accessibilityValue(Text(width))
        .accessibilityIdentifier("editor.ink.width")
    }
}

/// A row's name with what it is set to at its end, or under it when the text is too large for both.
private struct RowTitle<Value: View>: View {
    let name: Text
    @ViewBuilder var value: Value

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.x2) {
                name.lineLimit(1)
                Spacer(minLength: Space.x2)
                value.lineLimit(1)
            }
            VStack(alignment: .leading, spacing: Space.x1) {
                name
                value
            }
        }
    }
}

/// The first few colours of the ink, laid over one another.
private struct InkBlots: View {
    let tints: [UInt32]
    let light: Bool
    let ground: Color?
    @ScaledMetric(relativeTo: .callout) private var side: CGFloat = 20
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let side = min(side, 36)
        HStack(spacing: -side / 3) {
            ForEach(tints, id: \.self) { tint in
                Circle()
                    .fill(InkStyle.shown(tint, light: light))
                    .overlay { Circle().strokeBorder(blotRim(scheme, contrast), lineWidth: 1) }
                    .frame(width: side, height: side)
            }
        }
        .padding(3)
        .background { if let ground { RoundedRectangle.plate.fill(ground) } }
        .accessibilityHidden(true)
    }
}

/// The edge that tells a blot from the card it is on.
private func blotRim(_ scheme: ColorScheme, _ contrast: ColorSchemeContrast) -> Color {
    Color.ink.opacity(contrast == .increased ? 0.7 : scheme == .dark ? 0.45 : 0.25)
}

/// The pen colours, the highlighter's and one of your own, as blots. A tap colours the ink and leaves the cards open.
struct InkColourDrawer: View {
    let session: EditorSession
    @State private var mixing = false
    /// The colour tried on the strips and not yet put down, and whether a finger is on them.
    @State private var mixed: UInt32?
    @State private var sliding = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private static let cell: CGFloat = 48
    private static let columns = Array(repeating: GridItem(.fixed(cell), spacing: 0), count: 6)
    private static let palette = ToolPreset.inks + ToolPreset.tints

    var body: some View {
        let tints = session.inkLook?.tints ?? []
        let one = tints.count == 1 ? tints.first : nil
        let light = InkStyle.inkIsLight(session), ground = InkStyle.ground(session)
        LazyVGrid(columns: Self.columns, spacing: 0) {
            ForEach(Self.palette, id: \.self) { tint in
                blot(tint, chosen: one == tint, light: light)
            }
            mixButton(one: one, first: tints.first, light: light)
        }
        .padding(Space.x1)
        .background { if let ground { RoundedRectangle.plate.fill(ground) } }
        .padding(Space.x3)
        .disabled(tints.isEmpty)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Colour"))
    }

    /// On Chalkboard the ring is white, where cobalt would sink into the green.
    private var ring: Color { session.inkIsLight ? .white : .accentColor }

    private func blot(_ tint: UInt32, chosen: Bool, light: Bool) -> some View {
        Button { session.canvas?.tintInkSelection(tint) } label: {
            Circle()
                .fill(InkStyle.shown(tint, light: light))
                .overlay { Circle().strokeBorder(blotRim(scheme, contrast), lineWidth: 1) }
                .frame(width: 28, height: 28)
                .padding(4)
                .overlay { if chosen { Circle().strokeBorder(ring, lineWidth: 2) } }
                .frame(width: Self.cell, height: Self.cell)
                .contentShape(Rectangle())
        }
        .buttonStyle(BlotStyle())
        .accessibilityLabel(Text(ToolPreset.colorName(tint)))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("editor.ink.colour." + String(tint >> 8, radix: 16, uppercase: true))
    }

    /// The last blot is a colour of your own: it opens the strips it is mixed on, and the ink follows them.
    private func mixButton(one: UInt32?, first: UInt32?, light: Bool) -> some View {
        let own = one.map { !Self.palette.contains($0) } ?? false
        return Button { mixing = true } label: {
            Circle()
                .fill(own ? InkStyle.shown(one ?? 0, light: light) : Color.board)
                .overlay { Circle().strokeBorder(AngularGradient(colors: InkMixer.hues, center: .center), lineWidth: 4) }
                .frame(width: 28, height: 28)
                .padding(4)
                .overlay { if own { Circle().strokeBorder(ring, lineWidth: 2) } }
                .frame(width: Self.cell, height: Self.cell)
                .contentShape(Rectangle())
        }
        .buttonStyle(BlotStyle())
        .panel("Custom Colour", isPresented: $mixing) {
            InkMixer(color: ToolPreset.uiColor(one ?? first ?? ToolPreset.inks[0])) { mix($0) }
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in sliding = true }
                    .onEnded { _ in
                        sliding = false
                        settleMix()
                    })
                .onDisappear(perform: settleMix)
        }
        .accessibilityLabel(Text("Custom Colour"))
        .accessibilityAddTraits(own ? .isSelected : [])
        .accessibilityIdentifier("editor.ink.colour.custom")
    }

    /// The ink follows the strips and is put down when a slide ends, so a whole slide is one undo step. A step from VoiceOver is put down at once.
    private func mix(_ color: UIColor) {
        let tint = ToolPreset.bytes(of: color) | 0xFF
        guard tint != mixed else { return }
        mixed = tint
        session.canvas?.tryInkTint(tint)
        if !sliding { settleMix() }
    }

    private func settleMix() {
        guard mixed != nil else { return }
        mixed = nil
        session.canvas?.settleInkTint()
    }
}

/// A blot that leaves the cards open when tapped, unlike a menu's rows.
private struct BlotStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .hoverEffect(.highlight)
    }
}

/// How much broader caught ink is made, from half to three times as broad, on a logarithmic strip.
enum InkWidthScale {
    static let factors: ClosedRange<Double> = 0.5...3
    /// A plate makes the lines a tenth broader, or takes that tenth off again.
    static let step = 1.1
    /// Where the strip is marked: as the ink was, and twice as broad.
    static let marks: [Double] = [1, 2]
    private static let span = log(factors.upperBound / factors.lowerBound)

    static func clamped(_ factor: Double) -> Double { min(max(factor, factors.lowerBound), factors.upperBound) }

    static func place(of factor: Double) -> Double { log(clamped(factor) / factors.lowerBound) / span }

    /// The factor at a place, caught by a mark that is near it.
    static func factor(at place: Double) -> Double {
        let place = min(max(place, 0), 1)
        if let mark = marks.first(where: { abs(Self.place(of: $0) - place) < 0.015 }) { return mark }
        return factors.lowerBound * exp(place * span)
    }
}

/// Thinner to broader: a knob on a strip and a plate at each end. The ink follows the knob, and a whole slide or hold is one undo step.
struct InkWidthDrawer: View {
    let session: EditorSession
    /// How many times as broad the ink has been made since the drawer opened.
    @State private var factor = 1.0
    /// The factor the ink was last put down at. A try is passed relative to it, since the canvas tries from the ink as it stands.
    @State private var settled = 1.0
    @State private var trying = false
    @State private var pressing = false
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        let look = session.inkLook
        let readout = look.map { InkStyle.widthName(tried($0.widths)) } ?? ""
        VStack(alignment: .leading, spacing: Space.x1) {
            heading(readout)
            HStack(spacing: Space.x2) {
                plate(broader: false)
                WidthTrack(factor: factor, readout: readout, flipped: direction == .rightToLeft, slide: slide, release: settle) { broader in
                    step(broader: broader)
                    settle()
                }
                plate(broader: true)
            }
        }
        .padding(Space.x4)
        .frame(width: 328)
        .disabled(look == nil)
        .onDisappear(perform: settle)
    }

    /// The ink's widths as the knob makes them, kept as the canvas keeps a line.
    private func tried(_ widths: ClosedRange<Double>) -> ClosedRange<Double> {
        let times = factor / settled
        func width(_ now: Double) -> Double { InkRestyle.clamped(now * times, from: now) }
        return width(widths.lowerBound)...width(widths.upperBound)
    }

    private func heading(_ readout: String) -> some View {
        let name = Text("Width"), figure = Text(readout).monospacedDigit().foregroundStyle(Color.ink)
        return ViewThatFits(in: .horizontal) {
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
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Color.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(name)
        .accessibilityValue(Text(readout))
        .accessibilityIdentifier("editor.ink.width.value")
    }

    private func plate(broader: Bool) -> some View {
        Button { step(broader: broader) } label: {
            broader ? Label("Broader", systemImage: "plus") : Label("Thinner", systemImage: "minus")
        }
        .buttonStyle(HeldPlate { held in
            pressing = held
            if !held { settle() }
        })
        .buttonRepeatBehavior(.enabled)
        .disabled(broader ? factor >= InkWidthScale.factors.upperBound : factor <= InkWidthScale.factors.lowerBound)
        .accessibilityIdentifier(broader ? "editor.ink.width.plus" : "editor.ink.width.minus")
    }

    private func slide(to place: Double) {
        move(to: InkWidthScale.factor(at: place))
    }

    /// A tenth broader or narrower. Held, the plate repeats and is put down when it is let go; otherwise at once.
    private func step(broader: Bool) {
        move(to: broader ? factor * InkWidthScale.step : factor / InkWidthScale.step)
        let end = broader ? InkWidthScale.factors.upperBound : InkWidthScale.factors.lowerBound
        if !pressing || factor == end { settle() }
    }

    private func move(to wanted: Double) {
        let next = InkWidthScale.clamped(wanted)
        guard next != factor else { return }
        factor = next
        trying = true
        session.canvas?.tryInkLine(.times(factor / settled))
    }

    private func settle() {
        guard trying else { return }
        trying = false
        session.canvas?.settleInkLine()
        settled = factor
    }
}

/// A plate icon that says when it is pressed and let go, so a hold can be put down as one step.
private struct HeldPlate: ButtonStyle {
    let held: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        PlateIconButtonStyle().makeBody(configuration: configuration)
            .onChange(of: configuration.isPressed) { _, pressed in held(pressed) }
    }
}

/// The well the knob slides in, marked in mustard as the ink was and at twice as broad. It runs the way the card's rows do.
private struct WidthTrack: View {
    let factor: Double
    let readout: String
    let flipped: Bool
    let slide: (Double) -> Void
    let release: () -> Void
    let adjust: (Bool) -> Void
    @State private var grip: CGFloat?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - StripKnob.width, 1), middle = proxy.size.height / 2
            let x = { (factor: Double) in StripKnob.width / 2 + travel * along(InkWidthScale.place(of: factor)) }
            ZStack {
                Color.clear
                    .well(in: RoundedRectangle.thumb)
                    .frame(height: 16)
                ForEach(InkWidthScale.marks, id: \.self) { mark in
                    Rectangle()
                        .fill(Color.mustard)
                        .overlay { if contrast == .increased { Rectangle().strokeBorder(plateEdge(contrast), lineWidth: 0.5) } }
                        .frame(width: 3, height: 20)
                        .position(x: x(mark), y: middle)
                }
                StripKnob()
                    .position(x: x(factor), y: middle)
                    .animation(grip == nil && !reduceMotion ? Motion.quick : nil, value: factor)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if grip == nil {
                        let knob = x(factor)
                        grip = abs(drag.startLocation.x - knob) <= 22 ? drag.startLocation.x - knob : 0
                    }
                    slide(along((drag.location.x - (grip ?? 0) - StripKnob.width / 2) / travel))
                }
                .onEnded { _ in
                    grip = nil
                    release()
                })
            .accessibilityElement()
            .accessibilityLabel(Text("Width"))
            .accessibilityValue(Text(readout))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(true)
                case .decrement: adjust(false)
                @unknown default: break
                }
            }
            // A tap from Voice Control or VoiceOver lands on the knob, which leaves the width as it is.
            .accessibilityActivationPoint(UnitPoint(x: x(factor) / max(proxy.size.width, 1), y: 0.5))
            .accessibilityIdentifier("editor.ink.width.strip")
        }
        .frame(height: 44)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func along(_ place: Double) -> Double {
        flipped ? 1 - place : place
    }
}
