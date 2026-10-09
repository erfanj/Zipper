import Foundation

/// Operations an engine can perform on a format.
public struct EngineOperations: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let inspect = EngineOperations(rawValue: 1 << 0)
    public static let extract = EngineOperations(rawValue: 1 << 1)
    public static let create = EngineOperations(rawValue: 1 << 2)
    public static let modify = EngineOperations(rawValue: 1 << 3)
    public static let test = EngineOperations(rawValue: 1 << 4)
    public static let repair = EngineOperations(rawValue: 1 << 5)
    public static let createSplit = EngineOperations(rawValue: 1 << 6)
    public static let readSplit = EngineOperations(rawValue: 1 << 7)
    public static let encrypt = EngineOperations(rawValue: 1 << 8)
    public static let decrypt = EngineOperations(rawValue: 1 << 9)
    public static let encryptFilenames = EngineOperations(rawValue: 1 << 10)
    public static let preserveMetadata = EngineOperations(rawValue: 1 << 11)
    public static let streamingRead = EngineOperations(rawValue: 1 << 12)
    public static let streamingWrite = EngineOperations(rawValue: 1 << 13)
    public static let multithreaded = EngineOperations(rawValue: 1 << 14)
    public static let selectiveExtract = EngineOperations(rawValue: 1 << 15)

    public static let readOnly: EngineOperations = [.inspect, .extract, .test, .selectiveExtract]

    public static let allNamed: [(EngineOperations, String)] = [
        (.inspect, "inspect"), (.extract, "extract"), (.create, "create"), (.modify, "modify"),
        (.test, "test"), (.repair, "repair"), (.createSplit, "createSplit"), (.readSplit, "readSplit"),
        (.encrypt, "encrypt"), (.decrypt, "decrypt"), (.encryptFilenames, "encryptFilenames"),
        (.preserveMetadata, "preserveMetadata"), (.streamingRead, "streamingRead"),
        (.streamingWrite, "streamingWrite"), (.multithreaded, "multithreaded"),
        (.selectiveExtract, "selectiveExtract"),
    ]

    public var names: [String] { Self.allNamed.filter { contains($0.0) }.map(\.1) }

    public init(from decoder: Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)
        var v: EngineOperations = []
        for n in names { if let op = Self.allNamed.first(where: { $0.1 == n })?.0 { v.insert(op) } }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(names)
    }
}

/// What one engine can do with one format.
public struct EngineFormatSupport: Codable, Hashable, Sendable {
    public var format: FormatID
    public var operations: EngineOperations
    /// Methods available when creating.
    public var compressionMethods: [CompressionMethod]
    /// Encryption methods available when creating.
    public var encryptionMethods: [EncryptionMethod]
    /// Encryption methods that can be decrypted.
    public var decryptionMethods: [EncryptionMethod]
    public var memory: String?
    public var threading: String?
    public var streaming: String?
    public var limitations: [String]

    public init(format: FormatID, operations: EngineOperations, compressionMethods: [CompressionMethod] = [],
                encryptionMethods: [EncryptionMethod] = [], decryptionMethods: [EncryptionMethod] = [],
                memory: String? = nil, threading: String? = nil, streaming: String? = nil, limitations: [String] = []) {
        self.format = format
        self.operations = operations
        self.compressionMethods = compressionMethods
        self.encryptionMethods = encryptionMethods
        self.decryptionMethods = decryptionMethods
        self.memory = memory
        self.threading = threading
        self.streaming = streaming
        self.limitations = limitations
    }
}

/// Static and runtime information about an engine.
public struct EngineDescriptor: Codable, Hashable, Sendable {
    public var id: EngineID
    public var name: String
    /// How the engine is implemented (linked C library, bundled helper executable, system framework…).
    public var implementation: String
    public var version: String?
    public var minimumVersion: String?
    public var license: String
    public var licensingRestrictions: String?
    public var isAvailable: Bool
    public var unavailableReason: String?
    /// Where the helper binary lives (for external engines).
    public var location: String?
    /// How untrusted input is isolated when using this engine.
    public var isolation: String

    public init(id: EngineID, name: String, implementation: String, version: String?, minimumVersion: String?,
                license: String, licensingRestrictions: String? = nil, isAvailable: Bool, unavailableReason: String? = nil,
                location: String? = nil, isolation: String) {
        self.id = id
        self.name = name
        self.implementation = implementation
        self.version = version
        self.minimumVersion = minimumVersion
        self.license = license
        self.licensingRestrictions = licensingRestrictions
        self.isAvailable = isAvailable
        self.unavailableReason = unavailableReason
        self.location = location
        self.isolation = isolation
    }
}

/// An archive on disk, possibly spanning several volumes.
public struct ArchiveSource: Sendable, Hashable {
    /// The file the user opened (or the first volume).
    public var url: URL
    /// All volumes in order. A single-file archive has exactly one.
    public var volumes: [URL]
    public var format: FormatID
    /// Compression layers from outermost to innermost (tar.gz → [gz, tar]).
    public var layers: [FormatID]

    public init(url: URL, volumes: [URL]? = nil, format: FormatID, layers: [FormatID] = []) {
        self.url = url
        self.volumes = volumes ?? [url]
        self.format = format
        self.layers = layers
    }

