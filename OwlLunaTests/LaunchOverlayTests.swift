import XCTest
import SwiftUI
@testable import OwlLuna

@MainActor
final class LaunchOverlayTests: XCTestCase {
    /// The splash plays only for the first scene of a real launch: not for UI tests, not under XCTest, not for a second window.
    func testGatePlaysOnlyForTheFirstSceneOfARealLaunch() {
        XCTAssertTrue(LaunchAnimation.isEnabled(arguments: ["OwlLuna"], underTest: false, firstScene: true))
        XCTAssertFalse(LaunchAnimation.isEnabled(arguments: ["OwlLuna", "-storageRoot", "Launch"], underTest: false, firstScene: true))
        XCTAssertFalse(LaunchAnimation.isEnabled(arguments: ["OwlLuna", "-skipLaunchAnimation"], underTest: false, firstScene: true))
        XCTAssertFalse(LaunchAnimation.isEnabled(arguments: ["OwlLuna"], underTest: true, firstScene: true))
        XCTAssertFalse(LaunchAnimation.isEnabled(arguments: ["OwlLuna"], underTest: false, firstScene: false))
    }

    func testGateIsOffInTheTestProcess() {
        XCTAssertFalse(LaunchAnimation.isEnabled)
        XCTAssertFalse(LaunchAnimation.isEnabled, "and stays off once the first scene is claimed")
    }

    func testAHurriedSplashLeavesAtOnceAndOneNobodyHasSeenIsSimplyOver() {
        var clock = SplashClock(time: 0)
        for _ in 0..<30 { XCTAssertNil(LaunchOverlay.advance(&clock, by: 16, ready: false, hurried: true)) }
        XCTAssertEqual(clock.time, 0, "nothing of it is shown while something is waiting")
        XCTAssertEqual(LaunchOverlay.advance(&clock, by: 16, ready: true, hurried: true), .finished)
        XCTAssertNil(clock.leaving, "there are no tiles to peel off")

        clock = SplashClock(time: 800)
        XCTAssertNil(LaunchOverlay.advance(&clock, by: 16, ready: false, hurried: true), "it plays on until the app is ready")
        XCTAssertEqual(clock.time, 816, accuracy: 1e-6)
        for (start, longest) in [(816.0, 440.0), (100, 300)] {
            clock = SplashClock(time: start)
            XCTAssertEqual(LaunchOverlay.advance(&clock, by: 16, ready: true, hurried: true), .handOver, "the tiles leave without waiting for 2.15 s")
            var events: [LaunchOverlay.Event] = []
            for _ in 0..<60 where events.isEmpty {
                if let event = LaunchOverlay.advance(&clock, by: 16, ready: true, hurried: true) { events.append(event) }
            }
            XCTAssertEqual(events, [.finished])
            XCTAssertLessThan(clock.exit, longest, "it is over as soon as what had come in has gone, from \(start) ms")
            XCTAssertTrue(BentoTile.allCases.allSatisfy { $0.hasLeft(at: clock) })
        }
    }

    func testTheCurtainHoldsOnlyWhileItIsUpAndAskingHurriesIt() {
        let curtain = LaunchCurtain()
        XCTAssertFalse(curtain.holds())
        XCTAssertFalse(curtain.isHurried, "nothing waits for a splash that is not there")
        curtain.isUp = true
        XCTAssertTrue(curtain.holds())
        XCTAssertTrue(curtain.isHurried)
        curtain.isUp = false
        XCTAssertFalse(curtain.holds())
    }

    func testAWindowKnowsWhetherItWillReopenANotebook() {
        let scene = "launch-\(UUID().uuidString)", notebook = UUID()
        defer { WindowMemory.keep(only: []) }
        XCTAssertFalse(WindowMemory.reopens(in: scene), "nothing kept, nothing noted")
        XCTAssertTrue(WindowMemory.reopens(in: scene, fallback: notebook.uuidString), "nothing kept yet, so the scene's own note counts")
        WindowMemory.remember(notebook, beside: nil, in: scene)
        XCTAssertTrue(WindowMemory.reopens(in: scene))
        WindowMemory.remember(nil, beside: nil, in: scene)
        XCTAssertFalse(WindowMemory.reopens(in: scene, fallback: notebook.uuidString), "back in the library: what is kept here wins over an older note")
    }

