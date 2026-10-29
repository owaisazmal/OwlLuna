# Device checks

These are the checks the simulator can't do. Unless a check says it has passed, it has only run in the simulator or in tests. Work through a section, tick its items in the "Device checks before 1.0" issue, and attach what it asks you to keep.

You need:

- Two iPads on one test Apple Account with iCloud Drive on (the sync checks delete notebooks for good), ideally one with Face ID and one with Touch ID.
- An Apple Pencil Pro for squeeze and hover. Double-tap also works with an Apple Pencil (2nd generation).
- iPadOS 18 or later, and iPadOS 26 for the calligraphy pen and the study guide. CI's iPadOS 18 job is skipped, so try the main paths on iPadOS 18 too.
- A keyboard with a trackpad, a display with a USB-C to HDMI adapter or an Apple TV, a Mac with Xcode 27, and an iPhone that films at 240 fps.
- For the iPhone checks, an iPhone on iOS 18 or later, ideally an iPhone Duo.

Names are spelt as the app spells them. In the editor, ⋯ is More, + is Add, and the title menu opens from the notebook's title. Keep a screen recording of every check, and film your hand with a phone where it matters. Write the build, the iPadOS version and the Pencil beside every result.

## Before you start

TestFlight is a Release build: no launch arguments, no profiling, and Console hides IDs and errors as `<private>`. Run from Xcode (Debug) for launch arguments and full logs in Xcode's console, after setting up signing ([README › Getting started](../README.md#getting-started)). Product › Profile builds Release into Instruments. Use one build per section.

Evidence:

- Console: pick the iPad, Start, and search `subsystem:com.owais.OwlLuna category:<name>` with the category a check names. The app only logs errors, plus two sync notices. For iCloud itself, also stream `bird` and `cloudd`.
- Instruments: os_signpost shows Launch, Open to first ink, Save, Thumbnail, OCR page, Export and Cover render.
- sysdiagnose: hold both volume buttons and the top button for a second. Ten minutes later it is in Settings › Privacy & Security › Analytics & Improvements › Analytics Data, beside `OwlLuna-…` crash logs and `JetsamEvent-…` memory kills. For sync, install Apple's iCloud logging profile first (developer.apple.com/bug-reporting/profiles-and-logs).
- Xcode builds only: Window › Devices and Simulators › OwlLuna › ⋯ › Download Container. `AppData/Library/Application Support/` holds `sync-state.json`, `expired-trash.json`, `Library/`, `Arriving/` and `Deleting/`.

Fixtures, Debug only (Edit Scheme › Run › Arguments): `-seedLibrary N`, `-seedLongPDF` (300 pages), `-seedReplay`, `-seedHandwriting`, `-seedStudy`. Seeds only fill an empty library, and without `-storageRoot <name> -resetStorage` that is the real one, which syncs: answer Not Now to the iCloud question, or use an iPad outside the sync sitting. Settings › Backup › Back Up Library… carries a seeded library to a TestFlight iPad.

Heavy stand-in, any build: write a full page on the default paper, about 150 strokes. ⋯ › Select Ink Across Pages, drag corner to corner, Duplicate, drag the copy over and tap Done. Repeat until there are about 600 strokes, then ⋯ › Duplicate Page to 30 pages or more (past the 24 the ink cache keeps).

The exact heavy fixture (100 pages of 500 strokes) only exists as a unit test. Run it on the iPad:

```bash
TEST_RUNNER_OWLLUNA_PERF=1 xcodebuild test -project OwlLuna.xcodeproj -scheme OwlLuna -destination 'platform=iOS,name=<your iPad name>' -only-testing:OwlLunaTests/PerformanceBaselineTests/testV2MemoryScrollingHeavyInk
```

It prints two `PERF v2 memory` lines. Swap in `testV2StrokeEndHeavyNotebook`, `testV2OpenHeavy` or `testV2PageOperationsHeavy` for the other heavy timings.

## iCloud sync

Passed on real iCloud in October 2026, on two iPads with one Apple Account: Sync 1, 4, 5 and 7, and the lock and folder in Sync 3. A pass now downloads only what changed (CHANGELOG, Unreleased), so run Sync 1, 5, 7 and 8 again with Sync 14.

Setup: iPads A and B on the same build and test account, iCloud Drive on, 2 GB free in iCloud, automatic time, the logging profile, and Console on `category:sync`. First turn sync off in OwlLuna everywhere and delete OwlLuna's data in Settings › your name › iCloud. B starts without the app. Run the checks in order (about four hours) and write down the time at each step.

