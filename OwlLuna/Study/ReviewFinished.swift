import SwiftUI

/// The end of a sitting, or a deck with nothing due: when the cards come back, and a way to go through them anyway.
struct ReviewFinished: View {
    let session: ReviewSession
    let all: [DeckCard]
    /// Starts another sitting with these cards.
    let restart: ([DeckCard]) -> Void
    @Environment(FlashcardLibrary.self) private var library
    @Environment(WritingActivity.self) private var activity
    @Environment(\.dismiss) private var dismiss

    /// This week's study days, or nil when none are being kept: the history is off, or its file is from a newer build.
    private var studyWeek: StudyWeek? {
        activity.isEnabled && !activity.log.isNewerThanSupported ? activity.studyWeek() : nil
    }

    var body: some View {
        let studied = session.total > 0
        let visible = Set(all.map(\.notebook))
        let next = library.nextDue(in: visible).flatMap { ActivityFile.date(forKey: $0, calendar: .current) }
        ScrollView {
            VStack(spacing: Space.x4) {
                CardStackIllustration(isDone: true, width: 132)
                    .padding(.bottom, Space.x2)
                Text(studied ? "All caught up." : "Nothing is due.")
                    .displayFont(34)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("review.done.title")
                Group {
                    if let next {
                        Text("The next cards come back on \(next.formatted(.dayName)).")
                    } else if studied {
                        Text("Every card has been through your hands today.")
                    } else {
                        Text("Cards come back here when it is time to see them again.")
                    }
                }
                .font(.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                if session.studied > 0 {
                    TallySlip(studied: session.studied, firstTime: session.firstTime, cameRound: session.cameRound, week: studyWeek)
                        .padding(.top, Space.x2)
                }
                VStack(spacing: Space.x3) {
                    Button { dismiss() } label: { Text("Done").frame(maxWidth: 240) }
                        .buttonStyle(.owlLuna(.primary))
                        .accessibilityIdentifier("review.done")
                    if !library.refreshed(all).isEmpty {
                        Button { restart(library.refreshed(all)) } label: {
                            Text(studied ? "Go Through Them All Again" : "Study Them Anyway").frame(maxWidth: 240)
                        }
                        .buttonStyle(.owlLuna)
                        .accessibilityIdentifier("review.all")
                    }
                }
                .padding(.top, Space.x3)
            }
            .padding(Space.x8)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: .infinity)
    }
}
