import XCTest
import SwiftUI
import UIKit
@testable import OwlLuna

/// The type strip: what it holds at each width, and the page keeping the words being typed clear of it.
@MainActor
final class TypeStripTests: XCTestCase {
    private typealias Piece = TypeStrip.Piece
    private let paper = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)

    private func pieces(_ room: CGFloat, at textSize: DynamicTypeSize = .large) -> Set<Piece> {
        TypeStrip.pieces(room: room) { TypeStrip.width(of: $0, at: textSize) }
    }

    /// What the pieces kept in a room take of it, as the strip lays them out.
    private func taken(_ kept: Set<Piece>, at textSize: DynamicTypeSize) -> CGFloat {
        kept.reduce(0) { $0 + TypeStrip.width(of: $1, at: textSize) } + CGFloat(kept.count - 1) * TypeStrip.gap + TypeStrip.inset * 2
    }

    // MARK: What the strip holds

    func testAFullPaneHoldsEveryPieceAndANarrowOneKeepsTheMostUsed() {
        let all = Set(Piece.allCases)
        XCTAssertEqual(pieces(1210), all, "an 11-inch iPad on its side")
        XCTAssertEqual(pieces(834), all, "and upright")
        XCTAssertEqual(pieces(605), all, "half its window on its side, beside another notebook")
        XCTAssertEqual(pieces(410), [.more, .size, .emphasis], "half a narrower window")
        XCTAssertEqual(pieces(381), [.more, .size, .emphasis], "a folded iPhone Duo, beside its rail")
        XCTAssertEqual(pieces(320), [.more, .size])
        XCTAssertEqual(pieces(120), [.more], "More is always there")
    }

    func testPiecesGiveWayInOrderAndNeverRunPastThePane() {
        for textSize in DynamicTypeSize.allCases {
            var before: Set<Piece> = []
            for room in stride(from: CGFloat(100), through: 1400, by: 7) {
                let kept = pieces(room, at: textSize)
                XCTAssertEqual(kept, Set(Piece.allCases.prefix(kept.count)), "the last gives way first, at \(room) pt")
                XCTAssertTrue(kept.isSuperset(of: before), "a wider pane never holds less, at \(room) pt")
                if kept.count > 1 { XCTAssertLessThanOrEqual(taken(kept, at: textSize), room, "\(kept.count) pieces at \(room) pt, \(textSize)") }
                before = kept
            }
            XCTAssertEqual(before, Set(Piece.allCases), "all of it fits a wide pane at \(textSize)")
        }
    }

    func testItsWordsGrowWithTheTextSizeAndItsIconsKeepABarsSize() {
        for piece in [Piece.more, .size, .face] {
            XCTAssertGreaterThan(TypeStrip.width(of: piece, at: .xxxLarge), TypeStrip.width(of: piece, at: .large), "\(piece)")
            XCTAssertGreaterThan(TypeStrip.width(of: piece, at: .accessibility5), TypeStrip.width(of: piece, at: .xxxLarge), "\(piece) past where bars stop")
        }
        for piece in Piece.allCases {
            XCTAssertGreaterThanOrEqual(TypeStrip.width(of: piece, at: .xSmall), 44, "nothing on it is under 44 points wide")
        }
        for piece in [Piece.emphasis, .list, .colour] {
            XCTAssertEqual(TypeStrip.width(of: piece, at: .accessibility5), TypeStrip.width(of: piece, at: .large))
        }
        XCTAssertLessThan(pieces(605, at: .xxxLarge).count, Piece.allCases.count, "larger words leave room for less in half a window")
        XCTAssertEqual(pieces(381, at: .accessibility5), [.more], "at the largest size a folded iPhone Duo keeps More")
        XCTAssertTrue(pieces(834, at: .accessibility2).isSuperset(of: [.more, .size, .emphasis]))
    }

    func testTheSizeIsReadOutInWholePointsOrToATenth() {
        XCTAssertEqual(TypeStrip.sizeText(17), "17")
        XCTAssertEqual(TypeStrip.sizeText(200), "200")
        XCTAssertEqual(TypeStrip.sizeText(17.5), "17.5")
        XCTAssertEqual(TypeStrip.sizeText(12.04), "12.0")
    }

    // MARK: The page keeps clear of it

    private func makeDocument(items: [PageItem]) async throws -> NotebookDocument {
        let root = temporaryRoot(self)
        var page = paper.newPage()
        page.items = items
        let manifest = NotebookManifest(title: "Lab", defaults: paper, pages: [page])
        try await NotebookPackage(root: root, id: manifest.id).create(manifest)
        return try await NotebookDocument.open(manifest.id, root: root)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// A box near the foot of a page, being typed in, in a window of its own.
    private func typing(_ box: TextBox, y: CGFloat) async throws -> (EditorSession, PageStackController, UITextView) {
        let placed = PageItem(content: .text(box), center: CGPoint(x: 300, y: y), size: CGSize(width: 260, height: box.height(width: 260)))
        let document = try await makeDocument(items: [placed])
        let session = EditorSession(document: document)
        let controller = PageStackController(session: session)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        for _ in 0..<100 where controller.canvas(forPage: 0)?.isLoaded != true { await pause(0.05) }
        controller.select(ItemSelection(pageID: document.pages[0].id, itemID: placed.id))
        controller.editText()
        let textView = try XCTUnwrap(window.descendants(UITextView.self).first { $0.accessibilityIdentifier == "page.text.editor" })
        return (session, controller, textView)
    }

    /// Waits for the page to come to rest with `rect` of the text view above what is covered of the view's foot.
    private func settles(_ textView: UITextView, _ rect: @autoclosure () -> CGRect, above covered: CGFloat, in controller: PageStackController) async -> Bool {
        for _ in 0..<40 {
            await pause(0.05)
            if textView.convert(rect(), to: controller.view).maxY <= controller.view.bounds.maxY - covered + 0.5 { return true }
        }
        return false
    }

    func testABoxAtTheFootOfAPageIsBroughtClearOfTheStrip() async throws {
        let (session, controller, textView) = try await typing(TextBox(string: "Oats"), y: 740)
        await pause(0.3)
        let covered: CGFloat = 420
        XCTAssertGreaterThan(textView.convert(textView.bounds, to: controller.view).maxY, controller.view.bounds.maxY - covered, "the box starts where the strip will stand")

        session.typeStripHeight = covered
        let cleared = await settles(textView, textView.bounds, above: covered, in: controller)
        XCTAssertTrue(cleared, "with no keyboard at all the page moves the box above the strip")
        XCTAssertGreaterThan(textView.convert(textView.bounds, to: controller.view).minY, controller.view.safeAreaInsets.top, "and not off the top")
    }

    func testTheStripOnAKeyboardCountsFromTheKeyboard() async throws {
        let (session, controller, textView) = try await typing(TextBox(string: "Oats"), y: 740)
        // The strip at the foot of the pane, then a keyboard that it will ride.
        session.typeStripHeight = 68
        let screen = try XCTUnwrap(controller.view.window).screen.bounds
        let keyboard = CGRect(x: 0, y: screen.maxY - 300, width: screen.width, height: 300)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboard)])
        let overlap = controller.view.bounds.maxY - controller.view.convert(keyboard, from: try XCTUnwrap(controller.view.window).screen.coordinateSpace).minY
        let cleared = await settles(textView, textView.bounds, above: overlap + TypeStrip.height, in: controller)
        XCTAssertTrue(cleared, "the box clears the keyboard and the strip on it before the strip has moved")
    }

    // MARK: Typing goes on

    func testAChangeOfStyleLeavesTheSelectionAndAHalfComposedWordAlone() async throws {
        let (session, _, textView) = try await typing(TextBox(string: "Oats and flour"), y: 300)
        func font() -> UIFont? { textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont }
        XCTAssertTrue(textView.isFirstResponder)
        textView.selectedRange = NSRange(location: 5, length: 3)

        session.stepTextSize(by: 1)
        session.updateText { $0.isBold = true }
        XCTAssertTrue(textView.isFirstResponder, "the box is still being typed in")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 3), "with the same words selected")
        XCTAssertTrue(font()?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false, "and the change shows in it at once")
        XCTAssertEqual(session.selectedItem?.text?.fontSize, 18)
        session.refreshUndoState()
        XCTAssertTrue(session.canUndoFromBar, "the bar's Undo takes the change back while typing goes on")

        textView.selectedRange = NSRange(location: 14, length: 0)
        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(textView.markedTextRange)
        session.updateText { $0.isItalic = true }
        XCTAssertNotNil(textView.markedTextRange, "a word still being composed is not broken off")
        XCTAssertEqual(textView.text, "Oats and flourni")
        XCTAssertFalse(font()?.fontDescriptor.symbolicTraits.contains(.traitItalic) ?? true)

        textView.unmarkText()
        textView.delegate?.textViewDidChange?(textView)
        XCTAssertTrue(font()?.fontDescriptor.symbolicTraits.contains(.traitItalic) ?? false, "the style lands once the word is finished")
    }

    func testTheLineBeingTypedIsFollowedAsATallBoxGrows() async throws {
        var box = TextBox(string: "Oats")
        box.fontSize = 34
        let (session, controller, textView) = try await typing(box, y: 120)
        let covered: CGFloat = 500
        session.typeStripHeight = covered
        func caret() -> CGRect { textView.caretRect(for: textView.endOfDocument) }

        for line in 1...16 {
            let end = (textView.text as NSString).length
            _ = textView.delegate?.textView?(textView, shouldChangeTextIn: NSRange(location: end, length: 0), replacementText: "\nFlour")
            textView.textStorage.replaceCharacters(in: NSRange(location: end, length: 0), with: "\nFlour")
            textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
            textView.delegate?.textViewDidChange?(textView)
            let followed = await settles(textView, caret(), above: covered, in: controller)
            XCTAssertTrue(followed, "the caret stays above the strip after line \(line)")
        }
        let room = controller.view.bounds.height - controller.view.safeAreaInsets.top - covered
        XCTAssertGreaterThan(textView.bounds.height, room, "the box has outgrown what shows of the page")
        XCTAssertGreaterThanOrEqual(textView.convert(caret(), to: controller.view).minY, controller.view.safeAreaInsets.top, "and its last line is still on show")
    }
}

private extension UIView {
    func descendants<View: UIView>(_ type: View.Type) -> [View] {
        subviews.flatMap { (($0 as? View).map { [$0] } ?? []) + $0.descendants(type) }
    }
}
