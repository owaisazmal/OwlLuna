import XCTest
import PencilKit
@testable import OwlLuna

/// The tool tray: what is kept of a pen, the shelf the pens stand on, and the toolbox that knows which tool is in hand.
@MainActor
final class ToolPresetTests: XCTestCase {
    /// Settings of its own for each test, taken away afterwards.
    private func freshDefaults() throws -> UserDefaults {
        let suite = "ToolPresetTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func testAToolIsKeptWithItsKindColourAndWidth() throws {
        let preset = try XCTUnwrap(ToolPreset(PKInkingTool(.fountainPen, color: UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1), width: 6)))
        XCTAssertEqual(preset.inkType, .fountainPen)
        XCTAssertEqual(preset.color, 0x3366_CCFF)
        XCTAssertEqual(preset.width, 6, accuracy: 0.01)
        let tool = try XCTUnwrap(preset.tool)
        XCTAssertEqual(tool.inkType, .fountainPen)
        XCTAssertEqual(tool.width, 6, accuracy: 0.01)
        XCTAssertEqual(ToolPreset(tool)?.color, preset.color, "the colour comes back as it went in")
        XCTAssertNil(ToolPreset(PKEraserTool(.vector)), "only pens, pencils and markers are kept")
        XCTAssertNil(ToolPreset(PKLassoTool()))
    }

    func testAWidthPastWhatTheInkAllowsIsBroughtBackIn() throws {
        let range = PKInkingTool.InkType.monoline.validWidthRange
        let tool = try XCTUnwrap(ToolPreset(ink: .monoline, color: 0x0000_00FF, width: 500).tool)
        XCTAssertEqual(tool.width, range.upperBound, accuracy: 0.01)
        XCTAssertEqual(ToolPreset(ink: .monoline, color: 0x0000_00FF, width: 500).widthFraction, 1)
        XCTAssertEqual(ToolPreset(ink: .marker, color: 0x0000_00FF, width: PKInkingTool.InkType.marker.validWidthRange.lowerBound).widthFraction, 0)
    }

    func testTheSameToolIsToldByKindColourAndWidthNotByWhichWasSaved() {
        let pen = ToolPreset(ink: .pen, color: 0x2747_B8FF, width: 3)
        XCTAssertTrue(pen.isSameTool(as: ToolPreset(ink: .pen, color: 0x2747_B8FF, width: 3.1)))
        XCTAssertFalse(pen.isSameTool(as: ToolPreset(ink: .pencil, color: 0x2747_B8FF, width: 3)))
        XCTAssertFalse(pen.isSameTool(as: ToolPreset(ink: .pen, color: 0x2747_B9FF, width: 3)))
        XCTAssertFalse(pen.isSameTool(as: ToolPreset(ink: .pen, color: 0x2747_B8FF, width: 4)))
    }

    func testColoursAreNamedForVoiceOver() {
        func name(_ color: UInt32) -> String { ToolPreset(ink: .pen, color: color, width: 3).colorName }
        XCTAssertEqual(name(0x1B22_30FF), "Black")
        XCTAssertEqual(name(0xFFFF_FFFF), "White")
        XCTAssertEqual(name(0x8080_80FF), "Grey")
        XCTAssertEqual(name(0xC945_2FFF), "Red")
        XCTAssertEqual(name(0xFFD4_26FF), "Yellow")
        XCTAssertEqual(name(0xE8B0_23FF), "Mustard", "a colour of the palette that shares its hue with another has its own name")
        XCTAssertEqual(Set((ToolPreset.inks + ToolPreset.tints).map(ToolPreset.colorName)).count, 16, "no two of the palette are called the same")
        XCTAssertEqual(name(0x2747_B8FF), "Blue")
        XCTAssertEqual(name(0x3D5A_40FF), "Green")
        XCTAssertEqual(ToolPreset(ink: .marker, color: 0xE8B0_23FF, width: 20).name, "Highlighter, Mustard")
    }

    func testAPenIsAsFaintAsItIsSetWhateverItsColour() throws {
        var pen = ToolPreset(ink: .pen, color: 0x2747_B8FF, width: 3)
        XCTAssertEqual(pen.opacity, 1)
        XCTAssertEqual(pen.opacityName, "100%")
        pen.opacity = 0.6
        XCTAssertEqual(pen.color, 0x2747_B899, "the opacity is the colour's last byte, so pens saved before it are at full strength")
        XCTAssertEqual(pen.tint, 0x2747_B8FF)
        XCTAssertEqual(pen.opacity, 0.6, accuracy: 0.001)
        XCTAssertEqual(pen.opacityName, "60%")
        XCTAssertEqual(pen.name, "Pen, Blue", "a faint pen is called what it was")
        var alpha: CGFloat = 0
        try XCTUnwrap(pen.tool).color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        XCTAssertEqual(alpha, 0.6, accuracy: 0.01, "the canvas writes as faintly")
        XCTAssertEqual(ToolPreset(try XCTUnwrap(pen.tool))?.color, pen.color)

        pen.setTint(0xE8B0_23FF)
        XCTAssertEqual(pen.color, 0xE8B0_2399, "another colour is as faint as the last")
        XCTAssertEqual(pen.colorName, "Mustard")
        pen.opacity = 0
        XCTAssertEqual(pen.opacity, ToolPreset.leastOpacity, accuracy: 0.005, "a pen never writes nothing")
        pen.opacity = 4
        XCTAssertEqual(pen.color, 0xE8B0_23FF)
        XCTAssertFalse(ToolPreset(ink: .pen, color: 0x2747_B8FF, width: 3).isSameTool(as: ToolPreset(ink: .pen, color: 0x2747_B899, width: 3)))

        let back = try JSONDecoder().decode(ToolPreset.self, from: JSONEncoder().encode(ToolPreset(ink: .pencil, color: 0x1B22_3080, width: 4)))
        XCTAssertEqual(back.opacity, 0.5, accuracy: 0.005)
    }

    func testANewPenIsAsFaintAsTheOneInHandAndAHelperOffTheTrayIsPutAway() throws {
        let toolbox = Toolbox(defaults: try freshDefaults())
        let first = try XCTUnwrap(toolbox.pen)
        toolbox.changePen(first.id) { $0.opacity = 0.4 }
        XCTAssertEqual(try XCTUnwrap(toolbox.pen).opacity, 0.4, accuracy: 0.005)
        let new = try XCTUnwrap(toolbox.addPen().flatMap { id in toolbox.shelf.usable.first { $0.id == id } })
        XCTAssertEqual(new.opacity, 0.4, accuracy: 0.005)
        XCTAssertEqual(new.tint, 0x6E73_7CFF, "black, blue and red are taken, however faint the black is")

        XCTAssertFalse(toolbox.typesHandwriting)
        toolbox.setExtra(.typing, shown: true)
        toolbox.setExtra(.ruler, shown: true)
        toolbox.typesHandwriting = true
        toolbox.isRulerActive = true
        toolbox.setExtra(.typing, shown: false)
        XCTAssertFalse(toolbox.typesHandwriting, "with its tag off the tray there would be nothing to turn it off with")
        XCTAssertTrue(toolbox.isRulerActive)
        toolbox.setExtra(.ruler, shown: false)
        XCTAssertFalse(toolbox.isRulerActive)
        XCTAssertEqual(ToolExtra.typing.title, "Handwriting to Text")
        XCTAssertEqual(Set(ToolExtra.allCases.map(\.symbol)).count, ToolExtra.allCases.count)
    }

    func testANewShelfStartsWithTheAppsInksAndKeepsWhatIsSaved() throws {
        let defaults = try freshDefaults()
        let shelf = ToolShelf(defaults: defaults)
        XCTAssertEqual(shelf.usable.count, ToolShelf.starters.count)
        let pencil = ToolPreset(ink: .pencil, color: 0x3D5A_40FF, width: 4)
        XCTAssertTrue(shelf.add(pencil))
        XCTAssertFalse(shelf.add(ToolPreset(ink: .pencil, color: 0x3D5A_40FF, width: 4)), "the same tool isn't kept twice")
        XCTAssertEqual(ToolShelf(defaults: defaults).usable.last?.id, pencil.id, "and it is there the next time the app opens")

        shelf.move(pencil.id, by: -1)
        XCTAssertEqual(shelf.usable.map(\.id).firstIndex(of: pencil.id), ToolShelf.starters.count - 1)
        shelf.move(pencil.id, by: 5)
        XCTAssertEqual(shelf.usable.map(\.id).firstIndex(of: pencil.id), ToolShelf.starters.count - 1, "there is nowhere that far down to go")

        shelf.change(pencil.id) { $0.ink = PKInkingTool.InkType.crayon.rawValue; $0.color = 0xC945_2FFF }
        XCTAssertEqual(shelf.usable.first { $0.id == pencil.id }?.inkType, .crayon, "changed where it stood")
        XCTAssertEqual(ToolShelf(defaults: defaults).usable.first { $0.id == pencil.id }?.color, 0xC945_2FFF)
        shelf.remove(pencil.id)
        XCTAssertEqual(ToolShelf(defaults: defaults).usable.count, ToolShelf.starters.count)
    }

    func testTheShelfHoldsEightAndATrayLeftWithNothingGetsTheStartersBack() throws {
        let defaults = try freshDefaults()
        let shelf = ToolShelf(defaults: defaults)
        for width in 0..<10 { shelf.add(ToolPreset(ink: .pen, color: 0x0000_00FF, width: 1 + Double(width))) }
        XCTAssertEqual(shelf.usable.count, ToolShelf.limit)
        XCTAssertTrue(shelf.isFull)
        for preset in shelf.presets { shelf.remove(preset.id) }
        XCTAssertTrue(ToolShelf(defaults: defaults).presets.isEmpty)
        XCTAssertEqual(Toolbox(defaults: defaults).shelf.usable.count, ToolShelf.starters.count, "a tray needs something to write with")
    }

    func testTheTrayGivesThePensWhatTheyNeedAndLetsShortcutsGiveWay() {
        let fixed: CGFloat = 32 + 3 * ToolTray.button + 34 + 16
        XCTAssertEqual(ToolTray.plan(pens: 4, extras: 2, room: 834), ToolTray.Plan(pens: 5 * ToolTray.slot, extras: 2), "four pens and the empty label")
        XCTAssertEqual(ToolTray.plan(pens: 8, extras: 7, room: 1194), ToolTray.Plan(pens: 8 * ToolTray.slot, extras: 7), "a full shelf has no empty label")
        XCTAssertEqual(ToolTray.plan(pens: 8, extras: 2, room: 417), ToolTray.Plan(pens: 417 - fixed - 2 * ToolTray.button, extras: 2),
                       "short of room, the pens scroll in what there is")
        XCTAssertEqual(ToolTray.plan(pens: 8, extras: 4, room: 375), ToolTray.Plan(pens: 375 - fixed - ToolTray.button, extras: 1),
                       "the shortcuts give way, the last first, until three pens have a place")
        XCTAssertEqual(ToolTray.plan(pens: 8, extras: 4, room: 320), ToolTray.Plan(pens: 320 - fixed, extras: 0))
        XCTAssertEqual(ToolTray.plan(pens: 1, extras: 0, room: 200).pens, ToolTray.slot, "there is always a place for one pen")
    }

    func testAToolOfAKindThisBuildDoesNotKnowIsKeptAndLeftOut() throws {
        let defaults = try freshDefaults()
        let stored = #"[{"id":"\#(UUID().uuidString)","ink":"com.apple.ink.future","color":255,"width":3},{"id":"\#(UUID().uuidString)","ink":"com.apple.ink.pen","color":255,"width":3}]"#
        defaults.set(Data(stored.utf8), forKey: SettingsKey.toolPresets)
        let shelf = ToolShelf(defaults: defaults)
        XCTAssertEqual(shelf.presets.count, 2)
        XCTAssertEqual(shelf.usable.count, 1)
        shelf.add(ToolPreset(ink: .marker, color: 0xE8B0_23FF, width: 20))
        XCTAssertEqual(ToolShelf(defaults: defaults).presets.first?.ink, "com.apple.ink.future", "saving again doesn't drop it")
    }

    func testTheToolboxKnowsWhatIsInHandAndKeepsIt() throws {
        let defaults = try freshDefaults()
        let toolbox = Toolbox(defaults: defaults)
        let pens = toolbox.shelf.usable
        XCTAssertEqual(toolbox.choice, .pen(pens[0].id), "a new toolbox starts with its first pen in hand")
        XCTAssertEqual((toolbox.tool as? PKInkingTool)?.inkType, .pen)

        toolbox.take(.pen(pens[3].id))
        XCTAssertEqual((toolbox.tool as? PKInkingTool)?.inkType, .marker)
        toolbox.take(.pen(UUID()))
        XCTAssertEqual(toolbox.choice, .pen(pens[3].id), "a pen that isn't on the shelf can't be taken up")
        toolbox.take(.eraser)
        XCTAssertEqual((toolbox.tool as? PKEraserTool)?.eraserType, .vector)
        toolbox.setEraser(Eraser(kind: .part, width: 40))
        XCTAssertEqual((toolbox.tool as? PKEraserTool)?.eraserType, .fixedWidthBitmap)
        XCTAssertEqual(try XCTUnwrap((toolbox.tool as? PKEraserTool)?.width), 40, accuracy: 0.01)
        toolbox.setExtra(.ruler, shown: true)
        toolbox.setExtra(.text, shown: false)

        let again = Toolbox(defaults: defaults)
        XCTAssertEqual(again.choice, .eraser)
        XCTAssertEqual(again.eraser, Eraser(kind: .part, width: 40))
        XCTAssertEqual(again.extras, [.picture, .ruler])
        XCTAssertFalse(again.isRulerActive, "the ruler is put away between launches")
    }

    func testAPenIsChangedAddedAndRemovedWhereItStands() throws {
        let toolbox = Toolbox(defaults: try freshDefaults())
        let first = toolbox.shelf.usable[0]
        toolbox.changePen(first.id) { $0.color = 0x2F8F_4EFF; $0.width = ToolPreset.width(at: 0.5, of: .pen) }
        XCTAssertEqual(toolbox.pen?.color, 0x2F8F_4EFF)
        XCTAssertEqual(try XCTUnwrap(toolbox.pen).widthTravel, 0.5, accuracy: 0.001, "the slider comes back to where it was let go")
        XCTAssertEqual((toolbox.tool as? PKInkingTool).flatMap { ToolPreset($0) }?.color, 0x2F8F_4EFF, "and the pen in hand writes with it")

        let added = try XCTUnwrap(toolbox.addPen())
        XCTAssertEqual(toolbox.choice, .pen(added), "a new pen is taken up")
        XCTAssertEqual(toolbox.pen?.inkType, .pen)
        XCTAssertEqual(toolbox.pen?.color, 0x1B22_30FF, "in the first of the palette's colours no pen of its kind has")
        toolbox.removePen(added)
        XCTAssertEqual(toolbox.choice, .pen(toolbox.shelf.usable[3].id), "taken off while in hand, the pen beside it is taken up")

        for pen in toolbox.shelf.usable { toolbox.removePen(pen.id) }
        XCTAssertEqual(toolbox.shelf.usable.count, 1, "the last pen stays")
        XCTAssertEqual(toolbox.choice, .pen(toolbox.shelf.usable[0].id))
    }

    func testThePencilSwitchesToTheEraserAndBackAndToTheToolBefore() throws {
        let toolbox = Toolbox(defaults: try freshDefaults())
        let pens = toolbox.shelf.usable
        toolbox.take(.pen(pens[1].id))
        toolbox.switchEraser()
        XCTAssertEqual(toolbox.choice, .eraser)
        toolbox.switchEraser()
        XCTAssertEqual(toolbox.choice, .pen(pens[1].id), "from the eraser, back to what was in hand")
        toolbox.take(.lasso)
        toolbox.switchPrevious()
        XCTAssertEqual(toolbox.choice, .pen(pens[1].id))
        toolbox.switchPrevious()
        XCTAssertEqual(toolbox.choice, .lasso)
    }

    func testTheKeyboardTakesUpThePenLastInHand() throws {
        let toolbox = Toolbox(defaults: try freshDefaults())
        let pens = toolbox.shelf.usable
        toolbox.take(.pen(pens[2].id))
        toolbox.take(.eraser)
        toolbox.take(.lasso)
        toolbox.takePen()
        XCTAssertEqual(toolbox.choice, .pen(pens[2].id), "back to the pen last in hand, not the first")
        toolbox.take(.pen(pens[1].id))
        toolbox.takePen()
        XCTAssertEqual(toolbox.choice, .pen(pens[1].id), "a pen in hand stays in hand")
    }

    func testResettingThePenTrayBringsBackTheFourItStartedWith() throws {
        let defaults = try freshDefaults()
        let toolbox = Toolbox(defaults: defaults)
        XCTAssertTrue(toolbox.shelf.isAsItStarted)
        let first = try XCTUnwrap(toolbox.pen)
        toolbox.changePen(first.id) { $0.color = 0x3D5A_40FF }
        let added = try XCTUnwrap(toolbox.addPen())
        toolbox.removePen(toolbox.shelf.usable[2].id)
        toolbox.setExtra(.ruler, shown: true)
        toolbox.setEraser(Eraser(kind: .part, width: 30))
        XCTAssertFalse(toolbox.shelf.isAsItStarted)
        XCTAssertEqual(toolbox.choice, .pen(added))

        toolbox.resetPens()
        XCTAssertTrue(toolbox.shelf.isAsItStarted)
        XCTAssertEqual(toolbox.shelf.usable.map(\.color), ToolShelf.starters.map(\.color))
        XCTAssertEqual(toolbox.shelf.usable.map(\.width), ToolShelf.starters.map(\.width))
        XCTAssertEqual(toolbox.choice, .pen(toolbox.shelf.usable[0].id), "the pen in hand gives way to the first")
        XCTAssertTrue(toolbox.extras.contains(.ruler), "the shortcuts stay")
        XCTAssertEqual(toolbox.eraser.kind, .part, "and so does the eraser")
        let relaunched = Toolbox(defaults: defaults)
        XCTAssertTrue(relaunched.shelf.isAsItStarted, "it lasts")
        XCTAssertEqual(relaunched.choice, toolbox.choice)

        toolbox.addPen()
        toolbox.take(.eraser)
        toolbox.resetPens()
        XCTAssertEqual(toolbox.choice, .eraser, "with the eraser in hand, the eraser stays")
        toolbox.switchEraser()
        XCTAssertEqual(toolbox.choice, .pen(toolbox.shelf.usable[0].id), "and the Pencil's switch goes back to a pen on the tray")
    }

    func testEveryCanvasTakesTheToolInHand() throws {
        let document = try makeDocument()
        let session = EditorSession(document: document)
        let toolbox = Toolbox(defaults: try freshDefaults())
        let controller = PageStackController(session: session, toolbox: toolbox)
        session.canvas = controller
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.view.layoutIfNeeded()
        let canvas = try XCTUnwrap(controller.canvas(forPage: 0))
        XCTAssertEqual((canvas.tool as? PKInkingTool)?.inkType, .pen)

        let marker = toolbox.shelf.usable[3]
        toolbox.take(.pen(marker.id))
        XCTAssertEqual((canvas.tool as? PKInkingTool).flatMap { ToolPreset($0) }?.color, marker.color)
        toolbox.changePen(marker.id) { $0.width = 30 }
        XCTAssertEqual(try XCTUnwrap((canvas.tool as? PKInkingTool)?.width), 30, accuracy: 0.01, "a change to the pen in hand reaches the page at once")
        toolbox.take(.lasso)
        XCTAssertTrue(canvas.tool is PKLassoTool)
        toolbox.isRulerActive = true
        XCTAssertTrue(canvas.isRulerActive)

        // "System Setting" lets a finger draw while the tools are out, as PencilKit does for its own picker.
        controller.setDrawingPolicy(.default)
        XCTAssertEqual(canvas.drawingPolicy, UIPencilInteraction.prefersPencilOnlyDrawing ? .pencilOnly : .anyInput)
        session.toggleTools()
        XCTAssertEqual(canvas.drawingPolicy, .pencilOnly, "with the tools put away, only the Pencil draws")
        controller.setDrawingPolicy(.anyInput)
        XCTAssertEqual(canvas.drawingPolicy, .anyInput)
    }

    func testEveryKindOfInkWritesALineOfItsOwnBroaderAsThePenIsSet() throws {
        func inked(_ image: UIImage) throws -> [UInt8] {
            let cg = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        }
        var lines: Set<[UInt8]> = []
        for kind in ToolPreset.kinds {
            let name = ToolPreset.name(of: kind), image = InkSample.image(of: kind, breadth: 0)
            XCTAssertEqual(image.size, InkSample.size)
            let narrow = try inked(image), broad = try inked(InkSample.image(of: kind, breadth: 1))
            XCTAssertGreaterThan(narrow.count { $0 > 60 }, 300, "\(name) leaves a mark at its narrowest")
            XCTAssertGreaterThan(broad.count { $0 > 60 }, narrow.count { $0 > 60 } * 2, "\(name) writes broader as the pen is set broader")
            XCTAssertTrue(lines.insert(narrow).inserted, "\(name) writes a line unlike the others")
        }
    }

    private func makeDocument() throws -> NotebookDocument {
        let root = StorageRoot(url: FileManager.default.temporaryDirectory.appending(path: "tool-tests-\(UUID().uuidString)", directoryHint: .isDirectory))
        let defaults = PageDefaults(template: .blank, paperColor: .white, pageSize: .letter)
        let manifest = NotebookManifest(title: "Tools", defaults: defaults, pages: [defaults.newPage()])
        let package = NotebookPackage(root: root, id: manifest.id)
        return NotebookDocument(package: package, load: ManifestLoad(manifest: manifest))
    }
}
