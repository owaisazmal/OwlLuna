import SwiftUI
import PencilKit

/// What Change Area works on: a tape card's page and tape as they are now, and what its clippings were cut from.
struct CardAreaSource: Identifiable {
    let id = UUID()
    let document: NotebookDocument
    let page: NotebookPage
    let tape: PageItem
    /// Nil for a card made before its area was kept.
    let clip: CardClip?
}

/// The page drawn once for choosing from, and the areas measured on it, in page points.
private struct CardAreaSheet: Sendable {
    let picture: UIImage
    let ink: PKDrawing
    /// The part of the page the picture shows: all of it, or a piece of a whiteboard.
    let window: CGRect
    let start: CGRect
    /// Where Reset Area sends the frame: the area a card made now would start with.
    let suggested: CGRect
    let tape: CGRect
}

/// Choosing how much of its page a tape card shows: the page on the desk, under the crop frame a picture gets.
struct CardAreaEditor: View {
    let source: CardAreaSource
    /// Called with both clippings cut again, just before this closes.
    let onDone: (CardClipping.TapeCut) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sheet: CardAreaSheet?
    @State private var crop = PageItem.wholePicture
    @State private var isCutting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    if let sheet {
                        CardAreaCrop(picture: sheet.picture, size: sheet.window.size, holds: CardArea.unit(sheet.tape, in: sheet.window), crop: $crop)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .background(Color.desk.ignoresSafeArea())
            .navigationTitle("Change Area")
            .barGround(.desk)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.owlLuna(.secondary, inBar: true))
                        .keyboardShortcut(.cancelAction)
                        .disabled(isCutting)
                        .accessibilityIdentifier("area.cancel")
                }
                .boardBackground()
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: keep)
                        .buttonStyle(.owlLuna(.primary, inBar: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(sheet == nil || isCutting)
                        .accessibilityIdentifier("area.done")
                }
                .boardBackground()
            }
        }
        .task { await load() }
    }

    private var footer: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Space.x2)) : AnyLayout(HStackLayout(spacing: Space.x4))
        return layout {
            Text("Drag an edge or corner")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if isCutting {
                ProgressView().controlSize(.small).frame(minHeight: 44)
            } else {
                Button(action: reset) { Label("Reset Area", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.owlLuna(.secondary, compact: true))
                    .disabled(isSuggested)
                    .accessibilityIdentifier("area.reset")
            }
        }
        .padding(.horizontal, Space.x4)
        .padding(.bottom, Space.x3)
    }

    private var isSuggested: Bool {
        guard let sheet else { return true }
        let region = CardArea.region(crop, of: sheet.window), suggested = sheet.suggested
        return abs(region.minX - suggested.minX) <= 1 && abs(region.minY - suggested.minY) <= 1
            && abs(region.maxX - suggested.maxX) <= 1 && abs(region.maxY - suggested.maxY) <= 1
    }

    private func reset() {
        guard let sheet else { return }
        crop = CardArea.unit(sheet.suggested, in: sheet.window)
    }

    /// The frame starts round what the card shows now.
    private func load() async {
        guard sheet == nil else { return }
        let page = source.page, tape = source.tape, clip = source.clip, assets = source.document.package.assetsDirectory
        let ink = await source.document.ink(page.id)
        let loaded = await Task.detached(priority: .userInitiated) {
            let box = tape.boundingBox.intersection(CGRect(origin: .zero, size: page.size))
            let start = CardClipping.region(of: clip, tape: tape, on: page)
            let suggested = CardClipping.startingRegion(around: tape, on: page, ink: ink, assets: assets)
            let window = CardArea.window(showing: start.union(suggested), on: page)
            return CardAreaSheet(picture: CardClipping.picture(of: page, ink: ink, assets: assets, window: window), ink: ink, window: window,
                                 start: start, suggested: suggested, tape: box)
        }.value
        crop = CardArea.unit(loaded.start, in: loaded.window)
        sheet = loaded
    }

    /// Both sides are cut again from what the frame holds. Nothing is kept until the card is saved.
    private func keep() {
        guard let sheet, !isCutting else { return }
        isCutting = true
        let page = source.page, tape = source.tape, ink = sheet.ink, assets = source.document.package.assetsDirectory
        let region = CardArea.region(crop, of: sheet.window)
        Task {
            let cut = await Task.detached(priority: .userInitiated) {
                await CardClipping.cut(tape, on: page, ink: ink, assets: assets, region: region)
            }.value
            onDone(cut)
            dismiss()
        }
    }
}

/// The page under the crop frame, as large as the room it is given.
private struct CardAreaCrop: UIViewRepresentable {
    let picture: UIImage
    /// The size in page points of what the picture shows.
    let size: CGSize
    let holds: CGRect
    @Binding var crop: CGRect

    final class Coordinator {
        /// The crop last shown or reported, so only a change from outside moves the frame.
        var known: CGRect?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CardAreaStage {
        let stage = CardAreaStage(picture: picture, size: size, crop: crop, holds: holds)
        let coordinator = context.coordinator, binding = $crop
        coordinator.known = crop
        stage.frameView.onChange = { crop in
            coordinator.known = crop
            binding.wrappedValue = crop
        }
        return stage
    }

    func updateUIView(_ stage: CardAreaStage, context: Context) {
        guard crop != context.coordinator.known else { return }
        context.coordinator.known = crop
        stage.frameView.show(crop)
    }
}

/// Fits the page to its own bounds and stands the crop frame on it.
final class CardAreaStage: UIView {
    /// Room for the frame's knobs past the edge of the page.
    private static let inset: CGFloat = 28

    let frameView: ItemCropView
    private let paper = UIView()
    private let size: CGSize

    init(picture: UIImage, size: CGSize, crop: CGRect, holds: CGRect) {
        self.size = size
        let whole = PageItem(content: .unknown, center: CGPoint(x: size.width / 2, y: size.height / 2), size: size)
        frameView = ItemCropView(item: whole.cropped(to: crop), picture: picture.cgImage, assets: FileManager.default.temporaryDirectory, scale: 1)
        frameView.holds = holds
        super.init(frame: .zero)
        addSubview(paper)
        paper.addSubview(frameView)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The paper fills the stage with the page's corner as its origin, so the frame can be caught past the page's edge.
    override func layoutSubviews() {
        super.layoutSubviews()
        let room = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        guard room.width > 0, room.height > 0, size.width > 0, size.height > 0 else { return }
        let scale = min(room.width / size.width, room.height / size.height)
        paper.frame = bounds
        paper.bounds.origin = CGPoint(x: (size.width * scale - bounds.width) / 2, y: (size.height * scale - bounds.height) / 2)
        frameView.scale = scale
    }
}
