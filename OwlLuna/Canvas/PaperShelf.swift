import UIKit
import PDFKit
import ImageIO

/// Paper the user added from a PDF or a picture. Kept beside the library, as their stickers are, so every notebook can use it.
struct CustomPaper: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    /// A PDF's own size; a picture has none, so it is given the width of US Letter.
    let size: CGSize

    var isPDF: Bool { url.pathExtension == "pdf" }

    func background(file: String) -> PageBackground { isPDF ? .pdf(file: file, index: 0) : .image(file: file) }

    func fitted(width: CGFloat) -> CGSize {
        CGSize(width: width, height: (width * size.height / max(size.width, 1)).rounded())
    }

    /// A PDF keeps the size it was made at, and a picture takes `width`.
    func newPageSize(width: CGFloat) -> CGSize { isPDF ? size : fitted(width: width) }

    /// The page it makes, drawn from the shelf, for its miniature.
    var preview: NotebookPage { NotebookPage(background: background(file: url.lastPathComponent), paperColor: .white, size: size) }
}

/// The user's paper as one notebook keeps it: its own copy among the notebook's files, and the page that copy makes.
struct NotebookPaper: Sendable, Hashable {
    var id: String
    var background: PageBackground
    var size: CGSize

    func page(size: CGSize? = nil) -> NotebookPage {
        var page = NotebookPage(background: background, paperColor: .white, size: size ?? self.size)
        page.paperID = id
        return page
    }
}

enum PaperShelf {
    static let extensions: Set<String> = ["pdf", "jpg", "png"]
    private static let nameLimit = 80

    /// By name.
    static func list(_ root: StorageRoot) -> [CustomPaper] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root.papers, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap(paper(at:)).sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    static func paper(_ id: String, in root: StorageRoot) -> CustomPaper? {
        list(root).first { $0.id == id }
    }

    /// Files are named "<name> <id>.<ext>", so the folder alone says what each paper is called and sync copies one file.
    static func paper(at url: URL) -> CustomPaper? {
        let base = url.deletingPathExtension().lastPathComponent
        guard extensions.contains(url.pathExtension), base.count > 37, UUID(uuidString: String(base.suffix(36))) != nil,
              let size = size(of: url) else { return nil }
        return CustomPaper(id: String(base.suffix(36)), name: String(base.dropLast(37)), url: url, size: size)
    }

    /// Keeps the first page of a PDF, upright and with what was written on it, as a PDF of its own. The copy has no lock:
    /// a locked PDF is opened with `password`.
    @discardableResult
    static func add(pdf source: URL, name: String, to root: StorageRoot, password: String = "") throws -> CustomPaper {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        guard let document = CGPDFDocument(source as CFURL) else { throw ImportError.unreadable }
        if document.isEncrypted && !document.isUnlocked && !document.unlockWithPassword(password) { throw ImportError.locked }
        guard let page = document.page(at: 1) else { throw ImportError.empty }
        let bounds = CGRect(origin: .zero, size: PageRenderer.displaySize(of: page))
        guard bounds.width >= 1, bounds.height >= 1 else { throw ImportError.empty }
        let marked = PDFMarks.has(page) ? PDFDocument(url: source) : nil
        if let marked, marked.isLocked { _ = marked.unlock(withPassword: password) }
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            PageRenderer.drawPDFPage(page, in: context.cgContext, size: bounds.size, marks: marked?.page(at: 0).map { .page($0) })
        }
        return try write(data, name: name, ext: "pdf", to: root)
    }

    /// The same for a file chosen in Files. A locked PDF is asked for its password until it opens.
    @discardableResult
    static func add(file source: URL, to root: StorageRoot, password: PDFImport.Password?) async throws -> CustomPaper {
        guard source.pathExtension.lowercased() == "pdf" else {
            return try await Task.detached(priority: .userInitiated) { try add(file: source, to: root) }.value
        }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let typed = try await PDFImport.password(for: source, asking: password) { typed in
            guard let document = CGPDFDocument(source as CFURL) else { throw ImportError.unreadable }
            return document.unlockWithPassword(typed)
        }
        let name = source.deletingPathExtension().lastPathComponent
        return try await Task.detached(priority: .userInitiated) { try add(pdf: source, name: name, to: root, password: typed ?? "") }.value
    }

    /// Keeps a picture upright, at most 2,400 px on its long side.
    @discardableResult
    static func add(image data: Data, name: String, to root: StorageRoot) throws -> CustomPaper {
        guard let image = UIImage(data: data) else { throw ImportError.unreadable }
        let picture = try PhotoImport.picture(image, longSide: 2400)
        return try write(picture.data, name: name, ext: picture.ext, to: root)
    }

    @discardableResult
    static func add(file source: URL, to root: StorageRoot) throws -> CustomPaper {
        let name = source.deletingPathExtension().lastPathComponent
        if source.pathExtension.lowercased() == "pdf" { return try add(pdf: source, name: name, to: root) }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: source) else { throw ImportError.unreadable }
        return try add(image: data, name: name, to: root)
    }

    static func rename(_ paper: CustomPaper, to name: String) throws -> CustomPaper {
        let target = paper.url.deletingLastPathComponent().appending(path: fileName(name: name, id: paper.id, ext: paper.url.pathExtension))
        guard target.lastPathComponent != paper.url.lastPathComponent else { return paper }
        try FileManager.default.moveItem(at: paper.url, to: target)
        return self.paper(at: target) ?? paper
    }

    /// Pages that already use the paper keep their own copy.
    static func remove(_ paper: CustomPaper) {
        try? FileManager.default.removeItem(at: paper.url)
    }

    static func fileName(name: String, id: String, ext: String) -> String { "\(cleaned(name)) \(id).\(ext)" }

    /// A name that can be part of a file's: no slashes, colons or line breaks, no leading dot, and not too long.
    static func cleaned(_ name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters)
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: unsafe).joined(separator: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(nameLimit)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? String(localized: "Paper") : cleaned
    }

    private static func write(_ data: Data, name: String, ext: String, to root: StorageRoot) throws -> CustomPaper {
        try FileManager.default.createDirectory(at: root.papers, withIntermediateDirectories: true)
        let url = root.papers.appending(path: fileName(name: name, id: UUID().uuidString, ext: ext))
        try data.write(to: url, options: .atomic)
        guard let paper = paper(at: url) else {
            try? FileManager.default.removeItem(at: url)
            throw ImportError.unreadable
        }
        return paper
    }

    private static func size(of url: URL) -> CGSize? {
        if url.pathExtension == "pdf" {
            guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return nil }
            let size = PageRenderer.displaySize(of: page)
            return size.width >= 1 && size.height >= 1 ? size : nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, width >= 1, height >= 1 else { return nil }
        let letter = PageSize.letter.points.width
        return CGSize(width: letter, height: (letter * height / width).rounded())
    }
}
