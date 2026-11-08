# OwlLuna architecture

How the app is built and why. The README says what each feature does, [DESIGN.md](DESIGN.md) covers the visual system and [DEVICE-CHECKS.md](DEVICE-CHECKS.md) lists what still needs a real iPad.

## Editor: one canvas per page, in a UIKit page stack

We chose this in Phase 2 (M1) after timing three designs against the same fixtures.

### The three designs

- A: a `PKCanvasView` per page in a zooming `UIScrollView` page stack. Only the visible pages ±1 have a canvas, re-scaled after each pinch.
- B: a `PDFView` with templates drawn as PDF pages and a `PKCanvasView` overlay per page.
- C: the v1 single canvas, fixed: no per-stroke copy, saves off the main thread, ink stored per page.

### Measurements

Each design was built in its own worktree against a shared harness, then timed one at a time on an iPad Pro 11-inch (M5) simulator, iOS 27.0, Debug build, M4 Mac mini at load average 6 to 9. Figures are XCTest in-process medians. "Heavy" is 100 Letter pages × 500 strokes with a 1,000-stroke first page.

| Measure (simulator) | A: per-page canvases | B: PDFKit overlays | C: fixed single canvas |
|---|---|---|---|
| Main thread at stroke end, 1,000-stroke page, 100-page notebook | 0.12 ms | 0.13 ms | 0.03 ms |
| Autosave, main-thread part (heavy) | 0.13 ms | 0.15 ms | 4.5 ms |
| Insert page at start (heavy) | 3.1 ms | 14.7 ms | 114 ms |
| Move page 0→50 (heavy) | 4.0 ms | 19.5 ms | 107 ms |
| Delete page (heavy) | 0.6 ms | 0.6 ms | 104 ms |
| Open heavy: longest synchronous block | 15 ms | 18 ms | 9 ms |
| Open heavy: to first ink | 49 ms | 75 ms | 629 ms |
| Peak footprint scrolling heavy / at 5× | 356 / 411 MB | 283 / 210 MB | 531 / 473 MB |
| Ink at 1×, 2.5×, 5× and after a pinch | re-rendered sharp | sharp only with a counter-scaled canvas hack | re-rendered sharp |

The simulator can't measure hitches: `XCTOSSignpostMetric.scrollingAndDecelerationMetric` reports only the swipe's duration and `XCTHitchMetric` records nothing, so the debug frame-pacing probe (`-framePacing`) stands in until a device run. `phys_footprint` leaves out GPU memory, and B's lower figure comes from PDFKit tiling well, not from its ink.

### Decision

A. It is the only design that meets every main-thread target (page operations under 5 ms, first ink under 100 ms, autosave on the main thread under 2 ms), and it keeps full control of layout, zoom and the desk.

C was rejected because every page operation and first render is O(notebook), and one canvas holding every stroke can stall VoiceOver. B was rejected because it reaches into PDFKit's private scroll view, and PDFKit only transform-scales overlays, so sharp ink needs a counter-scaling hack that re-renders after the zoom settles. Its pinch also overshoots the maximum zoom, and its page operations take 15 to 20 ms.

A's weakness is simulator footprint at 5×. The tiling and canvas windowing below answer it, still to be confirmed on a device.

## How the editor works

`PageStackController` runs a `UIScrollView` of page slots laid out in page points (`PageStackLayout`). Slots exist only for the visible pages ±1, so page operations cost O(visible pages). Paper is `PagePaperView`: 512-pixel tiles drawn on their own queue and shown in plain layers, only near the viewport, because paper covering each whole page grew to about 900 MB at 5× in the spike.

Each live slot has a `PageCanvasView`. Its drawing is in page-local points and its frame is a viewport-sized window onto the page, so PencilKit only backs what can be seen, even at 5×. A pinch magnifies the content view, and when it ends the zoom is baked: the layout is rebuilt at the new scale and each canvas's `zoomScale` set, so PencilKit re-renders the ink sharply. The scroll view takes direct touches only, so the Pencil never scrolls.

When the view changes size, a new height (the tabs, a bar or a keyboard coming or going) moves nothing and bakes nothing. If the top edge moved, the scroll moves with it, so the ink stays still on the screen. A new width keeps the same point of the stack at the same share of the view, at the same zoom: a text box being typed in, a selection, Find's match or the zoom window's outline if one shows, the top of a page just gone to, or else the middle of the view. While the width keeps changing, as a divider or a Stage Manager window is dragged, the content view is magnified the way a pinch does it and baked once the width has rested for 0.3 s, or at once if it is off by more than √2. Presenting, a replay and an open whiteboard keep their own place, and so does the layout before the view first appears.

Each slot clips its canvas, so ink past the page edge is kept but never shown. Masking at stroke end instead copied every stroke on the page per stroke and clipped lasso-moved ink for good. Pages with a live canvas are pinned in memory, so the ink a stroke replaces is there for its undo.

`NotebookDocument` owns one `UndoManager`, and everything registers against the document, never a view, so undo survives canvas recycling. Each canvas returns a `CanvasUndoProxy` as its undo manager: PencilKit wraps each stroke's registration in its own group and calls private grouping API, and the proxy absorbs that and forwards undo and redo to the document. Filtering those registrations on the shared stack left an empty step per stroke, and deferring the group crashed. Undo hands the canvas a drawing with no history (`PKDrawing(strokes:)`), because given an earlier version of a drawing it has seen, PencilKit brings the later strokes back.

