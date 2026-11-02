import Foundation
import ArchiveCore
import ArchiveEngines

public struct ConvertRequest: Sendable {
    public var archive: URL
    public var settings: CompressionSettings
    public var destinationDirectory: URL?
    /// Password to open the source (if encrypted).
    public var readOptions: ReadOptions
    /// Password for the new archive when `settings.encryption` is set.
    public var newPassword: Secret?
    /// Move the original to the Trash after the converted archive verified. Off by default.
    public var trashOriginalAfterVerification: Bool

    public init(archive: URL, settings: CompressionSettings, destinationDirectory: URL? = nil, readOptions: ReadOptions = ReadOptions(),
                newPassword: Secret? = nil, trashOriginalAfterVerification: Bool = false) {
        self.archive = archive
        self.settings = settings
        self.destinationDirectory = destinationDirectory
        self.readOptions = readOptions
        self.newPassword = newPassword
        self.trashOriginalAfterVerification = trashOriginalAfterVerification
    }
}

/// Something the target format may lose.
public struct ConversionWarning: Codable, Sendable, Hashable {
    public var feature: String
    public var message: String
}

public struct ConversionOutcome: Sendable {
    public var created: CreatedArchive
    public var warnings: [ConversionWarning]
    /// Entry-by-entry comparison of source and result (content hashes).
    public var comparison: ComparisonResult
    public var trashedOriginal: Bool
}

/// Conversion presets shown in the UI.
public enum ConversionPresets {
    public static let all: [(name: String, settings: CompressionSettings)] = [
        ("ZIP (most compatible)", CompressionSettings(format: .zip, method: .deflate, level: 6)),
        ("7z (smaller)", CompressionSettings(format: .sevenZip, method: .lzma2, level: 7, solid: .on)),
        ("TAR + Zstandard (fast)", CompressionSettings(format: .tarZstd, method: .zstd, level: 3)),
        ("TAR + XZ (small, preserves Unix metadata)", CompressionSettings(format: .tarXz, method: .xz, level: 6)),
        ("Encrypted 7z", CompressionSettings(format: .sevenZip, method: .lzma2, level: 7, encryption: EncryptionSettings(method: .sevenZipAES256, encryptFilenames: true))),
    ]
}

extension ArchiveService {
    /// Features of `listing` that `target` cannot represent.
    public func conversionWarnings(from listing: ArchiveListing, to target: CompressionSettings) -> [ConversionWarning] {
        var w: [ConversionWarning] = []
        let container = FormatCatalog.descriptor(for: target.format)?.effectiveContainer ?? target.format
        let kind = FormatCatalog.descriptor(for: target.format)?.kind
        let entries = listing.entries
        if listing.properties.hasEncryptedEntries == true || entries.contains(where: \.isEncrypted) {
            if target.encryption == nil {
                w.append(.init(feature: "Encryption", message: "The original is encrypted; the converted archive will NOT be, unless you enable encryption."))
            }
        }
        if listing.properties.hasEncryptedHeaders == true, !(target.encryption?.encryptFilenames ?? false) || ![FormatID.sevenZip, .appleEncryptedArchive].contains(container) {
            w.append(.init(feature: "Filename protection", message: "File names are hidden in the original but will be visible in the converted archive."))
        }
        let unixPerms = entries.contains { ($0.permissions ?? 0o644) & 0o7000 != 0 || ($0.permissions.map { $0 & 0o111 != 0 } ?? false) }
        if unixPerms, container == .sevenZip {
            w.append(.init(feature: "Permissions", message: "7z stores Unix permissions only partially; executable bits may be lost on some tools."))
        }
        if entries.contains(where: { !$0.extendedAttributeNames.isEmpty }), target.metadata != .macPreservation || ![.tar, .xar, .appleArchive, .cpio].contains(container) && kind != .compressedArchive {
            w.append(.init(feature: "Extended attributes", message: "Extended attributes (Finder tags, quarantine, etc.) will not be kept."))
        }
        if entries.contains(where: { $0.type == .hardlink }), ![FormatID.tar, .cpio].contains(container) && kind != .compressedArchive {
            w.append(.init(feature: "Hard links", message: "Hard links will be stored as separate copies."))
        }
        if entries.contains(where: { $0.type == .symlink }), container == .sevenZip || kind == .compressionStream {
            w.append(.init(feature: "Symbolic links", message: "Symbolic links may be stored as copies of their targets or skipped."))
        }
        if entries.contains(where: { $0.type == .special }) {
            w.append(.init(feature: "Special files", message: "Device files, FIFOs and sockets are never extracted and will be missing."))
        }
        if listing.properties.comment != nil, container != .zip {
            w.append(.init(feature: "Comment", message: "The archive comment will not be kept."))
        }
        if [FormatID.apk, .ipa, .jar, .appx, .msix, .pkg].contains(listing.properties.format) {
            w.append(.init(feature: "Signature", message: "This package is signed; a converted copy is not a valid signed package."))
        }
        return w
    }

