import SwiftUI
import PencilKit
import PhotosUI
import UniformTypeIdentifiers

/// Picks paper from miniatures drawn by the page renderer: for a new page, or live on the current one.
struct PaperDrawer: View {
    enum Mode: Identifiable {
        case add(after: Int), change(pageID: UUID)

        var id: String {
            switch self {
            case .add(let index): "add-\(index)"
            case .change(let pageID): "change-\(pageID)"
            }
        }

        var isAdding: Bool {
            if case .add = self { true } else { false }
        }
    }

    let session: EditorSession
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.panelClose) private var panelClose
    @State private var template: PaperTemplate
    @State private var paperID: String?
    @State private var color: PaperColor
    @PaperNight private var night
    @State private var pageSize: PageSize?
    private let newPageSize: CGSize

    init(session: EditorSession, mode: Mode) {
        self.session = session
        self.mode = mode
        let page: NotebookPage = switch mode {
        case .add(let index): session.document.newPage(after: index)
        case .change(let pageID): session.document.pages.first { $0.id == pageID } ?? session.document.newPage(after: nil)
        }
        newPageSize = page.size
        _template = State(initialValue: page.template ?? .blank)
        _paperID = State(initialValue: page.paperID)
        _color = State(initialValue: page.paperColor)
        _pageSize = State(initialValue: PageSize.allCases.first { $0.points == page.size })
    }

    private var document: NotebookDocument { session.document }

    private var changing: NotebookPage? {
        guard case .change(let pageID) = mode else { return nil }
        return document.pages.first { $0.id == pageID }
    }

    private var selectedTemplate: PaperTemplate { changing?.template ?? template }
    private var selectedPaper: String? {
        if let changing { return changing.paperID }
        return paperID
    }

    /// A page on the user's own paper has no colour to change.
    private var keepsOwnColours: Bool { changing?.paperID != nil }
    private var selectedColor: PaperColor { changing?.paperColor ?? color }
    private var previewSize: CGSize { changing?.shownSize ?? pageSize?.points ?? newPageSize }
    private var isBoard: Bool { changing?.isBoard ?? false }

    private var hint: String {
        switch mode {
        case .add(let index): String(localized: "Adds a page after page \(index + 1)")
        case .change(let pageID): String(localized: "Changes page \((document.index(of: pageID) ?? 0) + 1)")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.x5) {
                        controls
                        Divider().overlay(Color.hairline)
                        PaperGallery(template: Binding(get: { selectedTemplate }, set: { template = $0 }), color: selectedColor,
                                     pageSize: previewSize, hint: { _ in hint }, onPick: pick, only: isBoard ? Whiteboard.templates : nil,
                                     own: isBoard ? nil : PaperGallery.Own(root: document.package.root, chosen: selectedPaper, hint: hint, onPick: pickPaper))
                    }
                    .padding(Space.x5)
                }
                .accessibilityIdentifier("paper.drawer")
                .onAppear { if let selectedPaper { proxy.scrollTo(selectedPaper) } else { proxy.scrollTo(selectedTemplate) } }
            }
            .background(Color.surface)
            .navigationTitle("Paper")
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { if panelClose == nil { header } }
            .onChange(of: changing == nil) { _, gone in if gone, !mode.isAdding { dismiss() } }
        }
        .frame(minWidth: 340, idealWidth: 560, minHeight: 440, idealHeight: 720)
    }

    /// A popover's bar tints whatever sits in it, so the title and Done are a row of their own.
    private var header: some View {
        ZStack(alignment: .trailing) {
            Text("Paper")
                .font(.headline)
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Button("Done") { dismiss() }.buttonStyle(.owlLuna(.primary, inBar: true))
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, Space.x4)
        .padding(.vertical, Space.x2)
        .background(Color.surface)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            PaperColorChips(selection: Binding(get: { selectedColor }, set: pickColor))
                .disabled(keepsOwnColours)
                .opacity(keepsOwnColours ? 0.45 : 1)
            if keepsOwnColours {
                Text("Your own paper keeps its own colours.")
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if night, !selectedColor.isDark {
                Text("In Dark Mode this paper is shown dark. It keeps its colour when exported.")
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mode.isAdding {
                LabeledContent {
                    OwlLunaMenu(Text("Page Size")) {
                        OwlLunaPicker(selection: $pageSize) {
                            if PageSize.allCases.allSatisfy({ $0.points != newPageSize }) {
                                Text("Current Size").tag(PageSize?.none)
                            }
                            ForEach(PageSize.allCases) { Text($0.displayName).tag(PageSize?.some($0)) }
                        }
                    } label: {
                        HStack(spacing: Space.x2) {
                            Text(sizeName)
                            Image(systemName: "chevron.up.chevron.down").imageScale(.small).foregroundStyle(Color.textSecondary)
                        }
                    }
                    .buttonStyle(.owlLuna(.secondary, compact: true))
                    .accessibilityLabel(Text("Page Size"))
                    .accessibilityValue(Text(sizeName))
                } label: {
                    Text("Page Size").foregroundStyle(Color.ink)
                }
            }
        }
    }

    private var sizeName: String { pageSize?.displayName ?? String(localized: "Current Size") }

    private func pick(_ option: PaperTemplate) {
        paperID = nil
        switch mode {
        case .add(let index):
            session.addPage(after: index, template: option, color: color, size: pageSize)
            dismiss()
        case .change(let pageID):
            document.setPaper(template: option, color: selectedColor, forPage: pageID)
        }
    }

    private func pickPaper(_ paper: CustomPaper) async throws {
        switch mode {
        case .add(let index):
            try await session.addPage(after: index, paper: paper, size: pageSize)
            dismiss()
        case .change(let pageID):
            try await session.setPaper(paper, forPage: pageID)
        }
    }

    private func pickColor(_ option: PaperColor) {
        color = option
        paperID = nil
        if case .change(let pageID) = mode, !keepsOwnColours { document.setPaper(template: selectedTemplate, color: option, forPage: pageID) }
    }
}

