import SwiftUI

/// On the Mac the window has no title bar of its own: the app's top bar is the top of the window, beside the traffic lights.
final class MacWindowSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        #if targetEnvironment(macCatalyst)
        guard let titlebar = (scene as? UIWindowScene)?.titlebar else { return }
        // No toolbar, so nothing is left at the top but the traffic lights. Any toolbar, even an empty one,
        // would take every click in the top 30 pt, where the bars' buttons are.
        titlebar.titleVisibility = .hidden
        titlebar.toolbar = nil
        #endif
    }
}

enum MacTitlebar {
    /// Whether the app's top bars are the top of the window, as they are on a Mac.
    static var barsRise: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
    /// A UIKit bar at the top of a window keeps about this much above its buttons. A header of the app's own beside it
    /// keeps the same, so their buttons line up.
    static var headerTopPadding: CGFloat { barsRise ? 9 : 0 }
    /// Where a bar's first item starts, past the traffic lights, less the margin the bar keeps anyway.
    fileprivate static let lightsEnd: CGFloat = 79
    /// Above this, a view starts at the top of the window, where the traffic lights are.
    fileprivate static let lightsBottom: CGFloat = 40
    /// Where the bars' buttons are centred, down from the top of the window, and the traffic lights with them.
    fileprivate static let buttonsCentre: CGFloat = 31.5
}

extension EnvironmentValues {
    /// Whether this window shows the traffic lights over the app's top bar, as a Mac window does out of full screen.
    @Entry var showsTrafficLights = false
    /// How far the first item of the bar on show moves in to clear the traffic lights.
    @Entry var trafficLightsRoom: CGFloat = 0
}

extension View {
    /// On the Mac, the top bars of this view rise into the window's title bar. For the window's own view and a cover over it.
    func risesIntoTitlebar() -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(TitlebarRise())
        #else
        self
        #endif
    }

    /// Works out from where this view starts in the window whether the traffic lights cover the start of its top bar.
    func makesRoomForTrafficLights() -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(TrafficLightsRoom())
        #else
        self
        #endif
    }

    /// Moves the start of a top row of the app's own in, clear of the traffic lights.
    func clearsTrafficLights() -> some View {
        modifier(TrafficLightsClearance())
    }
}

/// A bar's first item, empty, that keeps the items after it clear of the traffic lights. A bar draws its buttons itself,
/// so they can't be moved in any other way.
struct TrafficLightsBarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { TrafficLightsGap() }
            .boardBackground()
    }
}

private struct TrafficLightsGap: View {
    @Environment(\.trafficLightsRoom) private var room

    var body: some View {
        Color.clear.frame(width: room, height: 1).accessibilityHidden(true)
    }
}

private struct TrafficLightsRoom: ViewModifier {
    @Environment(\.showsTrafficLights) private var showsLights
    @State private var start = CGPoint(x: CGFloat.infinity, y: .infinity)

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGPoint.self) { proxy in
                // A column's bar is above its frame, in the safe area, and a sidebar beside it may be in the frame or the safe area.
                let frame = proxy.frame(in: .global)
                return CGPoint(x: max(frame.minX, proxy.safeAreaInsets.leading), y: frame.minY - proxy.safeAreaInsets.top)
            } action: { start = $0 }
            .environment(\.trafficLightsRoom, showsLights && start.y < MacTitlebar.lightsBottom ? max(0, MacTitlebar.lightsEnd - start.x) : 0)
    }
}

private struct TrafficLightsClearance: ViewModifier {
    @Environment(\.trafficLightsRoom) private var room

    func body(content: Content) -> some View {
        content.padding(.leading, room)
    }
}

#if targetEnvironment(macCatalyst)
private struct TitlebarRise: ViewModifier {
    @State private var showsLights = false

