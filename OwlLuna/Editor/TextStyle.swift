import SwiftUI

/// Bold, italic and underline, each with its place in a text box and its key.
enum TextEmphasis: String, CaseIterable, Identifiable {
    case bold, italic, underline

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .bold: "b"
        case .italic: "i"
        case .underline: "u"
        }
    }

    var path: WritableKeyPath<TextBox, Bool> {
        switch self {
        case .bold: \.isBold
        case .italic: \.isItalic
        case .underline: \.isUnderlined
        }
    }
}

/// A text box's controls in the arrange bar: bold, italic and underline where the bar has room, and the Text Style
/// card that holds everything at once.
struct TextStyleControls: View {
    let session: EditorSession
    let box: TextBox
    let roomy: Bool
    let shortcuts: Bool
    @State private var showing = false

    var body: some View {
        HStack(spacing: 0) {
            if roomy {
                ForEach(TextEmphasis.allCases) { emphasis in
                    let on = box[keyPath: emphasis.path]
                    Button { session.updateText { $0[keyPath: emphasis.path].toggle() } } label: {
                        Label(emphasis.title, systemImage: emphasis.rawValue)
                    }
                    .background { if on { RoundedRectangle.thumb.fill(Color.well).padding(.horizontal, 3).padding(.vertical, 5) } }
                    .keyboardShortcut(shortcuts ? KeyboardShortcut(emphasis.key) : nil)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("editor.arrange.\(emphasis.rawValue)")
                }
            }
            Button { showing = true } label: { Label("Text Style", systemImage: "textformat.size") }
                .panel("Text Style", isPresented: $showing) { TextStylePanel(session: session) }
                .accessibilityIdentifier("editor.arrange.style")
        }
        .background {
            if shortcuts && !roomy {
                ForEach(TextEmphasis.allCases) { emphasis in
                    Button(emphasis.title) { session.updateText { $0[keyPath: emphasis.path].toggle() } }
                        .keyboardShortcut(KeyboardShortcut(emphasis.key))
                }
                .hidden()
                .accessibilityHidden(true)
            }
        }
    }
}

/// All of a text box's look on one card, nothing behind another: typeface, size, emphasis, alignment, list, and the
/// colours of the words and of the wash behind them.
struct TextStylePanel: View {
    let session: EditorSession
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var height: CGFloat?
    @ScaledMetric(relativeTo: .title3) private var sampleSize: CGFloat = 20
    private static let width: CGFloat = 344

    /// As tall as it needs, and scrolls where the screen is shorter than that.
    var body: some View {
        if let box = session.selectedItem?.text {
            ScrollView {
                card(box).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: Self.width)
            .frame(idealHeight: height)
        }
    }

