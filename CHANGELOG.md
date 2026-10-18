# Changelog

## Unreleased: review and release preparation

### Product

* Renamed to **Zipper**: the app, the `zipper` command-line tool, a single bundle identifier setting
  (`ZIPPER_BUNDLE_ID` in `project.yml`), and a new app icon (`Scripts/make-icon.py`).

### App: redesigned for the Mac

* The main window keeps only Home, open archives and Activity in its sidebar. There used to be
  about twenty entries.
* Tools moved to their own window (and the Tools menu); settings live only in the Settings window.
* Compress and Extract are focused sheets with one default button.
* The archive browser works like Finder:
  * list, column and icon views, and a path bar;
  * **Space** for Quick Look and **Return** to open;
  * drag out to extract, drop in to add (with confirmation);
  * an inspector (⌘I).
* The menu bar has full File, Archive and Tools menus with standard shortcuts, plus Open Recent and
  a Dock menu.
* Compression offers *Format* plus *Faster / Normal / Smaller*. Presets are an explicit menu: the
  old "Compression" picker silently changed the format.
* The Simple/Advanced/Expert "interface level" mode is gone. Advanced options sit in a disclosure
  where they apply.
* Settings are consolidated into five tabs; presets are managed in Settings › Compression.
* Notification permission is requested the first time it's useful, not at launch.

### Fixes (app)

* Password and conflict prompts from concurrent operations could receive each other's answers
  (one shared semaphore). Each request now has its own answer box, and prompts are queued native
  alerts that work whichever sheet is open.
* Reading `self.settings` before `init` finished doesn't compile with `@Observable`.
  `ComparisonResult` was ambiguous with Foundation's type. Both would have broken the first Xcode
  build.
* The Compress form:
  * skipped split-size validation when encryption was on;
  * didn't rescan when exclusions changed, but rescanned the whole tree on every slider tick;
  * let an old scan overwrite a newer one;
  * kept a method or encryption the newly chosen format can't use;
  * nested a grouped `Form` in a `ScrollView`, which collapses on macOS.
* The archive browser re-scanned and re-sorted the whole listing several times per redraw. It now
  builds a folder index once, off the main thread, with collision-free row IDs (the old IDs came
  from `hashValue` and could collide).
* "Edit in Default App" re-prompted every 2 seconds after "Not Now". It now prompts once per save.
* Settings side effects (preferred engines) weren't applied at launch, and adding a setting reset
  all the others. Decoding is now tolerant.
* The forms held `unowned` model references (a latent crash).

### Fixes (core)

* **Thread safety:**
  * `EngineRegistry.preferred`, `ArchiveService.performanceMode` and `fallbackPolicy`,
    `OperationCenter.operations` and `mode`, and the history and diagnostic flags were mutated from
    the UI while worker threads read them. They're now lock-protected; concurrent `Dictionary`
    mutation can crash.
  * `OperationCenter` read `pendingInputs` outside its lock and never removed entries.
* **Instant failures:** a fast-failing operation could finish before the app attached its completion
  handler, so the error was never shown. `enqueue` now takes the handler up front.
* **Helper processes:** a helper that exited early could kill the app with SIGPIPE, or crash it via
  `FileHandle.write`'s Objective-C exception. Writes now use the throwing API and SIGPIPE is
  ignored. `HelperProcess` also cleared *every* cancel and pause handler on a shared progress
  object; handlers are now removed by token.
* **App Nap and termination:** long operations could be throttled by App Nap in a hidden window,
  or the app terminated mid-write. Each operation now holds a `ProcessInfo` activity.
* **Keychain:** "Remember password" failed silently with the default "require Touch ID" setting,
  because access-control flags need the data-protection keychain, which Developer ID apps don't get
  without a provisioning profile. Authentication is now enforced with LocalAuthentication.
* **CLI Ctrl-C:** the handler took locks inside a signal handler, which could deadlock. It now uses
  a dispatch signal source, and a second Ctrl-C quits immediately.
* **Progress:** throughput and time remaining counted paused time; snapshots read the paused flag
  without its lock.
