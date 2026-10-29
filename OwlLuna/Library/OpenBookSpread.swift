import SwiftUI

/// The last notebook opened, lying open at its page: the case, two facing pages and a ribbon keeping the place.
/// The editor zooms out of the right-hand page and back into it.
struct OpenBookSpread: View {
    let record: NotebookRecord
    let zoomNamespace: Namespace.ID
    let action: (String) -> Void
    @Environment(LibraryStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @PaperNight private var night
    @State private var pages: Pages?
    @State private var currentImage: UIImage?
    @State private var previousImage: UIImage?
    @State private var availableWidth: CGFloat = 0

    private struct Pages: Equatable {
        var current: NotebookPage
        var previous: NotebookPage?
    }

    private static let caseMargin: CGFloat = 8
    private static let stackDepth: CGFloat = 3
    private static let ribbonTail: CGFloat = 26

    private var zoomID: String { "spread-\(record.id.uuidString)" }
    private var pageNumber: Int { record.currentPage + 1 }
    private var title: String { record.title.orUntitled }

    var body: some View {
        let regular = sizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
        let pageHeight: CGFloat = regular ? 200 : compactPageHeight
        let sideBySide = regular && availableWidth >= bookWidth(pageHeight: pageHeight) + Space.x8 + 280
        let layout = sideBySide ? AnyLayout(HStackLayout(alignment: .center, spacing: Space.x8))
                                : AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x4))
        Button { action(zoomID) } label: {
            layout {
                book(pageHeight: pageHeight)
                caption
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Continue writing \(title), page \(pageNumber) of \(record.pageCount)"))
        .accessibilityHint(Text("Opens at this page"))
        .accessibilityAddTraits(.isButton)
        .task(id: "\(record.id)-\(record.currentPage)-\(record.modifiedAt.timeIntervalSince1970)-\(night)") { await load() }
    }

    // MARK: The book

    /// Each page at the current page's proportions; a landscape page is narrowed to keep the spread compact.
    private func pageSize(height: CGFloat) -> CGSize {
        let aspect = pages.map { $0.current.shownSize.width / max($0.current.shownSize.height, 1) } ?? PageSize.letter.points.width / PageSize.letter.points.height
        let width = min(height * aspect, height * 0.9)
        return CGSize(width: width.rounded(), height: (width / aspect).rounded())
    }

    /// On a narrow screen the book spans the width, up to a size that still leaves the shelf in view.
    private var compactPageHeight: CGFloat {
        guard availableWidth > 0 else { return 170 }
        let aspect = pageSize(height: 100).width / 100
        let fits = (availableWidth - (Self.stackDepth + Self.caseMargin) * 2) / 2 / max(aspect, 0.1)
        return min(max(fits.rounded(.down), 170), 280)
    }

    private func bookWidth(pageHeight: CGFloat) -> CGFloat {
        pageSize(height: pageHeight).width * 2 + (Self.stackDepth + Self.caseMargin) * 2
    }

    private func book(pageHeight: CGFloat) -> some View {
        let page = pageSize(height: pageHeight)
        return HStack(spacing: 0) {
            leftPage.frame(width: page.width, height: page.height).clipped()
            rightPage.frame(width: page.width, height: page.height).clipped()
                .zoomSource(id: zoomID, in: zoomNamespace)
        }
        .overlay { gutter }
        .background {
            Color.labelCream
                .overlay { Rectangle().strokeBorder(Color.hairline, lineWidth: 1) }
                .padding(.horizontal, -Self.stackDepth)
                .padding(.bottom, -Self.stackDepth)
        }
        .padding(.horizontal, Self.stackDepth + Self.caseMargin)
        .padding(.top, Self.caseMargin)
        .padding(.bottom, Self.stackDepth + Self.caseMargin)
        .background { bookCase }
        .background { CoverShadowView() }
        .overlay(alignment: .topTrailing) { ribbon(height: page.height + Self.stackDepth + Self.caseMargin + Self.ribbonTail) }
        .padding(.bottom, Self.ribbonTail)
    }

    @ViewBuilder
    private var leftPage: some View {
        if record.currentPage == 0 {
            Bookplate(title: title, started: record.createdAt)
        } else if let previousImage {
            Image(uiImage: previousImage).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
        } else {
            placeholder(pages?.previous)
        }
    }

    @ViewBuilder
    private var rightPage: some View {
        if let currentImage {
            Image(uiImage: currentImage).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
        } else {
            placeholder(pages?.current)
        }
    }

    /// The page's own paper until its thumbnail arrives; paper never inverts, so nothing flashes in dark mode.
    private func placeholder(_ page: NotebookPage?) -> Color {
        page.map { Color(uiColor: $0.paperShown(night: night)) } ?? Color.surface
    }

    /// The seam, shaded where the pages curve into it; a plain rule with Increase Contrast.
    @ViewBuilder
    private var gutter: some View {
        if contrast == .increased {
            Color.hairline.frame(width: 1)
        } else {
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                   .init(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.14), location: 0.5),
                                   .init(color: .black.opacity(0), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 24)
        }
    }

