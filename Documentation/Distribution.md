# Building and shipping Zipper

This is the complete path from a fresh Mac to a notarized `Zipper-1.0.0.dmg` that anyone can
download and open. Zipper ships **outside the Mac App Store** with a Developer ID (see the end of this
page for why, and what the App Store would require).

## What you need

| | |
|---|---|
| A Mac | Apple silicon or Intel, macOS 14 Sonoma or later (macOS 15 recommended) |
| Xcode | 16 or later, from the App Store. Open it once to install its components |
| Homebrew | <https://brew.sh>, for XcodeGen |
| Apple Developer Program | $99/year at <https://developer.apple.com/programs/>. Needed for the Developer ID certificate and notarization (not for building and running locally) |

## 1. One-time setup

```sh
xcode-select --install                 # command-line tools (if Xcode hasn't installed them)
sudo xcodebuild -license accept
brew install xcodegen
git clone https://github.com/erfanj/Zipper.git && cd Zipper
```

**Choose the app's identity.** In `project.yml`, set:

* `ZIPPER_BUNDLE_ID`: your reverse-DNS identifier, for example `com.yourname.zipper`. It must be
  unique to you and must never change after release: macOS ties settings, Keychain items and
  permissions to it.
* `DEVELOPMENT_TEAM`: your Team ID, from <https://developer.apple.com/account> › Membership details.

Keep `fallbackBundleIdentifier` in `Sources/ArchiveCore/Model/ProductInfo.swift` equal to
`ZIPPER_BUNDLE_ID` (the command-line tool uses it when it runs outside the app).

**Create your Developer ID certificate.** Go to Xcode › Settings › Accounts, add your Apple ID,
select the team, then **Manage Certificates… › + › Developer ID Application**. Only the team's
Account Holder can create it.

**Store notarization credentials once.** Create an app-specific password at
<https://account.apple.com> › Sign-In and Security › App-Specific Passwords, then run:

```sh
xcrun notarytool store-credentials ZIPPER_NOTARY \
  --apple-id you@example.com --team-id YOURTEAMID --password abcd-efgh-ijkl-mnop
```

## 2. Build the pinned dependencies (once per machine, about 5 minutes)

```sh
Scripts/build-deps-macos.sh            # Apple silicon only
Scripts/build-deps-macos.sh --universal  # Apple silicon + Intel (use this for releases)
```

This downloads libarchive, XZ, Zstandard, LZ4, Brotli and 7-Zip at pinned versions, verifies their
SHA-256 checksums, and builds them into `Vendor/macos` (git-ignored):

* static XCFrameworks, which `Package.swift` picks up automatically;
* the `7zz` helper, which adds RAR, encrypted 7z and split archives.

Nothing from Homebrew ends up in the app. Run it again after changing the script, or after
`git clean`.

## 3. Generate and open the Xcode project

```sh
xcodegen generate
open Zipper.xcodeproj
```

`Zipper.xcodeproj` is generated from `project.yml` and is git-ignored. Run `xcodegen generate`
again whenever you pull changes or add or remove source files. The project has three targets:

* **Zipper**: the app;
* **ZipperQuickLook**: the Space-bar preview in Finder, embedded in the app;
* **ZipperCLI**: the `zipper` tool, copied into `Zipper.app/Contents/Helpers`.

## 4. Run and check it

Choose the **Zipper** scheme and **My Mac**, then press **⌘R**. Debug builds are "Signed to Run
Locally", so no certificate is needed yet.

Things to try on the first run:

1. Drop a folder on the window and choose **Compress**. Then compress again with **Encrypt** and a
   7z format.
2. Double-click the result in the sidebar, press **Space** on a file, drag a file out to the Desktop,
   and click **Extract All**.
3. Control-click a file in Finder and choose **Quick Actions › Compress to ZIP**. If the actions
   don't appear yet, run `/System/Library/CoreServices/pbs -update` or log out and in once.
4. Select an archive in Finder and press Space. If the preview isn't Zipper's yet, run `qlmanage -r`.
   `pluginkit -m -p com.apple.quicklook.preview | grep -i zipper` should list the extension.
5. In Shortcuts, search for "Zipper": Compress, Extract, Verify and more.

Package tests (core, engines, services, CLI) run from Terminal:

```sh
brew install unar zstd lz4 brotli lzip xz      # reference tools; tests needing others are skipped
UA_HELPERS_DIR=$PWD/Vendor/macos/helpers swift test   # the bundled 7-Zip is the engine and the reference
```