extension EditorSession {
    /// Inserts a page with this paper after `index` and makes it current.
    func addPage(after index: Int, template: PaperTemplate, color: PaperColor, size: PageSize?) {
        guard !document.isReadOnly else { return }
        var page = document.newPage(after: index, template: template)
        page.paperColor = color
        if let size { page.size = size.points }
        insert([page], at: index + 1)
    }

    /// Inserts a page on the user's own paper after `index` and makes it current. A picture takes the width of `size`.
    func addPage(after index: Int, paper: CustomPaper, size: PageSize?) async throws {
        guard !document.isReadOnly else { return }
        let kept = try await document.keepCopy(of: paper)
        let page = kept.page(size: paper.newPageSize(width: size?.points.width ?? document.newPage(after: index).size.width))
        insert([page], at: index + 1)
    }

    func setPaper(_ paper: CustomPaper, forPage pageID: UUID) async throws {
        guard !document.isReadOnly else { return }
        document.setPaper(try await document.keepCopy(of: paper), forPage: pageID)
    }
}

/// Every template as a miniature page, grouped by family after the user's own paper; a list of rows at accessibility sizes.
struct PaperGallery: View {
    struct Own {
        let root: StorageRoot
        var chosen: String?
        var hint: String
        var onPick: (CustomPaper) async throws -> Void
    }

    @Binding var template: PaperTemplate
    let color: PaperColor
    let pageSize: CGSize
    var hint: (PaperTemplate) -> String
    var onPick: (PaperTemplate) -> Void
    var compact = false
    /// The paper a whiteboard can have: rules with no margins to end at.
    var only: [PaperTemplate]?
    /// The user's own paper, listed first with a way to add more. Left out where only templates will do.
    var own: Own?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tileWidth: CGFloat { compact ? 64 : 80 }

