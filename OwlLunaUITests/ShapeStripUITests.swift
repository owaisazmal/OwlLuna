import XCTest

/// The Shapes shortcut: tied on from Customise Tools, it brings a strip of shapes over the tray, and a drag on the
/// page draws the one picked.
@MainActor
final class ShapeStripUITests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func strokeCount(_ canvas: XCUIElement) -> Int {
        Int(((canvas.value as? String) ?? "").split(separator: " ").first ?? "") ?? 0
    }

    private func waitUntilSelected(_ element: XCUIElement, _ selected: Bool = true) {
        wait(for: [expectation(for: NSPredicate(format: "isSelected == %@", NSNumber(value: selected)), evaluatedWith: element)], timeout: 5)
    }

    private func drag(_ canvas: XCUIElement, _ from: CGVector, _ to: CGVector) {
        canvas.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: to), withVelocity: 600, thenHoldForDuration: 0.1)
    }

    /// Opens a notebook and ties Shapes on from Customise Tools.
    private func openWithShapes(_ app: XCUIApplication, appearance: String) -> XCUIElement {
        app.launchArguments = ["-storageRoot", "shapes", "-resetStorage", "-seedLibrary", "3", "-drawingInput", "anyInput", "-freshToolPresets",
                               "-appearance", appearance]
        app.launch()
        let notebook = app.buttons["notebook.Physics II 3"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let canvas = app.element("page.canvas.1")
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["editor.tools.extra.shapes"].exists, "Shapes isn't in the tray until it is tied on")

        app.buttons["editor.tools.customise"].tap()
        let tag = app.buttons["editor.tools.shortcut.shapes"]
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        XCTAssertFalse(tag.isSelected)
        let hint = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "rest the pen a moment before lifting")).firstMatch
        XCTAssertTrue(hint.exists, "the tags say how draw and hold works")
        tag.tap()
        waitUntilSelected(tag)
        attach(app, "\(appearance)-customise")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()
        XCTAssertTrue(tag.waitForNonExistence(timeout: 5))
        return canvas
    }

    func testShapesArePickedFromTheStripAndDraggedOut() throws {
        let app = XCUIApplication()
        let canvas = openWithShapes(app, appearance: "light")
        let shapes = app.buttons["editor.tools.extra.shapes"]
        XCTAssertTrue(shapes.waitForExistence(timeout: 5))
        XCTAssertFalse(shapes.isSelected)
        shapes.tap()
        let circle = app.buttons["editor.tools.shape.circle"]
        XCTAssertTrue(circle.waitForExistence(timeout: 5), "the strip comes out over the tray")
        waitUntilSelected(circle)
        waitUntilSelected(shapes)
        XCTAssertTrue(app.element("editor.tools.shapes").frame.maxY <= app.element("editor.tools.tray").frame.minY, "above the tray")

        let before = strokeCount(canvas)
        drag(canvas, CGVector(dx: 0.15, dy: 0.2), CGVector(dx: 0.4, dy: 0.35))
        XCTAssertEqual(strokeCount(canvas), before + 1, "a drag draws the circle")
        for (kind, from, to) in [("rectangle", CGVector(dx: 0.55, dy: 0.2), CGVector(dx: 0.85, dy: 0.35)),
                                 ("triangle", CGVector(dx: 0.15, dy: 0.42), CGVector(dx: 0.4, dy: 0.58)),
                                 ("line", CGVector(dx: 0.55, dy: 0.5), CGVector(dx: 0.85, dy: 0.51)),
                                 ("arrow", CGVector(dx: 0.55, dy: 0.64), CGVector(dx: 0.85, dy: 0.58))] {
            let button = app.buttons["editor.tools.shape.\(kind)"]
            button.tap()
            waitUntilSelected(button)
            XCTAssertFalse(circle.isSelected)
            drag(canvas, from, to)
        }
        XCTAssertEqual(strokeCount(canvas), before + 5, "each drag is one stroke")
        sleep(1)
        attach(app, "light-shapes")

        app.buttons["editor.tools.shapes.undo"].tap()
        XCTAssertEqual(strokeCount(canvas), before + 4, "the strip's Undo takes the last shape away whole")

        shapes.tap()
        XCTAssertTrue(circle.waitForNonExistence(timeout: 5), "Shapes again puts the strip away")
        waitUntilSelected(shapes, false)
        drag(canvas, CGVector(dx: 0.15, dy: 0.7), CGVector(dx: 0.6, dy: 0.75))
        if strokeCount(canvas) == before + 4 { drag(canvas, CGVector(dx: 0.15, dy: 0.82), CGVector(dx: 0.6, dy: 0.86)) }
        XCTAssertEqual(strokeCount(canvas), before + 5, "and a drag writes again")
    }

    func testTheEraserPutsTheStripAwayAndShapesBringsAPenBack() throws {
        let app = XCUIApplication()
        let canvas = openWithShapes(app, appearance: "dark")
        let shapes = app.buttons["editor.tools.extra.shapes"]
        XCTAssertTrue(shapes.waitForExistence(timeout: 5))
        shapes.tap()
        let rectangle = app.buttons["editor.tools.shape.rectangle"]
        XCTAssertTrue(rectangle.waitForExistence(timeout: 5))
        rectangle.tap()
        let before = strokeCount(canvas)
        drag(canvas, CGVector(dx: 0.2, dy: 0.25), CGVector(dx: 0.7, dy: 0.45))
        app.buttons["editor.tools.shape.circle"].tap()
        drag(canvas, CGVector(dx: 0.3, dy: 0.5), CGVector(dx: 0.6, dy: 0.68))
        XCTAssertEqual(strokeCount(canvas), before + 2)
        sleep(1)
        attach(app, "dark-shapes")

        let eraser = app.buttons["editor.tools.eraser"]
        eraser.tap()
        waitUntilSelected(eraser)
        XCTAssertTrue(rectangle.waitForNonExistence(timeout: 5), "a shape is drawn in ink, so the eraser puts the strip away")
        shapes.tap()
        XCTAssertTrue(rectangle.waitForExistence(timeout: 5))
        waitUntilSelected(app.buttons["editor.tools.shape.circle"])
        waitUntilSelected(app.buttons["editor.tools.1"])
        XCTAssertFalse(eraser.isSelected, "and Shapes takes the pen up again")
    }
}
