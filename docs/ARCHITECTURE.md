# OwlLuna architecture

## Editor: one canvas per page, in a UIKit page stack

We chose this in Phase 2 (M1) after timing three designs against the same fixtures.

### The three designs

- **A: a PKCanvasView per page.** Each canvas lives in a zooming UIScrollView page stack. Only the visible pages ±1 have a canvas, and the canvas is re-scaled after each pinch.
- **B: PDFView with a PKCanvasView overlay per page.** Templates are drawn as PDF pages.
- **C: the v1 single canvas, fixed.** It keeps one canvas but removes the per-stroke copy, moves saves off the main thread and stores ink per page.

### Measurements

Each design was built in its own worktree against a shared harness. The timings were then re-run one design at a time on a quiet machine.

- **Environment:** iPad Pro 11-inch (M5) simulator, iOS 27.0, Debug build. Apple M4 Mac mini, load average 6–9.
- **Method:** XCTest in-process timing (medians), plus UI tests with real simulator touches.
- **Fixtures:** "heavy" is 100 Letter pages × 500 strokes. "Dense" has a 1,000-stroke page 0. "pdf300" is a generated 300-page PDF.

| Measure (simulator) | A: per-page canvases | B: PDFKit overlays | C: fixed single canvas |
|---|---|---|---|
| Main thread at stroke end, 1,000-stroke page, 100-page notebook | **0.12 ms** | 0.13 ms | 0.03 ms |
| Same, 10-page notebook (flatness) | 0.13 ms | 0.11 ms | 0.01 ms |
| Autosave, main-thread part (heavy) | **0.13 ms** | 0.15 ms | 4.5 ms |
| Insert page at start (heavy) | **3.1 ms** | 14.7 ms | 114 ms |
| Move page 0→50 (heavy) | **4.0 ms** | 19.5 ms | 107 ms |
| Delete page (heavy) | **0.6 ms** | 0.6 ms | 104 ms |
| Open heavy: longest synchronous block | 15 ms | 18 ms | 9 ms |
| Open heavy: to first ink | **49 ms** | 75 ms | 629 ms |
| Open pdf300: to first ink | 10 ms | 34 ms | 12 ms |
| Peak footprint scrolling heavy / at 5× | 356 / 411 MB | 283 / 210 MB | 531 / 473 MB |
| Peak footprint scrolling pdf300 / at 5× | 398 / 444 MB | 348 / 371 MB | 519 / 480 MB |
| Ink at 1×, 2.5×, 5× and after a pinch | re-rendered sharp | sharp only with a counter-scaled canvas hack | re-rendered sharp |
| Undo across pages (real touches), page-op undo | pass | pass (needs a canvas undo proxy) | pass (bridges PencilKit's native entries) |
| Finger scrolls / Pencil draws / finger draws with "any input" | pass | pass | pass |
| Zoom range, landscape | 0.54× (whole page) to 5× | 0.50× to 5× | 0.55× to 5× |

Notes on the measurements:

- **Hitches.** On the simulator, `XCTOSSignpostMetric.scrollingAndDecelerationMetric` reports only the swipe's duration (about 2.56 s for every design), and `XCTHitchMetric` records nothing. Hitch figures need a device. For v2 there is a debug frame-pacing probe as a simulator proxy (see below).
- **Memory.** The simulator's `phys_footprint` does not include GPU memory. B's lower footprint comes from PDFKit tiling well, not from ink.

### Decision

**A.** It is the only design that meets every main-thread target:

- page operations under 5 ms;
- first ink under 100 ms;
- autosave work on the main thread under 2 ms.

It also keeps full control of layout, zoom and the desk.

- **C was rejected.** Every page operation and first render is O(notebook), and the single canvas exposes every stroke of the notebook to accessibility, which can stall VoiceOver.
- **B was rejected.** It has to reach into PDFKit's private scroll view, and PDFKit only transform-scales overlays, so sharp ink needs a counter-scaling workaround that re-renders only after the zoom settles. Its pinch can overshoot the maximum zoom, and its page operations take 15–20 ms.

A's one weakness is simulator footprint at 5×. We addressed it with the measures below and need to confirm it on a device.

## How the editor works

- **`PageStackController`** is a UIScrollView of page slots laid out in page points (`PageStackLayout`).
  - Slot views exist only for the visible pages ±1, so page operations cost O(visible pages), not O(notebook).
  - Each slot has a paper-coloured view with a hairline edge.
  - Its background is drawn as 256-point `CATiledLayer` chunks, created only within half a viewport of the screen. One tiled view per page grew to about 900 MB at 5× in the spike.
- **Canvases.** Each visible page ±1 has a `PageCanvasView` (a PKCanvasView).
  - Its drawing is in page-local points.
  - Its frame is a viewport-sized window onto the page, so PencilKit only backs what can be seen, even at 5×.
  - At most three canvases are pooled for reuse.
- **Zoom.**
  - During a pinch, the content view is magnified.
  - When the pinch ends, the zoom is *baked*: the layout is rebuilt at the new scale, and each canvas's `zoomScale` is set so PencilKit re-renders the ink sharply.
  - Pages keep their true relative size: 1× fits the widest page to the window, so an A5 page between Letter pages is smaller. Fit Width (⌘0) and Fit Page (⌘9) fit the current page instead, which enlarges a smaller page.
  - The minimum zoom shows a whole page, and the maximum is 5×.
- **Input.** The scroll view's pan and pinch accept direct touches only, so the Pencil never scrolls. With "Pencil and finger", scrolling takes two fingers.
- **Ink stays on its page.** Each page slot clips its canvas, and every renderer (thumbnails, covers, OCR, export) draws only the page rectangle. Ink that runs past the edge is kept in the drawing but never shown. Nothing is masked at stroke end: doing that copied every stroke on the page per stroke, and clipped lasso-moved ink for good.
- **Ink in memory.** Pages with a live canvas are pinned, so the ink a stroke replaces is always there for its undo. Prefetches for pages near the viewport are cancelled when the viewport moves on; a load a canvas is waiting for never is. Ink files are read and decoded off the package actor, in parallel, at the requesting task's priority.
- **Undo.**
  - `NotebookDocument` owns one `UndoManager`, and every stroke and page operation registers against the document, never against a view. Undo therefore survives canvas recycling.
  - Canvases return a `CanvasUndoProxy` as their undo manager. PencilKit wraps each stroke's registration in its own group and calls private grouping API. The proxy absorbs that, and forwards undo and redo (from ⌘Z or gestures) to the document's stack.
  - Filtering those registrations out on the shared stack instead leaves an empty undo step per stroke, and deferring the group crashes.
  - Undo and redo hand the canvas a copy of the drawing with no history (`PKDrawing(strokes:)`). Given an earlier version of a drawing it has already seen, PencilKit brings the later strokes back with the next stroke.
- **Tools.** The app has its own tools, not PencilKit's picker: `Toolbox` knows which tool is in hand and every canvas is given it (`canvas.tool`), new and reused ones when they are attached. See Tools. A hidden first-responder anchor (`ResponderAnchor`) keeps the page stack's key commands and ⌘Z working on every page.
- **Stroke end.** The main thread does four things only:
  1. copies the page's drawing into the document;
  2. bumps the page's version;
  3. registers undo;
  4. schedules a save.

  The notebook's modification date is applied at save time, so a stroke never touches the observed manifest.

## Draw and hold

- **Knowing the pen rested.** PencilKit doesn't say how a stroke ended, so `StrokeHoldRecognizer`, a gesture recogniser on the page stack that never recognises, watches the touch that draws and records how long it stayed within 6 pt before lifting.
- **Reading the shape.** When a stroke lands after a rest of 0.45 s or more, with an inking tool and the ruler off, `ShapeRecognizer` looks at its points. An open stroke is a line if it stays within 7% of its length from the chord (made level or upright within three degrees), or a run of straight pieces if looking three times more closely finds no more corners (a curve keeps gaining them). A closed stroke is compared with the ellipse round it (level, or along its longer direction) and with the polygon through its corners; four near-square corners become a true rectangle. Anything else, and anything smaller than 24 pt, is left as drawn.
- **Redrawing it.** `ShapeSnap.snapped` builds a new stroke in the same ink, weight, opacity and creation date. PencilKit's path is a smooth curve through its control points, so each corner is given three times to keep it sharp.
- **Its own undo step.** The tidied stroke is applied one run-loop pass later, after the stroke's own undo group has closed, so the first Undo gives the hand-drawn stroke back and the second removes it.

## Pictures, stickers and bookmarks

- **They live on the page.** A page's `items` (pictures and stickers, back to front, in page points) and its `bookmark` are extra keys on the page in the manifest, like a journal page's `date`. An older build keeps them as unknown keys; an item of a kind this build doesn't know is kept as read and not drawn.
- **Under the ink.** `PageItemRenderer` draws items after the paper and before the ink in thumbnails, covers and exports, so a sticker is vector in an exported PDF. In the editor they are live views between the background chunks and the canvas, and the chunks skip them (`drawBackground(items: false)`), so moving one never redraws paper or touches the canvas.
- **Arranging.** A finger tap (when fingers don't draw) or a touch and hold picks an item up. The selection view sits above the canvas, so touches on the item move it instead of drawing; pinch, twist or the corner handle resize and rotate it. The page's own scroll and zoom wait for those gestures. Each gesture, and each bar action (duplicate, forward, backward, delete), is one undo step through `NotebookDocument.updateItems`. Writing anywhere puts the item down.
- **Files.** A placed picture is stored once in the package's assets, at most 1,600 px on its long side, as PNG when it has transparency. Garbage collection keeps any asset the manifest names, so a deleted picture's file goes when the editor closes.
- **Bookmarks.** The Outline tab lists bookmarked pages, then the table of contents of any imported PDF (`PDFOutlineReader`, mapped through each page's PDF index, so reordering or deleting pages keeps entries on the right page). An export writes bookmarks as the PDF's outline.

## Text boxes and links

- **Two more kinds of item.** A text box (`TextBox`: the string, a size, bold, one of five tints, an alignment) and a link (`PageLink`: the target page's ID and an optional label) are entries in the same `items` list, so they are arranged, layered, undone and garbage-collected like pictures and stickers.
- **Text is laid out in page points.** `TextBox.height(width:)` and `TextBox.draw` use the same attributed string everywhere, so a box wraps the same way in the editor, a thumbnail and an exported PDF, where it stays real text. A box's width is the user's; its height always follows the text and grows downwards (`fittedToText`). The corner handle scales the type, the side grip changes the width.
- **Typing.** `editText()` puts a `UITextView` over the box, in the slot, with the type scaled to the baked zoom. The page keeps the old string until typing ends (Done, Escape, a tap elsewhere, a stroke, the keyboard going away, the scene leaving the foreground or the editor closing); then one `updateItems` writes it as one undo step. A box left empty is removed, by undoing its own Add when that is still the last action. While typing, the page stack hands every key to the text view and the toolbar's ⌘Z stands aside for the text view's own.
- **Search.** `NotebookPage.typedText` joins a page's boxes. `HandwritingIndexer` writes it into the page's text file without recognising anything, and the file's `#ink:` stamp carries a hash of it only on pages that have typed text, so pages indexed before stay current.
- **Links name themselves.** `LinkTitles` maps every page to its bookmark name or "Page N"; a link with no label shows that, so it stays right when pages move, and the page stack refreshes link views whenever the map changes. A link whose page was deleted greys out and says so. Thumbnails render without the map and show the label or a plain "Page".
- **Following.** A finger tap on a link opens its page when fingers don't draw, and always while presenting; touch and hold picks it up instead. VoiceOver's double tap opens it. `EditorSession.follow` remembers the page it came from until the linked page is left, and the editor offers "Back to Page N".
- **In a PDF.** An export registers a named destination at the top of every linked page and a link rectangle over each tab (`addDestination`, `setDestinationWithName`; both take PDF coordinates, which run up the page).
- **Links out of the notebook.** A link's `destination` is a page, another notebook (with an optional page and the title it had when the link was made) or a web address. They are written under different keys (`target`, `notebook` and `page`, `url`), so an older build keeps one it can't read rather than showing a missing page. Only `http` and `https` addresses are read. The editor looks up the titles of the notebooks it links to (`EditorSession.notebookTitles`), so those links follow a rename and grey out when the notebook is deleted. Following one asks the window (`EditorWindow.openNotebook`) to save and close this editor and open the other notebook, which then offers "Back to" the page it came from. In a PDF a web link is a URL annotation, and a link to a notebook is a `owlluna://notebook/<id>?page=<id>` address that opens the app.
- **Your own stickers.** `StickerCutout` lifts a photo's subject with `VNGenerateForegroundInstanceMaskRequest`, grows its shape in white (`CIMorphologyMaximum`) for the die-cut edge, and caps it at 900 px. They are kept as PNGs in `Stickers/` beside the library, not in a notebook. Placing one copies it into the notebook's assets as an ordinary picture marked with its `source`, and placing it again reuses that file, so a notebook stays self-contained. Where Vision finds no subject (and in the simulator, where the request can't run) the drawer offers the whole photo with a white edge instead.

## Study tape

- **One more kind of item, over the ink.** `PageItem.Content.tape` is stored in the page's `items` like a sticker (`kind: "tape"`, its colour under `tint`), so it is arranged, undone and kept by older builds the same way. It is the only item with `isOverInk`: `PageItemRenderer` draws the rest before the ink and tape after it (`PageRenderer.drawOverInk`), in thumbnails, exported PDFs and images, the second screen and the time-lapse. In the editor its view sits above the page's canvas (`PageSlotView.raiseTape`), where every other item sits below.
- **A tap lifts it.** A tape view takes the touches that land on it, so nothing is written on tape and a tap never leaves a dot, whether fingers draw or not. One tap recogniser on the page stack, which only begins over tape, toggles it for a finger, the Pencil or a pointer; touch and hold still picks it up to move, and the side grip lengthens it.
- **Lifting isn't saved.** `EditorSession.liftedTapes` is the set of strips lifted for now. It never reaches the document, so there is no undo step and nothing to save, and a notebook always opens with every strip in place. A lifted strip is drawn as a dashed outline so it can be found and put back. While presenting, the page sent to a second screen is rendered without the lifted strips.

## Flashcards

- **Where they are kept.** A notebook's cards are `cards.json` beside its manifest (`FlashcardFile`: a version and the cards), and their clippings are PNGs in `cards/`. Nothing in the manifest names them, so the document never writes them and the asset collector never sees them; a duplicate, a backup and a sync carry them because they copy the whole package. `CardFiles` does the reading and writing: a file that won't decode is set aside as `.corrupt`, a file from a newer version can be studied but is never written, and a write is refused once the package's manifest is gone, so a review can't bring back a deleted notebook.
- **One library.** `FlashcardLibrary` (main actor, observable, owned by `AppModel`) reads every package's cards at launch, again after a sync or restore, and picks up new packages after each index save. Changes are applied in memory and written by one actor in order. The library desk card and a notebook's deck sheet both read from it; locked and deleted notebooks are left out by whoever asks.
- **The schedule.** `CardSchedule` is SM-2 with three answers. Good waits 1 day, then 3, then the last wait times the card's ease (2.5 to start). Easy waits 4 days at first, then the wait times ease times 1.3, and raises the ease by 0.15. Again resets the wait, lowers the ease by 0.2 (never below 1.3) and counts a lapse if the card had been learned. Due dates are day keys in the user's calendar, so a card is due on a day, not at an hour. `ReviewSession` puts a forgotten card back at the end of the sitting.
- **Clippings.** `CardClipping` renders the page with `PageRenderer` at 2x and crops it. A tape card's region is the strip plus the line it sits in; its answer lifts only that strip and draws the lifted outline in its place. Selected handwriting is drawn alone on its page's paper.

## Study guide

- **The words.** `StudyGuide.text` saves the notebook, has `HandwritingIndexer` read any page whose text is out of date, and joins the pages' text files without their stamps; for a recording it is the transcript's text.
- **The model.** `StudyModel` is a protocol with two questions: the key points of a text, and questions with answers about it. `AppleStudyModel` asks Apple's on-device model (Foundation Models, iPadOS 26 and later) through guided generation, a fresh session for each piece. `StudyGuide.status` says why there is none (system too old, device not eligible, turned off, still downloading), and the sheet then explains instead of offering anything.
- **Long notes.** The model reads about 4,000 tokens at once, so `StudyGuide.chunks` cuts the text between lines into pieces of 3,200 characters. A summary takes up to five points from each piece and then asks for the most important of those; questions are spread evenly over the pieces. A piece the model still finds too long is read as two halves.
- **Tests** use `ScriptedStudyModel` (`-fakeModel`), which answers with the notes' own lines, and `-noModel` for the sheet's explanation.

## Focus and presenting

- `EditorSession.mode` is writing, focus or presenting. Focus hides the navigation bar, status bar and ribbons and leaves the tool tray. Presenting also hides the tray, turns drawing off, shows one whole page at a time (extra scroll inset lets the first and last page centre) and dims its neighbours.
- **The laser** is a `UILongPressGestureRecognizer` with no delay on the page stack, accepting whatever would draw in the editor: the Pencil always, a finger when fingers draw (two fingers then scroll). `LaserTrailView` keeps 0.9 s of samples and redraws on a display link only while there is something to show. Nothing reaches the document.
- The screen stays awake while presenting.
- **A second screen.** The app delegate gives a scene with the `windowExternalDisplayNonInteractive` role to `ExternalDisplaySceneDelegate`, which only registers it with `ExternalDisplay`. No window is put on it until presenting starts, so the screen mirrors the iPad the rest of the time. While presenting, `PresentationStageController` shows the page on black: the page stack renders it once per page (background, items and ink, at twice the size that fits, within 12 megapixels), then sends only the part of the page showing on the iPad (`PresentationStage.pageFrame` fits that part to the screen) and the laser as fractions of the page. Ending the presentation, or closing the editor, removes the window and mirroring resumes. The first editor to present owns the screen until it stops.

- **Presenter notes.** A page's `notes` is one more extra key on the page in the manifest, changed through `updatePage` so it is one undo step. It is not part of the page's appearance key, so thumbnails, exports and the second screen never show it, but it joins the page's typed text for search. While presenting, `PresenterPanel` sits beside the page stack (in the same `HStack`, so the page is refitted to the room that is left) whenever a second screen is showing, or when asked for from the bar: the elapsed time and the clock, the next page's thumbnail (tap to go there) and the notes. When the page stack is resized while presenting it keeps the session's page, since the scroll position is mid-change.

## Selecting ink across pages

- **A mode, not a tool.** `EditorMode.selecting` puts `InkLassoOverlay` over the page stack and turns drawing off. The overlay takes the touches itself (a canvas underneath holds a drag back for half a second), so one finger or the Pencil draws the lasso and two fingers still scroll and zoom.
- **Catching.** The outline is kept in stack points (page points offset by where the page sits in the stack). A loop encloses itself; a straight drag is taken as the diagonal of a box. On each page with a canvas, a stroke is caught when at least 60% of its sampled points are inside (`InkLasso.strokes`).
- **Moving.** While dragged, the caught strokes are drawn by the overlay as pictures and the canvases show their pages without them. On drop, `InkLasso.moved` gives each stroke a translation; a stroke whose middle lands on another page is taken out of its page's drawing and appended to that page's, with its transform adjusted for the two pages' origins. In the gap between pages it goes to the nearer one. Duplicate makes new strokes 18 pt down and right; Delete removes them.
- **One undo step.** `NotebookDocument.updateInk` replaces the ink of every page involved and registers one undo that puts them all back. It refuses a change that names a page whose ink isn't in memory, and the lasso only reaches pages that have a canvas, which are pinned. An undo or redo under a selection lets the selection go, since the strokes it named have moved.

## Handwriting to text

- With ink selected across pages, Turn into Text collects the caught strokes of each page as a drawing of their own (`selectedInk`). `InkText` renders each as dark ink on white with a margin, at up to three times its size, and reads it with the same Vision request that indexes pages for search, off the main thread.
- The sheet shows the words in a text editor, to be corrected before they are used. Copy puts them on the pasteboard. Replace Handwriting removes the strokes (`updateInk`) and adds a text box where the first page's strokes were (`InkText.box`: the type is sized from the height of the writing, between 13 and 34 points, and the box is kept on the page). Both are registered in the same pass of the run loop, so they are one undo step.

## Replaying a recording

- **Nothing extra is stored for the ink.** PencilKit dates every stroke. `ReplayTimeline` compares those dates with the recording's start and length, and keeps, for each stroke written inside it, its time, page and place in the page's drawing. A new recording stores when it began (`startedAt`) and which pages were written on (`pages`), so a replay reads only those; an older one is taken to have begun its length before it was saved, and every page is read.
- **Faint, not hidden.** While replaying, each live canvas shows a copy of its page's drawing in which strokes still to come have 16% of their opacity (`ReplayInk`), so the page keeps its shape. The copies are new strokes, not the old ones with their ink changed, because a canvas keeps what it has drawn for a stroke it knows. A canvas is only given a new drawing when the set of faint strokes on its page changes, and the document is never touched.
- **The mode.** `EditorMode.replaying` hides the chrome and the tool tray, turns drawing, selection and undo off (`CanvasUndoProxy.isSuspended`), and shows `ReplayBar`: play or pause, a scrubber and Done. The recorder reports its position ten times a second; the session passes it to the canvas and turns to the page being written on when that page changes, and otherwise leaves you where you scrolled. A tap on ink written during the recording seeks to its time. When the sound ends the replay waits at the end rather than closing.
- The editor's cover can no longer be pulled shut by a drag (`interactiveDismissDisabled`): with drawing off, a sideways finger drag on the page dismissed it through the zoom transition, skipping the save-and-close path.

## Transcripts

- **On the device or not at all.** `DeviceTranscriber` uses `SFSpeechRecognizer` on the recording's file with `requiresOnDeviceRecognition`. If the recogniser for the language can't work on the device it throws, and the app says so: nothing is ever sent to a server. Speech recognition permission is asked for the first time a recording is transcribed.
- **Gathering the words.** The recogniser reports as it goes. Only a settled stretch carries its times, so words are taken from results that are final or carry metadata, and merged by time (`Transcript.merge`): what is held from the first new word's moment onward is replaced, which is right whether the recogniser sends the whole recording again or only its latest stretch. If the final result has words but no times, they are spread evenly over the recording. A recording that trails off into silence ends with an error; what was heard before it still counts.
- **Where it is kept.** A `Transcript` (the language and each word with its start and length) is a JSON file in the notebook's assets, named in the recording's entry (`transcript`), so it is saved, synced, backed up and garbage-collected with the recording. Its words are also written as plain text to `text/<recording id>.txt`, beside the pages' recognised text, so the library's search text includes them. `PageSearch` reads those files for recordings and reports a hit as "Recording N", which opens the first page written on during that recording.
- **Reading it.** `Transcript.lines` breaks the words at the end of a sentence, a pause of a second, or sixteen words. `TranscriptView`, pushed from the Recordings list, shows the lines; a tap starts the replay at that line's moment. During a replay of a transcribed recording `TranscriptPanel` sits beside the page stack (300 pt, as the presenter view does), marks the line being said and scrolls to it, and a tap on a line seeks. In a narrow pane there is no room for it and the transcript stays in the Recordings sheet.
- **Not undoable, and cancellable.** A transcript is attached like a recording is, outside the undo stack. Closing the editor cancels a transcription under way; nothing is written until it has finished.
- **Tests.** `-fakeTranscript` stands `ScriptedTranscriber` in for the recogniser, since the simulator can't recognise speech on the device. Everything round the recogniser is tested that way; the recogniser itself needs a device.

- **Translating.** The sheet's Translate menu lists the languages the system translator supports, the iPad's own first. Choosing one sets a `TranslationSession.Configuration`, and `translationTask` hands the sheet a session once iPadOS has the language (it asks before downloading one). `InkTranslation` sends the text line by line and puts the lines back where they stood, so the text keeps its shape; Show Original puts back what the handwriting read as. The session is used off the main actor, where it was handed over. `-fakeTranslate` stands a fixed answer in for the translator, which the simulator doesn't have.

## Find in a notebook

- **A mode.** `EditorMode.finding` puts the chrome away, turns drawing off and shows the find bar. `NotebookFinder` owns the query, the matches (a page and a rectangle in page points each) and which one is shown; the session passes them to the canvas whenever they change.
- **Where the words are.** A text box holding the words is marked whole. A PDF page is searched in its own text (`PDFPage.selection(for:)`, line by line) and each rectangle is taken through the same turn and flip the page is drawn with. Handwriting and the picture of a scan or photo page are read with Vision, which gives a box for any range of what it read (`boundingBox(for:)`); the image read is the whole page, so the box is a fraction of the page.
- **Reading as little as possible.** The library's search already keeps what each page read as (`text/<page>.txt`, stamped with the ink it was read from). While that stamp still matches and the text doesn't hold the words, the page is skipped. A page written on since, or never read, is read now. `FindReader`, an actor, does the reading and keeps each page's lines (keyed by a fingerprint of its ink), so a second search of the same page costs nothing.
- **Order.** Pages are read from the one being looked at to the end, then from the start, and results are published as they come, so the first match shown is the nearest one ahead. Matches are kept in page order, and down each page in reading order. Next and Previous come round at the ends.
- **On the page.** `FindHighlightView` sits over a page's canvas and gives each match a small layer of its own (a view drawing the whole page would be too large at 5×). The match being shown is outlined as well as filled. The page stack scrolls just far enough to bring it clear of the bar and the keyboard.

## PDF text

- **A mode.** `EditorMode.selectingText` (⋯ › Select PDF Text, offered when the notebook has PDF pages) puts the chrome away, turns drawing off and lays `TextSelectOverlay` over the page stack. The overlay takes the touches itself, as the ink lasso's does: one finger or the Pencil selects, two fingers still scroll and zoom. It works in a read-only notebook too, where only Copy is offered.
- **What is selected.** A drag selects from the letter it began on to the letter it has reached, a tap selects a word, and Select All on This Page takes the page being read. `PDFTextReader`, an actor, does the reading with PDFKit off the main thread and keeps the documents it has opened; only the latest answer is shown, so a drag never waits on an earlier one. What comes back is a `TextSelection`: the words, and a rectangle for each line in page points, through the same turn and flip the page is drawn with (`NotebookFind.transform`). ⌘C copies it.
- **Settling a touch on the text.** Given a point off the text, PDFKit's `selection(from:to:)` picks a letter that can be lines away, or none. `PDFText.settled` first moves each end of a drag onto the line it is on or nearest to, and no further than that line's ends, so a drag past the end of a line takes the line and a drag into the margin doesn't jump.
- **Words.** `PDFPage.selectionForWord(at:)` needs a PDFView behind the page and ends the app without one (seen on iPadOS 27). `PDFText.word` reads the line from its start to the point and from the point to its end; the letter under the point is where the two meet, and Foundation's word boundaries widen it to its word.
- **Highlighting.** Highlight lays one marker stroke over each line of the selection (`TextHighlight.stroke`) and adds them to the page's ink with `updateInk`, as one undo step. They are ink like any other: the eraser takes them off, a replay shows them and an export draws them. With the chisel held across the stroke, a marker is drawn 1.43 times as tall as the size of its points, so the points are sized from the line's height, and the path stops a little short of each end because the chisel reaches past them.
- **A highlighter that snaps.** At stroke end, a marker stroke on a PDF page that runs sideways without much wander (`PDFText.runsAlongALine`) is checked against the page's text, off the main thread. `PDFText.line` reads the characters under the middle band of the stroke and returns their line's rectangle, no wider than the letters the stroke passed over. The stroke is then replaced by one laid over that rectangle, as an undo step of its own (`replaceLastStroke`, which is also how draw and hold tidies a shape), so the first Undo gives the hand-drawn stroke back. With no text under it the stroke is left as drawn, and draw and hold still applies. Settings › Apple Pencil turns it off.

## Zoom window

- **Two canvases, one page.** The strip at the foot of the editor (`ZoomWindowPanel`) holds a second `PageCanvasView` for the page being written on. Like every canvas it is a window onto the page: its `zoomScale` is the strip's width over the width of the area it covers, and its content offset is that area's corner, so strokes written in it are in page points from the start. Whichever canvas is written in, the document gets the stroke the usual way and the other canvas is given the same drawing (`mirrorInk`); an undo reaches both. The page's ink is pinned while the window is on it.
- **The area.** `ZoomWindow` is the geometry: the area's rectangle on the page, where its lines start and how far apart they are (the paper's own ruling on ruled, squared and dotted paper, half the window's height otherwise). It is always kept on the page. Three zoom levels show 30%, 42% or 60% of the page's width.
- **Moving along.** A stroke that reaches the last three tenths of the area marks it; 0.8 seconds after the last stroke ends the window moves on by 55% of its width, so what was just written stays in view on the left. At the end of the line it goes to the start of the next, and from the foot of a page to the top of the next page. Starting another stroke cancels a move that is waiting.
- **On the page.** `ZoomTargetView` outlines the area. Only its tab takes touches (to drag it), so the page under the outline is still written on directly. The paper behind the strip's canvas is the page's background and items drawn for that area alone.
- **When it closes.** Presenting, replaying, selecting ink and finding close it, as does deleting its page. Draw and hold doesn't apply in the strip.

## Tools

- **Why our own.** PencilKit's picker can't be restyled, can't hold anything of ours (a picture, a text box) and floats over the page at a size of its own choosing. The canvases only need a `PKTool`, so the app keeps the tools itself and draws them on one slim board.
- **What is kept.** A `ToolPreset` is a pen: the kind of ink (PencilKit's own name for it), its colour as four bytes and its width. `ToolShelf` keeps up to eight in the app's settings (`toolPresets`, as JSON), the same for every notebook and window; a new shelf starts with four of the app's own inks, and a shelf left with nothing usable gets them back. A pen of a kind this build doesn't know is kept and not shown. `Toolbox` owns the shelf and the rest (`toolbox`, as JSON): which tool is in hand (`ToolChoice`: a pen, the eraser or the lasso), the eraser (whole strokes, or part of one at a set width), and which shortcuts stand in the tray. The ruler is on or off for the session only.
- **Reaching the pages.** Any change to the tool in hand or the ruler posts `Toolbox.didChange`; each page stack gives `toolbox.tool` to its live canvases, the ones waiting to be reused and the zoom window's. A canvas attached later takes it then. Two panes and every window share the one toolbox, so a tool chosen in one is the tool in the other.
- **The tray.** `ToolTray` is a SwiftUI overlay at the foot of the editor, 48 points tall: the pens, an empty label that adds one, the eraser, the lasso, the shortcuts and the menu that chooses them. `ToolTray.plan` shares the width out: the eraser, lasso and menu always show, shortcuts give way from the last until three pens have a place, and pens that still don't fit scroll within their part with a fade at the edge. It shows in writing and focus mode while the tools are out (`EditorSession.showsToolTray`), not for a read-only notebook or while a text box is typed in, and it ignores the keyboard's safe area so nothing moves it.
- **Room for it.** The tray floats; it takes nothing from the page's width. The page stack keeps `toolsObscured` (the tray, the gap under it and the home indicator's margin or the zoom window it stands on) as bottom inset, so the last page scrolls clear of it, and `readableArea` leaves it out, so Fit Page and Show Everything fit above it and a new picture lands clear of it. A whiteboard is remembered by the middle of `pageArea`, which doesn't count the tray, so a board doesn't shift when the tray comes and goes.
- **Changing a pen.** A tap takes a pen up; a tap on the pen in hand opens `PenOptions` in a popover: its kind (`PenRoll`, a roll of cloth with a drawn tool in each pocket), its colour (the app's twelve inks, four highlighter tints and the system colour picker), its width and its opacity. The width is `WidthBar`, a stroke that swells along a strip of paper with a knob on it; VoiceOver gets a slider in its place (`accessibilityRepresentation`). The opacity is the same bar with `measure: .opacity`: a wash over ruled lines, moved in twentieths. Travel along it is squared, so the thin end, where writing is done, has most of the room. A new pen copies the one in hand, or the one last in hand, in the first palette colour no pen of its kind has. The tools of the roll are drawn in code (`PenDrawing`, on a `Canvas`), so they take the pen's colour and need no assets. The line on the options' label (`InkLabel`) is real ink: `InkSample` builds one stroke for a kind and a breadth (twelve steps) from its own points, has PencilKit draw it and keeps it as a template image, so a change of colour draws nothing again. The points' sizes are PencilKit's own measure and differ by ink: a pen, fineliner or fountain pen under about 2 leaves no mark. The options' last row moves the pen (`ToolShelf.move`) or removes it; touch and hold on a pen opens the same options. The tray's last button opens `ShortcutOptions`, a popover of `ShortcutTag`s over `Toolbox.setExtra`. Each of the tray's popovers is a `ScrollView` that only scrolls when it is taller than the screen allows (the largest text sizes with the iPad on its side). What a pen's ink is shown on comes from `ToolSwatch.paper(onDark:night:)`, and the rim that tells ink from the dark at night from `ToolSwatch.rim`.
- **Opacity.** A pen's opacity is the last byte of `ToolPreset.color`, which was always red, green, blue and alpha, so pens saved before it are at full strength and nothing is migrated. `opacity` reads and writes that byte (never under `leastOpacity`, 10%), `tint` is the colour without it, which is what the palette, the colour's name and a new pen's choice of colour compare, and `setTint` changes the colour and keeps the opacity. `ToolPreset.tool` hands PencilKit the colour with its alpha, which is all PencilKit needs. `ToolSwatch.ink(_:onDark:solid:night:)` is the colour to show: the ink with its alpha by day and on Chalkboard, the ink at full strength for the roll and the bars (`solid`), and at night `ToolSwatch.onPaper`, the opaque colour the ink has over white, since a faint ink over a dark well would look darker, not paler.
- **Finger or Pencil.** PencilKit's `.default` drawing policy follows the system's Only Draw with Apple Pencil switch only while its own picker shows. With no picker, `effectivePolicy` does the same for the tray: with the tools out and the switch off a finger draws, otherwise only the Pencil does. It is read again when the scene becomes active.
- **Pencil double-tap and squeeze.** With no picker to act on the system's setting, the page stack does: switch to the eraser and back, or to the tool before (`PencilToolMemory` inside the toolbox), and the system's palette actions bring out the ink dish. An action chosen in Settings replaces the system's; `PencilAction.palette` asks for the dish outright.
- **The ink dish.** `UIPencilInteraction`'s tap and squeeze carry a hover pose; its location, in the page stack's view, goes to `EditorSession.dish` (the middle of the view when the Pencil is too far off to have one), and `EditorContent` lays `InkDish` over the page stack while that is set. The overlay shares the stack's origin, so the point needs no conversion. `InkDish.centre(for:in:foot:)` keeps the whole dish on the pages and off the tray, and `InkDish.wells(_:)` sets the wells round the rim; `InkDish.luminance` decides whether a well's mark is dark or light. A clear layer behind the dish takes the tap or drag that puts it away. The session drops it when the mode changes, a sheet opens or the stack goes away. `-fakePencilSqueeze` adds a two-finger tap that stands in for the squeeze, since the simulator has no Pencil.
- **Handwriting to Text.** `Toolbox.typesHandwriting` is the helper's switch; like the ruler it isn't saved, and taking its tag off the tray turns it off. While it is on, `PageStackController.noteWriting` records each stroke a writing pen adds (by its path's creation date, PencilKit's only lasting name for a stroke) in `unreadWriting` and restarts a timer of `InkTyping.pause` (1.2 s); a stroke beginning stops it. When it fires, `typeUnreadWriting` reads those strokes off the main thread with `InkText.recognize`, the Vision recogniser the search index uses. A pass counter drops a reading if writing went on meanwhile, and the strokes wait for the next rest. `setType` then takes the strokes out (`NotebookDocument.updateInk`) and adds a text box where they stood (`InkText.box`), or grows the box made just before when `InkTyping.join` says the writing carries on its last line or starts the line below (`InkTyping.extended`); both changes are registered in one pass of the run loop, so they are one undo step. Strokes that Undo gives back are no longer in `unreadWriting`, so they stay ink. Putting the pen down or turning the helper off reads what is waiting at once. `-scriptedInkText` and `-inkTypingPause` let a UI test, which draws slowly and only in straight lines, stand in for the recogniser and wait long enough; the unit test writes block letters on a real canvas and has Vision read them.
- **Shortcuts.** `ToolExtra` is what can stand beside the tools: Picture, Text Box, Sticker, Link, Study Tape, Ruler, Zoom Window and Handwriting to Text. They do what the Add and More menus do, or turn a helper on and off, through `EditorContent.use`; the tags behind the tray's last button (`ShortcutOptions`) choose which show.

## Whiteboards

- **A page, not a second editor.** A whiteboard is a `NotebookPage` marked `board` in its extras, 40,000 points square, first shown at its middle. Ink and items are in the board's own points and never move, so undo, replay, links and saved ink need nothing special. Nothing is ever backed at that size: the canvas is already a viewport-sized window onto its page, paper is tiles near the viewport, and the slot, the find marks and the lasso overlay are layers without a backing store. PencilKit was checked at this content size on the iPadOS 27 simulator: writing at 1× and pinched far out, 20,000 points from the origin. At 5× it has only been laid out, not written on, and no real Pencil has been tried.
- **Alone when open.** A sheet that large can't stand in a stack fitted to the widest page, so `PageStackLayout` has two states. With `solo` nil, pages stack as before and a board is a card (`BoardCardView`): a picture of what is on it and a board chip that opens it, with no canvas. With `solo` set, that board's frame is the whole content and every other page has an empty frame; `isLaidOut` says which pages have real geometry, and the lasso, drops, the zoom window and find ask it. `scrollToPage` is the one door: going to a board opens it, going to any other page brings the stack back, so the ribbon, the navigator, links, replay, presenting and find all cross over without knowing. The stack's zoom and each board's middle and zoom are kept for coming back.
- **Scale.** An open board uses the scale the stack would have (the window's width over the widest page, a Letter page if there is none), so ink is the size it is on a page. It zooms from 0.15× to 5×. Fit Page becomes Show Everything, Fit Width becomes Actual Size.
- **Its controls.** Nothing stands over an open board. Show Everything, Actual Size, Pages and the guide are behind one Whiteboard button in the bar (`boardMenu`), left of undo and redo; in a narrow pane, where the bar has no room for it, they are in More. The guide opens as a popover from the button, or a sheet where there is none. The tip shown over a first whiteboard is the only thing that covers it, until it is put away once.
- **Standing in for the whole.** `Whiteboard.frame(of:ink:)` is what is on the board with room round it, never less than 1024 by 768 and always in that shape. `Whiteboard.piece(of:in:)` makes a page of a rectangle of the board: its size, its items moved, and `cut`, the rectangle's corner. `cut` is never saved. `PageRenderer.image` cuts a board down by itself, and renderers draw `page.inkRect` of the ink, so the ink is never transformed. Thumbnails, the card, PDF and image export, the time-lapse, handwriting search, find (rectangles are put back by `cut`), flashcard clippings and the second screen all go through a piece. `shownSize` is the shape a page has in lists; `sheetSize` is what new pictures, text and the zoom window are sized against (a Letter page on a board).
- **Paper.** `drawBoardPaper` rules a board with a Letter page's gaps and no margins, at multiples of the gap from the board's corner offset by `cut`, so tiles meet and the rules stay under the same ink in every piece. Only what is inside the clip is drawn, and rules closer than 14 pixels are thinned by halves. Boards take blank, dotted, squared and narrow ruled paper.

## Scanning

- `DocumentScanner` wraps the system's document camera (`VNDocumentCameraViewController`), which finds, straightens and crops each sheet. Each scan is stored as a JPEG of at most 2,400 px (`DocumentScan.picture`) and becomes a page with that picture as its background, a letter page wide and as tall as the paper was. In a notebook the pages go in after the current one as one undo step; from the library they become a notebook of their own with a first-page cover.
- **Searchable.** `HandwritingIndexer` now reads the picture of a scan or photo page with the same Vision request as ink. Such a page's stamp ends in `+img`, so a page stamped before pictures were read is read again once.
- The simulator has no camera, so `-fakeScan` supplies two printed sheets.

## Locked notebooks

- **The lock is a flag.** `library.locked` in the manifest (an unknown key to older builds) and `isLocked` in the index. It is not encryption: the files are protected by iPadOS like any app's, and a backup or an iCloud copy holds a locked notebook like any other.
- **Who may open it.** `NotebookLock` asks with `LAContext` (`deviceOwnerAuthentication`: Face ID or Touch ID, falling back to the passcode) and remembers which notebooks are open for now. That set is never saved: a notebook is locked again when its editor closes and when the scene goes to the background. Locking, removing a lock and exporting a locked notebook from the library ask too.
- **Two gates.** The library asks before it opens a locked notebook, so a refusal leaves you in the library. `EditorScreen` is the second gate for every other way in (a restored window, the notebook beside another, a link): it lays `LockedNotebookView` over the editor until the notebook is unlocked, and whenever the scene isn't active, so the pages never show in the app switcher. The editor underneath stays alive, so a recording carries on.
- **What a lock hides.** The cover is blurred under a padlock (`CoverView.isObscured`). Search matches a locked notebook by title only and shows no page results for it. It is left out of Continue Writing, On This Day, the widgets' snapshot and Spotlight, and Today's card shows a blank page for a locked journal.
- `-fakeUnlock`, `-fakeUnlockOnce` and `-fakeUnlockFails` stand in for Face ID in tests.

## Today's events

- `Agenda` reads the day's events with EventKit (`requestFullAccessToEvents`), all-day events first and then by the clock, and writes them as an ordinary text box: at most ten lines, with the rest counted. Nothing but that text is kept, and it is read on the device.
- **By hand.** Add › Today's Events places the box on the current page, selected like any new item.
- **On the journal.** With Settings › Daily Journal › Print Today's Events on, the page that becomes today's (`DailyJournal.dateToday`, `ensureTodayPage`, and a new journal's first page) gets the box below the printed date, against the right-hand margin. The calendar is read only on a day that has no page yet. The box is marked (`agenda` on the item), so when an untouched page is re-dated to a later day its old events come off; a page with anything else placed on it is left alone.
- `-fakeCalendar` stands three events in for the calendar.

## Time-lapse video

- `InkTimelapse.Plan` orders a page's strokes by PencilKit's creation dates and gives each a span of the film in proportion to how long it took to draw (its last point's time offset, between 0.06 and 4 seconds). The waits between strokes are dropped. The writing is shown in a quarter of the time it took, but never in less than three seconds or more than twenty.
- Each frame is the paper and items, the strokes finished so far, the first part of the stroke under way (`partial`, a prefix of its control points), then any study tape. Finished strokes are painted once into a bitmap that carries from frame to frame, so a frame costs one stroke's rendering whatever the page holds. Marker strokes are multiplied in, as PencilKit does on light paper. The last 1.5 seconds hold the page rendered from the whole drawing, the way every other export draws it.
- Frames go straight into the pixel buffers of an `AVAssetWriter` (H.264 in an MP4, the page's shape within 1080 by 1920, 30 frames a second), off the main thread, with progress and cancellation through the same `ExportJob` as the other exports. The sheet plays the result on a loop without controls.

## Widgets and shortcuts

- **Routing.** A widget link (`owlluna://today`, `quicknote`, `continue`, `notebook/<id>`) or an App Intent becomes an `AppAction`. The front window's `LibraryRootView` carries it out: it puts sheets away, asks an editor showing another notebook to save and close (`owlLunaCloseEditor`, the same path as the back button), then opens the target. A target another window has open is shown there, and this window is left as it was.
- **Shortcuts** (`AppActions.swift`): Open Today's Journal Page, New Quick Note, Continue Writing and Open Notebook (with a notebook picker and search), offered to Siri and Spotlight through `AppShortcutsProvider`.
- **Control Center.** `QuickNoteControl` and `TodayPageControl` are `ControlWidget`s whose buttons run an App Intent that opens the app. The intents live in `Shared/` so both targets have them; all they do is leave the request in the App Group's defaults (`ControlRelay`), and the app takes it when it comes to the front and turns it into the same `AppAction` a widget link does. A Quick Note widget does the same from the Home Screen and the Lock Screen.
- **Spotlight.** `SpotlightIndexer` hands iPadOS one item per notebook: its title, its cover as the thumbnail, and up to 30,000 characters of what is written, typed or printed in it. It runs a few seconds after any change to the library index and only sends notebooks whose title, pages, cover or words changed, by a stamp kept in the caches folder. Trashed and locked notebooks are taken out. A result opens its notebook through the same `AppAction`. Settings › Search turns it off and empties the index. UI-test libraries never reach it.
- **Widgets** (`OwlLunaWidgets`): the app writes a `WidgetSnapshot` and the last notebook's cover image into the App Group container when it becomes ready and when it leaves the foreground (`WidgetBridge`), and reloads the timelines only when something changed. The widgets never open the library themselves. Timelines turn over at midnight so the week strip and date stay right. UI-test libraries (`-storageRoot`) never write a snapshot.

## Tags and smart shelves

- **Where tags live.** A notebook's tags are `library.tags` in its manifest and a page's are `tags` on the page, both lists of names kept as extra keys, so an older build writes them back untouched. Entries that aren't names, and a value that isn't a list, are another build's and stay as they were. A page's tags are not part of its appearance key, so tagging never re-renders a thumbnail, and a copy of a page keeps them.
- **Names.** `Tags.normalized` trims a name, collapses the space inside it, drops a leading "#" and stops at 40 characters. Two spellings are one tag when they differ only in case or accents (`Tags.key`). A list keeps the first spelling of each tag and is sorted the way file names are (`Tags.merged`). The tag sheet gives a tag typed again the spelling the library already uses.
- **Changing them.** A page's tags go through `NotebookDocument.setTags`, one undo step in the editor. A notebook's go through `LibraryStore.setTags` like a favourite or a lock: the open document if there is one, the file otherwise, and the index at once. From the library that is undoable through the slip (`LibraryChangeCenter.setTags`). The tag sheet changes nothing until it is done, so a visit is one change. Like a favourite, a tag put on a notebook doesn't date it, so iCloud sync carries it with the notebook's next edit.
- **In the index.** A record keeps its notebook's tags (`tagsRaw`) and the union of its pages' tags (`pageTagsRaw`), one to a line. There is no table of tags: the sidebar counts them from the records (`Tags.counts`), once a notebook, and where spellings differ the commonest names the tag. Search matches both fields. A save that changed a notebook's or a page's tags tells the library, as one that changed the title does.
- **Renaming.** `LibraryStore.renameTag` respells a tag on every notebook and page that carries it, or takes it off them all, through the open document (`applyLibraryChange`) or the closed notebook's file, and brings the records up to date at once. A new name the library already has is merged into, in the spelling it has there, and smart shelves looking for the tag follow. Read-only notebooks keep the old name. Neither is undoable, and removing asks first.
- **Smart shelves** are saved filters: a name, tags, and whether any or all of them are wanted (`TagRule`). They are kept in `Library/smart-shelves.json` (`SmartShelfFile`), read as tolerantly as `folders.json`: unknown keys are written back, entries that can't be read are kept, a way of matching this build doesn't know is read as "any", and a file that isn't an object is set aside as `.corrupt`. `LibraryStore.smartShelves` holds them, read at launch and after a sync or a restore, and its writes are chained so they land in order. A backup carries the file, and a restore adds the shelves the library lacks, by ID, and never replaces one. iCloud sync does not carry it: tags travel inside their notebooks, smart shelves stay on the device.
- **What a shelf shows.** A notebook stands on a tag's shelf, or a smart shelf, when its own tags satisfy the rule. Under the notebooks, "Pages" lists the pages that carry one of the rule's tags themselves; asked for all of the tags, the tags of a page's notebook count towards the rest. `TagPages.hits` reads manifests off the main thread, only for notebooks whose record says a page carries one of the tags, takes an open notebook's pages from its document, and runs again whenever the index is saved.
- **Locked notebooks.** A locked notebook is counted, found and shelved by its own tags only. Its pages' tags stay out of the sidebar and its pages are never listed.

## Two notebooks in one window

- **`EditorPanes`** is what the library presents: the window's editor, and, when `EditorWindow.beside` is set, a second `EditorScreen` next to it with a draggable divider (30% to 70%). They sit side by side when the window is wider than tall and one above the other otherwise. The first editor keeps its identity when the second arrives or leaves, so it is never rebuilt.
- **Each pane is a whole editor**: its own document, session, undo stack, page stack and bars. The picker leaves out the notebook already open and any notebook open in another window, so the one-editor-per-notebook rule holds.
- **One toolbox.** Both panes read the same `Toolbox`, so a tool chosen in one is the tool in the other. Each pane has its own tray, with its pens scrolling in the room half a window leaves.
- **The active pane.** A recogniser that already watches every touch on the pages tells the window which notebook was touched last. Only that pane registers the SwiftUI keyboard shortcuts (⌘Z, ⌘N, ⌘D, ⌘W and the rest), and its anchor takes first responder so the page stack's key commands and ⌘Z go to it.
- **Narrow panes.** Below 620 pt a pane's bar keeps Back, the title, undo, redo, Add and More; recording, the recordings list and the tools switch move into More. Layout decisions that used the horizontal size class use the pane's width too.
- **Closing.** The second pane has its own Close, which saves and closes it like any editor. Back to the library on the first pane first asks the second to save and close (`EditorScreen.beforeClose`) and only then closes itself, so a failed save in either keeps the editors up. A widget link or shortcut that needs the window does the same.
- **Reopening.** A window reopens the notebooks it had open, the pair included. `WindowMemory` keeps them under the scene session's identifier the moment they change, because iPadOS saves a scene's own state (`@SceneStorage`, still written) only on the way to the background, and an app stopped straight after would come back with what was open before. `@SceneStorage` is read only for a window with nothing kept yet. A window closed in the app switcher comes back as a new session and starts in the library, and if a window's reopening crashes the next launch skips it once for that window. The mark that tells is kept per window too (`WindowMemory.setRestoring`), so two windows reopening together never take each other for a crash. A notebook another window has opened meanwhile isn't reopened: the window comes back in the library, or without the notebook beside. A remembered notebook that has been deleted or is in the Trash is forgotten, so the window starts in the library and is not taken for one that reopens at the next launch.

## Notebook tabs

- **Tabs belong to the window.** `EditorWindow.tabs` is the notebooks open in the first pane, in the order of the bar, and `selected` the one on show. A notebook on its own is one tab and shows no bar; the bar (`TabStrip`) appears from two.
- **One editor on show, every document open.** Only the tab on show has an `EditorScreen`. The documents of the tabs looked at since the editor opened stay open in `EditorWindow.documents` (the registry itself holds documents weakly), so coming back to a tab finds the same document, with its undo history and anything not yet saved, and the one-editor-per-notebook rule covers every tab that has been looked at. The session (mode, selection, zoom) is made afresh, at the manifest's current page. A recording stops when its tab is left, as it does when an editor closes.
- **Closing.** The tab on show is closed by its own editor (`owlLunaCloseEditor`, with `EditorWindow.closing` set to `.tab`), which can say so if saving fails. A tab behind the bar is saved and closed by `EditorScreen.putAway`, the same path a window that goes away takes: a document that can't be saved is kept and retried. Back to Library saves and closes the notebook beside, every tab's document and then the editor on show, so nothing stays open, or busy for a sync, behind the library.
- **What waits in the library.** Two or more tabs are remembered and shown again when a notebook is next opened, which joins them; a notebook on its own leaves nothing behind. `WindowMemory` keeps the tabs with the window's notebook, so the app reopens with them. A tab that waits holds nothing open, so another window can open its notebook meanwhile; the tab is then let go of (see One window writes in a notebook).
- **Opening.** The title menu and the bar's plus choose from the notebooks not already open in the window. With tabs open, a link to another notebook, a widget link or a shortcut shows that notebook in a tab; with a single notebook it replaces it, as before.
- **One window writes in a notebook.** Whatever would show a notebook that another window has open brings that window forward with the notebook on show instead (`EditorWindow.goesToItsWindow`, through `DocumentRegistry.activateExistingEditor`, which posts `owlLunaSelectTab` and, for a page, `owlLunaShowPage`): its cover in the library, a link, a widget link or a shortcut, a row in either picker, and a tab that was waiting when the other window opened it. The window that asked stays as it was, less any tab it kept for that notebook, which is the other window's now; a link that goes elsewhere leaves the way back this window had. `EditorWindow.isOpenElsewhere` is the question, asked of the registry with the window's `scene`. `show` and `select` refuse such a notebook, so a broadcast `owlLunaSelectTab` moves only the window that has it; and its tabs are let go of (`letGoOfTabsOpenElsewhere`) before the bar is stepped along, before a tab moves beside and before the tab on show closes, so the tab that takes its place is always one this window can write in. With none left, closing the tab on show is going back to the library. `EditorScreen` asks once more before it opens a document, so a route that forgot to ask closes its pane and never shares the document.
- **Moving.** A tab is dragged along the bar as a `TabReference` and lands where it is dropped: after a later tab, before an earlier one (`EditorWindow.moveTab`), as pages do in the navigator. The drop is taken by a `DropDelegate` that proposes a move, so the tab carries no copy badge on its way. Held, a tab offers Move Left and Move Right, which VoiceOver has as actions too. The tab on show stays on show wherever it goes, and `WindowMemory` keeps the new order.
- **The tab's menu.** Close Other Tabs closes the tabs behind the bar as any tab behind the bar is closed, and the one on show, if it isn't the one staying, by its own editor. Open Beside takes the tab off the bar and sets `EditorWindow.beside`, wherever the title menu would offer a second pane. The document the window was keeping for the tab is the one the second pane opens, and that pane holds it from then on (`EditorWindow.release`), so the notebook arrives with its undo history. `EditorWindow.keep` only keeps the document of a notebook that has a tab, so one that finishes opening after its tab has left isn't held on to.
- **Shortcuts.** ⇧⌘] and ⇧⌘[, or ⌃Tab and ⇧⌃Tab, step along the bar. ⌘W closes the tab on show while there are tabs and goes back to the library otherwise.
- The bar goes with the rest of the chrome in focus mode, while presenting and in the other modes.

## One document per notebook

- `DocumentRegistry` hands out one `NotebookDocument` per notebook across windows. An open still in progress is shared, so two windows opening the same notebook at once get the same document. `otherWindow(with:than:)` says which window has a notebook open or opening; a window that has gone holds nothing back.
- Library changes (favourite, trash, folder, rename, cover) go through the open document. A change written to a closed notebook's files while a document is being opened is applied to that document too, so its first save can't revert it.
- In the editor, ⌘N adds a page. The library's ⌘N and the library itself are disabled and hidden from VoiceOver while the editor covers them.

## Saving and closing

- Saves are debounced (1.2 s), but a pending save always starts within 5 s of the first unsaved edit, and turning pages never postpones one. Pending and retry saves hold their document, so a change made as the editor closes (a recording stopping, an import landing) is still written.
- Closing stops any recording, waits for imports, then saves. If saving keeps failing, the editor stays open and asks: try again, keep editing, or close anyway. Closing anyway keeps the document alive in the registry and retrying in the background; reopening the notebook picks up the same document.
- Saves only update the library index when something the library shows changed (title, pages, cover, favourite, trash, folder, tags). Ink-only saves don't; closing indexes everything. The index record is only written, and SwiftData only saved, when a field actually differs.

## Launch

- `AppModel.start` runs once, and later callers wait for it: it adopts any `.scribe` packages an older build left (see Storage v2), seeds a test library in Debug builds, sweeps `Deleting/`, refreshes the index and loads the smart shelves, history and flashcards, then sets `phase` to `.ready`.
- `OwlLunaRoot` asks `LaunchAnimation.isEnabled` before `start()`. When it is true, `LaunchOverlay` plays the splash over the library (the choreography is in `docs/DESIGN.md` › Launch), which stays at opacity 0 and hidden from VoiceOver until the overlay hands over: at 2.15 s (1.45 s with Reduce Motion), or when `phase` is ready, whichever is later. The library is then there at once, a little large, and settles as the tiles leave it. When it is false the library's opacity follows `phase`, as before. The gate is false under tests, with `-storageRoot` or `-skipLaunchAnimation`, and for any scene but the first of the process, so UI tests and a second window see the library at once. Nor is the splash raised when the launch is about to show something (`OwlLunaRoot.opensSomething`): an action already pending, a link that arrived first (`LaunchCurtain.hurry()`), or a window that `WindowMemory` or its scene storage says had a notebook open.
- `LaunchCurtain`, in the environment, is what the library knows of the splash. While it is up, `LibraryRootView` holds whatever it would present, a reopened notebook, a pending action or a link, and asking (`holds()`) hurries the splash: the tiles leave as soon as the app is ready, or, if none has come into view yet, the splash is simply over. When the curtain drops the library carries out what it held. What a link or a shortcut asked for before the app was ready is shown in place of the notebook the window would have reopened.
- The splash (`Launch/`) keeps no state: `BentoSplash` draws whatever a `SplashClock` says, and `LaunchOverlay` owns the clock, moved on from a `TimelineView` by at most 50 ms a frame. A tile's motion and everything inside it are `SplashBeat`s and `SplashTrack`s read at that time, so a frame can be drawn at any moment, and the board, the curves and the clock's stepping are tested without waiting (`BentoSplashTests`).

## Storage v2

Each notebook is a package at `Application Support/Library/<uuid>.owlluna/`. An older build named them `<uuid>.scribe`; `StorageRoot.adoptLegacyPackages` renames those in place (one that already has a `.owlluna` successor, and anything not named by a UUID, is left alone) and runs first thing in `AppModel.start` and on a restored backup, so a Library copied into the container by hand, or an old `.scribebackup` restored through Settings, opens as normal. A rename that fails is logged (`storage` category) and the package left where it was. `packageIDs()` lists `.owlluna` only. iCloud sync does not adopt them: the container is new under this name, and a `.scribe` there would never match `cloud.package(id)`; `SyncTests` pins down that one is neither pulled nor deleted.

```
manifest.json          schemaVersion, title, cover, defaults, pages, recordings, library state
manifest.prev.json     the previous manifest, the fallback if the latest can't be read
ink/<pageID>.pkdrawing page-local ink, one file per page
assets/                imported PDFs, photos, audio
thumbs/                page thumbnails keyed by ink hash and page appearance
text/<pageID>.txt      recognised handwriting and PDF text, stamped with the ink hash it came from
cards.json             the notebook's flashcards and when each is next due
cards/                 clippings shown on flashcards (PNG)
```

### Writing

- `NotebookPackage` is an actor that does all file IO.
- A save writes only the dirty pages, each atomically, and writes the manifest last.
- A failed save keeps the pages dirty and retries with backoff (1 s, doubling, capped at 60 s), and shows a non-blocking notice.
- When the app goes to the background, pending writes finish under `beginBackgroundTask`.

### Reading and recovery

- **Tolerant decoding.** Unknown keys, unknown enum values and malformed fields never fail a manifest. Their raw JSON is written back unless the app changed them. Pages this build can't read are kept in place, and a newer schema opens read-only.
- **Quarantine.** A file that fails to decode is renamed to `.corrupt` and never overwritten. PencilKit returns an empty drawing for data without its `wrd\xf0` header instead of failing, so that case counts as damage too.
- **Crash between ink and manifest writes.** Ink files newer than the manifest are recovered as pages, and a stale hash is corrected.
- **Newer schemas.** The schema version is read first. A newer manifest opens read-only even if its page list has a shape this build can't read, and is never quarantined or rebuilt. The library hides changes for read-only notebooks.
- **Nested fields.** Unreadable values inside the cover, defaults, library state and recordings are written back as they were unless the app changed them, like top-level ones.

### Garbage collection and deletes

- On close, after a successful save, files no page or asset reference uses are removed. An asset is kept if its name appears anywhere in the manifest, including fields this build can't read. A transcript's search text is kept while its recording has a transcript.
- Nothing but stale thumbnails is removed while a damaged manifest is set aside, or after a manifest was rebuilt from ink, since the damaged copy may be all that lists those files.
- Background jobs (OCR text, thumbnails) never recreate a deleted package.
- Deleting permanently renames the package into `Deleting/` and removes it in the background; leftovers are swept at launch.

### Writing history

- `Library/activity.json` is the private writing log behind the library's This-week strip and the writing calendar: `{version, days: {"yyyy-MM-dd": {notebooks: {<notebook id>: [<page id>]}, otherPages}}}`.
- It is recorded after a save, not at stroke end: `NotebookDocument.onInkSaved` reports the pages the save left holding ink, and `WritingActivity` writes the file off the main thread, debounced by 3 s and flushed when the app leaves the foreground.
- Day keys are Gregorian dates in the local time zone. Page lists older than 400 days, and pages of permanently deleted notebooks, are kept only as counts in `otherPages`.
- It is read tolerantly like a manifest: unknown keys and unreadable days are written back, a file that isn't a JSON object is quarantined, and a newer version is never rewritten. Manifests and the SwiftData index are untouched, so older builds ignore it.
- Settings › Writing History turns recording off or clears the file.

### Library index

- SwiftData holds the library index (`LibraryIndexSchemaV5`): notebook records with their cover fields, whether they are locked and the tags they and their pages carry, folders, and one `NotebookSearchText` row per notebook. Search text is not a relationship of the record, so the shelf's queries never read it; a search fetches only the IDs of matching titles, tags and text rows (`LibraryIndex.notebookIDs`).
- A store written by an earlier schema migrates in place: a lightweight stage drops the record's search text and adds the table, another gives folders their parent, a third adds the lock and a fourth (V4 to V5) the tags, both of which the first refresh afterwards reads from every manifest. The refresh that follows gives every notebook without a row its text from the package's `text/` files, the same way a rebuilt index gets it.
- It is rebuilt from the manifests and `folders.json` whenever they are newer.
- **Folders inside folders.** A folder's `parent` is a key in `folders.json` and `parentID` in the index; an older build keeps the key and shows the folder at the top level. `FolderTree` turns the flat list into sidebar rows and answers what is inside what. A folder whose parent is missing, or whose parents loop, is shown at the top level, so a damaged file never hides one. Folders are numbered in sidebar order after every change, parents before their children, so a plain sort by index is that order. Deleting a folder moves its notebooks and its folders up to the folder it sat in. Nesting stops at five levels.
- An index that can't be opened is set aside and rebuilt; there is no `fatalError` at launch.

### Backup and restore

- **One file.** `LibraryBackup.create` writes `Library/` (every package, `folders.json`, `smart-shelves.json`, `activity.json`) and `Stickers/` into an Apple Archive compressed with LZFSE, named `OwlLuna Backup <date>.owllunabackup`, with a small `backup.json` (version, date, the daily journal's ID). Open notebooks are saved first. `thumbs/` folders are left out; they are a cache.
- **Restore only adds.** The archive is unpacked into a temporary folder (entries with absolute paths or `..` are skipped, and symbolic links are removed), then merged: a notebook the library doesn't have is moved in under its own ID; one that is identical (same modification date and pages) is left alone; one that differs is moved in under a new ID as "Title (from backup)", so nothing in the library is ever replaced. Folders and smart shelves the library lacks are appended, stickers are added by file name, and the writing history is merged day by day. The index is refreshed afterwards, which also reads the restored notebooks' search text.
- A backup from a newer version is refused, not half-read.
- **Old backups.** A `.scribebackup` is still a backup: the `com.owais.owlluna.backup` type in `Config/Info.plist` lists both extensions, so Files and the importer accept it, and its `.scribe` packages are adopted as `.owlluna` after the version check and before they are merged.

### iCloud sync

Experimental: everything below is tested with a plain folder standing in for iCloud (`SyncTests` plays two devices against it, and `SyncUITests` launches the app twice with two storage roots and `-cloudFolder`). It has not run against a real iCloud container.

- **The library never moves.** The app always works in `Application Support/Library`. Sync (`LibrarySync`) copies whole notebooks between that and a folder in the app's iCloud container (`<container>/Sync`), so the editor never reads a file that iCloud hasn't downloaded, and turning sync off changes nothing on the device. The default entitlements carry no iCloud keys; `Config/OwlLuna-iCloud.entitlements` adds them. Without them the container doesn't resolve and Settings says so.
- **One rule per notebook.** A small file on the device (`sync-state.json`) remembers each notebook's modification date the last time both sides agreed. From the three dates (here, there, agreed): unchanged here and changed there is pulled; the reverse is pushed; changed on both is a conflict. In a conflict the newer version keeps the notebook's ID everywhere and the older is kept as a notebook of its own, "Title (conflicted copy)", so nothing written is lost. Nothing is merged inside a notebook.
- **Deletes.** A notebook that was in step and is gone from the device was deleted here: a marker goes in `Deleted/` and the synced copy is removed. Another device removes its copy only if it hasn't changed since they agreed; one that has been written in since is uploaded again and the marker removed.
- **Copying.** A push mirrors the package into the container: files that differ are copied (through a temporary name, then swapped in), files that are gone are removed, the manifest goes last, and `thumbs/` and files set aside as damaged stay behind. A pull assembles the notebook beside the library, checks its manifest reads, and swaps it in whole. Writes to the container go through `NSFileCoordinator`.
- **Folders and stickers** are merged three ways on which ones exist, using the sets remembered from the last sync, so an add and a delete on different devices both carry over. For a folder both sides have, the more recently written `folders.json` wins. The writing history and the smart shelves are not synced.
- **When.** `SyncCenter` syncs at launch, when the app comes to the front or leaves it, a few seconds after any change to the library index, and when the container reports new manifests (`NSMetadataQuery`). A notebook open in an editor is skipped until it closes; a notebook whose manifest can't be read yet waits. After a sync that changed the device the index is rebuilt from the files.
- **Not done:** live updates to a notebook that is open on two devices at once, and progress for large uploads.

### v1 notebooks

The converter for notebooks from the first version (`V1Migrator`) was removed on 2026-10-01. Notebooks it already converted keep working. Anything v1 left on disk (an unconverted store, `Backups/v1`, a notebook's `legacy-v1.txt` search text) is left untouched and the app no longer reads or manages it, except that `legacy-v1.txt` still counts towards search like any other text file.

## Background work and caches

- **Off the main thread:**
  - thumbnails (`PageThumbnailer`, cached in `thumbs/`);
  - covers (`CoverRenderer` and `CoverCache`: an 80 MB memory LRU plus `Caches/Covers`, kept under 150 MB). Renders stop when their cell scrolls away, disk hits are decoded before they reach the main thread, and the New Notebook preview never touches either cache;
  - the time-lapse video (`InkTimelapse`) and speech recognition (`DeviceTranscriber`);
  - PDF export (`NotebookExporter`): streamed to disk a page at a time, with progress; cancelling or dismissing the sheet stops it. Pages can also be exported as PNGs, one file a page at twice its size in points;
  - handwriting OCR (`HandwritingIndexer`, per page by ink hash). Rendering and Vision run off the indexer actor so an edit's cancel gets through, and a page already being read is never read twice;
  - library search: debounced, matched by a SwiftData predicate on a background context, then each matching notebook's per-page text is read for page-level results (`PageSearch`) that open the editor at that page. Results refresh whenever the index is saved;
  - PDF parsing on import.
- **Tile culling.** Paper templates draw only the rules that reach the context's clip (`TemplateRules`), so a 512 px tile at 5× strokes its own few lines, not the page's; planner labels are cached Core Text lines. Diagonal rules are laid in short pieces on a fixed grid, because Core Graphics rasterises a long diagonal slightly differently depending on where the clip starts. `PaperParityTests` holds the original papers pixel-identical and every template equal in tiles, thumbnails and export.
- **Bounded caches:**
  - PDF documents: an LRU of 6;
  - page images: an LRU of 12;
  - thumbnails: an LRU of 120;
  - paper miniatures for the paper drawer and New Notebook: an LRU of 64;
  - loaded ink: 24 clean pages. Unsaved pages are never evicted.
- **Signposts** (`OSSignposter`, subsystem `com.owais.OwlLuna`):
  - "Open to first ink", "Save", "Thumbnail", "OCR page", "Export", "Cover render", "Launch".

## v1 and v2, before and after

Same run for both columns.

- **Environment:** "OwlLuna Bench" iPad Pro 11-inch (M5) simulator, iOS 27.0, Debug build in Swift 6 language mode, on an Apple M4 Mac mini at load average 3–4.
- **Method:** XCTest in-process timings (`OwlLunaTests/PerformanceBaselineTests`, run with `OWLLUNA_PERF=1`), medians unless noted. The v1 column was measured on the v1 code before it was removed in M6; the suite now runs the v2 cases only.
- **Fixtures:** heavy is 100 Letter pages × 500 strokes with a 1,000-stroke first page for v2's stroke-end cases; typical is 20 × 400.

None of these are device numbers. Pencil latency and hitches need the device checklist.

| Measure | v1 | v2 | Target |
|---|---|---|---|
| Main thread at stroke end (heavy) | 6.0 ms (copies the whole notebook's drawing out of the single canvas) | 0.12 ms; 0.12 ms for a stroke crossing the page edge; 0.12 ms in a 10-page notebook | ≤ 0.5 ms, flat |
| Autosave, main thread (heavy) | 124 ms (serialise and write the whole notebook on the main thread); typical 31 ms | 0.48 ms per save (snapshot 0.008 ms); 1.8 ms median, 2.8 ms max when the save also updates the library index | ≤ 2 ms |
| Insert a page at the start (heavy) | 332 ms (re-maps every stroke); typical 25 ms | 1.2 ms including relayout, undoable | ≤ 5 ms |
| Move page 0→50 / delete / undo (heavy) | not measured in v1 | 0.96 / 0.45 / 0.97 ms | ≤ 5 ms |
| Open heavy: longest main-thread block | 125 ms (load and lay out, all synchronous), plus 35 ms first render | 5.8 ms | ≤ 30 ms |
| Open heavy: to first ink | ≈ 160 ms | 71 ms | ≤ 100 ms |
| Open a 300-page PDF: longest block / first ink | 14 ms (synchronous) | 5.5 ms / 28 ms | |
| Export 20 pages | 1.13 s on the main thread | 1.11 s off the main thread; longest main-thread gap 2.5 ms (the probe's resolution) | never blocks |
| OCR 3 pages | 2.6 s | 3.0 s in the background; unchanged re-run 0.3 ms | |
| Library of 500, in-app scroll at 2,400 pt/s, 6 s | not measured | 0 long frames of 360, both passes | no hitches |
| 300-page PDF, in-app scroll at 2,400 pt/s, 6 s | not measured | 0 long frames of 360, both passes | no hitches |
| Peak footprint (test process, excludes GPU) | opening heavy: 528 MB | scrolling heavy: 516 MB (baseline 365), at 5×: 520 MB; scrolling the PDF: 486 MB, at 5×: 510 MB | bounded |

"Long frame" means a frame over 1.5× the display interval, counted by the debug frame-pacing probe (`-framePacing`). Swipes driven by XCUITest add two or three long frames each from its own snapshots, so the in-app scroll is the figure to compare.

## Swift 6

All three targets build in the Swift 6 language mode with no warnings. Two things matter at runtime:

- `CATiledLayer` calls `draw(_:)` on background threads, so both tiled views mark it `nonisolated`.
- A new window is laid out by whichever thread commits a Core Animation transaction first, and the tile threads commit their own. The second screen's window is created while tiles are being drawn, so its first layout could land on a tile thread, where the main-actor check traps. `ExternalDisplay.open` lays the window out and flushes the transaction on the main thread as soon as it is shown, and the stage's `viewDidLayoutSubviews` is `nonisolated` and defers to the main thread if it is ever called off it.
- `CanvasUndoProxy` keeps its notification tokens `nonisolated(unsafe)`: they're only read again in `deinit`, when nothing else can reach them.

## Colour and accessibility

- `inkSecondary` is for decoration, large text, borders and icons only. Small labels and metadata use `textSecondary`, which keeps 7:1 on paper, desk and surface in light, dark and Increase Contrast, so anti-aliased small text still clears Apple's audit (`DesignTokenTests`).
- `AccessibilityAuditUITests` runs Apple's full audit over the empty and seeded library, search results, Recently Deleted, New Notebook, Settings, Change Cover (sheets at both ends of their scroll), the editor, the paper drawer (only its top at the large text size, where the audit misreads rows it scrolls back into view), the page navigator and its Outline tab, the sticker drawer, a selected sticker with the arrange bar, a text box being typed in, the link sheet's three tabs, a selected link, focus mode, the presenter notes sheet, presenting with and without the presenter view, selecting ink, Recordings empty and with a recording, the Open Beside picker, two notebooks in one window, a replay, study tape selected and lifted, selected ink, the handwriting-as-text sheet, the video export sheet, a recording's transcript before and after it is written, a replay with the transcript beside it, the handwriting sheet with a translation showing, the find bar with a match marked, the zoom window, today's events on a page, a scanned page, and a locked notebook's lock screen and blurred cover, in light, dark and both with Increase Contrast (`-increaseContrast` sets the trait override), then Dynamic Type, clipping and contrast again at a large text size. A few issues are logged rather than failed: text on the system glass bars, text behind a sheet that VoiceOver skips, unnamed contrast issues on a sheet scrolled so text sits under its glass bar, and Dynamic Type on the last row and footer of the Settings Form and on the hint under a transcript, which the audit flags whatever they contain (all scale fully at the largest size). In a scrolled Form, a named row the audit pulls out from under the bar is sampled for contrast mid-scroll and is logged too; its colours are checked in the pass before the scroll. A one-line text field on a floating bar (the find field) is logged for clipping: it scrolls what doesn't fit.
- Text typed on a page is logged, not failed, for Dynamic Type: its size is the user's choice and it zooms with the page, as ink does. The controls round it scale as usual.
- The audit runs in portrait: in landscape the iPadOS 27 simulator hands it a rotated screenshot, so contrast is sampled from the wrong pixels. It also skips text a sheet or the undo slip covers, text cut by the screen edge, text inside cover and page images, contrast in the paper popover (iPadOS reports its content about 49 pt low) and contrast inside sheets at the large text size. It also logs contrast reports for text on the editor's floating bars, which it makes on some runs whatever the colours (their pairs are covered by `DesignTokenTests`), and text-size reports that name no element. Each real failure prints an `AUDIT FAIL` line.
- In a scrolled sheet, named text just below the glass bar sits in the bar's fading edge and is logged, not failed, for contrast; so is unnamed clipped text there. The divider between two notebooks is 14 pt, so VoiceOver's handle for it is a separate 44 pt element laid over it that takes no touches. At the largest text size the title menu is a list and the two-notebook screens are skipped; they are audited at the default size.
- Layouts that change with text size use `AnyLayout`, not `ViewThatFits`: the audit can't follow text across `ViewThatFits`'s two copies and reports it as partly unscaled.
- No text uses `caption2`: the audit reports it as partly unscaled, so the smallest style is `caption`.
- A button holding both text and a light image (a paper miniature, a light cloth) is read as low-contrast text, so captions sit outside their button, as a cover's meta line does, and paper colour chips are filled with their own colour.

## Languages

- Every string the app shows goes through `String(localized:)`, a SwiftUI text literal or a `LocalizedStringResource`, and is translated in a string catalog: `OwlLuna/Resources/Localizable.xcstrings` for the app, `InfoPlist.xcstrings` for the permission prompts and file type names, `AppShortcuts.xcstrings` for the Siri phrases, and `OwlLunaWidgets/Localizable.xcstrings` for the widgets. English is the source language; Spanish, French and German are filled in.
- Names stored in a notebook are never translated values: paper templates, colours, stickers and cover styles are stored by their raw values and only their display names are localized.
- A count is one string with plural variations in the catalog ("%lld pages" has a form for one and a form for the rest), never a "1 page" string chosen in code, so a language with more plural forms only needs its forms filled in. A sentence with two counts, or a count beside other values, varies through substitutions, and each language picks the count its words agree with (in French "1 trait écrit sur 5" agrees with the strokes written, in German "1 von 5 Strichen" with the total). `PluralTests` reads the built tables and fails if a count is spelled out for one again.
- `LocalizationUITests` launches the app in each language and checks a few known strings; the accessibility audit runs in English only.

## Known limits

- Undo keeps whole-page drawings. The number of steps shrinks as the pages being edited get heavier: 200 steps for light pages down to 20 for pages whose saved ink is over about 2.4 MB (`UndoBudget`, a 48 MB budget). The budget is an estimate and should be checked against a device memory trace.
- PencilKit's own lasso and ruler are page-scoped: each page is its own canvas, so neither can span two pages, and ink past a page edge is hidden. Selecting ink across pages is a mode of the editor instead (see "Selecting ink across pages"). The ruler can't be done that way: its position and angle aren't readable or settable, and a stroke can't leave its canvas, so a ruler across pages would have nothing to rule.
- ⌘F is claimed by a first-responder view in the library (the toolbar search swallows it otherwise). In the iPadOS 27 simulator under XCUITest, ⌘F never reaches the app at all while ⌘G on the same view does, so it needs a check on a device.
- iCloud sync has only run against a folder standing in for iCloud (see "iCloud sync"). Downloading files that iCloud has evicted, file coordination with the iCloud daemon and the metadata query are written but have never executed.
- Transcription has only run with a scripted stand-in (`-fakeTranscript`): the simulator has no on-device recogniser. How the real recogniser reports a long recording, and whether its words carry their times, needs a device.
- The second screen has been checked with a stand-in window (`-secondScreenInset`), not with a display: the simulator's external display can't be attached from a test. Lifting a subject out of a photo runs on a Mac with the same code but not in the simulator. Both need a check on a device.
- Several features run in tests through stand-ins because the simulator lacks the hardware or the service: scanning (`-fakeScan`, no camera), Face ID (`-fakeUnlock`), translation (`-fakeTranslate`), the calendar (`-fakeCalendar`). The code round each is tested; the camera, the biometric prompt, the translator and the calendar's permission prompt need a device.
- Tabs, PDF text and the tool tray have only run in the simulator. The tray's tools have never been used with a Pencil: hover, pressure, the eraser's widths, and double-tap and squeeze switching tools with no system picker all need a device. So do the ink dish (whether a squeeze's hover pose puts it under the tip) and Handwriting to Text with real handwriting, which has only read block letters drawn by a test. Selecting text with a Pencil, a highlighter stroke snapping under a real hand, the tab shortcuts on a hardware keyboard, dragging a tab with a finger or a pointer, and how many open tabs a device's memory carries all need a device. PDF text has been tried on generated PDFs; scanned PDFs have no text to select, and PDFs with columns, right-to-left text or turned pages have only been covered by a unit test of a turned page.
- Two windows have only been tried one at a time. `TabsAcrossWindowsUITests` opens a second window with a debug hook (`-windowButtons`, which also reads out only the window in front), and the simulator shows one window full screen. Two windows on screen together, in Split View or Stage Manager, where a notebook can be opened in one while a picker is up in the other, need a device.
- The zoom window has only been written in with simulated touches. Whether the rest before it moves on (0.8 s) and the size of the band feel right with a Pencil needs a device. The tool tray stands on the strip while it is open.
- The Control Center buttons build and their relay is tested, but pressing one from Control Center has not been tried. Spotlight indexing is skipped in test libraries, so what Spotlight shows has not been seen.
- Every figure above is from the simulator. The device checklist covers Pencil latency, hitches (Instruments), memory at 5× with the heavy fixture, palm rejection, and Pencil double-tap and squeeze.

