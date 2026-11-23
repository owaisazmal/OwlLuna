import SwiftUI

/// The slip that ends a sitting: the cards studied, how many were known first time, and this week's study days as squares.
struct TallySlip: View {
    let studied: Int
    let firstTime: Int
    let cameRound: Int
    /// Nil when no study days are kept, which leaves the week off the slip.
    let week: StudyWeek?

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.primaryCloth)
                .clothWeave(in: Rectangle())
                .frame(width: 6)
            VStack(alignment: .leading, spacing: Space.x2) {
                Text("\(studied) cards")
                    .displayFont(30, relativeTo: .title)
                    .foregroundStyle(Color.ink)
                if firstTime > 0 { Text("\(firstTime) first time") }
                if cameRound > 0 { Text("\(cameRound) came round") }
                if let week, !week.days.isEmpty {
                    Color.hairline.frame(height: 1)
                        .padding(.vertical, Space.x1)
                    Text("This week").eyebrowStyle(Color.textSecondary)
                    StudySquares(week: week)
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle.plate)
        .plate(in: RoundedRectangle.plate, fill: .surface)
        .frame(maxWidth: 360)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(studied: studied, firstTime: firstTime, cameRound: cameRound, week: week))
        .accessibilityIdentifier("review.tally")
    }

    /// The slip in plain words, in the order it is read.
    static func spokenLabel(studied: Int, firstTime: Int, cameRound: Int, week: StudyWeek?) -> String {
        let cards = String(localized: "\(studied) cards")
        var parts = [String(localized: "\(cards) studied.")]
        if firstTime > 0 { parts.append(String(localized: "\(firstTime) remembered first time.")) }
        if cameRound > 0 { parts.append(String(localized: "\(cameRound) came round again.")) }
        if let week, week.dayCount > 0 {
            let days = String(localized: "\(week.dayCount) days")
            parts.append(week.includesToday ? String(localized: "Studied on \(days) this week, including today.")
                                            : String(localized: "Studied on \(days) this week."))
        }
        return parts.joined(separator: " ")
    }
}

/// Seven squares in the calendar's order: cobalt with a tick on the days cards were studied, today underlined.
private struct StudySquares: View {
    let week: StudyWeek
    @ScaledMetric(relativeTo: .body) private var size = 32
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: Space.x2) {
            ForEach(week.days, id: \.date) { day in
                VStack(spacing: Space.x1) {
                    square(studied: day.cards > 0)
                    Rectangle()
                        .fill(day.date == week.today ? Color.ink : Color.clear)
                        .frame(height: 2)
                }
                .frame(maxWidth: size)
            }
        }
    }

    private func square(studied: Bool) -> some View {
        RoundedRectangle.thumb
            .fill(studied ? Color.primaryCloth : Color.clear)
            .overlay { RoundedRectangle.thumb.strokeBorder(studied ? Color.primaryCloth : plateEdge(contrast), lineWidth: 1) }
            .overlay {
                if studied {
                    Tick()
                        .stroke(Color.onPrimaryCloth, style: StrokeStyle(lineWidth: 2.5, lineCap: .square, lineJoin: .miter))
                        .padding(Space.x2)
                }
            }
            .aspectRatio(1, contentMode: .fit)
    }
}

/// A tick drawn with straight strokes, to sit in a square.
private struct Tick: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.08))
        return path
    }
}
