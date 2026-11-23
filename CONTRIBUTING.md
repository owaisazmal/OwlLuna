# Contributing to OwlLuna

Thanks for helping. Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Workflow

1. For anything bigger than a small fix, open an issue first so we can agree on the approach.
2. Fork the repo and branch from `main`.
3. Keep each pull request to one change.
4. The app should build without warnings and the unit tests (`OwlLunaTests`) should pass. ⌘U also runs the UI tests, which are much slower; CI runs those.
5. For UI changes, add iPad screenshots or a short recording in portrait and landscape, light and dark.

## Checks

Every pull request runs [CI](.github/workflows/ci.yml): a Debug build, the unit tests and one UI test on an iPad, an iPhone Duo and an iPhone simulator, and Release builds for iPad and iPhone and for the Mac. Warnings fail the builds. A test that fails is run once more on a rebooted simulator and fails the check only if it fails again. Each night with a new commit on `main`, the whole UI suite and the accessibility audits run. CI has no iPadOS 18 simulator, since Xcode 27.2 doesn't offer that runtime for download, so the oldest iPadOS the app supports is checked by hand. A change to `website/` alone runs the [website checks](website/README.md#checks) instead, and a change under `.github/` also runs [actionlint](.github/workflows/lint.yml) on the workflows.

CI builds with Xcode 27.2. When the app moves to a newer Xcode, change `DEVELOPER_DIR` in `ci.yml` and `release.yml` too.

## Code style

- Swift and SwiftUI, with UIKit where PencilKit needs it (`Canvas/`).
- Match the code around you: small types, clear names, few comments. Add a short comment only when the reason isn't obvious.
- The project uses folder-synchronised groups, so a new file only needs to go in the right folder.
- Page geometry lives in `PageStackLayout`; cover changes to it with unit tests.
- No third-party dependencies without an issue first. The app uses Apple frameworks only.

## Privacy

OwlLuna collects no data. Don't add analytics, tracking, ads, or network calls that send user content anywhere.

## Reporting bugs

Use the bug report form in [GitHub Issues](https://github.com/owaisazmal/OwlLuna/issues/new/choose). Include your iPad model, iPadOS version, the app's version and build, the steps, and what you expected. For drawing bugs, say whether you used Apple Pencil or a finger.

A question about how something works, or an idea that isn't worked out yet, goes in [GitHub Discussions](https://github.com/owaisazmal/OwlLuna/discussions).

Issues and Discussions are public. Report security problems, or privacy questions about your own notes, privately: see [SECURITY.md](SECURITY.md).
