import Foundation

/// A password held in memory. The buffer is zeroed when the last reference goes away.
///
/// Swift strings cannot be reliably wiped, so passwords are kept as bytes wherever possible and only
/// converted at the boundary of an API that requires a C string.
public final class Secret: @unchecked Sendable, Equatable {
    private var storage: [UInt8]

    public init(_ string: String) { storage = Array(string.utf8) }
    public init(bytes: [UInt8]) { storage = bytes }

    deinit {
        storage.withUnsafeMutableBufferPointer { buf in
            for i in buf.indices { buf[i] = 0 }
        }
    }

    public var isEmpty: Bool { storage.isEmpty }
    public var byteCount: Int { storage.count }

    /// Calls `body` with a NUL-terminated copy that is wiped afterwards.
    public func withCString<R>(_ body: (UnsafePointer<CChar>) throws -> R) rethrows -> R {
        var tmp = storage.map { CChar(bitPattern: $0) }
        tmp.append(0)
        defer { tmp.withUnsafeMutableBufferPointer { b in for i in b.indices { b[i] = 0 } } }
        return try tmp.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }

    public func withBytes<R>(_ body: ([UInt8]) throws -> R) rethrows -> R { try body(storage) }

    /// Only for APIs that require a String (avoid where possible).
    public var unsafeStringValue: String { String(decoding: storage, as: UTF8.self) }

    public static func == (lhs: Secret, rhs: Secret) -> Bool {
        guard lhs.storage.count == rhs.storage.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.storage.count { diff |= lhs.storage[i] ^ rhs.storage[i] }
        return diff == 0
    }
}

/// Why a password is being requested.
public enum PasswordRequestReason: Sendable, Equatable {
    case required
    case previousAttemptIncorrect
}

/// Supplies passwords on demand. Implementations may prompt the user, read the Keychain or return a
/// value given on the command line (via stdin). Returning nil aborts the operation.
public protocol PasswordProvider: AnyObject, Sendable {
    func password(for archive: URL, reason: PasswordRequestReason) -> Secret?
}

/// A provider that always returns the same password (or none).
public final class FixedPasswordProvider: PasswordProvider, @unchecked Sendable {
    private let secret: Secret?
    private var used = 0
    private let lock = NSLock()
    /// How many times the same password may be offered (re-offering a wrong password is pointless).
    public let maxAttempts: Int

    public init(_ secret: Secret?, maxAttempts: Int = 1) {
        self.secret = secret
        self.maxAttempts = maxAttempts
    }

    public convenience init(_ string: String?) { self.init(string.map(Secret.init)) }

    public func password(for archive: URL, reason: PasswordRequestReason) -> Secret? {
        lock.lock(); defer { lock.unlock() }
        guard used < maxAttempts else { return nil }
        used += 1
        return secret
    }
}

/// Caches the password that worked for a multipart set or a batch so the user is asked once.
public final class CachingPasswordProvider: PasswordProvider, @unchecked Sendable {
    private let upstream: PasswordProvider
    private let lock = NSLock()
    private var cache: [String: Secret] = [:]
    private var lastGood: Secret?

    public init(upstream: PasswordProvider) { self.upstream = upstream }

    public func password(for archive: URL, reason: PasswordRequestReason) -> Secret? {
        let key = MultipartDetector.setKey(for: archive)
        lock.lock()
        if reason == .required, let s = cache[key] ?? lastGood {
            lock.unlock()
            return s
        }
        lock.unlock()
        let s = upstream.password(for: archive, reason: reason)
        if let s {
            lock.lock(); cache[key] = s; lock.unlock()
        }
        return s
    }

    /// Record that a password was accepted, so related archives try it first.
    public func confirm(_ secret: Secret, for archive: URL) {
        lock.lock()
        cache[MultipartDetector.setKey(for: archive)] = secret
        lastGood = secret
        lock.unlock()
    }
}