"Sync A": on A, tap Library, then Settings › iCloud › Sync Now, wait for "Last synced" with the time now, and screenshot that line. "Sync A, then B" leaves a minute between. The library's iCloud plate is tomato for trouble and cobalt for conflicted copies. At the first failure, take a sysdiagnose on both.

### Sync 1. First sync

Passed, October 2026.

1. On A, answer "Keep a copy of your notebooks in iCloud?" with Sync with iCloud.
2. Make "Sync 1" with a word on two pages and a photo, "Sync 2" to "Sync 4" with a word each, and four quick notes. Sync A.
3. On B, install the app, tap Sync with iCloud, wait two minutes and Sync B.

Expect: A shows "Syncing … of 8 notebooks", then "Uploading …", and "Not uploaded yet" under covers until they're up. B copies nothing before you answer, then has all eight, whole, with nothing "still downloading" after five minutes. A second pass says "Everything is up to date". No conflicted copy.

### Sync 2. A notebook open on the other iPad

1. On A, open "Sync 1" and go to the Home Screen. On B, write "from B" in it and Sync B. A minute later, go back to OwlLuna on A.
2. With "Sync 1" open on both, write "live A" on A and wait, then "live B" on B. Then write on A without stopping for a minute.
3. On A, Record Audio (a notebook being recorded isn't sent) and write "from A". On B, write "B again".
4. On A, stop recording and tap Keep Both. Tap Library on both, and Sync A, then B.

Expect: A shows "from B" in place within seconds. Live lines reach the other iPad within about half a minute, in place, with no banner or copy, and B catches up at least every half minute while A writes. In step 3 A says "This notebook was changed on another device too…", with no Keep Both until the recording stops. Keep Both keeps B's version as "Sync 1 (conflicted copy)", and B shows A's writing within half a minute. Blank pages on B are a known gap when both send within seconds; write down the time.

### Sync 3. Lock, favourite, folder, tag and sticker

The lock and folder passed in October 2026.

1. On A, Lock… "Sync 2", Favourite "Sync 3", put "Sync 3" in a New Folder "Trip" with a Spine Colour, tag "Sync 4" with "device-check", and add a sticker from a photo (+ › Sticker… › My Stickers › From Photo…). Sync A, then B.
2. On B, rename "Trip" to "Trip 2". Sync B, then A.

Expect: B has the lock (asking for Face ID or Touch ID), the favourite, the coloured folder, the tag and the sticker, and A gets the rename. A lock is never lost.

### Sync 4. Delete and restore

Passed, October 2026. On A, delete "Sync 4", and Sync A, then B. On B, restore it from Recently Deleted, and Sync B, then A. On A, delete it and sync, then Delete Permanently and sync again.

Expect: it waits in B's Recently Deleted, comes back on both with its tag, and at the end goes everywhere for good.

### Sync 5. Offline, and a notebook changed on both

Passed, October 2026.

1. On A, in Airplane Mode with Wi-Fi off, write "A offline" in "Sync 3", rename "Trip 2" to "Trip offline", make "Made offline", and Sync A.
2. On B, write "B online" in "Sync 3", change the folder's colour, Sync B, and wait five minutes.
3. Bring A online, wait two minutes, then Sync A, B and A again.

Expect: step 1 reports no failure ("iCloud can't be reached right now…" is fine), and nothing reaches B in step 2. Then both have "Sync 3" and its conflicted copy, one line each, "Trip offline" in B's colour, and "Made offline". No "Sync stopped".

### Sync 6. Many deletes at once

A pass that would remove more than three notebooks, or over half the library, removes none and asks.

1. On A, in Airplane Mode, delete the four quick notes and empty Recently Deleted. Go online and Sync A.
2. Tap the plate ("4 notebooks weren't deleted") › Keep, and Sync A.
3. Repeat step 1, then Delete on the card and confirm. Sync A, then B.

Expect: step 1 deletes nothing on B and says "4 deletions held back". Keep brings the notes back with their writing. After step 3 they are in B's Recently Deleted, and B never asks.

### Sync 7. A large upload

Passed, October 2026. On A, Import PDF… with 200 pages or more, record 20 minutes into it, write on a few pages and Sync A. Sync B every minute and turn A's Wi-Fi off for 30 seconds partway.

Expect: A shows "Not uploaded yet" until done, then "Everything is up to date", and carries on after the break. B only shows the notebook once all of it is there, recording included. Record both times; there is no target yet.

### Sync 8. Files iCloud hasn't brought down

1. Sync A, then B. Delete the app on B, reinstall it and tap Sync with iCloud. Open a notebook as soon as it appears, and Sync B until "Everything is up to date".
2. Optional, overnight: fill B until iPadOS warns about storage, leave it to evict files, free the space and Sync B.

Expect: every notebook comes back whole, with folders, tags, favourites, locks and stickers, and only appears once whole; no `.icloud` placeholder is ever copied. Nothing is deleted on A. After step 2 every notebook still opens whole.

### Sync 9. The last notebook, reopened at launch

On A, open "Sync 1" and shut A down from Settings (not the app switcher). On B, write "while A was off" in it and Sync B. Start A, wait a minute and open OwlLuna.

Expect: A opens in "Sync 1" with B's line within about four seconds of the splash, with no banner or copy. If it starts in the library, the window wasn't restored; try again.

### Sync 10. A clock that runs fast

On B, set the clock ten minutes ahead, Lock… "Made offline", and Sync B, then A. On A, Remove Lock…, and Sync A, then B. Set B's clock back.

Expect: "Made offline" ends unlocked on both.

### Sync 11. Recently Deleted kept for different lengths

1. Settings › Recently Deleted › Keep Deleted Notebooks For: 7 days on A, 90 days on B.
2. On A, delete "Sync 1 (conflicted copy)". Sync A, then B.
3. Set A's date eight days ahead, reopen OwlLuna, check Recently Deleted, and Sync A, then B. Set the date back and reopen.

Expect: it leaves A's Recently Deleted, stays in B's, and never comes back to A.

### Sync 12. A folder list that can't be read (optional, needs a Mac)

On a Mac with the test account, copy `~/Library/Mobile Documents/iCloud~com~owais~OwlLuna/Sync/folders.json` aside and replace its contents with `not json`. Two minutes later, Sync A. Then tap the plate › Replace, confirm, and Sync A, then B.

Expect: "Folders aren't syncing", with folders untouched and notebooks still syncing until you choose Replace. Then the plate clears and both keep all their folders.

### Sync 13. Another Apple Account (optional)

On B, sign in to a second test account, open OwlLuna and tap Turn Off Sync. Sign back in to the first and turn Sync with iCloud on, choosing Sync with This Account if asked.

Expect: "A different Apple Account is signed in" before anything is copied, then syncing as before with the library intact.

### Sync 14. What sync keeps on the iPad

1. Screenshot Settings › General › iPad Storage on both. Sync each twice, two minutes apart, and screenshot again.
2. On A, write on page 100 of Sync 7's notebook and Sync A. Time Sync B until it arrives, then check the page, the PDF and the recording.
3. In B's Console, write down the count in "files were the same but dated differently", if any.
4. On A, in Airplane Mode, write in "Sync 1" and time Sync A. Go online and Sync A, then B.
5. Optional: set A's date 13 months ahead, Sync A, set it back, reopen OwlLuna, and Sync A, then B.

Expect: step 1 logs "took … files off the device", about one per picture, PDF, recording and transcript, and storage drops by about the PDF and recording (write down which figure moved). Step 2 is far quicker than Sync 7, and nothing downloads twice. Either result in step 3 passes; a count means iCloud changes file dates. The offline pass takes 15 seconds at most. After step 5 the delete markers from Sync 4 and 6 are gone and none of those notebooks returns. No "couldn't evict" lines.

### Sync 15. Smart shelves and the tray's pens

1. On A, tag "Sync 3" with "device-check" and make a New Smart Shelf for it. On B, add a pen in a new colour. Sync A, B, then A.
2. Rename the shelf on B, and make a second shelf on A. Sync B, A, then B.
3. Pick B's pen on A, then remove it on B. Sync B, then A.
4. Delete the second shelf on A. Sync A, then B.

Expect: shelves, renames and deletes reach both, none doubles or comes back, and the pen sits in the same tray slot. After step 3 A holds the pen that took its place. The tray syncs as one list, so the later change wins.

To finish, compare the two libraries notebook by notebook.

## Tool tray

1. Tap New Pen at the end of the tray.
2. For each kind (Pen, Fineliner, Fountain Pen, Calligraphy Pen, Pencil, Highlighter, Crayon, Watercolour): write lightly and hard, tilt to shade, write at both ends of Width, and write over ink at low Opacity.
3. Hover the tip over the page, and write at 5×. Repeat step 2 on Chalkboard paper, and with Settings › Appearance › Dark.
4. With pen and highlighter on the page, rub with Eraser › Whole Strokes, then Part of a Stroke at a narrow and a wide width, undoing each rub.

Expect: each kind looks like its picture in the roll and marks even at the thinnest Width. Low opacity is fainter, never darker. Ink keeps up with the tip, doesn't change on lift, and is sharp at 5×. Swatches match the ink in light, dark and on Chalkboard. The calligraphy pen only appears on iPadOS 26. Whole Strokes takes exactly the strokes touched, Part of a Stroke cuts only under the width shown, one Undo restores one rub, and erasing never scrolls.

## Palm rejection and latency

Palm rejection:

1. ⋯ › Draw With › Apple Pencil Only. Write a paragraph with your hand on the glass, low on the page and near the tray, lifting the palm mid-word.
2. Draw a line and rest the Pencil at its end with the palm down. Draw another without resting.
3. Repeat with Pencil and Finger, scrolling with two fingers while the palm is down. Then write left-handed with Settings › Input › Left-Handed on.

Expect: the palm never draws, scrolls, presses the tray or counts as a rest, and only the rested line straightens. Count stray marks per page on a phone video.

Latency, on a 120 Hz iPad Pro (and a 60 Hz iPad if you can): film fast zigzags at 240 fps in Apple Notes, then in OwlLuna with the Pen on a blank page, a heavy stand-in page, at 5×, with Handwriting to Text on, while recording, and in the zoom window. Count frames from tip to ink, five times per clip.

Expect: within one frame (about 4 ms) of Notes on the same iPad, with no stutter on lift. In a 60-second Time Profiler trace on the heavy page, nothing at stroke end on the main thread comes near 4 ms (the simulator measured 0.12 ms).

## Pencil gestures

### Double-tap and squeeze

1. Set OwlLuna's Settings › Apple Pencil › Double-Tap and Squeeze to System Setting.
2. With iPadOS set to switch to the eraser, double-tap twice. Set it to the last tool, use pen A then pen B, and double-tap.
3. With squeeze set to the palette, squeeze over the page, near its edge, near the tray, and with the tip high up.
4. Try each OwlLuna choice for both: Switch to Eraser, Undo, Select Ink, Show or Hide Tools, Tool Palette at the Pencil, Zoom Window.
5. Try them in focus mode, while presenting, with a sheet open, and in a read-only notebook.

Expect: one action each time, never the system's picker or palette: the eraser and back, then pen A. The ink dish opens centred under the tip, on the pages and clear of the tray (mid-page if the tip is too high), and a tap outside closes it. Focus mode works; the other places do nothing.

### Scribble and loop

Only test strokes have been recognised so far. Turn on Settings › Apple Pencil › Scribble to Erase and Circle and Hold to Select.

1. Scribble back and forth about six times over a word. Do it on 20 words, undoing each.
2. Loop round two words, hold half a second, lift and drag. Do it 20 times. Then loop once more and tap Undo in the bar.
3. Holding each time, box a formula and draw a triangle round a word, 20 of each. Loop a word as roundly as you can and tap Keep Circle, then Undo twice.
4. Write "mmm", "www", loops and cross-hatching, and loop a word without holding. Scribble with the highlighter, crayon and watercolour.

Expect: a scribble erases only what it covers, and Undo brings it back. A held loop selects, the bar counts the strokes, and the loop leaves no ink. Undo gives the loop back as drawn and leaves Select Ink. A held box or triangle round ink straightens instead of selecting. Keep Circle leaves a circle; Undo gives back the loop, a second Undo removes it. Step 4 never erases or selects. Count hits per 20, and whether misses were too strict or too loose.

Tunable (`ScribbleRecognizer`, `LoopRecognizer`, `PencilGestures.keepsFigure`): a scribble needs 5 turns, a length of 4 times its diagonal, and half a stroke under it. A loop's ends meet within 30% of its size or 20 pt, then rest 0.45 s. One that straightens into three or four sides is kept as a shape.

### Draw and hold

With Settings › Apple Pencil › Straighten Shapes on:

1. Draw a line and rest half a second before lifting. Draw one without resting.
2. Resting each time: a circle, ellipse, rectangle, triangle, pentagon, three-piece zigzag, a line with a hook at its end, a line with a barb either side of its tip, and a rectangle round some writing. Undo twice after each.
3. Rest on a shape under 24 pt, and on one in the zoom window. Write a page with your usual pauses.
4. Turn on Shapes (tray › Customise Tools › Shortcuts in the Tray). Drag out each shape fast and slow, with each pen at its usual and thinnest width, then with a finger under Draw With › Apple Pencil Only and Pencil and Finger. Tap Undo on the strip, then Shapes, and write.

Expect: only rested shapes straighten, into the kind drawn. Undo gives your stroke back, and a second Undo removes it. The hook and the barbs both make an arrow with a barb either side. Step 3 stays as drawn, and no L or tick becomes an arrow. Dragged shapes follow the tip, about as wide as the pen writes; a finger scrolls under Apple Pencil Only and draws under Pencil and Finger. One Undo removes a dragged shape. Count straightened holds per 20, and mistakes in handwriting.

Tunable (`ShapeSnap`, `TouchRests`, `ShapeRecognizer`): rest 0.45 s within 6 pt, taken within 2 s of lifting. Smallest shape 24 pt. A closed stroke that runs on past its start is cut there, if the rest stays within a quarter of its size. Three or four sides must fit at least as well as an ellipse. An arrow's hook is up to a third of the line, or barbs up to half, turned back 10° to 65°.

## Zoom window

In a ruled notebook, ⋯ › Zoom Window.

1. Write in the strip until you reach the tinted band, then rest. Write ten lines at each size (Zoom In, Zoom Out).
2. Write a word across into the band without stopping. Rest at the end of a line and at the foot of a page.
3. Drag the outline's tab, and try Move Back Along the Line, Move Along the Line, Next Line and Bring the Zoom Area to This Page.
4. Repeat step 1 with Settings › Input › Left-Handed on.

Expect: the window moves 0.8 s after your last stroke in the band, never mid-word, keeping your last words in view, and goes on to the next line, then the next page. Left-Handed puts the buttons on the left; the band stays right. For each size, write down how many of ten moves felt late, early or right, with your hand and speed.

Tunable (`ZoomWindow`): rest 0.8 s, band the last 30% of the window, move 55% of its width, window 30, 42 or 60% of the page.

## Handwriting to Text

So far it has only read a test's block letters. Turn on tray › Customise Tools › Shortcuts in the Tray › Handwriting to Text, and tap the shortcut.

1. On a ruled page, write a sentence in print, one joined-up, and both small on Narrow Ruled, dotting i's and crossing t's after each word.
2. Carry a sentence onto the next line. Undo once after a word is set. Turn the shortcut off mid-line.
3. ⋯ › Select Ink Across Pages round some writing › Turn into Text. Fix a word, Copy, then Replace Handwriting.

Expect: a sentence becomes one text box in the pen's colour, onto the next line, with dots and crosses in the text. One Undo gives back the ink. Turning the shortcut off sets what was waiting. The first word isn't much slower than the rest. Count wrong words per 20 for print, joined-up and small.

Tunable (`InkTyping`): rest 1.0 s, reading from 0.4 s. Aim for about one second from lift to text. On Debug, compare `-inkTypingPause 0.8` and `1.4`.

## PDF text

Import PDF… a one-column PDF, a two-column paper and a scanned PDF with no text. Turn on Settings › Apple Pencil › Snap Highlighter to PDF Text.

1. ⋯ › Select PDF Text. Drag across words, tap a word, then Select All on This Page. Copy into Notes. Highlight in each Highlight Colour.
2. In the two-column paper, drag along a line into the margin.
3. Tap Done. Draw roughly along a line with the Highlighter, wavy and across two lines. Undo once, then erase a highlight.
4. Repeat on the scanned PDF.

Expect: the selection follows the Pencil letter by letter, stays in its column, and copies in reading order. A snapped stroke is straight, line height, no wider than the letters and on the right line, and nothing snaps with the setting off. The first Undo gives your stroke back. The scanned PDF works within a second of a page showing, though a selection may stop a letter off.

## Camera scan

Use three printed sheets (small print, a table, a creased page), in good and dim light.

1. In a notebook, + › Scan Documents… and scan the three. Undo, then redo.
2. In the library, New › Scan Documents… with two sheets.
3. A minute later, search the library for a printed word, open it, and ⌘F for it.
4. Import PDF… a scanned book of about 100 pages and write in it at once. Later, search for a word near its end.

Expect: the prompt reads "OwlLuna uses the camera to scan paper into your notebooks." Pages go in after the current one, upright, cropped and sharp (up to 2,400 px), and one Undo removes them all. The library scan becomes its own notebook. Search and Find reach printed words. The book stays smooth to write in while its pages are read (each is an "OCR page" signpost).

## Face ID

1. Touch and hold a notebook › Lock…, allowing Face ID.
2. Open it, go to the Home Screen and back, and check the app switcher.
3. Fail Face ID or Touch ID, then use the passcode. Cancel once.
4. Reach it by a link, Open Another Notebook Beside… and Open Another Notebook in a Tab….
5. Export as PDF, then Settings › Backup › Back Up Library….
6. Record Audio in it, pull down Notification Centre, then go to the Home Screen.
7. Remove Lock…. With the iPad's passcode off, try Lock… again.

Expect: the prompt reads "OwlLuna uses Face ID to open the notebooks you have locked." Every way in asks once, and a refusal keeps you out. Coming back shows "“Title” is locked" with Unlock, and the app switcher never shows the pages. Export and backup ask first. The recording survives Notification Centre and is saved at the Home Screen. Without a passcode: "To lock notebooks, set a passcode on this iPad in Settings first."

## Translation

Remove a downloaded Translate language first, such as German. Select some English handwriting with ⋯ › Select Ink Across Pages › Turn into Text, then Translate › German, allowing the download, and Show Original. Offline, translate into a language not downloaded, then decline a download.

Expect: lines translated one by one, kept as lines, under "Translated into German on this iPad." Show Original brings the reading back. Offline or declined, it says it couldn't translate and keeps the original. "Translating…" never hangs.

## Calendar prompt

On a fresh install, with events today (one all day) and over ten on another day:

1. + › Today's Events, and Don't Allow.
2. Allow access in Settings › Privacy & Security › Calendars, then + › Today's Events again.
3. Turn on Settings › Daily Journal › Print Today's Events, and open the next day's page (⌘T in the library).
4. If you can, repeat steps 1 and 2 in Spanish, French or German.

Expect: the prompt reads "OwlLuna reads today's events to print them on a page when you ask it to…", translated where set. A refusal says "OwlLuna isn't allowed to read your calendar…" and leaves the toggle off. Allowed, today's events print as text, all-day first, at most ten lines then "+ N more", and the journal page starts with them.

## Transcription

On an iPad that transcribes English on the device (Settings › Recordings › Transcription Language lists only those), with a two-minute and a 60-minute recording of speech:

1. In Airplane Mode, Recordings › Transcript › Transcribe the short one, timed.
2. Tap three lines, then Replay with Ink. Search the library for a spoken word.
3. Transcribe the long one, timed.
4. In the sheet's Language menu, pick a language Settings leaves out, if offered.

Expect: it works offline and most words are right. Lines break at sentences, pauses or sixteen words. A tapped line plays within about a second of where it was said, and Replay with Ink marks the line being said. The hour is covered with rising times, not evenly spread ones. Search names the recording. Step 4 says "This iPad can't transcribe … on the device…". Keep both times.

## Recording in the background

Set a passcode and Auto-Lock at 2 minutes, use two notebooks (one locked), and play speech throughout.

1. Record until the iPad locks itself, then five minutes more. Record and lock with the top button. Record, then use another app for two minutes.
2. With Stage Manager, record in one window while another plays a recording and tries Record Audio. Close the recording window.
3. Unlock the locked notebook, record for three minutes, then lock the iPad.
4. Record and take a call or ask Siri. Record and close the cover. Record, lock, then take a call.
5. Record, then swipe OwlLuna away (or stop it from Xcode).

Expect: in step 1 the indicator shows, no notice appears, the iPad locks as usual, and recordings run their full length without gaps. In step 2 the other window can neither play nor record while the first carries on, and closing the first leaves "Recording stopped at … when its window was closed." Step 3 keeps the iPad awake, then "… when the notebook locked." Step 4 gives "… when another app needed the microphone" and "… when the iPad's cover was closed", keeps the audio up to the call, and shows no save error. Step 5 gives "… when OwlLuna quit" and plays to the cut. Every recording shares as `.m4a`, and none lists as 0:00.

## Study guide

On iPadOS 26 with Apple Intelligence, use a page of handwritten lecture notes and a 30-page notebook or long PDF.

1. ⋯ › Study Guide…, Write From › the page. Time Summary and Practice Questions.
2. Add to Page, and Save N as Flashcards.
3. Write From › Whole Notebook on the long one, timed. Then a transcribed recording.
4. Open it on an iPad without Apple Intelligence.

Expect: the points match the notes, the answers are in them (write down anything made up), and the long notebook finishes. Without Apple Intelligence it explains why. Look out for "These notes are too long…" and "…wouldn't write about these notes." Notes go in pieces of 3,200 characters (`StudyGuide.chunkLimit`). If the output is nonsense, check library search finds the page's words.

## Control Center

Add OwlLuna's Quick Note and Today's Page controls (Control Center › + › Add a Control). Tap Quick Note with OwlLuna closed, and again just after writing in a notebook. Tap Today's Page from the library, and with two windows open. Set the Action button, if any, to a control and press it.

Expect: each opens one quick note or today's page. Writing is saved first, and the front window opens it.

## Stickers from photos

+ › Sticker… › My Stickers › From Photo… with a pet, a person, a mug, a screenshot and a busy landscape. Enlarge each at 5×.

Expect: "Cutting Out…", then the subject with a white die-cut edge, no halo or background, nothing cut off, within a few seconds (write down how many). The landscape gives "No Subject Found" › Use Whole Photo.

## Spotlight

With Settings › Search › Find Notebooks in Spotlight on, write an unusual handwritten word and an unusual typed word in a notebook with a PDF, and wait a minute. Search Spotlight for the title, each word, a PDF word, and a locked notebook's title, and tap a result. Then rename and search, delete and search, and turn the setting off and search.

Expect: results show the title, "Notebook, N pages" and the cover, and open the notebook. Locked notebooks never show. Only current names show, deleted ones go, and with the setting off nothing shows.

## Tabs

Shortcuts, with three tabs and a keyboard (⌘F never reached the app in the iPadOS 27 simulator):

1. ⇧⌘], ⇧⌘[, ⌃Tab, ⇧⌃Tab, then ⌘W until one notebook is left, and ⌘W again.
2. ⌘F, a word, ⌘G, ⇧⌘G, Esc. ⌘F in the library.
3. Open a notebook and, without touching the screen, press ⌘Z, ⌘N and ⌘F.

Expect: each works once. ⌘W closes tabs, never the window, then goes to the library. ⌘F opens the find bar, or the library's search. Step 3 needs no tap first.

Dragging, with four tabs: drag tabs to the end and the middle with a finger, then a pointer. Hold a tab for Move Left, Move Right, Close Other Tabs and Open Beside. Drop one on the page. Visit the library, then restart the iPad. Expect tabs to land where dropped with no "+" badge or copy, the shown tab to stay shown, the page not to scroll or take the drop, and the order to survive the restart.

Two windows, in Split View and then Stage Manager:

1. Window 1 opens X. Window 2 opens Y and leaves the Open Another Notebook in a Tab… picker up.
2. Window 1 opens Z, then window 2's picker taps Z. Window 2's library taps X.
3. Write in both and change the pen in one. Close one window from the app switcher.

Expect: a notebook open in one window is brought forward there, never opened twice. The pen is shared, both windows save, and the other window carries on.

Many tabs, on an Xcode build: open twelve heavy, PDF and photo notebooks as tabs. For 30 minutes, step through them with ⇧⌘], write, undo, record for five minutes and leave the app twice, writing down memory every five minutes. Expect no crash or `JetsamEvent`, no blank tab, undo kept per tab, and memory levelling off. With twelve open, Open Another Notebook in a Tab… is greyed out. Keep an Allocations trace.

