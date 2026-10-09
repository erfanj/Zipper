import Foundation

/// Requirements that narrow which engine may perform an operation.
public struct EngineRequirements: Sendable {
    public var operations: EngineOperations
    public var encryption: EncryptionMethod?
    public var method: CompressionMethod?

    public init(operations: EngineOperations, encryption: EncryptionMethod? = nil, method: CompressionMethod? = nil) {
        self.operations = operations
        self.encryption = encryption
        self.method = method
    }
}

/// Holds the available engines in priority order and answers "who can do X with format Y?".
///
/// Engines are compiled into the application. There is deliberately no mechanism to load engine
/// code from disk at runtime; helper executables used by some engines are resolved only from the
/// app bundle or fixed system locations.
public final class EngineRegistry: @unchecked Sendable {
    public private(set) var engines: [ArchiveEngine]
    /// User override: preferred engine per format.
    public var preferred: [FormatID: EngineID] = [:]

    public init(engines: [ArchiveEngine]) {
        self.engines = engines
    }

    public func engine(_ id: EngineID) -> ArchiveEngine? { engines.first { $0.id == id } }

    /// Engines able to satisfy `req` for `format`, best first.
    public func candidates(for format: FormatID, _ req: EngineRequirements) -> [ArchiveEngine] {
        let effective = FormatCatalog.descriptor(for: format)?.effectiveContainer ?? format
        var list = engines.filter { e in
            guard e.descriptor.isAvailable else { return false }
            guard let s = e.support(for: format) ?? e.support(for: effective) else { return false }
            guard s.operations.contains(req.operations) else { return false }
            if let enc = req.encryption {
                let methods = req.operations.contains(.create) ? s.encryptionMethods : s.decryptionMethods
                if !methods.contains(enc) { return false }
            }
            if let m = req.method, req.operations.contains(.create), !s.compressionMethods.isEmpty, !s.compressionMethods.contains(m) {
                return false
            }
            return true
        }
        if let pref = preferred[format], let i = list.firstIndex(where: { $0.id == pref }) {
            list.insert(list.remove(at: i), at: 0)
        }
        return list
    }

    /// The format support entry an engine uses for `format` (packages map to their container).
    public func support(of engine: ArchiveEngine, for format: FormatID) -> EngineFormatSupport? {
        engine.support(for: format) ?? FormatCatalog.descriptor(for: format)?.baseFormat.flatMap { engine.support(for: $0) }
    }

    /// Merged view of every recognised format and what the installed engines can do with it.
    public func capabilityMatrix() -> [FormatCapabilityRow] {
        FormatCatalog.all.map { d in
            var row = FormatCapabilityRow(format: d.id, name: d.name, kind: d.kind, category: d.category,
                                          extensions: d.extensions, baseFormat: d.baseFormat, layers: d.layers,
                                          isMultiFile: d.isMultiFile, signatures: d.signatures.count, engines: [], notes: d.notes)
            for e in engines {
                guard let s = support(of: e, for: d.id) else { continue }
                row.engines.append(.init(engine: e.id, available: e.descriptor.isAvailable, support: s))
            }
            return row
        }
    }
}

public struct FormatCapabilityRow: Codable, Sendable {
    public struct EngineEntry: Codable, Sendable {
        public var engine: EngineID
        public var available: Bool
        public var support: EngineFormatSupport
    }

    public var format: FormatID
    public var name: String
    public var kind: FormatKind
    public var category: FormatCategory
    public var extensions: [String]
    public var baseFormat: FormatID?
    public var layers: [FormatID]
    public var isMultiFile: Bool
    public var signatures: Int
    public var engines: [EngineEntry]
    public var notes: String?

    /// Union of operations across *available* engines.
    public var availableOperations: EngineOperations {
        engines.filter(\.available).reduce(EngineOperations()) { $0.union($1.support.operations) }
    }
}
