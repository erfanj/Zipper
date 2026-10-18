#if os(macOS)
import AppIntents
import Foundation
import ArchiveCore
import ArchiveEngines
import ArchiverKit

// Shortcuts actions. They run without UI: the only passwords they use are the ones Shortcuts
// collects as parameters, and they never show dialogs.

enum IntentFormat: String, AppEnum {
    case zip, sevenZip, tarGz, tarXz, tarZstd, appleArchive

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Archive Format"
    static let caseDisplayRepresentations: [IntentFormat: DisplayRepresentation] = [
        .zip: "ZIP", .sevenZip: "7z", .tarGz: "TAR.GZ", .tarXz: "TAR.XZ", .tarZstd: "TAR.ZST", .appleArchive: "Apple Archive",
    ]

    var formatID: FormatID {
        switch self {
        case .zip: return .zip
        case .sevenZip: return .sevenZip
        case .tarGz: return .tarGzip
        case .tarXz: return .tarXz
        case .tarZstd: return .tarZstd
        case .appleArchive: return .appleArchive
        }
    }
}

enum IntentHash: String, AppEnum {
    case sha256, sha512, crc32, md5, sha1

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Checksum Algorithm"
    static let caseDisplayRepresentations: [IntentHash: DisplayRepresentation] = [
        .sha256: "SHA-256", .sha512: "SHA-512", .crc32: "CRC-32", .md5: "MD5 (legacy)", .sha1: "SHA-1 (legacy)",
    ]

    var algorithm: HashAlgorithm { HashAlgorithm(rawValue: rawValue) ?? .sha256 }
}

private func fileURL(_ f: IntentFile) throws -> URL {
    guard let u = f.fileURL else { throw ArchiveError.invalidArgument("The file must be on this Mac.") }
    return u
}

/// Archive work is synchronous and can take minutes; run it on a regular thread, not on Swift
/// concurrency's small cooperative pool.
private func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

struct CompressFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Compress Files"
    static let description = IntentDescription("Creates an archive from files and folders.")

    @Parameter(title: "Files") var files: [IntentFile]
    @Parameter(title: "Format", default: .zip) var format: IntentFormat
    @Parameter(title: "Level (0–9)", default: 6, inclusiveRange: (0, 9)) var level: Int
    @Parameter(title: "Archive Name") var name: String?

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let urls = try files.map(fileURL)
        let request = CompressRequest(items: urls, archiveName: name, settings: CompressionSettings(format: format.formatID, level: level))
        let outputs = try await background { try ArchiveService().compress(request).archives.flatMap(\.outputs) }
        return .result(value: outputs.map { IntentFile(fileURL: $0) })
    }
}

struct EncryptArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Encrypted Archive"
    static let description = IntentDescription("Creates a 7z archive with AES-256 and hidden file names, or an AES-256 ZIP.")

    @Parameter(title: "Files") var files: [IntentFile]
    @Parameter(title: "Password") var password: String
    @Parameter(title: "Use ZIP instead of 7z", default: false) var useZip: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let urls = try files.map(fileURL)
        let settings = useZip
            ? CompressionSettings(format: .zip, encryption: .init(method: .zipAES256))
            : CompressionSettings(format: .sevenZip, method: .lzma2, encryption: .init(method: .sevenZipAES256, encryptFilenames: true))
        let request = CompressRequest(items: urls, settings: settings, password: Secret(password), verifyAfterCreation: true)
        let outputs = try await background { try ArchiveService().compress(request).archives.flatMap(\.outputs) }
        return .result(value: outputs.map { IntentFile(fileURL: $0) })
    }
}

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Compress with Preset"
    static let description = IntentDescription("Creates an archive using one of Zipper's presets or your own.")

    @Parameter(title: "Files") var files: [IntentFile]
    @Parameter(title: "Preset Name", default: "Balanced") var presetName: String

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let stored = PresetStore(fileURL: ProductInfo.applicationSupport.appendingPathComponent("Presets.json")).load()
        guard let p = (BuiltInPresets.all + stored).first(where: { $0.name.caseInsensitiveCompare(presetName) == .orderedSame }) else {
            throw ArchiveError.invalidArgument("There's no preset named “\(presetName)”.")
        }
        guard p.settings.encryption == nil else {
            throw ArchiveError.invalidArgument("“\(p.name)” encrypts archives. Use “Create Encrypted Archive” instead.")
        }
        let request = CompressRequest(items: try files.map(fileURL), settings: p.settings, namePattern: p.namePattern,
                                      verifyAfterCreation: p.postActions.contains(.verifyArchive))
        let outputs = try await background { try ArchiveService().compress(request).archives.flatMap(\.outputs) }
        return .result(value: outputs.map { IntentFile(fileURL: $0) })
    }
}

struct ExtractArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Extract Archive"
    static let description = IntentDescription("Extracts an archive next to it and returns the extracted items.")

    @Parameter(title: "Archive") var archive: IntentFile
    @Parameter(title: "Password") var password: String?

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let request = ExtractRequest(archive: try fileURL(archive), readOptions: ReadOptions(passwordProvider: FixedPasswordProvider(password)))
        let items = try await background { try ArchiveService().extract(request).createdItems }
        return .result(value: items.map { IntentFile(fileURL: $0) })
    }
}

struct ConvertArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Archive"
    static let description = IntentDescription("Re-packs an archive in another format and checks every file.")

    @Parameter(title: "Archive") var archive: IntentFile
    @Parameter(title: "To", default: .zip) var format: IntentFormat

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let request = ConvertRequest(archive: try fileURL(archive), settings: CompressionSettings(format: format.formatID))
        let output = try await background { try ArchiveService().convert(request).created.outputs.first }
        guard let output else { throw ArchiveError.internalError("The conversion produced no file.") }
        return .result(value: IntentFile(fileURL: output))
    }
}

struct VerifyArchiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Verify Archive"
    static let description = IntentDescription("Tests every file in an archive and reports whether it is intact.")

    @Parameter(title: "Archive") var archive: IntentFile
    @Parameter(title: "Password") var password: String?

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let url = try fileURL(archive)
        let options = ReadOptions(passwordProvider: FixedPasswordProvider(password))
        let report = try await background { try ArchiveService().test(url, options: options) }
        return .result(value: report.result == .passed, dialog: IntentDialog(stringLiteral: report.textSummary))
    }
}

struct ChecksumIntent: AppIntent {
    static let title: LocalizedStringResource = "Calculate Checksum"
    static let description = IntentDescription("Calculates a file's checksum.")

    @Parameter(title: "File") var file: IntentFile
    @Parameter(title: "Algorithm", default: .sha256) var algorithm: IntentHash

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let url = try fileURL(file)
        let alg = algorithm.algorithm
        return .result(value: try await background { try StreamingHasher.hashFile(at: url, algorithm: alg) })
    }
}

struct ZipperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CompressFilesIntent(), phrases: ["Compress files with \(.applicationName)"],
                    shortTitle: "Compress", systemImageName: "archivebox")
        AppShortcut(intent: ExtractArchiveIntent(), phrases: ["Extract an archive with \(.applicationName)"],
                    shortTitle: "Extract", systemImageName: "tray.and.arrow.up")
        AppShortcut(intent: VerifyArchiveIntent(), phrases: ["Verify an archive with \(.applicationName)"],
                    shortTitle: "Verify", systemImageName: "checkmark.shield")
    }
}
#endif