## Resizing the editor

Only checked in the simulator and in tests. Use a written notebook of several pages with two tabs open, and scroll to the lower half of page 3.

1. Loop and hold round some ink so it selects, then Done. Press ⌘F, then Esc. On a PDF page choose Select PDF Text, then Done.
2. Turn the iPad to landscape and back, at 1× and pinched to 5×.
3. Hold a tab for Open Beside, then drag the divider slowly, then quickly, as far as it goes both ways.
4. With Stage Manager on, resize the window by its corner.
5. Repeat steps 2 to 4 while typing in a text box, with the zoom window open, and with a Find match showing.

Expect: step 1 moves nothing as the bars and tabs go and come back. A turn or a resize keeps what you were looking at in view at the same zoom, and turning back puts it where it was. The text box, the zoom window's outline and the match stay where they were on the page and in view. The divider drag stays smooth; ink may look soft while it moves and is sharp a moment after you stop. Keep Animation Hitches for 30 seconds of dragging the divider.

## Second screen

So far only checked with a stand-in window. Connect a display (mirroring, Stage Manager off) and use a notebook with Presenter Notes… on three pages and study tape on one.

1. ⋯ › Present (⌥⌘↩). Draw the laser and change its Laser Colour.
2. Pinch, turn pages with the arrows, the space bar and the bar, and lift the tape.
3. Hide and show the panel with Notes and Next Page. Tap Done.
4. Present, then unplug and replug the display.
5. With Stage Manager on, try step 1 again and write down what happens.

