import SwiftUI

/// The empty library's shelf: ghost spines leaning on one cloth notebook. Without a cloth, just the ghosts.
struct ShelfIllustration: View {
    var cloth: ClothColor? = .cobalt

    var body: some View {
        HStack(alignment: .bottom, spacing: Space.x1) {
            GhostSpine(width: 18, height: 78)
            GhostSpine(width: 14, height: 88)
            if let cloth {
                GhostSpine(width: 20, height: 76)
                    .rotationEffect(.degrees(12), anchor: .bottomTrailing)
                    .padding(.trailing, 14)
                ClothNotebook(cloth: cloth)
            } else {
                GhostSpine(width: 20, height: 72)
                GhostSpine(width: 16, height: 82)
            }
        }
        .padding(.horizontal, Space.x5)
        .onLedge()
    }
}

/// Favourites before there are any: an empty cover's outline with the ribbon a favourite gets.
struct RibbonIllustration: View {
    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: Radius.coverSpine, bottomLeadingRadius: Radius.coverSpine,
                               bottomTrailingRadius: Radius.coverEdge, topTrailingRadius: Radius.coverEdge)
            .strokeBorder(Color.hairline, lineWidth: 1.5)
            .frame(width: 66, height: 88)
            .overlay(alignment: .topTrailing) {
                RibbonShape()
                    .fill(Color.tomato)
                    .overlay { RibbonShape().stroke(Color.labelCream, lineWidth: 1.5) }
                    .frame(width: 16, height: 50)
                    .padding(.trailing, Space.x3)
            }
            .padding(.horizontal, Space.x8)
            .onLedge()
    }
}

private extension View {
    /// Stands the illustration on a ledge as wide as itself.
    func onLedge() -> some View {
        padding(.bottom, ShelfLedge.height + 8)
            .background(alignment: .bottom) { ShelfLedge() }
            .accessibilityHidden(true)
    }
}

private struct GhostSpine: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(Color.hairline, lineWidth: 1.5)
            .frame(width: width, height: height)
    }
}

/// A small bound notebook standing face out: cloth board over a cream page block, a label and a ribbon.
private struct ClothNotebook: View {
    let cloth: ClothColor
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let board = UnevenRoundedRectangle(topLeadingRadius: Radius.coverSpine, bottomLeadingRadius: Radius.coverSpine,
                                           bottomTrailingRadius: Radius.coverEdge, topTrailingRadius: Radius.coverEdge)
        board
            .fill(cloth.color)
            .overlay(alignment: .leading) { Color.black.opacity(0.2).frame(width: 6) }
            .overlay { Color.black.opacity(colorScheme == .dark ? 0.1 : 0) }
            .overlay(alignment: .topLeading) {
                Color.labelCream
                    .overlay { Rectangle().strokeBorder(Color.labelInk.opacity(0.3), lineWidth: 1).padding(2) }
                    .frame(width: 44, height: 20)
                    .padding(.leading, 12)
                    .padding(.top, 15)
            }
            .clipShape(board)
            .overlay(alignment: .topTrailing) { FavoriteRibbon().scaleEffect(0.8, anchor: .top).padding(.trailing, Space.x2) }
            .padding(.trailing, 2)
            .padding(.bottom, 1.5)
            .background { board.fill(Color.labelCream).overlay { board.strokeBorder(Color.hairline, lineWidth: 0.5) } }
            .frame(width: 66, height: 88)
    }
}

struct ShelfLabel: View {
    let title: String
    var cloth: ClothColor?
    var body: some View {
        HStack(spacing: Space.x3) {
            if let cloth { SpineChip(cloth: cloth) }
            Text(title).metaStyle(.footnote).fixedSize().accessibilityAddTraits(.isHeader)
            Rectangle().fill(Color.hairline).frame(height: 1).accessibilityHidden(true)
        }
    }
}

struct EmptyShelf<Actions: View, Illustration: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let message: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var illustration: Illustration

    init(title: String, message: String, @ViewBuilder actions: () -> Actions = { EmptyView() },
         @ViewBuilder illustration: () -> Illustration = { EmptyView() }) {
        self.title = title
        self.message = message
        self.actions = actions()
        self.illustration = illustration()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content.frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        VStack(spacing: Space.x4) {
            illustration
            Text(title)
                .displayFont(30, relativeTo: .title)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .displayTextFont(17, relativeTo: .body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.textSecondary)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: Space.x3) { actions }
                } else {
                    // Side by side where both names fit whole, as on a phone's narrow shelf they may not.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Space.x3) { actions }
                        VStack(spacing: Space.x3) { actions }
                    }
                }
            }
            .controlSize(.large)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)
        .padding(Space.x8)
        .frame(maxWidth: .infinity)
    }
}
