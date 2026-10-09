#if os(macOS)
import AppIntents
import Foundation
import ArchiveCore
import ArchiveEngines
import ArchiverKit

// Shortcuts actions. They run headless (no UI) and never prompt for anything except the
// password parameters Shortcuts itself collects.

enum IntentFormat: String, AppEnum {
    case zip, sevenZip, tarGz, tarXz, tarZstd, appleArchive

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Archive Format"
    static var caseDisplayRepresentations: [IntentFormat: DisplayRepresentation] = [
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
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Checksum Algorithm"
    static var caseDisplayRepresentations: [IntentHash: DisplayRepresentation] = [
        .sha256: "SHA-256", .sha512: "SHA-512", .crc32: "CRC-32", .md5: "MD5 (legacy)", .sha1: "SHA-1 (legacy)",
    ]
    var algorithm: HashAlgorithm { HashAlgorithm(rawValue: rawValue) ?? .sha256 }
}

private func url(_ f: IntentFile) throws -> URL {
    guard let u = f.fileURL else { throw ArchiveError.invalidArgument("The file must be on this Mac.") }
    return u
}

struct CompressFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Compress Files"
    static var description = IntentDescription("Creates an archive from files and folders.")
    @Parameter(title: "Files") var files: [IntentFile]
    @Parameter(title: "Format", default: .zip) var format: IntentFormat
    @Parameter(title: "Level (0–9)", default: 6, inclusiveRange: (0, 9)) var level: Int
    @Parameter(title: "Archive Name") var name: String?

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let urls = try files.map(url)
        let o = try ArchiveService().compress(CompressRequest(items: urls, archiveName: name, settings: CompressionSettings(format: format.formatID, level: level)))
        return .result(value: o.archives.flatMap(\.outputs).map { IntentFile(fileURL: $0) })
    }
}

struct EncryptArchiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Encrypted Archive"
    static var description = IntentDescription("Creates a 7z archive with AES-256 and encrypted file names (or AES-256 ZIP).")
    @Parameter(title: "Files") var files: [IntentFile]
    @Parameter(title: "Password") var password: String
    @Parameter(title: "Use ZIP instead of 7z", default: false) var useZip: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let urls = try files.map(url)
        let s = useZip ? CompressionSettings(format: .zip, encryption: .init(method: .zipAES256))
            : CompressionSettings(format: .sevenZip, method: .lzma2, encryption: .init(method: .sevenZipAES256, encryptFilenames: true))
        let o = try ArchiveService().compress(CompressRequest(items: urls, settings: s, password: Secret(password), verifyAfterCreation: true))
        return .result(value: o.archives.flatMap(\.outputs).map { IntentFile(fileURL: $0) })
    }
}

struct ApplyPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Compress with Preset"
    @Parameter(title: "Files") var files: [IntentFile]
    @Parameter(title: "Preset Name", default: "Balanced") var presetName: String

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let stored = PresetStore(fileURL: ProductInfo.applicationSupport.appendingPathComponent("Presets.json")).load()
        guard let p = (BuiltInPresets.all + stored).first(where: { $0.name.caseInsensitiveCompare(presetName) == .orderedSame }) else {
            throw ArchiveError.invalidArgument("No preset named “\(presetName)”.")
        }
        guard p.settings.encryption == nil else { throw ArchiveError.invalidArgument("Use “Create Encrypted Archive” for presets with encryption.") }
        let o = try ArchiveService().compress(CompressRequest(items: try files.map(url), settings: p.settings, namePattern: p.namePattern,
                                                              verifyAfterCreation: p.postActions.contains(.verifyArchive)))
        return .result(value: o.archives.flatMap(\.outputs).map { IntentFile(fileURL: $0) })
    }
}

struct ExtractArchiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Extract Archive"
    @Parameter(title: "Archive") var archive: IntentFile
    @Parameter(title: "Password") var password: String?

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let o = try ArchiveService().extract(ExtractRequest(archive: try url(archive), readOptions: ReadOptions(passwordProvider: FixedPasswordProvider(password))))
        return .result(value: o.createdItems.map { IntentFile(fileURL: $0) })
    }
}

struct ConvertArchiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert Archive"
    @Parameter(title: "Archive") var archive: IntentFile
    @Parameter(title: "To", default: .zip) var format: IntentFormat

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let o = try ArchiveService().convert(ConvertRequest(archive: try url(archive), settings: CompressionSettings(format: format.formatID)))
        guard let out = o.created.outputs.first else { throw ArchiveError.internalError("no output") }
        return .result(value: IntentFile(fileURL: out))
    }
}

struct VerifyArchiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Verify Archive"
    @Parameter(title: "Archive") var archive: IntentFile
    @Parameter(title: "Password") var password: String?

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let r = try ArchiveService().test(try url(archive), options: ReadOptions(passwordProvider: FixedPasswordProvider(password)))
        return .result(value: r.result == .passed, dialog: IntentDialog(stringLiteral: r.textSummary))
    }
}

struct ChecksumIntent: AppIntent {
    static var title: LocalizedStringResource = "Calculate Checksum"
    @Parameter(title: "File") var file: IntentFile
    @Parameter(title: "Algorithm", default: .sha256) var algorithm: IntentHash

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try StreamingHasher.hashFile(at: try url(file), algorithm: algorithm.algorithm))
    }
}

struct UniversalArchiverShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CompressFilesIntent(), phrases: ["Compress files with \(.applicationName)"], shortTitle: "Compress", systemImageName: "archivebox")
        AppShortcut(intent: ExtractArchiveIntent(), phrases: ["Extract an archive with \(.applicationName)"], shortTitle: "Extract", systemImageName: "tray.and.arrow.up")
        AppShortcut(intent: VerifyArchiveIntent(), phrases: ["Verify an archive with \(.applicationName)"], shortTitle: "Verify", systemImageName: "checkmark.shield")
    }
}
#endif
