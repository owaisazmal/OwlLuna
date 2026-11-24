import SwiftUI

/// A text box's type controls on a strip over the keyboard while the box is typed in.
struct TypeStrip: View {
    let session: EditorSession
    let box: TextBox
    /// The pane's width.
    let room: CGFloat
    /// The card that is open, by the piece it hangs from.
    @State private var card: Piece?
    /// Where the pane ends in its window, where the keyboard or the home indicator's margin begins, and where that margin alone does.
    @State private var foot: CGFloat = 0
    @State private var safe: CGFloat = 0
    @State private var container: CGFloat = 0
    /// The keyboard's room, kept while a card has the system put the keyboard away.
    @State private var hold: Hold?
    @State private var waiting: Task<Void, Never>?
    @State private var tall = TypeStrip.height
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalBar) private var rail

    /// As tall as this until its words outgrow it at the accessibility text sizes.
    static let height: CGFloat = 48
    static let inset = Space.x2
    static let gap = Space.x2

    /// The page keeps clear of the room. A small card leaves the strip standing over it; the whole card takes it, and the strip stands under.
    private struct Hold: Equatable {
        var room: CGFloat
        var strip: Bool
    }

    /// What the strip holds, the first kept longest: as it narrows the last gives way first.
    enum Piece: CaseIterable, Identifiable {
        case more, size, emphasis, face, list, colour

        var id: Self { self }
    }

    /// The pieces a strip `room` wide holds, each taking `width` and a gap from the one before.
    static func pieces(room: CGFloat, width: (Piece) -> CGFloat) -> Set<Piece> {
        var kept: Set<Piece> = [], used = inset * 2
        for piece in Piece.allCases {
            let needs = width(piece) + (kept.isEmpty ? 0 : gap)
            guard kept.isEmpty || used + needs <= room else { break }
            kept.insert(piece)
            used += needs
        }
        return kept
    }

    /// How wide a piece stands at a text size. Its words follow the size all the way; its icons are a bar's.
    static func width(of piece: Piece, at textSize: DynamicTypeSize) -> CGFloat {
        switch piece {
        case .more: max(44, wordWidth(String(localized: "More"), .body, at: textSize) + 20)
        case .size: 44 * 2 + 2 + readoutWidth(at: textSize)
        case .emphasis: 44 * CGFloat(TextEmphasis.allCases.count)
        case .face: (TextBox.Face.allCases.map { wordWidth($0.displayName, .callout, at: textSize) }.max() ?? 0) + Space.x3 * 2 + Space.x2 + chevron
        case .list, .colour: 44
        }
    }

    private static let chevron: CGFloat = 12

    /// Room for three figures and a tenth, so the plate keeps its width as the size is stepped.
    static func readoutWidth(at textSize: DynamicTypeSize) -> CGFloat {
        max(44, wordWidth("200.0", .callout, weight: .semibold, at: textSize) + Space.x2)
    }

    private static func wordWidth(_ word: String, _ style: UIFont.TextStyle, weight: UIFont.Weight = .medium, at textSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(textSize))
        let font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize, weight: weight)
        return (word as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 1
    }

    /// A size as the strip reads it out: whole points, or to a tenth between them.
    static func sizeText(_ size: CGFloat) -> String {
        Double(size).formatted(.number.precision(.fractionLength(size == size.rounded() ? 0 : 1)))
    }

    /// The keyboard's height under the strip, or the home indicator's margin.
    private var stands: CGFloat { max(foot - safe, 0) }

    var body: some View {
        let shown = Self.pieces(room: room) { Self.width(of: $0, at: textSize) }
        let lift = hold.flatMap { $0.strip ? max($0.room - (foot - container), 0) : nil }
        // With no keyboard under it the strip stands on the zoom window, as the tray does.
        let perch = hold == nil && stands <= foot - container + 1 ? session.zoomPanelLift : 0
        let covers = tall + max(stands, hold?.room ?? 0) + perch
        // A folded iPhone Duo's rail stands beside the strip, not on it.
        let sides: Edge.Set = rail == nil ? .horizontal : rail?.edge == .leading ? .trailing : .leading
        HStack(spacing: Self.gap) {
            ForEach([Piece.face, .size, .emphasis, .list, .colour].filter(shown.contains)) { piece in
                view(for: piece).frame(width: Self.width(of: piece, at: textSize))
            }
            Spacer(minLength: 0)
            more.frame(width: Self.width(of: .more, at: textSize))
        }
        .padding(.horizontal, Self.inset)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: Self.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tall = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Text Style"))
        .accessibilityIdentifier("editor.type.strip")
        .background { Color.board.overlay(alignment: .top) { HairlineRule() }.ignoresSafeArea(.all, edges: sides) }
        .padding(.bottom, lift ?? perch)
        .background { if perch == 0 { Color.board.ignoresSafeArea(.all, edges: sides.union(.bottom)) } }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(lift == nil ? [] : .keyboard, edges: .bottom)
        .background { edges }
        .onChange(of: covers, initial: true) { session.typeStripHeight = covers }
        .onDisappear { session.typeStripHeight = 0 }
        .onChange(of: card == nil) { _, closed in if closed { letGoSoon() } }
        .onChange(of: stands) { if card == nil, let hold, stands >= hold.room - 0.5 { letGo(animated: false) } }
    }

    /// Reads where the pane's foot, the keyboard and the home indicator's margin are.
    private var edges: some View {
        ZStack {
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { safe = $0 }
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { container = $0 }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { foot = $0 }
                .ignoresSafeArea(.all, edges: .bottom)
        }
    }

    private func isOpen(_ piece: Piece) -> Binding<Bool> {
        Binding(get: { card == piece }, set: { open in
            if open { self.open(piece) } else if card == piece { card = nil }
        })
    }

    private func open(_ piece: Piece) {
        waiting?.cancel()
        if stands > foot - container + 1 { hold = Hold(room: stands, strip: piece != .more) } else { hold?.strip = piece != .more }
        card = piece
    }

    /// The keyboard comes back once the card has gone; with none to come, the room is given up.
    private func letGoSoon() {
        waiting?.cancel()
        guard hold != nil else { return }
        waiting = Task {
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { letGo(animated: true) }
        }
    }

    private func letGo(animated: Bool) {
        waiting?.cancel()
        withAnimation(animated ? Motion.adaptive(Motion.standard, reduceMotion: reduceMotion) : nil) { hold = nil }
    }

    @ViewBuilder
    private func view(for piece: Piece) -> some View {
        switch piece {
        case .more: more
        case .size: stepper
        case .emphasis: emphasis
        case .face: faceMenu
        case .list: listMenu
        case .colour: colourMenu
        }
    }

    private var more: some View {
        Button("More") { open(.more) }
            .buttonStyle(WordStyle())
            .panel("Text Style", isPresented: isOpen(.more)) { TextStylePanel(session: session) }
            .accessibilityIdentifier("editor.type.more")
    }

    // MARK: Size

    /// One ruled plate: a step down, the size, a step up.
    private var stepper: some View {
        let rule = Rectangle().fill(plateEdge(contrast)).frame(width: 1).padding(.vertical, BarMetrics.inset)
        return HStack(spacing: 0) {
            step(-1, "Smaller", symbol: "minus").disabled(box.fontSize <= TextBox.fontSizes.lowerBound)
            rule
            Text(Self.sizeText(box.fontSize))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .frame(minHeight: 44)
                .frame(width: Self.readoutWidth(at: textSize))
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel(Text("Size"))
                .accessibilityValue(Text("\(Self.sizeText(box.fontSize)) pt"))
                .accessibilityAdjustableAction { session.stepTextSize(by: $0 == .increment ? 1 : -1) }
                .accessibilityIdentifier("editor.type.size")
            rule
            step(1, "Larger", symbol: "plus").disabled(box.fontSize >= TextBox.fontSizes.upperBound)
        }
        .buttonStyle(.barIcon)
        .background { Color.clear.plate(in: RoundedRectangle.plate).padding(.vertical, BarMetrics.inset) }
    }

    /// A point at a time, and on for as long as it is held.
    private func step(_ points: Int, _ title: LocalizedStringKey, symbol: String) -> some View {
        Button { session.stepTextSize(by: points) } label: { Label(title, systemImage: symbol) }
            .buttonRepeatBehavior(.enabled)
            .accessibilityIdentifier("editor.type.size.\(symbol)")
    }

    // MARK: Bold, italic and underline

    private var emphasis: some View {
        HStack(spacing: 0) {
            ForEach(TextEmphasis.allCases) { emphasis in
                let on = box[keyPath: emphasis.path]
                Button { session.updateText { $0[keyPath: emphasis.path].toggle() } } label: {
                    Label(emphasis.title, systemImage: emphasis.rawValue)
                        .labelStyle(.iconOnly)
                        .font(.body.weight(on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.ink : Color.textSecondary)
                        .frame(width: 44)
                        .frame(minHeight: 44, maxHeight: .infinity)
                        .background { if on { SegmentThumb().padding(.vertical, 1) } }
                        .contentShape(Rectangle())
                        .contentShape(.hoverEffect, RoundedRectangle.thumb.inset(by: 5))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityShowsLargeContentViewer { Label(emphasis.title, systemImage: emphasis.rawValue) }
                .accessibilityIdentifier("editor.type.\(emphasis.rawValue)")
            }
        }
        .background { Color.clear.well(in: RoundedRectangle.track).padding(.vertical, BarMetrics.inset) }
        .dynamicTypeSize(...barTextLimit)
    }

    // MARK: Cards

    /// One of the strip's buttons, and the card of rows it opens.
    private func menu<Label: View, Rows: View>(_ piece: Piece, _ title: LocalizedStringKey, @ViewBuilder rows: @escaping () -> Rows,
                                               @ViewBuilder label: () -> Label) -> some View {
        Button { open(piece) } label: { label() }
            .cardMenu(Text(title), isPresented: isOpen(piece), under: CGRect(x: 0, y: 0, width: Self.width(of: piece, at: textSize), height: 44), rows: rows)
    }

    private var faceMenu: some View {
        menu(.face, "Typeface") {
            OwlLunaPicker(selection: Binding(get: { box.face }, set: { face in session.updateText { $0.face = face } })) {
                ForEach(TextBox.Face.allCases) { face in
                    FaceName(box: box, face: face).tag(face)
                }
            }
        } label: {
            HStack(spacing: Space.x2) {
                Text(box.face.displayName).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).frame(width: Self.chevron).accessibilityHidden(true)
            }
        }
        .buttonStyle(WordStyle(ruled: true))
        .accessibilityLabel(Text("Typeface"))
        .accessibilityValue(Text(box.face.displayName))
        .accessibilityIdentifier("editor.type.face")
    }

    /// A list keeps to the left, as on the card.
    private var listMenu: some View {
        menu(.list, "List") {
            OwlLunaPicker(selection: Binding(get: { box.list }, set: { list in
                session.updateText {
                    if list != nil || $0.list != nil { $0.alignment = .leading }
                    $0.list = list
                }
            })) {
                Label { Text("No List") } icon: { ListIcon(list: nil) }.tag(TextBox.List?.none)
                ForEach(TextBox.List.allCases) { list in
                    Label { Text(list.displayName) } icon: { ListIcon(list: list) }.tag(TextBox.List?.some(list))
                }
            }
        } label: {
            Label { Text("List") } icon: { ListIcon(list: box.list ?? .bullet) }
        }
        .buttonStyle(.barIcon)
        .accessibilityValue(Text(box.list?.displayName ?? String(localized: "No List")))
        .accessibilityIdentifier("editor.type.list")
    }

    private var colourMenu: some View {
        menu(.colour, "Text Colour") {
            OwlLunaPicker(selection: Binding(get: { box.tint }, set: { tint in session.updateText { $0.tint = tint } })) {
                ForEach(TextBox.Tint.allCases) { tint in
                    Label { Text(tint.displayName) } icon: { swatch(tint) }.tag(tint)
                }
            }
        } label: {
            Label { Text("Text Colour") } icon: { swatch(box.tint) }
        }
        .buttonStyle(.barIcon)
        .accessibilityLabel(Text("Text Colour"))
        .accessibilityValue(Text(box.tint.displayName))
        .accessibilityIdentifier("editor.type.colour")
    }

    /// A tint as it will look on the page, over its paper.
    private func swatch(_ tint: TextBox.Tint) -> some View {
        let onDark = session.inkIsLight || session.paperIsNight
        let paper = Color(uiColor: session.inkIsLight ? PageRenderer.paperColor(.charcoal) : PageRenderer.paperColor(.white, night: session.paperIsNight))
        return RoundedRectangle.thumb
            .fill(Color(uiColor: tint.color(onDark: onDark)))
            .frame(width: 14, height: 14)
            .frame(width: 24, height: 24)
            .background(paper, in: RoundedRectangle.plate)
            .overlay { RoundedRectangle.plate.strokeBorder(plateEdge(contrast), lineWidth: 1) }
            .accessibilityHidden(true)
    }
}

