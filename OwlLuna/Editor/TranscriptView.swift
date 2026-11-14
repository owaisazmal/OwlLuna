import SwiftUI

/// The lines of a transcript, each a button that goes to its moment. The line being said is marked.
struct TranscriptLines: View {
    let lines: [Transcript.Line]
    var current: Int?
    let select: (Transcript.Line) -> Void

    var body: some View {
        ForEach(lines) { line in
            Button { select(line) } label: {
                HStack(alignment: .firstTextBaseline, spacing: Space.x3) {
                    Text(RecordingStop.clock(line.start))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.textSecondary)
                    Text(line.text)
                        .font(.body.weight(line.id == current ? .semibold : .regular))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Space.x2)
                .padding(.horizontal, Space.x3)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background {
                    if line.id == current {
                        RoundedRectangle.plate.fill(Color.mustard.opacity(0.2))
                        RoundedRectangle.plate.strokeBorder(Color.mustard, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(RecordingStop.clock(line.start)), \(line.text)"))
            .accessibilityAddTraits(line.id == current ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("transcript.line.\(line.id + 1)")
        }
    }
}

/// What was said in one recording: read it and tap a line to hear it with the ink, or have it written down.
struct TranscriptView: View {
    let recorder: NotebookRecorder
    let recordingID: UUID
    /// Replays the recording with its ink from a moment in it.
    var replay: ((RecordingEntry, TimeInterval) -> Void)?
    /// Picked for this recording alone; until then it is the first of `languages`, the one Settings has.
    @State private var language = ""
    @State private var languages = Transcription.languages
    @State private var copied = false

    private var recording: RecordingEntry? { recorder.recordings.first { $0.id == recordingID } }
    private var locale: Locale { languages.first { $0.identifier(.bcp47) == language } ?? languages[0] }

    var body: some View {
        Group {
            if let recording {
                if let progress = recorder.transcribing[recordingID] {
                    running(progress)
                } else if let transcript = recorder.transcript(for: recording), !transcript.isEmpty {
                    written(transcript, recording)
                } else {
                    offer(recording)
                }
            }
        }
        .background(Color.surface)
        .navigationTitle(recording?.name ?? "")
        .barGround(.surface)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func start(_ recording: RecordingEntry) {
        recorder.transcribe(recording, locale: locale)
        AccessibilityNotification.Announcement(String(localized: "Transcribing")).post()
    }

    private func offer(_ recording: RecordingEntry) -> some View {
        ScrollView {
            EmptyPlate("No Transcript Yet", systemImage: "quote.bubble",
                       message: (Device.isMac
                           ? Text("OwlLuna can write down what was said, so you can read it, search for it and jump to any moment. The recording is transcribed on this Mac.")
                           : Text("OwlLuna can write down what was said, so you can read it, search for it and jump to any moment. The recording is transcribed on this iPad.")))
        }
        .scrollBounceBehavior(.basedOnSize)
        // The button stays in reach however long the words above it run.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Space.x2) {
                if recorder.isReadOnly {
                    Text("This notebook is read-only.").foregroundStyle(Color.textSecondary)
                } else {
                    Button("Transcribe") { start(recording) }
                        .buttonStyle(.owlLuna(.primary))
                        .disabled(recorder.isRecording)
                        .accessibilityIdentifier("transcript.start")
                    if languages.count > 1 { languagePicker }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(Space.x4)
            .background(Color.surface)
        }
    }

    private var languagePicker: some View {
        OwlLunaMenu(Text("Language")) {
            OwlLunaPicker(selection: Binding(get: { locale.identifier(.bcp47) }, set: { language = $0 })) {
                ForEach(languages, id: \.identifier) { Text(Transcription.name(of: $0)).tag($0.identifier(.bcp47)) }
            }
        } label: {
            HStack(spacing: Space.x2) {
                Label(Transcription.name(of: locale), systemImage: "globe")
                Image(systemName: "chevron.up.chevron.down").imageScale(.small).foregroundStyle(Color.textSecondary)
            }
        }
        .buttonStyle(.owlLuna(.secondary, compact: true))
        .accessibilityLabel(Text("Language"))
        .accessibilityValue(Text(Transcription.name(of: locale)))
        .accessibilityIdentifier("transcript.language")
    }

    private func running(_ progress: Double) -> some View {
        VStack(spacing: Space.x5) {
            if progress > 0 {
                ProgressView(value: progress) { Text("Transcribing…").foregroundStyle(Color.ink) } currentValueLabel: {
                    Text(progress, format: .percent.precision(.fractionLength(0))).foregroundStyle(Color.textSecondary)
                }
            } else {
                ProgressView { Text("Transcribing…").foregroundStyle(Color.ink) }
            }
            Button("Cancel", role: .cancel) { recorder.cancelTranscription(recordingID) }
                .buttonStyle(.owlLuna)
        }
        .padding(Space.x8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func written(_ transcript: Transcript, _ recording: RecordingEntry) -> some View {
        let lines = transcript.lines
        let current = recorder.playingID == recordingID ? Transcript.line(at: recorder.currentTime, in: lines) : nil
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.x1) {
                TranscriptLines(lines: lines, current: current) { line in replay?(recording, line.start) }
                if replay != nil {
                    Text("Tap a line to hear it, with the ink you wrote as it was said.")
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, Space.x3)
                        .padding(.top, Space.x3)
                }
            }
            .padding(Space.x3)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                OwlLunaMenu {
                    Button {
                        UIPasteboard.general.string = transcript.text
                        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
                    } label: { Label("Copy Transcript", systemImage: "doc.on.doc") }
                    if !recorder.isReadOnly {
                        if languages.count > 1 {
                            OwlLunaMenu {
                                ForEach(languages, id: \.identifier) { choice in
                                    Button(Transcription.name(of: choice)) {
                                        language = choice.identifier(.bcp47)
                                        recorder.transcribe(recording, locale: choice)
                                    }
                                }
                            } label: { Label("Transcribe Again", systemImage: "arrow.clockwise") }
                        } else {
                            Button { start(recording) } label: { Label("Transcribe Again", systemImage: "arrow.clockwise") }
                        }
                        Button(role: .destructive) { recorder.removeTranscript(recording) } label: { Label("Remove Transcript", systemImage: "trash") }
                    }
                } label: {
                    Label("Transcript Options", systemImage: "ellipsis")
                }
                .buttonStyle(.plateIcon)
                .accessibilityIdentifier("transcript.options")
            }
            .boardBackground()
        }
    }
}

/// Beside the page while a recording is replayed with its ink: what is being said, line by line.
struct TranscriptPanel: View {
    let session: EditorSession
    var side = HorizontalEdge.trailing

    var body: some View {
        let lines = session.replayLines
        let current = Transcript.line(at: session.recorder.currentTime, in: lines)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.x1) {
                    Text("Transcript")
                        .metaStyle(.footnote)
                        .padding(.horizontal, Space.x3)
                        .padding(.bottom, Space.x2)
                        .accessibilityAddTraits(.isHeader)
                    TranscriptLines(lines: lines, current: current) { session.seekReplay(to: $0.start) }
                }
                .padding(Space.x3)
                .padding(.bottom, Space.x12 * 2)
            }
            .onChange(of: current) { _, line in
                guard let line else { return }
                withAnimation(Motion.standard) { proxy.scrollTo(line, anchor: .center) }
            }
        }
        .background(Color.surface)
        .overlay(alignment: Alignment(horizontal: side.other.alignment, vertical: .center)) {
            Rectangle().fill(Color.hairline).frame(width: 1).ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Transcript"))
        .accessibilityIdentifier("replay.transcript")
    }
}