## 5. Set the version

In `project.yml`, set `MARKETING_VERSION` (what users see, e.g. `1.0.0`) and increase
`CURRENT_PROJECT_VERSION` (the build number) for every build you distribute. Then run
`xcodegen generate`.

## 6. Archive, sign and notarize

### With Xcode (recommended)

1. Select **Product › Archive**. Release builds are signed with your *Developer ID Application*
   certificate. A build phase signs the embedded helpers (`zipper`, `7zz`) with the same identity,
   the hardened runtime and a secure timestamp, as notarization requires.
2. In the Organizer, choose **Distribute App › Direct Distribution**, then **Distribute**. Xcode
   uploads the app to Apple's notary service, waits (usually a few minutes) and staples the
   ticket.
3. Choose **Export** and save `Zipper.app` into the repository's `dist/` folder.

### From the command line (for scripts and CI)

```sh
xcodebuild -project Zipper.xcodeproj -scheme Zipper -configuration Release \
  -archivePath build/Zipper.xcarchive archive
# put your Team ID in Packaging/ExportOptions.plist first
xcodebuild -exportArchive -archivePath build/Zipper.xcarchive \
  -exportOptionsPlist Packaging/ExportOptions.plist -exportPath dist
Scripts/notarize.sh dist/Zipper.app                      # submits, waits, staples the app
```

## 7. Make the disk image and notarize it

```sh
Scripts/make-dmg.sh dist/Zipper.app --sign "Developer ID Application: Your Name (YOURTEAMID)"
Scripts/notarize.sh dist/Zipper-1.0.0.dmg
```

The result is a compressed, read-only DMG with an Applications shortcut. The app and the DMG are both
stapled, so they open without contacting Apple.

## 8. Verify before you publish

```sh
spctl --assess --type open --context context:primary-signature -v dist/Zipper-1.0.0.dmg   # "accepted, source=Notarized Developer ID"
codesign --verify --deep --strict --verbose=2 dist/Zipper.app
codesign -dv --verbose=4 dist/Zipper.app 2>&1 | grep -E "Authority|TeamIdentifier|Runtime"
for h in dist/Zipper.app/Contents/Helpers/*; do codesign -dv "$h" 2>&1 | grep -E "Authority=Developer ID|flags"; done
```

Then test the DMG the way a user will: download it from where you'll host it, on a Mac (or a new
user account) that has never run Zipper. Check both macOS 14 and the current release, and Intel too
if you built universal. Opening it must show no Gatekeeper warning. Try compress, extract, an
encrypted 7z, Quick Look and a Finder Quick Action.

## 9. Publish

* Upload `Zipper-<version>.dmg`, for example to a GitHub Release. Publish its SHA-256
  (`shasum -a 256 dist/Zipper-*.dmg`) in the release notes.
* Keep the `.xcarchive` (it holds the debug symbols for crash reports).
* Tag the commit: `git tag v1.0.0 && git push --tags`.

**Release checklist:**

* [ ] Version and build number increased.
* [ ] CI green, including the macOS job.
* [ ] Archive notarized and stapled.
* [ ] DMG notarized and stapled.
* [ ] `spctl` accepts both.
* [ ] Tested on clean macOS 14 and current macOS (and Intel, if universal).
* [ ] Quick Look, Quick Actions and Shortcuts work.
* [ ] Release notes and SHA-256 published.

## Troubleshooting

| Problem | Fix |
|---|---|
| `No such module 'CArchive'`, or pkg-config errors | Run `Scripts/build-deps-macos.sh`, then in Xcode use **File › Packages › Reset Package Caches** and build again |
| "Signing for Zipper requires a development team" | Set `DEVELOPMENT_TEAM` in `project.yml` and run `xcodegen generate` |
| "No signing certificate 'Developer ID Application' found" | Create it (step 1). To test a Release build without one, temporarily set Release's `CODE_SIGN_IDENTITY` to `"-"` |
| Notarization rejects a file in `Contents/Helpers` | It wasn't signed with your Developer ID and a timestamp. Archive again (the build phase signs helpers with the Release identity). `xcrun notarytool log <id> --keychain-profile ZIPPER_NOTARY` names the file |
| Quick Look preview not used | Run `qlmanage -r`. Make sure only one copy of Zipper is installed (`mdfind kMDItemCFBundleIdentifier = com.yourname.zipper`) |
| Quick Actions missing | Run `/System/Library/CoreServices/pbs -update`. Check System Settings › Keyboard › Keyboard Shortcuts › Services |

