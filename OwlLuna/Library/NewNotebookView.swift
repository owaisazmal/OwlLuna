import SwiftUI

struct NewNotebookView: View {
    let folder: FolderRecord?
    let onCreated: (UUID) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("newNotebookCoverStyle") private var style: CoverStyle = .cloth
    @State private var template: PaperTemplate
    @State private var paper: CustomPaper?
    @State private var paperColor: PaperColor
    @State private var pageSize: PageSize
    @State private var useForQuickNote = false
    @State private var starter: NotebookStarter?
    @State private var id = UUID()
    @State private var title = ""
    @State private var cloth: ClothColor
    @State private var inkPair = 0
    @State private var seed: UInt32
    @State private var creating = false
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    init(folder: FolderRecord?, onCreated: @escaping (UUID) -> Void) {
        self.folder = folder
        self.onCreated = onCreated
        let id = UUID()
        let defaults = UserDefaults.standard
        _id = State(initialValue: id)
        _cloth = State(initialValue: .seeded(by: id))
        _seed = State(initialValue: CoverSpec.seed(from: id))
        _inkPair = State(initialValue: Int(id.uuid.3) % RisoInk.pairs.count)
        _template = State(initialValue: defaults.defaultTemplate)
        _paperColor = State(initialValue: defaults.defaultPaperColor)
        _pageSize = State(initialValue: defaults.defaultPageSize)
    }

    private static let coverWidth: CGFloat = 120

    private var spec: CoverSpec {
        CoverSpec(style: style, cloth: cloth, inks: RisoInk.pairs[inkPair], seed: seed)
    }

    private var placeholder: String { starter?.notebookTitle ?? String(localized: "Untitled Notebook") }

