# Testing

## How to run

```sh
export PATH=/opt/swift/usr/bin:$PATH            # or any Swift 5.10+ toolchain
Scripts/make-interop-fixtures.sh                 # regenerates fixtures (disk images are not committed)
swift build --build-tests
swift test --skip-build                          # full suite
UA_RUN_LARGE_TESTS=1 swift test --skip-build     # adds the >4 GB ZIP64 and 2 GB streaming cases
swift test --skip-build --filter SecurityTests   # one target
UA_CASE_INSENSITIVE_DIR=/mnt/ci/t swift test --skip-build --filter CaseInsensitiveVolumeTests
```

`CaseInsensitiveVolumeTests` need a disk that treats `A.txt` and `a.txt` as one file. On a Mac that
is the default, so they always run there. On Linux they are skipped unless `UA_CASE_INSENSITIVE_DIR`
names a folder on such a mount (for example `ciopfs /mnt/ci-store /mnt/ci`); setting
`TMPDIR=/mnt/ci/tmp` as well runs the *whole* suite on it.

The helper-based tests need the reference tools on `PATH` (Linux package names): `7zip` + `7zip-rar`
(or a 7-Zip 23+ `7zz`), `unar`/`lsar`, `zip`/`unzip`, `rar` (RARLAB, optional), `lzip`, `lzop`,
`zpaq`, `lrzip`, `nomarch`, `jlha`/`lha`, `python3`. Tests whose tool is missing are **skipped with a
reason**, never reported as passed. On macOS, `Scripts/build-deps-macos.sh` builds the bundled 7-Zip
and libraries; point the tests at that 7-Zip with
`UA_HELPERS_DIR=$PWD/Vendor/macos/helpers swift test --skip-build` (the CI job does). The reference
7-Zip must be the official program, 21.00 or later: older p7zip builds (macOS runners ship 17.05)
are ignored, because they mishandle non-ASCII ZIP passwords.

## Inventory

