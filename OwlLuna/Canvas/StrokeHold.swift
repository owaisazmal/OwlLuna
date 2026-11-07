import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit

/// How long each touch on the pages rested before it lifted, and which rest the stroke ended with: the Pencil's, or a
/// finger's when fingers draw and it was alone on the pages, so a resting palm or thumb never counts.
struct TouchRests {
    static let slop: CGFloat = 6
    /// How far apart the touch's clock and the stroke's may read.
    static let clockSlack: TimeInterval = 0.1

    private struct Touch {
        let landed: TimeInterval
        var anchor: CGPoint
        var restingSince: TimeInterval
        let isPencil: Bool
        var counts: Bool
    }

    private var down: [AnyHashable: Touch] = [:]
    private var last: (duration: TimeInterval, landed: TimeInterval, endedAt: TimeInterval, isPencil: Bool)?

    /// Every touch has lifted.
    var isEmpty: Bool { down.isEmpty }

    mutating func began(_ touch: AnyHashable, isPencil: Bool, fingersDraw: Bool, at point: CGPoint, time: TimeInterval) {
        let alone = down.isEmpty
        if isPencil {
            for key in down.keys { down[key]?.counts = false }
            last = nil
        } else if fingersDraw {
            for key in down.keys where down[key]?.isPencil == false { down[key]?.counts = false }
            if last?.isPencil == false { last = nil }
        }
        down[touch] = Touch(landed: time, anchor: point, restingSince: time, isPencil: isPencil, counts: isPencil || (fingersDraw && alone))
    }

    mutating func moved(_ touch: AnyHashable, to point: CGPoint, time: TimeInterval) {
        guard let anchor = down[touch]?.anchor, hypot(point.x - anchor.x, point.y - anchor.y) > Self.slop else { return }
        down[touch]?.anchor = point
        down[touch]?.restingSince = time
    }

    mutating func ended(_ touch: AnyHashable, time: TimeInterval) {
        guard let ended = down.removeValue(forKey: touch), ended.counts else { return }
        last = (time - ended.restingSince, ended.landed, time, ended.isPencil)
    }

    mutating func cancelled(_ touch: AnyHashable) {
        down[touch] = nil
    }

    /// Forgets the touches that are down, but not the rest waiting to be taken.
    mutating func lift() { down.removeAll() }

    /// The rest the last stroke ended with, once: if it ended less than `window` before `now`, and its touch was down when `strokeBegan`.
    mutating func take(at now: TimeInterval, within window: TimeInterval, strokeBegan: TimeInterval? = nil) -> TimeInterval? {
        defer { last = nil }
        guard let last, now - last.endedAt < window else { return nil }
        if let strokeBegan, !(last.landed - Self.clockSlack...last.endedAt + Self.clockSlack).contains(strokeBegan) { return nil }
        return last.duration
    }
}

/// One finger alone on the pages, dragged as far as a stroke would go and lifted.
struct FingerDrag {
    /// How far the finger goes, in points on the screen, to be more than a tap.
    static let reach: CGFloat = 20

    private var start: CGPoint?
    private var touches = 0
    private var reached = false

    mutating func began(isPencil: Bool, at point: CGPoint) {
        touches += 1
        start = touches == 1 && !isPencil ? point : nil
    }

    mutating func moved(to point: CGPoint) {
        guard let start, hypot(point.x - start.x, point.y - start.y) > Self.reach else { return }
        reached = true
    }

    mutating func cancelled() { start = nil }

    /// Every touch has lifted: whether they were one finger's drag. It starts afresh.
    mutating func lifted() -> Bool {
        defer { self = FingerDrag() }
        return start != nil && reached
    }
}

/// Watches the touches on the pages, without ever recognising: it reports how long the stroke rested before lifting, and a lone finger's drag.
final class StrokeHoldRecognizer: UIGestureRecognizer {
    private var rests = TouchRests()
    private var drag = FingerDrag()
    /// Called when a touch lands on the pages, before anything is made of it.
    var onTouchDown: (() -> Void)?
    /// Called as the Pencil lands on the pages.
    var onPencilDown: (() -> Void)?
    /// Called when one finger alone on the pages has dragged and lifted.
    var onFingerDrag: (() -> Void)?
    /// Whether a finger draws as well as the Pencil, asked as each touch lands.
    var fingersDraw: () -> Bool = { false }

    /// Taken in place of the next stroke's rest, for tests, which have no touches.
    var nextRest: TimeInterval?

