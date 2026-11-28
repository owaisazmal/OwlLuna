import UIKit
import PencilKit
import os

/// Page thumbnails, rendered off the main thread and cached in the package's `thumbs/` folder by ink and appearance, and by
/// whether highlights are even.
enum PageThumbnailer {
    static let pixelWidth: CGFloat = 360
    private static let memory = LRUCache<SharedUIImage>(capacity: 120)
    private static let signposter = OSSignposter(category: "thumbnails")

    struct SharedUIImage: @unchecked Sendable { let image: UIImage }

    /// Light paper shown dark has a thumbnail of its own, beside the one in the paper's colour, and even highlights another.
    static func key(for page: NotebookPage, night: Bool, even: Bool = EvenHighlights.isOn) -> String {
        (page.turnsDark(night) ? page.thumbnailKey + nightSuffix : page.thumbnailKey) + (even ? evenSuffix : "")
    }

    /// The names a page's thumbnails can have now, which the package's clean-up keeps.
    static func keys(for page: NotebookPage, even: Bool = EvenHighlights.isOn) -> [String] {
        [page.thumbnailKey, page.thumbnailKey + nightSuffix].map { $0 + (even ? evenSuffix : "") }
    }

    static let nightSuffix = "-night"
    static let evenSuffix = "-even"

    /// Thumbnail of the saved page (its manifest ink hash). For unsaved ink, use `render(page:ink:assets:)`.
    static func thumbnail(package: NotebookPackage, page: NotebookPage, night: Bool = false, even: Bool = EvenHighlights.isOn) async -> UIImage? {
        let name = key(for: page, night: night, even: even)
        let file = package.thumbURL(page.id, key: name)
        let key = file.path(percentEncoded: false)
        if let hit = memory.value(key, create: { nil }) { return hit.image }
        let assets = package.assetsDirectory
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return image.preparingForDisplay() ?? image }
            let ink: PKDrawing
            switch await package.readInk(page.id) {
            case .ink(let drawing, _): ink = drawing
            case .empty, .quarantined, .cancelled: ink = PKDrawing()
            }
            let image = render(page: page, ink: ink, assets: assets, night: night, even: even)
            if let png = image.pngData() { try? await package.writeThumbnail(png, pageID: page.id, key: name) }
            return image
        }.value
        if let image { _ = memory.value(key) { SharedUIImage(image: image) } }
        return image
    }

    static func render(page: NotebookPage, ink: PKDrawing, assets: URL, night: Bool = false, even: Bool = EvenHighlights.isOn) -> UIImage {
        let interval = signposter.beginInterval("Thumbnail")
        defer { signposter.endInterval("Thumbnail", interval) }
        return PageRenderer.image(of: page, ink: ink, assets: assets, width: pixelWidth, scale: 1, night: night, evenHighlights: even)
    }

    /// Makes sure the first page's thumbnail exists on disk, for first-page covers.
    static func ensureFirstPage(root: StorageRoot, notebookID: UUID, even: Bool = EvenHighlights.isOn) async {
        let package = NotebookPackage(root: root, id: notebookID)
        guard let page = try? await package.readManifest().manifest.pages.first else { return }
        let file = package.thumbURL(page.id, key: key(for: page, night: false, even: even))
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return }
        _ = await thumbnail(package: package, page: page, even: even)
    }
}
