import SwiftUI

/// The tiles of the splash, in the order they are drawn: a later tile passes over an earlier one as it lands.
enum BentoTile: CaseIterable, Sendable {
    case ticker, volume, note, cards, moon, owl, word
}

/// The words printed on the tiles, in capitals and in the reader's language. The wordmark is not one of them.
enum BentoWords {
    static let notebook = String(localized: "NOTEBOOK")
    static let notes = String(localized: "NOTES")
    static let page = String(localized: "P. 12")
    static let volume = String(localized: "VOL.")
    static let write = String(localized: "WRITE")
    static let sketch = String(localized: "SKETCH")
    static let study = String(localized: "STUDY")

    /// The three things the app is for, each with its English, which a tile falls back on when it cannot set the word.
    static let verbs = [(word: write, english: "WRITE"), (word: sketch, english: "SKETCH"), (word: study, english: "STUDY")]
}

/// What a tile needs to draw itself at one moment.
struct BentoScene {
    let time: Double
    let exit: Double
    let palette: SplashPalette
    /// A hundredth of the window's shorter side.
    let unit: CGFloat

    /// The size the tiles' small labels are set at; their corners are placed in it too.
    var labelSize: CGFloat { unit * 1.7 }
}

extension GraphicsContext {
    /// A small label in tracked system bold, fading up as `shown` goes to 1; `corner` is the top of its one-em line at the leading end, or the trailing end when `trailing`.
    func label(_ string: String, corner: CGPoint, trailing: Bool = false, shown: Double, scene: BentoScene) {
        guard shown > 0 else { return }
        let em = scene.labelSize
        var layer = self
        layer.opacity = shown
        let text = layer.resolve(Text(verbatim: string).font(.system(size: em, weight: .bold)).tracking(em * 0.18).foregroundStyle(scene.palette.ink))
        let ascent = text.firstBaseline(in: CGSize(width: CGFloat.infinity, height: .infinity))
        layer.draw(text, at: CGPoint(x: corner.x, y: corner.y + em * (0.8555 + 0.9 * (1 - shown)) - ascent), anchor: trailing ? .topTrailing : .topLeading)
    }
}

/// The splash's grid in one window: where each tile rests, and the way it comes and goes.
struct BentoBoard {
    /// The whole window; the grid is laid out in `area`, which starts under the status bar.
    let size: CGSize
    let area: CGRect
    let unit: CGFloat
    private let arrangement: Arrangement

    private static let columns = 12
    var gutter: CGFloat { unit * 1.8 }
    var outline: CGFloat { unit * 0.42 }
    var corner: CGFloat { unit * 1.1 }

    init(size: CGSize, statusBar: CGFloat = 0) {
        self.size = size
        let halfGutter = min(size.width, size.height) * 0.009
        let top = min(max(0, statusBar - halfGutter), size.height / 4)
        area = CGRect(x: 0, y: top, width: size.width, height: size.height - top)
        unit = min(area.width, area.height) / 100
        arrangement = area.width <= area.height ? .tall : (area.width >= area.height * 2 ? .wide : .landscape)
    }

    func frame(_ tile: BentoTile) -> CGRect {
        let slot = arrangement.slot(tile)
        let column = (area.width - gutter * CGFloat(Self.columns + 1)) / CGFloat(Self.columns)
        let row = (area.height - gutter * CGFloat(arrangement.rows + 1)) / CGFloat(arrangement.rows)
        return CGRect(x: area.minX + gutter + CGFloat(slot.columns.lowerBound) * (column + gutter),
                      y: area.minY + gutter + CGFloat(slot.rows.lowerBound) * (row + gutter),
                      width: CGFloat(slot.columns.count) * (column + gutter) - gutter,
                      height: CGFloat(slot.rows.count) * (row + gutter) - gutter)
    }

