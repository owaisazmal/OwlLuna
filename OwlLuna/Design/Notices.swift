import SwiftUI

extension View {
    /// Stands a notice in the middle of the screen while `isPresented` is true: the app's own alert. A button with the
    /// cancel role is its way out, and one that destroys turns its edge tomato.
    func notice<Fields: View, Actions: View>(_ title: Text, isPresented: Binding<Bool>, message: Text? = nil,
                                             @ViewBuilder fields: @escaping () -> Fields = { EmptyView() },
                                             @ViewBuilder actions: @escaping () -> Actions) -> some View {
        modifier(PanelPresenter(isPresented: isPresented, notice: true) {
            NoticeCard(title: title, message: message) { fields() } actions: { actions() }
        })
    }

    func notice<Actions: View>(_ title: LocalizedStringKey, isPresented: Binding<Bool>, message: Text? = nil,
                               @ViewBuilder actions: @escaping () -> Actions) -> some View {
        notice(Text(title), isPresented: isPresented, message: message, actions: actions)
    }

    /// A notice with only OK, shown while `message` holds something to say.
    func notice(_ title: LocalizedStringKey, message: Binding<String?>) -> some View {
        notice(title, isPresented: Binding(isPresent: message), message: Text(message.wrappedValue ?? "")) {
            Button("OK", role: .cancel) {}
        }
    }

    /// A notice that asks for something to be typed: its first field is ready to type in as it opens.
    func notice<Fields: View, Actions: View>(_ title: LocalizedStringKey, isPresented: Binding<Bool>, message: Text? = nil,
                                             @ViewBuilder fields: @escaping () -> Fields,
                                             @ViewBuilder actions: @escaping () -> Actions) -> some View {
        notice(Text(title), isPresented: isPresented, message: message, fields: fields, actions: actions)
    }
}

/// What a notice's buttons do, for the keys and gestures that stand for them: Return in a field, and the way out.
@MainActor
private final class NoticeKeys {
    var main: (() -> Void)?
    var cancel: (() -> Void)?
}

private struct NoticeDestroys: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension EnvironmentValues {
    @Entry fileprivate var noticeKeys: NoticeKeys?
}

extension ContainerValues {
    /// A notice's field ruled in tomato, as what was typed in it didn't work.
    @Entry fileprivate var isNoticeFieldWrong = false
    /// Shown in a notice as it is, not in a field's well.
    @Entry fileprivate var isNoticeBare = false
}

extension View {
    func noticeFieldWrong(_ wrong: Bool) -> some View { containerValue(\.isNoticeFieldWrong, wrong) }

    func noticeBare() -> some View { containerValue(\.isNoticeBare, true) }
}

/// A board with a cloth edge that says what kind of notice it is, over its words, its fields and its buttons.
private struct NoticeCard<Fields: View, Actions: View>: View {
    let title: Text
    let message: Text?
    @ViewBuilder var fields: Fields
    @ViewBuilder var actions: Actions
    @State private var destroys = false
    @State private var keys = NoticeKeys()

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(destroys ? Color.destructiveCloth : Color.primaryCloth)
                .clothWeave(in: Rectangle())
                .frame(width: 6)
            VStack(alignment: .leading, spacing: 0) {
                title
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    message
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .padding(.top, Space.x1)
                }
                Group(subviews: fields) { fields in
                    if !fields.isEmpty {
                        VStack(spacing: Space.x2) {
                            ForEach(fields) { field in
                                if field.containerValues.isNoticeBare {
                                    field
                                } else {
                                    field
                                        .textFieldStyle(.plain)
                                        .foregroundStyle(Color.ink)
                                        .padding(.horizontal, Space.x3)
                                        .frame(minHeight: 44)
                                        .well(in: RoundedRectangle.plate)
                                        .overlay {
                                            if field.containerValues.isNoticeFieldWrong {
                                                RoundedRectangle.plate.strokeBorder(Color.destructiveCloth, lineWidth: 1.5)
                                            }
                                        }
                                }
                            }
                        }
                        .padding(.top, Space.x3)
                        .submitLabel(.done)
                        .onSubmit { keys.main?() }
                        .background { FirstFieldFocus() }
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.x2) { actions }
                    VStack(alignment: .trailing, spacing: 0) { actions }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, Space.x3)
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.x4)
            .padding(.top, Space.x4)
            .padding(.bottom, Space.x3)
        }
        .frame(minWidth: 280, maxWidth: 400)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle.plate)
        .plate(in: RoundedRectangle.plate, fill: .board)
        .buttonStyle(NoticeButtonStyle())
        .environment(\.noticeKeys, keys)
        .environment(\.isEnabled, true)
        .onPreferenceChange(NoticeDestroys.self) { destroys = $0 }
        .accessibilityAction(.escape) { keys.cancel?() }
    }
}

/// Puts the caret in a notice's first field as it opens, as an alert does.
private struct FirstFieldFocus: UIViewRepresentable {
    func makeUIView(context: Context) -> Seeker { Seeker() }

    func updateUIView(_ view: Seeker, context: Context) {}

    final class Seeker: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.focus() }
        }

        private func focus() {
            guard let screen = hostScreen else { return }
            Self.field(in: screen)?.becomeFirstResponder()
        }

        private static func field(in view: UIView) -> UITextField? {
            if let field = view as? UITextField { return field }
            for child in view.subviews { if let field = field(in: child) { return field } }
            return nil
        }
    }
}

/// A notice's button does its work once the notice has gone. Cancel is a plate; what destroys is tomato cloth, and the way on cobalt.
private struct NoticeButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View { NoticeButton(configuration: configuration) }

    private struct NoticeButton: View {
        let configuration: Configuration
        @Environment(\.panelClose) private var close
        @Environment(\.noticeKeys) private var keys

        var body: some View {
            let role = configuration.role
            let press = { if let close { close(then: configuration.trigger) } else { configuration.trigger() } }
            let _ = note(press, for: role)
            Group {
                if role == .cancel {
                    Button(action: press) { configuration.label }.buttonStyle(NoticePlateStyle())
                } else {
                    Button(action: press) { configuration.label }
                        .buttonStyle(.owlLuna(role == .destructive ? .destructive : .primary, compact: true))
                }
            }
            .keyboardShortcut(role == .cancel ? .cancelAction : role == nil ? .defaultAction : nil)
            .preference(key: NoticeDestroys.self, value: role == .destructive)
        }

        private func note(_ press: @escaping () -> Void, for role: ButtonRole?) {
            if role == .cancel { keys?.cancel = press } else if role == nil { keys?.main = press }
        }
    }
}

/// The quiet button of a notice: a plate, as flat as the notice itself.
private struct NoticePlateStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.ink)
            .lineLimit(1)
            .padding(.horizontal, Space.x3)
            .frame(minWidth: 44, minHeight: 34)
            .plate(in: RoundedRectangle.plate, pressed: configuration.isPressed)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
    }
}

extension Binding where Value == Bool {
    /// True while `optional` holds a value; set to false, it clears it.
    @MainActor
    init<Wrapped>(isPresent optional: Binding<Wrapped?>) {
        self.init(get: { optional.wrappedValue != nil }, set: { if !$0 { optional.wrappedValue = nil } })
    }
}
