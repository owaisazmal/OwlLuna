import SwiftUI
import PencilKit

/// The tools, on one board at the foot of the editor: the pens with their inks, the eraser, the lasso, and the
/// shortcuts chosen to stand beside them. It floats over the desk and takes nothing from the page's width; the page
/// stack leaves room under the last page for it.
struct ToolTray: View {
    let session: EditorSession
    /// The width of the pane the tray stands in.
    let room: CGFloat
    /// Down the vertical bar of a folded iPhone Duo the tray is a column of the pens, the eraser and the lasso.
    var vertical = false
    let use: (ToolExtra) -> Void
    @State private var toolbox = Toolbox.shared
    @State private var hidden: Edge.Set = []
    @State private var editing: UUID?
    @State private var editingEraser = false
    @State private var customising = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 48
    /// What is left under the tray, above the home indicator's margin or the zoom window.
    static let gap = Space.x2
    static let slot: CGFloat = 38
    static let button: CGFloat = 44
    private static let inset = Space.x2
    private static let rule: CGFloat = 17
    private static let margin = Space.x4
    private static let fade: CGFloat = 20

    /// How a tray is shared out: the width its pens get, in which they scroll if it is short, and how many shortcuts show.
    struct Plan: Equatable {
        var pens: CGFloat
        var extras: Int
    }

    /// The eraser, the lasso and the customise menu always show. Shortcuts give way, the last first, until three pens fit.
    static func plan(pens: Int, extras: Int, room: CGFloat) -> Plan {
        let need: CGFloat = CGFloat(pens + (pens < ToolShelf.limit ? 1 : 0)) * slot
        let fixed: CGFloat = button * 3 + rule * 2 + inset * 2
        let space: CGFloat = room - margin * 2 - fixed
        var shown = extras
        while shown > 0, space - CGFloat(shown) * button < min(need, slot * 3) { shown -= 1 }
        return Plan(pens: max(min(need, space - CGFloat(shown) * button), slot), extras: shown)
    }

    /// The strip of shapes keeps within the pane while the tray does, its buttons narrowing as far as their wells when they must.
    static func shapeButton(room: CGFloat) -> CGFloat {
        min(button, max(ToolSwatch.side, (room - margin * 2 - rule - inset * 2) / CGFloat(ShapeKind.allCases.count + 1)))
    }

    var body: some View {
        if vertical { column } else { tray }
    }

