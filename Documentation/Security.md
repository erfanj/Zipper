# Security architecture

Archives are untrusted input. Zipper is designed so that a malicious archive cannot
write outside the folder the user chose, exhaust the disk or memory, create dangerous filesystem
objects, or run code — and so that passwords and file names never leave the Mac.

## Threat model

| Threat | Defence | Evidence |
|---|---|---|
| Path traversal / ZIP Slip (`../`, `..\`, absolute and drive-letter paths) | `SafePath` rejects `..` components and NUL bytes; strips leading `/` and `C:`; treats `\` as a separator | `MaliciousArchiveTests.testZipSlip`, `testTarSlip` |
| Symlink escape (archive creates `link → /tmp`, then writes `link/file`) | Escaping links are refused by default; **every** directory component is opened with `openat(…, O_NOFOLLOW \| O_DIRECTORY)`, so writes can never pass through any link — even with links allowed, or with a link planted in the destination beforehand | `testSymlinkEscape`, `testSymlinkEscapeEvenWhenLinksTrusted`, `testZipSymlinkThroughLink`, `testDestinationSymlinkPlantedBeforeExtraction` |
| Link chains (`up → ..`, then `escape → up/../secret`: each target reads as contained, the pair isn't) | After extraction every link the archive created is followed, hop by hop, with the links that are really on disk (the user's own included). One that leads outside the destination is removed and reported. Absolute targets and loops count as outside | `LinkChainTests` (6) |
| Names that differ only by case on a Mac disk (`Up` is a link, `up/file` is written "through" it) | Components are opened with `O_NOFOLLOW` whatever their spelling; files whose names collide are all kept, one under a numbered name, and reported | `CaseInsensitiveVolumeTests` (8; they run on a Mac, and on Linux against a case-insensitive mount) |
| Hard-link abuse (link to `/etc/passwd`) | Hard links may only point at files already extracted from the same archive; created with `linkat` between descriptors inside the destination | `testHardlinkEscape` |
| Device nodes, FIFOs, sockets | Never created; reported as skipped | `testSpecialFilesAndSetuid` |
| Set-UID/GID and sticky bits | Stripped (`mode & 0o777`) | `testSpecialFilesAndSetuid` |
| Decompression bombs | Limits on total output, single-entry size, entry count, expansion ratio (after a grace amount), nesting depth, wall time, and free-disk reserve — all enforced on bytes actually produced, not declared sizes | `testDecompressionBombStopsAtLimitWithoutPartialOutput`, `testExpansionRatioLimit`, `testLyingSizeIsBounded`, `testEntryCountLimit`, `testLowDiskSpaceStopsBeforeFillingTheDisk` |
| Excessive nesting | Recursive extraction is opt-in and bounded by `maxNestingDepth` with a shared byte budget | `testDeepNestingIsBounded` |
| A helper program made to take all the memory, or to never finish | Helpers that read archives are watched: one that holds more than half the machine's memory (2 GB for The Unarchiver's tools) is stopped; The Unarchiver's tools, whose decoders can loop on damaged data, also get a time allowance (two minutes plus 30 s per MB of archive, pauses not counted). The error says what was stopped | `HelperLimitTests` (11), `testADamagedArchiveCannotMakeAHelperTakeAllTheMemory`; fixtures `helper-memory.7z`, `helper-spin.xz` (found by fuzzing) |
| Malformed headers, integer overflows, crashes | Mature parsers (libarchive, 7-Zip) plus mutation fuzzing of every writable format; a double free found by fuzzing malformed input was fixed | `testMalformedInputsFailCleanly`, `FuzzTests` (1,650+ mutated archives per run, no crash, nothing written outside the destination) |
| Duplicate/colliding names | Never overwrite silently: keep-both by default, or the user's explicit policy | `testDuplicateNamesNeverOverwriteSilently` |
| Partial output after failure | Extraction happens in a private staging folder (0700) on the destination volume and is moved into place only on success; files are written to temporary names and linked into place atomically; compression writes to a temporary file | `testCancelledExtractionLeavesNoPartialOutput`, `testCancelledCompressionLeavesNoOutput` |
| Helper tools writing outside the destination | Helper engines (7-Zip, unar, zpaq…) write only into the private staging folder; their output is re-validated by the same sink; a free-space watchdog stops them before the disk fills | `testHelperEngineOutputIsAlsoValidated` |
| Running untrusted code | Nothing extracted is ever opened automatically. Opening an app/script from the browser reveals it in Finder instead. Previews are written read-only (`0400`) into a private folder and opened only with Quick Look. "Edit in Default App" hands the system a copy without executable permission (a script with it set would be run in Terminal), and refuses the file types macOS runs or installs when opened (`.command`, `.terminal`, `.webloc`, `.app`, `.pkg`, `.workflow`…); the entry keeps its own permissions in the archive. Installers (PKG, MSI, NSIS, RPM/DEB scripts) and shell archives are never executed | `ExecutableContent`, `testContentSearchAndPreview`, `ExternalEditSafetyTests` |
| Gatekeeper bypass | On macOS the archive's `com.apple.quarantine` attribute is copied to every extracted file, as Archive Utility does | `SafeExtractionSink.applyFileMetadata` |
| Mounting malicious disk images | Never automatic. Only with consent, read-only, `-nobrowse -noautoopen`, at a random private mount point, detached afterwards | `DiskImageEngine` |

Default limits (`SafetyLimits.default`, adjustable in Settings › Extraction; "trusted" mode raises
them but keeps the disk reserve): 500 GB total, 256 GB per file, 2,000,000 entries, 10,000:1 ratio
after the first 1 GB, nesting depth 3, keep 512 MB free.

Executable-content detection (apps, Mach-O/ELF/PE binaries, `#!` scripts, installer packages,
executable bits) is a **warning aid only**. Zipper does not scan for malware and never
claims an archive is safe; a passing integrity test means the data decoded and checksums matched,
nothing more.