Expect: the display shows only the page, on black, centred, following zoom and lifted tape, with a smooth laser and fading tail. Notes, the next page and the clock stay on the iPad. After Done it mirrors again, and unplugging doesn't stop the presentation or crash.

## Whiteboards

A board has only been laid out at 5× in the simulator, never written on with a Pencil.

1. New › Whiteboard. Write at 1× and small at 5×.
2. Pinch out to 0.15×, drag several screens away and to a corner, and write there at 1× and 5×.
3. Whiteboard › Show Everything, then Actual Size. Pan and pinch with the tools showing.
4. Back to Pages, and reopen the board.
5. Multiply the ink (Select Ink Across Pages, Duplicate) to several thousand strokes. Pan, pinch, Show Everything, reopen.
6. Title menu › Export › This Page as a Time-lapse Video…. ⌘F a word written far out. Present the board on a display.

Expect: ink lands under the tip and is sharp at any distance, with no blank tiles or jumps. Show Everything fits all the ink within about a second, and the board reopens quickly where you left it. Memory levels off. The time-lapse shows all the ink in order, at most twenty seconds. Find brings the word into view, and the display shows the inked area with the laser. Keep Animation Hitches for 30 seconds of panning and Allocations for a minute.

## iPhone

Only checked in the simulator, on an iPhone Duo (iOS 27.1, folded), an iPhone 17 Pro and an iPhone 18 Pro Max. Use an iPhone signed in to the same test Apple Account as the iPads, and an iPhone Duo if you can.

