# Changelog

All notable changes to OwlLuna are listed here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each TestFlight build has its own section, such as 1.0.0-build.3 for build 3 of 1.0; the build that goes to the App Store also gets a section with the version alone.

## [Unreleased]

## [1.0.0-build.4] - 2026-10-28

### Added

- Take Photos: a camera button next to Add opens the camera straight away and keeps it open. Each photo goes onto the page with no step to check it, sized to how far you're zoomed in, and lined up in columns that carry on to a new page when one is full. Resize and rotate them afterwards. The volume buttons take a photo too, and you can pinch to zoom.

### Fixed

- Undo and Redo do nothing while presenting. After typing in a new text box, one Undo takes the box away and Redo brings it back with its words.
- A notebook you favourite, lock, tag, file or move to Recently Deleted just before opening it now keeps that change. Its first save could undo it.
- A box or triangle drawn and held round writing now straightens instead of selecting it. A loop that selects can be undone back to ink, and the Select Ink bar's Keep Circle keeps a round one as a circle.
- A held box or triangle whose end runs on past its start now straightens without a spike at that corner, and a rough loop is less often straightened into a box.
- Deleting a recording now asks first, and Undo brings it back with its name and transcript.
- The page no longer jumps to its top when the editor changes size. ⌘F, Select PDF Text and the tabs hiding leave it where it is, turning the iPad or resizing a window keeps what you were looking at in view, and dragging the divider between two notebooks is smoother.
- Study Them Anyway and Go Through Them All Again no longer send cards months away. A card answered before its day grows only from the days it has waited, so going over a deck again the same evening leaves it where it was.
- Missing a card on the same day you last answered it no longer counts as forgetting it, so going over a new deck several times doesn't make its waits grow more slowly later.
- Library search finds every word you type, in any order, even when a line ends between them. Put words in quotes to find them together. A notebook with more matching pages than are shown says how many more.
- Closing a study guide, changing what it is written from, or choosing Write It Again now stops the writing in progress. A very long notebook's summary is written from 24 pieces spread through it, and the progress bar moves while pages are read.
- A selected item, its grips and its corner handle now stay under your finger from where it touched down, instead of starting a little behind it.
- Find in Notebook works like library search: it finds every word you type, in any order, on the same page, and a quoted phrase even when a line ends between its words.

## [1.0.0-build.3] - 2026-10-21

### Added

- Text boxes can use a serif, monospaced or Fraunces typeface, with italic and underline.
- A text box can be a bulleted, numbered or checklist list. Tick a checklist line on the page.
- A text box can be highlighted in any of the highlighter's four colours.
- Crop a picture on the page. Reset Crop brings the whole picture back, and exports keep only the cropped part.
- Squeeze or stretch a picture from the grip on any side. The corner handle and a pinch still keep its proportions.
- Shapes in the tool tray (add it from Customise Tools): drag out a line, arrow, circle, rectangle or triangle in the pen's ink.
- Draw and hold turns a line with a hook or barbs at its tip into an arrow.
- Settings › Appearance: follow the iPad, or always Light or Dark.
- Settings › Input › Left-Handed moves the page ribbon, the zoom window's buttons and the panels beside the page to the left.
- Settings › Recently Deleted: empty it after 7, 30 or 90 days. Each iPad keeps its own setting.
- Settings › Pen Tray puts the tray back to the pens it started with.
- Settings › Recordings sets the language transcripts use. Each recording can still pick another.
- A list view for the library, switched from the library's bar, with sortable columns.
- The sort menu can reverse the order.
- Select several notebooks, or Select All, then favourite, tag, move, lock, export as PDFs or delete them together.
- Drag a notebook from the library into another app as a PDF. Locked notebooks and those in Recently Deleted stay behind.
- A notebook open on two iPads stays up to date. Writing is sent a few seconds after you stop, and the other iPad shows it in place if it has nothing unsaved. If both were written in, Keep Both saves the older as a conflicted copy straight away.
- Sync progress: a thread along the library's bar, "Not uploaded yet" under a cover until iCloud has it, and an upload count in Settings.
- Smart shelves and the tray's pens sync with iCloud. The later change wins.
- Scanned PDFs, slides saved as pictures, and pictures placed on a page are read for search, Find in Notebook, Spotlight and the study guide. Exported PDFs carry those words as selectable text.
- Select PDF Text and the snapping highlighter work on scanned PDFs and slides saved as pictures.
- Paper of your own: Add Paper… in the paper drawer or New Notebook takes the first page of a PDF, or a picture. It is kept under My Paper for every notebook, and syncs and is backed up with your stickers.
- Export options: pick the pages, keep or drop the paper, and choose Smaller File or Sharper Ink. Image exports ask which pages too.
- This Page as a PDF, in the editor's Export menu.
- Exported PDFs are searchable: handwriting and scanned words lie under the ink as selectable text. Searchable Handwriting turns it off.
- Export a notebook as plain text or Markdown, from the editor or the library.

