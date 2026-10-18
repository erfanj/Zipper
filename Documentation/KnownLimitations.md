# Known limitations

Honest list of what is not done, not verified, or not possible.

## Not yet verified

* **The app builds and runs on macOS, but most of its UI isn't covered by automated tests.** The
  macOS CI job (`.github/workflows/ci.yml`, Xcode 16.4 on macOS 15) builds the app, the Quick Look
  extension and the embedded `zipper` tool, verifies the signature and bundle layout, and runs the
  whole test suite on macOS against the bundled libarchive 3.8.9 and 7-Zip. The release workflow
  builds the universal DMG and runs it (`Scripts/smoke-test-app.sh`): the app launches, opens an
  archive and quits cleanly, and the bundled tools round-trip an encrypted 7z on both
  architectures. Not covered by any automated test:
  * the views' behaviour (keyboard navigation, VoiceOver, drag and drop, light and dark mode);
  * Finder Quick Actions, Shortcuts, Dock progress and notifications at run time;
  * the Quick Look preview inside Finder;
  * the Apple Archive/AEA and `hdiutil` engines and Keychain storage, which have no tests yet.

  Try these by hand before a release (see the checklist in [Distribution.md](Distribution.md)).
* **No Apple Silicon measurements.** Benchmarks were run on x86_64 Linux. The Apple-Silicon-specific
  logic (P/E core detection via `hw.perflevel*`, QoS mapping, Low Power Mode and thermal handling)
  is implemented but unmeasured.
* **Not signed or notarized yet.** That needs your Developer ID; see [Distribution.md](Distribution.md).
* **UI tests** (keyboard navigation, VoiceOver, drag and drop, light/dark mode) aren't written yet.
  They need XCUITest on macOS.

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
  quit; they restart cleanly (temporary output is removed).
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
