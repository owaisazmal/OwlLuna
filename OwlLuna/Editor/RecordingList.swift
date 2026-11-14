import SwiftUI

struct RecordingList: View {
    let recorder: NotebookRecorder
    /// Replays a recording with its ink, from a moment in it.
    var replay: ((RecordingEntry, TimeInterval) -> Void)?
    @State private var path: [UUID] = []
    @State private var renaming: RecordingEntry?
    @State private var name = ""
    @State private var deleting: RecordingEntry?
    @State private var sharing: SharedFiles?
    @Environment(\.panelClose) private var panelClose

    private struct SharedFiles: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    var body: some View {
        NavigationStack(path: $path) {
            Ledger {
              Section {
                ForEach(Array(recorder.recordings.enumerated()), id: \.element.id) { index, recording in
                    RecordingRow(recorder: recorder, recording: recording, number: index + 1, replay: replay,
                                 openTranscript: { path.append(recording.id) },
                                 rename: {
                                     name = recording.title ?? ""
                                     renaming = recording
                                 },
                                 share: { share($0, of: recording) },
                                 delete: { deleting = recording })
                    .ledgerSwipe {
                        if !recorder.isReadOnly {
                            Button(role: .destructive) { deleting = recording } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
              } footer: {
                if replay != nil, !recorder.recordings.isEmpty {
                    Text("The pencil replays a recording with your ink: what you wrote appears as it was written, and tapping ink jumps to that moment. The speech bubble opens what was said.")
                        .foregroundStyle(Color.textSecondary)
                }
              }
            }
            .background(Color.surface)
            .overlay {
                if recorder.recordings.isEmpty {
                    ScrollView {
                        EmptyPlate("No Recordings", systemImage: "waveform",
                                   message: Text("Tap the microphone to record a lecture or meeting alongside your notes."))
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .background(Color.surface)
                }
            }
            .navigationTitle("Recordings")
            .barGround(.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(panelClose == nil ? .automatic : .hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                TranscriptView(recorder: recorder, recordingID: id, replay: replay)
            }
        }
        .notice("Rename Recording", isPresented: Binding(isPresent: $renaming),
                message: Text("Leave it empty to name it after when it was recorded.")) {
            TextField("Name", text: $name)
                .accessibilityIdentifier("recording.rename.field")
        } actions: {
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let renaming { recorder.rename(renaming, to: name) } }
        }
        .notice("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(isPresent: $deleting), message: Text("You can undo this.")) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Recording", role: .destructive) { if let deleting { recorder.delete(deleting) } }
        }
        .sheet(item: $sharing) { files in
            ShareSheet(items: files.urls)
                .presentationCornerRadius(Radius.sheet)
                .appModels()
                .onDisappear { ExportFolder.discard(files.urls) }
        }
    }

    private func share(_ part: NotebookRecorder.Part, of recording: RecordingEntry) {
        Task {
            do {
                if let urls = try await recorder.files(sharing: part, of: recording) { sharing = SharedFiles(urls: urls) }
            } catch {
                recorder.errorMessage = error.localizedDescription
            }
        }
    }
}

/// A recording in the list: play it, read what was said, replay it with its ink, or name, share and delete it.
/// While it plays, its position and the speed are under it.
private struct RecordingRow: View {
    let recorder: NotebookRecorder
    let recording: RecordingEntry
    let number: Int
    var replay: ((RecordingEntry, TimeInterval) -> Void)?
    let openTranscript: () -> Void
    let rename: () -> Void
    let share: (NotebookRecorder.Part) -> Void
    let delete: () -> Void

    var body: some View {
        let playing = recorder.playingID == recording.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.x3) {
                Button { recorder.togglePlayback(recording) } label: {
                    Label(playing ? "Stop" : "Play", systemImage: playing ? "stop.circle.fill" : "play.circle.fill")
                }
                .buttonStyle(.barIcon)
                .disabled(recorder.isRecording)
                .accessibilityIdentifier("recording.play.\(number)")
                HStack(spacing: Space.x3) {
                    VStack(alignment: .leading, spacing: Space.x1) {
                        Text(recording.name).font(.body.weight(.medium)).foregroundStyle(Color.ink)
                        if recording.title != nil {
                            Text(recording.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Color.textSecondary)
                        }
                    }
                    Spacer()
                    Text(Duration.seconds(recording.duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.callout.monospacedDigit()).foregroundStyle(Color.textSecondary)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                HStack(spacing: 0) {
                    Button(action: openTranscript) {
                        Label("Transcript", systemImage: "quote.bubble").symbolVariant(recording.transcriptFile == nil ? .none : .fill)
                    }
                    .accessibilityValue(Text(recorder.transcribing[recording.id] != nil ? "Transcribing" : recording.transcriptFile == nil ? "Not transcribed" : "Transcribed"))
                    .accessibilityIdentifier("recording.transcript.\(number)")
                    if let replay {
                        Button { replay(recording, 0) } label: { Label("Replay with Ink", systemImage: "pencil.and.scribble") }
                            .disabled(recorder.isRecording)
                            .accessibilityHint(Text("Plays the recording while the ink written during it appears"))
                            .accessibilityIdentifier("recording.replay.\(number)")
                    }
                    options
                }
                .buttonStyle(.barIcon)
            }
            if playing {
                HStack(spacing: Space.x2) {
                    Text(PlaybackScrubber.clock(recorder.currentTime))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.ink)
                        .accessibilityHidden(true)
                    PlaybackScrubber(time: recorder.currentTime, duration: recording.duration) { recorder.seek(to: $0) }
                        .accessibilityIdentifier("recording.position.\(number)")
                    PlaybackSpeedMenu(recorder: recorder)
                        .accessibilityIdentifier("recording.speed.\(number)")
                }
                .padding(.leading, 44 + Space.x3)
                .padding(.bottom, Space.x2)
            }
        }
    }

    private var options: some View {
        OwlLunaMenu(Text(recording.name)) {
            Button(action: rename) { Label("Rename…", systemImage: "pencil") }
                .disabled(recorder.isReadOnly)
                .accessibilityIdentifier("recording.rename")
            Button { share(.audio) } label: { Label("Share Audio…", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("recording.share.audio")
            if recording.transcriptFile != nil {
                Button { share(.transcript) } label: { Label("Share Transcript…", systemImage: "doc.text") }
                    .accessibilityIdentifier("recording.share.transcript")
            }
            if !recorder.isReadOnly {
                MenuBreak()
                Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
                    .accessibilityIdentifier("recording.delete")
            }
        } label: {
            Label("Recording Options", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("recording.options.\(number)")
    }
}