    /// The rest at the end of `stroke`, once, if the touch that drew it rested and lifted less than `window` ago.
    func takeHold(for stroke: PKStroke?, within window: TimeInterval = 2) -> TimeInterval? {
        if let rest = nextRest {
            nextRest = nil
            return rest
        }
        let now = ProcessInfo.processInfo.systemUptime
        return rests.take(at: now, within: window, strokeBegan: stroke.map { now + $0.path.creationDate.timeIntervalSinceNow })
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchDown?()
        let fingersDraw = fingersDraw()
        for touch in touches {
            let isPencil = touch.type == .pencil
            if isPencil { onPencilDown?() }
            drag.began(isPencil: isPencil, at: touch.location(in: nil))
            rests.began(ObjectIdentifier(touch), isPencil: isPencil, fingersDraw: fingersDraw, at: touch.location(in: view), time: touch.timestamp)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            rests.moved(ObjectIdentifier(touch), to: touch.location(in: view), time: touch.timestamp)
            drag.moved(to: touch.location(in: nil))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { rests.ended(ObjectIdentifier(touch), time: touch.timestamp) }
        guard rests.isEmpty else { return }
        if drag.lifted() { onFingerDrag?() }
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { rests.cancelled(ObjectIdentifier(touch)) }
        drag.cancelled()
        if rests.isEmpty { state = .failed }
    }

    override func reset() {
        rests.lift()
        drag = FingerDrag()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// Whether the touches on a canvas are one finger alone, which may open PencilKit's touch and hold on handwriting
/// (Select All, Insert Space). A resting palm, a second finger or the Pencil's hand never does.
struct LoneFingerHold {
    /// A touch wider than this is the side of a hand, not a fingertip.
    static let palmRadius: CGFloat = 22
    /// How long after the first touch lands the touches are judged, before the hold's own half second.
    static let judgingDelay: TimeInterval = 0.35

    private var fingers: [AnyHashable: CGFloat] = [:]
    private var pencils: Set<AnyHashable> = []
    private var wasCrowded = false

    /// Something is down.
    var isTouching: Bool { !fingers.isEmpty || !pencils.isEmpty }

    /// A lone fingertip may hold; anything more, now or since the touches began, may not.
    var isLoneFinger: Bool {
        !wasCrowded && pencils.isEmpty && fingers.count == 1 && fingers.values.allSatisfy { $0 < Self.palmRadius }
    }

    mutating func began(_ touch: AnyHashable, isPencil: Bool, radius: CGFloat) {
        if isPencil { pencils.insert(touch) } else { fingers[touch] = radius }
        if !isLoneFinger { wasCrowded = true }
    }

    mutating func moved(_ touch: AnyHashable, radius: CGFloat) {
        guard fingers[touch] != nil else { return }
        fingers[touch] = max(fingers[touch] ?? 0, radius)
        if !isLoneFinger { wasCrowded = true }
    }

    mutating func ended(_ touch: AnyHashable) {
        fingers[touch] = nil
        pencils.remove(touch)
    }
}

/// Stands between the touches and PencilKit's touch and hold on handwriting: the hold waits for this to fail, which it
/// does only for one fingertip alone. A palm, a second finger or the Pencil's hand makes it begin instead, so the hold is off.
final class LoneFingerHoldGuard: UIGestureRecognizer {
    /// The names PencilKit gives the recognisers that open the handwriting menu.
    static let guardedNames: Set<String> = ["com.apple.PencilKit.longPressToSelectToken", "com.apple.PencilKit.knobBrush"]

    private var hold = LoneFingerHold()
    private var judging: Task<Void, Never>?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    /// Makes every hold in `view` wait for this guard. Returns how many were found.
    @discardableResult
    func guardHolds(in view: UIView) -> Int {
        var found = 0
        for recognizer in view.gestureRecognizers ?? [] where recognizer.name.map(Self.guardedNames.contains) == true {
            recognizer.require(toFail: self)
            found += 1
        }
        return view.subviews.reduce(found) { $0 + guardHolds(in: $1) }
    }

    private func judge() {
        guard state == .possible else { return }
        state = hold.isLoneFinger ? .failed : .began
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { hold.began(ObjectIdentifier(touch), isPencil: touch.type == .pencil, radius: touch.majorRadius) }
        if !hold.isLoneFinger, state == .possible { state = .began }
        guard judging == nil else { return }
        judging = Task { [weak self] in
            try? await Task.sleep(for: .seconds(LoneFingerHold.judgingDelay))
            guard !Task.isCancelled else { return }
            self?.judge()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { hold.moved(ObjectIdentifier(touch), radius: touch.majorRadius) }
        if !hold.isLoneFinger, state == .possible { state = .began }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { hold.ended(ObjectIdentifier(touch)) }
        guard !hold.isTouching else { return }
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { hold.ended(ObjectIdentifier(touch)) }
        guard !hold.isTouching else { return }
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        judging?.cancel()
        judging = nil
        hold = LoneFingerHold()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
