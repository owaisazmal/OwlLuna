import XCTest
import PencilKit
@testable import OwlLuna

/// The part of its page a tape card shows: where it starts, and how it is cut again when the area is changed.
@MainActor
final class CardAreaTests: XCTestCase {
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
    private let letter = CGRect(origin: .zero, size: PageSize.letter.points)

    private func limit(_ tape: PageItem) -> CGRect { CardArea.limit(round: tape, on: paper.newPage()) }

    private func tape(at center: CGPoint, _ size: CGSize = CGSize(width: 80, height: 20)) -> PageItem {
        PageItem(content: .tape(.mustard), center: center, size: size)
    }

    private func fixed(_ tape: PageItem) -> CGRect {
        let box = tape.boundingBox, reach = max((420 - box.width) / 2, 90)
        return box.insetBy(dx: -reach, dy: -64)
    }

    /// Lines of print 13 points tall, one every `pitch`, from `top` down.
    private func lines(_ count: Int, top: CGFloat, pitch: CGFloat = 14, from left: CGFloat = 72, to right: CGFloat = 540) -> [CardArea.Mark] {
        (0..<count).map { .line(CGRect(x: left, y: top + CGFloat($0) * pitch, width: right - left, height: 13)) }
    }

    // MARK: Where the area starts

    func testWithNothingWrittenRoundTheTapeTheAreaIsTheFixedOne() {
        let tape = tape(at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(CardArea.region(around: tape, fixed: fixed(tape), marks: [], held: [], limit: limit(tape)), fixed(tape))
        let far = lines(3, top: 600)
        XCTAssertEqual(CardArea.region(around: tape, fixed: fixed(tape), marks: far, held: [], limit: limit(tape)), fixed(tape), "writing elsewhere on the page changes nothing")
    }

    func testTheAreaGrowsToTheWholeLineAndTheLinesThatRunOnFromIt() {
        // A question of nine lines with the tape on its last, a short one; another question a blank line above and below.
        let tape = tape(at: CGPoint(x: 300, y: 318), CGSize(width: 40, height: 18))
        let question = lines(8, top: 200) + [.line(CGRect(x: 72, y: 312, width: 250, height: 13))]
        let before = lines(2, top: 158), after = lines(3, top: 353)
        let fixed = fixed(tape)
        let region = CardArea.region(around: tape, fixed: fixed, marks: before + question + after, held: [], limit: limit(tape))

        XCTAssertTrue(region.contains(fixed), "never smaller than the fixed area")
        XCTAssertEqual(region.minX, 72 - CardArea.margin.width, "out to where the lines start")
        XCTAssertEqual(region.maxX, 540 + CardArea.margin.width, "and to where they end")
        XCTAssertEqual(region.minY, 200 - CardArea.margin.height, "up to the question's first line")
        XCTAssertFalse(fixed.contains(question[0].rect), "which the fixed area cut off")
        XCTAssertEqual(region.maxY, fixed.maxY, "the question below is across a blank line, so nothing is added for it")
        XCTAssertGreaterThan(region.minY, before[1].rect.maxY, "nor for the one above")

        let shuffled = CardArea.region(around: tape, fixed: fixed, marks: (before + question + after).reversed(), held: [], limit: limit(tape))
        XCTAssertEqual(shuffled, region, "whatever order the page gives its lines in")
    }

    func testLinesThatRunOnWithoutAGapAreTakenOnlySoFarAndNeverCutThrough() {
        let tape = tape(at: CGPoint(x: 300, y: 400))
        let text = lines(40, top: 120)
        let region = CardArea.region(around: tape, fixed: fixed(tape), marks: text, held: [], limit: limit(tape))
        let limit = limit(tape)
        XCTAssertEqual(limit, CGRect(x: 0, y: 390 - CardArea.reach.height, width: letter.width, height: 20 + 2 * CardArea.reach.height))
        let first = text.first { $0.rect.minY >= limit.minY }!.rect, last = text.last { $0.rect.maxY <= limit.maxY }!.rect
        XCTAssertEqual(region.minY, first.minY - CardArea.margin.height, "the top edge is above a whole line")
        XCTAssertEqual(region.maxY, last.maxY + CardArea.margin.height, "and the bottom edge below one")
        XCTAssertLessThanOrEqual(region.height, tape.size.height + 2 * (CardArea.reach.height + CardArea.margin.height))

        let board = NotebookPage.board(template: .dotted, color: .white)
        let far = self.tape(at: Whiteboard.center)
        let wide = [CardArea.Mark.line(CGRect(x: 0, y: Whiteboard.center.y - 6, width: Whiteboard.side, height: 13))]
        let across = CardArea.region(around: far, fixed: fixed(far), marks: wide, held: [], limit: CardArea.limit(round: far, on: board))
        XCTAssertEqual(across.width, far.size.width + 2 * (CardArea.reach.width + CardArea.margin.width), "a line with no page to end at, on a whiteboard, is taken only so far")
    }

    func testHandwritingIsTakenByItsLineAndABracketOrAMarginNoteIsLeftOut() {
        // Three lines written close together, a line skipped above and below them, with the tape on a word of the middle one.
        func written(_ text: String, _ y: CGFloat) -> [PKStroke] { BlockLetters.strokes(text, origin: CGPoint(x: 40, y: y), height: 16) }
        let block = written("THE MANTLE HAVE THE ATOM THAT MELT", 228) + written("IT TAKE THE HEAT ONTO THE WHOLE", 256) + written("WHEN IT MELT THE LAVA FLOW", 284)
        let others = written("WHAT MAKE THE HEAT IN THE MANTLE", 172) + written("NEXT", 340)
        let note = stroke(from: CGPoint(x: 590, y: 262), to: CGPoint(x: 604, y: 262), width: 3)
        var page = paper.newPage()
        let tape = tape(at: CGPoint(x: 290, y: 264), CGSize(width: 70, height: 24))
        page.items = [tape]
        let bracket = stroke(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 30, y: 700), width: 3)
        let ink = PKDrawing(strokes: others + block + [note, bracket])
        let fixed = CardClipping.region(around: tape, on: page)
        let region = CardClipping.startingRegion(around: tape, on: page, ink: ink, assets: FileManager.default.temporaryDirectory)

        let hand = PKDrawing(strokes: block).bounds
        XCTAssertTrue(region.contains(fixed))
        XCTAssertTrue(region.contains(hand), "the three lines, each from its first letter to its last")
        XCTAssertFalse(fixed.contains(hand))
        XCTAssertEqual(region.minX, (hand.minX - CardArea.margin.width).rounded(.down), accuracy: 1)
        XCTAssertEqual(region.maxX, (hand.maxX + CardArea.margin.width).rounded(.up), accuracy: 1, "not out to the note in the margin")
        XCTAssertEqual(region.minY, fixed.minY, "the line above is a skipped line away")
        XCTAssertEqual(region.maxY, fixed.maxY)
        XCTAssertEqual([fixed.size, region.size], [CGSize(width: 420, height: 152), CGSize(width: 535, height: 152)])
    }