At stroke end the main thread copies the page's drawing into the document, bumps the page's version, registers undo and schedules a save. The modification date is applied at save time, so a stroke never touches the observed manifest.

SwiftUI builds a body on the main thread's stack (1 MB on an iPad, 8 MB in the simulator), and a debug build copies a view's whole value at every chained modifier. The editor's page, bar and fifty-odd sheets took 1,051 KB of stack, so it crashed on an iPad as soon as a notebook opened. `EditorContent` puts that layout and each bar menu behind `AnyView`, so only a pointer is copied (about 325 KB to open a notebook now). New sheets and menus go behind the same wrappers.

## Draw and hold

PencilKit doesn't say how a stroke ended, so `StrokeHoldRecognizer`, a recogniser on the page stack that never recognises, records how long each touch rested before lifting (`TouchRests`). After a 0.45 s rest `ShapeRecognizer` looks for a line, an arrow, an ellipse or a polygon, and `ShapeSnap.snapped` rebuilds the stroke with each corner point given three times, because PencilKit draws a smooth curve through its control points. It lands one run-loop pass later, after the stroke's own undo group has closed, so the first Undo gives back the hand-drawn stroke.

Circle and hold uses the same rest, and `pencilGesture` sees the stroke first. A closed stroke with ink inside selects that ink, unless it straightens into three or four sides (`PencilGestures.keepsFigure`): a box or triangle round a formula is kept. In strokes drawn in code, loops round words read as ellipses or as five to twelve sides, and almost never as four. The loop goes into the document, then a second step, Circle to Select, takes it off as the selection starts, so Undo gives it back and leaves Select Ink. If the loop reads as an ellipse, the Select Ink bar offers Keep Circle, which undoes that step and straightens the loop. Tests have no touches, so they set `StrokeHoldRecognizer.nextRest`.

On iPadOS 27 PencilKit opens its own menu (Select All, Insert Space) when a finger is held on handwriting, and a resting palm counted as that finger. `LoneFingerHoldGuard`, a recogniser on every `PageCanvasView` that PencilKit's named holds are made to wait for, fails only for one fingertip alone (`LoneFingerHold`); a wide touch, a second finger or the Pencil's hand makes it begin instead, which keeps the menu shut.

PencilKit draws a pen's, fineliner's or fountain pen's nib 2 pt narrower all round than its point size, so `ShapeSnap.pointSize(for:)` sizes the points of a shape drawn from the tray to match a hand-drawn stroke. Those sizes were measured with a finger and need a Pencil check.

## Pictures, stickers and bookmarks

A page's `items` (back to front, in page points) and its `bookmark` are extra fields on the page in the manifest, so older builds keep them as unknown fields. An item of an unknown kind is kept and not drawn.

`PageItemRenderer` draws items between the paper and the ink, so a sticker stays vector in a PDF. In the editor they are live views between the paper and the canvas, and the paper tiles skip them (`drawBackground(items: false)`), so moving one never redraws paper or touches the canvas. Each change is one undo step through `NotebookDocument.updateItems`.

A placed picture is stored once in `assets/` and read for search like ink. The page's text stamp ends in `+pic` and a hash of its pictures' files and crops (`PageItem.readingKey`), so cropping one re-reads the page and moving one doesn't.

User stickers live in `Stickers/` beside the library. Custom papers live in `Papers/`, one file each named `<name> <id>`, so the folder alone lists them and a rename is a move (`PaperShelf`). Placing either copies the file into the notebook's assets (`NotebookDocument.keepCopy` for papers), so a notebook stays self-contained and deleting the original leaves its pages whole.

## Text boxes and links

`TextBox` and `PageLink` are entries in the same `items` list, so they behave like pictures. `TextBox.height(width:)` and `TextBox.draw` share one attributed string (`typeset`), so a box wraps the same in the editor, a thumbnail and a PDF, where it stays real text. Typing happens in a `UITextView` over the box, scaled to the baked zoom so it wraps where the page does.

A box writes `text`, `fs`, `bold`, `color` and `align` as 1.0.0-build.2 does and leaves newer style fields out at their defaults. That build keeps fields it can't read but rewrites `text`, `fs`, `bold`, `w` and `h` by its own measure, so two fields put that right: `fit` fingerprints a styled box's size and text so a box that no longer matches is refitted on reading, and `checkedText` lets `checks(_:carriedFrom:to:)` move a checklist's ticks by a line diff.

A link's `destination` is a page, another notebook or a web address, stored under different fields (`target`, `notebook` and `page`, `url`) so an older build keeps one it can't read instead of showing a missing page. `LinkTitles` names unlabelled links by the target's bookmark or "Page N", so they stay right when pages move.

## Study tape

`PageItem.Content.tape` is an item like a sticker and the only one drawn over the ink (`isOverInk`, `PageRenderer.drawOverInk`, `PageSlotView.raiseTape`). Lifting a strip only changes `EditorSession.liftedTapes`, which never reaches the document, so it has no undo step and a notebook always opens with its tape down.

## Flashcards

A notebook's cards are `cards.json` beside its manifest (`FlashcardFile`: a version, the cards, and `removed`), with clippings as PNGs in `cards/`. The manifest doesn't name them, so the document never writes them, garbage collection never sees them and a card change doesn't date the notebook. `CardFiles` sets an undecodable file aside as `.corrupt`, never writes a newer version's file, and refuses a write once the manifest is gone, so a review can't bring back a deleted notebook.

