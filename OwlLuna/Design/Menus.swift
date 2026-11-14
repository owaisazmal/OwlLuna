import SwiftUI

extension EnvironmentValues {
    @Entry fileprivate var inPanelMenu = false
    @Entry fileprivate var menuRowChosen = false
}

private struct MenuBreakKey: ContainerValueKey {
    static let defaultValue = false
}

extension ContainerValues {
    fileprivate var isMenuBreak: Bool {
        get { self[MenuBreakKey.self] }
        set { self[MenuBreakKey.self] = newValue }
    }
}

/// A button that opens a card of rows under it. In another menu it is a row that opens the next card beside it.
struct OwlLunaMenu<Label: View, Content: View>: View {
    private let title: Text?
    private let split: MenuSplit?
    private let primaryAction: (() -> Void)?
    private let content: Content
    private let label: Label
    @State private var isOpen = false
    @State private var held = false
    @Environment(\.inPanelMenu) private var nested

    /// The band is named after the label unless it is given a `title`. With a `primaryAction` a tap does that, and holding opens
    /// the menu; `split` cuts a chevron off the cloth button that opens it with a tap.
    init(_ title: Text? = nil, split: MenuSplit? = nil, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label,
         primaryAction: (() -> Void)? = nil) {
        self.title = title
        self.split = split
        self.primaryAction = primaryAction
        self.content = content()
        self.label = label()
    }

    var body: some View {
        trigger.modifier(PanelPresenter(isPresented: $isOpen, beside: nested, chained: nested) {
            PanelChrome(fill: .board) {
                if let title { title } else { label.labelStyle(.titleOnly) }
            } content: {
                MenuRows { content }
            }
        })
    }

    @ViewBuilder
    private var trigger: some View {
        if nested {
            Button { isOpen = true } label: { label }
                .buttonStyle(MenuRowBody(opens: true))
        } else if let primaryAction, let split {
            SplitCloth(split: split, label: label, primaryAction: primaryAction, held: $held) { isOpen = true }
                .onChange(of: isOpen) { _, open in if !open { held = false } }
        } else if let primaryAction {
            Button { if held { held = false } else { primaryAction() } } label: { label }
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    held = true
                    isOpen = true
                })
                .onChange(of: isOpen) { _, open in if !open { held = false } }
                .accessibilityAction(named: Text("Show Menu")) { isOpen = true }
        } else {
            Button { isOpen = true } label: { label }
        }
    }
}

/// Where a menu button's chevron is cut: beside the label in a bar, or below it in a vertical one. The text names the chevron.
enum MenuSplit {
    case beside(Text)
    case below(Text)
}

/// One cloth bar button cut in two: the label does its work, and the chevron opens the card. Holding the label opens it too.
private struct SplitCloth<Label: View>: View {
    let split: MenuSplit
    let label: Label
    let primaryAction: () -> Void
    @Binding var held: Bool
    let open: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let chevron: CGFloat = 26
        let (beside, name): (Bool, Text) = switch split {
        case .beside(let name): (true, name)
        case .below(let name): (false, name)
        }
        let layout = beside ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            Button { if held { held = false } else { primaryAction() } } label: {
                label
                    .padding(.horizontal, Space.x3)
                    .frame(minWidth: 44, minHeight: BarMetrics.height)
                    .frame(maxWidth: beside ? nil : .infinity, maxHeight: beside ? .infinity : nil)
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                held = true
                open()
            })
            .accessibilityAction(named: Text("Show Menu"), open)
            Rectangle()
                .fill(Color.onPrimaryCloth.opacity(0.4))
                .frame(width: beside ? 1 : nil, height: beside ? nil : 1)
                .padding(beside ? .vertical : .horizontal, Space.x2)
            Button(action: open) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .frame(width: beside ? chevron : nil, height: beside ? nil : chevron - 4)
                    .frame(maxWidth: beside ? nil : .infinity, maxHeight: beside ? .infinity : nil)
            }
            .accessibilityLabel(name)
        }
        .buttonStyle(ClothSegment())
        .font(.callout.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(isEnabled ? Color.onPrimaryCloth : Color.textSecondary)
        .frame(height: beside ? BarMetrics.height : nil)
        .fixedSize()
        .clipShape(RoundedRectangle.plate)
        .background { if isEnabled { ClothFill() } else { RoundedRectangle.plate.fill(Color.well) } }
        .contentShape([.hoverEffect, .accessibility], RoundedRectangle.plate)
        .padding(.vertical, beside ? (44 - BarMetrics.height) / 2 : 0)
        .contentShape(Rectangle())
        .modifier(BarLimit(active: true))
    }
}