## One command: `Scripts/release.sh`

Steps 2 and 5–8 in one go, on your Mac:

```sh
Scripts/release.sh --sign "Developer ID Application: Your Name (TEAMID)" --team TEAMID --notarize
Scripts/smoke-test-app.sh dist/Zipper.app     # launches it, opens an archive, round-trips an encrypted 7z
```

`release.sh` builds universal libraries if needed, archives, exports, notarizes and staples the
app, builds and notarizes the DMG, mounts it, checks every signature and architecture, and writes
`dist/Zipper-<version>.dmg` plus its `.sha256`. Without `--sign` it makes an ad-hoc-signed DMG for
testing.

## Release builds on GitHub Actions

`.github/workflows/release.yml` does the same on a GitHub-hosted Mac. It runs:

* when you push a version tag (`git tag v1.0.0 && git push --tags`);
* when you start it from **Actions › Release › Run workflow** (once the workflow is on the default
  branch);
* for any pushed commit whose message contains `[release]`.

The DMG, its SHA-256 and screenshots of the running app are attached to the run, under
**Artifacts**. For a version tag with a notarized build, it also drafts a GitHub release with the
DMG attached, which you review and publish.

Without the secrets below it builds an ad-hoc-signed DMG, which is fine for testing on your own Mac.
To sign and notarize, add these in **Settings › Secrets and variables › Actions › New repository
secret**:

| Secret | What to put in it |
|---|---|
| `MACOS_CERTIFICATE_P12` | Your *Developer ID Application* certificate and its private key, base64-encoded. In Keychain Access, find the certificate under **My Certificates**, choose **File › Export Items…**, save it as `.p12` with a password, then run `base64 -i Certificates.p12 \| pbcopy` and paste. |
| `MACOS_CERTIFICATE_PASSWORD` | The password you chose for the `.p12`. |
| `APPLE_TEAM_ID` | Your Team ID (developer.apple.com › Account › Membership details). |
| `NOTARY_KEY_P8` | An App Store Connect API key for notarization. In App Store Connect, go to **Users and Access › Integrations › App Store Connect API**, generate a team key with the *Developer* role, download `AuthKey_XXXXXXXXXX.p8`, and paste its whole contents. Apple lets you download it only once. |
| `NOTARY_KEY_ID` | That key's Key ID (the `XXXXXXXXXX`). |
| `NOTARY_ISSUER_ID` | The Issuer ID shown above the keys list. Leave it unset if you use an individual key. |

The workflow imports the certificate into a temporary keychain that it deletes at the end, and only
the job that drafts the release can write to the repository.

## Building without Xcode's project

`Scripts/build-app.sh [--universal] [--sign "Developer ID Application: …"]` builds `dist/Zipper.app`
with SwiftPM alone. It's handy for quick local builds. It doesn't include the Quick Look extension,
the compiled asset catalog or the Shortcuts metadata, so ship the Xcode build.

## Updates (design; not implemented)

Zipper contains no network code: it works fully offline and never phones home. To add updates to
direct downloads, use [Sparkle 2](https://sparkle-project.org):

* an HTTPS appcast and **EdDSA-signed** update archives, with the public key in Info.plist
  (`SUPublicEDKey`);
* update checks off until the user turns them on (consistent with the privacy policy);
* every update notarized like the first release.

## Mac App Store — feasibility

It's possible with changes, documented here rather than claimed:

* Use `Packaging/Zipper-AppStore.entitlements` (App Sandbox, user-selected files, bookmarks). Sign
  helpers with `Packaging/Helper-Inherit.entitlements`.
* Bundled helpers are allowed if they're signed and inherit the sandbox. 7-Zip and unar (LGPL) are
  acceptable as separate executables, with licence texts and source offers.
* A user-installed `rar`, `zpaq`, `lrzip`, `lzop` or `nomarch` can't be run from inside the sandbox,
  so those engines would be unavailable.
* "Extract Here" next to the archive needs write access to the archive's folder, which the user must
  grant (or the app defaults to a chosen destination).
* Mounting DMGs with `hdiutil` isn't possible from the sandbox. DMG browsing would be limited to
  7-Zip's read-only parsing.