`CardFiles.Deck.merged` takes the copy of each card with the later `stamp`, keeps one-sided cards, and drops a card deleted at or after its stamp. Sync, restore and every write merge this way, so cards a sync brought in meanwhile stay. `CardSchedule` is SM-2 with three answers, and a card falls due on a calendar day rather than at an hour.

## Study guide

`AppleStudyModel` (behind the `StudyModel` protocol) asks Apple's on-device Foundation Models for main points and questions through guided generation. The model reads about 4,000 tokens, so `StudyGuide.chunks` cuts the text between lines into 3,200-character pieces. Tests use `ScriptedStudyModel` (`-fakeModel`).

## Focus and presenting

The app delegate hands an external display's scene to `ExternalDisplaySceneDelegate`, which only registers it with `ExternalDisplay`, so the screen mirrors the iPad until presenting starts. `PresentationStageController` renders each page once, within 12 megapixels, and then only receives the visible part (`PresentationStage.pageFrame`) and the laser as fractions of the page. Presenter notes are a page's `notes` field. They aren't part of its `appearanceKey`, so thumbnails and exports never show them.

Showing one page at a time is a layout choice (`PageFlow`, kept in `UserDefaults` as `pageFlow`), not an editor mode: `PageStackController.setPageFlow` lays out the one page and turns to the next or previous on a swipe, so writing, find, select and the zoom window all work inside it. Presenting is the mode that locks editing.

## Selecting ink across pages

PencilKit's lasso can't leave its canvas, so this is an editor mode. `EditorMode.selecting` lays `InkLassoOverlay` over the page stack, and `InkLasso.moved` moves a stroke whose middle lands on another page into that page's drawing. `NotebookDocument.updateInk` replaces every affected page's ink with one undo step, and refuses a page whose ink isn't in memory; the lasso only reaches pinned pages.

## Handwriting to text

`InkText` renders selected strokes as dark ink on white at up to 3× and reads them off the main thread with the Vision request search uses. Replacing the handwriting removes the strokes and adds a text box (`InkText.box`) in one run-loop pass, so it is one undo step. `InkTranslation` sends the text to the system translator line by line and puts each line back where it stood. `-fakeTranslate` stands in for the translator, which the simulator lacks.

## Recording

An `.m4a` is only playable once closed, so a crash would lose it. `AVAudioRecorder` writes ADTS AAC (`.aac`), where every frame has its own header, and `RecordingFile.remux` copies the packets into an `.m4a` when recording stops.

The entry goes into the manifest's `unfinishedRecordings` and is saved at once, so garbage collection keeps the file. Opening a notebook adopts an unfinished entry only on the device that made it (`StorageRoot.deviceID`), since elsewhere the recording may still be running. Sync won't pull a copy that lacks this device's unfinished entry (`losesRecording`).

`AudioSessionOwner` is the only thing that changes `AVAudioSession`. While a recording runs nothing else plays, because playback under `playAndRecord` would record the speaker. `BackgroundRecording` stops a locked notebook's recording when its window goes to the background, so nothing is recorded behind a lock. A recording is never resumed after an interruption, even with `shouldResume`, because replay times ink from the recording's start and a gap would put it out of step.

No file asks for more than the default protection (`completeUntilFirstUserAuthentication`), so recordings and saves can be written while the iPad is locked; with `complete` they would stop about ten seconds after locking.

## Replaying a recording

Nothing extra is stored for the ink. PencilKit dates every stroke, and `ReplayTimeline` compares those dates with the recording's `startedAt` and length, reading only the `pages` it lists. Each canvas shows a copy of its drawing in which strokes still to come have 16% opacity (`ReplayInk`). The copies are new strokes, because a canvas keeps what it has drawn for a stroke it already knows. The editor's cover has `interactiveDismissDisabled`: with drawing off, a sideways drag dismissed it and skipped the save-and-close path.

## Transcripts