    private func card(_ box: TextBox) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            let named = faceNamesFit()
            OwlLunaSegmentedPicker("Typeface", selection: Binding(get: { box.face }, set: { face in session.updateText { $0.face = face } }),
                                   options: TextBox.Face.allCases, padding: Space.x2) { face in
                VStack(spacing: 0) {
                    Text(verbatim: "Ag").font(Font(sample(box, face: face)))
                    if named { Text(face.displayName).font(.caption).lineLimit(1) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(face.displayName))
            }
            .accessibilityIdentifier("editor.text.face")
            VStack(alignment: .leading, spacing: Space.x1) {
                sizeHeading(box)
                sizes(box)
                TextSizeStrip(session: session, box: box)
            }
            let stacked = textSize.isAccessibilitySize
            (stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x3)) : AnyLayout(HStackLayout(spacing: Space.x3))) {
                emphasis(box)
                alignment(box)
            }
            OwlLunaSegmentedPicker("List", selection: Binding(get: { box.list }, set: { list in
                session.updateText {
                    if list != nil || $0.list != nil { $0.alignment = .leading }
                    $0.list = list
                }
            }), options: [nil] + TextBox.List.allCases.map(Optional.some)) { list in
                Label { Text(list?.displayName ?? String(localized: "No List")) } icon: { ListIcon(list: list) }.labelStyle(.iconOnly)
            }
            .accessibilityIdentifier("editor.text.list")
            colours(box)
        }
        .padding(Space.x4)
    }

    /// The face as it would be set, at a size to compare them by.
    private func sample(_ box: TextBox, face: TextBox.Face) -> UIFont {
        var sample = box
        sample.face = face
        sample.fontSize = sampleSize
        return sample.font()
    }

    /// Whether every face's name fits whole under its sample; where one doesn't, the samples stand alone.
    private func faceNamesFit() -> Bool {
        guard !textSize.isAccessibilitySize else { return true }
        let font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(textSize)))
        let room = (Self.width - 2 * Space.x4) / CGFloat(TextBox.Face.allCases.count) - 2 * Space.x2
        return TextBox.Face.allCases.allSatisfy { ($0.displayName as NSString).size(withAttributes: [.font: font]).width.rounded(.up) <= room }
    }

    /// "Size", and the box's size in points beside it, which the strip under it changes as it slides.
    private func sizeHeading(_ box: TextBox) -> some View {
        let name = Text("Size"), points = TextBox.pointsLabel(box.fontSize)
        let figure = Text(points).monospacedDigit().foregroundStyle(Color.ink)
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
        .accessibilityValue(Text(points))
        .accessibilityIdentifier("editor.text.size.value")
    }

    /// The four named sizes, in points where a name won't fit. None is chosen while the box's size is between them.
    private func sizes(_ box: TextBox) -> some View {
        let named = namesFit()
        return OwlLunaSegmentedPicker("Size", selection: Binding(get: { box.fontSize }, set: { size in session.updateText { $0.fontSize = size } }),
                                      options: TextBox.sizes.map(\.points), padding: Space.x2) { points in
            let name = Text(TextBox.sizes.first { $0.points == points }?.name ?? "")
            if named {
                name
            } else {
                let number = Text(Double(points), format: .number)
                number.accessibilityLabel(name).accessibilityInputLabels([number, name])
            }
        }
        .accessibilityIdentifier("editor.text.size")
    }

    /// Whether every size's name keeps its words whole on a segment's two lines, measured as the chosen segment sets it.
    private func namesFit() -> Bool {
        guard !textSize.isAccessibilitySize else { return true }
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(textSize))
        let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).pointSize, weight: .semibold)
        let room = (Self.width - 2 * Space.x4) / CGFloat(TextBox.sizes.count) - 2 * Space.x2
        return TextBox.sizes.map(\.name).allSatisfy { name in
            let words = name.split(whereSeparator: \.isWhitespace).allSatisfy {
                (String($0) as NSString).size(withAttributes: [.font: font]).width.rounded(.up) <= room
            }
            let height = (name as NSString).boundingRect(with: CGSize(width: room, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
                                                         attributes: [.font: font], context: nil).height
            return words && height <= font.lineHeight * 2 + 1
        }
    }

    private func emphasis(_ box: TextBox) -> some View {
        HStack(spacing: 0) {
            ForEach(TextEmphasis.allCases) { emphasis in
                let on = box[keyPath: emphasis.path]
                Button { session.updateText { $0[keyPath: emphasis.path].toggle() } } label: {
                    Label(emphasis.title, systemImage: emphasis.rawValue)
                        .labelStyle(.iconOnly)
                        .font(.body.weight(on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.ink : Color.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .background { if on { SegmentThumb() } }
                        .contentShape(Rectangle())
                        .contentShape(.hoverEffect, RoundedRectangle.thumb.inset(by: 4))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("editor.text.\(emphasis.rawValue)")
            }
        }
        .background { Color.clear.well(in: RoundedRectangle.track) }
        .fixedSize()
    }

    /// A list keeps to the left, so turning one of the others on takes the list away.
    private func alignment(_ box: TextBox) -> some View {
        OwlLunaSegmentedPicker("Alignment", selection: Binding(get: { box.list == nil ? box.alignment : .leading }, set: { alignment in
            session.updateText {
                $0.alignment = alignment
                if alignment != .leading { $0.list = nil }
            }
        }), options: TextBox.Alignment.allCases) {
            Label($0.displayName, systemImage: $0.symbol).labelStyle(.iconOnly)
        }
        .accessibilityIdentifier("editor.text.alignment")
    }

    /// Shown as they will look on the page, over its paper.
    private func colours(_ box: TextBox) -> some View {
        let onDark = session.inkIsLight || session.paperIsNight
        let paper = Color(uiColor: session.inkIsLight ? PageRenderer.paperColor(.charcoal) : PageRenderer.paperColor(.white, night: session.paperIsNight))
        return HStack(spacing: Space.x4) {
            blot(box, onDark: onDark, paper: paper)
            VStack(alignment: .leading, spacing: Space.x1) {
                heading("Text Colour")
                PaletteStrip(title: "Text Colour", selection: box.tint, options: TextBox.Tint.allCases, paper: paper, name: \.displayName,
                             identifier: { "editor.text.colour.\($0.rawValue)" }, color: { Color(uiColor: $0.color(onDark: onDark)) }) { tint in
                    session.updateText { $0.tint = tint }
                }
                heading("Highlight Colour")
                PaletteStrip(title: "Highlight Colour", selection: box.highlight, options: [nil] + TextBox.Highlight.allCases.map(Optional.some), paper: paper,
                             name: { $0?.displayName ?? String(localized: "No Highlight") },
                             identifier: { "editor.text.highlight.\($0?.rawValue ?? "none")" },
                             color: { $0.map { Color(uiColor: $0.color(onDark: onDark)) } }) { highlight in
                    session.updateText { $0.highlight = highlight }
                }
            }
        }
    }

    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

    /// The box's words as they stand on its page, in its colour over its wash.
    private func blot(_ box: TextBox, onDark: Bool, paper: Color) -> some View {
        var sample = box
        sample.fontSize = 22
        return Text(verbatim: "Aa")
            .font(Font(sample.font()))
            .underline(box.isUnderlined)
            .foregroundStyle(Color(uiColor: box.tint.color(onDark: onDark)))
            .padding(.horizontal, 2)
            .background { if let highlight = box.highlight { Color(uiColor: highlight.color(onDark: onDark)) } }
            .frame(width: 56, height: 56)
            .background(paper, in: RoundedRectangle.plate)
            .plate(in: RoundedRectangle.plate)
            .accessibilityHidden(true)
    }
}

/// The palette laid along a strip with a square knob on the chosen colour, the way a pen's own ink is mixed. A tap
/// picks a colour; the knob can also be slid along, and picks where it is let go.
private struct PaletteStrip<Value: Hashable>: View {
    let title: LocalizedStringKey
    let selection: Value
    let options: [Value]
    let paper: Color
    let name: (Value) -> String
    let identifier: (Value) -> String
    /// Nil for none, which the strip shows struck through.
    let color: (Value) -> Color?
    let choose: (Value) -> Void
    @State private var sliding: Value?
    @State private var width: CGFloat = 0
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shown = sliding ?? selection
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button { choose(option) } label: {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay { if option == shown { StripKnob() } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(name(option)))
                .accessibilityAddTraits(option == selection ? .isSelected : [])
                .accessibilityIdentifier(identifier(option))
            }
        }
        .background { band.frame(height: 16) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 6)
            .onChanged { sliding = option(at: $0.location.x) }
            .onEnded { drag in
                let picked = option(at: drag.location.x)
                sliding = nil
                if picked != selection { choose(picked) }
            })
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private func option(at x: CGFloat) -> Value {
        let index = Int((x / max(width, 1) * CGFloat(options.count)).rounded(.down))
        return options[min(max(index, 0), options.count - 1)]
    }

    private var band: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                if let fill = color(option) {
                    fill
                } else {
                    Color.clear.overlay {
                        GeometryReader { proxy in
                            Path { path in
                                path.move(to: CGPoint(x: proxy.size.width * 0.3, y: proxy.size.height))
                                path.addLine(to: CGPoint(x: proxy.size.width * 0.7, y: 0))
                            }
                            .stroke(Color.tomato, lineWidth: 1.5)
                        }
                    }
                }
            }
        }
        .background(paper)
        .clipShape(RoundedRectangle.thumb)
        .overlay { RoundedRectangle.thumb.strokeBorder(plateEdge(contrast), lineWidth: 1) }
    }
}

