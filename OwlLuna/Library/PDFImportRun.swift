import SwiftUI

/// Chosen PDFs brought in one at a time, so one that fails doesn't stop the rest: how far it has got, the locked one
/// waiting for its password, and those that didn't come in.
@MainActor
@Observable
final class PDFImportRun {
    typealias Bring = @MainActor (URL, @escaping PDFImport.Password, @escaping PDFImport.Progress) async throws -> Void

    struct Missed: Identifiable {
        let id = UUID()
        let name: String
        let error: any Error

        var wasSkipped: Bool { (error as? ImportError) == .locked }

        var reason: String {
            switch error as? ImportError {
            case .locked: String(localized: "Skipped, it's locked")
            case .unreadable: String(localized: "Can't be read")
            case .empty: String(localized: "Has no pages")
            case nil: String(localized: "Couldn't be copied")
            }
        }
    }

    /// A locked PDF waiting for its password, and whether the last one tried didn't open it.
    struct Asking: Equatable {
        let name: String
        let wrong: Bool
    }

    private(set) var names: [String] = []
    /// How many have come in or been missed.
    private(set) var done = 0
    /// How far through the one coming in now, from 0 to 1.
    private(set) var current = 0.0
    private(set) var asking: Asking?
    private(set) var missed: [Missed] = []
    private(set) var isFinished = false
    @ObservationIgnored private var waiting: [(url: URL, bring: Bring)] = []
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var answering: CheckedContinuation<String?, Never>?

    var fraction: Double { min((Double(done) + current) / Double(max(names.count, 1)), 1) }
    var name: String? { names.indices.contains(done) ? names[done] : nil }
    /// Once it's over, whether something didn't come in other than what was skipped.
    var hasNews: Bool { isFinished && missed.contains { !$0.wasSkipped } }

    /// Brings in each of `urls` with `bring`, after any still waiting.
    func add(_ urls: [URL], bring: @escaping Bring) {
        waiting += urls.map { ($0, bring) }
        names += urls.map { $0.deletingPathExtension().lastPathComponent }
        isFinished = false
        if running == nil { running = Task { await work() } }
    }

    /// Waits until everything added has come in or been missed.
    func finish() async {
        while let running { await running.value }
    }

    /// The password typed for the locked PDF, or nil to skip it. It goes to that PDF and is kept nowhere.
    func answer(_ password: String?) {
        asking = nil
        let waiting = answering
        answering = nil
        waiting?.resume(returning: password)
    }

    private func work() async {
        while done < waiting.count {
            let index = done, item = waiting[index], name = names[index]
            current = 0
            do {
                try await item.bring(item.url, { [weak self] wrong in await self?.ask(name, wrong: wrong) },
                                     { [weak self] value in Task { @MainActor in self?.advance(index, to: value) } })
            } catch {
                missed.append(Missed(name: name, error: error))
            }
            done = index + 1
        }
        current = 0
        isFinished = true
        running = nil
    }

    private func ask(_ name: String, wrong: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            answering = continuation
            asking = Asking(name: name, wrong: wrong)
        }
    }

    private func advance(_ index: Int, to value: Double) {
        guard index == done, value > current else { return }
        current = value
    }
}

/// A PDF import as it shows: a thread once it has taken a moment, a notice asking for a locked one's password, and
/// at the end a notice naming what didn't come in.
struct PDFImportStatus: View {
    let run: PDFImportRun
    /// The edge the thread stands at: the shelf's foot, or the top of the editor, clear of its tools.
    var edge: VerticalEdge = .bottom
    let onEnd: () -> Void
    @State private var shown = false
    @State private var password = ""

    private static let most = 8

    var body: some View {
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if shown, !run.isFinished, let name = run.name {
                ProgressView(value: run.fraction) {
                    Text("Importing “\(name)”")
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } currentValueLabel: {
                    if run.names.count > 1 {
                        Text("\(run.done + 1) of \(run.names.count)")
                    } else {
                        Text(run.fraction, format: .percent.precision(.fractionLength(0)))
                    }
                }
                .padding(.horizontal, Space.x4)
                .padding(.vertical, Space.x3)
                .frame(maxWidth: 420)
                .board(in: RoundedRectangle.bar)
                .padding(.horizontal, Space.x4)
                .padding(edge == .bottom ? .bottom : .top, edge == .bottom ? Space.x4 : Space.x2)
                .accessibilityIdentifier("pdfImport.progress")
            }
        }
        .notice(Text("“\(run.asking?.name ?? "")” is locked"), isPresented: Binding(get: { run.asking != nil }, set: { _ in }),
                message: run.asking?.wrong == true ? Text("That password didn't work. Try again.").foregroundStyle(Color.tomato)
                                                   : Text("Type its password to import it.")) {
            SecureField("Password", text: $password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .noticeFieldWrong(run.asking?.wrong == true)
                .accessibilityIdentifier("pdfImport.password")
        } actions: {
            Button("Skip", role: .cancel) { answer(nil) }
            Button("Unlock") { answer(password) }
        }
        .notice(missedTitle, isPresented: Binding(get: { run.hasNews }, set: { if !$0 { onEnd() } }), message: missedMessage) {
            if run.names.count > 1 { missedRows }
        } actions: {
            Button("OK", role: .cancel) {}
        }
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            shown = true
        }
        .onChange(of: run.isFinished, initial: true) { _, finished in if finished, !run.hasNews { onEnd() } }
        .onChange(of: run.asking?.wrong) { _, wrong in
            if wrong == true { AccessibilityNotification.Announcement(String(localized: "That password didn't work. Try again.")).post() }
        }
        .onDisappear { if run.asking != nil { answer(nil) } }
    }

    private func answer(_ typed: String?) {
        run.answer(typed)
        password = ""
    }

    private var missedTitle: Text {
        if run.names.count == 1, let missed = run.missed.first { return Text("“\(missed.name)” wasn't imported") }
        return Text("\(run.names.count - run.missed.count) of \(run.names.count) PDFs imported")
    }

    private var missedMessage: Text {
        if run.names.count == 1, let missed = run.missed.first { return Text(missed.error.localizedDescription) }
        return Text("These didn't come in:")
    }

    private var missedRows: some View {
        VStack(spacing: 0) {
            ForEach(run.missed.prefix(Self.most)) { missed in
                HStack(alignment: .firstTextBaseline, spacing: Space.x3) {
                    Text(missed.name)
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: Space.x2)
                    Text(missed.reason)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
                .padding(.vertical, Space.x2)
                .overlay(alignment: .top) { HairlineRule() }
                .accessibilityElement(children: .combine)
            }
            if run.missed.count > Self.most {
                Text("\(run.missed.count - Self.most) more PDFs")
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Space.x2)
                    .overlay(alignment: .top) { HairlineRule() }
            }
        }
        .noticeBare()
        .accessibilityIdentifier("pdfImport.missed")
    }
}
