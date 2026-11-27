# OwlLuna

[![CI](https://github.com/owaisazmal/OwlLuna/actions/workflows/ci.yml/badge.svg)](https://github.com/owaisazmal/OwlLuna/actions/workflows/ci.yml)

**A free, open-source handwritten notes app for iPad, iPhone and Mac. No subscriptions, no ads, no tracking.**

OwlLuna is built only on Apple frameworks (SwiftUI, PencilKit, PDFKit, Vision, SwiftData). Your notes stay on your device, with a copy in your own private iCloud storage if you turn sync on.

## Try the beta

OwlLuna is in a free TestFlight beta. No Mac is needed.

1. On an iPad with iPadOS 18 or later, install TestFlight from the App Store.
2. Open <https://testflight.apple.com/join/68jmH6R7> on that iPad. TestFlight offers to install OwlLuna.

The App Store version comes later. To build it yourself, see [Getting started](#getting-started).

## Features

### Writing

- Apple Pencil writing with palm rejection, pressure and tilt.
- A tool tray of up to eight pens (pen, fineliner, fountain, calligraphy, pencil, highlighter, crayon, watercolour), an eraser for whole or partial strokes that can be kept to the highlighter, a lasso, and the shortcuts you pick: Picture, Text Box, Sticker, Link, Study Tape, Ruler, Zoom Window, Handwriting to Text and Shapes.
- Draw and hold: rest the pen at the end of a line, circle, rectangle or other straight-sided shape and it straightens. A hooked or barbed line becomes an arrow.
- Shapes: drag out a line, arrow, circle, rectangle or triangle in the current pen's ink.
- Pencil gestures: scribble over ink to erase it, loop round ink to select it, and choose what double-tap and squeeze do. A squeeze can bring an ink dish of your pens to the Pencil's tip.
- Finger taps: two fingers undo and three redo, or choose another action for each, and for a one-finger double-tap.
- Lasso ink, resize, stretch and turn it, change its colour and line width, carry it to another page, and cut, copy and paste it, also to and from Notes.
- Handwriting to text, read on the device: convert a selection, or have writing set as type as you go. Translate it with Apple's translator.
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
- A PDF's own table of contents in the page navigator, with chapters that fold and a tap to jump to one.
- Insert photos as pages, or scan paper with the camera. Printed words are read for search.
- Pictures you can move, resize, rotate, crop and layer.
- Paste a copied picture or screenshot where you hold a finger on the page, or as a page of its own.
- Forty vector stickers, plus stickers cut out of your own photos.
- Study tape that hides what is under it until you tap it.
- Typed text boxes with fonts, styles, lists, checklists and LaTeX formulas, and today's calendar events.
- Export as PDF (vector ink, searchable handwriting, working links), as images, as SVG with every stroke a shape of its own, as text or Markdown, or a page as a time-lapse video.

### Studying

- Flashcards made from study tape, from handwriting or by hand, with spaced repetition.
- A study guide of main points and practice questions, written on the device by Apple Intelligence.

### Audio

- Record alongside a notebook, then replay it with your ink appearing as it was written.
- Transcripts made on the device, never on a server. Tap a line to hear it.

### Library

- Cloth, Print and first-page covers.
- A daily journal with Today's page (⌘T) and On This Day.
- A This Week strip and a writing calendar. No streaks, badges or reminders.
- Locked notebooks, opened with Face ID, Touch ID or the passcode. A lock hides a notebook in the app; it does not encrypt its files.
- Folders inside folders, tags, smart shelves, favourites, sorting, and a list view.
- Recently Deleted, emptied after 7, 30 or 90 days.
- Search across handwriting, typed text, PDFs, scans and transcripts, Find in Notebook (⌘F), and Spotlight.
- iCloud sync between your devices, and a backup of the whole library to one file.
- Light, Dark or the system appearance, and a left-handed layout.

### Everywhere else

- English, Spanish, French and German. The translations are machine-made and not yet checked by native speakers; corrections are welcome.
- Home Screen and Lock Screen widgets, Control Center buttons, and Shortcuts and Siri.

## Requirements

- Xcode 27 or later (iOS 27 SDK, Swift 6). The app uses newer APIs where the device has them, so older Xcodes fail to compile.
- iPadOS 18 or later on iPad, and iOS 18 or later on iPhone.
- macOS 26 or later on the Mac, where it runs as a Mac Catalyst app.

## Privacy

OwlLuna has no accounts and no analytics. Handwriting, speech and printed text are read on the device. Transcription runs only when you ask, and only if the device can do it without a server. Translation and study guides also run on the device. The calendar is read only for today's events, and the camera only while you scan.

On a device that has never synced, iCloud sync copies nothing until you allow it in Settings › iCloud. With it on, your library goes to the app's private container in your own iCloud. The writing history (`Library/activity.json`) is never synced, though your backups include it; Settings › Writing History turns it off or clears it.

The widgets read a small snapshot the app writes to its shared container on the device. A locked notebook's title and cover are never in it, nor in Spotlight, and its name isn't offered to Siri. A lock keeps a notebook closed in the app but doesn't encrypt it beyond what the system does for every app, so a backup or iCloud copy holds it like any other.

## Getting started

```bash
git clone https://github.com/owaisazmal/OwlLuna.git
```

```bash
open OwlLuna/OwlLuna.xcodeproj
```

To run on your iPad, copy the signing settings, which git ignores:

```bash
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

Set your team ID and a bundle ID prefix you own. The bundle IDs, App Group and iCloud container follow the prefix (`<prefix>.OwlLuna`, `group.<prefix>.OwlLuna`, `iCloud.<prefix>.OwlLuna`); set `APP_GROUP` or `ICLOUD_CONTAINER` if yours differ. Set the team there, not in Signing & Capabilities, which writes it into the project. A free developer account can't sign the iCloud capability: uncomment `APP_ENTITLEMENTS` and `MAC_APP_ENTITLEMENTS` in the same file and the app runs with sync shown as unavailable.

Pick your iPad and run. Only the Apple Pencil draws at first; **⋯ › Draw With › Pencil and Finger** lets a finger draw too.

Run the unit tests (`OwlLunaTests`) from Xcode's Test navigator. ⌘U also runs the UI tests, which are much slower.

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

The main decisions, with measurements, are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). The visual system is in [docs/DESIGN.md](docs/DESIGN.md). The steps for checking features on a real iPad or Mac are in [docs/DEVICE-CHECKS.md](docs/DEVICE-CHECKS.md).

- **One package per notebook.** Each notebook is `Library/<id>.owlluna/`: a `manifest.json`, one ink file per page, plus assets, thumbnails and recognised text. Saves write only changed pages, atomically, with the manifest last, off the main thread. Files that can't be read are set aside as `.corrupt`, never overwritten.
- **One canvas per visible page.** Pages sit in a UIKit scroll view and only the visible pages ±1 have a `PKCanvasView`, so cost follows what's on screen, not the notebook's size.
- **One undo history.** Strokes and page changes register against the document, not the views, so undo survives canvases being recycled.
- **One document per notebook.** Every window shares it. Closing waits for recordings, imports and the last save, and a failed save keeps the editor open.
- **The index is a cache.** SwiftData indexes the library for sorting and search, and can always be rebuilt from the manifests.

## Website

The site, with its Privacy Policy and Support page, is in [`website/`](website/README.md) and is published at <https://owaisazmal.github.io/OwlLuna/>.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Bugs and feature requests go in [GitHub Issues](https://github.com/owaisazmal/OwlLuna/issues). Questions, ideas and anything else go in [GitHub Discussions](https://github.com/owaisazmal/OwlLuna/discussions). Report security problems privately, as [SECURITY.md](SECURITY.md) describes.

## License

[MIT](LICENSE).
