import SwiftUI
import SwiftData

/// Every notebook that takes the PDFs from another app, opened last first, with a search; closed without a choice, nothing comes in.
struct IncomingPDFList: View {
    let desk: IncomingPDFDesk
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var store
    @Query(filter: #Predicate<NotebookRecord> { $0.deletedAt == nil }) private var records: [NotebookRecord]
    @State private var search = ""
    @FocusState private var searching: Bool

    var body: some View {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let terms = SearchQuery(search).terms
        let shown = IncomingPDFDesk.offer(records, store: store).all.compactMap { byID[$0] }
            .filter { record in terms.allSatisfy { record.title.localizedStandardContains($0) } }
        NavigationStack {
            Ledger {
                ForEach(shown) { record in
                    Button {
                        desk.add(to: record.id, title: record.title, store: store)
                        dismiss()
                    } label: {
                        HStack(spacing: Space.x4) {
                            RecordCover(record: record, width: CoverWidth.row, showsShadow: false)
                                .frame(width: 40)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Space.x1) {
                                Text(record.title.orUntitled).font(.headline).foregroundStyle(Color.ink)
                                Text(record.pageCountText)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                    }
                    .accessibilityHint(Text("Adds the pages after its last page."))
                    .accessibilityIdentifier("incomingPDF.list.\(record.title)")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                OwlLunaSearchField("Search", text: $search, capsTextSize: false, identifier: "incomingPDF.search", focus: $searching)
                    .padding(.horizontal, Space.x4)
                    .padding(.top, Space.x2)
                    .background(Color.desk)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Color.desk)
            .overlay {
                if shown.isEmpty {
                    EmptyPlate("Nothing found for “\(search)”", systemImage: "magnifyingglass", message: Text("Check the spelling, or try other words."))
                }
            }
            .navigationTitle("Add to a Notebook")
            .barGround(.desk)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                CancelToolbarItem { dismiss() }
            }
        }
    }
}
