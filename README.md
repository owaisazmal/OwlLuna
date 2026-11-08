# OwlLuna

[![CI](https://github.com/owaisazmal/OwlLuna/actions/workflows/ci.yml/badge.svg)](https://github.com/owaisazmal/OwlLuna/actions/workflows/ci.yml)

**A free, open-source handwritten notes app for iPad. No subscriptions, no ads, no tracking.**

OwlLuna is built only on Apple frameworks (SwiftUI, PencilKit, PDFKit, Vision, SwiftData). Your notes stay on your iPad, with a copy in your own private iCloud storage if you turn sync on.

## Try the beta

OwlLuna is in a free TestFlight beta. No Mac is needed.

1. On an iPad with iPadOS 18 or later, install TestFlight from the App Store.
2. Open <https://testflight.apple.com/join/68jmH6R7> on that iPad. TestFlight offers to install OwlLuna.

The App Store version comes later. To build it yourself, see [Getting started](#getting-started).

## Features

### Writing

- Apple Pencil writing with palm rejection, pressure and tilt.
- A tool tray of up to eight pens (pen, fineliner, fountain, calligraphy, pencil, highlighter, crayon, watercolour), an eraser for whole or partial strokes, a lasso, and the shortcuts you pick: Picture, Text Box, Sticker, Link, Study Tape, Ruler, Zoom Window, Handwriting to Text and Shapes.
- Draw and hold: rest the pen at the end of a line, circle, rectangle or other straight-sided shape and it straightens. A hooked or barbed line becomes an arrow.
- Shapes: drag out a line, arrow, circle, rectangle or triangle in the current pen's ink.
- Pencil gestures: scribble over ink to erase it, loop round ink to select it, and choose what double-tap and squeeze do. A squeeze can bring an ink dish of your pens to the Pencil's tip.
- Select ink across pages and move it to another page.
- Handwriting to text, read on the iPad: convert a selection, or have writing set as type as you go. Translate it with Apple's translator.
- A zoom window for writing small and neat.
- Whiteboards: a page with no edges, for diagrams and brainstorming.
- Zoom up to 5× with sharp ink, Fit Width (⌘0) and Fit Page (⌘9).
- Undo and redo for ink and page changes, and keyboard shortcuts for most actions.
- Draw with the Pencil only, or with a finger too.
- Pages scrolled continuously, or shown one at a time and turned with a swipe.
- Focus mode (⌃⌘F), notebook tabs, and two notebooks side by side in one window.

### Presenting

- Present one page at a time (⌥⌘↩), with a laser pointer.
- On a second screen the audience sees only the page. The iPad keeps the controls, presenter notes, the next page and a timer.

### Notebooks and paper

- Fourteen paper templates (ruled, grid, dotted, Cornell, planners, music staff, storyboard and more), nine paper colours, and Letter, A4, A5 and widescreen pages.
- Your own paper from a PDF page or a picture.
- New notebook starters and Quick Note (⇧⌘N).
- A page navigator for jumping, reordering, inserting, duplicating and deleting pages.
- Bookmarks, and links to another page, another notebook or a web address.

### PDFs and pictures

- Import PDFs and write on them. Select their text to copy or highlight it, and use a highlighter that snaps to a line of text. Scanned PDFs work too.
- Insert photos as pages, or scan paper with the camera. Printed words are read for search.
- Pictures you can move, resize, rotate, crop and layer.
- Forty vector stickers, plus stickers cut out of your own photos.
- Study tape that hides what is under it until you tap it.
- Typed text boxes with fonts, styles, lists and checklists, and today's calendar events.
- Export as PDF (vector ink, searchable handwriting, working links), as images, as text or Markdown, or a page as a time-lapse video.

### Studying

- Flashcards made from study tape, from handwriting or by hand, with spaced repetition.
- A study guide of main points and practice questions, written on the iPad by Apple Intelligence.

### Audio

- Record alongside a notebook, then replay it with your ink appearing as it was written.
- Transcripts made on the iPad, never on a server. Tap a line to hear it.

### Library

- Cloth, Print and first-page covers.
- A daily journal with Today's page (⌘T) and On This Day.
- A This Week strip and a writing calendar. No streaks, badges or reminders.
- Locked notebooks, opened with Face ID, Touch ID or the passcode. A lock hides a notebook in the app; it does not encrypt its files.
- Folders inside folders, tags, smart shelves, favourites, sorting, and a list view.
- Recently Deleted, emptied after 7, 30 or 90 days.
- Search across handwriting, typed text, PDFs, scans and transcripts, Find in Notebook (⌘F), and Spotlight.
- iCloud sync between your iPads, and a backup of the whole library to one file.
- Light, Dark or the system appearance, and a left-handed layout.

### Everywhere else

- English, Spanish, French and German. The translations are machine-made and not yet checked by native speakers; corrections are welcome.
- Home Screen and Lock Screen widgets, Control Center buttons, and Shortcuts and Siri.

## Requirements

- Xcode 27 or later (iOS 27 SDK, Swift 6). The app uses newer APIs where the iPad has them, so older Xcodes fail to compile.
- iPadOS 18 or later.
- Runs on iPad and on Apple silicon Macs ("Designed for iPad").

## Privacy

OwlLuna has no accounts and no analytics. Handwriting, speech and printed text are read on the iPad. Transcription runs only when you ask, and only if the iPad can do it on the device. Translation and study guides also run on the iPad. The calendar is read only for today's events, and the camera only while you scan.

On an iPad that has never synced, iCloud sync copies nothing until you allow it in Settings › iCloud. With it on, your library goes to the app's private container in your own iCloud. The writing history (`Library/activity.json`) is never synced, though your backups include it; Settings › Writing History turns it off or clears it.

The widgets read a small snapshot the app writes to its shared container on the device. A locked notebook's title and cover are never in it, nor in Spotlight, and its name isn't offered to Siri. A lock keeps a notebook closed in the app but doesn't encrypt it beyond what iPadOS does for every app, so a backup or iCloud copy holds it like any other.

## Getting started

```bash
git clone https://github.com/owaisazmal/OwlLuna.git
```

```bash
open OwlLuna/OwlLuna.xcodeproj
```

Pick an iPad simulator and run. Only the Apple Pencil draws at first; **⋯ › Draw With › Pencil and Finger** lets a finger, or the simulator's mouse, draw too.

To run on a device, copy the signing settings, which git ignores:

```bash
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

Set your team ID and a bundle ID prefix you own. The bundle IDs, App Group and iCloud container follow the prefix (`<prefix>.OwlLuna`, `group.<prefix>.OwlLuna`, `iCloud.<prefix>.OwlLuna`); set `APP_GROUP` or `ICLOUD_CONTAINER` if yours differ. Set the team there, not in Signing & Capabilities, which writes it into the project. A free developer account can't sign the iCloud capability: uncomment `APP_ENTITLEMENTS` in the same file and the app runs with sync shown as unavailable.

Run the tests with ⌘U, or from Terminal with any iPad simulator:

```bash
xcrun simctl list devices available | grep iPad
```

```bash
xcodebuild test -project OwlLuna.xcodeproj -scheme OwlLuna -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'
```

## Architecture

```
OwlLuna/
├── App/          Entry point, launch, shortcuts, test-only seeds and probes
├── Launch/       The launch splash
├── Models/       Manifest types, pages, covers, paper, tools
├── Storage/      Notebook packages, manifest codec, SwiftData library index
├── Canvas/       Page stack (one PencilKit canvas per visible page), page items, rendering
├── Editor/       NotebookDocument (model, undo, autosave), editor chrome, navigator, recorder
├── Library/      Library views, covers, new-notebook sheet, library store
├── Study/        Flashcards, review and the study guide
├── Design/       Colour tokens, typography, shared controls, cover renderer
├── Services/     Export, backup, iCloud sync, recognition, scanning, locks, Spotlight
├── Settings/     Settings and acknowledgements
└── Resources/    Fonts and their licences, privacy manifest, string catalogs
OwlLunaWidgets/   Widgets and Control Center buttons
Shared/           Code shared by the app and the widgets: the app icon art, the widget snapshot, control actions
```

The main decisions, with measurements, are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). The visual system is in [docs/DESIGN.md](docs/DESIGN.md).

- **One package per notebook.** Each notebook is `Library/<id>.owlluna/`: a `manifest.json`, one ink file per page, plus assets, thumbnails and recognised text. Saves write only changed pages, atomically, with the manifest last, off the main thread. Files that can't be read are set aside as `.corrupt`, never overwritten.
- **One canvas per visible page.** Pages sit in a UIKit scroll view and only the visible pages ±1 have a `PKCanvasView`, so cost follows what's on screen, not the notebook's size.
- **One undo history.** Strokes and page changes register against the document, not the views, so undo survives canvases being recycled.
- **One document per notebook.** Every window shares it. Closing waits for recordings, imports and the last save, and a failed save keeps the editor open.
- **The index is a cache.** SwiftData indexes the library for sorting and search, and can always be rebuilt from the manifests.

## Roadmap

Some features can't be fully tested in the simulator. The steps for checking them on a real iPad are in [docs/DEVICE-CHECKS.md](docs/DEVICE-CHECKS.md). Help with any of these is welcome.

- [x] iCloud sync between two real iPads: arrival, edits on both, delete, restore, lock, folders, large uploads, offline catch-up (October 2026).
- [ ] The rest of iCloud sync: a notebook open on both iPads, many deletes at once, evicted files, a fast clock, different Recently Deleted lengths, another Apple Account.
- [ ] Transcription with real speech and a long recording.
- [ ] Camera scanning, Face ID, translation, the calendar prompt, Control Center buttons, and the zoom window with a Pencil.
- [ ] The study guide on an iPad with Apple Intelligence.
- [ ] Pencil double-tap, squeeze, scribble and loop with a real Pencil.
- [ ] Handwriting to Text with real handwriting.
- [ ] Whiteboards, tabs, PDF text and the tool tray with a Pencil on a real iPad.
- [ ] A ruler that spans pages.
- [ ] Native-speaker review of the translations, and more languages.

## Website

The site, with its Privacy Policy and Support page, is in [`website/`](website/README.md) and is published at <https://owaisazmal.github.io/OwlLuna/>.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Bugs and feature requests go in [GitHub Issues](https://github.com/owaisazmal/OwlLuna/issues). Report security problems privately, as [SECURITY.md](SECURITY.md) describes.

## License

[MIT](LICENSE).
