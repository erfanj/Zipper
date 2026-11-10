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
| 17 | Low | Activity redrew every row twice a second, finished operations included, for as long as it was open. | Only queued, running and paused rows redraw. |
| 18 | Test hygiene | The app-model tests would have written to the developer's real Application Support folder (history, presets). | `AppModel` takes a support directory; tests use a temporary one. |

### Not bugs, noted

* Landing page: four 404s for `assets/screenshots/*.png` on every visit. This is by design (the page
  falls back to drawn windows until real screenshots are added), but it shows as console errors.
* Info-ZIP `unzip -l` displays Unicode names as `#U00fc…` in a C locale; the archives are correct
  (UTF-8 flag set, verified with Python and 7-Zip).

### Still not covered by automation

Drag and drop between Finder and the app, Quick Look inside Finder, Finder Quick Actions and Shortcuts at
run time, VoiceOver, and the Keychain. They need a person or a signed build on a real Mac; see the
release checklist in [Distribution.md](Distribution.md).

## Robustness pass

A second round aimed at what a feature test doesn't reach: work running at the same time, other
programs touching the same files, hostile names and archives, processes that die, and long runs.

| Check | How | Result |
|---|---|---|
| Data races | Whole suite under Thread Sanitizer (`swift test --sanitize=thread`) | No race in Zipper. One in a test (fixed). |
| Memory errors and leaks | Whole suite under Address Sanitizer | No memory-safety errors. Leaks found and fixed: below. |
| Concurrent edits | Six adds and a rename started together on one archive | Lost data (fixed) |
| Archive changed by another app mid-edit | Replaced while Zipper was rebuilding it | Overwritten (fixed) |
| Ctrl-C | SIGINT during compress (tar.xz, 7z, zip) and extract | Exit 130, nothing left behind |
| Crash / force quit | SIGKILL during compress | Hidden partial files left forever (fixed); 7-Zip helper keeps running (documented, follow-up) |
| Awkward names | Leading dash, tab, newline, quotes, colon, `*?`, NFD, 240-character names, CJK folders, emoji | Round-trip in ZIP, 7z, tar.gz; a newline was silently dropped from 7z (fixed) |
| Destinations | Folder compressed into itself; destination is a file; read-only folder | Correct, or a clear error |
| Empty inputs | Empty files and folders; a 22-byte empty ZIP; a 0-byte `.zip` | Correct; the 0-byte file opened as an archive (fixed) |
| Hostile archives in the browser | `../`, absolute and duplicate paths, 300 levels deep; every malicious and interop fixture | No crash, no endless walk |
| Huge archive in the browser | 202,000 entries | Indexed and browsed in ~4 s (debug build) |
| Files over 4 GB | `UA_RUN_LARGE_TESTS=1` (ZIP64 and the large stress cases) | Pass |
| Fuzzing | 150 iterations × 11 formats (1,650 mutated archives) | No crash, no escape |
| Objects outliving their use | Weak references to `ArchiveService`, `AppModel`, `BrowserState` and progress objects after use | Progress objects leaked on every compression (fixed) |

| # | Severity | Finding | Fix |
|---|---|---|---|
| R1 | High | **Concurrent edits of one archive lost data.** Each rebuilt from the original and the last to finish replaced the others (six adds and a rename → two adds survived). In the app: Add, then Rename or Update Archive before the first rebuild finishes. | Edits of one archive run one at a time, each on top of the previous one. |
| R2 | High | **An archive replaced by another app during an edit was overwritten** with a rebuild of the old contents. | The archive's identity is checked before the swap; the other version is kept and the user is told. |
| R3 | Medium | **Every cancelled compression leaked its encoder's memory** (7.5 MB per cancelled bzip2 compression; zlib too): failing the write callback makes libarchive skip closing its filters. | For bzip2 and zlib, a cancellation discards the output and the handle is closed normally in the background. zstd and helper-program filters keep the immediate abort (they'd keep working for seconds). |
| R4 | Medium | **Every compression leaked two progress objects and their handlers** (a retain cycle between the operation's progress and the per-archive one). | Weak references, removed after each archive. |
| R5 | Medium | **Crash leftovers:** after a crash or force quit, hidden partial files (as large as the archive) stayed next to the user's files forever. | Temporary items carry the owning process's ID; the next operation in that folder removes those of processes that are gone. |
| R6 | Medium | A file name with a line break was **silently left out of 7z archives**. | 7z refuses with a clear message; ZIP and TAR keep the name. |
| R7 | Low | A 0-byte file named `.zip` opened as an empty archive. | Reported as not an archive. |
| R8 | Test | A data race in `StressTests` (reading a value the sampling thread was still writing). | The test waits for the sampler to stop. |

Documented rather than fixed: a killed Zipper's 7-Zip helper finishes its job in the background (its
output is discarded); a backslash in a name is extracted as a folder separator in every format, on
purpose, because archives made on Windows use it that way.

## Test counts