    func testEveryGroupHasPartsInBothLaunchPalettes() {
        for (name, groups) in [("light", OwlLunaMarkGroups.launchLight), ("dark", .launchDark)] {
            XCTAssertNotNil(groups.skyTop, "\(name) tile")
            XCTAssertNotNil(groups.glow, "\(name) halo")
            for group in OwlLunaMarkGroups.Group.allCases {
                XCTAssertFalse(groups.parts(group).isEmpty, "\(name) \(group)")
            }
        }
        XCTAssertNotEqual(OwlLunaMarkGroups.launchLight.skyTop, OwlLunaMarkGroups.launchDark.skyTop)
    }
}

@MainActor
final class BentoSplashTests: XCTestCase {
    /// An iPad in landscape and in portrait, a wide strip of a window, a narrow one and a short one.
    private let windows = [CGSize(width: 640, height: 360), CGSize(width: 1194, height: 834), CGSize(width: 834, height: 1194), CGSize(width: 1366, height: 500), CGSize(width: 375, height: 1024)]

    /// Where a tile and its paper plate are drawn at one moment.
    private func place(_ tile: BentoTile, on board: BentoBoard, at clock: SplashClock) -> CGRect {
        let frame = board.frame(tile), pose = board.pose(tile, at: clock)
        let centre = CGAffineTransform(translationX: frame.midX + pose.offset.width, y: frame.midY + pose.offset.height)
        return CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height)
            .insetBy(dx: -board.gutter, dy: -board.gutter)
            .applying(centre.rotated(by: pose.degrees * .pi / 180).scaledBy(x: pose.scale, y: pose.scale))
    }

    func testSplashStartsOnBarePaperAndLeavesTheLibraryBare() {
        let moments = [("start", SplashClock(time: 0)), ("last unseen moment", SplashClock(time: LaunchOverlay.unseen)),
                       ("end", SplashClock(time: 9000, leaving: BentoSplash.leaveDuration))]
            + [100.0, 300, 900].map { ("end of a leave begun at \(Int($0))", SplashClock(time: $0 + BentoSplash.leaveDuration, leaving: BentoSplash.leaveDuration)) }
        for size in windows {
            for statusBar: CGFloat in [0, 24, 32] {
                let board = BentoBoard(size: size, statusBar: statusBar), window = CGRect(origin: .zero, size: size)
                for (name, clock) in moments {
                    for tile in BentoTile.allCases {
                        let placed = place(tile, on: board, at: clock)
                        XCTAssertTrue(placed.isEmpty || !placed.intersects(window), "\(tile) at the \(name) in \(size) under a bar of \(statusBar)")
                    }
                }
            }
        }
    }

    func testATileStopsComingInOnceTheTilesStartToLeave() {
        let board = BentoBoard(size: CGSize(width: 1194, height: 834), statusBar: 24)
        for start in [400.0, 700] {
            for tile in BentoTile.allCases {
                let held = board.pose(tile, at: SplashClock(time: start)), leaving = board.pose(tile, at: SplashClock(time: start + 20, leaving: 20))
                XCTAssertEqual(leaving.offset.width, held.offset.width, accuracy: 0.001, "\(tile) from \(start)")
                XCTAssertEqual(leaving.offset.height, held.offset.height, accuracy: 0.001, "\(tile) from \(start)")
                XCTAssertEqual(leaving.degrees, held.degrees, accuracy: 0.001, "\(tile) from \(start)")
                XCTAssertEqual(leaving.scale, held.scale, accuracy: 0.001, "\(tile) from \(start)")
            }
        }
    }

    func testTilesRestOnTheGridAndFillTheWindow() {
        for size in windows {
            let board = BentoBoard(size: size), window = CGRect(origin: .zero, size: size)
            var placed: [CGRect] = []
            for tile in BentoTile.allCases {
                let frame = board.frame(tile), pose = board.pose(tile, at: SplashClock(time: BentoSplash.rest))
                XCTAssertEqual(tile.sceneClock(SplashClock(time: 9000)).leaving, nil, "\(tile) is not drawn as leaving before the hand-over")
                XCTAssertEqual(pose.offset, .zero, "\(tile) in \(size)")
                XCTAssertEqual(pose.degrees, 0, accuracy: 0.001, "\(tile) in \(size)")
                XCTAssertEqual(pose.scale, 1, accuracy: 0.001, "\(tile) in \(size)")
                XCTAssertTrue(window.contains(frame), "\(tile) in \(size)")
                XCTAssertFalse(placed.contains { $0.intersects(frame) }, "\(tile) overlaps another in \(size)")
                placed.append(frame)
            }
            let covered = placed.reduce(0) { $0 + ($1.width + board.gutter) * ($1.height + board.gutter) }
            XCTAssertEqual(covered, (size.width - board.gutter) * (size.height - board.gutter), accuracy: 1, "tiles and gutters in \(size)")
        }
    }

    func testTheGridStartsUnderTheStatusBarAndPlatesReachTheWindowEdges() {
        let size = CGSize(width: 1194, height: 834)
        let board = BentoBoard(size: size, statusBar: 24), bare = BentoBoard(size: size)
        XCTAssertEqual(bare.area, CGRect(origin: .zero, size: size))
        for tile in BentoTile.allCases {
            let frame = board.frame(tile), reach = board.plateReach(frame)
            XCTAssertGreaterThanOrEqual(frame.minY, 24, "\(tile)")
            XCTAssertLessThanOrEqual(frame.maxY, size.height - board.gutter + 0.01, "\(tile)")
            let plate = CGRect(x: frame.minX + reach.leading, y: frame.minY + reach.top,
                               width: frame.width - reach.leading - reach.trailing, height: frame.height - reach.top - reach.bottom)
            for other in BentoTile.allCases where other != tile {
                XCTAssertFalse(plate.intersects(board.frame(other)), "the plate of \(tile) lies over \(other)")
            }
            if frame.minY < 60 { XCTAssertLessThan(plate.minY, 0, "\(tile) leaves the status bar's strip bare") }
            if frame.minX < 60 { XCTAssertLessThan(plate.minX, 0, "\(tile)") }
            if frame.maxX > size.width - 60 { XCTAssertGreaterThan(plate.maxX, size.width, "\(tile)") }
            if frame.maxY > size.height - 60 { XCTAssertGreaterThan(plate.maxY, size.height, "\(tile)") }
        }
    }

    func testTheSplashHoldsUntilTheAppIsReadyThenHandsOverAndFinishesOnce() {
        var clock = SplashClock(time: 0)
        for _ in 0..<200 { XCTAssertNil(LaunchOverlay.advance(&clock, by: 600_000, ready: false)) }
        XCTAssertEqual(clock.time, 200 * LaunchOverlay.longestStep, accuracy: 1e-6, "a late frame counts for 50 ms")
        XCTAssertNil(clock.leaving, "the splash holds until the app is ready")

        clock = SplashClock(time: 0)
        var events: [LaunchOverlay.Event] = [], handedOverAt = 0.0
        for _ in 0..<400 {
            guard let event = LaunchOverlay.advance(&clock, by: 1000.0 / 60, ready: true) else { continue }
            events.append(event)
            if event == .handOver {
                handedOverAt = clock.time
                XCTAssertEqual(clock.leaving, 0)
            }
            if event == .finished { break }
        }
        XCTAssertEqual(events, [.handOver, .finished])
        XCTAssertEqual(handedOverAt, BentoSplash.handOver, accuracy: 1000.0 / 60)
        XCTAssertEqual(clock.exit, BentoSplash.leaveDuration, accuracy: 1000.0 / 60)
    }

    func testEveryTileHasLeftBeforeTheSplashIsOver() {
        XCTAssertLessThan(BentoSplash.rest, BentoSplash.handOver)
        XCTAssertGreaterThanOrEqual(BentoSplash.still, BentoSplash.rest)
        for tile in BentoTile.allCases {
            XCTAssertLessThanOrEqual(tile.entrance.delay + tile.entrance.duration, BentoSplash.rest, "\(tile)")
            XCTAssertLessThanOrEqual(tile.departure.delay + tile.departure.duration, BentoSplash.leaveDuration, "\(tile)")
        }
    }

    func testCurvesHoldTheirEndsAndSpringsPassThem() {
        let spring = SplashCurve.spring(damping: 0.58, settle: 6.4)
        for curve in [SplashCurve.linear, .glide, .bounce, .easeInOut, spring] {
            XCTAssertEqual(curve.value(-1), 0, accuracy: 1e-6)
            XCTAssertEqual(curve.value(0), 0, accuracy: 1e-6)
            XCTAssertEqual(curve.value(1), 1, accuracy: 1e-6)
            XCTAssertEqual(curve.value(2), 1, accuracy: 1e-6)
        }
        XCTAssertGreaterThan(spring.value(0.375), 1.05)
        XCTAssertGreaterThan(SplashCurve.bounce.value(0.6), 1.05)
        XCTAssertLessThan(SplashCurve.bezier(0.55, -0.25, 0.75, 0.1).value(0.25), 0)
    }

    func testBeatsWaitPlayAndRepeat() {
        let beat = SplashBeat(delay: 100, duration: 200, curve: .linear)
        XCTAssertEqual(beat.progress(0), 0)
        XCTAssertEqual(beat.progress(200), 0.5, accuracy: 1e-9)
        XCTAssertEqual(beat.progress(400), 1)
        XCTAssertEqual(beat.progress(SplashClock(time: 400).exit), 0, "nothing leaves before the hand-over")
        XCTAssertEqual(beat.cycle(50), 0)
        XCTAssertEqual(beat.cycle(350), 0.25, accuracy: 1e-9)
        XCTAssertEqual(beat.cycle(350, alternating: true), 0.75, accuracy: 1e-9)

        let blink = SplashTrack(delay: 1000, duration: 1000, stops: [.init(at: 0, value: 0), .init(at: 0.1, value: 1), .init(at: 0.2, value: 0), .init(at: 1, value: 0)])
        XCTAssertEqual(blink.value(500), 0)
        XCTAssertEqual(blink.value(1050), 0.5, accuracy: 1e-9)
        XCTAssertEqual(blink.value(1100), 1, accuracy: 1e-9)
        XCTAssertEqual(blink.value(2500), 0)
        XCTAssertEqual(blink.value(3050, repeating: true), 0.5, accuracy: 1e-9)
    }

    func testPathDataIsReadAsItIsDrawn() {
        func assertBounds(_ data: String, _ expected: CGRect, line: UInt = #line) {
            let bounds = Path(svg: data).boundingRect
            for (found, wanted) in [(bounds.minX, expected.minX), (bounds.minY, expected.minY), (bounds.width, expected.width), (bounds.height, expected.height)] {
                XCTAssertEqual(found, wanted, accuracy: 0.01, data, line: line)
            }
        }
        assertBounds("M10,10 h20 v-5 H5 V12 z m1,1 l2,2", CGRect(x: 5, y: 5, width: 25, height: 8))
        assertBounds("M0,0 C0,10 10,10 10,0", CGRect(x: 0, y: 0, width: 10, height: 7.5))
        assertBounds("M4,207 q4.5,-9 9,0 t9,0 t9,0", CGRect(x: 4, y: 202.5, width: 27, height: 9))
        assertBounds("M58,148.5 A13.5,13.5 0 0 0 58,175.5 A6,13.5 0 0 0 58,148.5 Z", CGRect(x: 44.5, y: 148.5, width: 19.5, height: 27))
        assertBounds("M80,245 a5,5 0 0 1 5,-5 h108 a5,5 0 0 1 5,5 v14 h-118 z", CGRect(x: 80, y: 240, width: 118, height: 19))
        assertBounds("M10,10 L", CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testTheHandPrintsEveryCapitalAndTheMarksTheyCarry() {
        for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            XCTAssertTrue(BentoNoteTile.canPrint(String(letter)), "\(letter)")
        }
        for word in ["écrire", "ÀÈÊËÎÔÛ", "ÑANDÚ", "ÜBER", "GARÇON", "Straße", "S'EXERCER", "S\u{2019}EXERCER", "RENDEZ-VOUS", "TO DO", " lernen "] {
            XCTAssertTrue(BentoNoteTile.canPrint(word), word)
        }
        for word in ["", "  ", "日本", "ØL", "NO. 1"] {
            XCTAssertFalse(BentoNoteTile.canPrint(word), word)
        }
        let english = BentoNoteTile.printed(["WRITE", "SKETCH", "STUDY"])
        let fallen = BentoNoteTile.printed(["日本", "sketch", "ØL"])
        XCTAssertEqual(fallen.map(\.bounds), english.map(\.bounds), "a word the hand cannot print gives way to its row's English one")
    }

    /// The checklist's three words in every language the app is built in, read from the catalog.
    private func checklists() throws -> [[String]] {
        let keys: [String.LocalizationValue] = ["WRITE", "SKETCH", "STUDY"]
        return try Bundle.main.localizations.sorted().map { code in
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)), code)
            return keys.map { String(localized: $0, bundle: bundle, locale: Locale(identifier: code)) }
        }
    }

    func testTheChecklistFitsBeforeTheStarInEveryLanguage() throws {
        let languages = try checklists()
        XCTAssertGreaterThanOrEqual(languages.count, 4)
        XCTAssertTrue(languages.contains(["SCHREIBEN", "ZEICHNEN", "LERNEN"]), "the catalog's German is what is checked")
        for words in languages {
            for word in words { XCTAssertTrue(BentoNoteTile.canPrint(word), "the hand cannot print \(word)") }
            let rows = BentoNoteTile.printed(words)
            XCTAssertEqual(rows.count, 3, "\(words)")
            XCTAssertEqual(Set(rows.map(\.scale)).count, 1, "one size on every row: \(words)")
            for (row, word) in rows.enumerated() {
                XCTAssertGreaterThan(word.scale, 0.75, "\(words[row]) is too small to read")
                XCTAssertLessThan(word.bounds.maxX + word.penWidth / 2, 170, "\(words[row]) reaches the star")
                XCTAssertGreaterThan(word.bounds.minY - word.penWidth / 2, 36 * CGFloat(row), "\(words[row]) reaches the rule above")
            }
        }
        XCTAssertEqual(BentoNoteTile.printed(["WRITE", "SKETCH", "STUDY"]).first?.scale, 1, "English is printed at full size")
        XCTAssertEqual(BentoNoteTile.checklist.count, 3)
    }

    func testTheTickerAndTheStampCanSetEveryTranslatedWord() throws {
        let font = OwlLunaFonts.splashTitle(size: 1000, width: 95)
        for word in try checklists().joined() {
            XCTAssertTrue(SplashType(word, font: font).isWhole, "Archivo lacks a letter of \(word)")
        }
        XCTAssertTrue(SplashType("TO DO", font: font).isWhole)
        XCTAssertTrue(SplashType("E\u{301}CRIRE", font: font).isWhole, "a letter and its mark are set as one")
        XCTAssertFalse(SplashType("УЧИТЬ", font: font).isWhole)
        XCTAssertFalse(SplashType("", font: font).isWhole)
        XCTAssertEqual(SplashType("УЧИТЬ", fallback: "STUDY", font: font).width, SplashType("STUDY", font: font).width, "a word Archivo cannot set gives way to English")
    }

    func testTheWordmarkIsSetInArchivoAtItsNarrowest() {
        let narrow = SplashType("OWLLUNA", font: OwlLunaFonts.splashTitle(size: 1000, width: 62))
        let wide = SplashType("OWLLUNA", font: OwlLunaFonts.splashTitle(size: 1000, width: 125))
        XCTAssertEqual(CTFontCopyFamilyName(OwlLunaFonts.splashTitle(size: 20, width: 62)) as String, "Archivo")
        XCTAssertEqual(narrow.letters.count, 7)
        XCTAssertFalse(narrow.letters.contains { $0.outline.isEmpty })
        XCTAssertEqual(narrow.capHeight, 0.686, accuracy: 0.01)
        XCTAssertGreaterThan(wide.width, narrow.width * 1.5)
    }
}