1. Write with a finger. Scroll and pinch with two fingers, then rest the side of your hand on the page while writing.
2. On a folded Duo, use the column on the right: change shelves from its tabs, make a notebook from New, and in the editor take each pen, the eraser and the lasso, Undo, Add and More. Tap the title and the page count at the top of the page.
3. Unfold the Duo with a notebook open, then fold it again. Do the same in the library.
4. On another iPhone, go back from the shelf with the plate at the top left and choose the same place again. Turn the phone to landscape in the library and the editor.
5. Write a page on the iPhone and let it sync to an iPad, then the other way. Open Settings and read the notes under iCloud, Recordings and Search.
6. On a Duo with iOS 27.2 or later, write with an Apple Pencil (USB-C), then with a finger, then look at Settings › Input.

Expect: a finger draws from the first launch, two fingers never draw, and a resting hand makes no marks. After the Pencil's first stroke only the Pencil draws, and Draw With is back in Settings. Nothing in the column sits under the camera or the status bar, and menus open beside it. Unfolding keeps the page and shelf you were on, with the sidebar and the Pages column beside them. The same notebook opens on both devices with its pages and ink. Notes say iPhone, never iPad, and until a Pencil is used Settings has no Draw With, Double-Tap or Squeeze.

## Performance

None of these has been measured on a device yet: the simulator can't see hitches or graphics memory.

