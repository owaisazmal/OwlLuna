import SwiftUI

/// Flashcards are index cards: cream stock with a red head rule and faint ruling. Like covers and stickers they are
/// content, so they keep their colours at night.
enum CardStock {
    static let headRule = Color(hex: 0xC9452F)
    static let corner: CGFloat = 10
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: corner, style: .continuous) }
}

/// The paper of an index card, at any size.
struct CardPaper: View {
    /// Where the red rule sits, from the top.
    var head: CGFloat = 44
    var ruling: CGFloat = 28
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas { context, size in
            guard head < size.height else { return }
            if contrast != .increased, ruling > 0 {
                var lines = Path()
                var y = head + ruling
                while y < size.height - ruling / 2 {
                    lines.move(to: CGPoint(x: 0, y: y))
                    lines.addLine(to: CGPoint(x: size.width, y: y))
                    y += ruling
                }
                context.stroke(lines, with: .color(Color.labelInk.opacity(0.07)), lineWidth: 1)
            }
            var rule = Path()
            rule.move(to: CGPoint(x: 0, y: head))
            rule.addLine(to: CGPoint(x: size.width, y: head))
            context.stroke(rule, with: .color(CardStock.headRule.opacity(0.75)), lineWidth: max(1, head / 30))
        }
        .background(Color.labelCream)
        .clipShape(CardStock.shape)
        .overlay { CardStock.shape.strokeBorder(Color.labelInk.opacity(contrast == .increased ? 0.5 : 0.18), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

/// One side of a card, large enough to study from.
struct CardFace<Clipping: View>: View {
    let side: CardSide
    let isAnswer: Bool
    /// Printed at the head of the card beside the side's name: the notebook it belongs to.
    var source: String?
    private let hasClipping: Bool
    private let clipping: Clipping

    init(side: CardSide, isAnswer: Bool, source: String? = nil, hasClipping: Bool, @ViewBuilder clipping: () -> Clipping) {
        self.side = side
        self.isAnswer = isAnswer
        self.source = source
        self.hasClipping = hasClipping
        self.clipping = clipping()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(isAnswer ? "Answer" : "Question")
                    .eyebrowStyle(Color.labelInk)
                    .animation(nil, value: isAnswer)
                Spacer(minLength: Space.x3)
                if let source {
                    Text(source)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.labelInkSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Space.x5)
            .frame(height: 44)
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: Space.x4) {
                        clipping
                        if !side.text.isEmpty {
                            Text(side.text)
                                .displayTextFont(hasClipping ? 20 : 28, relativeTo: hasClipping ? .title3 : .title)
                                .foregroundStyle(Color.labelInk)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .animation(nil, value: side.text)
                        }
                    }
                    .padding(.horizontal, Space.x6)
                    .padding(.vertical, Space.x5)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .background { CardPaper() }
        .contentShape(CardStock.shape)
    }
}

extension CardFace where Clipping == CardClippingView? {
    init(side: CardSide, image: UIImage?, isAnswer: Bool, source: String? = nil) {
        self.init(side: side, isAnswer: isAnswer, source: source, hasClipping: image != nil) {
            if let image { CardClippingView(image: image, tape: isAnswer ? .sage : .mustard) }
        }
    }
}

/// A clipping from a page, held to the card by a strip of washi tape.
struct CardClippingView: View {
    let image: UIImage
    var tape: TapeColor = .mustard
    var showsTape = true

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clippingCut()
            .clippingShadow()
            .clippingHolder(showsTape ? tape : nil)
            .accessibilityLabel(Text("Clipping from the page"))
    }
}

extension View {
    /// The cut edge of a clipping.
    func clippingCut() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.labelInk.opacity(0.2), lineWidth: 1) }
    }

    /// The faint shadow a clipping casts on the card.
    func clippingShadow() -> some View {
        shadow(color: Color.labelInk.opacity(0.12), radius: 1.5, y: 1)
    }

    /// The strip of washi tape across a clipping's top edge that holds it to the card.
    func clippingHolder(_ tape: TapeColor?) -> some View {
        overlay(alignment: .top) {
            if let tape {
                TapeStrip(color: tape)
                    .frame(width: 58, height: 16)
                    .rotationEffect(.degrees(-3))
                    .offset(y: -8)
            }
        }
        .padding(.top, tape == nil ? 0 : 8)
    }
}

/// The study tape, drawn as it is on the page.
struct TapeStrip: View {
    let color: TapeColor

    var body: some View {
        Canvas { context, size in
            context.withCGContext { TapeArt.draw(color, in: $0, rect: CGRect(origin: .zero, size: size)) }
        }
        .accessibilityHidden(true)
    }
}

/// A card small enough for a row or a desk card: stock and head rule only, or the side's clipping.
struct MiniCard: View {
    var image: UIImage?
    var width: CGFloat = 56

    var body: some View {
        let height = (width * 0.66).rounded()
        ZStack {
            CardPaper(head: (height * 0.3).rounded(), ruling: (height * 0.2).rounded())
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width - 8, height: height - 8)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.labelInk.opacity(0.2), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

/// A few cards lying on the desk, for the places that have none to show yet or none left.
struct CardStackIllustration: View {
    var isDone = false
    var width: CGFloat = 120

    var body: some View {
        let height = (width * 0.66).rounded()
        ZStack {
            leaf(height).rotationEffect(.degrees(-9)).offset(x: -10, y: 6)
            leaf(height).rotationEffect(.degrees(6)).offset(x: 10, y: 3)
            leaf(height)
                .overlay {
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: height * 0.3, weight: .bold))
                            .foregroundStyle(Color.labelInk)
                            .offset(y: height * 0.12)
                    }
                }
        }
        .frame(width: width + 36, height: height + 30)
        .accessibilityHidden(true)
    }

    private func leaf(_ height: CGFloat) -> some View {
        CardPaper(head: (height * 0.28).rounded(), ruling: (height * 0.18).rounded())
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
    }
}

extension CardSchedule {
    /// "Today", "Tomorrow", "In 4 days": when a card comes back after an answer.
    static func waitText(_ days: Int) -> String {
        switch days {
        case ...0: String(localized: "Today")
        case 1: String(localized: "Tomorrow")
        case 2..<60: String(localized: "In \(days) days")
        default: String(localized: "In \(Int((Double(days) / 30).rounded())) months")
        }
    }
}

extension Flashcard {
    /// What a list calls the card: its question, or where its clipping came from.
    func summary(pageNumber: Int?) -> String {
        let question = front.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty { return question }
        if tapeID != nil { return pageNumber.map { String(localized: "Study tape on page \($0)") } ?? String(localized: "Study tape") }
        return pageNumber.map { String(localized: "Clipping from page \($0)") } ?? String(localized: "Clipping")
    }

    func dueText(today: String) -> String {
        guard !isDue(on: today) else { return reviews == 0 ? String(localized: "New") : String(localized: "Due") }
        let calendar = Calendar.current
        guard let from = ActivityFile.date(forKey: today, calendar: calendar), let to = ActivityFile.date(forKey: due, calendar: calendar) else { return due }
        return CardSchedule.waitText(calendar.dateComponents([.day], from: from, to: to).day ?? 1)
    }
}