    /// How far beyond the tile its paper plate reaches: almost a gutter, and right off the window where the tile is the last before its edge.
    func plateReach(_ frame: CGRect) -> EdgeInsets {
        let reach = gutter - unit * 0.1
        func side(_ margin: CGFloat, past edge: CGFloat = 0) -> CGFloat { -(margin < edge + gutter * 1.5 ? margin + 1 : reach) }
        return EdgeInsets(top: side(frame.minY, past: area.minY), leading: side(frame.minX),
                          bottom: side(size.height - frame.maxY), trailing: side(size.width - frame.maxX))
    }

    /// A tile stops coming in the moment the tiles start to leave, so a splash sent away early only takes off what has arrived.
    func pose(_ tile: BentoTile, at clock: SplashClock) -> Pose {
        let enter = tile.entrance.progress(clock.time - (clock.leaving ?? 0)), leave = tile.departure.progress(clock.exit)
        if tile == .volume {
            return Pose(offset: .zero, degrees: -14 * (1 - enter) + 12 * leave, scale: enter * (1 - leave))
        }
        let frame = frame(tile), slot = arrangement.slot(tile)
        return Pose(offset: CGSize(width: (slot.enter.dx * (1 - enter) + slot.leave.dx * leave) * frame.width,
                                   height: (slot.enter.dy * (1 - enter) + slot.leave.dy * leave) * (frame.height + area.minY)),
                    degrees: slot.tilt * (1 - enter + leave), scale: 1)
    }

    struct Pose {
        var offset: CGSize
        var degrees: Double
        var scale: CGFloat
    }

    /// Rows and columns are counted from 0; `enter` and `leave` are in tile widths and heights, the height with the status bar's strip added.
    private struct Slot {
        var rows: Range<Int>
        var columns: Range<Int>
        var enter = CGVector.zero
        var tilt = 0.0
        var leave = CGVector.zero
    }

    private enum Arrangement {
        case landscape, tall, wide

        var rows: Int { self == .tall ? 14 : 12 }

