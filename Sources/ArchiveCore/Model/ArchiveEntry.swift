import Foundation

/// The type of filesystem object an archive entry represents.
public enum EntryType: String, Codable, Sendable {
    case file
    case directory
    case symlink
    case hardlink
    /// Device nodes, FIFOs, sockets. Never materialised during extraction.
    case special
}

/// One entry in an archive listing. Every optional property means "not known for this archive";
/// the UI shows "Unknown" rather than guessing.
public struct ArchiveEntry: Codable, Hashable, Sendable, Identifiable {
    /// Index of the entry within the archive (engine-specific, stable for one listing).
    public var index: Int
    /// The path exactly as stored (decoded to Unicode). May be unsafe; never use it directly on disk.
    public var path: String
    public var type: EntryType
    public var uncompressedSize: UInt64?
    public var compressedSize: UInt64?
    public var modificationDate: Date?
    public var creationDate: Date?
    public var accessDate: Date?
    /// POSIX permission bits (lower 12 bits) if recorded.
    public var permissions: UInt16?
    public var ownerName: String?
    public var groupName: String?
    public var uid: Int?
    public var gid: Int?
    public var isEncrypted: Bool
    /// Compression method as reported by the engine (e.g. "LZMA2:24", "Deflate").
    public var method: String?
    /// CRC-32 as stored in the archive, when the format records one.
    public var crc32: UInt32?
    /// Target for symlinks / hardlinks as stored.
    public var linkTarget: String?
    /// Extended attribute names (values are not loaded into listings).
    public var extendedAttributeNames: [String]
    public var comment: String?

    public var id: Int { index }

    public init(index: Int, path: String, type: EntryType, uncompressedSize: UInt64? = nil, compressedSize: UInt64? = nil,
                modificationDate: Date? = nil, creationDate: Date? = nil, accessDate: Date? = nil,
                permissions: UInt16? = nil, ownerName: String? = nil, groupName: String? = nil,
                uid: Int? = nil, gid: Int? = nil, isEncrypted: Bool = false, method: String? = nil,
                crc32: UInt32? = nil, linkTarget: String? = nil, extendedAttributeNames: [String] = [], comment: String? = nil) {
        self.index = index
        self.path = path
        self.type = type
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.accessDate = accessDate
        self.permissions = permissions
        self.ownerName = ownerName
        self.groupName = groupName
        self.uid = uid
        self.gid = gid
        self.isEncrypted = isEncrypted
        self.method = method
        self.crc32 = crc32
        self.linkTarget = linkTarget
        self.extendedAttributeNames = extendedAttributeNames
        self.comment = comment
    }

    /// Path normalised for display and matching: forward slashes, no leading "./" or "/", no trailing "/".
    public var normalizedPath: String { ArchivePath.normalizeForDisplay(path) }

    public var name: String {
        let p = normalizedPath
        if let i = p.lastIndex(of: "/") { return String(p[p.index(after: i)...]) }
        return p
    }

    public var parentPath: String {
        let p = normalizedPath
        if let i = p.lastIndex(of: "/") { return String(p[..<i]) }
        return ""
    }

    public var fileExtension: String {
        let n = name
        guard let i = n.lastIndex(of: "."), i != n.startIndex else { return "" }
        return String(n[n.index(after: i)...]).lowercased()
    }

    /// Compressed / uncompressed, when both are known and meaningful.
    public var compressionRatio: Double? {
        guard let u = uncompressedSize, let c = compressedSize, u > 0 else { return nil }
        return Double(c) / Double(u)
    }
}

/// Helpers for archive-internal paths (always `/`-separated).
public enum ArchivePath {
    public static func normalizeForDisplay(_ raw: String) -> String {
        var p = raw.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }
}

/// Archive-level properties. Optional values are unknown.
public struct ArchiveProperties: Codable, Hashable, Sendable {
    public var format: FormatID
    /// Human-readable format as reported by the engine (e.g. "RAR5", "ZIP 2.0 (deflation)").
    public var formatDescription: String?
    /// Compression layers detected by the engine (e.g. ["gzip"]).
    public var filters: [String]
    public var archiveSize: UInt64?
    public var isSolid: Bool?
    public var hasEncryptedEntries: Bool?
    public var hasEncryptedHeaders: Bool?
    public var encryptionMethod: String?
    public var compressionMethods: [String]
    public var volumeCount: Int
    public var comment: String?
    public var engine: EngineID

    public init(format: FormatID, formatDescription: String? = nil, filters: [String] = [], archiveSize: UInt64? = nil,
                isSolid: Bool? = nil, hasEncryptedEntries: Bool? = nil, hasEncryptedHeaders: Bool? = nil,
                encryptionMethod: String? = nil, compressionMethods: [String] = [], volumeCount: Int = 1,
                comment: String? = nil, engine: EngineID) {
        self.format = format
        self.formatDescription = formatDescription
        self.filters = filters
        self.archiveSize = archiveSize
        self.isSolid = isSolid
        self.hasEncryptedEntries = hasEncryptedEntries
        self.hasEncryptedHeaders = hasEncryptedHeaders
        self.encryptionMethod = encryptionMethod
        self.compressionMethods = compressionMethods
        self.volumeCount = volumeCount
        self.comment = comment
        self.engine = engine
    }
}

/// The result of listing an archive.
public struct ArchiveListing: Codable, Sendable {
    public var properties: ArchiveProperties
    public var entries: [ArchiveEntry]

    public init(properties: ArchiveProperties, entries: [ArchiveEntry]) {
        self.properties = properties
        self.entries = entries
    }

    public var fileCount: Int { entries.filter { $0.type == .file || $0.type == .hardlink }.count }

    /// Directories, including implied parents of files that have no explicit directory entry.
    public var directoryCount: Int { allDirectoryPaths.count }

    public var allDirectoryPaths: Set<String> {
        var dirs = Set<String>()
        for e in entries {
            let p = e.normalizedPath
            if e.type == .directory, !p.isEmpty { dirs.insert(p) }
            var parent = e.type == .directory ? p : e.parentPath
            while !parent.isEmpty {
                dirs.insert(parent)
                if let i = parent.lastIndex(of: "/") { parent = String(parent[..<i]) } else { parent = "" }
            }
        }
        return dirs
    }

    /// Sum of known uncompressed sizes, or nil if any file's size is unknown.
    public var totalUncompressedSize: UInt64? {
        var total: UInt64 = 0
        for e in entries where e.type == .file {
            guard let s = e.uncompressedSize else { return nil }
            total &+= s
        }
        return total
    }

    public var totalCompressedSize: UInt64? {
        var total: UInt64 = 0
        var any = false
        for e in entries where e.type == .file {
            if let s = e.compressedSize { total &+= s; any = true }
        }
        return any ? total : nil
    }

    /// Distinct top-level path components.
    public var topLevelNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for e in entries {
            let p = e.normalizedPath
            guard !p.isEmpty else { continue }
            let first = p.split(separator: "/", maxSplits: 1).first.map(String.init) ?? p
            if seen.insert(first).inserted { out.append(first) }
        }
        return out
    }
}
