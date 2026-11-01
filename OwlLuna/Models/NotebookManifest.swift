import Foundation
import CoreGraphics

enum PageBackground: Sendable, Hashable {
    case template(String)
    case pdf(file: String, index: Int)
    case image(file: String)
    case unknown(JSONValue)

    static func template(_ template: PaperTemplate) -> PageBackground { .template(template.rawValue) }

    var template: PaperTemplate? {
        if case .template(let raw) = self { return PaperTemplate(rawValue: raw) ?? .blank }
        return nil
    }

    var assetFile: String? {
        switch self {
        case .pdf(let file, _), .image(let file): file
        case .template, .unknown: nil
        }
    }
}

struct NotebookPage: Sendable, Hashable, Identifiable {
    var id: UUID
    var background: PageBackground
    var paperColorRaw: String
    var size: CGSize
    var inkHash: String?
    var extra: [String: JSONValue] = [:]
    var undecoded: [String: UndecodedField] = [:]

    init(id: UUID = UUID(), background: PageBackground, paperColor: PaperColor, size: CGSize, inkHash: String? = nil) {
        self.id = id
        self.background = background
        self.paperColorRaw = paperColor.rawValue
        self.size = size
        self.inkHash = inkHash
    }

    static func template(_ template: PaperTemplate, color: PaperColor, size: PageSize) -> NotebookPage {
        NotebookPage(background: .template(template), paperColor: color, size: size.points)
    }

    var paperColor: PaperColor {
        get { PaperColor(rawValue: paperColorRaw) ?? .white }
        set { paperColorRaw = newValue.rawValue }
    }

    var template: PaperTemplate? { background.template }

    var effectivePaperColor: PaperColor { template == nil ? .white : paperColor }

    var inkFile: String { "ink/\(id.uuidString).pkdrawing" }

    /// A copy with a new identity and no ink, for duplicating structure.
    func duplicated() -> NotebookPage {
        var copy = self
        copy.id = UUID()
        copy.day = nil
        copy.extra["bookmark"] = nil
        return copy
    }

    static let pdfThumbnailPrefix = "pdf-marks-"

    /// Names a thumbnail by the page's ink and by how the page looks, so a template or paper change isn't served stale.
    var thumbnailKey: String {
        let version: String = if case .pdf = background { Self.pdfThumbnailPrefix } else { "" }
        return "\(version)\(inkHash?.prefix(12) ?? "blank")-\(appearanceKey)"
    }

    var appearanceKey: String {
        let backgroundKey = switch background {
        case .template(let raw): "t:\(raw)"
        case .pdf(let file, let index): "p:\(file)#\(index)|marks"
        case .image(let file): "i:\(file)"
        case .unknown(let raw): "u:" + ((try? raw.serialized(pretty: false)).map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        let dayKey = day.map { "|d:\($0)" } ?? ""
        let itemsKey = extra["items"].flatMap { try? $0.serialized(pretty: false) }.map { "|i:" + String(decoding: $0, as: UTF8.self) } ?? ""
        // Builds before text styles drew these boxes plainly and cached that under the same key.
        let styled = extra["items"]?.arrayValue?.contains { item in
            item["kind"]?.stringValue == "text" && ["face", "italic", "underline", "list", "highlight"].contains { item[$0] != nil }
        } == true
        let hash = fnv1a("\(backgroundKey)|\(paperColorRaw)|\(Int(size.width))x\(Int(size.height))\(dayKey)\(itemsKey)\(styled ? "|styled" : "")")
        return String(hash, radix: 16).prefix(8).description
    }
}

/// The 64-bit FNV-1a hash of `text`'s UTF-8 bytes.
func fnv1a(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01b3 }
    return hash
}

extension NotebookPage {
    /// "yyyy-MM-dd" on a daily-journal page; older builds keep it as an unknown key.
    var day: String? {
        get { extra["date"]?.stringValue }
        set { extra["date"] = newValue.map(JSONValue.string) }
    }

