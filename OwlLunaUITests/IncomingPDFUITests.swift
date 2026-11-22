import XCTest

/// A PDF shared in (`-sharePDF`, as Files leaves one) asks on a card: a new notebook first, or after a notebook's last page.
@MainActor
final class IncomingPDFUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ root: String, notebooks: Int = 3, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-storageRoot", root, "-resetStorage", "-seedLibrary", "\(notebooks)", "-sharePDF", "Lecture 4",
                               "-keepUndoVisible", "-appearance", "light"] + extra
        app.launch()
        return app
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func labelled(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testTheCardOffersANewNotebookFirstThenTheNotebooksOpenedLast() {
        let app = launch("incomingcard", notebooks: 6)
        XCTAssertTrue(app.element("incomingPDF.card").waitForExistence(timeout: 30), "the card asks where the PDF goes")
        XCTAssertTrue(labelled(app, "Import “Lecture 4.pdf”").exists, "the band names the file as it came")
        attach("incoming-card")
        let new = app.buttons["incomingPDF.new"]
        XCTAssertTrue(new.isSelected, "New Notebook is the chosen row")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "incomingPDF.notebook."))
        XCTAssertEqual(rows.count, 4, "four notebooks under New Notebook")
        let latest = app.buttons["incomingPDF.notebook.Cell Biology 1"]
        XCTAssertTrue(latest.exists, "the notebook opened last")
        XCTAssertLessThan(new.frame.midY, latest.frame.midY, "New Notebook comes first")
        XCTAssertFalse(app.buttons["incomingPDF.notebook.Ideas 6"].exists, "the oldest waits for Another Notebook…")
        XCTAssertTrue(latest.label.contains("1 page"), latest.label)
    }

    func testChoosingANotebookAddsThePagesAndOpenGoesToTheFirstNewPage() {
        let app = launch("incomingadd")
        let notebook = app.buttons["incomingPDF.notebook.Cell Biology 1"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        XCTAssertTrue(app.element("incomingPDF.slip").waitForExistence(timeout: 30), "the slip says where the pages went")
        XCTAssertTrue(labelled(app, "Added 3 pages to “Cell Biology 1”").exists)
        attach("incoming-added")
        XCTAssertFalse(app.buttons["notebook.Lecture 4"].exists, "no notebook was made of the PDF")
        app.buttons["incomingPDF.slip.open"].tap()
        let ribbon = app.buttons["editor.ribbon"]
        XCTAssertTrue(ribbon.waitForExistence(timeout: 20))
        wait(for: [expectation(for: NSPredicate(format: "label == 'Page 2 of 4'"), evaluatedWith: ribbon)], timeout: 15)
    }

    func testNewNotebookStillMakesANotebookOfThePDF() {
        let app = launch("incomingnew")
        let new = app.buttons["incomingPDF.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 30))
        new.tap()
        XCTAssertTrue(app.buttons["notebook.Lecture 4"].waitForExistence(timeout: 30), "a notebook named after the file")
        XCTAssertFalse(app.element("incomingPDF.card").exists)
        XCTAssertFalse(app.element("incomingPDF.slip").exists, "nothing was added to a notebook there was")
    }

    func testClosingTheCardImportsNothing() {
        let app = launch("incomingclose")
        let card = app.element("incomingPDF.card")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)).tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "a tap away closes the card")
        sleep(3)
        XCTAssertFalse(app.buttons["notebook.Lecture 4"].exists, "no notebook was made")
        XCTAssertFalse(app.element("incomingPDF.slip").exists, "nothing was added")
        XCTAssertFalse(app.element("pdfImport.progress").exists)
        XCTAssertTrue(app.buttons["notebook.Cell Biology 1"].exists)
    }

    func testAnotherNotebookListsTheRestWithASearch() {
        let app = launch("incominglist", notebooks: 6)
        let another = app.buttons["incomingPDF.another"]
        XCTAssertTrue(another.waitForExistence(timeout: 30))
        another.tap()
        let search = app.searchFields["incomingPDF.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["incomingPDF.list.Ideas 6"].exists, "every notebook that takes pages, the oldest too")
        search.tap()
        search.typeText("Field")
        XCTAssertTrue(app.buttons["incomingPDF.list.Studio Notes 2"].waitForNonExistence(timeout: 5), "the search narrows the list")
        attach("incoming-list")
        app.buttons["incomingPDF.list.Field Journal 5"].tap()
        XCTAssertTrue(labelled(app, "Added 3 pages to “Field Journal 5”").waitForExistence(timeout: 30))
    }

    func testOverAnOpenEditorItsOwnNotebookGoesStraightToTheNewPages() {
        let app = launch("incomingeditor", extra: ["-sharePDFAfter", "12"])
        let notebook = app.buttons["notebook.Cell Biology 1"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let ribbon = app.buttons["editor.ribbon"]
        XCTAssertTrue(ribbon.waitForExistence(timeout: 20))
        XCTAssertEqual(ribbon.label, "Page 1 of 1")
        let mine = app.buttons["incomingPDF.notebook.Cell Biology 1"]
        XCTAssertTrue(mine.waitForExistence(timeout: 30), "the card comes over the editor")
        sleep(1)
        attach("incoming-over-editor")
        mine.tap()
        wait(for: [expectation(for: NSPredicate(format: "label == 'Page 2 of 4'"), evaluatedWith: ribbon)], timeout: 30)
        XCTAssertFalse(app.element("incomingPDF.slip").exists, "the notebook is already open, so no slip to open it")
    }

    func testOverAnOpenEditorAnotherNotebookOpensFromTheSlip() {
        let app = launch("incomingother", extra: ["-sharePDFAfter", "12"])
        let notebook = app.buttons["notebook.Cell Biology 1"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 30))
        notebook.tap()
        let ribbon = app.buttons["editor.ribbon"]
        XCTAssertTrue(ribbon.waitForExistence(timeout: 20))
        let other = app.buttons["incomingPDF.notebook.Studio Notes 2"]
        XCTAssertTrue(other.waitForExistence(timeout: 30))
        other.tap()
        let open = app.buttons["incomingPDF.slip.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 30), "the slip shows over the editor")
        sleep(1)
        attach("incoming-slip-over-editor")
        XCTAssertEqual(ribbon.label, "Page 1 of 1", "the notebook on show is left alone")
        open.tap()
        wait(for: [expectation(for: NSPredicate(format: "label == 'Page 3 of 5'"), evaluatedWith: app.buttons["editor.ribbon"])], timeout: 30)
    }
}