`DeviceTranscriber` runs `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, so nothing is sent to a server. Only settled results carry timings, so `Transcript.merge` replaces everything from the first new word's moment on, which works whether the recogniser resends the whole recording or only its latest stretch. A `Transcript` is a JSON file in the notebook's assets, named by the recording's `transcript` field, so it syncs and backs up with the recording. `-fakeTranscript` substitutes `ScriptedTranscriber`, since the simulator can't recognise speech on the device.

## Find in a notebook

`NotebookFinder` owns the query and the matches, each a page and a rectangle in page points. PDF pages are searched in their own text; handwriting and scans are read with Vision, whose `boundingBox(for:)` gives a box for any range. A page is skipped while its `text/<page>.txt` stamp still matches its ink and the text lacks the words, and `FindReader` caches each page's lines by ink fingerprint. `FindHighlightView` gives each match its own small layer, because one view over the whole page would be too large at 5×.

## PDF text

`PDFTextReader`, an actor, reads with PDFKit off the main thread, and only the latest answer is shown, so a drag never waits on an earlier one. Two PDFKit calls needed working round. Given a point off the text, `selection(from:to:)` picks a letter lines away or none, so `PDFText.settled` first moves each end of a drag onto the nearest line. `PDFPage.selectionForWord(at:)` ends the app when no `PDFView` is behind the page (seen on iPadOS 27), so `PDFText.word` finds the word with Foundation's word boundaries. Picture-only pages are read once with Vision into a `PictureText`.

Highlights are ordinary marker strokes (`TextHighlight.stroke`). The snapping highlighter checks a sideways marker stroke (`PDFText.runsAlongALine`) against the text and replaces it as its own undo step (`replaceLastStroke`, shared with draw and hold).

## Zoom window

`ZoomWindowPanel` holds a second `PageCanvasView` for the current page. Like every canvas it is a window onto the page, so its strokes are in page points from the start. Whichever canvas is written in, the document takes the stroke and the other canvas gets the same drawing (`mirrorInk`), so one undo reaches both. `ZoomWindow` holds the geometry. A stroke near the end of the area moves the window on by 55% of its width 0.8 s after writing stops.

## Tools

PencilKit's picker can't be restyled, can't hold the app's own items and floats over the page at a size of its own. Canvases only need a `PKTool`, so the app keeps its own tools.

A `ToolPreset` is a pen: ink kind (PencilKit's name), colour as four bytes, width. `ToolShelf` keeps up to eight in settings (`toolPresets`), and `Toolbox` holds the shelf, the tool in hand and the tray shortcuts (`toolbox`). Every pane and window shares one toolbox. `ToolTray` floats over the page: the page stack adds `toolsObscured` as bottom inset, so the tray takes nothing from the page's width.

Opacity is the last byte of `ToolPreset.color`, which was always RGBA, so older pens needed no migration. At night `ToolSwatch.onPaper` shows the opaque colour an ink has over white, since a faint ink over a dark well would look darker, not paler. Point sizes are PencilKit's own measure and differ by ink: a pen, fineliner or fountain pen under about 2 leaves no mark.

PencilKit's `.default` drawing policy follows the system's Only Draw with Apple Pencil switch only while its own picker shows, so `effectivePolicy` does the same for the tray. With no system picker the page stack handles Pencil double-tap and squeeze itself (`PencilToolMemory`); `-fakePencilSqueeze` stands in for the squeeze.

Handwriting to Text tracks strokes by their path's creation date, PencilKit's only lasting identity for a stroke (`PageStackController.noteWriting`). Reading starts after `InkTyping.lookAhead` (0.4 s) of rest and the text is placed at `InkTyping.pause` (1 s), so recognition overlaps the pause. `InkText.warmUp` runs when the helper turns on, because a cold Vision read took 0.8 s against 0.37 s warm. `-scriptedInkText` and `-inkTypingPause` stand in for the recogniser in UI tests.

## Whiteboards

A whiteboard is a `NotebookPage` marked `board`, 40,000 points square. Ink and items are in the board's own points and never move, so undo, replay, links and saved ink need nothing special. Nothing is backed at that size: the canvas is already a viewport window, paper is tiles near the viewport, and the overlays are layers without a backing store. PencilKit was checked at this size on the iPadOS 27 simulator at 1× and zoomed out; 5× has only been laid out.

A sheet that large can't stand in a stack fitted to the widest page, so `PageStackLayout` has two states: with `solo` nil a board is a card (`BoardCardView`), and with `solo` set it fills the content. `scrollToPage` is the only way in and out, so links, replay and find cross over without knowing. Renderers draw a piece (`Whiteboard.piece(of:in:)`, with `cut` as its corner) and only `page.inkRect` of the ink, so ink is never transformed.

## Scanning

`DocumentScanner` wraps `VNDocumentCameraViewController`, and each scan becomes a page background, a JPEG of at most 2,400 px, read for search with Vision (stamp suffix `+img`). A PDF page with fewer than 40 letters and digits (`PDFText.isPicture`) is read the same way (`+pdf`). `-fakeScan` stands in for the camera.

## Locked notebooks

The lock is a flag, not encryption: `library.locked` in the manifest and `isLocked` in the index. Locking stamps `library.changedAt.locked` instead of dating the notebook, so sync settles it as library state. `NotebookLock` asks with `LAContext` and keeps unlocked notebooks in memory only. The library asks before opening one, and `EditorScreen` lays `LockedNotebookView` over every other way in and whenever the scene isn't active, so pages never show in the app switcher. `-fakeUnlock` and its variants stand in for Face ID.

## Today's events

`Agenda` writes the day's events as an ordinary text box; nothing else is kept. On the journal the box carries an `agenda` mark holding the printed words, so a re-dated page drops its old events unless the box was edited. `-fakeCalendar` supplies three events.

## PDF export

`InkVectors` draws ink as vector shapes. Pen and fineliner are stroked runs of round segments; the fountain pen is the union of convex hulls of its oval nib, one per step, all wound the same way so the union fills. PencilKit's nib has a radius of `size − 2`. Inks with grain or a soft edge (pencil, crayon, watercolour, calligraphy pen, highlighter) go in as PencilKit's own picture of that run, and the highlighter is multiplied in as on the canvas. `PDFExportTests` compares the shapes with PencilKit's rendering pixel by pixel.

A page range is `Input.narrowed(to:)`, which keeps the whole notebook so links use real page numbers. Searchable handwriting is `PageWords` writing each recognised word as invisible text under the ink, sized and sloped to the writing.

## Time-lapse video

`InkTimelapse.Plan` orders strokes by PencilKit's creation dates and gives each a share of the film by its drawing time, dropping the gaps. Finished strokes are painted once into a bitmap carried between frames, so a frame costs one stroke whatever the page holds. Frames go into an `AVAssetWriter` off the main thread.

## Widgets and shortcuts

Widget links (`owlluna://today`, `quicknote`, `continue`, `notebook/<id>`) and App Intents (`AppActions.swift`) become an `AppAction`, which the front window's `LibraryRootView` carries out after asking an open editor to save and close (`owlLunaCloseEditor`). Control Center intents live in `Shared/` so both targets build them, and only leave the request in the App Group's defaults (`ControlRelay`) for the app to pick up.

