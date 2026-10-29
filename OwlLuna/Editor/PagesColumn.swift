import SwiftUI

/// Beside the page on an iPhone with room for it, such as an unfolded iPhone Duo: the notebook's pages, the one on show
/// marked, a tap away. A panel that opens beside the page takes its place.
struct PagesColumn: View {
    let session: EditorSession
    var side = HorizontalEdge.trailing

    static let width: CGFloat = 132

    var body: some View {
        let document = session.document, current = session.currentPage
        VStack(spacing: 0) {
            Text("Pages")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.onPrimaryCloth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.x3)
                .padding(.vertical, 7)
                .background { Rectangle().fill(Color.primaryCloth).clothWeave(in: Rectangle()) }
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.x4) {
                        ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                            Button { session.go(to: index) } label: {
                                PageThumbnailCell(document: document, page: page, index: index, isCurrent: index == current)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(index == current ? Text("Page \(index + 1) of \(document.pages.count), current")
                                                                 : Text("Page \(index + 1) of \(document.pages.count)"))
                            .accessibilityHint(Text("Opens this page"))
                            .id(page.id)
                        }
                    }
                    .padding(Space.x3)
                }
                .onChange(of: current, initial: true) { _, index in
                    guard document.pages.indices.contains(index) else { return }
                    withAnimation(Motion.standard) { proxy.scrollTo(document.pages[index].id, anchor: .center) }
                }
            }
        }
        .frame(width: Self.width)
        .background(Color.surface)
        .overlay(alignment: Alignment(horizontal: side.other.alignment, vertical: .center)) {
            Rectangle().fill(Color.hairline).frame(width: 1).ignoresSafeArea()
        }
        .dynamicTypeSize(...barTextLimit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Pages"))
        .accessibilityIdentifier("editor.pagesColumn")
    }
}
