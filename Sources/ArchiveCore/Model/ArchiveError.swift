import Foundation

/// A safety limit that can stop an extraction.
public enum SafetyLimitKind: String, Codable, Sendable {
    case totalSize = "total extracted size"
    case entryCount = "number of files"
    case entrySize = "size of a single file"
    case expansionRatio = "compression ratio"
    case nestingDepth = "nesting depth"
    case duration = "processing time"
    case diskReserve = "free disk space reserve"
    case pathLength = "path length"
}

/// Every failure surfaced to users is one of these. Each case carries enough context for a
/// human-readable explanation, technical details and suggested next steps.
public enum ArchiveError: Error, Sendable, Equatable {
    case fileNotFound(path: String)
    case notAnArchive(path: String)
    case unsupportedFormat(String)
    /// The format is recognised but no installed engine can perform the operation.
    case noEngineAvailable(format: FormatID, operation: String, hint: String?)
    case engineUnavailable(EngineID, reason: String)
    case operationNotSupported(format: FormatID, operation: String, reason: String)
    case passwordRequired(archive: String)
    case incorrectPassword(archive: String)
    case unsupportedEncryption(method: String)
    case authenticationFailed(entry: String?)
    case unsupportedMethod(method: String, entry: String?)
    case damaged(details: String)
    case checksumMismatch(entry: String)
    case missingVolume(expected: [String])
    case truncated(details: String)
    case safetyLimitExceeded(SafetyLimitKind, limit: UInt64, observed: UInt64)
    case unsafePath(path: String, reason: String)
    case destinationExists(path: String)
    case insufficientSpace(needed: UInt64, available: UInt64)
    case permissionDenied(path: String)
    case io(path: String, code: Int32, message: String)
    case externalTool(tool: String, exitCode: Int32, message: String)
    case cancelled
    case invalidArgument(String)
    case verificationFailed(details: String)
    case notEditable(format: FormatID, reason: String)
    case internalError(String)

    /// Short title suitable for an alert.
    public var title: String {
        switch self {
        case .fileNotFound: return "File not found"
        case .notAnArchive: return "Not a recognised archive"
        case .unsupportedFormat: return "Unsupported format"
        case .noEngineAvailable: return "No compatible engine installed"
        case .engineUnavailable: return "Engine unavailable"
        case .operationNotSupported: return "Operation not supported for this format"
        case .passwordRequired: return "Password required"
        case .incorrectPassword: return "Incorrect password"
        case .unsupportedEncryption: return "Unsupported encryption"
        case .authenticationFailed: return "Authentication failed"
        case .unsupportedMethod: return "Unsupported compression method"
        case .damaged: return "The archive is damaged"
        case .checksumMismatch: return "Checksum mismatch"
        case .missingVolume: return "Missing archive part"
        case .truncated: return "The archive is incomplete"
        case .safetyLimitExceeded: return "Safety limit reached"
        case .unsafePath: return "Unsafe path blocked"
        case .destinationExists: return "Destination already exists"
        case .insufficientSpace: return "Not enough disk space"
        case .permissionDenied: return "Permission denied"
        case .io: return "Read/write error"
        case .externalTool: return "Helper tool failed"
        case .cancelled: return "Cancelled"
        case .invalidArgument: return "Invalid settings"
        case .verificationFailed: return "Verification failed"
        case .notEditable: return "This archive can't be edited"
        case .internalError: return "Unexpected error"
        }
    }

    /// Plain-language explanation.
    public var explanation: String {
        switch self {
        case .fileNotFound(let p):
            return "“\(Self.name(p))” could not be found. It may have been moved, renamed or deleted."
        case .notAnArchive(let p):
            return "“\(Self.name(p))” doesn't look like an archive Universal Archiver recognises."
        case .unsupportedFormat(let f):
            return "The \(f) format isn't supported."
        case .noEngineAvailable(let f, let op, let hint):
            return "Universal Archiver recognises this \(FormatCatalog.descriptor(for: f)?.name ?? f.rawValue) file, but no installed engine can \(op) it." + (hint.map { " " + $0 } ?? "")
        case .engineUnavailable(let e, let reason):
            return "The \(e.rawValue) engine can't be used: \(reason)"
        case .operationNotSupported(let f, let op, let reason):
            return "\(FormatCatalog.descriptor(for: f)?.name ?? f.rawValue) archives don't support \(op). \(reason)"
        case .passwordRequired(let a):
            return "“\(Self.name(a))” is encrypted. Enter its password to continue."
        case .incorrectPassword(let a):
            return "The password for “\(Self.name(a))” is incorrect."
        case .unsupportedEncryption(let m):
            return "The archive uses an encryption method (\(m)) that the available engines can't decrypt."
        case .authenticationFailed(let e):
            return "Encrypted data\(e.map { " in “\($0)”" } ?? "") failed its authentication check. The archive may be damaged or tampered with, or the password may be wrong."
        case .unsupportedMethod(let m, let e):
            return "\(e.map { "“\($0)” uses" } ?? "The archive uses") a compression method (\(m)) that the selected engine doesn't support."
        case .damaged(let d):
            return "The archive appears to be damaged. \(d)"
        case .checksumMismatch(let e):
            return "“\(e)” didn't match its stored checksum. The extracted data is not identical to what was archived."
        case .missingVolume(let expected):
            if expected.count == 1 { return "The archive is missing a part. Expected file: \(expected[0])" }
            return "The archive is missing \(expected.count) parts: \(expected.joined(separator: ", "))"
        case .truncated(let d):
            return "The archive ends unexpectedly; it may not have finished downloading. \(d)"
        case .safetyLimitExceeded(let kind, let limit, let observed):
            return "Extraction stopped because the \(kind.rawValue) exceeded the safety limit (\(Self.fmt(kind, limit)); reached \(Self.fmt(kind, observed))). This protects against decompression bombs. If you trust this archive, raise the limit in Settings › Extraction."
        case .unsafePath(let p, let reason):
            return "An entry tried to write outside the destination folder and was blocked: “\(p)” (\(reason))."
        case .destinationExists(let p):
            return "“\(Self.name(p))” already exists."
        case .insufficientSpace(let needed, let available):
            return "This needs about \(ByteFormatting.string(needed)) but only \(ByteFormatting.string(available)) is available."
        case .permissionDenied(let p):
            return "Universal Archiver doesn't have permission to access “\(Self.name(p))”."
        case .io(let p, _, let message):
            return "A read/write error occurred on “\(Self.name(p))”: \(message)"
        case .externalTool(let tool, _, let message):
            return "\(tool) reported an error: \(message)"
        case .cancelled:
            return "The operation was cancelled. Incomplete output was removed."
        case .invalidArgument(let m):
            return m
        case .verificationFailed(let d):
            return "The result did not pass verification. \(d)"
        case .notEditable(let f, let reason):
            return "\(FormatCatalog.descriptor(for: f)?.name ?? f.rawValue) archives can't be modified in place. \(reason)"
        case .internalError(let m):
            return "An unexpected internal error occurred: \(m)"
        }
    }