`SpotlightIndexer` sends only notebooks that changed, going by a stamp file in the caches folder; if iPadOS clears that file, the whole Spotlight domain is rebuilt. `WidgetBridge` writes a `WidgetSnapshot` into the App Group container. UI-test libraries (`-storageRoot`) never reach either.

## Tags and smart shelves

Notebook tags are `library.tags` in the manifest and page tags are `tags` on the page, both extra fields so older builds keep them. Page tags aren't part of `appearanceKey`, so tagging never re-renders a thumbnail. `Tags.key` folds case and accents, so two spellings are one tag. There is no table of tags: the sidebar counts them from the index's `tagsRaw` and `pageTagsRaw`.

Smart shelves are saved filters (`TagRule`) in `Library/smart-shelves.json` (`SmartShelfFile`). Each shelf stamps `changedAt`, and a save applies only changed shelves to the file as it stands (`SmartShelfFile.apply`), so one a sync brought in meanwhile survives.

## Two notebooks in one window

`EditorPanes` shows the window's editor and, when `EditorWindow.beside` is set, a second `EditorScreen` with its own document and undo stack. The picker leaves out notebooks open anywhere, so the one-editor-per-notebook rule holds. Closing the first pane asks the second to save and close first (`EditorScreen.beforeClose`), so a failed save in either keeps both up.

`WindowMemory` keeps a window's notebooks under its scene session's identifier the moment they change, because iPadOS writes `@SceneStorage` only on the way to the background, and an app stopped straight after would reopen what was open before. A window whose reopening crashed is skipped once at the next launch (`WindowMemory.setRestoring`).

## Notebook tabs

`EditorWindow.tabs` is the notebooks open in the first pane, and only the selected one has an `EditorScreen`. The registry holds documents weakly, so `EditorWindow.documents` keeps those of visited tabs, and coming back to a tab finds its undo history.

Only one window writes in a notebook. Anything that would show a notebook open in another window brings that window forward instead (`EditorWindow.goesToItsWindow`). Before the bar steps along or a tab closes, `letGoOfTabsOpenElsewhere` drops tabs another window has since opened, so the replacement is always writable here.

## One document per notebook

`DocumentRegistry` hands out one `NotebookDocument` per notebook across windows, and shares an open still in progress. Library changes (favourite, trash, folder, rename, cover) go through the open document. Opening waits for a change being written to a closed notebook's manifest, and one made while it opens goes to the document instead (`DocumentRegistry.startWriting`). A whole manifest written from an older read, a document's save included, keeps any library state the file has stamped later (`LibraryState.takeLaterChanges`), and the document takes it.

## Saving and closing

Saves are debounced by 1.2 s but always start within 5 s of the first unsaved edit. Pending and retry saves hold their document, so a change made as the editor closes is still written. If saving keeps failing the editor stays open; closing anyway leaves the document retrying in the registry, where reopening finds it. Saves touch the library index only when something the library shows changed.

## Launch

`AppModel.start` runs once and later callers wait for it. It adopts `.scribe` packages, sweeps `Deleting/`, refreshes the index and loads shelves, history and flashcards, then sets `phase` to `.ready`.

