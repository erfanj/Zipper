// swift-tools-version:5.10
//
// Zipper — Swift package manifest.
//
// Targets:
//   CArchive / CBrotli / CLzma / CZlib — the C libraries. On macOS, once Scripts/build-deps-macos.sh
//                               has built Vendor/macos/xcframeworks, the pinned static XCFrameworks
//                               are linked (self-contained; Xcode needs no environment setup).
//                               Otherwise the system libraries are found with pkg-config (Linux,
//                               or Homebrew during development).
//   ArchiveCore               — engine-agnostic model, format registry, detection, safety.
//   ArchiveEngines            — engines (libarchive, 7-Zip, Brotli, unar, RAR, Apple Archive, hdiutil).
//   ArchiverKit               — services (compress, extract, convert, test, repair, split, compare…).
//   ZipperCLI                 — the `zipper` command-line tool.
//   ZipperMac                 — the macOS SwiftUI app (a stub on other platforms). Release builds
//                               go through project.yml, which adds the Quick Look extension.
//
import Foundation
import PackageDescription

let vendoredFrameworks = "Vendor/macos/xcframeworks"
let useVendoredLibraries = FileManager.default.fileExists(
    atPath: "\(Context.packageDirectory)/\(vendoredFrameworks)/CArchive.xcframework")

/// A C library: the vendored static XCFramework when it has been built, else a pkg-config system library.
func cLibrary(_ name: String, pkgConfig: String?, brew: [String], apt: [String]) -> Target {
    if useVendoredLibraries {
        return .binaryTarget(name: name, path: "\(vendoredFrameworks)/\(name).xcframework")
    }
    return .systemLibrary(name: name, path: "Sources/\(name)", pkgConfig: pkgConfig,
                          providers: [.brew(brew), .apt(apt)])
}

let linuxObservationWorkaround: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "--allow-shlib-undefined"], .when(platforms: [.linux])),
]

let package = Package(
    name: "Zipper",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
        .library(name: "ArchiveEngines", targets: ["ArchiveEngines"]),
        .library(name: "ArchiverKit", targets: ["ArchiverKit"]),
        .executable(name: "zipper", targets: ["ZipperCLI"]),
        .executable(name: "ZipperMac", targets: ["ZipperMac"]),
    ],
    dependencies: [
        // Only used on non-Apple platforms; on macOS the identical CryptoKit API is used.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        cLibrary("CArchive", pkgConfig: "libarchive", brew: ["libarchive"], apt: ["libarchive-dev"]),
        cLibrary("CBrotli", pkgConfig: "libbrotlienc", brew: ["brotli"], apt: ["libbrotli-dev"]),
        cLibrary("CLzma", pkgConfig: "liblzma", brew: ["xz"], apt: ["liblzma-dev"]),
        // zlib ships with macOS and every Linux distribution, so it is never vendored.
        .systemLibrary(name: "CZlib", path: "Sources/CZlib", providers: [.apt(["zlib1g-dev"])]),
        .target(
            name: "ArchiveCore",
            dependencies: [
                "CZlib",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "ArchiveEngines",
            dependencies: ["ArchiveCore", "CArchive", "CBrotli", "CLzma", "CZlib"]
        ),
        .target(
            name: "ArchiverKit",
            dependencies: ["ArchiveCore", "ArchiveEngines", "CZlib"]
        ),
        .executableTarget(
            name: "ZipperCLI",
            dependencies: ["ArchiverKit", "ArchiveEngines", "ArchiveCore"]
        ),
        .executableTarget(
            name: "ZipperMac",
            dependencies: ["ArchiverKit", "ArchiveEngines", "ArchiveCore"],
            exclude: ["Info.plist", "Zipper.entitlements", "Resources"],
            // Linux only: the app's model code is compiled (and type-checked) there too, and the Linux
            // toolchain's libswiftObservation.so references a runtime symbol it doesn't export.
            linkerSettings: linuxObservationWorkaround
        ),
        .target(
            name: "UATestSupport",
            dependencies: ["ArchiveCore"],
            path: "Tests/UATestSupport"
        ),
        .testTarget(
            name: "ArchiveCoreTests",
            dependencies: ["ArchiveCore", "UATestSupport"]
        ),
        .testTarget(
            name: "ArchiveEnginesTests",
            dependencies: ["UATestSupport", "ArchiveEngines", "ArchiveCore", "ArchiverKit"]
        ),
        .testTarget(
            name: "ArchiverKitTests",
            dependencies: ["UATestSupport", "ArchiverKit", "ArchiveEngines", "ArchiveCore"]
        ),
        .testTarget(
            name: "SecurityTests",
            dependencies: ["UATestSupport", "ArchiverKit", "ArchiveEngines", "ArchiveCore"]
        ),
        .testTarget(
            name: "InteropTests",
            dependencies: ["UATestSupport", "ArchiverKit", "ArchiveEngines", "ArchiveCore"]
        ),
        .testTarget(
            name: "ZipperMacTests",
            dependencies: ["ZipperMac", "ArchiverKit", "ArchiveCore"],
            linkerSettings: linuxObservationWorkaround
        ),
    ]
)
