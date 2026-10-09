# Universal Archiver

A native archive manager for Apple Silicon Macs. It opens, creates, tests, repairs and converts
almost every archive format behind one interface, and it is safe by default. It is written in
Swift and SwiftUI on top of a pluggable engine layer: libarchive in-process, plus 7-Zip, The
Unarchiver tools, RAR, Apple Archive and `hdiutil` as helper engines.

> **Status: read this first.** The archive core, engines, services and the `archiver` command-line
> tool are built and tested on Linux. **The macOS app, Finder Quick Actions, Quick Look extension,
> App Intents, Keychain, Apple Archive and disk-image engines have not yet been compiled or run.**
> They were written without access to a Mac, so expect a round of compile fixes on the first Xcode
> build. Nothing is signed or notarized. See [VerifiedFeatures.md](Documentation/VerifiedFeatures.md)
> and [KnownLimitations.md](Documentation/KnownLimitations.md).

## What works today (verified by tests)

* **Formats**: 97 formats catalogued; 77 of 77 fixtures made by independent tools pass forward
  interop. These include ZIP/ZIP64/AES, 7z (including encrypted headers and volumes), RAR 2–5
  (including solid, encrypted and multi-volume), TAR with gzip, bzip2, xz, zstd, lz4, lzip, lzma, Z
  and brotli, cpio, ar, ISO, XAR, LHA, ARC, ZPAQ, lrzip and others. Our ZIP, 7z, tar, EPUB and
  stream outputs are read correctly by Info-ZIP, Python, 7-Zip and GNU tar. See
  [SupportedFormats.md](Documentation/SupportedFormats.md).
* **Safe extraction**: one write path checks every entry, including entries from helper engines.
  It blocks traversal and link escapes, setuid bits and device files, and enforces size, ratio,
  count, depth and disk-space limits. Tested with 16 hostile fixtures plus mutation fuzzing.
* **Smart extraction** (no double folders), conflict policies, batch and nested extraction, and
  multi-part detection with missing-volume reports.
* **Encryption**: AES-256 ZIP that 7-Zip can open, 7z with hidden file names, and RAR decryption.
  Passwords are never passed as command-line arguments.
* **Transactional editing**: add, rename, delete and move entries. The archive is rebuilt, tested
  and atomically swapped; the original stays byte-identical if anything fails.
* **Conversion with SHA-256 verification**, ZIP central-directory repair, salvage extraction,
  split/join, checksum manifests, archive comparison, duplicate finding and a compression
  advisor.
* **Robustness**: files over 4 GB (ZIP64), memory that stays flat while streaming, cancellation
  that leaves no partial output, and pause/resume.

## Quick start (command line)

```sh
export PATH=/opt/swift/usr/bin:$PATH     # any Swift 5.10+ toolchain
swift build -c release --product archiver
.build/release/archiver help
.build/release/archiver compress Photos -o Photos.zip
.build/release/archiver extract archive.rar -o out --verify
.build/release/archiver formats          # what this machine can read and write
```

On Linux you need the libarchive, zlib and brotli development packages. 7-Zip (`7zz`/`7z`) enables
RAR, encrypted 7z and split archives. See [BuildInstructions.md](Documentation/BuildInstructions.md).

## Building the Mac app

```sh
Scripts/build-deps-macos.sh            # pinned, checksum-verified libarchive/xz/zstd/lz4/brotli + 7-Zip
Scripts/build-app.sh                   # SwiftPM app bundle, or: xcodegen && open UniversalArchiver.xcodeproj
Scripts/make-dmg.sh && Scripts/notarize.sh dist/UniversalArchiver-<version>.dmg   # needs a Developer ID
```

## Tests

```sh
Scripts/make-interop-fixtures.sh       # recreates the (git-ignored) disk-image fixtures
swift build --build-tests && swift test --skip-build
UA_RUN_LARGE_TESTS=1 swift test --skip-build   # + >4 GB and 2 GB streaming cases
```

The suite has 108 tests in five targets; see [Testing.md](Documentation/Testing.md) for the
inventory and the last results. Benchmarks against Info-ZIP, GNU tar and 7-Zip (x86_64, not Apple
Silicon) are in [Benchmarks.md](Documentation/Benchmarks.md).

## Repository layout

| Path | Contents |
|---|---|
| `Sources/ArchiveCore` | Model, engine protocol, `SafeExtractionSink`, format detection, filters, hashing, presets, advisor |
| `Sources/ArchiveEngines` | libarchive, 7-Zip, unar, RAR, external tools, Apple Archive, disk images, Brotli |
| `Sources/ArchiverKit` | Services: extract, compress, convert, modify, repair, compare, tools, queue, passwords, history |
| `Sources/archiver` | Command-line tool |
| `Sources/UniversalArchiver` | SwiftUI app, Finder services, App Intents (macOS) |
| `Integrations/QuickLook` | Quick Look preview extension |
| `Packaging`, `project.yml`, `Scripts` | Entitlements, Xcode project spec, build, DMG, notarization and benchmark scripts |
| `Fixtures`, `Tests` | Malicious and interop fixtures; test targets |
| `Documentation` | Architecture, security, formats, plugins, user guide, distribution and more |

## Documentation

[Architecture](Documentation/Architecture.md) ·
[Supported formats](Documentation/SupportedFormats.md) ·
[Security](Documentation/Security.md) ·
[Plugin interface](Documentation/PluginInterface.md) ·
[User guide](Documentation/UserGuide.md) ·
[Installation](Documentation/Installation.md) ·
[Build instructions](Documentation/BuildInstructions.md) ·
[Distribution](Documentation/Distribution.md) ·
[Dependencies & licences](Documentation/Dependencies.md) ·
[Testing](Documentation/Testing.md) ·
[Benchmarks](Documentation/Benchmarks.md) ·
[Verified features](Documentation/VerifiedFeatures.md) ·
[Known limitations](Documentation/KnownLimitations.md)

## Privacy

All processing is local. The app has no network code, no analytics and no update checks. History
records names and outcomes, never file contents or passwords. Passwords are stored only in the
Keychain, and only when you ask.

The name "Universal Archiver" is a working title: the bundle identifier, product name and CLI name
are set in `ProductInfo` (`Sources/ArchiverKit/Services.swift`), `project.yml` and `Info.plist`.
