import Foundation
import ArchiveCore

/// The engines shipped with Universal Archiver, in default priority order.
///
/// Priority rationale: libarchive is in-process, streaming and fast to start, so it is preferred for
/// everything it supports. 7-Zip covers encryption, multi-volume creation and disk images. unar
/// covers legacy formats. The RAR engine only creates. Apple Archive and hdiutil are macOS-only.
public enum DefaultEngines {
    public static func make() -> [ArchiveEngine] {
        var engines: [ArchiveEngine] = [LibArchiveEngine(), SevenZipEngine()]
        #if canImport(AppleArchive)
        if #available(macOS 13.0, *) { engines.append(AppleArchiveEngine()) }
        #endif
        engines.append(UnarEngine())
        engines.append(RarEngine())
        #if os(macOS)
        engines.append(DiskImageEngine())
        #endif
        return engines
    }

    public static func registry() -> EngineRegistry {
        EngineRegistry(engines: make())
    }
}