/// A part of a split cloth button: pressed, it darkens on its own.
private struct ClothSegment: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background { if configuration.isPressed { Color.black.opacity(scheme == .dark ? 0.12 : 0.16) } }
            .hoverEffect(.highlight)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

extension View {
    /// Opens a card of rows when this view is touched and held. One that can be dragged opens it when it is let go.
    func heldMenu<Rows: View>(_ title: Text, when enabled: Bool = true, draggable: Bool = false,
                              @ViewBuilder rows: @escaping () -> Rows) -> some View {
        modifier(HeldMenu(title: title, enabled: enabled, draggable: draggable, rows: rows))
    }
}

private struct HeldMenu<Rows: View>: ViewModifier {
    let title: Text
    let enabled: Bool
    let draggable: Bool
    @ViewBuilder var rows: () -> Rows
    @State private var isOpen = false

    func body(content: Content) -> some View {
        content
            .background { if enabled { HoldProbe(draggable: draggable) { isOpen = true } } }
            .accessibilityActions { if enabled { Button("Show Menu") { isOpen = true } } }
            .modifier(PanelPresenter(isPresented: $isOpen) {
                PanelChrome(fill: .board) { title } content: { MenuRows { rows() } }
            })
    }
}

/// Watches its window for a touch held over it. What can be dragged opens its menu when it is let go, so a drag can begin instead.
private struct HoldProbe: UIViewRepresentable {
    let draggable: Bool
    let held: () -> Void

    func makeUIView(context: Context) -> HoldView { HoldView() }

    func updateUIView(_ view: HoldView, context: Context) {
        view.draggable = draggable
        view.held = held
    }

