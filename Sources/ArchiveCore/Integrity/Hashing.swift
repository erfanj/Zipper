import Foundation
import CZlib
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Supported checksum algorithms.
public enum HashAlgorithm: String, Codable, Sendable, CaseIterable {
    case sha256
    case sha512
    case sha384
    case crc32
    case sha1
    case md5

    public var displayName: String {
        switch self {
        case .sha256: return "SHA-256"
        case .sha384: return "SHA-384"
        case .sha512: return "SHA-512"
        case .crc32: return "CRC-32"
        case .sha1: return "SHA-1 (legacy)"
        case .md5: return "MD5 (legacy)"
        }
    }

    /// Whether the algorithm resists deliberate collisions. CRC-32 detects accidental corruption
    /// only; MD5 and SHA-1 are broken and offered for comparison with old manifests.
    public var isCollisionResistant: Bool {
        switch self {
        case .sha256, .sha384, .sha512: return true
        case .crc32, .sha1, .md5: return false
        }
    }

    public var note: String? {
        switch self {
        case .crc32: return "Detects accidental corruption only; not a security check."
        case .md5, .sha1: return "Cryptographically broken. Use only to compare with existing legacy checksums."
        default: return nil
        }
    }

    /// Conventional manifest file extension (sha256sum style).
    public var manifestExtension: String {
        switch self {
        case .crc32: return "sfv"
        default: return rawValue
        }
    }

    public var hexLength: Int {
        switch self {
        case .crc32: return 8
        case .md5: return 32
        case .sha1: return 40
        case .sha256: return 64
        case .sha384: return 96
        case .sha512: return 128
        }
    }
}

/// Incremental hasher over any supported algorithm.
public final class StreamingHasher {
    private enum State {
        case sha256(SHA256)
        case sha384(SHA384)
        case sha512(SHA512)
        case sha1(Insecure.SHA1)
        case md5(Insecure.MD5)
        case crc(UInt)
    }

    public let algorithm: HashAlgorithm
    private var state: State

    public init(_ algorithm: HashAlgorithm) {
        self.algorithm = algorithm
        switch algorithm {
        case .sha256: state = .sha256(SHA256())
        case .sha384: state = .sha384(SHA384())
        case .sha512: state = .sha512(SHA512())
        case .sha1: state = .sha1(Insecure.SHA1())
        case .md5: state = .md5(Insecure.MD5())
        case .crc32: state = .crc(0)
        }
    }

    public func update(_ buffer: UnsafeRawBufferPointer) {
        guard buffer.count > 0 else { return }
        switch state {
        case .sha256(var h): h.update(bufferPointer: buffer); state = .sha256(h)
        case .sha384(var h): h.update(bufferPointer: buffer); state = .sha384(h)
        case .sha512(var h): h.update(bufferPointer: buffer); state = .sha512(h)
        case .sha1(var h): h.update(bufferPointer: buffer); state = .sha1(h)
        case .md5(var h): h.update(bufferPointer: buffer); state = .md5(h)
        case .crc(let c): state = .crc(CRC32.update(c, buffer))
        }
    }

    public func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    public func finalizeHex() -> String {
        switch state {
        case .sha256(let h): return Self.hex(h.finalize())
        case .sha384(let h): return Self.hex(h.finalize())
        case .sha512(let h): return Self.hex(h.finalize())
        case .sha1(let h): return Self.hex(h.finalize())
        case .md5(let h): return Self.hex(h.finalize())
        case .crc(let c): return String(format: "%08x", UInt32(truncatingIfNeeded: c))
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes a file using bounded memory.
    public static func hashFile(at url: URL, algorithm: HashAlgorithm, progress: OperationProgress? = nil) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw FileManager.default.fileExists(atPath: url.path) ? ArchiveError.permissionDenied(path: url.path) : ArchiveError.fileNotFound(path: url.path)
        }
        defer { try? handle.close() }
        let hasher = StreamingHasher(algorithm)
        while true {
            try progress?.checkCancelled()
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(chunk)
            progress?.add(processed: UInt64(chunk.count))
        }
        return hasher.finalizeHex()
    }
}

/// CRC-32 (ISO-HDLC, as used by ZIP/gzip) via zlib, which is SIMD-accelerated on Apple Silicon.
public enum CRC32 {
    public static func update(_ crc: UInt, _ buffer: UnsafeRawBufferPointer) -> UInt {
        var c = crc
        var offset = 0
        while offset < buffer.count {
            let n = min(buffer.count - offset, Int(UInt32.max))
            c = UInt(crc32(uLong(c), buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Bytef.self), uInt(n)))
            offset += n
        }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(truncatingIfNeeded: update(0, $0)) }
    }
}
