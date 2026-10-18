# Zipper

A native archive manager for the Mac. Zipper creates, opens, tests, repairs and converts almost
every archive format behind one simple window, and it's safe by default. It's written in Swift and
SwiftUI on top of a pluggable engine layer:

* libarchive, in-process;
* 7-Zip, The Unarchiver's tools, RAR, Apple Archive and `hdiutil` as helper engines.

> **Status.** The core, engines, services, the `zipper` command-line tool and the app's model layer
> are built and tested on every push (Linux CI). The macOS app's SwiftUI views, the Quick Look
> extension, Finder Quick Actions and Shortcuts are written and reviewed but have not been compiled
> on a Mac yet. The macOS CI job and your first Xcode build are their first compile. Nothing is
> signed or notarized until you do it with your Developer ID. See
> [KnownLimitations.md](Documentation/KnownLimitations.md).

## Using Zipper

* **Compress:** drop files on the window (or **⌘N**). Pick a format (ZIP, 7z, TAR.GZ…), *Faster /
  Normal / Smaller*, and optionally a password or split size, then click **Compress**.
* **Open:** double-click an archive to see inside it like a Finder folder. Press **Space** for
  Quick Look, drag items out to extract them, and drop files in to add them.
* **Extract:** **Extract All** (⌘E) puts everything next to the archive, without a folder inside
  a folder.
* **From Finder:** Quick Actions such as *Compress to ZIP*, *Extract Here* and *Extract To…*, plus a
  Space-bar preview of any archive.
* **Tools:** test integrity, repair, convert, batch extract, checksums, split/join, compare and
  find duplicates.

See the [User guide](Documentation/UserGuide.md).

## What works today (verified by tests)

* **Formats.** 97 formats catalogued. Every committed interop fixture made by independent tools
  passes, including:
  * ZIP/ZIP64/AES and 7z (with encrypted headers and volumes);
  * RAR 2–5 (solid, encrypted, multi-volume);
  * TAR with gzip, bzip2, xz, zstd, lz4, lzip, lzma, Z and brotli;
  * cpio, ar, ISO, XAR, LHA, ARC, ZPAQ, lrzip and others.

  Zipper's own ZIP, 7z, tar, EPUB and stream output is read correctly by Info-ZIP, Python, 7-Zip
  and GNU tar. See [SupportedFormats.md](Documentation/SupportedFormats.md).
* **Safe extraction.** A single write path checks every entry, including entries from helper
  engines. It blocks:
  * path traversal and link escapes;
  * setuid bits and device files;
  * anything over the size, ratio, count, depth and disk-space limits.

  It's tested with 16 hostile fixtures plus mutation fuzzing.
* **Encryption.** AES-256 ZIP that 7-Zip can open, 7z with hidden file names, and RAR decryption.
  Passwords are never passed as command-line arguments.
* **Transactional editing.** Add, rename, delete and move entries. The archive is rebuilt, tested
  and atomically swapped in; the original stays byte-identical if anything fails.
* **And more:**
  * conversion with SHA-256 verification;
  * ZIP central-directory repair and salvage extraction;
  * split/join, checksum manifests, archive comparison and duplicate finding;
  * a compression advisor;
  * files over 4 GB, flat memory while streaming, and cancellation that leaves no partial output.

## Build and ship

```sh
Scripts/build-deps-macos.sh      # once: pinned, checksum-verified libraries + 7-Zip (Vendor/macos)
brew install xcodegen && xcodegen generate
open Zipper.xcodeproj            # scheme "Zipper", ⌘R
```

The complete, step-by-step path to a signed, notarized DMG is in
**[Documentation/Distribution.md](Documentation/Distribution.md)**:

* the Developer ID certificate and notary credentials;
* archiving in Xcode, then the DMG;
* verification, a release checklist and troubleshooting.

Developer quick reference: [BuildInstructions.md](Documentation/BuildInstructions.md).

## Command line

```sh
swift build -c release --product zipper
.build/release/zipper compress Photos -o Photos.zip
.build/release/zipper extract archive.rar -o out --verify
.build/release/zipper formats    # what this machine can read and write
```

## Tests

```sh
swift build --build-tests && swift test --skip-build
UA_RUN_LARGE_TESTS=1 swift test --skip-build      # + >4 GB and 2 GB streaming cases
```

Tests whose reference tool isn't installed are skipped with a reason. See
[Testing.md](Documentation/Testing.md).

## Repository layout

| Path | Contents |
|---|---|
| `Sources/ArchiveCore` | Model, engine protocol, `SafeExtractionSink`, format detection, filters, hashing, presets, advisor |
| `Sources/ArchiveEngines` | libarchive, 7-Zip, unar, RAR, external tools, Apple Archive, disk images, Brotli |
| `Sources/ArchiverKit` | Services: extract, compress, convert, modify, repair, compare, tools, queue, passwords, history |
| `Sources/ZipperCLI` | The `zipper` command-line tool |
| `Sources/ZipperMac` | The app: `Model/` (platform-neutral, unit-tested), `Views/`, `App/` (entry point, menus, Finder services, Shortcuts), `Platform/` (AppKit) |
| `Integrations/QuickLook` | Quick Look preview extension |
| `project.yml`, `Packaging`, `Scripts` | Xcode project spec, entitlements, export options, icon, deps/build/DMG/notarization scripts |
| `Fixtures`, `Tests` | Malicious and interop fixtures; test targets |
| `.github/workflows/ci.yml` | Linux tests on every push; macOS app build on pull requests or `[macos]` commits |
| `Documentation` | Architecture, security, formats, user guide, distribution and more |

## Documentation

[Architecture](Documentation/Architecture.md) ·
[Supported formats](Documentation/SupportedFormats.md) ·
[Security](Documentation/Security.md) ·
[Plugin interface](Documentation/PluginInterface.md) ·
[User guide](Documentation/UserGuide.md) ·
[Installation](Documentation/Installation.md) ·
[Build instructions](Documentation/BuildInstructions.md) ·
[Building and shipping](Documentation/Distribution.md) ·
[Dependencies & licences](Documentation/Dependencies.md) ·
[Testing](Documentation/Testing.md) ·
[Benchmarks](Documentation/Benchmarks.md) ·
[Verified features](Documentation/VerifiedFeatures.md) ·
[Known limitations](Documentation/KnownLimitations.md)

## Privacy

All processing is local. The app has no network code, no analytics and no update checks. History
records names and outcomes, never file contents or passwords. Passwords are stored only in the
keychain, and only when you ask.