| Target | Suites | Tests | What it covers |
|---|---|---:|---|
| ArchiveCoreTests | SafePathTests, GlobAndFilterTests, DetectionTests, IntegrityTests, PresetTests, AdvisorTests, ProgressTests | 18 | Path validation (traversal, absolute, backslash, NUL, Unicode normalisation), glob filters, content-first detection, multipart naming, CRC/SHA hashing, preset JSON without secrets, advisor rules, progress/cancel/pause |
| ArchiveEnginesTests | LibArchiveEngineTests | 21 | Round trips for ZIP (store/deflate/AES-256), 7z, TAR with gz/bz2/xz/zst/lz4/lzip/lzma/Z/brotli, cpio, xar, single-file streams, wrong password, selective extraction, EPUB packaging |
| | SevenZipEngineTests | 5 | Header-encrypted 7z hides names, multi-volume create/extract/missing volume, AES ZIP read by reference `unzip`, encrypted RAR5, selective extraction |
| | SpecialistEngineTests | 2 | RAR creation (incl. encrypted headers) through a licensed `rar`; ISO/ar/other writers round trip |
| ArchiverKitTests | ExtractionServiceTests, CompressionServiceTests, ToolsTests | 28 | Smart/here/new-folder extraction, conflict policies, folder merging, bounded nested extraction, batch, missing volumes, engine fallback, naming, encryption validation, format-aware options, ZIP64 >4 GB, conversion with SHA-256 verification, transactional edits, repair and salvage, split/join, checksum manifests, compare/duplicates, content search/preview, password tools, history privacy, operation queue, capability matrix honesty |
| | StressTests | 7 | Cancellation (ZIP, tar.xz, tar.zst, tar.bz2 at level 9, early and late) returns within 5 s and leaves no output; cancelled extraction leaves nothing, pause/resume, low-disk watchdog, 20,000 small files, deep directories and 255-byte names, bounded memory while streaming |
| SecurityTests | MaliciousArchiveTests | 16 | Committed malicious fixtures: zip-slip, absolute paths, backslash traversal, symlink and hard-link escapes, planted symlink parents, device/FIFO entries, setuid stripping, zip bomb ratio/size/count limits, nested bombs, helper-engine output passed through the same checks |
| | FuzzTests | 1 | Mutated archives (bit flips, byte overwrites, header/trailer corruption, truncation, splicing) of ZIP, 7z, TAR, tar.gz/bz2/xz/zst/lz4/br, cpio and gzip through listing, testing and extraction: no crash, hang or file outside the destination. `UA_FUZZ_ITERATIONS` (default 60 per format) scales it |
| InteropTests | ForwardInteropTests | 2 | 77 fixtures made by reference tools (Info-ZIP, 7-Zip, RAR 7, WinRAR-made RAR 2/3 corpus, GNU tar, bsdtar, gzip/bzip2/xz/zstd/lz4/lzip/lzop/brotli, cpio, ar, ISO, LHA, ARC, ZPAQ, lrzip, uuencode, …) listed and extracted with byte comparison; legacy Shift-JIS/CP437 name decoding |
| | ReverseInteropTests | 8 | Our output read by independent tools: Info-ZIP + Python `zipfile`, 7-Zip (AES ZIP, 7z, split 7z), GNU tar, reference stream decoders, OCF rules for EPUB, metadata preserved for GNU tar |
| ZipperMacTests | FolderIndexTests, FormTests, SettingsTests | 13 | The app's model layer: the archive browser's folder index (implicit folders, unique row IDs, folders first, whole-archive search), Compress/Extract form rules (password confirmation, split sizes with encryption, single-file streams, dropping settings a format can't use, rescans only when the file set changes), tolerant settings decoding |
| **Total** | | **121** | |

`Tests/UATestSupport` holds shared helpers: temporary directories, the Unicode sample tree (Persian,
Arabic, Chinese, Japanese, Korean, Hindi, Cyrillic, accents, emoji, deep paths, empty folders,
symlinks), tree comparison and a process runner.

## Fixtures

* `Fixtures/Malicious/` — committed, generated by `Scripts/make-malicious-fixtures.py` (pure Python,
  reproducible). Two are not generated: `helper-memory.7z` and `helper-spin.xz` were found by
  fuzzing The Unarchiver's `lsar` and are kept as they were found.
* `Fixtures/Interop/` — archives made by the real reference tools (not by this project's writers),
  plus `manifest.json` with their expected contents. They are generated by
  `Scripts/make-interop-fixtures.sh` and committed (about 17 MB). The disk and file-system images in
  `Fixtures/Interop/images/` (ext4, FAT, NTFS, SquashFS, ISO, VMDK, VHD/VHDX, VDI, QCOW2) are
  git-ignored; run the script to recreate them.

## Last results

On 2026-11-10, 245 tests, on the production-readiness branch (see [TestReport.md](TestReport.md)):

| Where | Result |
|---|---|
| Ubuntu 24.04, x86_64, local (Swift 6.1.3, libarchive 3.7.2, 7-Zip, unar) | **0 failures**, 11 skipped (the 8 case-insensitive-disk tests, 2 that need `rar`, the >4 GB test) |
| The same, with every temporary folder on a case-insensitive volume | **0 failures**, 4 skipped |
| macOS | **not run**: GitHub Actions accepted no jobs for the repository at the time |

The inventory above predates the end-to-end, robustness and readiness passes; the suites they added
(`AppFlowTests`, `CLITests`, `RobustnessTests`, `LeftoverTests`, `LinkChainTests`,
`CaseInsensitiveVolumeTests`, `HelperLimitTests`, `ErrorMessageTests` and others) are described in
[TestReport.md](TestReport.md).

On 2026-10-18, 125 tests:

| Where | Libraries and tools | Result |
|---|---|---|
| macOS 15, Apple silicon (CI, Xcode 16.4) | bundled libarchive 3.8.9 and 7-Zip 26.04 | **0 failures**, 3 skipped. Interop: 63 passed, 0 failed, 14 skipped |
| Ubuntu 24.04, x86_64 (CI, Swift 6.1) | libarchive 3.7.2, 7-Zip 23.01 with its RAR codec, unar, lrzip, zpaq | **0 failures**, 3 skipped. Interop: 67 passed, 0 failed, 10 skipped |
| Ubuntu 24.04, local | libarchive 3.7.2 with 7-Zip 26.04 (Linux build) as engine and reference | **0 failures**, 3 skipped |

* The 3 skipped tests are expected: the >4 GB ZIP64 test, which needs `UA_RUN_LARGE_TESTS=1`, and
  two tests that need RARLAB's licensed `rar`.
* Interop skips: the disk-image fixtures (git-ignored, recreated by
  `Scripts/make-interop-fixtures.sh`). On macOS also ARC, ZPAQ, lrzip and lzop, whose optional
  tools the runner doesn't have.
* Earlier full runs with `UA_RUN_LARGE_TESTS=1` (4.4 GB ZIP64 in 66 s; 2 GB streaming with flat
  memory) and `UA_FUZZ_ITERATIONS=150` (1,650 mutated archives, no crash or escape) are recorded in
  the git history of this file.

## Not covered by automated tests

* **Parts of the SwiftUI views, the Quick Look extension, Finder Services and App Intents.** The
  macOS CI job runs `Tests/ZipperUITests` (XCUITest, 10 tests: windows, menus, sidebar, sheets,
  shortcuts, browsing; see [KnownLimitations.md](KnownLimitations.md)); it needs Xcode, so it doesn't
  run here. Drag and drop, VoiceOver and light/dark mode are unverified. The app's model layer is
  covered here too (`ZipperMacTests`, including the `AppFlowTests` end-to-end flows).
* **macOS-only engines and services** — Apple Archive / AEA, `hdiutil` disk images, Keychain,
  extended attributes, resource forks, quarantine propagation, iCloud placeholders, P/E-core
  scheduling and thermal handling.
* **Interop with Archive Utility and Windows Explorer** — proxied by Info-ZIP and Python (see criterion
  19).
* **Performance on Apple Silicon** — [Benchmarks.md](Benchmarks.md) lists x86_64 Linux numbers only.