    /// The user's own paper that the page's PDF or picture is a copy of. Older builds keep it as an unknown key.
    var paperID: String? {
        get { extra["paper"]?.stringValue }
        set { extra["paper"] = newValue.map(JSONValue.string) }
    }

    var notebookPaper: NotebookPaper? {
        guard let paperID, background.assetFile != nil else { return nil }
        return NotebookPaper(id: paperID, background: background, size: size)
    }
}

struct PageDefaults: Sendable, Hashable {
    var templateRaw: String
    var paperColorRaw: String
    var pageSizeRaw: String
    var extra: [String: JSONValue] = [:]
    var undecoded: [String: UndecodedField] = [:]

    init(template: PaperTemplate, paperColor: PaperColor, pageSize: PageSize) {
        templateRaw = template.rawValue
        paperColorRaw = paperColor.rawValue
        pageSizeRaw = pageSize.rawValue
    }

    init(templateRaw: String, paperColorRaw: String, pageSizeRaw: String, extra: [String: JSONValue],
         undecoded: [String: UndecodedField] = [:]) {
        self.templateRaw = templateRaw
        self.paperColorRaw = paperColorRaw
        self.pageSizeRaw = pageSizeRaw
        self.extra = extra
        self.undecoded = undecoded
    }

    var template: PaperTemplate { PaperTemplate(rawValue: templateRaw) ?? .narrowRuled }
    var paperColor: PaperColor { PaperColor(rawValue: paperColorRaw) ?? .white }
    var pageSize: PageSize { PageSize(rawValue: pageSizeRaw) ?? .letter }

    func newPage() -> NotebookPage { paper?.page() ?? .template(template, color: paperColor, size: pageSize) }
}

extension PageDefaults {
    /// A notebook started on the user's own paper makes new pages on its copy. Older builds keep it as an unknown key and use the template.
    var paper: NotebookPaper? {
        get {
            guard let object = extra["paper"]?.objectValue, let id = object["id"]?.stringValue,
                  case let background = ManifestCodec.decodeBackground(object["background"]), background.assetFile != nil,
                  let width = object["width"]?.doubleValue, let height = object["height"]?.doubleValue, width >= 1, height >= 1 else { return nil }
            return NotebookPaper(id: id, background: background, size: CGSize(width: width, height: height))
        }
        set {
            extra["paper"] = newValue.map { paper in
                .object(["id": .string(paper.id), "background": ManifestCodec.encodeBackground(paper.background),
                         "width": .number(paper.size.width), "height": .number(paper.size.height)])
            }
        }
    }
}

struct RecordingEntry: Sendable, Hashable, Identifiable {
    var id: UUID
    var file: String
    var createdAt: Date
    var duration: TimeInterval
    var extra: [String: JSONValue] = [:]
    var undecoded: [String: UndecodedField] = [:]
}

extension String {
    /// A notebook's title as shown: "Untitled" while it has none.
    var orUntitled: String { isEmpty ? String(localized: "Untitled") : self }
}

extension NotebookManifest {
    /// Recordings being made, or cut off before Stop, so their audio is named. Older builds keep them as an unknown key.
    var unfinishedRecordings: [RecordingEntry] {
        get { extra["unfinishedRecordings"]?.arrayValue?.compactMap(ManifestCodec.decodeRecording) ?? [] }
        set { extra["unfinishedRecordings"] = newValue.isEmpty ? nil : .array(newValue.map(ManifestCodec.encodeRecording)) }
    }
}

extension RecordingEntry {
    /// The device an unfinished recording is being made on (`StorageRoot.deviceID`): only that one takes it up.
    var device: String? {
        get { extra["device"]?.stringValue }
        set { extra["device"] = newValue.map(JSONValue.string) }
    }
}

struct LibraryState: Sendable, Hashable {
    var isFavorite = false
    var deletedAt: Date?
    var folderID: UUID?
    var lastOpenedAt: Date?
    var currentPage = 0
    var extra: [String: JSONValue] = [:]
    var undecoded: [String: UndecodedField] = [:]
}

extension LibraryState {
    /// A locked notebook asks who is holding the iPad before it opens. Older builds keep it as an unknown key.
    var isLocked: Bool {
        get { extra["locked"]?.boolValue ?? false }
        set { extra["locked"] = newValue ? .bool(true) : nil }
    }