    private var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? placeholder : trimmed
    }

    private var previewPage: URL {
        FileManager.default.temporaryDirectory.appending(path: "cover-preview-\(paper?.id ?? template.rawValue)-\(paperColor.rawValue)-\(pageSize.rawValue).png")
    }

    private var request: CoverRequest {
        CoverRequest(notebookID: id, spec: spec, title: displayTitle, meta: folder?.name ?? Date.now.formatted(.dateTime.month(.abbreviated).year()),
                     width: CoverWidth.preview, scale: displayScale, dark: colorScheme == .dark, highContrast: contrast == .increased,
                     firstPage: previewPage, firstPageKey: previewPage.lastPathComponent, firstPageIsPDF: false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let sideBySide = sizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
                let layout = sideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: Space.x8))
                                        : AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x6))
                layout {
                    VStack(alignment: .leading, spacing: Space.x4) {
                        preview.frame(maxWidth: .infinity)
                        if sideBySide { pageOptions }
                    }
                    .frame(width: Self.coverWidth * 2.25)
                    .frame(maxWidth: sideBySide ? nil : .infinity)
                    form(withPageOptions: !sideBySide)
                }
                .padding(Space.x6)
            }
            .background(Color.surface)
            .navigationTitle("New Notebook")
            .barGround(.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                CancelToolbarItem { dismiss() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .buttonStyle(.owlLuna(.primary, inBar: true))
                        .disabled(creating)
                        .keyboardShortcut(.defaultAction)
                }
                .boardBackground()
            }
            .notice("Something went wrong", message: $errorMessage)
            .task {
                if let id = UserDefaults.standard.string(forKey: SettingsKey.defaultPaper) {
                    let root = store.root
                    paper = await Task.detached(priority: .userInitiated) { PaperShelf.paper(id, in: root) }.value
                }
                try? await Task.sleep(for: .milliseconds(350))
                titleFocused = true
            }
        }
        .presentationDetents([.large])
        .presentationSizing(.page)
    }

    /// The notebook lying open: its cover, then its first page.
    private var preview: some View {
        VStack(spacing: Space.x3) {
            let coverWidth = Self.coverWidth
            let page = paper?.preview ?? NotebookPage.template(template, color: paperColor, size: pageSize)
            let assets = paper?.url.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
            let aspect = page.size.width / max(page.size.height, 1)
            HStack(alignment: .bottom, spacing: 0) {
                let pageFile = previewPage
                CoverView(request: request, persist: false) {
                    await Task.detached(priority: .userInitiated) {
                        let image = PageRenderer.image(of: page, ink: .init(), assets: assets, width: PageThumbnailer.pixelWidth)
                        try? image.pngData()?.write(to: pageFile, options: .atomic)
                    }.value
                }
                .frame(width: coverWidth)
                .accessibilityHidden(false)
                .accessibilityLabel(paper.map { Text("Preview: \(style.displayName) cover for \(displayTitle), on \($0.name)") }
                                    ?? Text("Preview: \(style.displayName) cover for \(displayTitle), \(template.displayName) \(paperColor.displayName) paper"))
                Group {
                    if let paper {
                        PaperPreview(paper: paper, renderWidth: 200)
                    } else {
                        PaperPreview(template: template, color: paperColor, pageSize: page.size, renderWidth: 200)
                    }
                }
                .frame(width: min(coverWidth * 1.25, coverWidth * 4 / 3 * aspect))
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            }
            .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: pageSize)
            ShuffleButton(style: style, action: shuffle)
        }
    }

    private func form(withPageOptions: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            TextField("Title", text: $title, prompt: Text(placeholder).foregroundStyle(Color.textSecondary))
                .displayFont(24, relativeTo: .title2)
                .padding(.vertical, Space.x2)
                .owlLunaField(focused: titleFocused) { titleFocused = true }
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit { titleFocused = false }
                .accessibilityLabel("Title")

            label("Start from")
            StarterRow(notebookID: id, selection: starter, pick: apply)

            label("Cover")
            CoverStyleOptions(style: $style, cloth: $cloth, inkPair: $inkPair)

            label("Paper")
            PaperGallery(template: $template, color: paperColor, pageSize: pageSize.points,
                         hint: { _ in String(localized: "Sets the first page's paper") }, onPick: { _ in paper = nil }, compact: true,
                         own: PaperGallery.Own(root: store.root, chosen: paper?.id, hint: String(localized: "Sets the first page's paper")) { paper = $0 })
            PaperColorChips(selection: $paperColor)
                .disabled(paper != nil)
                .opacity(paper != nil ? 0.45 : 1)
            if withPageOptions { pageOptions }
        }
    }

    /// Size and Quick Note sit under the open notebook when there's room beside the form.
    private var pageOptions: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            Divider().overlay(Color.hairline)
            LabeledContent {
                OwlLunaMenu(Text("Page Size")) {
                    OwlLunaPicker(selection: $pageSize) {
                        ForEach(PageSize.allCases) { Text($0.displayName).tag($0) }
                    }
                } label: {
                    HStack(spacing: Space.x2) {
                        Text(pageSize.displayName)
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small).foregroundStyle(Color.textSecondary)
                    }
                }
                .buttonStyle(.owlLuna(.secondary, compact: true))
                .accessibilityLabel(Text("Page Size"))
                .accessibilityValue(Text(pageSize.displayName))
            } label: {
                Text("Page Size").foregroundStyle(Color.ink)
            }
            Divider().overlay(Color.hairline)
            Toggle(isOn: $useForQuickNote) {
                Text("Use this paper for Quick Note").foregroundStyle(Color.ink)
            }
            .toggleStyle(.owlLuna)
        }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).metaStyle(.footnote).accessibilityAddTraits(.isHeader)
    }

    private func apply(_ starter: NotebookStarter) {
        let spec = starter.spec(for: id)
        withAnimation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion)) {
            self.starter = starter
            style = spec.style
            template = starter.template
            paper = nil
            paperColor = starter.paperColor
            if spec.style == .print {
                inkPair = RisoInk.pairIndex(of: spec.inks) ?? inkPair
            } else {
                cloth = spec.cloth
            }
        }
    }

    private func shuffle() {
        var generator = SystemRandomNumberGenerator()
        let next = CoverShuffle.next(spec, using: &generator)
        cloth = next.cloth
        seed = next.seed
        inkPair = RisoInk.pairIndex(of: next.inks) ?? inkPair
    }

    private func create() async {
        guard !creating else { return }
        creating = true
        defer { creating = false }
        do {
            let created = try await store.createNotebook(id: id, title: displayTitle, cover: spec,
                                                         defaults: PageDefaults(template: template, paperColor: paperColor, pageSize: pageSize),
                                                         folder: folder, startsWithBoard: paper == nil && starter?.startsWithBoard(template: template) == true,
                                                         paper: paper)
            if useForQuickNote {
                let defaults = UserDefaults.standard
                defaults.set(template.rawValue, forKey: SettingsKey.defaultTemplate)
                defaults.set(paperColor.rawValue, forKey: SettingsKey.defaultPaperColor)
                defaults.set(pageSize.rawValue, forKey: SettingsKey.defaultPageSize)
                defaults.set(paper?.id, forKey: SettingsKey.defaultPaper)
            }
            dismiss()
            onCreated(created)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Rolls a different cloth, or a new print in other inks. Lives under the cover preview in New Notebook and Change Cover.
struct ShuffleButton: View {
    let style: CoverStyle
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var count = 0

    var body: some View {
        Button {
            count += 1
            action()
        } label: {
            Label("Shuffle", systemImage: "dice")
        }
        .buttonStyle(.owlLuna(.secondary, compact: true))
        .symbolEffect(.bounce, value: reduceMotion ? 0 : count)
        .accessibilityHint(style == .print ? Text("Prints a new pattern in another pair of inks") : Text("Picks another cloth"))
    }
}

private struct StarterRow: View {
    let notebookID: UUID
    let selection: NotebookStarter?
    let pick: (NotebookStarter) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            cards
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                cards.padding(Space.x2)
            }
            .padding(-Space.x2)
        }
    }

    private var cards: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.x3))
                                                         : AnyLayout(HStackLayout(alignment: .top, spacing: Space.x3))
        return layout {
            ForEach(NotebookStarter.allCases) { starter in
                let isSelected = starter == selection
                VStack(alignment: .leading, spacing: Space.x2) {
                    Button { pick(starter) } label: {
                        StarterCard(starter: starter, spec: starter.spec(for: notebookID), isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.lift)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(starter.accessibilityLabel(for: notebookID))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    Text(starter.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Space.x1)
                        .accessibilityHidden(true)
                        .onTapGesture { pick(starter) }
                }
            }
        }
    }
}

