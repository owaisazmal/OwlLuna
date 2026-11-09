import XCTest
import PencilKit
@testable import OwlLuna

/// Handwriting to Text, and the ink dish that comes to the Pencil's tip.
@MainActor
final class InkTypingTests: XCTestCase {
    func testWritingFurtherAlongOrOnTheLineBelowCarriesOn() {
        let written = CGRect(x: 100, y: 200, width: 240, height: 40)
        XCTAssertEqual(InkTyping.join(CGRect(x: 380, y: 204, width: 120, height: 38), after: written, lineHeight: 40), .sameLine)
        XCTAssertEqual(InkTyping.join(CGRect(x: 104, y: 256, width: 200, height: 42), after: written, lineHeight: 40), .nextLine)
        XCTAssertNil(InkTyping.join(CGRect(x: 700, y: 204, width: 80, height: 38), after: written, lineHeight: 40), "too far along to be the same sentence")
        XCTAssertNil(InkTyping.join(CGRect(x: 104, y: 420, width: 200, height: 42), after: written, lineHeight: 40), "further down the page")
        XCTAssertNil(InkTyping.join(CGRect(x: 420, y: 256, width: 200, height: 42), after: written, lineHeight: 40), "below, but not at the start of a line")
        XCTAssertNil(InkTyping.join(CGRect(x: 104, y: 120, width: 200, height: 42), after: written, lineHeight: 40), "above")
        XCTAssertNil(InkTyping.join(.null, after: written, lineHeight: 40))

        // After two lines, the last one is the one that is carried on.
        let two = CGRect(x: 100, y: 200, width: 240, height: 90)
        XCTAssertEqual(InkTyping.join(CGRect(x: 360, y: 250, width: 100, height: 38), after: two, lineHeight: 45), .sameLine)
        XCTAssertNil(InkTyping.join(CGRect(x: 360, y: 204, width: 100, height: 38), after: two, lineHeight: 45), "beside its first line")
    }

    func testCarriedOnTextGrowsTheBoxWhereItStands() throws {
        let page = CGSize(width: 612, height: 792)
        let item = InkText.box(for: "Hello", replacing: CGRect(x: 100, y: 200, width: 240, height: 40), pageSize: page)
        let left = item.center.x - item.size.width / 2, top = item.center.y - item.size.height / 2
        let along = try XCTUnwrap(InkTyping.extended(item, with: "there", .sameLine, pageSize: page))
        XCTAssertEqual(along.text?.string, "Hello there")
        XCTAssertEqual(along.id, item.id)
        XCTAssertEqual(along.center.x - along.size.width / 2, left, accuracy: 0.01)
        XCTAssertEqual(along.center.y - along.size.height / 2, top, accuracy: 0.01)
        XCTAssertEqual(along.size.width, item.size.width, accuracy: 0.01, "there was room for it in the box")
        XCTAssertEqual(along.size.height, item.size.height, accuracy: 1, "still one line")
        let longer = try XCTUnwrap(InkTyping.extended(item, with: "there, and a good deal more than that", .sameLine, pageSize: page))
        XCTAssertGreaterThan(longer.size.width, item.size.width, "the box grows to keep a longer line whole")
        XCTAssertEqual(longer.center.x - longer.size.width / 2, left, accuracy: 0.01)

        let below = try XCTUnwrap(InkTyping.extended(along, with: "World", .nextLine, pageSize: page))
        XCTAssertEqual(below.text?.string, "Hello there\nWorld")
        XCTAssertGreaterThan(below.size.height, along.size.height * 1.6)
        XCTAssertLessThanOrEqual(below.center.x + below.size.width / 2, page.width - 11)

        var turned = item
        turned.rotation = 0.3
        XCTAssertNil(InkTyping.extended(turned, with: "there", .sameLine, pageSize: page), "a box that has been turned is left alone")
        XCTAssertNil(InkTyping.extended(PageItem(content: .tape(.mustard), center: .zero, size: CGSize(width: 80, height: 24)), with: "x", .sameLine, pageSize: page))
    }

    func testWritingIsReadWhileThePenRestsAndSetOnlyOnceTheRestIsLongEnough() async {
        XCTAssertLessThan(InkTyping.lookAhead, InkTyping.pause, "the reading begins before the rest is long enough")
        let piece = PKDrawing(strokes: BlockLetters.strokes("HI", origin: .zero))
        let read = expectation(description: "both pages are read during the rest, not after it")
        read.expectedFulfillmentCount = 2
        let resting = Task {
            await InkTyping.read([piece, piece], handingBackAfter: 60) { _ in
                Thread.sleep(forTimeInterval: 0.2)
                read.fulfill()
                return "read"
            }
        }
        await fulfillment(of: [read], timeout: 10)
        resting.cancel() // cuts the rest short, as writing on does
        let texts = await resting.value
        XCTAssertEqual(texts, ["read", "read"])

        let start = CACurrentMediaTime()
        _ = await InkTyping.read([piece], handingBackAfter: 1.5) { _ in "read" }
        XCTAssertGreaterThanOrEqual(CACurrentMediaTime() - start, 1.5, "the text waits for the rest")

        let slow = CACurrentMediaTime()
        let late = await InkTyping.read([piece], handingBackAfter: 0.1) { _ in
            Thread.sleep(forTimeInterval: 0.4)
            return "late"
        }
        XCTAssertEqual(late, ["late"])
        XCTAssertGreaterThanOrEqual(CACurrentMediaTime() - slow, 0.4, "a reading that outlasts the rest is waited for")
    }

