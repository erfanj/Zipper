# End-to-end test report — November 2026

A full pass over every feature of Zipper, taken from the latest app branch
(`claude/youthful-wright-9b87vv`, which contains all of `claude/universal-archiver`), plus the landing
page on `claude/sleepy-dijkstra-wru6tt`. Fixes are on the testing branch
`claude/ecstatic-maxwell-twm3dm`, one commit per area.

## How it was tested

| Layer | How | Where |
|---|---|---|
| Existing suite | `swift test` (125 tests) before any change, as a baseline: all passed | Linux, Swift 6.1.3 (CI's toolchain) |
| Command line | Every command and option run by hand against real files; outputs checked with independent tools (7-Zip, Info-ZIP, GNU tar, bsdtar, Python `zipfile`, `sha256sum`/`md5sum`), every format round-tripped and compared with `diff -r` | Linux |
| App model | New `AppFlowTests` (49 tests): the calls the views and menus make, against real archives, with alerts, Finder and the Dock replaced by a recording fake | Linux and macOS CI |
| App UI | New `ZipperUITests` (XCUITest): windows, menus, sidebar, sheets and shortcuts in the real app | macOS CI |
| CLI regression | New `CLITests` (9 tests) run the built `zipper` executable | Linux and macOS CI |
| Landing page | Chromium (Playwright): assets, console, anchors, tabs by mouse and keyboard, download button with a release, with a 404 and offline, 320–414 px phone widths, dark mode, reduced motion, JavaScript off | Linux |

What worked from the start: all 16 writable formats round-trip byte-for-byte (ZIP, 7z, tar and its gzip,
xz, zstd, bzip2, lz4, brotli and lzip variants, cpio, ISO, XAR, CBZ, EPUB, JAR); AES-256 and ZipCrypto ZIP,
7z with hidden names, wrong-password handling and exit codes; split ZIP and encrypted split 7z; missing
volume detection; transactional editing of ZIP, 7z and tar.gz (a failed edit leaves the original
byte-identical); convert with SHA-256 verification; compare, duplicates, checksums and manifests;
split/join with corruption detection; ZIP central-directory repair; extraction modes and conflict
handling; the landing page.

## Findings

Severity: **critical** = crash or data loss; **high** = wrong result the user may act on;
**medium** = a feature misbehaves; **low** = cosmetic or misleading text. All are fixed unless noted.

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | Critical | **`zipper compress … -o OUT --force` deleted OUT before compressing.** If compression then failed, the existing archive was lost; if OUT was a folder, the folder and everything in it were deleted recursively (reproduced: `-o important --force` deleted `important/thesis.txt`). | A folder is refused; nothing is deleted up front; the new archive is moved over the old one with `rename(2)` only after it was created. |
| 2 | Critical | **Crash whenever a folder reached archive-reading or hashing code** (`FileHandle.readData(ofLength:)` traps on EISDIR; on macOS it raises an uncaught exception). CLI: `list`, `info`, `test`, `extract`, `convert`, `repair`, `analyze`, `duplicates`, `compare`, `edit`, `hash` and `split` on a folder all died with SIGILL. App: dropping a folder on any Tools list (Convert crashes with no click, from its warnings task), Save Checksum File… with a folder listed. Split and Join also *wrote* with the trapping API, so a full disk crashed them. | All file reads, writes and seeks go through throwing helpers (`SafeFileIO.swift`); a folder is reported as "not an archive" or "is a folder". |
| 3 | High | **After an edit rebuilt an archive, the browser's selection pointed at a different file** (b.txt selected → a.txt highlighted), and ⌘⌫ then offered to delete that file. Row IDs are entry indexes and change on rebuild. | The selection is kept by path. An older, slower listing can also no longer overwrite a newer one. |
| 4 | Medium | Dropping or opening a ZIP-based document (`.docx`, `.xlsx`, `.pptx`, `.pages`, `.key`, `.odt`…) to compress it **opened it as an archive** instead: such files are detected as plain ZIP by content, and the guard only checked the "package" category. | Content-only ZIP detection in a file with another extension is treated as a document. |
| 5 | Medium | Batch Extract skipped the second of two *different* archives with the same name (`Photos.zip`, `Photos.tar.gz`) as "already extracted": the folder it saw had just been created by the same run. | Only folders that existed before the run count. |
| 6 | Medium | A split compress whose `name.ext.001` already existed failed with "already exists" instead of choosing `name 2.ext` like every other compress. In the app, compressing the same items twice with *Split into parts* failed. | Free names also check the `.001` part. |
| 7 | Medium | CLI silently ignored invalid values: `--threads abc`, `--word-size abc`, `--performance turbo`, `--max-size lots` (a safety limit), `advise --intent nonsense`, `hash --algo sha3` (silently produced **SHA-256** under exit code 0), `genpass --length 0` (a 4-character "very weak" password). | All are usage errors (exit 2). |
| 8 | Medium | `extract --only PATH` with a path not in the archive reported success ("0 files") and left an empty folder. | Error: "“PATH” is not in the archive." |
| 9 | Medium | Repair and Compare showed results for an archive the user had switched away from while they ran; Checksums kept results for removed files and its checksum file included folders. | Results are applied only to the inputs they belong to. |
| 10 | Medium | Settings › Extraction › Restore Defaults: the size fields kept showing the old values, and leaving a field then committed the old text, **silently undoing the restore**. | Fields follow external changes. |
| 11 | Medium | Showing a new password (eye button) hid a mismatched Confirm field but kept "The passwords don't match", with no field left to fix it. | Showing the password makes the confirmation match it. |
| 12 | Low | Clear History in Settings didn't refresh Activity › History. | Both reload from a history version. |
| 13 | Low | The Compress sheet's "Counting…" could stay on after an interrupted scan. | Cleared on every path. |
| 14 | Low | ⌘-clicking the selected sidebar item left nothing selected while the detail still showed it. | The sidebar always has a selection. |
| 15 | Low | Missing parts suggested a "Locate Missing Part…" command that doesn't exist. A split ZIP's edit error said "ZIP archives can't be modified in place … Convert the archive to ZIP". | Accurate text. |
| 16 | Low | "1 KB" as a split or volume size failed with "must be at least 1 KB" (KB is decimal here; the minimum was 1,024 bytes). `split` said "1 parts". | 1 KB accepted; plural fixed. |
| 17 | Test hygiene | The app-model tests would have written to the developer's real Application Support folder (history, presets). | `AppModel` takes a support directory; tests use a temporary one. |

### Not bugs, noted

* Landing page: four 404s for `assets/screenshots/*.png` on every visit. This is by design (the page
  falls back to drawn windows until real screenshots are added), but it shows as console errors.
* Info-ZIP `unzip -l` displays Unicode names as `#U00fc…` in a C locale; the archives are correct
  (UTF-8 flag set, verified with Python and 7-Zip).

### Still not covered by automation

Drag and drop between Finder and the app, Quick Look inside Finder, Finder Quick Actions and Shortcuts at
run time, VoiceOver, and the Keychain. They need a person or a signed build on a real Mac; see the
release checklist in [Distribution.md](Distribution.md).

## Test counts

| | Before | After |
|---|---|---|
| Package tests (`swift test`, Linux) | 125 (3 skipped) | 187 (3 skipped), 0 failures |
| UI tests (XCUITest, macOS CI) | none | see the CI run for this branch |
