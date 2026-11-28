import SwiftUI

struct OnThisDayCard: View {
    let memory: DeskMemory
    let zoomNamespace: Namespace.ID
    var asRow = false
    let action: () -> Void
    let onHide: () -> Void
    let onTurnOff: () -> Void
    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @PaperNight private var night
    @AppStorage(SettingsKey.evenHighlights) private var evenHighlights = false

    private var record: NotebookRecord { memory.record }
    private var notebookTitle: String { record.title.orUntitled }
    private var fullDate: String { memory.resurfaced.date.formatted(.dateTime.day().month(.wide).year()) }
    private var zoomID: String { "onthisday-\(record.id.uuidString)" }

    private var title: String {
        memory.page == nil ? String(localized: "You started \(notebookTitle)") : notebookTitle
    }

    private var detail: String {
        if let number = memory.number { return String(localized: "Page \(number) · \(fullDate)") }
        let pages = String(localized: "\(record.pageCount) pages")
        return "\(fullDate) · \(pages)"
    }

    var body: some View {
        Button(action: action) {
            DeskCardLayout(asRow: asRow) {
                thumbnail
            } text: {
                Label {
                    Text(memory.resurfaced.headline)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath").imageScale(.small)
                }
                .labelStyle(DeskEyebrowLabelStyle())
                .eyebrowStyle(Color.textSecondary)
                Text(title)
                    .modifier(DeskTitle(asRow: asRow))
                Text(detail)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.textSecondary)
            } accessory: {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 36, height: 36)
            }
        }
        .buttonStyle(DeskCardButtonStyle())
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(memory.number.map { Text("\(memory.resurfaced.headline): \(notebookTitle), page \($0)") }
                            ?? Text("\(memory.resurfaced.headline) you started \(notebookTitle)"))
        .accessibilityHint(memory.page == nil ? Text("Opens the notebook") : Text("Opens the notebook at this page"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("desk.onThisDay")
        .accessibilityAction(named: Text("Hide for Today"), onHide)
        .accessibilityAction(named: Text("Turn Off On This Day"), onTurnOff)
        .heldMenu(Text("On This Day")) {
            Button(action: onHide) { Label("Hide for Today", systemImage: "eye.slash") }
            Button(action: onTurnOff) { Label("Turn Off On This Day", systemImage: "clock.badge.xmark") }
        }
        .task(id: "\(memory.page?.thumbnailKey ?? "")|\(night)|\(evenHighlights)") { await loadImage() }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let page = memory.page {
            DeskPage(image: image, page: page, width: asRow ? 44 : 56)
                .rotationEffect(.degrees(asRow ? 0 : -3))
                .zoomSource(id: zoomID, in: zoomNamespace)
        } else {
            RecordCover(record: record, width: CoverWidth.row, showsShadow: false)
                .frame(width: asRow ? 48 : 54)
                .zoomSource(id: zoomID, in: zoomNamespace)
                .accessibilityHidden(true)
        }
    }

    private func loadImage() async {
        guard let page = memory.page else { return }
        let loaded = await PageThumbnailer.thumbnail(package: NotebookPackage(root: store.root, id: record.id), page: page, night: night,
                                                         even: evenHighlights)
        guard !Task.isCancelled, let loaded else { return }
        withAnimation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion)) { image = loaded }
    }
}

private struct DeskEyebrowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.x1) {
            configuration.icon
            configuration.title
        }
    }
}
