import SwiftUI

/// The navigator's third tab: the contents an imported PDF came with, set like a printed contents page. Chapters fold, and
/// the entry the page on show falls under is marked.
struct NotebookContents: View {
    let session: EditorSession
    @Binding var folds: OutlineFolds
    let open: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let places = session.document.places
        let shown = folds.shown.filter { places[$0.pageID] != nil }
        let here = folds.mark(for: session.currentPage, places: places)?.id
        // A list with nothing to fold keeps no column for the chevrons.
        let folding = folds.entries.contains { $0.parent != nil }
        ScrollViewReader { proxy in
            Ledger {
                Section {
                    ForEach(shown) { entry in
                        row(entry, page: places[entry.pageID] ?? 0, isHere: entry.id == here, folding: folding)
                            .id(entry.id)
                    }
                }
            }
            .onAppear { if let here { proxy.scrollTo(here, anchor: .center) } }
        }
        .accessibilityIdentifier("navigator.contents")
    }

    private func row(_ entry: OutlineEntry, page: Int, isHere: Bool, folding: Bool) -> some View {
        HStack(spacing: 0) {
            if folds.hasParts(entry) {
                foldButton(entry)
            } else if folding {
                Color.clear.frame(width: 44)
            }
            Button { open(page) } label: {
                HStack(alignment: .lastTextBaseline, spacing: Space.x2) {
                    Text(entry.title)
                        .font(entry.level == 0 || isHere ? .body.weight(.semibold) : .body)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    DotLeader()
                        .stroke(Color.textSecondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.01, 5]))
                        .frame(minWidth: Space.x4)
                        .frame(height: 1.5)
                    Text(page + 1, format: .number)
                        .font(.body.weight(isHere ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(isHere ? Color.ink : Color.textSecondary)
                }
            }
            .buttonStyle(ContentsRowStyle(leading: folding ? 0 : Space.x3))
            .accessibilityLabel(Text("\(entry.title), page \(page + 1)"))
            .accessibilityValue(isHere ? Text("Current") : Text(verbatim: ""))
            .accessibilityHint(Text("Opens this page"))
        }
        .padding(.leading, CGFloat(entry.level) * Space.x5)
        .overlay(alignment: .leading) { if isHere { Rectangle().fill(Color.accentColor).frame(width: 3) } }
        .ledgerFlush()
    }

    private func foldButton(_ entry: OutlineEntry) -> some View {
        let folded = folds.isFolded(entry)
        return Button {
            withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) { folds.toggle(entry) }
        } label: {
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.textSecondary)
                .rotationEffect(.degrees(folded ? 0 : 90))
                .frame(width: 44)
                .frame(minHeight: 44, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(folded ? Text("Show Sections Under \(entry.title)") : Text("Hide Sections Under \(entry.title)"))
    }
}

/// The part of a contents row that opens its page: touched to the row's edges, and darker under the finger.
private struct ContentsRowStyle: ButtonStyle {
    let leading: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.leading, leading)
            .padding(.trailing, Space.x3)
            .padding(.vertical, Space.x2)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background { if configuration.isPressed { Color.well } }
            .contentShape(Rectangle())
    }
}

/// The dots a printed contents page runs from a title to its page number.
private struct DotLeader: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}
