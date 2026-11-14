import SwiftUI

/// Changes an existing notebook's cover with the same choices and live preview as New Notebook.
struct CoverEditorView: View {
    let record: NotebookRecord
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    @State private var spec: CoverSpec
    @State private var inkPair: Int

    init(record: NotebookRecord) {
        self.record = record
        let cover = record.cover
        _spec = State(initialValue: cover)
        _inkPair = State(initialValue: RisoInk.pairIndex(of: cover.inks) ?? 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x5) {
                    let root = store.root, id = record.id
                    CoverView(request: record.coverRequest(width: CoverWidth.preview, scale: displayScale, colorScheme: colorScheme,
                                                           contrast: contrast, root: root, spec: spec), persist: false) {
                        await PageThumbnailer.ensureFirstPage(root: root, notebookID: id)
                    }
                    .frame(width: 200)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(false)
                    .accessibilityLabel(Text("Cover preview: \(spec.style.displayName) cover for \(record.title)"))
                    ShuffleButton(style: spec.style) {
                        var generator = SystemRandomNumberGenerator()
                        spec = CoverShuffle.next(spec, using: &generator)
                        inkPair = RisoInk.pairIndex(of: spec.inks) ?? inkPair
                    }
                    .frame(maxWidth: .infinity)
                    CoverStyleOptions(style: $spec.style, cloth: $spec.cloth, inkPair: $inkPair)
                }
                .padding(Space.x6)
            }
            .background(Color.surface)
            .navigationTitle("Change Cover")
            .barGround(.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                CancelToolbarItem { dismiss() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.setCover(spec, for: record)
                        dismiss()
                    }
                    .buttonStyle(.owlLuna(.primary, inBar: true))
                    .keyboardShortcut(.defaultAction)
                }
                .boardBackground()
            }
            .onChange(of: inkPair) { _, index in spec.inks = RisoInk.pairs[index] }
        }
    }
}
