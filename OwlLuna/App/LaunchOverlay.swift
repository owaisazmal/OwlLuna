import SwiftUI

/// Whether the splash plays at launch: never under tests, and only for the first scene of the process.
enum LaunchAnimation {
    @MainActor private static var claimed = false

    static func isEnabled(arguments: [String], underTest: Bool, firstScene: Bool) -> Bool {
        firstScene && !underTest && !arguments.contains("-storageRoot") && !arguments.contains("-skipLaunchAnimation")
    }

    /// True once per process; a second window starts with the library as it is.
    @MainActor static var isEnabled: Bool {
        let first = !claimed
        claimed = true
        return isEnabled(arguments: LaunchOptions.arguments, underTest: NSClassFromString("XCTestCase") != nil, firstScene: first)
    }
}

/// The splash as the library under it knows it. Nothing is shown from under the splash: whatever is waiting asks, which sends the splash away at once.
@MainActor @Observable
final class LaunchCurtain {
    /// The splash is over the window.
    var isUp = false
    /// Something is waiting to be shown: a splash that is up goes as soon as the app is ready, and one not yet up stays down.
    private(set) var isHurried = false

    func hurry() { isHurried = true }

    /// True while the caller has to wait for the splash to go; asking is what hurries it.
    func holds() -> Bool {
        if isUp { hurry() }
        return isUp
    }
}

/// The splash over the paper while the app starts; once it has played and the app is ready, its tiles peel off the library.
struct LaunchOverlay: View {
    let isReady: Bool
    /// Something is waiting to be shown: the splash leaves as soon as the app is ready, and its tiles never come in if none has been seen yet.
    var isHurried = false
    /// The tiles are about to leave, so the library has to be there under them; `onFinished` follows once the last has gone.
    let onHandOver: () -> Void
    /// The splash has gone; a hurried one that nobody saw ends here without having handed over.
    let onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = SplashClock(time: 0)
    @State private var lastFrame: Date?
    @State private var finished = false
    @State private var ready = false
    @State private var stillOpacity = 0.0
    @State private var stillShown = false
    @State private var stillHolding = false

    /// A late frame moves the splash on by no more than this many milliseconds, so a busy main thread at start-up holds it up rather than skipping it ahead.
    static let longestStep = 50.0
    /// For this many milliseconds the first tile is still off the window, and a hurried splash can go without having been seen.
    static let unseen = 60.0
    /// With Reduce Motion the splash is a still: the seconds it stays, and the seconds it takes to fade out as the library fades in.
    static let stillDuration = 1.45
    static let stillFade = 0.35
    /// The library starts a little large under the leaving tiles and settles.
    static let libraryStart: CGFloat = 1.05
    static let settle = Animation.timingCurve(0.45, 0, 0.15, 1, duration: 0.5)

    var body: some View {
        Group {
            if let frozen = Self.frozen {
                BentoSplash(clock: frozen)
                    .task { if frozen.leaving != nil { onHandOver() } }
            } else if stillShown || (reduceMotion && clock.leaving == nil) {
                BentoSplash(clock: SplashClock(time: BentoSplash.still))
                    .opacity(stillOpacity)
                    .task { await showStill() }
            } else {
                TimelineView(.animation(paused: finished)) { timeline in
                    BentoSplash(clock: clock)
                        .onChange(of: timeline.date, initial: true) { _, now in advance(to: now) }
                }
            }
        }
        .onChange(of: isReady, initial: true) { _, isReady in
            ready = isReady
            if isReady && (stillHolding || isHurried) && stillShown { leaveStill() }
        }
        .onChange(of: isHurried) { _, isHurried in
            if isHurried && ready && stillShown { leaveStill() }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OwlLuna")
        .accessibilityAddTraits(.isImage)
    }

    enum Event { case handOver, finished }

    /// Moves a clock on by one frame that came `gap` milliseconds after the last; the frame that hands over starts the leaving clock at 0.
    static func advance(_ clock: inout SplashClock, by gap: Double, ready: Bool, hurried: Bool = false) -> Event? {
        let step = min(gap, longestStep)
        guard step > 0 else { return nil }
        if hurried, clock.leaving == nil, clock.time < unseen { return ready ? .finished : nil }
        clock.time += step
        if let leaving = clock.leaving {
            clock.leaving = leaving + step
        } else if ready, hurried || clock.time >= BentoSplash.handOver {
            clock.leaving = 0
            return .handOver
        }
        if hurried, clock.leaving != nil, BentoTile.allCases.allSatisfy({ $0.hasLeft(at: clock) }) { return .finished }
        return clock.exit >= BentoSplash.leaveDuration ? .finished : nil
    }

    private func advance(to now: Date) {
        defer { lastFrame = now }
        guard let lastFrame, !finished else { return }
        switch Self.advance(&clock, by: now.timeIntervalSince(lastFrame) * 1000, ready: ready, hurried: isHurried) {
        case .handOver:
            onHandOver()
        case .finished:
            finished = true
            onFinished()
        case nil:
            break
        }
    }

    private func showStill() async {
        stillShown = true
        if isHurried {
            stillHolding = true
            if ready { leaveStill() }
            return
        }
        withAnimation(.easeOut(duration: 0.25)) { stillOpacity = 1 }
        try? await Task.sleep(for: .seconds(Self.stillDuration))
        guard !Task.isCancelled else { return }
        stillHolding = true
        if ready { leaveStill() }
    }

    private func leaveStill() {
        guard !finished else { return }
        finished = true
        guard stillOpacity > 0 else { return onFinished() }
        onHandOver()
        withAnimation(.easeOut(duration: Self.stillFade)) { stillOpacity = 0 }
        Task {
            try? await Task.sleep(for: .seconds(Self.stillFade + 0.03))
            onFinished()
        }
    }

    #if DEBUG
    /// `-splashFreeze <ms>` holds the splash at one moment of its run, for screenshots.
    private static let frozen = LaunchOptions.value("-splashFreeze").flatMap(Double.init).map { time in
        SplashClock(time: time, leaving: time >= BentoSplash.handOver ? time - BentoSplash.handOver : nil)
    }
    #else
    private static let frozen: SplashClock? = nil
    #endif
}
