import Foundation

/// The result of testing an archive. It reports what was actually checked: a pass means the
/// archive decoded without errors and stored checksums matched. It says nothing about malware or
/// the authenticity of the sender.
public struct IntegrityReport: Codable, Sendable {
    public struct Issue: Codable, Sendable, Hashable {
        public var entry: String?
        public var message: String
        public var code: String
        public init(entry: String?, message: String, code: String) {
            self.entry = entry
            self.message = message
            self.code = code
        }
    }

    public enum Result: String, Codable, Sendable {
        case passed = "Passed"
        case failed = "Failed"
    }

    public var archive: String
    public var format: FormatID
    public var engine: EngineID
    public var filesInspected: Int = 0
    public var directories: Int = 0
    public var encrypted: Bool = false
    public var filesVerified: Int = 0
    public var bytesVerified: UInt64 = 0
    public var volumes: Int = 1
    /// What was verified (e.g. "CRC-32 of every entry", "AES authentication codes").
    public var checks: [String] = []
    public var issues: [Issue] = []

    public init(archive: String, format: FormatID, engine: EngineID) {
        self.archive = archive
        self.format = format
        self.engine = engine
    }

    public var result: Result { issues.isEmpty ? .passed : .failed }

    mutating func absorb(_ sink: VerifyingSink) {
        filesInspected += sink.files
        directories += sink.directories
        filesVerified += sink.files - sink.failedFiles
        bytesVerified += sink.bytes
        encrypted = encrypted || sink.sawEncrypted
    }

    public var textSummary: String {
        var lines = [
            "Archive Integrity Report",
            "",
            "Archive: \(archive)",
            "Format: \(FormatCatalog.descriptor(for: format)?.name ?? format.rawValue)",
            "Engine: \(engine.rawValue)",
            "",
            "Files inspected: \(filesInspected)",
            "Directories: \(directories)",
            "Encrypted: \(encrypted ? "Yes" : "No")",
            "Volumes: \(volumes)",
            "",
            "Files verified: \(filesVerified)",
            "Data decoded: \(ByteFormatting.string(bytesVerified))",
            "Errors detected: \(issues.count)",
        ]
        if !checks.isEmpty { lines.append("Checks: \(checks.joined(separator: "; "))") }
        for i in issues { lines.append("  • \(i.entry.map { "\($0): " } ?? "")\(i.message)") }
        lines.append("")
        lines.append("Result: \(result.rawValue)")
        return lines.joined(separator: "\n")
    }
}

/// A sink that decodes every entry without writing anything to disk.
public final class VerifyingSink: ExtractionSink {
    public private(set) var files = 0
    public private(set) var directories = 0
    public private(set) var bytes: UInt64 = 0
    public private(set) var failedFiles = 0
    public private(set) var sawEncrypted = false
    public private(set) var currentEntry: String?
    /// Optional per-entry hash consumer (used by compare/duplicate tools).
    private let hashKind: HashAlgorithm?
    public private(set) var digests: [String: String] = [:]
    public private(set) var sizes: [String: UInt64] = [:]

    public init(hashing: HashAlgorithm? = nil) { self.hashKind = hashing }

    public func begin(_ entry: ArchiveEntry, extras: EntryExtras) throws -> EntryDataWriter? {
        currentEntry = entry.path
        if entry.isEncrypted { sawEncrypted = true }
        switch entry.type {
        case .directory:
            directories += 1
            return nil
        case .file:
            files += 1
            return Writer(sink: self, path: entry.normalizedPath, hasher: hashKind.map { StreamingHasher($0) })
        default:
            return nil
        }
    }

    public func finish() throws {}

    final class Writer: EntryDataWriter {
        unowned let sink: VerifyingSink
        let path: String
        let hasher: StreamingHasher?
        var count: UInt64 = 0
        init(sink: VerifyingSink, path: String, hasher: StreamingHasher?) {
            self.sink = sink
            self.path = path
            self.hasher = hasher
        }
        func write(_ bytes: UnsafeRawBufferPointer) throws {
            count += UInt64(bytes.count)
            sink.bytes += UInt64(bytes.count)
            hasher?.update(bytes)
        }
        func commit() throws {
            sink.sizes[path] = count
            if let h = hasher { sink.digests[path] = h.finalizeHex() }
        }
        func abort() { sink.failedFiles += 1 }
    }
}
