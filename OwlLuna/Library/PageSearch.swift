import SwiftUI

struct PageHit: Identifiable, Hashable, Sendable {
    let notebookID: UUID
    let page: NotebookPage
    let index: Int
    let snippet: String
    /// Set when the match is in what was said in a recording.
    var recording: Recording?
    /// Set when the page is listed for its tags, not for a match.
    var tags: [String] = []
    var id: String { "\(notebookID.uuidString)-\(page.id.uuidString)-\(recording?.id.uuidString ?? "")" }

    struct Recording: Hashable, Sendable {
        let id: UUID
        let name: String
    }

    /// "Page 3", or the recording's name for a match in a transcript.
    var place: String {
        recording?.name ?? String(localized: "Page \(index + 1)")
    }

    func title(in notebook: String) -> String {
        recording.map { String(localized: "\(notebook), recording \($0.name)") } ?? String(localized: "\(notebook), page \(index + 1)")
    }

    /// What VoiceOver reads for the hit: where it is, then the words round the match.
    func label(in notebook: String) -> String {
        if !tags.isEmpty { return String(localized: "\(notebook), page \(index + 1), tagged \(tags.formatted(.list(type: .and)))") }
        return recording.map { String(localized: "\(notebook), recording \($0.name): \(snippet)") } ?? String(localized: "\(notebook), page \(index + 1): \(snippet)")
    }
}

/// The hits listed under each notebook, and how many more of its pages and transcripts match than are listed.
struct PageHits: Hashable, Sendable {
    var pages: [UUID: [PageHit]] = [:]
    var more: [UUID: Int] = [:]
}

/// Finds which pages of the matching notebooks contain every term of the query, from each page's recognised text, and which
/// recordings from their transcripts. A recording's match opens the first page written on while it ran.
enum PageSearch {
    static func hits(for query: String, in ids: [UUID], root: StorageRoot, limitPerNotebook: Int = 8, limit: Int = 60) async -> PageHits {
        let search = SearchQuery(query)
        var result = PageHits()
        guard !search.isEmpty else { return result }
        var total = 0
        for id in ids {
            if Task.isCancelled || total >= limit { break }
            let package = NotebookPackage(root: root, id: id)
            guard let manifest = try? await package.readManifest().manifest else { continue }
            let pages = manifest.pages
            var hits: [PageHit] = [], more = 0
            func take(_ text: String, as hit: (String) -> PageHit) {
                let body = SearchQuery.searchable(text)
                if hits.count < limitPerNotebook && total + hits.count < limit {
                    if let snippet = snippet(of: body, for: search) { hits.append(hit(snippet)) }
                } else if search.matches(body) {
                    more += 1
                }
            }
            for (index, page) in pages.enumerated() {
                if Task.isCancelled { return result }
                guard let text = await package.readText(page.id) else { continue }
                take(text) { PageHit(notebookID: id, page: page, index: index, snippet: $0) }
            }
            for recording in manifest.recordings where recording.transcriptFile != nil {
                if Task.isCancelled { return result }
                let index = recording.inkedPages?.compactMap { id in pages.firstIndex { $0.id == id } }.min() ?? 0
                guard pages.indices.contains(index),
                      let text = try? String(contentsOf: package.transcriptTextURL(recording.id), encoding: .utf8) else { continue }
                take(text) { PageHit(notebookID: id, page: pages[index], index: index, snippet: $0, recording: PageHit.Recording(id: recording.id, name: recording.name)) }
            }
            if !hits.isEmpty { result.pages[id] = hits }
            if more > 0 { result.more[id] = more }
            total += hits.count
        }
        return result
    }

    /// The text around the whole query, or else its longest term, on one line without the "#ink:" header. Nil unless every term is in it.
    static func snippet(in text: String, for query: String, radius: Int = 36) -> String? {
        snippet(of: SearchQuery.searchable(text), for: SearchQuery(query), radius: radius)
    }