    /// Suggested next steps.
    public var suggestions: [String] {
        switch self {
        case .passwordRequired, .incorrectPassword:
            return ["Check the password for typing errors and keyboard layout.", "Passwords are case-sensitive."]
        case .missingVolume:
            return ["Put all parts of the archive in the same folder.", "Choose “Locate Missing Part…” to select it manually."]
        case .truncated:
            return ["Download the archive again.", "Use Tools › Repair to recover the readable files."]
        case .damaged, .checksumMismatch:
            return ["Obtain a fresh copy of the archive.", "Use Tools › Repair to recover the readable files."]
        case .noEngineAvailable(_, _, let hint):
            return hint.map { [$0] } ?? ["See Settings › Advanced › Format capabilities."]
        case .unsupportedMethod, .unsupportedEncryption:
            return ["Try opening the archive with a different engine (Settings › Advanced).", "Ask the sender to recreate it as ZIP or 7z."]
        case .safetyLimitExceeded:
            return ["Only raise limits for archives from a source you trust."]
        case .insufficientSpace:
            return ["Free up disk space or choose a destination on another disk."]
        case .permissionDenied:
            return ["Choose a different destination, or grant access in System Settings › Privacy & Security."]
        case .notEditable:
            return ["Convert the archive to ZIP or 7z, then edit the converted copy."]
        default:
            return []
        }
    }

    /// A stable machine-readable code (used by the CLI's JSON output and exit codes).
    public var code: String {
        switch self {
        case .fileNotFound: return "file-not-found"
        case .notAnArchive: return "not-an-archive"
        case .unsupportedFormat: return "unsupported-format"
        case .noEngineAvailable: return "no-engine"
        case .engineUnavailable: return "engine-unavailable"
        case .operationNotSupported: return "operation-not-supported"
        case .passwordRequired: return "password-required"
        case .incorrectPassword: return "incorrect-password"
        case .unsupportedEncryption: return "unsupported-encryption"
        case .authenticationFailed: return "authentication-failed"
        case .unsupportedMethod: return "unsupported-method"
        case .damaged: return "damaged"
        case .checksumMismatch: return "checksum-mismatch"
        case .missingVolume: return "missing-volume"
        case .truncated: return "truncated"
        case .safetyLimitExceeded: return "safety-limit"
        case .unsafePath: return "unsafe-path"
        case .destinationExists: return "destination-exists"
        case .insufficientSpace: return "insufficient-space"
        case .permissionDenied: return "permission-denied"
        case .io: return "io-error"
        case .externalTool: return "external-tool"
        case .cancelled: return "cancelled"
        case .invalidArgument: return "invalid-argument"
        case .verificationFailed: return "verification-failed"
        case .notEditable: return "not-editable"
        case .internalError: return "internal"
        }
    }

    private static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func fmt(_ kind: SafetyLimitKind, _ v: UInt64) -> String {
        switch kind {
        case .totalSize, .entrySize, .diskReserve: return ByteFormatting.string(v)
        case .expansionRatio: return "\(v):1"
        case .duration: return "\(v) s"
        default: return "\(v)"
        }
    }

    /// Map an arbitrary error into an ArchiveError.
    public static func wrap(_ error: Error) -> ArchiveError {
        if let e = error as? ArchiveError { return e }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            if ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError {
                return .fileNotFound(path: (ns.userInfo[NSFilePathErrorKey] as? String) ?? "")
            }
            if ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError {
                return .permissionDenied(path: (ns.userInfo[NSFilePathErrorKey] as? String) ?? "")
            }
            if ns.code == NSFileWriteOutOfSpaceError { return .insufficientSpace(needed: 0, available: 0) }
        }
        return .internalError(ns.localizedDescription)
    }
}

extension ArchiveError: LocalizedError {
    public var errorDescription: String? { explanation }
    public var failureReason: String? { title }
    public var recoverySuggestion: String? { suggestions.isEmpty ? nil : suggestions.joined(separator: " ") }
}

/// Byte formatting that works identically on every platform (ByteCountFormatter is not available everywhere).
public enum ByteFormatting {
    public static func string(_ bytes: UInt64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        if bytes < 1000 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let s = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(s) \(units[unit])"
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        return string(UInt64(bytesPerSecond)) + "/s"
    }

    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
