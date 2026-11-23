import XCTest
@testable import OwlLuna

/// Where the tape lies on a tape card's question, from what the card was cut from or from its two pictures.
@MainActor
final class TapeLiftTests: XCTestCase {
    private let clip = CardClip(region: CGRect(x: 100, y: 200, width: 420, height: 152), tapeCenter: CGPoint(x: 310, y: 276),
                                tapeSize: CGSize(width: 120, height: 24), tapeRotation: 0.12, color: .rose)

    private func tapeCard(clip: CardClip? = nil, back: String? = "back.png") -> Flashcard {
        var card = Flashcard(front: CardSide(image: "front.png"), back: CardSide(image: back), pageID: UUID(), tapeID: UUID())
        card.clip = clip
        return card
    }

    /// A clipping 420 by 152 points with lines of ink across it and a strip of tape on, or lifted.
    private func picture(_ tape: LiftStrip, lifted: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat(scale: 2)
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 420, height: 152), format: format).image { context in
            let ctx = context.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 420, height: 152))
            UIColor.black.setFill()
            for y in stride(from: 30, to: 140, by: 24) { ctx.fill(CGRect(x: 20, y: CGFloat(y), width: 380, height: 3)) }
            ctx.translateBy(x: tape.center.x, y: tape.center.y)
            ctx.rotate(by: tape.rotation)
            TapeArt.draw(tape.color, lifted: lifted, in: ctx,
                         rect: CGRect(x: -tape.size.width / 2, y: -tape.size.height / 2, width: tape.size.width, height: tape.size.height))
        }
    }

    func testAStripIsPlacedFromItsClipOnThePictureAsDrawn() throws {
        // Clippings are cut at twice the page's points and read back at a scale of 1.
        let picture = CGSize(width: 840, height: 304)
        let strip = try XCTUnwrap(LiftStrip(clip: clip, picture: picture))
        XCTAssertEqual(strip, LiftStrip(center: CGPoint(x: 420, y: 152), size: CGSize(width: 240, height: 48), rotation: 0.12, color: .rose))

        let drawn = strip.placed(from: picture, in: CGSize(width: 315, height: 114))
        XCTAssertEqual(drawn.center.x, 157.5, accuracy: 0.001)
        XCTAssertEqual(drawn.center.y, 57, accuracy: 0.001)
        XCTAssertEqual(drawn.size.width, 90, accuracy: 0.001)
        XCTAssertEqual(drawn.size.height, 18, accuracy: 0.001)
        XCTAssertEqual(drawn.rotation, 0.12, "turning doesn't change with size")
        XCTAssertEqual(drawn.frame, CGRect(x: 112.5, y: 48, width: 90, height: 18))
    }

    func testAClipThatDoesNotFitThePictureIsNotUsed() {
        XCTAssertNil(LiftStrip(clip: clip, picture: CGSize(width: 840, height: 600)), "the clippings were cut again since")
        var away = clip
        away.tapeCenter = CGPoint(x: 900, y: 276)
        XCTAssertNil(LiftStrip(clip: away, picture: CGSize(width: 840, height: 304)), "the tape is nowhere near the clipping")
        var empty = clip
        empty.region.size = .zero
        XCTAssertNil(LiftStrip(clip: empty, picture: CGSize(width: 840, height: 304)))
        var thin = clip
        thin.tapeSize = CGSize(width: 120, height: 0)
        XCTAssertNil(LiftStrip(clip: thin, picture: CGSize(width: 840, height: 304)))
    }

    func testOnlyCardsMadeFromTapeWithBothPicturesLift() {
        XCTAssertTrue(LiftStrip.lifts(tapeCard()))
        XCTAssertTrue(LiftStrip.lifts(tapeCard(clip: clip)))
        XCTAssertFalse(LiftStrip.lifts(tapeCard(back: nil)), "a tape card whose answer was rewritten in words turns over")
        XCTAssertFalse(LiftStrip.lifts(Flashcard(front: CardSide(image: "a.png"), back: CardSide(image: "b.png"))), "not made from tape")
        XCTAssertFalse(LiftStrip.lifts(Flashcard(front: CardSide(text: "Q"), back: CardSide(text: "A"))))
    }

    func testACardWithoutAClipHasItsStripFoundFromItsPictures() throws {
        let tapes = [LiftStrip(center: CGPoint(x: 210, y: 76), size: CGSize(width: 120, height: 24), rotation: 0, color: .mustard),
                     LiftStrip(center: CGPoint(x: 180, y: 70), size: CGSize(width: 160, height: 30), rotation: -0.35, color: .sky),
                     LiftStrip(center: CGPoint(x: 240, y: 80), size: CGSize(width: 90, height: 20), rotation: 0.6, color: .rose),
                     LiftStrip(center: CGPoint(x: 200, y: 76), size: CGSize(width: 200, height: 30), rotation: 0.05, color: .sage)]
        for tape in tapes {
            let question = picture(tape, lifted: false), answer = picture(tape, lifted: true)
            let found = try XCTUnwrap(LiftStrip.find(question: XCTUnwrap(question.cgImage), answer: XCTUnwrap(answer.cgImage), picture: question.size),
                                      "\(tape)")
            XCTAssertEqual(found.color, tape.color)
            XCTAssertEqual(found.center.x, tape.center.x, accuracy: 1.5, "\(tape.color)")
            XCTAssertEqual(found.center.y, tape.center.y, accuracy: 1.5, "\(tape.color)")
            XCTAssertEqual(found.size.width, tape.size.width, accuracy: tape.size.width * 0.04, "\(tape.color)")
            XCTAssertEqual(found.size.height, tape.size.height, accuracy: tape.size.height * 0.08, "\(tape.color)")
            XCTAssertEqual(found.rotation, tape.rotation, accuracy: 0.03, "\(tape.color)")
        }
    }

    func testPicturesThatDoNotDifferByAStripFindNone() throws {
        let tape = LiftStrip(center: CGPoint(x: 210, y: 76), size: CGSize(width: 120, height: 24), rotation: 0, color: .mustard)
        let same = try XCTUnwrap(picture(tape, lifted: false).cgImage)
        XCTAssertNil(LiftStrip.find(question: same, answer: same, picture: CGSize(width: 420, height: 152)), "nothing differs")

        let format = UIGraphicsImageRendererFormat(scale: 2)
        format.opaque = true
        let black = UIGraphicsImageRenderer(size: CGSize(width: 420, height: 152), format: format).image { context in
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 420, height: 152))
        }
        XCTAssertNil(LiftStrip.find(question: same, answer: try XCTUnwrap(black.cgImage), picture: CGSize(width: 420, height: 152)),
                     "the whole picture differs")
        let small = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 100, height: 40), format: format).image { _ in }.cgImage)
        XCTAssertNil(LiftStrip.find(question: same, answer: small, picture: CGSize(width: 420, height: 152)), "different sizes")
    }

    func testTheFinderTakesTheClipFirstAndFindsTheRest() async throws {
        let tape = LiftStrip(center: CGPoint(x: 210, y: 76), size: CGSize(width: 120, height: 24), rotation: 0.2, color: .sage)
        let question = picture(tape, lifted: false), answer = picture(tape, lifted: true)

        let given = CardClip(region: CGRect(x: 0, y: 0, width: 420, height: 152), tapeCenter: CGPoint(x: 210.4, y: 76.2),
                             tapeSize: CGSize(width: 120, height: 24), tapeRotation: 0.2, color: .sage)
        let fromClip = await TapeFinder.strip(for: tapeCard(clip: given), question: question, answer: answer)
        XCTAssertEqual(fromClip?.center, CGPoint(x: 210.4, y: 76.2), "the card says where its tape lay")

        let searched = await TapeFinder.strip(for: tapeCard(), question: question, answer: answer)
        let found = try XCTUnwrap(searched)
        XCTAssertEqual(found.center.x, 210, accuracy: 1.5)
        XCTAssertEqual(found.color, .sage)

        var stale = given
        stale.tapeCenter = CGPoint(x: 80, y: 40)
        var moved = tapeCard(clip: stale)
        moved.front.image = "moved-front.png"
        let instead = await TapeFinder.strip(for: moved, question: question, answer: answer)
        XCTAssertEqual(instead?.center.x ?? 0, 210, accuracy: 1.5, "a clip with no tape under it gives way to the pictures")

        var swapped = tapeCard(clip: given)
        swapped.front.image = "swapped-front.png"
        let backwards = await TapeFinder.strip(for: swapped, question: answer, answer: question)
        XCTAssertNil(backwards, "with its sides swapped the tape is on the answer, so the card cross-fades")

        let plain = Flashcard(front: CardSide(image: "a.png"), back: CardSide(image: "b.png"))
        let none = await TapeFinder.strip(for: plain, question: question, answer: answer)
        XCTAssertNil(none, "a card that turns over has no strip")
    }
}
