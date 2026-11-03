# Verified features and acceptance criteria

Status of the 20 acceptance tests from the specification. **Verified** means an automated test in
this repository exercises it and passed in the last full run (Linux x86_64; see
[Testing.md](Testing.md)). **Implemented, unverified** means the code exists but could not be run in
the build environment (macOS-only). Nothing here is claimed on the basis of code review alone.

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | Ordinary ZIP: create and extract | **Verified** | `LibArchiveEngineTests.testZipDeflate`, `ExtractionServiceTests`, `ReverseInteropTests.testZipReadByInfoZipAndPython` |
| 2 | 7z with selected settings | **Verified** (LZMA2/PPMd/BZip2, levels, solid on/off, dictionary via 7-Zip) | `testSevenZipLZMA2`, `test7zReadBy7Zip`, 7z interop fixtures |
| 3 | RAR4 and RAR5 extraction | **Verified** (RAR5 from RAR 7.00; RAR 2/3 from WinRAR-made corpus; plain, solid, encrypted, multi-volume) | `ForwardInteropTests` `rar/*`, `rar4/*` |
| 4 | AES-256 ZIP readable by an independent app | **Verified** — libarchive-written AES-256 ZIP decrypted by 7-Zip; wrong password rejected | `ReverseInteropTests.testAESZipDecryptedBy7Zip` |
| 5 | Encrypted 7z hides file names | **Verified** — names absent from the file bytes (UTF-8 and UTF-16), listing fails without the password, reference 7-Zip reveals nothing | `SevenZipEngineTests.testEncrypted7zHidesFilenames` |
| 6 | Multipart: create, extract, detect missing volumes | **Verified** | `testMultipartCreateExtractAndMissingVolume`, `testSplit7zReadBy7Zip`, `testMissingVolumeIsReportedBeforeExtraction`, multipart fixtures |
| 7 | Preview images/documents without extracting everything | **Engine part verified** (single-entry extraction into a private read-only preview folder); Quick Look (Space) UI unverified | `testContentSearchAndPreview`; `ArchiveBrowserView.quickLook()` (macOS) |
| 8 | Extract one file from thousands | **Verified** (1 of 2,000) | `testSelectiveExtraction` (libarchive and 7-Zip) |
| 9 | Add, rename, remove entries; archive stays valid | **Verified** (add, delete, rename, move, new folder; encrypted ZIP keeps encryption; failed edits leave the original byte-identical) | `testTransactionalModification`, `testModifyEncryptedZipKeepsEncryption` |
| 10 | ZIP → 7z conversion with content comparison | **Verified** (SHA-256 of every entry compared) | `testConversionZipTo7zVerifiesContent` |
| 11 | Damaged archive gives an understandable error, no crash | **Verified** (malformed/truncated inputs; 1,650 fuzzed archives; double free found and fixed) | `testMalformedInputsFailCleanly`, `FuzzTests`, `testZipRepairRebuildsCentralDirectory` |
| 12 | Finder integration | **Implemented, unverified** (NSServices Quick Actions, enabled by default; Quick Look extension) | `App/ServicesProvider.swift`, `Info.plist`, `Integrations/QuickLook` |
| 13 | Files larger than 4 GB | **Verified** (4.4 GB file, ZIP64, test + extraction + Info-ZIP `unzip -t`) | `testLargeFileOver4GBZip64` (`UA_RUN_LARGE_TESTS=1`) |
| 14 | Unicode names (Persian, Arabic, Chinese, Japanese, Korean, Hindi, Cyrillic, accents, emoji) | **Verified** in every round-trip and interop test; legacy Shift-JIS/CP437 names decoded | sample tree in all engine tests; `testLegacyFilenameEncodingOverride` |
| 15 | Malicious entries cannot escape the destination | **Verified** (traversal, absolute, backslash, symlink and hard-link escapes, planted symlinks, helper-engine output) | `MaliciousArchiveTests` (16 tests) |
| 16 | Large archives without loading them into memory | **Verified** (resident memory growth ≈ 0 MB while extracting 300 MB; 2 GB with large tests) | `testStreamingKeepsMemoryBounded` |
| 17 | Safe cancellation | **Verified** (no partial or temporary output after cancelling compression or extraction; pause/resume completes correctly) | `testCancelledCompressionLeavesNoOutput`, `testCancelledExtractionLeavesNoPartialOutput`, `testPauseAndResumeCompletesCorrectly` |
| 18 | Metadata preservation | **Verified** on Linux for permissions, modification times and symbolic links (TAR, read by GNU tar). macOS extended attributes, resource forks and quarantine propagation: implemented, unverified | `testMetadataPreservationInTar` |
| 19 | ZIPs readable by built-in Windows and macOS tools | **Proxy verified**: Info-ZIP and Python read our ZIPs; only Store/Deflate are used by default; every non-ASCII name has the UTF-8 flag. Not run on Windows Explorer or Archive Utility | `testZipReadByInfoZipAndPython` |
| 20 | Standalone app bundle | **Verified by CI**: the macOS job (Xcode 16.4, macOS 15) builds `Zipper.app` with the Quick Look extension and embedded `zipper` and `7zz`, runs `codesign --verify --deep --strict`, runs the embedded `zipper --version` and lints Info.plist. Developer ID signing and notarization need your certificate | `.github/workflows/ci.yml` |

## Other verified capabilities

* 77 reference-tool fixtures across 40+ format variants (see [SupportedFormats.md](SupportedFormats.md)): all 67 committed fixtures pass; the 10 disk-image fixtures are regenerated locally by `Scripts/make-interop-fixtures.sh`.
* Engine fallback with logged reasons (encrypted RAR5/7z, Deflate64, solid RAR3, ARC).
* Smart extraction rules, five conflict policies, folder merging, batch extraction with skip/continue.
* Bounded nested extraction; safety limits on size, count, ratio, depth and disk reserve.
* ZIP central-directory reconstruction; salvage extraction past corrupt entries.
* Split/join with SHA-256 manifests; checksum manifests (GNU/BSD/SFV) with traversal-safe verification.
* Archive comparison (metadata and content), duplicate detection, content search, analysis.
* Compression advisor with measured sample ratios; presets with secret-free JSON export.
* EPUB packaging that satisfies the OCF `mimetype` rules.
* RAR creation through a licensed `rar`, including encrypted headers (read back by 7-Zip).
* CLI with JSON output, documented exit codes, and no password arguments.
