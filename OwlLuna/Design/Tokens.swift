import SwiftUI

/// 4-point spacing grid.
enum Space {
    static let x1: CGFloat = 4
    static let x2: CGFloat = 8
    static let x3: CGFloat = 12
    static let x4: CGFloat = 16
    static let x5: CGFloat = 20
    static let x6: CGFloat = 24
    static let x8: CGFloat = 32
    static let x10: CGFloat = 40
    static let x12: CGFloat = 48
}

enum Radius {
    /// Covers: nearly square, a touch rounder on the fore-edge.
    static let coverSpine: CGFloat = 2
    static let coverEdge: CGFloat = 5
    /// Controls and cards are cut nearly square, and what slides inside one squarer still.
    static let plate: CGFloat = 4
    static let thumb: CGFloat = 3
    /// The well a thumb slides in, the boards that float over a page, and sheets: each a touch rounder than the last.
    static let track: CGFloat = 6
    static let bar: CGFloat = 8
    static let sheet: CGFloat = 12
}

enum Motion {
    static let standard = Animation.easeOut(duration: 0.18)
    static let quick = Animation.easeOut(duration: 0.15)
    static let ribbon = Animation.spring(response: 0.34, dampingFraction: 0.62)

    /// Everything becomes a short cross-fade when Reduce Motion is on.
    static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : animation
    }

    /// UIKit's side of `adaptive`: with Reduce Motion a scroll doesn't slide, `layer` cross-fades instead. Returns
    /// whether to animate the scroll.
    @MainActor
    static func slides(_ animated: Bool, fading layer: CALayer) -> Bool {
        guard animated, UIAccessibility.isReduceMotionEnabled else { return animated }
        crossFade(layer)
        return false
    }

    /// The short cross-fade, added to a layer just before it changes.
    @MainActor
    static func crossFade(_ layer: CALayer) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "crossFade")
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

extension ClothColor {
    var color: Color { Color(hex: hex) }
    var uiColor: UIColor { UIColor(hex: hex) }

    /// Text on the cloth itself (the page ribbon): white on dark cloths, ink on mustard, rose and oat,
    /// whichever reaches 4.5:1.
    var onCloth: Color {
        switch self {
        case .mustard, .rose, .oat: Color(hex: 0x1B2230)
        default: .white
        }
    }
}

extension RisoInk {
    var uiColor: UIColor { UIColor(hex: hex) }
}