    /// The cloth, dimmed for Print and first-page covers whose cloth only shows on the spine, and on the night desk.
    private var bookCase: some View {
        let dim = (record.coverStyle == .cloth ? 0 : 0.18) + (colorScheme == .dark ? 0.1 : 0)
        return RoundedRectangle(cornerRadius: Radius.coverEdge)
            .fill(record.cloth.color)
            .overlay { RoundedRectangle(cornerRadius: Radius.coverEdge).fill(.black.opacity(dim)) }
            .overlay {
                if contrast == .increased { RoundedRectangle(cornerRadius: Radius.coverEdge).strokeBorder(Color.hairline, lineWidth: 1) }
            }
    }

    private func ribbon(height: CGFloat) -> some View {
        Text(pageNumber, format: .number)
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(record.cloth.onCloth)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Space.x1)
            .frame(minWidth: 26)
            .padding(.bottom, 26 * RibbonShape.notch + Space.x1)
            .frame(height: height, alignment: .bottom)
            .background {
                RibbonShape()
                    .fill(record.cloth.color)
                    .overlay { RibbonShape().stroke(Color.labelCream, lineWidth: 1.5) }
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
            }
            .padding(.top, Self.caseMargin)
            .padding(.trailing, Self.caseMargin + Self.stackDepth + Space.x6)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text("Continue writing")
                .eyebrowStyle(Color.accentColor)
            Text(title)
                .displayFont(26, relativeTo: .title2)
                .foregroundStyle(Color.ink)
                .lineLimit(2)
            Text("Page \(pageNumber) of \(record.pageCount) · edited \(record.modifiedAt.formatted(.relative(presentation: .named)))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.textSecondary)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Loading

    private func load() async {
        let package = NotebookPackage(root: store.root, id: record.id)
        guard let manifest = try? await package.readManifest().manifest, !manifest.pages.isEmpty else { return }
        let index = min(record.currentPage, manifest.pages.count - 1)
        let loaded = Pages(current: manifest.pages[index], previous: index > 0 ? manifest.pages[index - 1] : nil)
        if loaded != pages { pages = loaded }
        async let current = PageThumbnailer.thumbnail(package: package, page: loaded.current, night: night)
        async let previous = Self.thumbnail(package: package, page: loaded.previous, night: night)
        let images = await (current, previous)
        guard !Task.isCancelled else { return }
        withAnimation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion)) {
            currentImage = images.0
            previousImage = images.1
        }
    }

    private static func thumbnail(package: NotebookPackage, page: NotebookPage?, night: Bool) async -> UIImage? {
        guard let page else { return nil }
        return await PageThumbnailer.thumbnail(package: package, page: page, night: night)
    }
}

/// Page 1's facing page: a cream bookplate with the title and when the notebook was started.
private struct Bookplate: View {
    let title: String
    let started: Date

    var body: some View {
        VStack(spacing: Space.x2) {
            Text("Ex libris")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.6)
            Color.labelInk.opacity(0.3).frame(width: 20, height: 1)
            Text(title)
                .displayFont(17, relativeTo: .headline)
                .lineLimit(3)
            Text("Started \(started.formatted(.dateTime.month(.wide).year()))")
                .font(.caption)
        }
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.7)
        .foregroundStyle(Color.labelInk)
        .padding(Space.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            Rectangle().strokeBorder(Color.labelInk.opacity(0.3), lineWidth: 1).padding(Space.x2)
            Rectangle().strokeBorder(Color.labelInk.opacity(0.18), lineWidth: 1).padding(Space.x2 + 3)
        }
        .background(Color.labelCream)
    }
}
