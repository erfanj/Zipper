# Distribution, signing and updates

**Status:** no Developer ID credentials were available while this was built, so nothing has been
signed with a Developer ID or notarized. The scripts below are complete; run them with your own
certificate.

## Developer ID (outside the Mac App Store) — recommended

1. `Scripts/build-deps-macos.sh --universal` (or arm64 only).
2. `Scripts/build-app.sh --universal --sign "Developer ID Application: Name (TEAMID)"` — signs
   `Contents/Helpers/*` then the app, with the hardened runtime and
   `Sources/UniversalArchiver/UniversalArchiver.entitlements` (no special entitlements).
3. `Scripts/make-dmg.sh --sign "Developer ID Application: Name (TEAMID)"` — compressed, read-only
   DMG with an Applications link.
4. `xcrun notarytool store-credentials UA_NOTARY …` once, then `Scripts/notarize.sh dist/UniversalArchiver-<version>.dmg`
   — submits, waits, staples, and checks with `spctl`.

For the Quick Look extension and Shortcuts, build with the Xcode project instead (`project.yml`) and
archive/export with "Developer ID" distribution; then run steps 3–4 on the exported app.

## Mac App Store — feasibility

Possible with changes, documented here rather than claimed:

* Use `Packaging/UniversalArchiver-AppStore.entitlements` (App Sandbox, user-selected files,
  bookmarks) and sign helpers with `Packaging/Helper-Inherit.entitlements`.
* Bundled helper executables are allowed if they are signed and inherit the sandbox; 7-Zip (LGPL)
  and unar (LGPL) are acceptable as separate executables, with licence texts and source offers.
* Calling a user-installed `rar`, `zpaq`, `lrzip`, `lzop` or `nomarch` from `/usr/local` or
  `/opt/homebrew` is not possible inside the sandbox: those engines are unavailable in that build.
* "Extract Here" next to the archive requires write access to the archive's folder: the sandboxed
  build must ask the user to grant that folder (or default to a chosen destination).
* Mounting DMGs with `hdiutil` from the sandbox is not possible; DMG browsing would be limited to
  7-Zip's read-only parsing.

## Installation and uninstallation

See [Installation.md](Installation.md).

## Update mechanism (design; not implemented)

No network code is included, so the app works fully offline and never phones home. The recommended
design for direct distribution:

* Use [Sparkle 2](https://sparkle-project.org) with an HTTPS appcast and **EdDSA-signed** update
  archives; the public key lives in Info.plist (`SUPublicEDKey`).
* Updates are checked only if the user enables it (off by default, consistent with the privacy
  policy); the check sends no identifiers beyond the standard Sparkle request.
* Sparkle's installer runs as a separate, sandbox-compatible XPC helper; updates are themselves
  notarized DMGs/ZIPs.
* App Store builds rely on the App Store for updates instead.