    /// The grid the miniatures are laid in, the user's own paper's as well.
    fileprivate static func columns(tileWidth: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: tileWidth + Space.x3), spacing: Space.x3, alignment: .top)]
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                rows
            } else if compact {
                strip
            } else {
                grid
            }
        }
        .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: template)
        .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: own?.chosen)
    }

    private var chosenTemplate: PaperTemplate? { own?.chosen == nil ? template : nil }

    private var families: [PaperFamily] { PaperFamily.allCases.filter { !templates(in: $0).isEmpty } }

    private func templates(in family: PaperFamily) -> [PaperTemplate] {
        family.templates.filter { only?.contains($0) ?? true }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            if let own { OwnPaperSection(own: own, layout: .grid, tileWidth: tileWidth, pageSize: pageSize) }
            ForEach(families) { family in
                VStack(alignment: .leading, spacing: Space.x3) {
                    header(family)
                    LazyVGrid(columns: Self.columns(tileWidth: tileWidth), alignment: .leading, spacing: Space.x5) {
                        ForEach(templates(in: family)) { tile($0).id($0) }
                    }
                }
            }
        }
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Space.x8) {
                    if let own { OwnPaperSection(own: own, layout: .strip, tileWidth: tileWidth, pageSize: pageSize) }
                    ForEach(families) { family in
                        VStack(alignment: .leading, spacing: Space.x2) {
                            header(family)
                            HStack(alignment: .top, spacing: Space.x4) {
                                ForEach(templates(in: family)) { tile($0).id($0) }
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.x2)
                .padding(.vertical, Space.x2)
            }
            .padding(.horizontal, -Space.x2)
            .onAppear { if let chosen = own?.chosen { proxy.scrollTo(chosen, anchor: .center) } else { proxy.scrollTo(template, anchor: .center) } }
            .onChange(of: template) { _, selected in
                withAnimation(reduceMotion ? nil : Motion.standard) { proxy.scrollTo(selected, anchor: .center) }
            }
            .onChange(of: own?.chosen) { _, chosen in
                guard let chosen else { return }
                withAnimation(reduceMotion ? nil : Motion.standard) { proxy.scrollTo(chosen, anchor: .center) }
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            if let own { OwnPaperSection(own: own, layout: .rows, tileWidth: tileWidth, pageSize: pageSize) }
            ForEach(families) { family in
                header(family).padding(.bottom, Space.x6)
                ForEach(templates(in: family)) { option in
                    HStack(spacing: Space.x6) {
                        button(option) { preview(option).frame(width: 60) }
                        name(option)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func header(_ family: PaperFamily) -> some View {
        Text(family.displayName).metaStyle(compact ? .caption : .footnote).accessibilityAddTraits(.isHeader)
    }

    private func tile(_ option: PaperTemplate) -> some View {
        VStack(spacing: Space.x4) {
            button(option) { preview(option).frame(width: tileWidth) }
            name(option)
                .multilineTextAlignment(.center)
                .frame(width: tileWidth + Space.x3)
        }
    }

    private func preview(_ option: PaperTemplate) -> some View {
        PaperPreview(template: option, color: color, pageSize: pageSize, isBoard: only != nil)
            .overlay {
                if option == chosenTemplate {
                    StitchedSelection().transition(reduceMotion ? .opacity : .scale(scale: 1.06).combined(with: .opacity))
                }
            }
    }

    /// Outside the button, like a cover's meta line: the audit reads text beside a light miniature as low contrast.
    private func name(_ option: PaperTemplate) -> some View {
        Text(option.displayName)
            .font(option == chosenTemplate ? .caption.weight(.semibold) : .caption)
            .foregroundStyle(option == chosenTemplate ? Color.ink : Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
            .onTapGesture { pick(option) }
    }

    private func pick(_ option: PaperTemplate) {
        template = option
        onPick(option)
    }

    private func button<Content: View>(_ option: PaperTemplate, @ViewBuilder label: () -> Content) -> some View {
        Button {
            pick(option)
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.displayName)
        .accessibilityValue(color.displayName)
        .accessibilityHint(hint(option))
        .accessibilityAddTraits(option == chosenTemplate ? [.isButton, .isSelected] : .isButton)
    }
}

/// The user's own paper in the gallery: Add Paper… takes a PDF's first page or a picture, and a paper can be renamed or deleted.
private struct OwnPaperSection: View {
    enum Layout { case grid, strip, rows }

    let own: PaperGallery.Own
    let layout: Layout
    let tileWidth: CGFloat
    let pageSize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var papers: [CustomPaper] = []
    @State private var importing = false
    @State private var pickingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var isAdding = false
    @State private var renaming: CustomPaper?
    @State private var newName = ""
    @State private var failure: String?
    @State private var unlocking = PDFPasswordRequest()

    var body: some View {
        content
            .task { await reload() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image]) { result in
                guard case .success(let url) = result else { return }
                let root = own.root, unlocking = unlocking, name = url.deletingPathExtension().lastPathComponent
                Task { await add { try await PaperShelf.add(file: url, to: root) { wrong in await unlocking.ask(name, wrong: wrong) } } }
            }
            .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { await add(item) }
            }
            .notice("Rename Paper", isPresented: Binding(isPresent: $renaming)) {
                TextField("Name", text: $newName)
            } actions: {
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let renaming { rename(renaming, to: newName) } }
            }
            .notice("Something went wrong", message: $failure)
            .pdfPasswordNotice(unlocking, message: Text("Type its password to use it as paper."))
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .grid:
            VStack(alignment: .leading, spacing: Space.x3) {
                header
                LazyVGrid(columns: PaperGallery.columns(tileWidth: tileWidth), alignment: .leading, spacing: Space.x5) {
                    tile { addButton } name: { addName }
                    ForEach(papers) { paper in tile { button(paper) } name: { name(paper) }.id(paper.id) }
                }
                if papers.isEmpty {
                    Text("Add a planner, a lab sheet or a letterhead to write on it in any notebook. A PDF gives its first page.")
                        .font(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .strip:
            VStack(alignment: .leading, spacing: Space.x2) {
                header
                HStack(alignment: .top, spacing: Space.x4) {
                    tile { addButton } name: { addName }
                    ForEach(papers) { paper in tile { button(paper) } name: { name(paper) }.id(paper.id) }
                }
            }
        case .rows:
            VStack(alignment: .leading, spacing: Space.x4) {
                header.padding(.bottom, Space.x6)
                HStack(spacing: Space.x6) {
                    addButton.frame(width: 60)
                    addName
                    Spacer(minLength: 0)
                }
                ForEach(papers) { paper in
                    HStack(spacing: Space.x6) {
                        button(paper).frame(width: 60)
                        name(paper)
                        Spacer(minLength: 0)
                    }
                    .id(paper.id)
                }
            }
        }
    }

    private var header: some View {
        Text("My Paper").metaStyle(layout == .strip ? .caption : .footnote).accessibilityAddTraits(.isHeader)
    }

    private func tile<Miniature: View, Name: View>(@ViewBuilder _ miniature: () -> Miniature, @ViewBuilder name: () -> Name) -> some View {
        VStack(spacing: Space.x4) {
            miniature().frame(width: tileWidth)
            name()
                .multilineTextAlignment(.center)
                .frame(width: tileWidth + Space.x3)
        }
    }

    private var addButton: some View {
        OwlLunaMenu(Text("Add Paper")) {
            Button { importing = true } label: { Label("From Files…", systemImage: "folder") }
            Button { pickingPhoto = true } label: { Label("From Photos…", systemImage: "photo") }
        } label: {
            Rectangle()
                .fill(Color.paper)
                .aspectRatio(pageSize.width / max(pageSize.height, 1), contentMode: .fit)
                .overlay {
                    if isAdding {
                        ProgressView()
                    } else {
                        Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(Color.ink)
                    }
                }
                .overlay { Rectangle().strokeBorder(Color.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .disabled(isAdding)
        .accessibilityLabel(Text(isAdding ? "Adding the paper" : "Add Paper"))
        .accessibilityHint(Text("Adds a PDF or a picture as paper of your own"))
        .accessibilityIdentifier("paper.add")
    }

    private var addName: some View {
        Text(isAdding ? "Adding…" : "Add Paper…")
            .font(.caption)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

    private func button(_ paper: CustomPaper) -> some View {
        let chosen = paper.id == own.chosen
        return Button { pick(paper) } label: {
            PaperPreview(paper: paper)
                .overlay {
                    if chosen { StitchedSelection().transition(reduceMotion ? .opacity : .scale(scale: 1.06).combined(with: .opacity)) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .disabled(isAdding)
        .heldMenu(Text(paper.name)) {
            Button { startRenaming(paper) } label: { Label("Rename…", systemImage: "pencil") }
            Button(role: .destructive) { remove(paper) } label: { Label("Delete Paper", systemImage: "trash") }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paper.name)
        .accessibilityHint(own.hint)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Rename")) { startRenaming(paper) }
        .accessibilityAction(named: Text("Delete Paper")) { remove(paper) }
        .accessibilityIdentifier("paper.mine.\(paper.name)")
    }

    private func name(_ paper: CustomPaper) -> some View {
        let chosen = paper.id == own.chosen
        return Text(paper.name)
            .font(chosen ? .caption.weight(.semibold) : .caption)
            .foregroundStyle(chosen ? Color.ink : Color.textSecondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
            .onTapGesture { pick(paper) }
    }

    private func reload() async {
        let root = own.root
        papers = await Task.detached(priority: .userInitiated) { PaperShelf.list(root) }.value
    }

    private func pick(_ paper: CustomPaper) {
        Task {
            do { try await own.onPick(paper) } catch { failure = error.localizedDescription }
        }
    }

    private func add(_ item: PhotosPickerItem) async {
        defer { photo = nil }
        isAdding = true
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            isAdding = false
            failure = ImportError.unreadable.localizedDescription
            return
        }
        let root = own.root, name = String(localized: "Photo \(Date.now.formatted(date: .abbreviated, time: .omitted))")
        await add { try await Task.detached(priority: .userInitiated) { try PaperShelf.add(image: data, name: name, to: root) }.value }
    }

    /// A new paper is put to use at once, as picking it would. A locked PDF whose password was skipped is let go quietly.
    private func add(_ make: () async throws -> CustomPaper) async {
        isAdding = true
        defer { isAdding = false }
        do {
            let paper = try await make()
            await reload()
            AccessibilityNotification.Announcement(String(localized: "Paper added")).post()
            try await own.onPick(paper)
        } catch ImportError.locked {
        } catch {
            failure = error.localizedDescription
        }
    }

    private func startRenaming(_ paper: CustomPaper) {
        newName = paper.name
        renaming = paper
    }

    private func rename(_ paper: CustomPaper, to name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            _ = try PaperShelf.rename(paper, to: name)
        } catch {
            failure = error.localizedDescription
        }
        Task { await reload() }
    }

    private func remove(_ paper: CustomPaper) {
        PaperShelf.remove(paper)
        papers.removeAll { $0 == paper }
    }
}

/// Paper colours as named chips in their own colour; the selected one shows a check and an accent ring.
struct PaperColorChips: View {
    @Binding var selection: PaperColor

    var body: some View {
        FlowLayout(spacing: Space.x1) {
            ForEach(PaperColor.allCases) { option in
                let isSelected = option == selection
                Button { selection = option } label: {
                    HStack(spacing: Space.x1) {
                        if isSelected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                        Text(option.displayName).font(isSelected ? .subheadline.weight(.semibold) : .subheadline)
                    }
                    .foregroundStyle(option.isDark ? Color.white : Color.labelInk)
                    .padding(.horizontal, Space.x3)
                    .frame(minHeight: 34)
                    .background(Color(uiColor: PageRenderer.paperColor(option)), in: RoundedRectangle.plate)
                    .overlay { RoundedRectangle.plate.strokeBorder(Color.hairline) }
                    .padding(3)
                    .overlay { if isSelected { RoundedRectangle.plate.strokeBorder(Color.accentColor, lineWidth: 2.5) } }
                    .contentShape(RoundedRectangle.plate)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(option.displayName)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// A page's paper at its true aspect and colour, rendered off the main thread by the page renderer.
struct PaperPreview: View {
    let template: PaperTemplate
    let color: PaperColor
    let pageSize: CGSize
    var renderWidth: CGFloat = 120
    var isBoard = false
    /// The user's own paper, drawn in place of the template.
    var paper: CustomPaper?
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var shownKey = ""

    init(template: PaperTemplate, color: PaperColor, pageSize: CGSize, renderWidth: CGFloat = 120, isBoard: Bool = false) {
        self.template = template
        self.color = color
        self.pageSize = pageSize
        self.renderWidth = renderWidth
        self.isBoard = isBoard
    }

    init(paper: CustomPaper, renderWidth: CGFloat = 120) {
        self.init(template: .blank, color: .white, pageSize: paper.size, renderWidth: renderWidth)
        self.paper = paper
    }

    var body: some View {
        let key = paper.map { PaperPreviewCache.key(paper: $0, width: renderWidth, scale: displayScale) }
            ?? PaperPreviewCache.key(template: template, color: color, size: pageSize, width: renderWidth, scale: displayScale, board: isBoard)
        Rectangle()
            .fill(Color(uiColor: PageRenderer.paperColor(color)))
            .aspectRatio(pageSize.width / max(pageSize.height, 1), contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().id(shownKey).transition(.opacity)
                }
            }
            .overlay { Rectangle().strokeBorder(Color.hairline, lineWidth: 1) }
            .accessibilityHidden(true)
            .task(id: key) {
                if let hit = PaperPreviewCache.cached(key) {
                    image = hit
                    shownKey = key
                    return
                }
                let rendered = if let paper {
                    await PaperPreviewCache.image(of: paper, width: renderWidth, scale: displayScale)
                } else {
                    await PaperPreviewCache.image(template: template, color: color, size: pageSize, width: renderWidth, scale: displayScale, board: isBoard)
                }
                guard !Task.isCancelled else { return }
                withAnimation(Motion.standard) {
                    image = rendered
                    shownKey = key
                }
            }
    }
}

enum PaperPreviewCache {
    static let images = LRUCache<PageThumbnailer.SharedUIImage>(capacity: 64)

    static func key(template: PaperTemplate, color: PaperColor, size: CGSize, width: CGFloat, scale: CGFloat, board: Bool = false) -> String {
        "\(template.rawValue)|\(color.rawValue)|\(Int(size.width))x\(Int(size.height))|\(Int(width))@\(scale)\(board ? "|board" : "")"
    }

    static func key(paper: CustomPaper, width: CGFloat, scale: CGFloat) -> String {
        "own|\(paper.url.lastPathComponent)|\(Int(width))@\(scale)"
    }

    static func cached(_ key: String) -> UIImage? { images.value(key) { nil }?.image }

    static func image(of paper: CustomPaper, width: CGFloat = 120, scale: CGFloat) async -> UIImage {
        await rendered(key(paper: paper, width: width, scale: scale)) {
            PageRenderer.image(of: paper.preview, ink: PKDrawing(), assets: paper.url.deletingLastPathComponent(), width: width, scale: scale)
        }
    }

    static func image(template: PaperTemplate, color: PaperColor, size: CGSize, width: CGFloat = 120, scale: CGFloat, board: Bool = false) async -> UIImage {
        await rendered(key(template: template, color: color, size: size, width: width, scale: scale, board: board)) {
            // A whiteboard's miniature is a small piece of it, so its rules show at a size that can be told apart.
            let page = board ? Whiteboard.piece(of: .board(template: template, color: color),
                                                in: CGRect(origin: Whiteboard.center, size: CGSize(width: 320, height: 320 * size.height / max(size.width, 1))))
                             : NotebookPage(background: .template(template), paperColor: color, size: size)
            return PageRenderer.image(of: page, ink: PKDrawing(), assets: FileManager.default.temporaryDirectory, width: width, scale: scale)
        }
    }

    /// The image kept under `key`, drawn off the main thread by `render` the first time.
    private static func rendered(_ key: String, render: @escaping @Sendable () -> UIImage) async -> UIImage {
        if let hit = cached(key) { return hit }
        let image = await Task.detached(priority: .userInitiated) { render() }.value
        return images.value(key) { PageThumbnailer.SharedUIImage(image: image) }?.image ?? image
    }
}
