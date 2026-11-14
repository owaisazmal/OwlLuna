import SwiftUI
import AVFoundation

struct ExportSheet: View {
    let job: ExportJob
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            Group {
                if job.state == .choosing {
                    ExportChoices(job: job) { dismiss() }
                } else {
                    progressAndResult
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.surface)
            .navigationTitle(title)
            .barGround(.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if job.state != .choosing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.buttonStyle(.owlLuna(.secondary, inBar: true))
                    }
                    .boardBackground()
                }
            }
        }
        .presentationDetents(job.asks || job.format == .timelapse ? [.large] : [.medium])
        .presentationBackground(Color.surface)
        .onDisappear { job.close() }
    }

    private var title: Text {
        switch job.format {
        case .pdf: job.isSeveral ? Text("Export PDFs") : Text("Export PDF")
        case .images: Text("Export Images")
        case .timelapse: Text("Export Video")
        case .text: Text("Export Text")
        }
    }

    private var progressAndResult: some View {
        VStack(spacing: Space.x5) {
            switch job.state {
            case .choosing:
                EmptyView()
            case .running:
                ProgressView(value: job.progress) { Text("Exporting…") } currentValueLabel: {
                    Text(job.progress, format: .percent.precision(.fractionLength(0)))
                }
                Button("Cancel", role: .cancel) { job.cancel(); dismiss() }
                    .buttonStyle(.owlLuna)
            case .finished(let urls):
                if job.format == .timelapse, let url = urls.first {
                    LoopingVideo(url: url)
                        .aspectRatio(job.shape, contentMode: .fit)
                        .frame(maxHeight: 420)
                        .overlay { Rectangle().strokeBorder(Color.hairline, lineWidth: 1) }
                        .accessibilityElement()
                        .accessibilityLabel(Text("The page being written, playing over and over"))
                        .accessibilityAddTraits(.isImage)
                        .accessibilityIdentifier("export.preview")
                }
                if !urls.isEmpty {
                    Label(readyText(urls.count), systemImage: "checkmark.circle").font(.headline)
                        .accessibilityIdentifier("export.ready")
                    if job.offersRecordings { recordingsToggle }
                    HStack(spacing: Space.x3) {
                        Button { sharing = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.owlLuna(.primary))
                            .disabled(job.shared.isEmpty)
                            .accessibilityIdentifier("export.share")
                        if job.format == .pdf || job.format == .images {
                            Button { print(urls) } label: { Label(String(localized: "export.print", defaultValue: "Print"), systemImage: "printer") }
                                .buttonStyle(.owlLuna)
                        }
                    }
                    .sheet(isPresented: $sharing) { ShareSheet(items: job.shared).presentationCornerRadius(Radius.sheet).appModels() }
                }
                if job.skipped > 0 {
                    Label(String(localized: "\(job.skipped) locked notebooks were left out. Unlock them to export them."), systemImage: "lock")
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("export.skipped")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
            case .cancelled:
                Text("Export cancelled.")
            }
        }
        .padding(Space.x8)
    }

    private var recordingsToggle: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Toggle(isOn: Binding(get: { job.includesRecordings }, set: { job.includeRecordings($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include Recordings").foregroundStyle(Color.ink)
                    Text(job.recordingCount == 1 ? String(localized: "The recording and any transcript go in a zip with the PDF.")
                                                 : String(localized: "The \(job.recordingCount) recordings and any transcripts go in a zip with the PDF."))
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.owlLuna)
            .accessibilityIdentifier("export.recordings")
            if job.includesRecordings {
                switch job.bundle {
                case .making?: ProgressView { Text("Adding recordings…").font(.footnote).foregroundStyle(Color.textSecondary) }
                case .failed(let message)?: Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.tomato)
                default: EmptyView()
                }
            }
        }
        .frame(maxWidth: 380)
    }

    private func readyText(_ count: Int) -> String {
        switch job.format {
        case .pdf: count == 1 ? String(localized: "Your PDF is ready.") : String(localized: "Your \(count) PDFs are ready.")
        case .images: count == 1 ? String(localized: "Your image is ready.") : String(localized: "Your \(count) images are ready.")
        case .timelapse: String(localized: "Your video is ready.")
        case .text: String(localized: "Your text is ready.")
        }
    }

    private func print(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = first.deletingPathExtension().lastPathComponent
        info.outputType = .general
        controller.printInfo = info
        if urls.count == 1 { controller.printingItem = first } else { controller.printingItems = urls }
        ExportFolder.beginReading(urls)
        if !controller.present(animated: true, completionHandler: { _, _, _ in ExportFolder.endReading(urls) }) { ExportFolder.endReading(urls) }
    }
}

/// A film playing silently over and over, without controls: the preview of an exported time-lapse.
struct LoopingVideo: UIViewRepresentable {
    let url: URL

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var looper: AVPlayerLooper?
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let player = AVQueuePlayer()
        player.isMuted = true
        view.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        (view.layer as? AVPlayerLayer)?.player = player
        (view.layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        (view.layer as? AVPlayerLayer)?.player?.pause()
        view.looper = nil
    }
}
