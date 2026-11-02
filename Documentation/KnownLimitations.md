# Known limitations

Honest list of what is not done, not verified, or not possible.

## Not yet verified

* **Part of the app's UI is still only tested by hand.** The macOS CI job (`.github/workflows/ci.yml`,
  Xcode 16.4 on macOS 15) builds the app, the Quick Look extension and the embedded `zipper` tool,
  verifies the signature and bundle layout, runs the whole test suite on macOS against the bundled
  libarchive 3.8.9 and 7-Zip, and then runs the XCUITest suite (`Tests/ZipperUITests`, 10 tests)
  against the Debug app: launch, the sidebar, the Archive and Tools menus, the Tools and Settings
  windows, closing and reopening windows, quitting, browsing an archive (folders, ⌘↑, ⌘I, Test
  Integrity, Close), ⌘E, and the Compress sheet (cancel and compress). The release workflow
  builds the universal DMG and runs it (`Scripts/smoke-test-app.sh`): the app launches, opens an
  archive and quits cleanly, and the bundled tools round-trip an encrypted 7z on both
  architectures. Not covered by any automated test:
  * drag and drop, Quick Look (Space) in the browser, the column and icon views, VoiceOver, and
    light and dark mode;
  * Finder Quick Actions, Shortcuts, Dock progress and notifications at run time;
  * the Quick Look preview inside Finder;
  * the Apple Archive/AEA and `hdiutil` engines and Keychain storage, which have no tests yet.

  Try these by hand before a release (see the checklist in [Distribution.md](Distribution.md)).
* **No Apple Silicon measurements.** Benchmarks were run on x86_64 Linux. The Apple-Silicon-specific
  logic (P/E core detection via `hw.perflevel*`, QoS mapping, Low Power Mode and thermal handling)
  is implemented but unmeasured.
* **Not signed or notarized yet.** That needs your Developer ID; see [Distribution.md](Distribution.md).
* **UI tests don't cover** drag and drop (XCUITest can't drag from Finder), VoiceOver, or light/dark
  mode, and open files through a Debug-only launch option rather than Finder's open event.

## Format limitations

* RAR creation needs the user's licensed `rar`; RAR 1.5–4.x creation is impossible with current RAR
  versions. RAR recovery-record repair also needs `rar`.
* ACE 2, PAQ/LPAQ, PEA, BH, UCL-based formats, NRG/MDF/CDI/ISZ/DAA images: not supported.
* StuffIt X is partially supported by unar; encrypted StuffIt archives are not supported.
* Legacy Mac and Amiga formats rely on unar, which is not bundled by default and is unverified here.
* ZIPX entries using WinZip's JPEG, WavPack or other proprietary methods cannot be decoded.
* Classic spanned ZIP (`.z01…`) can be read but not created; split ZIPs are created as `.zip.001`
  byte-split sets (readable by 7-Zip-compatible tools and by Zipper).
* WARC writing was withdrawn after it lost entries in testing; WARC reading remains.
* Brotli streams have no magic number: `.br` files are recognised by extension only.
* Encrypted archives handled by unar are not supported (its tools only accept passwords as
  arguments, which would expose them in the process list).

## Behavioural limitations

* **Archive editing rebuilds** the archive (extract → edit → recompress → verify → atomic replace).
  This is safe and works for every writable format, but on very large archives it costs time and
  temporary disk space proportional to the uncompressed size; untouched entries are recompressed.
* **Pause and cancel** take effect at the next output write for in-process engines. For .xz, the
  encoder returns at least every 250 ms, so cancel and pause respond within about that. Other codecs
  with large internal blocks (bzip2, LZMA in 7z created by libarchive) can take a few seconds.
  Multithreaded zstd jobs that are already running finish in the background after a cancel; the
  operation itself returns immediately and its output is already gone. Helper processes are
  suspended with SIGSTOP. Interrupted operations are not resumable after a crash or
  quit. Cancelling (or Ctrl-C in the CLI) removes partial output at once. After a crash or force
  quit, the hidden partial files are removed by the next operation that writes to that folder (each
  carries the ID of the process that made it; those of running processes are left alone).
* **A killed Zipper leaves its helper running.** If the app or CLI is force-quit or crashes during
  an operation that uses 7-Zip (or another helper), the helper process finishes its job in the
  background before exiting; its output is discarded as above.
* **Edits of one archive run one at a time.** Add, Rename, Delete, New Folder and "Update Archive"
  on the same archive wait for each other, so each applies on top of the previous one. If another app
  replaces the archive while Zipper is rebuilding it, Zipper keeps the other version and reports
  that the change wasn't applied.
* **Backslashes in names** are treated as folder separators when extracting, in every format
  (archives made on Windows use them that way): `a\b.txt` extracts as `a/b.txt`. 7z archives
  can't be created from files whose names contain a line break; Zipper says so instead of leaving
  them out. ZIP and TAR keep such names.
* **Metadata**: creation dates (birth times) are read from archives but not restored on extraction;
  ACLs are stored only in Mac Preservation mode and restored only by formats/engines that support
  them; sparse files are materialised (written out in full) on extraction; hard links are preserved
  for TAR/CPIO but stored as copies in ZIP and 7z.
* **Selective extraction from solid archives** decodes the data stored before the selected file.
* **Content search** inside archives covers text and source files only, with per-file and total size
  budgets.
* **Malware scanning** is not performed. Executable-content warnings are heuristics only.
* **Cloud files**: iCloud placeholders are downloaded before compression; other providers are read
  through the file system (File Provider). Direct cloud uploads/links are not implemented.
* **Filename encoding detection** is automatic only for UTF-8 and ZIP's CP437 default; other legacy
  encodings need the manual setting.
* **GPU / Neural Engine**: not used. No compression or checksum workload here was shown to benefit;
  CPU paths (with zlib's and the codecs' own SIMD) are used throughout.
* **Localization**: infrastructure only (String Catalog filled by Xcode at build time); English is the only language.