    /// The pens scroll when the column is too short for them all.
    private var column: some View {
        let pens = toolbox.shelf.usable
        let rows = CGFloat(pens.count + (toolbox.shelf.isFull ? 0 : 1))
        return VStack(spacing: 0) {
            penRow(pens, axis: .vertical)
                .frame(maxHeight: rows * Self.slot)
            Rectangle().fill(Color.hairline).frame(width: 24, height: 1).padding(.vertical, Space.x1)
            eraserButton
            lassoButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tools"))
        .accessibilityIdentifier("editor.tools.tray")
    }

    @ViewBuilder
    private var tray: some View {
        let pens = toolbox.shelf.usable
        let extras = ToolExtra.allCases.filter(toolbox.extras.contains)
        let plan = Self.plan(pens: pens.count, extras: extras.count, room: room)
        // Pens that all fit have no edge to fade at, whatever the scroll view last said: its word on a first
        // layout, when the tray has no width yet, isn't always taken back.
        let scrolls = plan.pens < CGFloat(pens.count + (toolbox.shelf.isFull ? 0 : 1)) * Self.slot - 0.5
        HStack(spacing: 0) {
            penRow(pens)
                .frame(width: plan.pens, height: Self.button)
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(scrolls && hidden.contains(.leading) ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.fade)
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(scrolls && hidden.contains(.trailing) ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.fade)
                    }
                }
            rule
            eraserButton
            lassoButton
            rule
            ForEach(extras.prefix(plan.extras)) { extraButton($0) }
            customiseButton
        }
        .padding(.horizontal, Self.inset)
        .frame(height: Self.height)
        .board(in: RoundedRectangle.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tools"))
        .accessibilityIdentifier("editor.tools.tray")
        .overlay(alignment: .top) {
            Group {
                if toolbox.shape != nil { ShapeStrip(session: session, toolbox: toolbox, button: Self.shapeButton(room: room)).transition(.opacity) }
            }
            .alignmentGuide(.top) { $0[.bottom] + Space.x2 }
        }
        .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: toolbox.shape == nil)
    }

    private var rule: some View {
        Rectangle().fill(Color.hairline).frame(width: 1, height: 24).padding(.horizontal, Space.x2)
    }

    // MARK: Pens

    private func penRow(_ pens: [ToolPreset], axis: Axis = .horizontal) -> some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return ScrollViewReader { proxy in
            ScrollView(axis == .horizontal ? .horizontal : .vertical) {
                layout {
                    ForEach(Array(pens.enumerated()), id: \.element.id) { index, pen in
                        penButton(pen, at: index, of: pens.count).id(pen.id)
                    }
                    if !toolbox.shelf.isFull {
                        Button(action: addPen) { Label("New Pen", systemImage: "plus") }
                            .buttonStyle(NewPenButtonStyle(turned: vertical))
                            .accessibilityHint(Text("Adds a pen like the one in hand, in another colour"))
                            .accessibilityIdentifier("editor.tools.add")
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: axis == .horizontal ? .horizontal : .vertical)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Edge.Set.self) { geometry in
                // A tray with no width yet has no edges to report.
                guard room > 0, axis == .horizontal else { return [] }
                let x = geometry.contentOffset.x, end = geometry.contentSize.width - geometry.containerSize.width
                return (x > 1 ? Edge.Set.leading : []).union(x < end - 1 ? .trailing : [])
            } action: { _, edges in hidden = edges }
            .onChange(of: toolbox.choice) { _, choice in
                guard case .pen(let id) = choice else { return }
                withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) { proxy.scrollTo(id) }
            }
            .onChange(of: pens.map(\.id)) {
                guard case .pen(let id) = toolbox.choice else { return }
                withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) { proxy.scrollTo(id) }
            }
        }
    }

    private func penButton(_ pen: ToolPreset, at index: Int, of count: Int) -> some View {
        let inHand = toolbox.choice == .pen(pen.id)
        // The pen in hand opens; any other is taken up.
        return Button { if inHand { editing = pen.id } else { take(.pen(pen.id), named: pen.name) } } label: {
            ToolSwatch(preset: pen, inUse: inHand, onDark: session.inkIsLight, turned: session.paperIsNight)
        }
        .buttonStyle(ToolSwatchButtonStyle(turned: vertical))
        .panel("Pen Options", isPresented: Binding(get: { editing == pen.id }, set: { if !$0, editing == pen.id { editing = nil } })) {
            ScrollView { PenOptions(id: pen.id, toolbox: toolbox, onDark: session.inkIsLight, turned: session.paperIsNight) { remove(pen) } }
                .scrollBounceBehavior(.basedOnSize)
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in change(pen) })
        .accessibilityLabel(Text(pen.name))
        .accessibilityValue(pen.opacity < 1 ? Text("Width \(pen.width.formatted(.number.precision(.fractionLength(0...1)))), opacity \(pen.opacityName)")
                                            : Text("Width \(pen.width.formatted(.number.precision(.fractionLength(0...1))))"))
        .accessibilityAddTraits(inHand ? .isSelected : [])
        .accessibilityActions {
            Button("Change Pen") { change(pen) }
            if index > 0 { Button(vertical ? "Move Up" : "Move Left") { toolbox.shelf.move(pen.id, by: -1) } }
            if index < count - 1 { Button(vertical ? "Move Down" : "Move Right") { toolbox.shelf.move(pen.id, by: 1) } }
            if count > 1 { Button("Remove") { remove(pen) } }
        }
        .accessibilityShowsLargeContentViewer { Label(pen.name, systemImage: pen.symbol) }
        .accessibilityIdentifier("editor.tools.\(index + 1)")
    }

    private func take(_ choice: ToolChoice, named name: String) {
        toolbox.take(choice)
        UISelectionFeedbackGenerator().selectionChanged()
        AccessibilityNotification.Announcement(name).post()
    }

    /// Takes a pen up and opens its options, where it is also moved along the tray or taken off it.
    private func change(_ pen: ToolPreset) {
        guard editing != pen.id else { return }
        toolbox.take(.pen(pen.id))
        UISelectionFeedbackGenerator().selectionChanged()
        editing = pen.id
    }

    /// The new pen opens, so its colour can be chosen straight away.
    private func addPen() {
        guard let id = toolbox.addPen() else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            editing = id
        }
    }

    private func remove(_ pen: ToolPreset) {
        if editing == pen.id { editing = nil }
        toolbox.removePen(pen.id)
        AccessibilityNotification.Announcement(String(localized: "\(pen.name) removed from the tools")).post()
    }

    // MARK: Eraser, lasso and shortcuts

    private var eraserButton: some View {
        let inHand = toolbox.choice == .eraser
        return Button { if inHand { editingEraser = true } else { take(.eraser, named: String(localized: "Eraser")) } } label: {
            Label("Eraser", systemImage: "eraser")
        }
        .buttonStyle(TrayIconStyle(isOn: inHand))
        .panel("Eraser", isPresented: $editingEraser) {
            ScrollView { EraserOptions(toolbox: toolbox) }
                .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityValue(Text(toolbox.eraser.kind.displayName))
        .accessibilityAddTraits(inHand ? .isSelected : [])
        .accessibilityIdentifier("editor.tools.eraser")
    }

    private var lassoButton: some View {
        let inHand = toolbox.choice == .lasso
        return Button { take(.lasso, named: String(localized: "Lasso")) } label: { Label("Lasso", systemImage: "lasso") }
            .buttonStyle(TrayIconStyle(isOn: inHand))
            .accessibilityAddTraits(inHand ? .isSelected : [])
            .accessibilityIdentifier("editor.tools.lasso")
    }

    private func extraButton(_ extra: ToolExtra) -> some View {
        let isOn = switch extra {
        case .ruler: toolbox.isRulerActive
        case .zoomWindow: session.isZoomWindowOpen
        case .typing: toolbox.typesHandwriting
        case .shapes: toolbox.shape != nil
        default: false
        }
        return Button { use(extra) } label: { Label(extra.title, systemImage: extra.symbol) }
            .buttonStyle(TrayIconStyle(isOn: isOn))
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .accessibilityIdentifier("editor.tools.extra.\(extra.rawValue)")
    }

    private var customiseButton: some View {
        Button { customising = true } label: { Label("Customise Tools", systemImage: "slider.horizontal.3") }
            .buttonStyle(TrayIconStyle(isOn: customising))
            .panel("Customise Tools", isPresented: $customising) {
                ScrollView { ShortcutOptions(toolbox: toolbox) }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .accessibilityIdentifier("editor.tools.customise")
    }
}

/// The shapes a drag on the page draws, on a strip over the tray, with Undo at its end. The shape picked wears the
/// frame the tool in hand does.
private struct ShapeStrip: View {
    let session: EditorSession
    let toolbox: Toolbox
    let button: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ShapeKind.allCases) { kind in
                let chosen = toolbox.shape == kind
                Button { pick(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    .buttonStyle(TrayIconStyle(isOn: chosen, width: button))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .accessibilityIdentifier("editor.tools.shape.\(kind.rawValue)")
            }
            Rectangle().fill(Color.hairline).frame(width: 1, height: 24).padding(.horizontal, Space.x2)
            Button { session.document.undoManager.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .buttonStyle(TrayIconStyle(width: button))
                .disabled(!session.canUndo)
                .accessibilityIdentifier("editor.tools.shapes.undo")
        }
        .padding(.horizontal, Space.x2)
        .frame(height: ToolTray.height)
        .board(in: RoundedRectangle.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Shapes"))
        .accessibilityIdentifier("editor.tools.shapes")
    }

    private func pick(_ kind: ShapeKind) {
        guard toolbox.shape != kind else { return }
        toolbox.pick(kind)
        UISelectionFeedbackGenerator().selectionChanged()
        AccessibilityNotification.Announcement(kind.title).post()
    }
}

private struct NewPenButtonStyle: ButtonStyle {
    var turned = false

    func makeBody(configuration: Configuration) -> some View {
        Icon(configuration: configuration, turned: turned)
    }

    private struct Icon: View {
        let configuration: Configuration
        let turned: Bool
        @Environment(\.accessibilityShowBorders) private var showBorders

        /// An empty label waiting for a pen, so it isn't taken for the bar's Add.
        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(width: ToolSwatch.side, height: ToolSwatch.side)
                .background { if configuration.isPressed || showBorders { ToolSwatch.shape.fill(Color.well) } }
                .overlay {
                    ToolSwatch.shape.strokeBorder(Color.ink.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .frame(width: turned ? ToolTray.button : ToolTray.slot, height: turned ? ToolTray.slot : ToolTray.button)
                .contentShape(Rectangle())
                .contentShape(.hoverEffect, RoundedRectangle.plate.inset(by: 1))
                .hoverEffect(.highlight)
                .accessibilityShowsLargeContentViewer { configuration.label.labelStyle(.titleAndIcon) }
        }
    }
}
