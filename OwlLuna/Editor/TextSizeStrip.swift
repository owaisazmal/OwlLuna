import SwiftUI

/// Where a type size stands along the size strip, from 0 to 1. The scale is logarithmic, so the sizes most written in have the most room.
enum TextSizeScale {
    private static let sizes = TextBox.fontSizes
    private static let span = log(sizes.upperBound / sizes.lowerBound)

    static func place(of size: CGFloat) -> CGFloat {
        log(min(max(size, sizes.lowerBound), sizes.upperBound) / sizes.lowerBound) / span
    }

    /// The whole point nearest a place.
    static func size(at place: CGFloat) -> CGFloat {
        (sizes.lowerBound * exp(min(max(place, 0), 1) * span)).rounded()
    }
}

extension TextBox {
    /// A type size as the card reads it out: in whole points, or to a tenth between them.
    static func pointsLabel(_ size: CGFloat) -> String {
        guard size != size.rounded() else { return String(localized: "\(Int(size)) pt") }
        return String(localized: "\(Double(size).formatted(.number.precision(.fractionLength(1)))) pt")
    }
}

/// The type size on a strip: a knob to slide, and a point at a time from the plates at its ends.
struct TextSizeStrip: View {
    let session: EditorSession
    let box: TextBox
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        HStack(spacing: Space.x2) {
            step(-1, "Smaller", symbol: "minus", identifier: "editor.text.size.minus")
                .disabled(box.fontSize <= TextBox.fontSizes.lowerBound)
            SizeTrack(session: session, size: box.fontSize, flipped: direction == .rightToLeft)
            step(1, "Larger", symbol: "plus", identifier: "editor.text.size.plus")
                .disabled(box.fontSize >= TextBox.fontSizes.upperBound)
        }
    }

    private func step(_ points: Int, _ title: LocalizedStringKey, symbol: String, identifier: String) -> some View {
        Button { session.stepTextSize(by: points) } label: { Label(title, systemImage: symbol) }
            .buttonStyle(.plateIcon)
            .buttonRepeatBehavior(.enabled)
            .accessibilityIdentifier(identifier)
    }
}

/// The well the knob slides in, marked in mustard where the named sizes fall. It runs the way the card's rows do.
private struct SizeTrack: View {
    let session: EditorSession
    let size: CGFloat
    let flipped: Bool
    @State private var slide: Slide?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Slide {
        let run = UUID()
        /// How far from the knob's middle it was taken hold of; nothing when the touch was beside it.
        let grip: CGFloat
        var last: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - StripKnob.width, 1), middle = proxy.size.height / 2
            let x = { (size: CGFloat) in StripKnob.width / 2 + travel * along(TextSizeScale.place(of: size)) }
            ZStack {
                Color.clear
                    .well(in: RoundedRectangle.thumb)
                    .frame(height: 16)
                ForEach(TextBox.sizes, id: \.points) { preset in
                    Rectangle()
                        .fill(Color.mustard)
                        .overlay { if contrast == .increased { Rectangle().strokeBorder(plateEdge(contrast), lineWidth: 0.5) } }
                        .frame(width: 3, height: 20)
                        .position(x: x(preset.points), y: middle)
                }
                StripKnob()
                    .position(x: x(size), y: middle)
                    .animation(slide == nil && !reduceMotion ? Motion.quick : nil, value: size)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if slide == nil {
                        let knob = x(size), onKnob = abs(drag.startLocation.x - knob) <= 22
                        slide = Slide(grip: onKnob ? drag.startLocation.x - knob : 0, last: onKnob ? TextSizeScale.size(at: TextSizeScale.place(of: size)) : size)
                    }
                    guard var current = slide else { return }
                    let target = TextSizeScale.size(at: along((drag.location.x - current.grip - StripKnob.width / 2) / travel))
                    guard target != current.last else { return }
                    current.last = target
                    slide = current
                    session.updateText(run: current.run) { $0.fontSize = target }
                }
                .onEnded { _ in slide = nil })
            .accessibilityElement()
            .accessibilityLabel(Text("Size"))
            .accessibilityValue(Text(TextBox.pointsLabel(size)))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: session.stepTextSize(by: 1)
                case .decrement: session.stepTextSize(by: -1)
                @unknown default: break
                }
            }
            // A tap from Voice Control or VoiceOver lands on the knob, which leaves the size as it is.
            .accessibilityActivationPoint(UnitPoint(x: x(size) / max(proxy.size.width, 1), y: 0.5))
            .accessibilityIdentifier("editor.text.size.strip")
        }
        .frame(height: 44)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func along(_ place: CGFloat) -> CGFloat {
        flipped ? 1 - place : place
    }
}
