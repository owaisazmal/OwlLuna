import SwiftUI
import QuartzCore
import PencilKit

#if DEBUG
/// Test-only frame pacing: counts frames that took longer than 1.5× the display's target interval.
/// A simulator proxy for hitches, which XCTest can't measure there. Enabled with `-framePacing`.
@MainActor
final class FramePacingProbe: NSObject {
    static let shared = FramePacingProbe()

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var long = 0
    private var worst: CFTimeInterval = 0
    private var hitch: CFTimeInterval = 0
    private var elapsed: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        link = .running(self, #selector(tick(_:)))
    }

    func reset() {
        last = 0; frames = 0; long = 0; worst = 0; hitch = 0; elapsed = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let expected = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        let delta = link.timestamp - last
        guard delta < 1 else { return }
        frames += 1
        elapsed += delta
        worst = max(worst, delta)
        if delta > expected * 1.5 {
            long += 1
            hitch += delta - expected
        }
    }

    var summary: String {
        let ratio = elapsed > 0 ? hitch * 1000 / elapsed : 0
        return String(format: "frames=%d long=%d worst=%.1fms hitchRatio=%.1fms/s", frames, long, worst * 1000, ratio)
    }
}

/// Buttons and a readout in their own window above everything, so UI tests can reach them over sheets and the editor.
@MainActor
final class FramePacingWindow {
    static var window: UIWindow?

    static func install() {
        guard window == nil, let scene = UIApplication.shared.appWindowScenes.first else { return }
        let label = UILabel()
        label.accessibilityIdentifier = "debug.framePacing.summary"
        label.font = .systemFont(ofSize: 8)
        label.alpha = 0.3
        let reset = UIButton(type: .system, primaryAction: UIAction(title: "reset") { _ in FramePacingProbe.shared.reset(); label.text = "" })
        reset.accessibilityIdentifier = "debug.framePacing.reset"
        let read = UIButton(type: .system, primaryAction: UIAction(title: "read") { _ in label.text = FramePacingProbe.shared.summary })
        read.accessibilityIdentifier = "debug.framePacing.read"
        let auto = UIButton(type: .system, primaryAction: UIAction(title: "autoscroll") { _ in
            label.text = ""
            AutoScroller.run { label.text = FramePacingProbe.shared.summary }
        })
        auto.accessibilityIdentifier = "debug.framePacing.autoscroll"
        window = PassThroughWindow.strip([reset, read, auto, label], width: 320, on: scene)
        FramePacingProbe.shared.start()
    }
}

/// Scrolls the largest scroll view on screen down and back at a steady speed, driven by a display link,
/// so frame pacing is measured without XCUITest touching the app mid-run.
@MainActor
final class AutoScroller: NSObject {
    private static var current: AutoScroller?
    private var link: CADisplayLink?
    private weak var scrollView: UIScrollView?
    private var start: CFTimeInterval = 0
    private var origin: CGFloat = 0
    private let duration: CFTimeInterval = 6
    private let speed: CGFloat = 2400
    private var completion: (() -> Void)?

    static func run(completion: @escaping () -> Void) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).filter { $0.windowLevel == .normal }
        let scrollViews = windows.flatMap { allScrollViews(in: $0) }.filter { $0.window != nil && $0.contentSize.height > $0.bounds.height }
        guard let target = scrollViews.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return completion() }
        let scroller = AutoScroller()
        scroller.scrollView = target
        scroller.origin = target.contentOffset.y
        scroller.completion = completion
        current = scroller
        FramePacingProbe.shared.reset()
        scroller.link = .running(scroller, #selector(step(_:)))
    }

    private static func allScrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? [] + view.subviews.flatMap(allScrollViews)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView else { return finish() }
        if start == 0 { start = link.timestamp }
        let t = link.timestamp - start
        guard t < duration else { return finish() }
        let half = duration / 2
        let distance = CGFloat(t < half ? t : duration - t) * speed
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        scrollView.contentOffset.y = min(origin + distance, maxY)
    }

    private func finish() {
        link?.invalidate()
        link = nil
        completion?()
        Self.current = nil
    }
}

/// `-animationProbe <file>` writes what is animating, every two seconds while it changes, so a UI test that stalls waiting
/// for the app to go idle can say whether an animation or a scroll of the app's was still running.
@MainActor
enum AnimationProbe {
    private static var timer: Timer?
    private static var last: String?

