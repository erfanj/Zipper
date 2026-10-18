# Build instructions

For the complete path to a signed, notarized release, see [Distribution.md](Distribution.md). This
page is the developer quick reference.

## Requirements

* macOS 14 Sonoma or later, Apple silicon or Intel.
* Xcode 16 or later (Swift 6 compiler; the code uses the Swift 5 language mode).
* [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

## The app (Xcode)

```sh
Scripts/build-deps-macos.sh            # once: pinned static libraries + 7-Zip helper → Vendor/macos
xcodegen generate                      # creates Zipper.xcodeproj from project.yml
open Zipper.xcodeproj                  # scheme "Zipper", My Mac, ⌘R
```

Debug builds are signed to run locally and need no certificate. Release builds (Product › Archive)
use your Developer ID: set `DEVELOPMENT_TEAM` and `ZIPPER_BUNDLE_ID` in `project.yml` first.

**How the C libraries are found.** `Package.swift` uses the static XCFrameworks in
`Vendor/macos/xcframeworks` when they exist, so Xcode needs no environment variables. Without them,
it falls back to pkg-config system libraries: fine on Linux, but in Xcode on macOS that needs
`PKG_CONFIG_PATH` set for Xcode itself. Run the deps script instead.

## The package and the command-line tool (SwiftPM)

```sh
swift build -c release --product zipper    # .build/release/zipper
swift test                                 # all suites (helper-based tests skip when a tool is missing)
UA_RUN_LARGE_TESTS=1 swift test            # adds the >4 GB ZIP64 test and larger stress cases
UA_FUZZ_ITERATIONS=500 swift test --filter FuzzTests
```

Reference tools for the interop and helper tests on macOS:
`brew install sevenzip unar zstd lz4 brotli lzip xz rar`. RAR is proprietary; it's used only for
fixtures and for creating RAR archives.

`Scripts/build-app.sh` builds `dist/Zipper.app` with SwiftPM alone. It's quick for local testing,
but it has no Quick Look extension or Shortcuts metadata.

## Linux (core, engines, CLI, tests, and type-checking the app's model code)

```sh
sudo apt install libarchive-dev libbrotli-dev liblzma-dev zlib1g-dev \
  7zip 7zip-rar unar zip unzip lzip lzop zstd lz4 brotli lrzip zpaq nomarch
swift build --build-tests && swift test --skip-build
```

On Linux the `ZipperMac` target compiles the app's platform-neutral model layer (`Sources/ZipperMac/Model`)
around a small stub. That type-checks every call the UI makes into the core, even without macOS.

## Continuous integration

`.github/workflows/ci.yml` has two jobs:

* **Linux**: builds and runs the full test suite on every push.
* **macOS**: builds the dependencies, generates the Xcode project, builds the app, checks the
  bundle's signature and layout, runs the package tests, and uploads a downloadable
  `Zipper-debug-app`. Because macOS minutes cost 10× on private repositories, it runs on pull
  requests, from the Actions tab, or for pushes whose commit message contains `[macos]`.

## Regenerating assets

* App icon: `python3 Scripts/make-icon.py` writes the asset catalog icon set and
  `Packaging/AppIcon.icns`. It needs Pillow.
* Interop fixtures: `Scripts/make-interop-fixtures.sh` (needs the reference tools).
* Benchmarks: `Scripts/benchmark.py --archiver .build/release/zipper --out Documentation/Benchmarks.md`.