### Changed

- iCloud sync is no longer experimental. It has been tested on real iCloud, on iPads signed in to one Apple Account.
- iCloud sync uses less space and data. It downloads only what changed, leaves uploaded pictures, PDFs and recordings in iCloud, compares files by content rather than date, and no longer waits a minute offline before sending.
- Dark Paper in Dark Mode is now Keep Paper Light, in Settings › Appearance. Exports always keep the page's own colours.
- The language picked in a recording's transcript is now for that recording only.
- A notebook made with a newer version of OwlLuna can now go into Recently Deleted and come back out.
- A notebook deleted for good on another iPad now goes into Recently Deleted here, unless it was in there already.
- On a Mac, fingers and the pointer draw from the start.
- A recording carries on when the iPad locks or you switch apps. In a locked notebook it still stops when the iPad locks.
- At the accessibility text sizes, the shelf becomes a list.
- Pen, fineliner and fountain pen are exported to PDF as vectors, so they stay sharp and usually take less space.

### Fixed

- iCloud sync no longer deletes many notebooks at once without asking. It holds them back: Keep restores them everywhere, Delete lets them go.
- Folder changes made on two iPads are settled one at a time, so a rename made offline is no longer lost.
- A folder list that can't be read, on the iPad or in iCloud, is never written over. The library says folders aren't syncing, and your folders stay as they were.
- Restoring a backup over a damaged folder list keeps the folders you had.
- A change made after syncing with an iPad whose clock runs fast now wins, as it should.
- A notebook reopened at launch, or when you return to the app, takes in writing from another iPad first. If that isn't ready yet, the editor says so and closing keeps both.
- Typing in a text box while zoomed in now wraps the lines where the page does.
- In the zoom window, Next Line on Cornell and Checklist paper now moves down by one rule, so writing stays on the lines.
- Today's events on a journal page are no longer replaced on a new day once you have edited them.
- A notebook you close no longer stays in memory until the app quits.
- A recording is kept if OwlLuna quits, crashes or runs out of battery before Stop. It appears the next time the notebook opens.
- If a recording stops without Stop, the editor says when and why.
- The first time a finger tries to draw when only the Pencil draws, a notice explains why, with a Let Fingers Draw button.
- A resting palm or thumb no longer spoils draw and hold.
- With two notebooks side by side, touching one makes it active, and Pencil double-tap or squeeze reaches only that one.
- With Appearance set to always Light or Dark, notebooks open at the right page and whiteboards are ready to write on.
- At the largest text sizes, the library's title is no longer cut off.
- In Dark Mode, selection grips and crop handles are easy to see.
- Highlighter in an exported PDF no longer hides the writing and printed words under it.
- Links in a partial export show the linked page's name instead of "Missing page", and bookmarks keep their page numbers.
- Ink added while a page opens (a shape or an undo) no longer stays half drawn or gets dropped when the iPad is short of memory.

