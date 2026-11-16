# Releasing OwlLuna

A checklist for each build. Run commands from the repository root. The examples cut build 3 of version 1.0; use your own numbers.

## Version numbers

- `MARKETING_VERSION` is the version people see, such as 1.0. It stays the same for every TestFlight build until that version is approved for the App Store. After that, the next build needs a higher one, such as 1.0.1.
- `CURRENT_PROJECT_VERSION` is the build. It goes up by one for every upload and is never reused.
- TestFlight builds are tagged `v<version>-build.<build>`, so build 3 of 1.0 is `v1.0.0-build.3`. The App Store build also gets the version alone, `v1.0.0`.

## 1. Bump the build

In the project's General › Identity, raise Build on both the **OwlLuna** and **OwlLunaWidgets** targets. Change Version only when the last version is already on the App Store. The two targets must match, or the upload is rejected.

```bash
for t in OwlLuna OwlLunaWidgets; do xcodebuild -project OwlLuna.xcodeproj -target "$t" -configuration Release -showBuildSettings 2>/dev/null | grep -E ' (MARKETING_VERSION|CURRENT_PROJECT_VERSION) = '; done
```

## 2. Update the changelog

In [CHANGELOG.md](CHANGELOG.md), move Unreleased into a new `## [1.0.0-build.3] - YYYY-MM-DD` section and leave Unreleased empty. Update the links at the bottom:

```
[Unreleased]: https://github.com/owaisazmal/OwlLuna/compare/v1.0.0-build.3...HEAD
[1.0.0-build.3]: https://github.com/owaisazmal/OwlLuna/compare/v1.0.0-build.2...v1.0.0-build.3
```

For an App Store build, add a short `## [1.0.0] - YYYY-MM-DD` section above it that names the build, linked to the `v1.0.0` tag.

Commit the bump and the changelog, and archive from that commit with nothing else changed, so the tag matches the build. Push it and let CI pass on it first: its Release builds job builds that commit for iPad, iPhone and the Mac.

## 3. Archive and upload from Xcode

Skip this step once the tag uploads the build: see [Uploading from CI](#uploading-from-ci).

1. Set the destination to Any iOS Device (arm64).
2. Product › Archive.
3. In the Organizer, Distribute App › TestFlight & App Store, and upload.
4. Wait for the build to finish processing in App Store Connect › TestFlight.
5. Fill in What to Test; a short form of the changelog section is enough.
6. Add the build to the external testing group. The first build of a new version waits for Beta App Review.

`ITSAppUsesNonExemptEncryption` is NO, so there is no export compliance question.

## 4. Tag the build

```bash
git tag -a v1.0.0-build.3 -m "OwlLuna 1.0 (build 3)"
```

```bash
git push origin v1.0.0-build.3
```

The tag runs the Release workflow. It fails if the changelog has no section for the build, the tag doesn't match the app's version and build, or the widgets' numbers differ. Then it publishes the build's GitHub Release: a prerelease with the changelog section as its notes.

When the build is approved for the App Store, tag the same commit with the version:

```bash
git tag -a v1.0.0 'v1.0.0-build.3^{}' -m "OwlLuna 1.0"
```

```bash
git push origin v1.0.0
```

## 5. Publish the App Store release

The workflow publishes TestFlight builds only. The App Store release is made by hand, from a checkout whose changelog has the `## [1.0.0]` section. This needs the GitHub CLI, signed in once:

```bash
brew install gh
```

```bash
gh auth login
```

Use the version's changelog section as the notes:

```bash
python3 .github/scripts/release-notes.py v1.0.0 "$TMPDIR/notes.md"
```

```bash
gh release create v1.0.0 --verify-tag --title "OwlLuna 1.0" --notes-file "$TMPDIR/notes.md"
```

## Uploading from CI

The Release workflow can also sign a TestFlight build and upload it when its tag is pushed. That is off until these are in place:

1. An App Store Connect API key (Users and Access › Integrations) with a role allowed cloud-managed signing.
2. A GitHub environment named `testflight` (Settings › Environments) with a required reviewer, so a pushed tag can't upload without approval. Limit it to tags matching `v*`, and give it the key as the secrets `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8`, the text of the `.p8` file.
3. The repository variable `TESTFLIGHT_UPLOAD` set to `true` (Settings › Secrets and variables › Actions › Variables).

From then on, skip step 3: push the tag and approve the upload when the workflow asks. It archives the tagged commit, signs it for the team in `Config/Signing.xcconfig` and uploads it, and the GitHub Release follows once the upload has gone through. What to Test and the external testing group are still set in App Store Connect.