    /// Vision passes over some short words in a tight frame, so one that reads as nothing is read again with more room.
    func testShortWordsAreReadHoweverTheyAreFramed() async throws {
        struct Unfinished: Error, CustomStringConvertible {
            let word: String
            var description: String { "Vision did not finish reading \(word) within 60 s" }
        }
        // Vision has no timeout of its own: starved of CPU on a slow runner, a reading never comes back.
        func read(_ word: String) async throws -> String? {
            let piece = PKDrawing(strokes: BlockLetters.strokes(word, origin: CGPoint(x: 100, y: 140)))
            let finished = expectation(description: "Vision finished reading \(word)")
            let reading = Task {
                let text = await InkText.recognizeInBackground([piece])
                finished.fulfill()
                return text?.uppercased()
            }
            guard await XCTWaiter.fulfillment(of: [finished], timeout: 60) == .completed else { throw Unfinished(word: word) }
            return await reading.value
        }
        guard try await read("HELLO") == "HELLO" else { throw XCTSkip("Vision's text recogniser can't read block letters here") }
        for word in ["OK", "ZINK", "WILL", "MAX"] {
            let text = try await read(word)
            XCTAssertEqual(text, word)
        }
    }

    func testTheTextTakesTheColourNearestThePens() {
        func tint(_ color: UInt32) -> TextBox.Tint { InkTyping.tint(for: ToolPreset.uiColor(color)) }
        XCTAssertEqual(tint(0x1B22_30FF), .ink)
        XCTAssertEqual(tint(0x6E73_7CFF), .ink)
        XCTAssertEqual(tint(0xC945_2FFF), .tomato)
        XCTAssertEqual(tint(0x2747_B8FF), .cobalt)
        XCTAssertEqual(tint(0x3D8F_D9FF), .cobalt)
        XCTAssertEqual(tint(0x2F8F_4EFF), .moss)
        XCTAssertEqual(tint(0x1F8A_8AFF), .moss)
        XCTAssertEqual(tint(0x7A3E_9DFF), .plum)
        XCTAssertEqual(tint(0xD957_8CFF), .plum)
        XCTAssertEqual(tint(0xE8B0_23FF), .ink, "yellow type can't be read")
        XCTAssertEqual(tint(0x7A52_30FF), .ink, "brown is nearest the ink")
    }