    /// The daily journal, marked in its own manifest so that every device that syncs uses the same one. Older builds keep it as an unknown key.
    var isJournal: Bool {
        get { extra["journal"]?.boolValue ?? false }
        set { extra["journal"] = newValue ? .bool(true) : nil }
    }

    /// What follows a notebook to other devices without counting as writing in it.
    enum Filing: String, CaseIterable, Sendable {
        case favorite, locked, folder, tags, deleted, journal
    }

    /// When each of those was last changed here. Sync settles them one by one and apart from the pages, so a lock is
    /// only ever taken off by a later unlock. Older builds keep the stamps as an unknown key.
    func changedAt(_ filing: Filing) -> Date? {
        extra.changedAt(filing.rawValue)
    }

    mutating func setChangedAt(_ date: Date?, for filing: Filing) {
        extra.setChangedAt(date, for: filing.rawValue)
    }

    func files(_ filing: Filing, like other: LibraryState) -> Bool {
        switch filing {
        case .favorite: isFavorite == other.isFavorite
        case .locked: isLocked == other.isLocked
        case .folder: folderID == other.folderID
        case .tags: tags == other.tags
        case .journal: isJournal == other.isJournal
        case .deleted:
            // Dates are kept to the millisecond.
            if let deletedAt, let theirs = other.deletedAt { abs(deletedAt.timeIntervalSince(theirs)) < 0.0005 } else { deletedAt == other.deletedAt }
        }
    }

    /// A stamp for a change made at `date` that still comes after `last`, even when `last` came from a device whose
    /// clock runs fast.
    static func stamp(after last: Date?, at date: Date) -> Date {
        max(date, (last ?? .distantPast).addingTimeInterval(0.001))
    }

    /// Stamps a change made here, after every stamp this device has seen for it.
    mutating func stampChange(_ filing: Filing, at date: Date) {
        setChangedAt(Self.stamp(after: changedAt(filing), at: date), for: filing)
    }

    /// Stamps whatever a change just made differs from how the notebook was filed before it.
    mutating func stamp(changesSince before: LibraryState, at date: Date) {
        for filing in Filing.allCases where !files(filing, like: before) { stampChange(filing, at: date) }
    }
}

struct UndecodedField: Sendable, Hashable {
    var raw: JSONValue
    var fallback: JSONValue
}

/// A page from the manifest that this version can't read. Kept verbatim and written back after `anchor`.
struct OpaquePage: Sendable, Hashable {
    var anchor: UUID?
    var raw: JSONValue
}

struct NotebookManifest: Sendable, Hashable {
    static let currentSchemaVersion = 2

    var schemaVersion = NotebookManifest.currentSchemaVersion
    var id: UUID
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var cover: CoverSpec
    var defaults: PageDefaults
    var pages: [NotebookPage]
    var opaquePages: [OpaquePage] = []
    var recordings: [RecordingEntry] = []
    var opaqueRecordings: [JSONValue] = []
    var library = LibraryState()
    var extra: [String: JSONValue] = [:]
    var undecoded: [String: UndecodedField] = [:]

    init(id: UUID = UUID(), title: String, createdAt: Date = .now, cover: CoverSpec? = nil,
         defaults: PageDefaults, pages: [NotebookPage]) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.cover = cover ?? .defaultCloth(for: id)
        self.defaults = defaults
        self.pages = pages
    }

    /// Newer schema versions open read-only so an older build never rewrites data it doesn't understand.
    var isNewerThanSupported: Bool { schemaVersion > Self.currentSchemaVersion }
}