    private static func snippet(of body: String, for search: SearchQuery, radius: Int = 36) -> String? {
        guard search.matches(body), let range = search.focus(in: body) else { return nil }
        let start = body.index(range.lowerBound, offsetBy: -radius, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(range.upperBound, offsetBy: radius, limitedBy: body.endIndex) ?? body.endIndex
        let excerpt = body[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > body.startIndex ? "…" : "") + excerpt + (end < body.endIndex ? "…" : "")
    }

    /// Mustard under ink at night; on light paper the audit reads a pale band as faint text, so it deepens to ochre under cream.
    private static let highlighter = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .mustard : UIColor(hex: 0x806113) })
    private static let onHighlighter = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .onMustard : .labelCream })

    /// The snippet with the query and its terms in bold on a mustard band, so a match never relies on colour alone.
    static func highlighted(_ snippet: String, query: String) -> AttributedString {
        var text = AttributedString(snippet)
        for match in SearchQuery(query).highlights(in: snippet) {
            guard let range = Range(match, in: text) else { continue }
            text[range].backgroundColor = highlighter
            text[range].foregroundColor = onHighlighter
            text[range].font = .subheadline.bold()
        }
        return text
    }
}

/// "Pages" results under the matching notebooks: each hit shows its page and the text around the match.
struct PageHitsSection: View {
    let records: [NotebookRecord]
    let hits: [UUID: [PageHit]]
    var more: [UUID: Int] = [:]
    let query: String
    let zoomNamespace: Namespace.ID
    let onOpen: (NotebookRecord, UUID, String) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Space.x5) {
            ShelfLabel(title: String(localized: "Pages"))
            ForEach(records.filter { hits[$0.id] != nil }) { record in
                VStack(alignment: .leading, spacing: Space.x2) {
                    title(record)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Space.x4) {
                            ForEach(hits[record.id] ?? []) { hit in
                                PageHitCard(hit: hit, query: query, zoomNamespace: zoomNamespace) { onOpen(record, hit.page.id, "hit-\(hit.id)") }
                                    .accessibilityLabel(Text(hit.label(in: record.title)))
                                    .accessibilityHint(Text("Opens the notebook at this page"))
                            }
                        }
                        .padding(.vertical, Space.x1)
                    }
                }
            }
        }
    }

    /// The notebook's name, then how many more matches it has than are shown, on one line where they fit.
    @ViewBuilder
    private func title(_ record: NotebookRecord) -> some View {
        let name = Text(record.title).font(.headline).foregroundStyle(Color.ink)
        if let count = more[record.id] {
            let line = String(localized: "\(count) more matches")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Space.x3) { name; Text(line).metaStyle(.footnote) }
                VStack(alignment: .leading, spacing: Space.x1) { name; Text(line).metaStyle(.footnote) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(record.title), \(line)"))
        } else {
            name
        }
    }
}

private struct PageHitCard: View {
    let hit: PageHit
    let query: String
    let zoomNamespace: Namespace.ID
    let action: () -> Void
    @Environment(LibraryStore.self) private var store
    @State private var image: UIImage?
    @PaperNight private var night
    @AppStorage(SettingsKey.evenHighlights) private var evenHighlights = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.x3) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable()
                    } else {
                        Rectangle().fill(Color(uiColor: hit.page.paperShown(night: night)))
                    }
                }
                .aspectRatio(hit.page.shownSize.width / max(hit.page.shownSize.height, 1), contentMode: .fit)
                .frame(width: 56)
                .overlay { Rectangle().strokeBorder(Color.hairline, lineWidth: 1) }
                VStack(alignment: .leading, spacing: Space.x1) {
                    if hit.recording != nil {
                        Label(hit.place, systemImage: "waveform").metaStyle(.caption)
                    } else {
                        Text(hit.place).metaStyle(.caption)
                    }
                    Text(PageSearch.highlighted(hit.snippet, query: query))
                        .font(.subheadline)
                        .foregroundStyle(Color.ink)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .frame(width: 200, alignment: .leading)
            }
            .padding(Space.x3)
            .background(Color.surface, in: RoundedRectangle.plate)
            .overlay { RoundedRectangle.plate.strokeBorder(Color.hairline) }
            .zoomSource(id: "hit-\(hit.id)", in: zoomNamespace)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .task(id: "\(hit.page.thumbnailKey)-\(night)-\(evenHighlights)") {
            image = await PageThumbnailer.thumbnail(package: NotebookPackage(root: store.root, id: hit.notebookID), page: hit.page, night: night,
                                                  even: evenHighlights)
        }
    }
}