    func testATextBoxUnderTheTapeIsTakenWhole() {
        var box = TextBox(string: StudySeed.notes)
        box.fontSize = 17
        let typed = PageItem(content: .text(box), center: CGPoint(x: 280, y: 220), size: CGSize(width: 400, height: box.height(width: 400)))
        let tape = tape(at: CGPoint(x: 240, y: 178), CGSize(width: 120, height: 24))
        let sticker = PageItem(content: .sticker("star"), center: CGPoint(x: 520, y: 178), size: CGSize(width: 40, height: 40))
        var page = paper.newPage()
        page.items = [typed, sticker, tape]
        let fixed = CardClipping.region(around: tape, on: page)
        let region = CardClipping.startingRegion(around: tape, on: page, ink: PKDrawing(), assets: FileManager.default.temporaryDirectory)
        XCTAssertFalse(fixed.contains(typed.boundingBox), "the fixed area cut the lines off at the right")
        XCTAssertTrue(region.contains(typed.boundingBox))
        XCTAssertTrue(region.contains(fixed))
        XCTAssertFalse(region.intersects(sticker.boundingBox), "what the tape doesn't lie on is left where it is")
    }

    func testAPrintedQuestionOfSeveralLinesFitsOnItsCard() async throws {
        let root = temporaryRoot(self), id = UUID()
        let package = NotebookPackage(root: root, id: id)
        let font = UIFont.systemFont(ofSize: 11), left: CGFloat = 72, pitch: CGFloat = 14
        let question = ["12. Welche der folgenden Aussagen über die Mitochondrien trifft zu? Beachten Sie, dass nur",
                        "eine Antwort richtig ist und dass für falsche Antworten keine Punkte abgezogen werden.",
                        "A) Sie speichern die Erbinformation der Zelle.", "B) Sie stellen ATP her, die Energie der Zelle.",
                        "C) Sie bauen Proteine aus Aminosäuren auf.", "D) Sie wandeln Licht in Zucker um.", "Antwort: B"]
        let pdf = UIGraphicsPDFRenderer(bounds: letter).pdfData { context in
            context.beginPage()
            func set(_ lines: [String], top: CGFloat) {
                for (index, line) in lines.enumerated() { (line as NSString).draw(at: CGPoint(x: left, y: top + CGFloat(index) * pitch), withAttributes: [.font: font]) }
            }
            set(["11. Wie heißt die Hauptstadt von Frankreich?", "Antwort: Paris"], top: 160)
            set(question, top: 216)
            set(["13. Was bauen die Ribosomen?", "Antwort: Proteine"], top: 216 + 8 * pitch)
        }
        let file = try await package.writeAsset(pdf, ext: "pdf")
        var page = NotebookPage(background: .pdf(file: file, index: 0), paperColor: .white, size: PageSize.letter.points)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let answer = CGPoint(x: left + width("Antwort: ") + width("B") / 2, y: 216 + 6 * pitch + font.lineHeight / 2)
        let tape = tape(at: answer, CGSize(width: 40, height: 18))
        page.items = [tape]
        try await package.create(NotebookManifest(id: id, title: "Biologie", defaults: paper, pages: [page]))
        let assets = package.assetsDirectory

        let whole = CGRect(x: left, y: 216, width: question.map(width).max()!, height: 6 * pitch + font.lineHeight)
        let fixed = CardClipping.region(around: tape, on: page)
        XCTAssertFalse(fixed.contains(whole), "the fixed area cuts the question off: its first lines, and the long ones at the right")
        let region = CardClipping.startingRegion(around: tape, on: page, ink: PKDrawing(), assets: assets)
        XCTAssertTrue(region.contains(whole), "\(region) holds the whole question, \(whole)")
        XCTAssertTrue(region.contains(fixed))
        XCTAssertLessThan(region.height, 180, "and not the questions before and after it")
        XCTAssertEqual(CardClipping.startingRegion(around: tape, on: page, ink: PKDrawing(), assets: assets), region, "the same every time")
        XCTAssertEqual([fixed.size, region.size], [CGSize(width: 334, height: 147), CGSize(width: 567, height: 174)])

        let document = try await NotebookDocument.open(id, root: root)
        let library = FlashcardLibrary(root: root)
        await library.load()
        let made = try await EditorSession(document: document).makeCard(from: tape, on: document.pages[0], in: library)
        XCTAssertEqual(made.clip, CardClip(region: region, tape: tape), "a card says what it was cut from")
        XCTAssertTrue(try XCTUnwrap(made.front.imageText).contains("Welche der folgenden Aussagen"), "and its question is read from its first line")
    }

