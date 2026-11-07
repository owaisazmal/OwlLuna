# PDF import investigation (#26)

The [TestFlight report](https://github.com/owaisazmal/OwlLuna/issues/26) shows “The file couldn't be read.” The PDF, its storage provider, the app build and its behavior in Files are unknown. The screenshot does not establish a cause, and the original failure has not been reproduced.

## Findings

The current checkout already includes the changes for [#14](https://github.com/owaisazmal/OwlLuna/issues/14): failed files no longer stop a batch, protected PDFs prompt for a password, and imports show progress. A single failed import now names the file in its notice.

`NotebookPackage.importAsset` held security-scoped access but copied directly from the selected URL. It now coordinates the read and copies from the URL supplied by the coordinator, retaining provider and filesystem errors. This follows [Apple's document picker requirements](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller). Coordination lets a provider or document owner prepare the file before the copy. This is a confirmed gap in the code, but not a confirmed explanation of the report.

PDF parsing now explains that a file may be damaged or unsupported and suggests opening it in Files or exporting a fresh PDF. It also refuses an unreadable page instead of silently omitting it. Empty PDFs and password-protected PDFs retain their separate handling.

New notebooks are assembled in `Arriving/` and moved into the library only after the manifest is written. Failed copies remove their destination asset, including when importing into an existing notebook. Regression coverage checks source coordination, malformed and zero-byte files, missing files in a batch, PDFs with no pages, and skipping a protected PDF after a wrong password. Failures must leave no notebook index entry, library package or staging files.

## Local validation

Passed 54 tests on the iPad Pro 11-inch (M5), iOS 27.0 simulator with Xcode 27.1: `PDFImportTests`, `LibraryStoreSafetyTests`, `NotebookPackageTests`, `PaperShelfTests`, `PDFMarksTests` and `PDFRoundTripV2Tests`. Six new tests cover the import failure paths, including a PDF with an unreadable second page. The coordination test registers a file presenter with pending changes and verifies that the imported copy includes those changes.

The first empty-file fixture incorrectly used a renderer that inserts a blank page. The final fixture uses an empty PDF page tree, which Core Graphics rejects as unreadable. This is distinct from a zero-byte file and neither creates a notebook.

The final `xcodebuild test` run succeeded, and `git diff --check` passed. The initial clean build emitted existing UI-test actor-isolation warnings in `ShapeStripUITests.swift` and a widget App Intents metadata warning. No new compiler warnings were reported for these changes.

On 2026-11-06 the same 54 tests passed again on the iPad Pro 13-inch (M5), iOS 27.0 simulator with the build after 1.0.0-build.5. The error notices were screenshotted on the iPad Pro 11-inch (M5) simulator in portrait and landscape, light and dark: one unreadable PDF on its own ("Lecture 3 notes" wasn't imported, with the damaged-or-unsupported explanation) and the same file in a batch with a readable one (1 of 2 PDFs imported, the file named with "Can't be read"). The shots are in `build/issue-26-screenshots/`, which git ignores. A debug build takes `-importPDFs <path,path>` with `-storageRoot` to bring files in as the shelf shows, which is how they were taken.

## Device checks still needed

Use the current build and record the app version, OS version, provider, file size and whether Files can open the same file. If the reporter can share the original PDF privately, retest that file without assuming it is damaged.

1. Import a readable PDF from On My iPad, then insert it into an existing notebook. Check page count and rendering.
2. Repeat with an iCloud Drive PDF after using Remove Download in Files, with the device online. Repeat with an available third-party file provider. Check that import waits for the source and that all pages arrive.
3. Repeat with the cloud file unavailable offline. Expect an understandable failure, no new notebook or leftover asset, and successful retry after the file becomes available.
4. Import a batch containing a readable PDF, a malformed PDF, a protected PDF and another readable PDF. Try a wrong password, then the right one; repeat and skip instead. Check the named failures and that later files still arrive.
5. For a failed insertion into an existing notebook, compare its page count and `assets/` before and after. For a failed library import, check that `Arriving/` is empty and no incomplete package exists in `Library/`.

These provider and real-device checks are not covered by a local-file simulator test. Keep #26 open until the original report is reproduced or the reporter confirms the current build resolves it.
