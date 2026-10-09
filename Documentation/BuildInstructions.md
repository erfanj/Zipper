# Build instructions

## Requirements

* macOS 14 Sonoma or later on Apple Silicon (Intel builds are possible with `--universal`).
* Xcode 15.3 or later (Swift 5.10+); Xcode 16 recommended.
* Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the Xcode project (Quick Look
  extension and Shortcuts metadata).

## 1. Dependencies (self-contained build)

```sh
Scripts/build-deps-macos.sh            # arm64; add --universal for arm64 + x86_64
```

This downloads pinned, SHA-256-verified sources of libarchive, XZ, Zstandard, LZ4 and Brotli,
builds static libraries into `Vendor/macos`, and unpacks the official 7-Zip console build
(`7zz`) as a helper. libarchive uses Apple's CommonCrypto for ZIP AES. Nothing from Homebrew ends up
in the app.

For quick development you can instead use Homebrew (`brew install libarchive brotli sevenzip`); the
scripts pick it up automatically, but the resulting app then depends on Homebrew's libraries.

Optional legacy-format helpers (not bundled by default): `brew install unar` (StuffIt, Compact Pro,
ARC, Zoo, Amiga…), `brew install zpaq lrzip lzop`. To bundle unar/lsar, copy them into
`Vendor/macos/helpers/` (LGPL — see Dependencies.md).

## 2a. App with SwiftPM (no Xcode project)

```sh
Scripts/build-app.sh                   # dist/Universal Archiver.app, ad-hoc signed
Scripts/build-app.sh --universal       # arm64 + x86_64
Scripts/build-app.sh --sign "Developer ID Application: Your Name (TEAMID)"
```

The bundle contains the app, the `archiver` CLI and `7zz` in `Contents/Helpers`, licence files, and
is signed inside-out with the hardened runtime.

## 2b. App with Xcode (includes Quick Look + Shortcuts)

```sh
brew install xcodegen
xcodegen generate
open UniversalArchiver.xcodeproj
```

Set your team in the project, then build the `UniversalArchiver` scheme. If you did not run
`build-deps-macos.sh`, set `PKG_CONFIG_PATH` (e.g. in the scheme's environment or in Xcode's build
settings) to Homebrew's `libarchive` and `brotli` `lib/pkgconfig` folders.

## 3. Tests

```sh
swift test                                   # all suites
UA_RUN_LARGE_TESTS=1 swift test              # adds the >4 GB ZIP64 test and larger stress cases
UA_FUZZ_ITERATIONS=500 swift test --filter FuzzTests
Scripts/make-interop-fixtures.sh             # (re)generate reference fixtures; needs the reference tools
```

Interop and helper-engine tests are skipped (not failed) when a reference tool is missing. On macOS
install them with Homebrew: `brew install sevenzip unar zstd lz4 brotli lzip xz rar` (RAR is
proprietary; it is only used to create test fixtures and RAR archives).

## 4. Linux (core, engines, CLI and tests)

Everything except the app builds on Linux, which is how this repository was developed and tested:

```sh
sudo apt install libarchive-dev libbrotli-dev zlib1g-dev 7zip 7zip-rar unar
swift build && swift test
```

## 5. Benchmarks

```sh
swift build -c release --product archiver
Scripts/benchmark.py --archiver .build/release/archiver --out Documentation/Benchmarks.md
```

## 6. Distribution

See [Distribution.md](Distribution.md) for signing, notarization, DMG packaging and updates.