| | Before | After |
|---|---|---|
| Package tests (`swift test`, Linux) | 125 (3 skipped) | 203 (3 skipped), 0 failures |
| Package tests on macOS CI (Xcode 16.4, bundled libarchive and 7-Zip) | 125 | 203 (3 skipped), 0 failures |
| UI tests (XCUITest, macOS CI) | none | 10, 0 failures |

The UI suite took four CI rounds to settle. Every failure on the way was in the tests, not the app:
a window clicked while another covered it; sample files written by the test runner, whose container
macOS protects from other apps (the app now makes its own, Debug builds only); and a query that asked
`CONTAINS` of numeric values, which XCTest reports as a time-out. Final run:
[CI #19](https://github.com/erfanj/Zipper/actions/runs/41496372931).

## Production-readiness pass

A third round, on branch `claude/ecstatic-maxwell-twm3dm` from `main` at `28bd667`. The question
this time: what would a consumer hit that a feature test and a robustness test don't? The plan below
is what a release needs; the last column says honestly how far each part got.

| # | Area | What was done | Status |
|---|---|---|---|
| 1 | Regression | The whole suite on Linux, with the final code | Done: 245 tests, 0 failures (11 skipped: the 8 that need a case-insensitive disk, 2 that need a licensed `rar`, the >4 GB test) |
| 2 | A Mac's file system | The whole suite again with every temporary folder on a case-insensitive, case-preserving volume (a Mac's default), plus eight tests written for it | Done: 245 tests, 0 failures (4 skipped). Unicode-normalising behaviour (APFS treats `é` typed two ways as one name) can't be reproduced on Linux; the name comparison is unit-tested instead |
| 3 | Security review | Every place archive content meets the system, read and attacked: links, names, "open with", previews, helper programs, Finder services, the Quick Look extension | Done: two holes found and closed (P1, P2) |
| 4 | Privacy | No network code anywhere in the app, tools or extension; what history, settings and logs store | Done: nothing found |
| 5 | Resource hygiene | 60 rounds of the main operations, including failures, cancels and safety-limit stops, counting open file descriptors and temporary items before and after | Done: no leak |
| 6 | Damaged saved state | Garbage, truncated and partly valid History, Presets, settings and recent items; then launch and use | Done: one data-loss bug (P7) |
| 7 | Every message a user can see | Every error case: a title, a finished sentence, no internals showing, and every "Tools › …" or "Settings › …" it names must exist | Done: P11 |
| 8 | Command line | Mistyped and unknown options, wording, one-character names | Done: P3, P8 |
| 9 | Build hygiene | Zero compiler warnings in app, tools and tests; `shellcheck` on the build and release scripts | Done: all warnings fixed (P13); the scripts' two remaining notes are harmless |
| 10 | Data races in the new code | The suites that touch what changed (66 tests: helpers, 7-Zip, hostile archives, links, edits, saved state, operations) under Thread Sanitizer | Done: no race |
| 11 | Fuzzing, again | The 660 mutated archives on each disk, a 4,400-archive sweep, and 30,000 mutations fed straight to `lsar`, all with a watcher on the helpers' memory | Done: P9 |
| 12 | The release itself | Universal Release build, DMG, signature, notarization, Gatekeeper on a clean Mac, installing over an older version | **Not done.** Needs macOS; GitHub Actions refuses every job for this repository (no runner is assigned; the run fails in 1 to 4 s) |
| 13 | The app's windows | The 10 XCUITests on this branch, an accessibility audit, VoiceOver, keyboard-only use, dark mode, large text | **Not done**, same reason |
| 14 | Mac integration | Finder Quick Actions, Quick Look in Finder, drag and drop, Dock progress, notifications, Shortcuts, Keychain and Touch ID, iCloud Drive, exFAT and network disks | **Not done**, same reason |
| 15 | Performance on a Mac | Speed, memory and energy on Apple silicon with a large archive | **Not done**, same reason |

### Findings