    public var totalSize: UInt64 {
        volumes.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? UInt64) ?? 0) }
    }
}

/// Options for reading archives.
public struct ReadOptions: Sendable {
    public var passwordProvider: PasswordProvider?
    /// Legacy filename character set (e.g. "CP437", "CP932", "GBK", "CP1256"). Nil means automatic.
    public var filenameEncoding: String?

    public init(passwordProvider: PasswordProvider? = nil, filenameEncoding: String? = nil) {
        self.passwordProvider = passwordProvider
        self.filenameEncoding = filenameEncoding
    }
}

/// Which entries to extract.
public enum EntrySelection: Sendable, Equatable {
    case all
    /// Entries whose normalised path equals one of these, or lies inside one of these directories.
    case paths(Set<String>)

    public func includes(_ path: String) -> Bool {
        switch self {
        case .all: return true
        case .paths(let set):
            let p = ArchivePath.normalizeForDisplay(path)
            if set.contains(p) { return true }
            var parent = p
            while let i = parent.lastIndex(of: "/") {
                parent = String(parent[..<i])
                if set.contains(parent) { return true }
            }
            return false
        }
    }
}

/// Extra per-entry data that is not part of the listing model.
public struct EntryExtras: Sendable {
    public var extendedAttributes: [(name: String, value: [UInt8])]
    public init(extendedAttributes: [(name: String, value: [UInt8])] = []) {
        self.extendedAttributes = extendedAttributes
    }
    public static let none = EntryExtras()
}

/// Receives entry data from an engine. All filesystem writes during extraction go through a sink so
/// that path validation, conflict handling and safety limits are enforced in exactly one place.
public protocol ExtractionSink: AnyObject {
    /// Called for every selected entry before its data. Return a writer to receive the data, or nil
    /// if the entry needs no data (directories, links) or is being skipped.
    func begin(_ entry: ArchiveEntry, extras: EntryExtras) throws -> EntryDataWriter?
    /// Called after the last entry. Applies deferred metadata and returns.
    func finish() throws
}

public protocol EntryDataWriter: AnyObject {
    func write(_ bytes: UnsafeRawBufferPointer) throws
    /// The entry's data is complete and valid.
    func commit() throws
    /// The entry failed; discard partial data.
    func abort()
}

/// Settings for creating an archive, already resolved for a single output.
public struct CreateRequest: Sendable {
    public var output: URL
    public var format: FormatID
    public var items: [SourceItem]
    public var settings: CompressionSettings
    public var password: Secret?

    public init(output: URL, format: FormatID, items: [SourceItem], settings: CompressionSettings, password: Secret? = nil) {
        self.output = output
        self.format = format
        self.items = items
        self.settings = settings
        self.password = password
    }
}

public struct CreateResult: Sendable {
    /// The archive (or first volume) and all volumes written.
    public var outputs: [URL]
    public var inputBytes: UInt64
    public var outputBytes: UInt64
    public var entryCount: Int
    public var warnings: [String]
    public var engine: EngineID

    public init(outputs: [URL], inputBytes: UInt64, outputBytes: UInt64, entryCount: Int, warnings: [String], engine: EngineID) {
        self.outputs = outputs
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.entryCount = entryCount
        self.warnings = warnings
        self.engine = engine
    }
}

/// An archive engine. Engines are trusted, signed code that ships with the application; they are
/// never loaded from arbitrary locations.
public protocol ArchiveEngine: AnyObject, Sendable {
    var descriptor: EngineDescriptor { get }
    /// Support for `format`, or nil.
    func support(for format: FormatID) -> EngineFormatSupport?
    var supportedFormats: [FormatID] { get }

    func list(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> ArchiveListing
    func extract(_ source: ArchiveSource, selection: EntrySelection, into sink: ExtractionSink,
                 options: ReadOptions, progress: OperationProgress) throws
    /// Verifies the archive. The default implementation decodes every entry into a verifying sink.
    func test(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> IntegrityReport
    func create(_ request: CreateRequest, progress: OperationProgress) throws -> CreateResult
}

public extension ArchiveEngine {
    var id: EngineID { descriptor.id }

    func can(_ ops: EngineOperations, _ format: FormatID) -> Bool {
        guard descriptor.isAvailable, let s = support(for: format) else { return false }
        return s.operations.contains(ops)
    }

    func create(_ request: CreateRequest, progress: OperationProgress) throws -> CreateResult {
        throw ArchiveError.operationNotSupported(format: request.format, operation: "creation", reason: "\(descriptor.name) cannot create this format.")
    }

    func test(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> IntegrityReport {
        let sink = VerifyingSink()
        var report = IntegrityReport(archive: source.url.lastPathComponent, format: source.format, engine: descriptor.id)
        do {
            try extract(source, selection: .all, into: sink, options: options, progress: progress)
            try sink.finish()
        } catch let e as ArchiveError {
            if case .cancelled = e { throw e }
            if case .passwordRequired = e { throw e }
            if case .incorrectPassword = e { throw e }
            report.issues.append(.init(entry: sink.currentEntry, message: e.explanation, code: e.code))
        }
        report.absorb(sink)
        report.volumes = source.volumes.count
        return report
    }
}