`LaunchAnimation.isEnabled` is false under tests, with `-storageRoot` or `-skipLaunchAnimation`, and for any scene but the first. The splash is also skipped when the launch is about to open something (`OwlLunaRoot.opensSomething`). Otherwise `LaunchOverlay` plays the splash over the hidden library ([DESIGN.md › Launch](DESIGN.md#launch) has the choreography), and `LaunchCurtain` holds whatever the library would present meanwhile. `BentoSplash` keeps no state and draws whatever a `SplashClock` says, so `BentoSplashTests` can check any frame without waiting.

## Storage v2

Each notebook is a package at `Application Support/Library/<uuid>.owlluna/`. Older builds named them `<uuid>.scribe`, and `StorageRoot.adoptLegacyPackages` renames those at launch and on restore. Sync doesn't adopt them, since a `.scribe` in the container could never match `cloud.package(id)`.

```
manifest.json                 schemaVersion, title, cover, defaults, pages, recordings, library state
manifest.prev.json            the previous manifest, the fallback if the latest can't be read
ink/<pageID>.pkdrawing        page-local ink, one file per page
assets/                       imported PDFs, photos, placed pictures, audio, transcripts
thumbs/                       page thumbnails keyed by ink hash and page appearance
text/<pageID>.txt             recognised handwriting and PDF text, stamped with the ink hash it came from
text/<pageID>.pictures.json   what each placed picture read as
text/<recording id>.txt       a transcript's words, for search
cards.json                    flashcards, when each is next due, and which were deleted
cards/                        clippings shown on flashcards (PNG)
```

`Library/` also holds `folders.json`, `smart-shelves.json` and `activity.json`. Beside it in Application Support are the SwiftData index (`LibraryIndex.store`), `Stickers/`, `Papers/`, `Arriving/`, `Deleting/`, `sync-state.json` and `device-id`.

### Writing

`NotebookPackage` is an actor that does all file IO. A save writes only the dirty pages, each atomically, then the manifest last. A failed save keeps the pages dirty and retries with backoff (1 s, doubling, capped at 60 s). Pending writes finish under `beginBackgroundTask` when the app goes to the background.

### Reading and recovery

Unknown fields, unknown enum values and malformed fields never fail a manifest. Their raw JSON is written back unless the app changed them, at the top level and inside the cover, defaults, library state and recordings, and pages this build can't read are kept in place. The schema version is read first, and a newer manifest opens read-only and is never quarantined or rebuilt.

A file that fails to decode is renamed to `.corrupt` and never overwritten. PencilKit returns an empty drawing for data without its `wrd` header instead of failing, so that counts as damage too. Ink files newer than the manifest, left by a crash between the ink and manifest writes, are recovered as pages.

### Garbage collection and deletes

On close, after a successful save, files nothing references are removed. An asset is kept if its name appears anywhere in the manifest, including fields this build can't read. Only stale thumbnails are removed while a damaged manifest is set aside or after one was rebuilt from ink, since the damaged copy may be all that lists those files. Background jobs never recreate a deleted package. A permanent delete renames the package into `Deleting/` and removes it in the background; leftovers are swept at launch.

### Writing history

`Library/activity.json` is the private writing log behind the This Week strip and the writing calendar: `{version, days: {"yyyy-MM-dd": {notebooks: {<notebook id>: [<page id>]}, otherPages}}}`. It is recorded after a save, not at stroke end (`NotebookDocument.onInkSaved`, `WritingActivity`), and page lists older than 400 days shrink to counts in `otherPages`.

### Library index

SwiftData holds the index (`LibraryIndexSchemaV6`): notebook records, folders, and one `NotebookSearchText` row per notebook. Search text isn't a relationship of the record, so shelf queries never load it. Each record keeps the date of the manifest it was read from (`manifestDate`), and `LibraryIndex.refresh` re-reads only notebooks whose manifest has moved on. Schema changes are lightweight stages (`LibraryIndexMigrationPlan`) whose new fields the first refresh fills. The index can always be rebuilt from the manifests and `folders.json`, so one that can't be opened is set aside and rebuilt. `FolderTree` shows a folder whose parent is missing or loops at the top level, so a damaged file never hides one.

### Backup and restore

`LibraryBackup.create` writes `Library/`, `Stickers/` and `Papers/` into an LZFSE Apple Archive (`.owllunabackup`) with a small `backup.json`, leaving out `thumbs/`. A restore only adds. A notebook the library lacks moves in under its own ID, an identical one is left alone apart from merging its flashcards, and one that differs moves in as "Title (from backup)" under a new ID, so nothing is ever replaced. Unpacking skips absolute paths, `..` and symbolic links. A backup from a newer version is refused, not half-read.

### iCloud sync

The tests use a plain folder standing in for iCloud: `SyncTests` plays two devices against it, and `SyncUITests` launches the app twice with two storage roots and `-cloudFolder`. The main paths have also run on real iCloud with two iPads on one Apple Account; [DEVICE-CHECKS.md](DEVICE-CHECKS.md#icloud-sync) says which.

The app always works in `Application Support/Library`. `LibrarySync` copies whole notebooks between it and a `Sync` folder in the app's iCloud container, so the editor never reads a file iCloud hasn't downloaded and turning sync off changes nothing locally. The app is signed with `Config/OwlLuna-iCloud.entitlements`; `Config/OwlLuna.entitlements` drops iCloud for teams that can't sign it. `Config/Info.plist` exports `.owlluna` as a package type, so the system treats a notebook folder as one document.

#### Deciding what to copy

`sync-state.json` remembers each notebook's modification date when both sides last agreed. From the three dates (here, there, agreed), a notebook changed only there is pulled, one changed only here is pushed, and one changed on both is a conflict: the newer version keeps the ID and the older becomes "Title (conflicted copy)", so nothing written is lost. The copy is made and the agreed date saved before the newer version goes through, so a pass cut short finishes without a second copy. Pages are never merged. Flashcards are, card by card (`settleCards`), so answers given without writing on a page still sync.

Favourite, lock, folder, tags, the Recently Deleted date and the journal mark (`library.journal`) change without dating the notebook. Each change stamps `library.changedAt`, and each is settled on its own (`LibraryState.settled`): the later stamp wins and only the other side's manifest is rewritten. With no stamps this device wins, except that a lock is kept whichever side has it. Stamps never move backwards, so an old unlock can't undo a newer lock. Writing in a notebook beats moving it to Recently Deleted, as it beats a permanent delete. Where two devices each started a journal, the one begun first keeps the mark everywhere.

#### Which copy and which account

The container holds `copy-id`, a random ID that `sync-state.json` remembers. When it is missing or different (the copy was erased, refilled or belongs to another account), what was agreed is forgotten and the pass only adds. A `copy-id` or `folders.json` that is still a `.icloud` placeholder or can't be read yet stops the pass (`SyncError.stillArriving`) before anything is copied, rather than being taken as missing.

`sync-state.json` also keeps a digest of `ubiquityIdentityToken`. When it differs, `SyncCenter` asks (`Question.accountChanged`) before touching the container, and a device that has never synced asks once (`Question.firstSync`). A pass compares the token before each notebook and stops if it has moved (`SyncError.accountChanged`). `-cloudAccount` stands in for the account.

#### Deletes

A notebook that was in step and is gone locally was deleted here. The delete carries only if the synced copy hasn't changed since they agreed; then a `DeleteMarker` goes into `Deleted/` and the synced copy is removed, and otherwise the notebook is pulled back. The marker records which version was deleted, and another device removes its copy only if it holds that version. A pass reads only this device's replica of the container, so a delete can be made on a stale view, and the marker is what lets the other devices overrule it.

Markers are cleared after a year (`DeleteMarker.keptForDays`), four times the longest Recently Deleted. Nothing is deleted for want of a marker, so the length only sets how rarely a deleted notebook comes back. A library that can't be listed stops the pass rather than reading as empty. A pass that would take more than three notebooks out of a library, or more than half of it, takes none of them (`SyncReport.held`). The library's notice then either brings them back (`SyncCenter.keepHeld`) or lets the deletes through (`SyncCenter.letHeldGo`).

#### Copying and downloading

A push copies changed files through a temporary name and writes the manifest last. A notebook new to the container is assembled as `<id>-<random>.uploading` and moved into place whole, so a cut-off upload never leaves a package without its manifest. A pull assembles in `Arriving/`, checks the package holds everything the manifest names (`isWhole`: each page's ink matches its `inkHash`, every asset is there) and swaps it in whole. iCloud downloads a package's files in its own order, so another device's manifest can arrive before its ink; such a notebook waits with nothing agreed, so a change made here meanwhile becomes a conflict, never a push over writing it missed. The manifest is the seal: it goes last and hashes every page, and assets are UUID-named and never rewritten. Container writes go through `NSFileCoordinator`.

A pass first downloads only the small files it decides on (`LibrarySync.deciding`), then fetches only what a changed notebook lacks. `CloudFiles.download` waits up to 60 s, or 10 s with nothing arriving; a notebook still missing files waits for the next pass. After a good pass, in-step assets are evicted from the container once uploaded (`CloudFiles.evict`); ink, manifests and text stay, since every push compares them. `SyncCostTests` swaps `CloudAccess` for a folder that leaves `.icloud` placeholders.

#### Folders, stickers, papers, shelves and pens

Folders, stickers, papers and smart shelves are merged three ways on which ones exist, against the sets remembered from the last sync, so an add on one device and a delete on another both carry. Each `folders.json` entry and each shelf stamps its changes, and an item both sides have is settled by the later stamp (a folder field by field). `LibraryStore` writes only changed entries into the file as it stands, and a pass settles them inside `LibraryStore.holdingFolders` and `LibraryStore.holdingShelves`, so one made mid-pass is kept. An unreadable `folders.json` on either side skips folders for that pass; one in iCloud can be replaced from this device's folders (`SyncCenter.replaceFolders`). A side with no shelf file only adds. The tray's pens travel as one stamped list in `pens.json` (`SyncedPens`). Writing history is not synced.

#### When a pass runs

`SyncCenter` syncs at launch, on coming to the front or leaving it, a few seconds after a library change, and when `NSMetadataQuery` reports new files. Each notebook is taken when its turn comes (`DocumentRegistry.take`): one that is open, opening or saving is skipped, and one the pass holds makes `DocumentRegistry.open` wait, so an editor never loads files mid-swap. A pass that stops part-way saves what it agreed and throws `StoppedPass`. A window reopening its notebook at launch first pulls just that one (`SyncCenter.pullNewer`) for at most 4 s.

#### A notebook open on two devices

Every save of an open notebook asks `SyncCenter.sendSoon`, which waits for writing to pause for 5 s (30 s at most) and then sends that notebook alone (`LibrarySync.pushNewer`) if the synced copy still holds the agreed version. `DocumentRegistry.takeToSend` hands over the document's own package and the copy runs inside `NotebookPackage.hold`, so saves wait and what goes up is one whole save. `SyncCenter.catchUp` swaps a newer version into an open notebook with nothing unsaved, reopening at the same page. Where both devices wrote, the editor offers Keep Both (`SyncCenter.keepBoth`), which settles the conflict as a pass would.

#### What it reports

A pass lists the notebooks it left alone as `open`, `arriving`, `failed` (each a `SyncFailure` with a reason) or `held`, and retries them every pass. `CloudUploads` reads `ubiquitousItemIsUploaded` and `ubiquitousItemUploadingError`, so Settings can say what is still uploading and when iCloud is full. `SyncCenter.news` feeds the library's notice.

#### Known gaps

Two devices writing in one open notebook within the seconds iCloud takes to carry a change can both send theirs before either sees the other's. iCloud then keeps the later of each file, and a device whose pages and manifest don't match waits for the notebook until one of them writes in it again. A device on an older build ignores what a marker says and goes by the older delete rule. Whether iCloud downloads and evicts single files inside a `.owlluna` package, rather than the package as one item, has only been assumed; Sync 14 in [DEVICE-CHECKS.md](DEVICE-CHECKS.md#icloud-sync) checks it. A package without a manifest that no device has a copy of is still waited on. Deleting a notebook for good, or duplicating it, isn't held back while a pass has it in hand, and a delete made during that notebook's pull is undone by the pull.

### v1 notebooks

The v1 converter was removed on 2026-10-01. Notebooks it converted keep working, and anything v1 left on disk is no longer read.

## Background work and caches

Thumbnails (`PageThumbnailer`), covers (`CoverRenderer`), PDF export (`NotebookExporter`, streamed a page at a time), handwriting OCR (`HandwritingIndexer`, per page by ink hash), library search (`PageSearch`) and PDF parsing all run off the main thread.

Paper templates draw only the rules that reach the clip (`TemplateRules`), so a tile at 5× strokes its own few lines. Diagonal rules are laid in short pieces on a fixed grid, because Core Graphics rasterises a long diagonal slightly differently depending on where the clip starts. `PaperParityTests` keeps tiles, thumbnails and export pixel-identical.

Every cache is bounded: LRUs of 6 PDF documents, 12 page images and 120 thumbnails, 80 MB of covers in memory and 150 MB on disk, and 24 clean pages of loaded ink (unsaved pages are never evicted). Memory warnings empty every `LRUCache`, and the editor drops its pooled canvases. Signposts use `OSSignposter` under `com.owais.OwlLuna`.

## v1 and v2, before and after

Same run for both columns, on the "OwlLuna Bench" iPad Pro 11-inch (M5) simulator, iOS 27.0, Debug build, M4 Mac mini at load average 3 to 4. Timings are medians from `OwlLunaTests/PerformanceBaselineTests` (`OWLLUNA_PERF=1`); the v1 column was measured before v1 was removed in M6.

| Measure | v1 | v2 | Target |
|---|---|---|---|
| Main thread at stroke end (heavy) | 6.0 ms (copies the whole notebook's drawing) | 0.12 ms, the same in a 10-page notebook | ≤ 0.5 ms, flat |
| Autosave, main thread (heavy) | 124 ms (writes everything on the main thread) | 0.48 ms; 2.8 ms max when the index updates too | ≤ 2 ms |
| Insert a page at the start (heavy) | 332 ms (re-maps every stroke) | 1.2 ms including relayout | ≤ 5 ms |
| Open heavy: longest main-thread block | 125 ms, plus 35 ms first render | 5.8 ms | ≤ 30 ms |
| Open heavy: to first ink | ≈ 160 ms | 71 ms | ≤ 100 ms |
| Export 20 pages | 1.13 s on the main thread | 1.11 s off it; longest main-thread gap 2.5 ms | never blocks |
| Library of 500 / 300-page PDF, in-app scroll at 2,400 pt/s for 6 s | not measured | 0 long frames of 360 | no hitches |
| Peak footprint (test process, excludes GPU) | opening heavy: 528 MB | scrolling heavy: 516 MB (baseline 365), at 5×: 520 MB | bounded |

A long frame is over 1.5× the display interval, counted by the frame-pacing probe. XCUITest swipes add two or three long frames each from its own snapshots, so the in-app scroll is the figure to compare. None of these are device numbers.

## Swift 6

All three targets build in the Swift 6 language mode with no warnings. What matters at runtime:

- Paper tiles are drawn by `PagePaperView.image`, a `nonisolated` static that touches no layer, and handed to their layers on the main thread, so nothing commits a Core Animation transaction off it. With the `CATiledLayer` paper used before, the second screen's new window could be laid out on a tile thread and trap the main-actor check.
- Images and PDFs that cross threads go in small immutable `@unchecked Sendable` boxes (`SharedImage`, `SharedPDF`).
- `CanvasUndoProxy` and `LRUCache` keep notification tokens `nonisolated(unsafe)`; they're only read again in `deinit`, when nothing else can reach them.

## Colour and accessibility

Small labels use `textSecondary`, which keeps 7:1 in light, dark and Increase Contrast, so anti-aliased small text clears Apple's audit (`DesignTokenTests`); `inkSecondary` is for decoration and large text only.

`AccessibilityAuditUITests` runs Apple's full audit over the library, the editor's modes and the sheets, in light and dark with and without Increase Contrast (`-increaseContrast`), then at a large text size. Reports it makes whatever the colours, such as text on system glass bars, are logged rather than failed. It runs in portrait, because in landscape the iPadOS 27 simulator hands it a rotated screenshot. Layouts that change with text size use `AnyLayout`, not `ViewThatFits`, whose two copies of the text read as partly unscaled, and no text uses `caption2` for the same reason.

## Languages

Every string goes through `String(localized:)`, a SwiftUI text literal or a `LocalizedStringResource`, into a string catalog: `OwlLuna/Resources/Localizable.xcstrings`, `InfoPlist.xcstrings`, `AppShortcuts.xcstrings` and `OwlLunaWidgets/Localizable.xcstrings`. English is the source language; Spanish, French and German are filled in. Values stored in a notebook are raw values, never translated text. A count is one string with plural variations, never a "1 page" string chosen in code, and `PluralTests` fails if one comes back. `LocalizationUITests` launches the app in each language.

## Known limits

- Undo keeps whole-page drawings, so steps shrink as pages get heavier: 200 for light pages down to 20 above about 2.4 MB of ink (`UndoBudget`, 48 MB). The budget is an estimate to check against a device memory trace.
- PencilKit's lasso and ruler are page-scoped because each page is its own canvas. A cross-page ruler can't be built: the ruler's position and angle can't be read or set, and a stroke can't leave its canvas.
- ⌘F is claimed by a first-responder view in the library, since the toolbar search swallows it otherwise. In the iPadOS 27 simulator under XCUITest ⌘F never reaches the app while ⌘G does, so it needs a device check.
- iCloud sync has run on real iCloud along its main paths only. Evicted files, a notebook open on the other iPad, mass deletes and an account change have only run against the stand-in folder.
- Transcription (`-fakeTranscript`), the second screen (`-secondScreenInset`), scanning (`-fakeScan`), Face ID (`-fakeUnlock`), translation (`-fakeTranslate`) and the calendar (`-fakeCalendar`) have only run through stand-ins. The tool tray, the zoom window and PDF text have only had synthesised touches, and two windows (`-windowButtons`) have only been tried one at a time.
- Every figure here is from the simulator. [DEVICE-CHECKS.md](DEVICE-CHECKS.md) covers Pencil latency, hitches, memory at 5× with the heavy fixture, palm rejection and every other limit above that needs a device.