## Passwords and encryption

* Only standard schemes are used: WinZip AES-256/128 (PBKDF2-HMAC-SHA1, AES-CTR, HMAC-SHA1
  authentication), 7z AES-256 (with optional header encryption), RAR 5 AES-256 (through the
  licensed tool), Apple Encrypted Archive (HKDF-SHA256, AES-CTR, HMAC, scrypt), AES-256 encrypted
  DMG. No custom cryptography. ZipCrypto is available for decryption and as an explicitly labelled
  legacy option with a warning.
* The UI states what each method protects: e.g. ZIP AES leaves names, sizes and dates visible; 7z
  with encrypted headers hides them.
* Interoperability is verified: ZIP AES-256 written by libarchive is decrypted by 7-Zip; 7z with
  encrypted names is unreadable without the password (names absent from the bytes on disk).
* Passwords are held as byte buffers (`Secret`) that are zeroed when released; they are never
  logged, never put in error messages, never passed as command-line arguments (helpers receive them
  on stdin in answer to their prompt, `hdiutil` via `-stdinpass`), and never written to settings or
  presets (preset JSON is tested to contain no secret fields).
* The `zipper` CLI refuses `--password`; it reads from the terminal with echo off or from stdin.
* Passwords can be saved in the macOS Keychain, removed individually, or not stored at all. They
  are generic passwords in the login keychain, readable without a prompt only by Zipper.
  "Require Touch ID or your login password" is checked with LocalAuthentication before the item is
  read. The flag is stored with each item, so turning the setting off doesn't unlock existing
  passwords. A password is associated with the whole multipart set.
* Random passwords use the system CSPRNG (`SystemRandomNumberGenerator`); strength feedback is a
  local estimate.
* Errors distinguish incorrect password, missing password, unsupported encryption, authentication
  failure, damage and missing volumes; a failure is never reported as "wrong password" by default.

## Process isolation and sandboxing

* **Direct distribution (default)**: hardened runtime, Developer ID signed, not sandboxed. This lets
  "Extract Here", multipart sets and batch operations work in any folder without repeated prompts.
  Parsers run in-process (libarchive) or in separate helper processes (7-Zip, unar, zpaq, lrzip,
  lzop, nomarch, rar, hdiutil) with a minimal environment (`PATH=/usr/bin:/bin`, temporary `HOME`).
* **Sandboxed configuration** (`Packaging/Zipper-AppStore.entitlements`): App Sandbox with
  user-selected read-write access and app-scoped bookmarks; helpers signed with
  `com.apple.security.inherit`. Sibling volumes of multipart sets rely on `NSIsRelatedItemType`;
  where that is insufficient the user is asked to choose the folder. This configuration has not
  been built or tested in this delivery (no macOS environment).
* The Quick Look extension is sandboxed, read-only, uses only the in-process engine and never starts
  helper processes; for archives with encrypted file names it shows that they are protected rather
  than revealing anything.
* Helper executables are found only in the app bundle's `Contents/Helpers` and fixed system
  directories, and are rejected if writable by other users. There is no run-time plug-in loading.

**Future hardening (not implemented):** moving libarchive parsing into an XPC service with a tighter
sandbox than the app would further reduce the impact of a parser vulnerability.

## Privacy

No account, no analytics, no advertising, no network access for any archive operation. File names,
contents and passwords never leave the Mac. Activity history stores operation type, paths (or only
names, if the user prefers), timing and outcome — never listings, contents or passwords — and can
be disabled or cleared. Diagnostic logs are off by default and replace paths with anonymous
placeholders.
