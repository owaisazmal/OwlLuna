import SwiftUI

/// What an export asks before it starts: which pages, the paper, how fine, whether the handwriting can be searched, or for
/// text whether it is Markdown.
struct ExportChoices: View {
    @Bindable var job: ExportJob
    let cancel: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x4) {
                    if job.choosesPages, let package = job.package {
                        ProofStrip(pages: job.pages, package: package, range: $job.range, current: job.currentPage)
                    }
                    if job.format == .text {
                        PlatePair(title: "Text", selection: $job.options.markdown, first: (false, "Plain Text"), second: (true, "Markdown"),
                                  identifier: "export.markdown")
                        note("Markdown gives the notebook and each page a heading.")
                    } else {
                        PlatePair(title: "Paper", selection: $job.options.paper, first: (true, "Paper On"), second: (false, "No Paper"),
                                  identifier: "export.paper")
                        note(job.options.paper ? "Pages keep their colour and ruling." : "Leaves out the colour and ruling. Imported PDF pages and photos stay.")
                    }
                    if job.format == .svg {
                        note("Each stroke is a shape of its own that other apps can edit. Everything else goes in as pictures.")
                    }
                    if job.format == .pdf {
                        PlatePair(title: "Quality", selection: $job.options.quality, first: (.smaller, "Smaller File"), second: (.sharper, "Sharper Ink"),
                                  identifier: "export.quality")
                        note(job.options.quality == .smaller ? "Pencil, highlighter, photos and scans go in at screen sharpness."
                                                             : "Pencil, highlighter, photos and scans go in as fine as they are.")
                        Toggle(isOn: $job.options.searchable) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Searchable Handwriting").foregroundStyle(Color.ink)
                                Text("Words read from your writing lie under it, so any PDF reader can find and select them.")
                                    .font(.footnote)
                                    .foregroundStyle(Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.owlLuna)
                        .accessibilityIdentifier("export.searchable")
                    }
                }
                .padding(Space.x5)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            Rectangle().fill(Color.hairline).frame(height: 1)
            HStack(spacing: Space.x3) {
                Button("Cancel", role: .cancel) { cancel() }
                    .buttonStyle(.owlLuna)
                Spacer(minLength: 0)
                Button(startTitle) { job.start() }
                    .buttonStyle(.owlLuna(.primary))
                    .accessibilityIdentifier("export.start")
            }
            .padding(.horizontal, Space.x5)
            .padding(.vertical, Space.x3)
            .frame(maxWidth: 600)
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, -Space.x2)
    }

    private var startTitle: String {
        guard job.choosesPages else { return String(localized: "Export") }
        let count = job.range.count
        return count == 1 ? String(localized: "Export Page \(job.range.lowerBound + 1)") : String(localized: "Export \(count) Pages")
    }
}

/// Two choices side by side as plates, the chosen one in cloth. At the largest text sizes they stack.
struct PlatePair<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let first: (Value, LocalizedStringKey)
    let second: (Value, LocalizedStringKey)
    var identifier: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Space.x2)) : AnyLayout(HStackLayout(spacing: Space.x2))
        layout {
            plate(first, tag: "first")
            plate(second, tag: "second")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private func plate(_ choice: (Value, LocalizedStringKey), tag: String) -> some View {
        let chosen = selection == choice.0
        return Button { selection = choice.0 } label: { Text(choice.1).frame(maxWidth: .infinity) }
            .buttonStyle(.owlLuna(chosen ? .primary : .secondary))
            .accessibilityAddTraits(chosen ? .isSelected : [])
            .accessibilityIdentifier(identifier.map { "\($0).\(tag)" } ?? "", isEnabled: identifier != nil)
    }
}

