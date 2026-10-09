import Foundation
import ArchiveCore
import ArchiveEngines

/// What to do when the preferred engine can't handle an archive feature.
public enum FallbackPolicy: Sendable {
    /// Retry with the next capable engine and record why (default).
    case automatic
    /// Ask before retrying. The closure receives the failed engine, the error and the proposed engine.
    case ask(@Sendable (EngineID, ArchiveError, EngineID) -> Bool)
    /// Never retry with another engine.
    case never
}

/// An archive that has been identified and listed.
public struct OpenedArchive: Sendable {
    public var url: URL
    public var detection: DetectionResult
    public var source: ArchiveSource
    public var listing: ArchiveListing
    public var engine: EngineID
    /// Why another engine was used, if any.
    public var engineNotes: [String]
}

/// The façade used by the app, the CLI and automation. Thread-safe; long operations take an
/// `OperationProgress` for progress, pause and cancellation.
public final class ArchiveService: @unchecked Sendable {
    public let registry: EngineRegistry
    public var fallbackPolicy: FallbackPolicy = .automatic
    /// Drives thread counts for engines that support multithreading.
    public var performanceMode: PerformanceMode = .balanced

    public init(registry: EngineRegistry = DefaultEngines.registry()) {
        self.registry = registry
    }

    // MARK: Detection

    public func detect(_ url: URL) throws -> DetectionResult {
        guard FileManager.default.fileExists(atPath: url.path) || MultipartDetector.detect(url) != nil else {
            throw ArchiveError.fileNotFound(path: url.path)
        }
        guard let d = try FormatDetector.detect(url) else { throw ArchiveError.notAnArchive(path: url.path) }
        return d
    }

    /// Errors that mean "this engine can't do it", as opposed to "the archive is bad" or "the
    /// password is wrong". Only these trigger a fallback to another engine.
    static func isCapabilityError(_ e: ArchiveError) -> Bool {
        switch e {
        case .unsupportedMethod, .unsupportedEncryption, .operationNotSupported, .engineUnavailable, .noEngineAvailable:
            return true
        case .notAnArchive:
            return true // the engine's own detection disagreed; another engine may recognise it
        case .missingVolume:
            return true // e.g. split ZIP (.z01) sets, which only 7-Zip reads
        default:
            return false
        }
    }

    /// Runs `body` with each capable engine until one succeeds or a non-capability error occurs.
    func withEngines<T>(for format: FormatID, _ req: EngineRequirements, notes: inout [String],
                        _ body: (ArchiveEngine) throws -> T) throws -> (T, EngineID) {
        let candidates = registry.candidates(for: format, req)
        guard !candidates.isEmpty else {
            let any = registry.engines.contains { $0.support(for: format) != nil || registry.support(of: $0, for: format) != nil }
            var hint: String?
            if !any { hint = "No engine in this build supports the format." }
            else {
                let unavailable = registry.engines.filter { !$0.descriptor.isAvailable && ($0.support(for: format) != nil || $0.id == .sevenZip || $0.id == .unar) }
                hint = unavailable.compactMap(\.descriptor.unavailableReason).first
            }
            throw ArchiveError.noEngineAvailable(format: format, operation: req.operations.names.first ?? "open", hint: hint)
        }
        var lastError: ArchiveError?
        for (i, engine) in candidates.enumerated() {
            do {
                return (try body(engine), engine.id)
            } catch {
                let e = ArchiveError.wrap(error)
                lastError = e
                guard Self.isCapabilityError(e), i + 1 < candidates.count else { throw e }
                let next = candidates[i + 1]
                switch fallbackPolicy {
                case .never: throw e
                case .ask(let decide): if !decide(engine.id, e, next.id) { throw e }
                case .automatic: break
                }
                notes.append("\(engine.descriptor.name) could not handle this archive (\(e.title.lowercased())); used \(next.descriptor.name) instead.")
            }
        }
        throw lastError ?? ArchiveError.internalError("no engine ran")
    }

    // MARK: Open / list

    public func open(_ url: URL, options: ReadOptions = ReadOptions(), progress: OperationProgress = OperationProgress()) throws -> OpenedArchive {
        let detection = try detect(url)
        if let mp = detection.multipart, !mp.isComplete {
            // Missing parts are reported up front, with the exact file names expected.
            throw ArchiveError.missingVolume(expected: mp.missing)
        }
        let source = detection.source(for: url)
        var notes: [String] = []
        let (listing, engine) = try withEngines(for: detection.format, EngineRequirements(operations: .inspect), notes: &notes) {
            try $0.list(source, options: options, progress: progress)
        }
        return OpenedArchive(url: url, detection: detection, source: source, listing: listing, engine: engine, engineNotes: notes)
    }

    // MARK: Test