* **Error messages:** a file whose name suggested an archive but whose content didn't match showed
  a helper tool's raw JSON. It now reads "not an archive Zipper recognises".
* **7-Zip 26 was silently unusable.** 7-Zip 26 (the version the app bundles) dropped the index
  and update-flags columns from its `7zz i` format table. Zipper's parser skipped every row, so the
  engine reported itself available while supporting no formats. That disabled encrypted 7z,
  encrypted and solid RAR, split archives, Deflate64 and disk images, without any error. Both
  layouts now parse (with tests built from real 23.01 and 26.04 output), and an empty format list
  marks the engine unavailable with a reason, so this can't fail silently again. Linux CI used
  7-Zip 23.01 and couldn't see it; the first macOS test run did.
* **Recovering damaged archives on the Mac:** with libarchive 3.8 (the version the app bundles), a
  corrupt Deflate stream puts the whole reader into a fatal state, so salvage stopped at the first
  damaged file and recovered nothing after it. Salvage now reopens the archive and continues after
  the damaged entry; for ZIP that skip seeks through the central directory. This was found by the
  first macOS test run; Linux's libarchive 3.7.2 hid it.
* **Encrypted split ZIPs:** 7-Zip (which makes split ZIPs) refuses non-ASCII ZIP passwords and
  reported only `E_INVALIDARG`. The engine now explains the rule, and the Compress sheet flags it
  before you start. Unsplit ZIPs (libarchive) and 7z accept any password.

### Build and distribution

* **Xcode build:**
  * `project.yml` used XcodeGen's `info:` and `entitlements:` keys, which **overwrite** the
    hand-written Info.plist (document types, Services, UTIs) and the Quick Look extension's sandbox
    entitlements. The files are now referenced through build settings.
  * The Xcode build needed `PKG_CONFIG_PATH` set inside Xcode. `Scripts/build-deps-macos.sh` now
    produces static XCFrameworks that `Package.swift` uses automatically (module maps in per-module
    folders, so Xcode's shared `include/` doesn't collide).
  * Release builds sign with Developer ID. A build phase signs the embedded helpers with the
    hardened runtime and a secure timestamp, and user-script sandboxing is off for it.
  * The app now has an asset catalog and an icon, and versions come from `MARKETING_VERSION` and
    `CURRENT_PROJECT_VERSION`.
  * libarchive gets the SDK's libxml2 flags (for XAR), since macOS has no pkg-config.
* **Info.plist and Finder Services:**
  * extract, test and convert services were offered for every file; they now only appear for
    archives and disk images;
  * they were disabled by default; `NSRequiredContext` now enables them;
  * `NSPortName` didn't match the app's name;
  * the invented `org.ultimate-archivers` type identifiers are replaced.
* **Quick Look:** the preview could hang on huge compressed tarballs; it now stops after 4 seconds
  with a message.
* **First macOS build:** CI now builds the app with Xcode 16.4, then checks the signature, the
  embedded helpers and the Quick Look extension, and uploads the app. Two compile fixes came out of
  the first run: the archive browser's modifier chain was too long for the type checker in
  reasonable time, and `.quickLookPreview` needs `import QuickLook`.
* **Scripts and CI:** `build-app.sh` left `$(…)` placeholders in Info.plist. `notarize.sh`
  notarizes and staples apps and DMGs and prints Apple's log on rejection. `make-dmg.sh` takes the
  exported app. Added `Packaging/ExportOptions.plist` and a CI workflow (Linux tests; macOS app
  build and artifact).

### Tests

* Added `ZipperMacTests`, 13 tests for the app's model layer. It now compiles on Linux, so the
  type-checker covers every call the UI makes into the core.
* The interop test skips fixtures whose optional helper isn't installed (as documented) instead of
  failing.
* The macOS test run uses the bundled 7-Zip as engine and reference (`UA_HELPERS_DIR`). Tests now
  ignore p7zip builds older than 21.00 (macOS runners ship 17.05, which rejects valid non-ASCII AES
  passwords). The deep-path stress test is sized to macOS's 1,024-byte path limit.