    final class HoldView: UIView, UIGestureRecognizerDelegate {
        var draggable = false { didSet { press.cancelsTouchesInView = !draggable } }
        var held: (() -> Void)?
        private weak var touch: UITouch?
        private lazy var press: UILongPressGestureRecognizer = {
            let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed))
            press.minimumPressDuration = 0.45
            press.delegate = self
            return press
        }()

        /// A right-click opens the menu at once, as a Mac's context menus do.
        private lazy var secondaryClick: UITapGestureRecognizer = {
            let click = UITapGestureRecognizer(target: self, action: #selector(clicked))
            click.buttonMaskRequired = .secondary
            // Only a pointer's clicks, and never at the cost of a touch meant for what lies under it.
            click.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            click.cancelsTouchesInView = false
            click.delaysTouchesEnded = false
            click.delegate = self
            return click
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            for recognizer in [press, secondaryClick] {
                recognizer.view?.removeGestureRecognizer(recognizer)
                window?.addGestureRecognizer(recognizer)
            }
        }

        @objc private func pressed() {
            guard press.state == (draggable ? .ended : .began) else { return }
            if !draggable { takeTouch() }
            held?()
        }

        @objc private func clicked() { held?() }

        /// The screen's own gestures let go of a held touch, so a button under it doesn't take its lifting for a tap.
        private func takeTouch() {
            guard let screen = hostScreen else { return }
            for other in touch?.gestureRecognizers ?? [] where other !== press && other.view?.isDescendant(of: screen) == true {
                other.isEnabled = false
                other.isEnabled = true
            }
        }

        /// A touch over this view counts only if it lands in the screen this view is on, not in one that covers it.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard bounds.contains(touch.location(in: self)) else { return false }
            if let screen = hostScreen, touch.view?.isDescendant(of: screen) != true { return false }
            self.touch = touch
            return true
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// One of a few values in a menu: a row for each, the chosen one checked.
struct OwlLunaPicker<Value: Hashable, Options: View>: View {
    private let title: Text?
    @Binding private var selection: Value
    private let options: Options

    init(_ title: LocalizedStringKey? = nil, selection: Binding<Value>, @ViewBuilder options: () -> Options) {
        self.title = title.map { Text($0) }
        self._selection = selection
        self.options = options()
    }

    var body: some View {
        Group(sections: options) { sections in
            ForEach(sections) { section in
                Section {
                    ForEach(section.content) { option in
                        let value = option.containerValues.tag(for: Value.self)
                        Button { if let value { selection = value } } label: { option }
                            .menuChosen(value == selection)
                    }
                } header: {
                    if !section.header.isEmpty { section.header } else if let title { title }
                }
            }
        }
    }
}

/// A wider rule between two runs of rows in a menu.
struct MenuBreak: View {
    var body: some View {
        Color.clear.frame(height: 0).containerValue(\.isMenuBreak, true)
    }
}

extension View {
    /// Marks a menu's row as the one in force: checked, with an accent edge.
    func menuChosen(_ chosen: Bool) -> some View { environment(\.menuRowChosen, chosen) }
}

/// A menu's rows ruled apart, with a band over each run that has a name.
private struct MenuRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Group(sections: content) { sections in
                    ForEach(sections) { section in
                        let first = section.id == sections.first?.id
                        if !section.header.isEmpty {
                            section.header
                                .sectionBand()
                                .overlay(alignment: .top) { if !first { HairlineRule() } }
                                .overlay(alignment: .bottom) { HairlineRule() }
                                .accessibilityAddTraits(.isHeader)
                        } else if !first {
                            MenuStrip()
                        }
                        let rows = Array(section.content)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            let breaks = row.containerValues.isMenuBreak
                            let afterBreak = index > 0 && rows[index - 1].containerValues.isMenuBreak
                            if breaks {
                                if index > 0, index < rows.count - 1, !afterBreak { MenuStrip() }
                            } else {
                                row.overlay(alignment: .top) { if index > 0, !afterBreak { HairlineRule() } }
                            }
                        }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(minWidth: 220, maxWidth: 380)
        .buttonStyle(MenuRowButtonStyle())
        .toggleStyle(MenuRowToggleStyle())
        .labelStyle(MenuRowLabelStyle())
        .environment(\.inPanelMenu, true)
        .environment(\.isEnabled, true)
        .fontWeight(nil)
        .dynamicTypeSize(DynamicTypeSize(UIApplication.shared.preferredContentSizeCategory) ?? .large)
    }
}

private struct MenuStrip: View {
    var body: some View {
        Color.well.frame(height: 6)
            .overlay(alignment: .top) { HairlineRule() }
            .overlay(alignment: .bottom) { HairlineRule() }
            .accessibilityHidden(true)
    }
}

/// A button in a menu closes the menu, and does its work once the menu has gone.
private struct MenuRowButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.panelClose) private var close

        var body: some View {
            Button {
                if let close { close(then: configuration.trigger) } else { configuration.trigger() }
            } label: {
                configuration.label
            }
            .buttonStyle(MenuRowBody(role: configuration.role))
        }
    }
}

private struct MenuRowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .menuChosen(configuration.isOn)
    }
}

private struct MenuRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.x3) {
            configuration.icon.frame(width: 24)
            configuration.title
        }
    }
}

private struct MenuRowBody: ButtonStyle {
    var role: ButtonRole?
    var opens = false

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, role: role, opens: opens)
    }

    private struct Row: View {
        let configuration: Configuration
        let role: ButtonRole?
        let opens: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.menuRowChosen) private var chosen

        var body: some View {
            HStack(spacing: Space.x3) {
                configuration.label
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if chosen {
                    Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
                if opens {
                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(Color.textSecondary).accessibilityHidden(true)
                }
            }
            .font(.callout.weight(chosen ? .semibold : .regular))
            .foregroundStyle(role == .destructive ? Color.tomato : Color.ink)
            .opacity(isEnabled ? 1 : 0.4)
            .padding(.horizontal, Space.x3)
            .padding(.vertical, Space.x2)
            .frame(minHeight: 44)
            .background { if configuration.isPressed { Color.well } }
            .overlay(alignment: .leading) { if chosen { Rectangle().fill(Color.accentColor).frame(width: 3) } }
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
            .accessibilityAddTraits(chosen ? .isSelected : [])
        }
    }
}