| # | Severity | Finding | Fix |
|---|---|---|---|
| P1 | High (security) | **A link could leave the destination through another link.** With the default "safe links only" setting, an archive holding `sub/up → ..` and `sub/escape → up/../secret.txt` was extracted with both links: each target reads as staying inside, but followed on disk the second one is a file *next to* the destination, and a deeper chain reached `/`. Nothing was written outside, but the extracted folder then held a link to the user's own files, which a later copy, upload or re-compress would follow. | After extraction, every link the archive created is followed hop by hop against what is really on disk (the user's own links included). One that ends outside is removed and listed as blocked. Order, depth and loops don't matter. |
| P2 | High (security) | **"Edit in Default App" could run a script from an archive.** The temporary copy kept the entry's executable permission, and macOS runs an executable file with no known type in Terminal when asked to open it; `.command` files are run, `.terminal` and `.webloc` files can carry a command or address. | The copy is never executable (and is private to the user); types macOS runs or installs when opened are refused with an explanation. The entry keeps its own permissions in the archive when the edit is saved. |
| P3 | High (crash) | **A file or folder with a one-character name crashed `zipper`** on Linux when making a 7z or RAR archive or renaming an entry (`zipper compress S -o a.7z`): Foundation's path function traps on such names there. | Paths are split by Zipper's own code. |
| P4 | Medium | On a Mac's disk, **editing or converting an archive whose names differ only by case** (`Readme.txt`, `README.TXT`), or that holds one name twice, failed after doing all the work with "verification failed: missing README.TXT", which reads like damage. | Detected up front; a message names the two items and says to extract instead. The archive isn't touched. Extraction already kept every file (one renamed, and reported). |
| P5 | Medium | On a Mac's disk, **renaming only the case of an entry** (`report.txt` → `Report.txt`) was refused with "already exists". | Recognised as the same item and renamed. A real clash is still refused. |
| P6 | Medium | Extracting **directly into a folder with "Skip existing"** reported the skipped files as extracted ("2 files, 8 bytes" when nothing was written). | The summary counts what was written and adds "N existing items skipped". |
| P7 | Medium (data loss) | **One unreadable entry in the saved presets or history emptied the whole list**, and the next save wrote the empty list over the file: all custom presets gone after, say, an older build wrote a value this one doesn't know. | Entries are read one by one; the unreadable ones are skipped, and a copy of the original file is kept next to it (`Presets.unreadable.json`). |
| P8 | Medium | **`zipper` ignored options it didn't know.** `--encypt aes256` made an archive with no password, `--hide-name` left the file names readable, `-d out` extracted into the current folder; all with exit code 0. | Unknown options stop the command (exit 2) with a suggestion: "Unknown option “--encypt”. Did you mean --encrypt?". `--help` works after a command. |
| P9 | Medium | **A damaged archive could make a helper program take all the memory, or run for ever.** During the fuzz run on the second disk the kernel stopped `lsar` three times at 13.6 GB. (`lsar` and `unar` are The Unarchiver's tools; Zipper falls back to them when they are installed, they aren't bundled.) Feeding 30,000 mutated archives straight to `lsar` found five that do it: two 2.5 KB `.7z` files that make it allocate without end, and three `.xz` streams that it decodes for ever. Zipper put no bound on a helper's memory or time, and a helper that was only listing or testing couldn't be cancelled: `zipper test` on such a file never returned, and an unattended extraction would have kept a processor busy until someone noticed. | Helpers that read archives are stopped once they hold more than half the computer's memory (2 GB for The Unarchiver's tools). Those tools also get a time allowance: two minutes plus half a minute per megabyte of archive, pauses not counted. The message says what was stopped and why. Listing and testing through a helper respond to Cancel. Two of the files are now fixtures with their own tests. Helpers that create archives are exempt: what they need follows from the user's settings. |
| P10 | Low | Modification dates were lost on disks whose driver ignores "set only the modified time" (some FUSE and network file systems). | Both times are set explicitly. |
| P11 | Low | Messages: three pointed at things that don't exist ("Tools › Split File", "Settings › Advanced › Format capabilities", an engine chooser in Settings); eight ended mid-sentence when a detail was added ("…reported an error: fatal"); "1 files", "item(s)". | Corrected, and `ErrorMessageTests` now checks every error's text and every place it names. |
| P12 | Low | Recent items could list an empty entry or a folder. | Filtered on load. |
| P13 | Code health | Compiler warnings in the app, tools and tests, among them shared state in the helper-program runner that the compiler couldn't prove safe. | That state now lives in one locked object; the build has no warnings. |

Checked and found sound, so unchanged: extraction on a case-insensitive disk keeps every colliding
file and verification understands the renames; writing "through" a link under another spelling is
blocked; the ten Finder services in Info.plist match the code that serves them; the Quick Look
extension is sandboxed and read-only; helper programs are looked up only in fixed folders and
refused if others can write to them; previews are read-only copies in a private folder; damaged
state files never stop the app from launching.

### What this does not show

Nothing in this pass ran on a Mac. The code compiles and passes on Linux, where the app's model
layer and everything below it are the same code; the SwiftUI views, the Quick Look extension and the
macOS-only engines were not compiled for this branch at all. Before this is released, rows 12 to 15
above need to run. Once GitHub Actions accepts jobs again, the CI workflow builds the app and runs
the UI tests of row 13 on this branch (re-run it; the last commit message carries `[macos]`), and the
release workflow builds and smoke-tests the DMG of row 12. Rows 14 and 15, and the parts of 12 and 13
no workflow covers, are an afternoon by hand with the checklist in
[Distribution.md](Distribution.md). Two things are worth adding then, since they can't be written
blind: an XCUITest that calls `performAccessibilityAudit()` on each window, and a timing run on Apple
silicon. One piece of this pass is Mac-specific and so unproven: on macOS the helper memory guard
reads a helper's memory through `/bin/ps`; that code path is tested here on Linux, not on a Mac.

| | Before this pass | After |
|---|---|---|
| Package tests (`swift test`, Linux) | 203 (3 skipped) | 245 (11 skipped), 0 failures |
| The same on a case-insensitive volume | not run | 245 (4 skipped), 0 failures |
| Compiler warnings | some, in sources and tests | 0 |
