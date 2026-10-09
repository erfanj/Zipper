// swift-tools-version:5.10
//
// Universal Archiver — Swift package manifest.
//
// Targets:
//   CArchive / CZlib / CBrotli  — system-library shims for the C engines.
//   ArchiveCore                 — engine-agnostic model, format registry, detection, safety.
//   ArchiveEngines              — concrete engine providers (libarchive, 7-Zip, Brotli, unar, RAR, Apple Archive).
//   ArchiverKit                 — high-level services (compress, extract, convert, test, repair, split, compare…).
//   archiver                    — command-line companion.
//   UniversalArchiver           — the macOS SwiftUI application (compiles to a stub on non-Apple platforms).
//
import PackageDescription

let package = Package(
    name: "UniversalArchiver",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
        .library(name: "ArchiveEngines", targets: ["ArchiveEngines"]),
        .library(name: "ArchiverKit", targets: ["ArchiverKit"]),
        .executable(name: "archiver", targets: ["archiver"]),
        .executable(name: "UniversalArchiver", targets: ["UniversalArchiver"]),
    ],
    dependencies: [
        // Only used on non-Apple platforms; on macOS the identical CryptoKit API is used.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CArchive",
            path: "Sources/CArchive",
            pkgConfig: "libarchive",
            providers: [.brew(["libarchive"]), .apt(["libarchive-dev"])]
        ),
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            providers: [.apt(["zlib1g-dev"])]
        ),
        .systemLibrary(
            name: "CBrotli",
            path: "Sources/CBrotli",
            pkgConfig: "libbrotlienc",
            providers: [.brew(["brotli"]), .apt(["libbrotli-dev"])]
        ),
        .target(
            name: "ArchiveCore",
            dependencies: [
                "CZlib",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "ArchiveEngines",
            dependencies: ["ArchiveCore", "CArchive", "CBrotli", "CZlib"]
        ),
        .target(
            name: "ArchiverKit",
            dependencies: ["ArchiveCore", "ArchiveEngines", "CZlib"]
        ),
        .executableTarget(
            name: "archiver",
            dependencies: ["ArchiverKit", "ArchiveEngines", "ArchiveCore"]
        ),
        .executableTarget(
            name: "UniversalArchiver",
            dependencies: ["ArchiverKit", "ArchiveEngines", "ArchiveCore"],
            exclude: ["Info.plist", "UniversalArchiver.entitlements"]
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
    ]
)
