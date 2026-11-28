import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

extension UTType {
    static let notebookReference = UTType(exportedAs: "com.owais.owlluna.notebook-reference")
}

/// What a dragged notebook carries: its identity, typed so it can't be pasted into another app as text.
struct NotebookReference: Codable, Transferable, Hashable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .notebookReference)
    }
}

/// Renders covers in a few fixed widths so the cache is shared across the library, the spread and sheets.
enum CoverWidth {
    static let shelf: CGFloat = 176
    static let spread: CGFloat = 220
    static let preview: CGFloat = 260
    static let row: CGFloat = 64
}

struct CoverView: View {
    let request: CoverRequest
    /// False for the live preview, whose every keystroke would otherwise fill the caches.
    var persist = true
    var showsShadow = true
    /// A locked notebook's cover is blurred past reading, under a padlock.
    var isObscured = false
    var prepareFirstPage: (@MainActor () async -> Void)?
    @State private var image: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    init(request: CoverRequest, persist: Bool = true, showsShadow: Bool = true, isObscured: Bool = false,
         prepareFirstPage: (@MainActor () async -> Void)? = nil) {
        self.request = request
        self.persist = persist
        self.showsShadow = showsShadow
        self.isObscured = isObscured
        self.prepareFirstPage = prepareFirstPage
        _image = State(initialValue: CoverCache.shared.cached(request.key))
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: Radius.coverSpine, bottomLeadingRadius: Radius.coverSpine,
                               bottomTrailingRadius: Radius.coverEdge, topTrailingRadius: Radius.coverEdge)
    }

    var body: some View {
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().interpolation(.high)
                        .blur(radius: isObscured ? max(request.width * 0.09, 5) : 0, opaque: true)
                        .clipShape(shape)
                        .transition(.opacity)
                } else {
                    shape.fill(placeholder)
                }
            }
            .overlay { if isObscured { LockBadge(diameter: min(max(request.width * 0.3, 20), 52)) } }
            .overlay { if contrast == .increased { shape.strokeBorder(Color.hairline, lineWidth: 1) } }
            .background { if showsShadow { CoverShadowView() } }
            .task(id: request.key) {
                if let hit = CoverCache.shared.cached(request.key) { image = hit; return }
                if !persist {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                }
                if request.spec.style == .firstPage, let file = request.firstPage,
                   !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                    await prepareFirstPage?()
                }
                if let rendered = await CoverCache.shared.image(for: request, persist: persist) {
                    withAnimation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion)) { image = rendered }
                }
            }
            .accessibilityHidden(true)
    }

    private var placeholder: Color {
        switch request.spec.style {
        case .cloth: request.spec.cloth.color
        case .print: Color(hex: RisoInk.paperStock)
        case .firstPage: .white
        }
    }
}

/// A favourite's index flag, tucked between the pages behind a cover and sticking out of its fore-edge.
struct FavoriteFlag: View {
    let coverWidth: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    static func reach(for coverWidth: CGFloat) -> CGFloat { min(max(coverWidth * 0.07, 8), 14) }

    var body: some View {
        let reach = Self.reach(for: coverWidth)
        let height = min(max(coverWidth * 0.15, 16), 30)
        let shape = UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2)
        shape.fill(Color.tomato)
            .overlay { if contrast == .increased { shape.strokeBorder(Color.ink.opacity(0.6), lineWidth: 1) } }
            .overlay(alignment: .trailing) {
                Image(systemName: "star.fill")
                    .font(.system(size: height * 0.46, weight: .bold))
                    .foregroundStyle(Color.onTomato)
                    .frame(width: reach)
            }
            .frame(width: reach * 2, height: height)
            .offset(x: reach, y: max((coverWidth * 0.13).rounded(), Radius.coverEdge + 1))
            .accessibilityHidden(true)
    }
}

extension View {
    /// The favourite flag behind a cover this wide, sliding out from between the pages when it is favourited.
    func favoriteFlag(_ shown: Bool, coverWidth: CGFloat) -> some View {
        modifier(FavoriteFlagBehind(shown: shown, coverWidth: coverWidth))
    }
}

private struct FavoriteFlagBehind: ViewModifier {
    let shown: Bool
    let coverWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.background(alignment: .topTrailing) {
            ZStack {
                if shown {
                    FavoriteFlag(coverWidth: coverWidth)
                        .transition(reduceMotion ? .opacity : .offset(x: -FavoriteFlag.reach(for: coverWidth) * 2))
                }
            }
            .animation(Motion.adaptive(Motion.ribbon, reduceMotion: reduceMotion), value: shown)
        }
    }
}

extension NotebookRecord {
    @MainActor
    func coverRequest(width: CGFloat, scale: CGFloat, colorScheme: ColorScheme, contrast: ColorSchemeContrast, root: StorageRoot,
                      spec: CoverSpec? = nil, even: Bool = EvenHighlights.isOn) -> CoverRequest {
        let spec = spec ?? cover
        let package = NotebookPackage(root: root, id: id)
        let thumbKey = (firstPageThumbKey ?? "none") + (even ? PageThumbnailer.evenSuffix : "")
        let thumb = firstPageID.map { package.thumbURL($0, key: thumbKey) }
        return CoverRequest(notebookID: id, spec: spec, title: title.orUntitled,
                            meta: folder?.name ?? createdAt.formatted(.dateTime.month(.abbreviated).year()), width: width, scale: scale,
                            dark: colorScheme == .dark, highContrast: contrast == .increased, firstPage: thumb,
                            firstPageKey: spec.style == .firstPage ? "\(firstPageID?.uuidString ?? "")-\(thumbKey)" : nil,
                            firstPageIsPDF: firstPageIsPDF)
    }

    var pageCountText: String {
        String(localized: "\(pageCount) pages")
    }

    var metaLine: String {
        "\(pageCountText) · \(modifiedAt.formatted(.relative(presentation: .named)))"
    }

    func accessibilityHint(isSelecting: Bool) -> String {
        if isSelecting { return String(localized: "Selects or deselects this notebook") }
        if isTrashed { return String(localized: "Deleted. Use actions to restore it or delete it permanently.") }
        return String(localized: "Opens the notebook")
    }

    var accessibilityDescription: String {
        var parts = [title.orUntitled, String(localized: "notebook"),
                     pageCountText,
                     String(localized: "edited \(modifiedAt.formatted(.relative(presentation: .named)))")]
        if isFavorite { parts.append(String(localized: "favourite")) }
        if let folder { parts.append(String(localized: "in \(folder.name)")) }
        if !tags.isEmpty { parts.append(String(localized: "tagged \(tags.formatted(.list(type: .and)))")) }
        if isLocked { parts.append(String(localized: "locked")) }
        if isReadOnly { parts.append(String(localized: "read-only")) }
        if issueCount > 0 { parts.append(String(localized: "has files that couldn't be read")) }
        return parts.joined(separator: ", ")
    }
}