    public func test(_ url: URL, options: ReadOptions = ReadOptions(), progress: OperationProgress = OperationProgress()) throws -> IntegrityReport {
        let detection = try detect(url)
        var notes: [String] = []
        if let mp = detection.multipart, !mp.isComplete {
            var r = IntegrityReport(archive: url.lastPathComponent, format: detection.format, engine: "none")
            r.volumes = mp.volumes.count
            r.issues.append(.init(entry: nil, message: ArchiveError.missingVolume(expected: mp.missing).explanation, code: "missing-volume"))
            return r
        }
        let source = detection.source(for: url)
        progress.setPhase("Testing")
        let (report, _) = try withEngines(for: detection.format, EngineRequirements(operations: .test), notes: &notes) { engine -> IntegrityReport in
            let r = try engine.test(source, options: options, progress: progress)
            // A capability failure reported inside the report (rather than thrown) should still fall back.
            if let first = r.issues.first, ["unsupported-method", "unsupported-encryption"].contains(first.code) {
                throw first.code == "unsupported-method" ? ArchiveError.unsupportedMethod(method: first.message, entry: first.entry)
                    : ArchiveError.unsupportedEncryption(method: first.message)
            }
            return r
        }
        var final = report
        let container = FormatCatalog.descriptor(for: detection.format)?.effectiveContainer ?? detection.format
        if container == .zip, detection.multipart == nil {
            for p in ZipStructure.problems(url) { final.issues.append(.init(entry: nil, message: p, code: "damaged")) }
            final.checks.append("ZIP central directory structure")
        }
        return final
    }

    // MARK: Engine choice for creation

    func creationEngine(format: FormatID, settings: CompressionSettings) throws -> ArchiveEngine {
        var ops: EngineOperations = [.create]
        if settings.splitVolumeSize != nil { ops.insert(.createSplit) }
        if settings.encryption != nil { ops.insert(.encrypt) }
        if settings.encryption?.encryptFilenames == true, format == .sevenZip { ops.insert(.encryptFilenames) }
        let req = EngineRequirements(operations: ops, encryption: settings.encryption?.method, method: settings.method)
        var candidates = registry.candidates(for: format, req)
        // Prefer 7-Zip for 7z when available: multithreaded LZMA2 and full feature set.
        if format == .sevenZip || format == .cb7, let i = candidates.firstIndex(where: { $0.id == .sevenZip }), registry.preferred[format] == nil {
            candidates.insert(candidates.remove(at: i), at: 0)
        }
        if let e = candidates.first { return e }
        // Explain precisely what is missing.
        let base = registry.candidates(for: format, EngineRequirements(operations: [.create]))
        if base.isEmpty {
            if format == .rar || format == .cbr {
                throw ArchiveError.noEngineAvailable(format: format, operation: "create", hint: "RAR archives can only be created with RARLAB's licensed RAR program. Install it, or choose 7z or ZIP.")
            }
            throw ArchiveError.noEngineAvailable(format: format, operation: "create", hint: registry.engine(.sevenZip)?.descriptor.unavailableReason)
        }
        if settings.splitVolumeSize != nil {
            throw ArchiveError.operationNotSupported(format: format, operation: "split archives", reason: "Use 7z or ZIP (requires the 7-Zip engine), or split the finished file with Tools › Split File.")
        }
        if let enc = settings.encryption {
            throw ArchiveError.operationNotSupported(format: format, operation: "\(enc.method.displayName) encryption", reason: registry.engine(.sevenZip)?.descriptor.unavailableReason ?? "Choose ZIP (AES-256), 7z or Apple Encrypted Archive.")
        }
        if let m = settings.method {
            throw ArchiveError.operationNotSupported(format: format, operation: m.displayName, reason: "Choose another compression method.")
        }
        throw ArchiveError.noEngineAvailable(format: format, operation: "create", hint: nil)
    }

    /// Options the UI may show for a format: only meaningful, supported controls.
    public func creationOptions(for format: FormatID) -> CreationOptions {
        let engines = registry.candidates(for: format, EngineRequirements(operations: [.create]))
        var methods: [CompressionMethod] = []
        var enc: [EncryptionMethod] = []
        var ops: EngineOperations = []
        for e in engines {
            guard let s = registry.support(of: e, for: format) else { continue }
            for m in s.compressionMethods where !methods.contains(m) { methods.append(m) }
            for m in s.encryptionMethods where !enc.contains(m) { enc.append(m) }
            ops.formUnion(s.operations)
        }
        let kind = FormatCatalog.descriptor(for: format)?.kind
        let container = FormatCatalog.descriptor(for: format)?.effectiveContainer ?? format
        return CreationOptions(
            format: format, canCreate: !engines.isEmpty, methods: methods, encryptionMethods: enc,
            canEncryptFilenames: ops.contains(.encryptFilenames), canSplit: ops.contains(.createSplit),
            supportsLevel: container != .tar && container != .cpio && container != .xar && container != .ar && container != .iso,
            supportsDictionary: container == .sevenZip, supportsWordSize: container == .sevenZip,
            supportsSolid: container == .sevenZip || container == .rar, supportsThreads: ops.contains(.multithreaded),
            singleFileOnly: kind == .compressionStream, supportsComment: container == .zip || container == .rar,
            supportsMacMetadata: [.tar, .xar, .appleArchive, .appleEncryptedArchive, .cpio].contains(container) || kind == .compressedArchive)
    }
}

/// Which controls make sense for a format (so the UI never shows meaningless settings).
public struct CreationOptions: Sendable {
    public var format: FormatID
    public var canCreate: Bool
    public var methods: [CompressionMethod]
    public var encryptionMethods: [EncryptionMethod]
    public var canEncryptFilenames: Bool
    public var canSplit: Bool
    public var supportsLevel: Bool
    public var supportsDictionary: Bool
    public var supportsWordSize: Bool
    public var supportsSolid: Bool
    public var supportsThreads: Bool
    public var singleFileOnly: Bool
    public var supportsComment: Bool
    public var supportsMacMetadata: Bool
}