    /// Converts an archive: secure extraction to a private staging folder, recompression, then
    /// verification by comparing content hashes of every entry. The original is never modified.
    public func convert(_ request: ConvertRequest, progress: OperationProgress = OperationProgress()) throws -> ConversionOutcome {
        let fm = FileManager.default
        let opened = try open(request.archive, options: request.readOptions, progress: OperationProgress())
        let warnings = conversionWarnings(from: opened.listing, to: request.settings)
        let destDir = request.destinationDirectory ?? request.archive.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: destDir.path) else { throw ArchiveError.permissionDenied(path: destDir.path) }
        if let total = opened.listing.totalUncompressedSize, let free = Self.freeSpace(at: destDir), total * 2 > free {
            throw ArchiveError.insufficientSpace(needed: total * 2, available: free)
        }
        Leftovers.sweep(destDir)
        let work = destDir.appendingPathComponent(".ua-convert-\(TempToken.make())", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }

        progress.setPhase("Extracting")
        var opts = ExtractionOptions(conflictPolicy: .keepBoth, linkPolicy: .preserveSafe, skipAppleDoubleArtifacts: false, archiveSize: opened.source.totalSize)
        opts.restoreExtendedAttributes = true
        let sink = try SafeExtractionSink(destination: work, options: opts, progress: progress)
        var notes: [String] = []
        _ = try withEngines(for: opened.detection.format, EngineRequirements(operations: .extract), notes: &notes) {
            try $0.extract(opened.source, selection: .all, into: sink, options: request.readOptions, progress: progress)
        }
        try sink.finish()

        progress.setPhase("Compressing")
        var settings = request.settings
        settings.includeRootFolder = true // the staged top-level items are the roots
        settings.grouping = .single
        let items = ((try? fm.contentsOfDirectory(atPath: work.path)) ?? []).sorted().map { work.appendingPathComponent($0) }
        guard !items.isEmpty else { throw ArchiveError.verificationFailed(details: "The source archive contained no extractable items.") }
        let base = Self.baseName(for: request.archive)
        let compressed = try compress(CompressRequest(items: items, destinationDirectory: destDir, archiveName: base, settings: settings,
                                                      password: request.newPassword, verifyAfterCreation: true), progress: progress)
        guard let created = compressed.archives.first else { throw ArchiveError.internalError("no output") }

        // Verify: every original entry must be present with identical content.
        progress.setPhase("Verifying")
        var comparison = try compare(request.archive, created.outputs[0], mode: .content,
                                     leftOptions: request.readOptions,
                                     rightOptions: ReadOptions(passwordProvider: request.newPassword.map { FixedPasswordProvider($0) }),
                                     progress: OperationProgress())
        // Entries refused by the extraction safety checks (unsafe paths, device files) are expected to be absent.
        let refused = Set((sink.report.blocked + sink.report.skipped).map { ArchivePath.normalizeForDisplay($0.path) })
        comparison.removed.removeAll { refused.contains($0) }
        if !comparison.removed.isEmpty || !comparison.modified.isEmpty {
            for u in created.outputs { try? fm.removeItem(at: u) }
            throw ArchiveError.verificationFailed(details: "The converted archive differs from the original (\(comparison.removed.count) missing, \(comparison.modified.count) changed). It was deleted; the original is untouched.")
        }
        var trashed = false
        if request.trashOriginalAfterVerification {
            #if os(macOS)
            for v in opened.source.volumes {
                var out: NSURL?
                if (try? fm.trashItem(at: v, resultingItemURL: &out)) != nil { trashed = true }
            }
            #endif
        }
        return ConversionOutcome(created: created, warnings: warnings, comparison: comparison, trashedOriginal: trashed)
    }
}