        func slot(_ tile: BentoTile) -> Slot {
            switch (self, tile) {
            case (.landscape, .owl): Slot(rows: 0..<7, columns: 0..<5, enter: CGVector(dx: -1.25, dy: 0), tilt: -5, leave: CGVector(dx: -1.32, dy: 0))
            case (.landscape, .note): Slot(rows: 0..<5, columns: 5..<9, enter: CGVector(dx: 0, dy: -1.3), tilt: 4, leave: CGVector(dx: 0, dy: -1.36))
            case (.landscape, .moon): Slot(rows: 0..<2, columns: 9..<12, enter: CGVector(dx: 0, dy: -1.7), tilt: -8, leave: CGVector(dx: 0, dy: -1.76))
            case (.landscape, .cards): Slot(rows: 2..<5, columns: 9..<12, enter: CGVector(dx: 1.35, dy: 0), tilt: 7, leave: CGVector(dx: 1.4, dy: 0))
            case (.landscape, .volume): Slot(rows: 5..<7, columns: 5..<7)
            case (.landscape, .ticker): Slot(rows: 5..<7, columns: 7..<12, enter: CGVector(dx: 1.25, dy: 0), tilt: 2, leave: CGVector(dx: 1.32, dy: 0))
            case (.landscape, .word): Slot(rows: 7..<12, columns: 0..<12, enter: CGVector(dx: 0, dy: 1.35), tilt: 1.5, leave: CGVector(dx: 0, dy: 1.42))

            case (.tall, .owl): Slot(rows: 0..<6, columns: 0..<12, enter: CGVector(dx: -1.15, dy: 0), tilt: -3, leave: CGVector(dx: -1.19, dy: 0))
            case (.tall, .note): Slot(rows: 6..<10, columns: 0..<6, enter: CGVector(dx: -1.25, dy: 0), tilt: 4, leave: CGVector(dx: -1.32, dy: 0))
            case (.tall, .moon): Slot(rows: 6..<8, columns: 6..<12, enter: CGVector(dx: 1.25, dy: 0), tilt: -6, leave: CGVector(dx: 1.32, dy: 0))
            case (.tall, .volume): Slot(rows: 8..<10, columns: 6..<8)
            case (.tall, .cards): Slot(rows: 8..<10, columns: 8..<12, enter: CGVector(dx: 1.4, dy: 0), tilt: 7, leave: CGVector(dx: 1.46, dy: 0))
            case (.tall, .ticker): Slot(rows: 10..<11, columns: 0..<12, enter: CGVector(dx: 1.15, dy: 0), tilt: 1, leave: CGVector(dx: 1.19, dy: 0))
            case (.tall, .word): Slot(rows: 11..<14, columns: 0..<12, enter: CGVector(dx: 0, dy: 1.4), tilt: 1.5, leave: CGVector(dx: 0, dy: 1.48))

            case (.wide, .owl): Slot(rows: 0..<12, columns: 0..<3, enter: CGVector(dx: -1.3, dy: 0), tilt: -5, leave: CGVector(dx: -1.38, dy: 0))
            case (.wide, .note): Slot(rows: 0..<6, columns: 3..<6, enter: CGVector(dx: 0, dy: -1.3), tilt: 4, leave: CGVector(dx: 0, dy: -1.36))
            case (.wide, .moon): Slot(rows: 0..<3, columns: 6..<9, enter: CGVector(dx: 0, dy: -1.7), tilt: -8, leave: CGVector(dx: 0, dy: -1.76))
            case (.wide, .cards): Slot(rows: 0..<3, columns: 9..<12, enter: CGVector(dx: 1.35, dy: 0), tilt: 7, leave: CGVector(dx: 1.4, dy: 0))
            case (.wide, .volume): Slot(rows: 3..<6, columns: 6..<8)
            case (.wide, .ticker): Slot(rows: 3..<6, columns: 8..<12, enter: CGVector(dx: 1.25, dy: 0), tilt: 2, leave: CGVector(dx: 1.32, dy: 0))
            case (.wide, .word): Slot(rows: 6..<12, columns: 3..<12, enter: CGVector(dx: 0, dy: 1.35), tilt: 1.5, leave: CGVector(dx: 0, dy: 1.42))
            }
        }
    }
}

extension BentoTile {
    /// In from an edge on a spring that passes its place and locks; the volume tile is stuck on last, like a label.
    var entrance: SplashBeat {
        func landing(_ delay: Double, _ damping: Double) -> SplashBeat {
            SplashBeat(delay: delay, duration: 900, curve: .spring(damping: damping, settle: 6.6))
        }
        return switch self {
        case .owl: landing(30, 0.62)
        case .word: landing(90, 0.64)
        case .note: landing(150, 0.6)
        case .ticker: landing(210, 0.62)
        case .cards: landing(265, 0.58)
        case .moon: landing(320, 0.56)
        case .volume: SplashBeat(delay: 560, duration: 700, curve: .spring(damping: 0.5, settle: 6.2))
        }
    }

    /// Off to the nearest edge, one tile after another.
    var departure: SplashBeat {
        func peel(_ delay: Double, _ duration: Double) -> SplashBeat {
            SplashBeat(delay: delay, duration: duration, curve: .bezier(0.35, 0.1, 0.85, 0.55))
        }
        return switch self {
        case .word: peel(30, 320)
        case .owl: peel(56, 320)
        case .note: peel(82, 300)
        case .ticker: peel(108, 290)
        case .cards: peel(134, 280)
        case .moon: peel(160, 270)
        case .volume: SplashBeat(delay: 140, duration: 230, curve: .bezier(0.55, -0.25, 0.75, 0.1))
        }
    }

    /// Off the window again: a tile that came only part of the way in has left once it has gone as far back.
    func hasLeft(at clock: SplashClock) -> Bool {
        let came = entrance.progress(clock.time - (clock.leaving ?? 0)), gone = departure.progress(clock.exit)
        return came <= 0 || gone >= (self == .volume ? 1 : min(came, 1))
    }