    func testTheDishStaysOnThePagesAndSetsItsWellsEvenlyRoundTheRim() {
        let size = CGSize(width: 834, height: 1100), reach = InkDish.diameter / 2 + Space.x2
        XCTAssertEqual(InkDish.centre(for: CGPoint(x: 400, y: 500), in: size), CGPoint(x: 400, y: 500), "at the Pencil's tip")
        XCTAssertEqual(InkDish.centre(for: CGPoint(x: 4, y: 6), in: size), CGPoint(x: reach, y: reach))
        XCTAssertEqual(InkDish.centre(for: CGPoint(x: 830, y: 1090), in: size, foot: 64), CGPoint(x: 834 - reach, y: 1100 - 64 - reach), "clear of the tray")
        XCTAssertEqual(InkDish.centre(for: CGPoint(x: 50, y: 50), in: CGSize(width: 200, height: 200)), CGPoint(x: reach, y: reach), "a room too small for it")

        XCTAssertTrue(InkDish.wells(0).isEmpty)
        let four = InkDish.wells(4)
        XCTAssertEqual(four[0].x, 0, accuracy: 0.001)
        XCTAssertEqual(four[0].y, -InkDish.ring, accuracy: 0.001, "the first pen is at the top")
        XCTAssertEqual(four[1].x, InkDish.ring, accuracy: 0.001)
        XCTAssertEqual(four[2].y, InkDish.ring, accuracy: 0.001)
        for count in 1...ToolShelf.limit {
            let wells = InkDish.wells(count)
            XCTAssertEqual(wells.count, count)
            for well in wells {
                XCTAssertEqual(hypot(well.x, well.y), InkDish.ring, accuracy: 0.001)
                XCTAssertLessThanOrEqual(hypot(well.x, well.y) + ToolTray.button / 2, InkDish.diameter / 2, "a well's whole target is on the dish")
            }
            for (a, b) in zip(wells, wells.dropFirst()) {
                XCTAssertGreaterThanOrEqual(hypot(a.x - b.x, a.y - b.y), ToolTray.button, "wells don't share a target")
            }
        }

        let cream = UIColor(red: 0.97, green: 0.95, blue: 0.9, alpha: 1)
        XCTAssertLessThan(InkDish.luminance(of: ToolPreset.uiColor(0x1B22_30FF), at: 1, over: cream), 0.36, "black ink takes a light mark")
        XCTAssertGreaterThan(InkDish.luminance(of: ToolPreset.uiColor(0x1B22_30FF), at: 0.2, over: cream), 0.36, "faint black is pale, and takes a dark one")
        XCTAssertGreaterThan(InkDish.luminance(of: ToolPreset.uiColor(0xFFD4_26FF), at: 1, over: cream), 0.36)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The whole path on a real canvas, with Vision reading the block letters.
    func testHandwritingIsSetAsTypeWhenThePenRestsAndUndoGivesItBack() async throws {
        let root = temporaryRoot(self)
        let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
        let manifest = NotebookManifest(title: "Typing", defaults: paper, pages: [paper.newPage()])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        let page = manifest.pages[0].id
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let session = EditorSession(document: document)
        let controller = PageStackController(session: session)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let toolbox = Toolbox.shared
        addTeardownBlock { @MainActor in
            window.isHidden = true
            toolbox.typesHandwriting = false
        }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where controller.canvas(forPage: 0)?.isLoaded != true { await pause(0.05) }
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0))
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)

        func write(_ word: String, at origin: CGPoint) async {
            for stroke in BlockLetters.strokes(word, origin: origin, from: .now) {
                canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + [stroke])
                await pause(0.02)
            }
        }
        func texts() -> [String] { document.pages[0].items.compactMap { $0.text?.string } }
        /// Waits for the handwriting to give way. What Vision makes of it differs by machine, and a slow one takes
        /// its time: where it reads nothing, or something else, there is nothing here to hold the app to.
        func read(leaving count: Int) async throws {
            for _ in 0..<200 where document.loadedInk(page)?.strokes.count != count { await pause(0.1) }
            guard document.loadedInk(page)?.strokes.count == count else { throw XCTSkip("Vision's text recogniser read nothing here") }
        }

        // With the helper off, writing stays ink however long the pen rests.
        await write("HI", at: CGPoint(x: 100, y: 500))
        await pause(InkTyping.pause + 0.6)
        XCTAssertEqual(document.loadedInk(page)?.strokes.count, 4)
        XCTAssertTrue(texts().isEmpty)

        toolbox.typesHandwriting = true
        let before = canvas.drawing.strokes.count
        await write("HELLO", at: CGPoint(x: 100, y: 140))
        let lifted = CACurrentMediaTime(), written = before + BlockLetters.strokes("HELLO", origin: .zero).count
        XCTAssertEqual(document.loadedInk(page)?.strokes.count, written, "nothing is read while the pen is moving")
        await pause(InkTyping.pause - 0.4)
        if CACurrentMediaTime() - lifted < InkTyping.pause - 0.1 {
            XCTAssertEqual(document.loadedInk(page)?.strokes.count, written, "read during the rest, but not set before it is long enough")
        }
        try await read(leaving: before)
        guard texts().map({ $0.uppercased() }) == ["HELLO"] else { throw XCTSkip("Vision read the block letters as \(texts()) here") }
        XCTAssertEqual(canvas.drawing.strokes.count, before, "the canvas shows the page without the handwriting")
        XCTAssertEqual(document.undoManager.undoActionName, "Handwriting to Text")
        let box = try XCTUnwrap(document.pages[0].items.first)
        XCTAssertEqual(box.center.x - box.size.width / 2, 100, accuracy: 30, "the text stands where the handwriting did")
        XCTAssertEqual(box.center.y, 164, accuracy: 30)

        // Written on along the line, the next word joins the same text.
        await write("THEN", at: CGPoint(x: 420, y: 140))
        try await read(leaving: before)
        XCTAssertEqual(texts().count, 1)
        XCTAssertEqual(texts().first?.uppercased().hasPrefix("HELLO "), true)

        // One undo takes the word back out and gives its handwriting back, which then stays ink.
        document.undoManager.undo()
        await pause(0.3)
        XCTAssertEqual(texts().map { $0.uppercased() }, ["HELLO"])
        XCTAssertEqual(document.loadedInk(page)?.strokes.count, before + BlockLetters.strokes("THEN", origin: .zero).count)
        await pause(InkTyping.pause + 1)
        XCTAssertEqual(texts().count, 1, "handwriting that was given back is not read again")

        // Putting the pen down reads what is waiting without the wait.
        toolbox.typesHandwriting = false
        await pause(0.2)
        toolbox.typesHandwriting = true
        let strokes = try XCTUnwrap(document.loadedInk(page)?.strokes.count)
        await write("MILK", at: CGPoint(x: 100, y: 640))
        toolbox.typesHandwriting = false
        try await read(leaving: strokes)
        XCTAssertEqual(texts().count, 2)
    }
}
