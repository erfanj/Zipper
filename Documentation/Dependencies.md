# Dependencies and licences (software bill of materials)

Universal Archiver's own code is intended to be released under a licence chosen by the owner (none
is applied yet). The table lists every third-party component, how it is used, and the obligations
that follow. Versions are those pinned by `Scripts/build-deps-macos.sh` for the shipped app; the
Linux test environment used the distribution packages noted in the last column.

| Component | Version (shipped / tested) | Licence | How it is used | Source | Architectures |
|---|---|---|---|---|---|
| libarchive | 3.8.9 / 3.7.2 (Ubuntu 24.04) | BSD-2-Clause | Linked statically, in-process | github.com/libarchive/libarchive (SHA-256 pinned) | arm64, x86_64 |
| XZ Utils (liblzma) | 5.8.4 / 5.4.5 | 0BSD | Static, via libarchive | github.com/tukaani-project/xz (pinned) | arm64, x86_64 |
| Zstandard | 1.5.7 / 1.5.5 | BSD-3-Clause (dual GPLv2) | Static, via libarchive | github.com/facebook/zstd (pinned) | arm64, x86_64 |
| LZ4 | 1.10.0 / 1.9.4 | BSD-2-Clause (library) | Static, via libarchive | github.com/lz4/lz4 (pinned) | arm64, x86_64 |
| Brotli | 1.2.0 / 1.1.0 | MIT | Static; own Swift integration (`BrotliCodec`) | PyPI source distribution of the official package (pinned) | arm64, x86_64 |
| zlib, bzip2, libiconv, libxml2 | macOS SDK / Ubuntu | zlib / bzip2 / LGPL (Apple's system copy) / MIT | System libraries | Apple SDK | — |
| CommonCrypto / CryptoKit | macOS | Apple system | ZIP AES via libarchive; hashing | Apple SDK | — |
| swift-crypto | 3.x | Apache-2.0 | Hashing on Linux only (identical API to CryptoKit) | github.com/apple/swift-crypto | Linux |
| 7-Zip (`7zz`) | 26.04 / 23.01 (+ Debian `7zip-rar`) | LGPL-2.1-or-later; parts BSD-3-Clause; **unRAR restriction** | Bundled **separate helper process** | github.com/ip7z/7zip release (pinned) | universal |
| The Unarchiver CLI (`unar`, `lsar`, XADMaster) | 1.10.x (optional) | LGPL-2.1-or-later | Optional bundled/installed **separate process** | theunarchiver.com / Homebrew | universal |
| RAR (`rar`) | user-installed / 7.00 | Proprietary (RARLAB) | **Not bundled.** Invoked only if the user installed and licensed it | rarlab.com | — |
| zpaq, lrzip, lzop, nomarch | user-installed | MIT/PD, GPL-2.0, GPL-2.0, GPL-2.0 | **Not bundled.** Invoked as separate programs if present | Homebrew / distributions | — |
| AppleArchive.framework, hdiutil, QuickLook, AppIntents | macOS | Apple system | System frameworks/tools | — | — |

## Licence compatibility

* **BSD/MIT/0BSD/Apache** components are compatible with any distribution model; their notices are
  shipped in `Contents/Resources/Licenses`.
* **7-Zip (LGPL-2.1)** is shipped unmodified as a separate executable, so the app is not a
  derivative work. Obligations: include the licence and notice, and offer the corresponding source
  (the exact upstream release is referenced and pinned). The unRAR licence inside 7-Zip forbids using
  that code to re-create the RAR compression algorithm; Universal Archiver uses it only to extract.
* **unar/XADMaster (LGPL-2.1)**: same approach — separate, unmodified executables with licence and
  source offer.
* **GPL tools** (lrzip, lzop, nomarch) are never bundled; they are run as independent programs the
  user installed, which keeps the app free of GPL obligations.
* **RAR creation** cannot be implemented or bundled: RARLAB's licence does not permit it. The app
  only drives a copy of `rar` that the user has installed and licensed.
* **Test fixtures**: RAR 2/3 samples come from the `rarfile` project's test corpus (ISC licence,
  included as `Fixtures/Interop/rar4/LICENSE-rarfile`).

## Known advisories

The shipped versions above were the newest upstream releases available when this was prepared
(October 2026) and every tarball is verified by SHA-256 in `Scripts/build-deps-macos.sh`. Re-check
advisories before each release; notable history to be aware of:

* libarchive has had memory-safety fixes in its RAR, 7z and other readers across the 3.7.x and 3.8.x
  series — stay on the newest release.
* XZ Utils 5.6.0 and 5.6.1 contained the CVE-2024-3094 backdoor; later releases (including 5.8.4)
  are clean, and the build script refuses tarballs whose hash differs.
* 7-Zip has had decoder advisories fixed in the 24.x and 25.x series; the bundled helper is 26.04.
* The Linux development environment used older distribution packages (libarchive 3.7.2, 7-Zip
  23.01); those are for testing only and are not shipped.

`archiver engines` prints the versions actually present at run time.
