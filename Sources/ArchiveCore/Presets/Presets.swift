import Foundation

/// Actions run after an operation succeeds.
public enum PostAction: String, Codable, Sendable, CaseIterable {
    case revealInFinder
    case verifyArchive
    /// Move the source items to the Trash after the archive verified successfully. Off by default.
    case trashSourcesAfterVerification
}

/// Where outputs go.
public enum DestinationRule: Codable, Hashable, Sendable {
    /// Next to the source items.
    case sameFolder
    case fixed(path: String)
    /// Ask every time.
    case ask
}

/// A saved configuration. Presets never contain passwords or other secrets, so exporting them as
/// JSON is always safe.
public struct Preset: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var isBuiltIn: Bool
    public var settings: CompressionSettings
    public var destination: DestinationRule
    /// Archive name pattern. Tokens: {name} {date} {time} {count}.
    public var namePattern: String
    public var conflictPolicy: ConflictPolicy
    public var postActions: [PostAction]
    /// Whether the user should be asked for a password when this preset is used.
    public var promptsForPassword: Bool

    public init(id: String, name: String, summary: String, isBuiltIn: Bool = false, settings: CompressionSettings,
                destination: DestinationRule = .sameFolder, namePattern: String = "{name}", conflictPolicy: ConflictPolicy = .keepBoth,
                postActions: [PostAction] = [], promptsForPassword: Bool = false) {
        self.id = id
        self.name = name
        self.summary = summary
        self.isBuiltIn = isBuiltIn
        self.settings = settings
        self.destination = destination
        self.namePattern = namePattern
        self.conflictPolicy = conflictPolicy
        self.postActions = postActions
        self.promptsForPassword = promptsForPassword
    }

    /// Expands the name pattern.
    public func archiveBaseName(for items: [URL], date: Date = Date()) -> String {
        let name: String
        if items.count == 1, let first = items.first {
            name = first.deletingPathExtension().lastPathComponent.isEmpty ? first.lastPathComponent : (first.hasDirectoryPath ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent)
        } else {
            name = "Archive"
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "HH.mm.ss"
        var s = namePattern
        s = s.replacingOccurrences(of: "{name}", with: name)
        s = s.replacingOccurrences(of: "{date}", with: df.string(from: date))
        s = s.replacingOccurrences(of: "{time}", with: tf.string(from: date))
        s = s.replacingOccurrences(of: "{count}", with: String(items.count))
        s = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return s.isEmpty ? "Archive" : s
    }
}

public enum BuiltInPresets {
    public static let fastest = Preset(
        id: "builtin.fastest", name: "Fastest", summary: "Minimum processing time. Zstandard at a low level; ZIP when sharing is needed.",
        isBuiltIn: true, settings: CompressionSettings(format: .tarZstd, method: .zstd, level: 1))
    public static let balanced = Preset(
        id: "builtin.balanced", name: "Balanced", summary: "A good balance of size and speed in a format every computer opens.",
        isBuiltIn: true, settings: CompressionSettings(format: .zip, method: .deflate, level: 6))
    public static let smallest = Preset(
        id: "builtin.smallest", name: "Smallest File", summary: "Best compression ratio: 7z, LZMA2, maximum level, solid. Slower.",
        isBuiltIn: true, settings: CompressionSettings(format: .sevenZip, method: .lzma2, level: 9, solid: .on))
    public static let maxCompatibility = Preset(
        id: "builtin.compat", name: "Maximum Compatibility", summary: "Plain ZIP with Deflate, no macOS metadata. Opens everywhere, including Windows' built-in tools.",
        isBuiltIn: true, settings: CompressionSettings(format: .zip, method: .deflate, level: 6, metadata: .crossPlatform,
                                                       filenameNormalization: .nfc))
    public static let secure = Preset(
        id: "builtin.secure", name: "Secure", summary: "7z with AES-256 and encrypted file names.",
        isBuiltIn: true, settings: CompressionSettings(format: .sevenZip, method: .lzma2, level: 7,
                                                       encryption: EncryptionSettings(method: .sevenZipAES256, encryptFilenames: true)),
        promptsForPassword: true)
    public static let macBackup = Preset(
        id: "builtin.macbackup", name: "Mac Backup", summary: "Preserves macOS metadata: extended attributes, permissions, symbolic links.",
        isBuiltIn: true, settings: CompressionSettings(format: .tarXz, method: .xz, level: 6, metadata: .macPreservation),
        postActions: [.verifyArchive])
    public static let crossPlatform = Preset(
        id: "builtin.crossplatform", name: "Cross-Platform Sharing", summary: "ZIP without .DS_Store, __MACOSX or resource forks; Unicode names normalised.",
        isBuiltIn: true, settings: CompressionSettings(format: .zip, method: .deflate, level: 6, metadata: .crossPlatform,
                                                       filenameNormalization: .nfc))
    // Example workflow presets
    public static let workBackup = Preset(
        id: "builtin.workbackup", name: "Work Backup", summary: "Dated 7z archive with strong encryption, verified after creation.",
        isBuiltIn: true, settings: CompressionSettings(format: .sevenZip, method: .lzma2, level: 7,
                                                       encryption: EncryptionSettings(method: .sevenZipAES256, encryptFilenames: true)),
        namePattern: "{name} {date}", postActions: [.verifyArchive], promptsForPassword: true)
    public static let sendToWindows = Preset(
        id: "builtin.windows", name: "Send to Windows", summary: "ZIP without Mac metadata files.",
        isBuiltIn: true, settings: CompressionSettings(format: .zip, method: .deflate, level: 6, metadata: .crossPlatform,
                                                       filters: FileFilter.commonExclusions, filenameNormalization: .nfc))
    public static let developerRelease = Preset(
        id: "builtin.devrelease", name: "Developer Release", summary: "tar.xz excluding version-control folders, build output, caches and logs.",
        isBuiltIn: true, settings: CompressionSettings(format: .tarXz, method: .xz, level: 9, filters: FileFilter.developerExclusions))
    public static let photoArchive = Preset(
        id: "builtin.photos", name: "Photo Archive", summary: "Photos are already compressed: store them quickly and keep their metadata.",
        isBuiltIn: true, settings: CompressionSettings(format: .zip, method: .store, level: 0, metadata: .macPreservation))

    public static let all: [Preset] = [balanced, fastest, smallest, maxCompatibility, secure, macBackup, crossPlatform,
                                       workBackup, sendToWindows, developerRelease, photoArchive]
}

/// Persists user presets as JSON. Built-in presets are not stored.
public final class PresetStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() -> [Preset] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode([Preset].self, from: data)) ?? []
    }

    public func save(_ presets: [Preset]) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(presets.filter { !$0.isBuiltIn }).write(to: fileURL, options: .atomic)
    }

    public static func export(_ presets: [Preset]) throws -> Data {
        try encoder.encode(presets.map { var p = $0; p.isBuiltIn = false; return p })
    }

    public static func importPresets(from data: Data) throws -> [Preset] {
        let list = try decoder.decode([Preset].self, from: data)
        return list.map { var p = $0; p.isBuiltIn = false; if p.id.hasPrefix("builtin.") { p.id = "user." + UUID().uuidString }; return p }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