Scroll hitches, on a 120 Hz iPad Pro with Animation Hitches: flick for 30 seconds through 500 notebooks (`-seedLibrary 500`), the 300-page PDF and the heavy stand-in, each also at 5×. Expect a hitch time ratio under 5 ms per second, Apple's "good", and no visible hitch as pages load or a pinch ends. On Debug, `-framePacing` shows long frames for comparison.

Memory at 5×: keep both `PERF v2 memory` lines from the heavy fixture's test, then take Allocations while scrolling the heavy stand-in and the PDF, at 1× and 5×, for three minutes each. Expect memory to level off with no warning or `JetsamEvent`. The simulator's heavy figures were 516 MB scrolling and 520 MB at 5×.

Undo budget: undo keeps 48 MB divided by the heaviest page's saved ink, between 20 and 200 steps (`UndoBudget`).

1. From Download Container, take a heavy page's `ink/<page id>.pkdrawing` size and work out its step count.
2. In Allocations, make ten strokes more than that, a second or two apart, between two marked generations.
3. Undo until it greys out, counting. Repeat with 30 strokes on a light page.

Expect: the heavy count matches step 1 and the first ten strokes stay; all 30 light ones undo. Memory grows by at most about twice the count times the file size; more means the budget should use a drawing's size in memory.