/// A starter drawn as a tiny cover beside a tiny page. Plain SwiftUI shapes, so a row of them never renders a cover.
private struct StarterCard: View {
    let starter: NotebookStarter
    let spec: CoverSpec
    let isSelected: Bool

    var body: some View {
        Group {
            if starter == .whiteboard {
                board.frame(width: 75, height: 48)
            } else {
                HStack(spacing: 3) {
                    cover
                        .frame(width: 36, height: 48)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 1, bottomLeadingRadius: 1, bottomTrailingRadius: 3, topTrailingRadius: 3))
                    paper.frame(width: 36, height: 48)
                }
            }
        }
        .padding(Space.x3)
        .background(Color.paper, in: RoundedRectangle.plate)
        .overlay {
            RoundedRectangle.plate
                .strokeBorder(isSelected ? Color.accentColor : Color.hairline, lineWidth: isSelected ? 2 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Color.paper)
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor, in: Circle())
                    .offset(x: 6, y: -6)
            }
        }
        .contentShape(RoundedRectangle.plate)
    }

    @ViewBuilder private var cover: some View {
        if spec.style == .print {
            ZStack {
                Color(hex: RisoInk.paperStock)
                Circle().fill(Color(hex: spec.inks.1.hex)).frame(width: 30, height: 30).offset(x: 8, y: -9)
                Rectangle().fill(Color(hex: spec.inks.0.hex).opacity(0.85)).frame(height: 13).offset(y: 12)
            }
        } else {
            ZStack(alignment: .topLeading) {
                spec.cloth.color
                Rectangle().fill(Color.black.opacity(0.2)).frame(width: 5)
                RoundedRectangle(cornerRadius: 1).fill(Color.labelCream).frame(width: 20, height: 12).offset(x: 11, y: 9)
            }
        }
    }

    /// A whiteboard is drawn as what it is: one wide dotted sheet with a line running across it.
    private var board: some View {
        Canvas { context, size in
            let dot = Color(uiColor: TemplateInk.for(starter.paperColor).line)
            for x in stride(from: 7.5, to: size.width, by: 10) {
                for y in stride(from: 9, to: size.height, by: 10) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)), with: .color(dot))
                }
            }
            var line = Path()
            line.move(to: CGPoint(x: 10, y: 33))
            line.addCurve(to: CGPoint(x: 38, y: 22), control1: CGPoint(x: 18, y: 10), control2: CGPoint(x: 28, y: 42))
            line.addCurve(to: CGPoint(x: 66, y: 15), control1: CGPoint(x: 46, y: 6), control2: CGPoint(x: 56, y: 34))
            context.stroke(line, with: .color(spec.cloth.color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .background(Color(uiColor: PageRenderer.paperColor(starter.paperColor)))
        .overlay { Rectangle().strokeBorder(Color.hairline) }
    }

    private var paper: some View {
        let rule = Color(uiColor: TemplateInk.for(starter.paperColor).line)
        return Rectangle()
            .fill(Color(uiColor: PageRenderer.paperColor(starter.paperColor)))
            .overlay {
                VStack(spacing: 7) {
                    ForEach(0..<3, id: \.self) { _ in rule.frame(height: 1) }
                }
                .padding(.horizontal, 5)
            }
            .overlay { Rectangle().strokeBorder(Color.hairline) }
    }
}