/// The notebook's pages in a row, the chosen run of them between two mustard ends. Drag an end, or tap a page to bring the
/// nearer end to it.
struct ProofStrip: View {
    let pages: [NotebookPage]
    let package: NotebookPackage
    @Binding var range: ClosedRange<Int>
    let current: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cell = CGSize(width: 44, height: 60)
    private let gap: CGFloat = 6
    private let inset = Space.x4

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: gap) {
                        ForEach(pages.indices, id: \.self) { index in
                            ProofThumb(page: pages[index], package: package, number: index + 1, chosen: range.contains(index))
                                .frame(width: cell.width, height: cell.height + 16)
                                .contentShape(Rectangle())
                                .onTapGesture { reach(index) }
                                .id(index)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(inset)
                    .overlay(alignment: .topLeading) { bracket }
                    .coordinateSpace(.named(Self.space))
                }
                .onAppear { proxy.scrollTo(range.lowerBound, anchor: .center) }
            }
            .background(Color.desk, in: RoundedRectangle.plate)
            .overlay { RoundedRectangle.plate.strokeBorder(Color.hairline).allowsHitTesting(false) }
            HStack(spacing: Space.x3) {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("export.pages")
                if let current, range != current...current {
                    Button("This Page") { set(current...current) }
                        .buttonStyle(.owlLuna(.secondary, compact: true))
                        .accessibilityIdentifier("export.thisPage")
                }
                if range != 0...(pages.count - 1) {
                    Button("All Pages") { set(0...(pages.count - 1)) }
                        .buttonStyle(.owlLuna(.secondary, compact: true))
                        .accessibilityIdentifier("export.allPages")
                }
            }
        }
    }

    private static let space = "proof-strip"

    private var summary: String {
        if range.count == pages.count { return String(localized: "All \(pages.count) pages") }
        if range.count == 1 { return String(localized: "Page \(range.lowerBound + 1) of \(pages.count)") }
        return String(localized: "Pages \(range.lowerBound + 1)–\(range.upperBound + 1) of \(pages.count)")
    }

    private func x(of index: Int) -> CGFloat { inset + CGFloat(index) * (cell.width + gap) }

    private func index(at x: CGFloat) -> Int {
        min(max(Int(((x - inset + gap / 2) / (cell.width + gap)).rounded(.down)), 0), pages.count - 1)
    }

    private var bracket: some View {
        let left = x(of: range.lowerBound) - 4, right = x(of: range.upperBound) + cell.width + 4
        return ZStack(alignment: .topLeading) {
            RoundedRectangle.plate
                .strokeBorder(Color.mustard, lineWidth: 2)
                .frame(width: right - left, height: cell.height + 8)
                .offset(x: left, y: inset - 4)
                .allowsHitTesting(false)
            end(first: true).offset(x: left - 11, y: inset + cell.height / 2 - 18)
            end(first: false).offset(x: right - 11, y: inset + cell.height / 2 - 18)
        }
        .animation(reduceMotion ? nil : Motion.quick, value: range)
    }

    /// A mustard tab on the frame's edge, dragged along the strip.
    private func end(first: Bool) -> some View {
        Rectangle()
            .fill(Color.mustard)
            .frame(width: 10, height: 36)
            .overlay {
                VStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Color.onMustard.opacity(0.6)).frame(width: 4, height: 1) } }
            }
            .clipShape(RoundedRectangle.thumb)
            .frame(width: 22, height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)).onChanged { value in
                let at = index(at: value.location.x)
                range = first ? min(at, range.upperBound)...range.upperBound : range.lowerBound...max(at, range.lowerBound)
            })
            .accessibilityElement()
            .accessibilityLabel(first ? Text("First page") : Text("Last page"))
            .accessibilityValue(Text("Page \((first ? range.lowerBound : range.upperBound) + 1)"))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 1 : -1
                if first {
                    range = min(max(range.lowerBound + step, 0), range.upperBound)...range.upperBound
                } else {
                    range = range.lowerBound...min(max(range.upperBound + step, range.lowerBound), pages.count - 1)
                }
            }
            .accessibilityIdentifier(first ? "export.firstPage" : "export.lastPage")
    }

    private func reach(_ index: Int) {
        if index < range.lowerBound { return set(index...range.upperBound) }
        if index > range.upperBound { return set(range.lowerBound...index) }
        set(index - range.lowerBound <= range.upperBound - index ? index...range.upperBound : range.lowerBound...index)
    }

    private func set(_ new: ClosedRange<Int>) {
        range = new
    }
}

private struct ProofThumb: View {
    let page: NotebookPage
    let package: NotebookPackage
    let number: Int
    let chosen: Bool
    @PaperNight private var night
    @AppStorage(SettingsKey.evenHighlights) private var evenHighlights = false
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Color.white
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .aspectRatio(page.shownSize.width / max(page.shownSize.height, 1), contentMode: .fit)
            .clipShape(RoundedRectangle.thumb)
            .overlay { RoundedRectangle.thumb.strokeBorder(Color.hairline.opacity(0.5)) }
            .frame(maxHeight: .infinity)
            .opacity(chosen ? 1 : 0.45)
            Text(number, format: .number)
                .font(.caption2.weight(chosen ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(chosen ? Color.ink : Color.textSecondary)
        }
        .task(id: "\(page.id)-\(page.inkHash ?? "")-\(page.appearanceKey)-\(night)-\(evenHighlights)") {
            if let document = DocumentRegistry.shared.document(for: package.id) {
                image = await document.thumbnail(for: page, night: night)
            } else {
                image = await PageThumbnailer.thumbnail(package: package, page: page, night: night, even: evenHighlights)
            }
        }
    }
}