## [1.0.0-build.2] - 2026-10-15

The first build for TestFlight testers. No accounts, no ads and no tracking.

### Added

#### Writing

- Apple Pencil handwriting with palm rejection, pressure and tilt.
- A tool tray with up to eight pens: pen, fineliner, fountain pen, calligraphy pen (iPadOS 26), pencil, highlighter, crayon and watercolour, each with its own colour, width and opacity. An eraser, a lasso and the shortcuts you choose sit beside them.
- Draw and hold: rest the pen at the end of a line or shape and it straightens.
- Pencil gestures: scribble over ink to erase it, loop round ink to select it, and choose what double-tap and squeeze do. An ink dish of your pens comes to the Pencil's tip.
- Select ink across pages and move it to another page.
- Handwriting to text, read on the iPad: turn selected ink into text, or have it set as type as you write. Translate it with Apple's translator.
- A zoom window for writing small and neat.
- Whiteboards: a page with no edges.
- Pinch to zoom up to 5×, with Fit Width and Fit Page.
- Undo and redo, including changes to pages.
- Hardware keyboard shortcuts.
- Draw with the Pencil only, or with a finger too.
- Focus mode, which puts the toolbar away.
- Notebook tabs, and two notebooks side by side in one window.

#### Presenting

- Present one page at a time, with a laser pointer.
- On a second screen, the audience sees the page while the iPad keeps the controls, your presenter notes, the next page and a timer.

#### Notebooks and paper

- Fourteen paper templates, nine paper colours and four page sizes.
- Change a page's paper and colour in place.
- New notebook starters, and Quick Note.
- A page navigator for jumping to, moving, adding, duplicating and deleting pages.
- Bookmarks, and links to another page, another notebook or a web address.

#### PDFs and pictures

- Import PDFs and write on them. Select a PDF's text to copy or highlight it, and a highlighter that snaps to a line of text.
- Insert photos as pages, and scan documents with the camera.
- Pictures, forty built-in stickers, and stickers of your own cut out of photos.
- Study tape that hides what is under it until you tap it.
- Typed text boxes, and today's events from your calendar.
- Export a notebook as a PDF, its pages as images, or a page as a time-lapse video.

#### Studying

- Flashcards made from study tape, from handwriting or by hand, with spaced repetition.
- A study guide written by Apple Intelligence on the iPad: the main points and practice questions.

#### Audio

- Record alongside a notebook, and replay the recording with your ink.
- Transcripts made on the iPad, never on a server.

#### Library

- Cloth, Print and first-page covers.
- A daily journal, with Today's page and On This Day.
- A This Week strip and a writing calendar, with no streaks or badges.
- Locked notebooks, opened with Face ID, Touch ID or the passcode.
- Folders inside folders, tags, smart shelves, favourites and sorting.
- Recently Deleted, emptied after 30 days.
- Search in handwriting, typed text, PDFs, scans and transcripts, Find in Notebook, and Spotlight.
- iCloud sync between your iPads. This is experimental: it has not yet run against real iCloud.
- Back up the whole library to one file, and restore it on this or another iPad.

#### Everywhere else

- English, Spanish, French and German. The translations have not yet been checked by native speakers.
- Home Screen and Lock Screen widgets, Control Center buttons, and Shortcuts and Siri.
- Runs on iPadOS 18 and later, and on Apple silicon Macs.

### Changed

- The app is now called OwlLuna. Notebooks and backups from before the rename still open.

[Unreleased]: https://github.com/owaisazmal/OwlLuna/compare/v1.0.0-build.4...HEAD
[1.0.0-build.4]: https://github.com/owaisazmal/OwlLuna/compare/v1.0.0-build.3...v1.0.0-build.4
[1.0.0-build.3]: https://github.com/owaisazmal/OwlLuna/compare/v1.0.0-build.2...v1.0.0-build.3
[1.0.0-build.2]: https://github.com/owaisazmal/OwlLuna/releases/tag/v1.0.0-build.2