    /// The clock a tile's scene is drawn from: stopped once the scene is finished, and leaving only for the owl, which watches the others go.
    func sceneClock(_ clock: SplashClock) -> SplashClock {
        switch self {
        case .note, .volume, .word: SplashClock(time: min(clock.time, BentoSplash.rest))
        case .ticker, .cards, .moon: SplashClock(time: clock.time)
        case .owl: clock
        }
    }

    func fill(_ palette: SplashPalette) -> Color {
        switch self {
        case .owl, .cards: palette.moon
        case .note, .volume: palette.board
        case .moon, .word: palette.ink
        case .ticker: palette.tomato
        }
    }

    func draw(_ context: GraphicsContext, size: CGSize, scene: BentoScene) {
        switch self {
        case .ticker: BentoTickerTile.draw(context, size: size, scene: scene)
        case .volume: BentoVolumeTile.draw(context, size: size, scene: scene)
        case .note: BentoNoteTile.draw(context, size: size, scene: scene)
        case .cards: BentoCardsTile.draw(context, size: size, scene: scene)
        case .moon: BentoMoonTile.draw(context, size: size, scene: scene)
        case .owl: BentoOwlTile.draw(context, size: size, scene: scene)
        case .word: BentoWordTile.draw(context, size: size, scene: scene)
        }
    }
}

/// The launch splash: seven tiles spring into a grid over the paper, each plays its own small scene, and they peel off the library.
struct BentoSplash: View {
    /// The tiles have landed, and the page, the volume and the wordmark are finished.
    nonisolated static let rest = 1700.0
    /// Every scene has played and only the loops run on: the moment Reduce Motion shows as a still.
    nonisolated static let still = 2160.0
    /// When the tiles may start to leave, once the app is ready; a hurried splash goes sooner.
    nonisolated static let handOver = 2150.0
    /// How long the leaving takes, the library's settling included.
    nonisolated static let leaveDuration = 510.0

    let clock: SplashClock
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { safe in
            let statusBar = safe.safeAreaInsets.top
            GeometryReader { geometry in
                let board = BentoBoard(size: geometry.size, statusBar: statusBar)
                let palette = colorScheme == .dark ? SplashPalette.dark : .light
                ZStack {
                    if clock.leaving == nil { palette.ground }
                    ForEach(BentoTile.allCases, id: \.self) { tile in
                        BentoTileView(tile: tile, board: board, clock: clock, palette: palette)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// A tile's scene, drawn again only when its moment changes.
private struct BentoTileScene: View {
    let tile: BentoTile
    let scene: BentoScene

    var body: some View {
        Canvas { context, size in
            tile.draw(context, size: size, scene: scene)
        }
    }
}

private struct BentoTileView: View {
    let tile: BentoTile
    let board: BentoBoard
    let clock: SplashClock
    let palette: SplashPalette

    var body: some View {
        let frame = board.frame(tile)
        let pose = board.pose(tile, at: clock)
        let moment = tile.sceneClock(clock)
        let scene = BentoScene(time: moment.time, exit: moment.exit, palette: palette, unit: board.unit)
        ZStack {
            if clock.leaving != nil {
                Rectangle().fill(palette.ground).padding(board.plateReach(frame))
            }
            RoundedRectangle(cornerRadius: board.corner).fill(tile.fill(palette))
            BentoTileScene(tile: tile, scene: scene)
                .clipShape(RoundedRectangle(cornerRadius: board.corner - board.outline))
                .padding(board.outline)
            RoundedRectangle(cornerRadius: board.corner).strokeBorder(palette.outline, lineWidth: board.outline)
        }
        .frame(width: frame.width, height: frame.height)
        .scaleEffect(pose.scale)
        .rotationEffect(.degrees(pose.degrees))
        .offset(pose.offset)
        .position(x: frame.midX, y: frame.midY)
    }
}