    static func install() {
        guard timer == nil, let path = LaunchOptions.value("-animationProbe") else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { write(summary(), to: path) }
        }
    }

    /// Every layer in the app's windows that has an animation running, and every scroll view in motion.
    static func summary(windows: [UIWindow] = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)) -> String {
        var animations: [String] = [], scrolling: [String] = []
        func walk(_ layer: CALayer, depth: Int) {
            if let keys = layer.animationKeys(), !keys.isEmpty {
                let owner = (layer.delegate as? UIView).map { NSStringFromClass(type(of: $0)) } ?? NSStringFromClass(type(of: layer))
                animations.append("\(owner)(\(keys.joined(separator: ",")))")
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer, depth: depth + 1) }
        }
        func views(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.isDragging || scroll.isDecelerating || scroll.isZooming || scroll.isZoomBouncing {
                scrolling.append("\(NSStringFromClass(type(of: scroll)))[\(scroll.accessibilityIdentifier ?? "-")]")
            }
            for subview in view.subviews { views(subview) }
        }
        for window in windows {
            walk(window.layer, depth: 0)
            views(window)
        }
        let date = Date.now.formatted(date: .omitted, time: .standard)
        return "\(date) animations=\(animations.count) \(animations.prefix(12).joined(separator: " ")) scrolling=\(scrolling.joined(separator: " "))"
    }

    private static func write(_ line: String, to path: String) {
        let state = String(line.drop { $0 != " " })
        guard state != last else { return }
        last = state
        try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// `-secondScreenInset` stands a small window in for a second screen, so UI tests can see what one would show.
@MainActor
enum SecondScreenInset {
    static func window() -> UIWindow? {
        guard LaunchOptions.arguments.contains("-secondScreenInset"), let scene = UIApplication.shared.appWindowScenes.first else { return nil }
        let window = PassThroughWindow.overlay(on: scene)
        window.frame = CGRect(x: scene.coordinateSpace.bounds.width - 496, y: 110, width: 480, height: 270)
        window.layer.borderColor = UIColor.white.cgColor
        window.layer.borderWidth = 1
        return window
    }
}

/// `-windowButtons` stands a number and three buttons over each window and reads out only the window in front, so UI tests can open a second window and go between the two.
@MainActor
final class WindowButtons: NSObject {
    static let shared = WindowButtons()

    private var overlays: [String: UIWindow] = [:]

    func install() {
        guard LaunchOptions.arguments.contains("-windowButtons") else { return }
        if overlays.isEmpty {
            for name in [UIScene.didActivateNotification, UIScene.didEnterBackgroundNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(readOutFront), name: name, object: nil)
            }
        }
        for scene in UIApplication.shared.appWindowScenes {
            let id = scene.session.persistentIdentifier
            guard overlays[id] == nil else { continue }
            let number = UILabel()
            number.text = "\(overlays.count + 1)"
            number.font = .systemFont(ofSize: 8)
            number.accessibilityIdentifier = "debug.window.number"
            let new = UIButton(type: .system, primaryAction: UIAction(title: "new") { _ in
                UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
            })
            new.accessibilityIdentifier = "debug.window.new"
            let other = UIButton(type: .system, primaryAction: UIAction(title: "other") { [unowned self] _ in
                guard let session = others(than: id).first(where: { overlays[$0.persistentIdentifier] != nil }) else { return }
                UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil, errorHandler: nil)
            })
            other.accessibilityIdentifier = "debug.window.other"
            let close = UIButton(type: .system, primaryAction: UIAction(title: "close") { [unowned self] _ in
                for session in others(than: id) {
                    overlays[session.persistentIdentifier] = nil
                    UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
                }
            })
            close.accessibilityIdentifier = "debug.window.close"
            overlays[id] = PassThroughWindow.strip([number, new, other, close], width: 200, on: scene)
        }
        readOutFront()
    }

    private func others(than id: String) -> [UISceneSession] {
        UIApplication.shared.openSessions.filter { $0.role == .windowApplication && $0.persistentIdentifier != id }
    }

    @objc private func readOutFront() {
        for scene in UIApplication.shared.appWindowScenes {
            for window in scene.windows { window.accessibilityElementsHidden = scene.activationState != .foregroundActive }
        }
    }
}

private final class PassThroughWindow: UIWindow {
    /// A window above everything, touched only through its buttons.
    static func overlay(on scene: UIWindowScene) -> PassThroughWindow {
        let window = PassThroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        return window
    }

    /// A faint row of debug controls along the foot of `scene`, shown in an overlay window.
    static func strip(_ views: [UIView], width: CGFloat, on scene: UIWindowScene) -> PassThroughWindow {
        let window = overlay(on: scene)
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        let stack = UIStackView(arrangedSubviews: views)
        stack.alpha = 0.3
        stack.spacing = 4
        stack.frame = CGRect(x: 8, y: scene.coordinateSpace.bounds.height - 40, width: width, height: 28)
        stack.autoresizingMask = [.flexibleTopMargin]
        controller.view.addSubview(stack)
        window.rootViewController = controller
        window.isHidden = false
        return window
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view is UIButton || view?.superview is UIButton ? view : nil
    }
}

private extension UIApplication {
    /// The scenes of the app's own windows, leaving out a second screen's.
    var appWindowScenes: [UIWindowScene] {
        connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.session.role == .windowApplication }
    }
}

private extension CADisplayLink {
    /// A link asking for up to 120 Hz, already running on the main run loop.
    @MainActor
    static func running(_ target: Any, _ selector: Selector) -> CADisplayLink {
        let link = CADisplayLink(target: target, selector: selector)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        return link
    }
}
#endif
