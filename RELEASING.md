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

The tag runs the Release workflow, which fails if the tag doesn't match the app's version and build or the widgets' numbers differ.

When the build is approved for the App Store, tag the same commit with the version:

```bash
git tag -a v1.0.0 'v1.0.0-build.3^{}' -m "OwlLuna 1.0"
```

```bash
git push origin v1.0.0
```

## 5. Publish the GitHub Release

This needs the GitHub CLI, signed in once:

```bash
brew install gh
```

```bash
gh auth login
```

Use the build's changelog section as the notes:

```bash
awk '/^## \[1\.0\.0-build\.3\]/{on=1; next} on && /^(## )?\[/{exit} on' CHANGELOG.md > "$TMPDIR/notes.md"
```

```bash
gh release create v1.0.0-build.3 --verify-tag --prerelease --title "OwlLuna 1.0 (build 3)" --notes-file "$TMPDIR/notes.md"
```

TestFlight builds are prereleases. Leave out `--prerelease` for the App Store release.

## Later: upload from CI

The Release workflow doesn't sign or upload, so it needs no secrets. Uploading from CI would need:

- An App Store Connect API key (Users and Access › Integrations) with a role allowed cloud-managed signing.
- Its key ID, issuer ID and `.p8` file as repository secrets, such as `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8`.
- The archive step without `CODE_SIGNING_ALLOWED=NO`, with `-allowProvisioningUpdates` and the key passed via `-authenticationKeyPath`, `-authenticationKeyID` and `-authenticationKeyIssuerID`.
- An `xcodebuild -exportArchive` step whose export options use method `app-store-connect` and destination `upload`.
- A GitHub environment with a required reviewer, so a pushed tag can't upload without approval.