/// A face's name set in the face, as the box would set it.
private struct FaceName: View {
    let box: TextBox
    let face: TextBox.Face
    @ScaledMetric(relativeTo: .callout) private var size: CGFloat = 17

    var body: some View {
        var sample = box
        sample.face = face
        sample.fontSize = size
        return Text(face.displayName).font(Font(sample.font())).underline(box.isUnderlined)
    }
}

/// A word on the strip, ruled as a plate or on its own. It fills the width it is given and grows with the text size, as the strip does.
private struct WordStyle: ButtonStyle {
    var ruled = false

    func makeBody(configuration: Configuration) -> some View {
        Word(configuration: configuration, ruled: ruled)
    }

    private struct Word: View {
        let configuration: Configuration
        let ruled: Bool
        @Environment(\.accessibilityShowBorders) private var showBorders

        var body: some View {
            let shape = RoundedRectangle.plate
            configuration.label
                .font(.system(ruled ? .callout : .body, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(Color.ink)
                .padding(.horizontal, ruled ? Space.x3 : 10)
                .frame(maxWidth: .infinity, minHeight: BarMetrics.height)
                .background {
                    if ruled {
                        Color.clear.plate(in: shape, pressed: configuration.isPressed)
                    } else if configuration.isPressed || showBorders {
                        RoundedRectangle.thumb.fill(Color.well).padding(3)
                    }
                }
                .contentShape([.hoverEffect, .accessibility], shape)
                .hoverEffect(.highlight)
                .padding(.vertical, BarMetrics.inset)
                .contentShape(Rectangle())
        }
    }
}
