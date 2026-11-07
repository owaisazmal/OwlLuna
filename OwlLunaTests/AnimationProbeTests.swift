import XCTest
@testable import OwlLuna

/// The animation probe names what is still moving when a UI test stalls waiting for the app to go idle.
@MainActor
final class AnimationProbeTests: XCTestCase {
    func testTheSummaryNamesRunningAnimationsAndScrollViewsInMotion() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let scroll = UIScrollView(frame: window.bounds)
        scroll.accessibilityIdentifier = "probe.scroll"
        scroll.contentSize = CGSize(width: 400, height: 4000)
        let box = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        scroll.addSubview(box)
        window.addSubview(scroll)
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }

        XCTAssertTrue(AnimationProbe.summary(windows: [window]).contains("animations=0"), "nothing moves yet")

        let spin = CABasicAnimation(keyPath: "transform.rotation")
        spin.duration = 10
        spin.repeatCount = .infinity
        box.layer.add(spin, forKey: "probe.spin")
        let summary = AnimationProbe.summary(windows: [window])
        XCTAssertTrue(summary.contains("animations=1 UIView(probe.spin)"), summary)
        XCTAssertFalse(summary.contains("probe.scroll"), "a scroll view at rest isn't scrolling")
    }
}