/// The cover style picker with its cloth or ink swatches, shared by New Notebook and Change Cover.
struct CoverStyleOptions: View {
    @Binding var style: CoverStyle
    @Binding var cloth: ClothColor
    @Binding var inkPair: Int

    var body: some View {
        OwlLunaSegmentedPicker("Cover", selection: $style, options: CoverStyle.allCases) { Text($0.displayName) }
        switch style {
        case .cloth, .firstPage:
            header(style == .cloth ? "Cloth" : "Spine")
            SwatchRow(items: ClothColor.allCases, selection: $cloth, label: \.displayName) { Circle().fill($0.color) }
        case .print:
            header("Inks")
            SwatchRow(items: Array(RisoInk.pairs.indices), selection: $inkPair, label: { RisoInk.name(of: RisoInk.pairs[$0]) }) { index in
                Circle().fill(LinearGradient(stops: [.init(color: Color(hex: RisoInk.pairs[index].0.hex), location: 0.5),
                                                    .init(color: Color(hex: RisoInk.pairs[index].1.hex), location: 0.5)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
    }

    private func header(_ text: LocalizedStringKey) -> some View {
        Text(text).metaStyle(.footnote).accessibilityAddTraits(.isHeader)
    }
}

struct SwatchRow<Item: Hashable, Swatch: View>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: (Item) -> String
    var size: CGFloat = 30
    @ViewBuilder let swatch: (Item) -> Swatch

    var body: some View {
        // Each button is a 44 pt target laid out at the size it's drawn, so the row keeps its spacing.
        let target = max(size + 6, 44)
        FlowLayout(spacing: Space.x2) {
            ForEach(items, id: \.self) { item in
                Button { selection = item } label: {
                    swatch(item)
                        .frame(width: size, height: size)
                        .padding(3)
                        .overlay { if item == selection { Circle().strokeBorder(Color.accentColor, lineWidth: 2.5) } }
                        .frame(width: target, height: target)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-(target - size - 6) / 2)
                .accessibilityLabel(label(item))
                .accessibilityAddTraits(item == selection ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