    func body(content: Content) -> some View {
        content
            .environment(\.showsTrafficLights, showsLights)
            .background(TitlebarWatch { showsLights = $0 }.frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// Takes the title bar's room out of the controller this view is in, the window's or one covering it, so its bars go to the top.
private struct TitlebarWatch: UIViewRepresentable {
    let onLights: (Bool) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.watcher.onLights = onLights
        return probe
    }

    func updateUIView(_ view: Probe, context: Context) { view.watcher.onLights = onLights }

    final class Probe: UIView {
        let watcher = Watcher()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else {
                watcher.lights = nil
                watcher.removeFromSuperview()
                return
            }
            var controller = sequence(first: self as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController
            while let parent = controller?.parent { controller = parent }
            watcher.controller = controller
            watcher.frame = window.bounds
            window.insertSubview(watcher, at: 0)
            watcher.update()
        }
    }

    /// Sits behind everything in the window to hear when the title bar's room changes, as it does in and out of full screen.
    final class Watcher: UIView {
        weak var controller: UIViewController?
        var onLights: ((Bool) -> Void)?
        var lights: TrafficLights?
        private var showsLights: Bool?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }

        required init?(coder: NSCoder) { nil }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            update()
        }

        func update() {
            guard let window, let controller else { return }
            let titlebar = window.safeAreaInsets.top
            if controller.additionalSafeAreaInsets.top != -titlebar { controller.additionalSafeAreaInsets.top = -titlebar }
            if titlebar > 0, lights == nil { lights = TrafficLights(window) }
            lights?.place()
            guard showsLights != (titlebar > 0) else { return }
            showsLights = titlebar > 0
            let onLights = onLights, shows = titlebar > 0
            DispatchQueue.main.async { onLights?(shows) }
        }
    }
}
/// AppKit sets the traffic lights where its own title bar would centre them, higher than the bars' buttons. This moves
/// them down level with the buttons, and again each time AppKit puts them back, as it does when the window resizes or
/// becomes active. AppKit isn't linked into an app built with Mac Catalyst, so the window and its buttons are reached by name.
@MainActor
final class TrafficLights {
    private typealias ButtonFunction = @convention(c) (AnyObject, Selector, Int) -> AnyObject?
    private typealias OriginFunction = @convention(c) (AnyObject, Selector, CGPoint) -> Void

    private weak var window: UIWindow?
    private let appKitWindow: NSObject
    private var observers: [any NSObjectProtocol] = []

    init?(_ window: UIWindow) {
        guard let frame = window.windowScene?.effectiveGeometry.systemFrame, let appKitWindow = Self.appKitWindow(at: frame) else { return nil }
        self.window = window
        self.appKitWindow = appKitWindow
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Notification.Name("NSViewFrameDidChangeNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
        for name in ["NSWindowDidBecomeKeyNotification", "NSWindowDidResignKeyNotification", "NSWindowDidBecomeMainNotification",
                     "NSWindowDidResignMainNotification", "NSWindowDidResizeNotification", "NSWindowDidExitFullScreenNotification"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: appKitWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.place()
                    DispatchQueue.main.async { self?.place() }
                }
            })
        }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The AppKit window with the same frame as the scene's. AppKit counts up from the foot of the first screen, UIKit down from its top.
    private static func appKitWindow(at frame: CGRect) -> NSObject? {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
              let windows = app.value(forKey: "windows") as? [NSObject],
              let screens = (NSClassFromString("NSScreen") as? NSObject.Type)?.value(forKey: "screens") as? [NSObject],
              let screenHeight = (screens.first?.value(forKey: "frame") as? NSValue)?.cgRectValue.height else { return nil }
        let flipped = CGRect(x: frame.minX, y: screenHeight - frame.maxY, width: frame.width, height: frame.height)
        return windows.first { ($0.value(forKey: "frame") as? NSValue)?.cgRectValue == flipped }
    }

    func place() {
        guard let window, window.bounds.height > 0,
              let styleMask = appKitWindow.value(forKey: "styleMask") as? UInt, styleMask & (1 << 14) == 0,
              let frame = (appKitWindow.value(forKey: "frame") as? NSValue)?.cgRectValue else { return }
        let centre = MacTitlebar.buttonsCentre * frame.height / window.bounds.height
        let buttonSelector = NSSelectorFromString("standardWindowButton:")
        let originSelector = NSSelectorFromString("setFrameOrigin:")
        let button = unsafeBitCast(appKitWindow.method(for: buttonSelector), to: ButtonFunction.self)
        for kind in 0...2 {
            guard let button = button(appKitWindow, buttonSelector, kind) as? NSObject,
                  let bar = button.value(forKey: "superview") as? NSObject,
                  let size = (bar.value(forKey: "frame") as? NSValue)?.cgRectValue.size,
                  let own = (button.value(forKey: "frame") as? NSValue)?.cgRectValue else { continue }
            let top = centre - own.height / 2
            let y = ((bar.value(forKey: "flipped") as? Bool) == true ? top : size.height - top - own.height).rounded()
            guard abs(own.minY - y) > 0.25 else { continue }
            unsafeBitCast(button.method(for: originSelector), to: OriginFunction.self)(button, originSelector, CGPoint(x: own.minX, y: y))
        }
    }
}
#endif