/// A kind of list as an icon. The dashes are drawn here, longer than the symbol's, which are too near its bullets to tell apart.
struct ListIcon: View {
    let list: TextBox.List?

    var body: some View {
        if list == .dash {
            Image(systemName: TextBox.List.bullet.symbol)
                .hidden()
                .overlay { DashedLines().fill().flipsForRightToLeftLayoutDirection(true) }
        } else {
            Image(systemName: list?.symbol ?? "text.alignleft")
        }
    }

    private struct DashedLines: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let marks = rect.insetBy(dx: rect.width * 0.1, dy: 0)
            let thick = max(rect.height * 0.11, 1), dash = marks.width * 0.27, words = marks.width * 0.42
            for row in [0.16, 0.5, 0.84] {
                let y = marks.minY + marks.height * row - thick / 2, round = CGSize(width: thick / 2, height: thick / 2)
                path.addRoundedRect(in: CGRect(x: marks.minX, y: y, width: dash, height: thick), cornerSize: round)
                path.addRoundedRect(in: CGRect(x: marks.minX + words, y: y, width: marks.width - words, height: thick), cornerSize: round)
            }
            return path
        }
    }
}

/// What a segment that is on stands on, as `OwlLunaSegmentedPicker` draws its chosen one.
struct SegmentThumb: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle.thumb
        Color.clear
            .board(in: shape)
            .overlay { if scheme == .dark { shape.fill(Color.ink.opacity(0.10)) } }
            .overlay { if contrast == .increased { shape.strokeBorder(Color.inkSecondary, lineWidth: 1) } }
            .padding(4)
    }
}
