import Foundation

/// How macOS-specific metadata is handled when creating archives.
public enum MetadataMode: String, Codable, Sendable, CaseIterable {
    /// Store permissions, timestamps, symlinks; omit extended attributes, resource forks, .DS_Store.
    case crossPlatform
    /// Standard: permissions, timestamps and symlinks.
    case standard
    /// Store extended attributes, resource forks, ACLs and file flags where the format supports them.
    case macPreservation

    public var displayName: String {
        switch self {
        case .crossPlatform: return "Cross-Platform"
        case .standard: return "Standard"
        case .macPreservation: return "Mac Preservation"
        }
    }
}

public enum SymlinkPolicy: String, Codable, Sendable, CaseIterable {
    /// Store the link itself.
    case preserve
    /// Store the file or folder the link points to.
    case follow
    /// Leave links out (reported, never silent).
    case skip
}

public enum ArchiveGrouping: String, Codable, Sendable, CaseIterable {
    /// One archive containing every selected item.
    case single
    /// A separate archive for each selected item.
    case perItem
    /// A separate archive for each selected folder; loose files go into one archive.
    case perFolder
}

public enum SolidMode: Codable, Hashable, Sendable {
    case off
    case on
    /// Solid blocks of at most this many bytes.
    case blockSize(UInt64)
}

public struct EncryptionSettings: Codable, Hashable, Sendable {
    public var method: EncryptionMethod
    /// Hide file names (7z header encryption, Apple Encrypted Archive). Ignored if unsupported.
    public var encryptFilenames: Bool

    public init(method: EncryptionMethod, encryptFilenames: Bool = false) {
        self.method = method
        self.encryptFilenames = encryptFilenames
    }
}

/// Complete compression configuration. Contains no secrets; passwords are supplied separately.
public struct CompressionSettings: Codable, Hashable, Sendable {
    public var format: FormatID
    public var method: CompressionMethod?
    /// 0 (store/fastest) … 9 (maximum). Engines map this onto their native scale.
    public var level: Int
    public var dictionarySize: UInt64?
    /// LZMA "fast bytes" / word size.
    public var wordSize: Int?
    public var solid: SolidMode?
    public var blockSize: UInt64?
    /// nil = automatic, based on the performance mode.
    public var threads: Int?
    public var memoryLimit: UInt64?
    public var encryption: EncryptionSettings?
    /// Volume size in bytes for native multipart archives.
    public var splitVolumeSize: UInt64?
    public var metadata: MetadataMode
    public var includeHidden: Bool
    public var symlinks: SymlinkPolicy
    /// When compressing a single folder, store its name as the top-level directory.
    public var includeRootFolder: Bool
    public var grouping: ArchiveGrouping
    public var filters: [FilterRule]
    public var filenameNormalization: UnicodeNormalization
    public var comment: String?

    public init(format: FormatID = .zip, method: CompressionMethod? = nil, level: Int = 5, dictionarySize: UInt64? = nil,
                wordSize: Int? = nil, solid: SolidMode? = nil, blockSize: UInt64? = nil, threads: Int? = nil,
                memoryLimit: UInt64? = nil, encryption: EncryptionSettings? = nil, splitVolumeSize: UInt64? = nil,
                metadata: MetadataMode = .standard, includeHidden: Bool = true, symlinks: SymlinkPolicy = .preserve,
                includeRootFolder: Bool = true, grouping: ArchiveGrouping = .single, filters: [FilterRule] = [],
                filenameNormalization: UnicodeNormalization = .none, comment: String? = nil) {
        self.format = format
        self.method = method
        self.level = level
        self.dictionarySize = dictionarySize
        self.wordSize = wordSize
        self.solid = solid
        self.blockSize = blockSize
        self.threads = threads
        self.memoryLimit = memoryLimit
        self.encryption = encryption
        self.splitVolumeSize = splitVolumeSize
        self.metadata = metadata
        self.includeHidden = includeHidden
        self.symlinks = symlinks
        self.includeRootFolder = includeRootFolder
        self.grouping = grouping
        self.filters = filters
        self.filenameNormalization = filenameNormalization
        self.comment = comment
    }

    public var clampedLevel: Int { min(9, max(0, level)) }
}

/// A file or folder to be placed in an archive.
public struct SourceItem: Sendable, Hashable {
    public var url: URL
    /// Path inside the archive (`/`-separated, relative).
    public var archivePath: String
    public var type: EntryType
    public var size: UInt64
    public var linkTarget: String?
    public var modificationDate: Date?
    /// The directory `archivePath` is relative to (used by helper-tool engines).
    public var baseDirectory: URL

    public init(url: URL, archivePath: String, type: EntryType, size: UInt64, linkTarget: String? = nil,
                modificationDate: Date? = nil, baseDirectory: URL) {
        self.url = url
        self.archivePath = archivePath
        self.type = type
        self.size = size
        self.linkTarget = linkTarget
        self.modificationDate = modificationDate
        self.baseDirectory = baseDirectory
    }
}