    // MARK: Cutting a card again

    private func tapedPage() -> (page: NotebookPage, tape: PageItem, ink: PKDrawing) {
        var page = paper.newPage()
        let tape = PageItem(content: .tape(.sage), center: CGPoint(x: 300, y: 200), size: CGSize(width: 240, height: 40))
        page.items = [tape]
        return (page, tape, PKDrawing(strokes: [stroke(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 400, y: 200), width: 8)]))
    }

    func testACardCutAgainShowsItsNewAreaOnBothSides() async throws {
        let (page, tape, ink) = tapedPage()
        let assets = FileManager.default.temporaryDirectory
        let cut = await CardClipping.cut(tape, on: page, ink: ink, assets: assets, region: CGRect(x: 100.4, y: 120.2, width: 400.2, height: 220.5))
        let clip = try XCTUnwrap(cut.clip)
        XCTAssertEqual(clip.region, CGRect(x: 100, y: 120, width: 401, height: 221), "in whole points")
        XCTAssertEqual(cut.front.size, clip.region.size)
        XCTAssertEqual(cut.back.size, clip.region.size)
        XCTAssertEqual(cut.front.scale, CardClipping.scale)
        XCTAssertEqual([clip.tapeCenter.x, clip.tapeCenter.y, clip.tapeSize.width, clip.tapeSize.height, clip.tapeRotation], [300, 200, 240, 40, 0])
        XCTAssertEqual(clip.color, .sage)
        XCTAssertEqual(clip.tapeCenterInClipping, CGPoint(x: 200, y: 80))
        let onTape = CGPoint(x: (250 - clip.region.minX) * CardClipping.scale, y: (200 - clip.region.minY) * CardClipping.scale)
        XCTAssertGreaterThan(try pixel(cut.front, at: onTape).r, 120, "the question has the tape on")
        XCTAssertLessThan(try pixel(cut.back, at: onTape).r, 110, "the answer shows the ink under it")

        let past = await CardClipping.cut(tape, on: page, ink: ink, assets: assets, region: CGRect(x: -80, y: 150, width: 5000, height: 100))
        XCTAssertEqual(past.clip?.region, CGRect(x: 0, y: 150, width: page.size.width, height: 100), "never more than the page has")
        XCTAssertEqual(past.front.size, CGSize(width: page.size.width, height: 100))
    }

    func testAChangedAreaIsKeptWithTheCardOnceItIsSaved() async throws {
        let root = temporaryRoot(self)
        let (page, tape, ink) = tapedPage()
        let manifest = NotebookManifest(title: "Biology", defaults: paper, pages: [page])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        _ = try await NotebookPackage(root: root, id: manifest.id).write(SaveSnapshot(manifest: manifest, ink: [page.id: ink]))
        let document = try await NotebookDocument.open(manifest.id, root: root)
        let library = FlashcardLibrary(root: root)
        await library.load()
        let made = try await EditorSession(document: document).makeCard(from: tape, on: document.pages[0], in: library)
        let start = CardClipping.region(around: tape, on: page)
        XCTAssertEqual(made.clip, CardClip(region: start, tape: tape))

        var draft = CardDraft(editing: made)
        XCTAssertEqual(draft.clip, made.clip)
        let cut = await CardClipping.cut(tape, on: page, ink: ink, assets: document.package.assetsDirectory, region: start.insetBy(dx: 60, dy: 20))
        draft.recut(cut)
        XCTAssertEqual(draft.front.newImage?.size, start.insetBy(dx: 60, dy: 20).size)
        XCTAssertNil(draft.front.imageName)
        XCTAssertEqual(library.cards(in: manifest.id), [made], "nothing is kept until the card is saved")

        let saved = try await library.save(draft, in: manifest.id)
        XCTAssertEqual(saved.clip?.region, start.insetBy(dx: 60, dy: 20))
        XCTAssertEqual([saved.id, saved.tapeID], [made.id, tape.id])
        XCTAssertEqual(saved.due, made.due)
        XCTAssertNotEqual(saved.front.image, made.front.image)
        let kept = await library.image(saved.back.image, in: manifest.id)
        XCTAssertEqual((kept?.size.width ?? 0) * (kept?.scale ?? 0), (start.width - 120) * CardClipping.scale, "the clipping in the notebook is the new one")
        await library.flush()
        let reread = FlashcardLibrary(root: root)
        await reread.load()
        XCTAssertEqual(reread.cards(in: manifest.id).first?.clip, saved.clip, "and is read back with it")

        var turned = CardDraft(editing: saved)
        turned.swapSides()
        turned.back.newImage = nil
        turned.back.imageName = nil
        turned.back.text = "Typed instead"
        let again = await CardClipping.cut(tape, on: page, ink: ink, assets: document.package.assetsDirectory, region: start)
        turned.recut(again)
        XCTAssertEqual(turned.front.newImage?.pngData(), again.back.pngData(), "a side takes its own clipping wherever it has been swapped to")
        XCTAssertNil(turned.back.newImage, "and one whose clipping was removed stays without")
        turned.front.newImage = nil
        let bare = try await library.save(turned, in: manifest.id)
        XCTAssertNil(bare.clip, "a card with no clipping left has nothing to say about one")
    }

    func testACardWithNoAreaOfItsOwnStartsAtTheFixedOne() {
        let (page, tape, _) = tapedPage()
        let fixed = CardClipping.region(around: tape, on: page)
        XCTAssertEqual(CardClipping.region(of: nil, tape: tape, on: page), fixed, "a card made before areas were kept")
        let chosen = CGRect(x: 40, y: 100, width: 500, height: 300)
        XCTAssertEqual(CardClipping.region(of: CardClip(region: chosen, tape: tape), tape: tape, on: page), chosen)
        var moved = tape
        moved.center = CGPoint(x: 300, y: 600)
        XCTAssertEqual(CardClipping.region(of: CardClip(region: chosen, tape: tape), tape: moved, on: page), CardClipping.region(around: moved, on: page),
                       "tape moved out of the area takes the area with it")
    }

    func testTheFrameMeasuresTheAreaAsAPartOfWhatIsShown() {
        let window = CGRect(x: 1000, y: 2000, width: 800, height: 400)
        let area = CGRect(x: 1200, y: 2100, width: 400, height: 100)
        XCTAssertEqual(CardArea.unit(area, in: window), CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25))
        XCTAssertEqual(CardArea.region(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25), of: window), area)
        XCTAssertEqual(CardArea.region(PageItem.wholePicture, of: window), window)

        let letter = paper.newPage()
        XCTAssertEqual(CardArea.window(showing: area, on: letter), CGRect(origin: .zero, size: letter.size), "an ordinary page is shown whole")
        var board = NotebookPage.board(template: .dotted, color: .white)
        let tape = tape(at: CGPoint(x: 20_000, y: 20_000), CGSize(width: 160, height: 22))
        board.items = [tape]
        let start = CardClipping.region(around: tape, on: board)
        let shown = CardArea.window(showing: start, on: board)
        XCTAssertEqual(shown, start.insetBy(dx: -300, dy: -300), "a whiteboard is far too large: the area and some room round it")
        let picture = CardClipping.picture(of: board, ink: PKDrawing(), assets: FileManager.default.temporaryDirectory, window: shown)
        XCTAssertEqual(picture.size, shown.size)
        let corner = CardArea.window(showing: CGRect(x: 0, y: 0, width: 420, height: 150), on: board)
        XCTAssertEqual(corner, CGRect(x: 0, y: 0, width: 720, height: 450), "never past the board's edge")
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> (r: Int, g: Int, b: Int) {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: -point.x, y: point.y - CGFloat(cgImage.height) + 1, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}
