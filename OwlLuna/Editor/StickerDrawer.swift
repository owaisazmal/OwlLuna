import SwiftUI
import PhotosUI

/// The sheet of stickers: the user's own, cut out of their photos, then the built-in ones. Picking one places it on the current page.
struct StickerDrawer: View {
    let onPick: (Sticker) -> Void
    let onPickOwn: (CustomSticker) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(LibraryStore.self) private var store
    @State private var own: [CustomSticker] = []
    @State private var pickingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var isCutting = false
    @State private var uncut: UIImage?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x6) {
                    VStack(alignment: .leading, spacing: Space.x3) {
                        Text("My Stickers").metaStyle(.footnote).accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: columns, spacing: Space.x3) {
                            newTile
                            ForEach(Array(own.enumerated()), id: \.element.id) { index, sticker in ownTile(sticker, number: own.count - index) }
                        }
                        if own.isEmpty {
                            Text("Pick a photo and OwlLuna lifts its subject out as a sticker you can use in any notebook.")
                                .font(.footnote)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    ForEach(Sticker.Family.allCases) { family in
                        VStack(alignment: .leading, spacing: Space.x3) {
                            Text(family.displayName).metaStyle(.footnote).accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: columns, spacing: Space.x3) {
                                ForEach(family.stickers) { tile($0) }
                            }
                        }
                    }
                    Text("Stickers sit under your ink, so you can write on a note or a label. Touch and hold one on the page to move, resize or remove it.")
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(Space.x5)
            }
            .accessibilityIdentifier("sticker.drawer")
            .background(Color.surface)
            .navigationTitle("Stickers")
            .barGround(.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                CancelToolbarItem { dismiss() }
            }
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await cutOut(item) }
        }
        .task { await reload() }
        .notice("No Subject Found", isPresented: Binding(isPresent: $uncut),
                message: Text("OwlLuna couldn't find a clear subject to lift out of this photo. You can use the whole photo as a sticker instead.")) {
            Button("Cancel", role: .cancel) {}
            Button("Use Whole Photo") { if let uncut { keepWhole(uncut) } }
        }
        .notice("Something went wrong", message: $failure)
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 96), spacing: Space.x3)] }

    private func reload() async {
        let root = store.root
        own = await Task.detached(priority: .userInitiated) { StickerShelf.list(root) }.value
    }

    private func cutOut(_ item: PhotosPickerItem) async {
        defer { photo = nil; isCutting = false }
        isCutting = true
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
            failure = StickerCutout.Failure.unreadable.localizedDescription
            return
        }
        let root = store.root
        do {
            let photo = SharedPhoto(image: image)
            _ = try await Task.detached(priority: .userInitiated) { try StickerShelf.add(StickerCutout.sticker(from: photo.image), to: root) }.value
            await reload()
            AccessibilityNotification.Announcement(String(localized: "Sticker made")).post()
        } catch StickerCutout.Failure.noSubject {
            uncut = image
        } catch {
            failure = error.localizedDescription
        }
    }

    private func keepWhole(_ image: UIImage) {
        let root = store.root, photo = SharedPhoto(image: image)
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try StickerShelf.add(StickerCutout.wholePhoto(photo.image), to: root) }.value
                await reload()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private var newTile: some View {
        Button { pickingPhoto = true } label: {
            VStack(spacing: Space.x1) {
                if isCutting {
                    ProgressView()
                } else {
                    Image(systemName: "plus").font(.title3.weight(.semibold))
                }
                Text(isCutting ? "Cutting Out…" : "From Photo…").font(.caption.weight(.medium))
            }
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(Color.paper, in: RoundedRectangle.plate)
            .overlay { RoundedRectangle.plate.strokeBorder(Color.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .disabled(isCutting)
        .accessibilityLabel(Text(isCutting ? "Cutting out the sticker" : "New Sticker from Photo"))
        .accessibilityHint(Text("Lifts the subject out of a photo you pick"))
        .accessibilityIdentifier("sticker.new")
    }

    /// A sticker on its paper tile. Picking it closes the drawer.
    private func tile<Art: View>(picking pick: @escaping () -> Void, @ViewBuilder art: () -> Art) -> some View {
        Button {
            pick()
            dismiss()
        } label: {
            art()
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(Color.paper, in: RoundedRectangle.plate)
                .overlay { RoundedRectangle.plate.strokeBorder(Color.hairline) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }

    private func ownTile(_ sticker: CustomSticker, number: Int) -> some View {
        tile(picking: { onPickOwn(sticker) }) {
            OwnStickerImage(sticker: sticker).frame(maxWidth: 64, maxHeight: 56)
        }
        .heldMenu(Text("Sticker")) {
            Button(role: .destructive) { remove(sticker) } label: { Label("Delete Sticker", systemImage: "trash") }
        }
        .accessibilityLabel(Text("My sticker \(number)"))
        .accessibilityHint(Text("Adds this sticker to the page"))
        .accessibilityAction(named: Text("Delete Sticker")) { remove(sticker) }
        .accessibilityIdentifier("sticker.mine.\(number)")
    }

    private func remove(_ sticker: CustomSticker) {
        StickerShelf.remove(sticker)
        own.removeAll { $0 == sticker }
    }

    private func tile(_ sticker: Sticker) -> some View {
        tile(picking: { onPick(sticker) }) {
            Image(uiImage: sticker.image(width: 160, scale: displayScale))
                .resizable()
                .aspectRatio(sticker.aspect, contentMode: .fit)
                .frame(maxWidth: sticker.aspect > 1.2 ? 84 : 56, maxHeight: 56)
        }
        .accessibilityLabel(Text(sticker.displayName))
        .accessibilityHint(Text("Adds this sticker to the page"))
        .accessibilityIdentifier("sticker.\(sticker.rawValue)")
    }
}

private struct SharedPhoto: @unchecked Sendable {
    let image: UIImage
}

private struct OwnStickerImage: View {
    let sticker: CustomSticker
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: sticker.id) {
            let url = sticker.url
            image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path(percentEncoded: false)).map { SharedPhoto(image: $0.preparingThumbnail(of: CGSize(width: 240, height: 240)) ?? $0) }
            }.value?.image
        }
    }
}
