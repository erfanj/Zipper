import Foundation
import ArchiveCore
import ArchiveEngines
#if canImport(Security)
import Security
#endif

// MARK: - Activity history

/// Local log of operations. Stores only what is needed to review or repeat an operation: the
/// operation type, archive and destination paths, timing and outcome — never archive contents,
/// file listings or passwords.
public struct HistoryRecord: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case compress, extract, convert, test, repair, modify, split, join, checksum, compare }
    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var inputs: [String]
    public var output: String?
    public var succeeded: Bool
    public var summary: String
    public var duration: TimeInterval
    /// Settings needed to repeat the operation (no secrets).
    public var settings: CompressionSettings?

    public init(kind: Kind, inputs: [String], output: String?, succeeded: Bool, summary: String, duration: TimeInterval, settings: CompressionSettings? = nil) {
        id = UUID()
        date = Date()
        self.kind = kind
        self.inputs = inputs
        self.output = output
        self.succeeded = succeeded
        self.summary = summary
        self.duration = duration
        self.settings = settings
    }
}

public final class ActivityHistory: @unchecked Sendable {
    public let fileURL: URL
    public var isEnabled: Bool
    public var maxRecords = 1000
    private let lock = NSLock()

    public init(fileURL: URL, isEnabled: Bool = true) {
        self.fileURL = fileURL
        self.isEnabled = isEnabled
    }

    public func add(_ r: HistoryRecord) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        var all = loadUnlocked()
        all.insert(r, at: 0)
        if all.count > maxRecords { all.removeLast(all.count - maxRecords) }
        saveUnlocked(all)
    }

    public func all() -> [HistoryRecord] {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked()
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        saveUnlocked(loadUnlocked().filter { $0.id != id })
    }

    private func loadUnlocked() -> [HistoryRecord] {
        guard let d = try? Data(contentsOf: fileURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([HistoryRecord].self, from: d)) ?? []
    }

    private func saveUnlocked(_ all: [HistoryRecord]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? enc.encode(all) {
            try? d.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}

// MARK: - Performance

public enum PerformanceMode: String, Codable, Sendable, CaseIterable {
    case maximum
    case balanced
    case energySaver

    public var displayName: String {
        switch self {
        case .maximum: return "Maximum Performance"
        case .balanced: return "Balanced"
        case .energySaver: return "Energy Saver"
        }
    }

    public var qos: DispatchQoS.QoSClass {
        switch self {
        case .maximum: return .userInitiated
        case .balanced: return .utility
        case .energySaver: return .background
        }
    }
}

/// Facts about the machine relevant to scheduling. Uses only public APIs; on Apple Silicon the
/// performance/efficiency core split comes from `hw.perflevel*` sysctls.
public struct SystemProfile: Sendable {
    public var logicalCores: Int
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    public var physicalMemory: UInt64
    public var isLowPowerMode: Bool
    public var thermalState: ThermalLevel

    public enum ThermalLevel: Int, Sendable { case nominal, fair, serious, critical }

    public static func current() -> SystemProfile {
        let p = ProcessInfo.processInfo
        var perf: Int?, eff: Int?
        #if os(macOS)
        func sysctlInt(_ name: String) -> Int? {
            var v: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        }
        perf = sysctlInt("hw.perflevel0.physicalcpu")
        eff = sysctlInt("hw.perflevel1.physicalcpu")
        let lowPower = p.isLowPowerModeEnabled
        let thermal: ThermalLevel
        switch p.thermalState {
        case .critical: thermal = .critical
        case .serious: thermal = .serious
        case .fair: thermal = .fair
        default: thermal = .nominal
        }
        #else
        let lowPower = false
        let thermal = ThermalLevel.nominal
        #endif
        return SystemProfile(logicalCores: p.activeProcessorCount, performanceCores: perf, efficiencyCores: eff,
                             physicalMemory: p.physicalMemory, isLowPowerMode: lowPower, thermalState: thermal)
    }

    /// Mode actually used: thermal pressure and Low Power Mode downgrade the requested mode.
    public func effectiveMode(_ requested: PerformanceMode) -> PerformanceMode {
        if thermalState == .critical || isLowPowerMode { return .energySaver }
        if thermalState == .serious, requested == .maximum { return .balanced }
        return requested
    }

    /// Worker threads for compression engines.
    public func threads(for requested: PerformanceMode) -> Int {
        switch effectiveMode(requested) {
        case .maximum: return max(1, logicalCores)
        case .balanced: return max(1, performanceCores ?? max(1, logicalCores - 1))
        case .energySaver: return max(1, min(2, efficiencyCores ?? 2))
        }
    }

    /// How many operations the queue runs at once.
    public func concurrentOperations(for requested: PerformanceMode) -> Int {
        switch effectiveMode(requested) {
        case .maximum: return max(2, min(4, logicalCores / 4))
        case .balanced: return 2
        case .energySaver: return 1
        }
    }
}

// MARK: - Operation queue

public final class QueuedOperation: @unchecked Sendable, Identifiable {
    public enum State: String, Sendable { case queued, running, paused, succeeded, failed, cancelled }
    public let id = UUID()
    public let title: String
    public let kind: HistoryRecord.Kind
    public let progress = OperationProgress()
    public let createdAt = Date()
    fileprivate let work: (OperationProgress) throws -> String
    private let lock = NSLock()
    private var _state: State = .queued
    private var _error: ArchiveError?
    private var _summary: String?
    public var onChange: (@Sendable (QueuedOperation) -> Void)?

    init(title: String, kind: HistoryRecord.Kind, work: @escaping (OperationProgress) throws -> String) {
        self.title = title
        self.kind = kind
        self.work = work
    }

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    public var error: ArchiveError? { lock.lock(); defer { lock.unlock() }; return _error }
    public var summary: String? { lock.lock(); defer { lock.unlock() }; return _summary }

    func set(_ s: State, error: ArchiveError? = nil, summary: String? = nil) {
        lock.lock()
        _state = s
        if let error { _error = error }
        if let summary { _summary = summary }
        lock.unlock()
        onChange?(self)
    }

    public func cancel() {
        progress.cancel()
        if state == .queued { set(.cancelled) }
    }

    public func pause() {
        guard state == .running else { return }
        progress.pause()
        set(.paused)
    }

    public func resume() {
        guard state == .paused else { return }
        progress.resume()
        set(.running)
    }
}

/// Runs archive operations in the background with a concurrency limit derived from the
/// performance mode. Operations keep running when windows close (as long as the app runs).
public final class OperationCenter: @unchecked Sendable {
    public private(set) var operations: [QueuedOperation] = []
    public var mode: PerformanceMode = .balanced
    public var history: ActivityHistory?
    public var onChange: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var running = 0

    public init(mode: PerformanceMode = .balanced, history: ActivityHistory? = nil) {
        self.mode = mode
        self.history = history
    }

    @discardableResult
    public func enqueue(_ title: String, kind: HistoryRecord.Kind, inputs: [String] = [], work: @escaping (OperationProgress) throws -> String) -> QueuedOperation {
        let op = QueuedOperation(title: title, kind: kind, work: work)
        op.onChange = { [weak self] _ in self?.onChange?() }
        lock.lock(); operations.append(op); lock.unlock()
        onChange?()
        pump(inputs: [op.id: inputs])
        return op
    }

    private var pendingInputs: [UUID: [String]] = [:]

    private func pump(inputs: [UUID: [String]] = [:]) {
        lock.lock()
        pendingInputs.merge(inputs) { a, _ in a }
        let limit = SystemProfile.current().concurrentOperations(for: mode)
        var toStart: [QueuedOperation] = []
        for op in operations where op.state == .queued && running + toStart.count < limit {
            toStart.append(op)
        }
        running += toStart.count
        lock.unlock()
        for op in toStart {
            op.set(.running)
            let ins = pendingInputs[op.id] ?? []
            DispatchQueue.global(qos: mode.qos).async { [weak self] in
                let start = Date()
                do {
                    let summary = try op.work(op.progress)
                    op.set(.succeeded, summary: summary)
                    self?.history?.add(HistoryRecord(kind: op.kind, inputs: ins, output: nil, succeeded: true, summary: summary, duration: Date().timeIntervalSince(start)))
                } catch {
                    let e = ArchiveError.wrap(error)
                    if case .cancelled = e { op.set(.cancelled) } else { op.set(.failed, error: e) }
                    self?.history?.add(HistoryRecord(kind: op.kind, inputs: ins, output: nil, succeeded: false, summary: e.title, duration: Date().timeIntervalSince(start)))
                }
                self?.lock.lock()
                self?.running -= 1
                self?.lock.unlock()
                self?.pump()
                self?.onChange?()
            }
        }
    }

    public var active: [QueuedOperation] { operations.filter { [.queued, .running, .paused].contains($0.state) } }
    public var finished: [QueuedOperation] { operations.filter { ![.queued, .running, .paused].contains($0.state) } }

    public func clearFinished() {
        lock.lock(); operations.removeAll { ![.queued, .running, .paused].contains($0.state) }; lock.unlock()
        onChange?()
    }

    /// Overall fraction for Dock / menu bar indicators.
    public var overallFraction: Double? {
        let act = active.compactMap { $0.progress.snapshot.fraction }
        guard !act.isEmpty else { return nil }
        return act.reduce(0, +) / Double(act.count)
    }
}

// MARK: - Passwords

/// Stores archive passwords. The macOS implementation uses the Keychain; nothing is ever written
/// to preference files.
public protocol PasswordStore: AnyObject, Sendable {
    func save(_ secret: Secret, for archiveKey: String, label: String, requireAuthentication: Bool) throws
    func password(for archiveKey: String, prompt: String?) -> Secret?
    func delete(_ archiveKey: String) throws
    func allKeys() -> [(key: String, label: String)]
}

/// Key used to associate a password with an archive: the multipart set (so all volumes share it).
public func passwordKey(for archive: URL) -> String {
    MultipartDetector.setKey(for: archive)
}

public final class InMemoryPasswordStore: PasswordStore, @unchecked Sendable {
    private var store: [String: (Secret, String)] = [:]
    private let lock = NSLock()
    public init() {}
    public func save(_ secret: Secret, for archiveKey: String, label: String, requireAuthentication: Bool) throws {
        lock.lock(); store[archiveKey] = (secret, label); lock.unlock()
    }
    public func password(for archiveKey: String, prompt: String?) -> Secret? {
        lock.lock(); defer { lock.unlock() }
        return store[archiveKey]?.0
    }
    public func delete(_ archiveKey: String) throws { lock.lock(); store[archiveKey] = nil; lock.unlock() }
    public func allKeys() -> [(key: String, label: String)] {
        lock.lock(); defer { lock.unlock() }
        return store.map { ($0.key, $0.value.1) }.sorted { $0.label < $1.label }
    }
}

#if os(macOS)
/// Keychain-backed store (generic passwords in the login keychain, this app only).
public final class KeychainPasswordStore: PasswordStore, @unchecked Sendable {
    public let service: String

    public init(service: String = "\(ProductInfo.bundleIdentifier).archive-passwords") { self.service = service }

    public func save(_ secret: Secret, for archiveKey: String, label: String, requireAuthentication: Bool) throws {
        try? delete(archiveKey)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: archiveKey,
            kSecAttrLabel as String: "\(ProductInfo.name): \(label)",
            kSecValueData as String: secret.withBytes { Data($0) },
        ]
        if requireAuthentication {
            var err: Unmanaged<CFError>?
            if let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &err) {
                query[kSecAttrAccessControl as String] = ac
            }
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ArchiveError.internalError("Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "")")
        }
    }

    public func password(for archiveKey: String, prompt: String?) -> Secret? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: archiveKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let prompt { query[kSecUseOperationPrompt as String] = prompt }
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return Secret(bytes: [UInt8](data))
    }

    public func delete(_ archiveKey: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: archiveKey]
        let s = SecItemDelete(query as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw ArchiveError.internalError("Keychain error \(s)") }
    }

    public func allKeys() -> [(key: String, label: String)] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { i in
            guard let acct = i[kSecAttrAccount as String] as? String else { return nil }
            return (acct, (i[kSecAttrLabel as String] as? String) ?? acct)
        }
    }
}
#endif

/// Password provider that consults a store first, then an interactive prompt.
public final class StoredPasswordProvider: PasswordProvider, @unchecked Sendable {
    let store: PasswordStore?
    let prompt: (URL, PasswordRequestReason) -> Secret?
    public init(store: PasswordStore?, prompt: @escaping (URL, PasswordRequestReason) -> Secret?) {
        self.store = store
        self.prompt = prompt
    }
    public func password(for archive: URL, reason: PasswordRequestReason) -> Secret? {
        if reason == .required, let s = store?.password(for: passwordKey(for: archive), prompt: "open “\(archive.lastPathComponent)”") { return s }
        return prompt(archive, reason)
    }
}

public enum PasswordGenerator {
    public static let symbols = Array("!#$%&*+-=?@^_~")
    static let ambiguous = Set("Il1O0o")

    /// Generates a password using the system CSPRNG (`SystemRandomNumberGenerator` reads from the
    /// kernel's cryptographically secure source on every supported platform).
    public static func generate(length: Int = 20, uppercase: Bool = true, digits: Bool = true, symbols useSymbols: Bool = true,
                                avoidAmbiguous: Bool = true) -> String {
        var pools: [[Character]] = [Array("abcdefghijklmnopqrstuvwxyz")]
        if uppercase { pools.append(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")) }
        if digits { pools.append(Array("0123456789")) }
        if useSymbols { pools.append(symbols) }
        if avoidAmbiguous { pools = pools.map { $0.filter { !ambiguous.contains($0) } } }
        let all = pools.flatMap { $0 }
        var rng = SystemRandomNumberGenerator()
        let n = max(length, pools.count)
        var chars = pools.map { $0.randomElement(using: &rng)! } // at least one of each class
        while chars.count < n { chars.append(all.randomElement(using: &rng)!) }
        chars.shuffle(using: &rng)
        return String(chars)
    }

    /// Diceware-style passphrase from a built-in word list.
    public static func passphrase(words: Int = 6, separator: String = "-") -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<max(4, words)).map { _ in PasswordStrength.wordList.randomElement(using: &rng)! }.joined(separator: separator)
    }
}

public struct PasswordStrength: Sendable {
    public enum Rating: Int, Sendable, Comparable {
        case veryWeak, weak, fair, strong, veryStrong
        public static func < (a: Rating, b: Rating) -> Bool { a.rawValue < b.rawValue }
        public var label: String { ["Very weak", "Weak", "Fair", "Strong", "Very strong"][rawValue] }
    }
    public var bits: Double
    public var rating: Rating
    public var feedback: [String]

    static let common: Set<String> = ["password", "123456", "12345678", "qwerty", "abc123", "111111", "123123", "letmein", "welcome",
                                      "monkey", "dragon", "iloveyou", "admin", "passw0rd", "password1", "1234567890", "sunshine",
                                      "princess", "football", "baseball", "master", "shadow", "superman", "trustno1", "000000"]
    static let wordList = ["acorn", "amber", "anchor", "apple", "arrow", "aspen", "atlas", "autumn", "badge", "bamboo", "banjo", "basil",
                           "beacon", "birch", "bison", "blaze", "bloom", "breeze", "brick", "bronze", "cactus", "camel", "candle", "canyon",
                           "cedar", "chalk", "cherry", "cinder", "citrus", "clover", "cobalt", "comet", "copper", "coral", "cosmos", "crane",
                           "crystal", "dahlia", "delta", "denim", "dolphin", "dune", "eagle", "ember", "falcon", "fern", "fjord", "flint",
                           "forest", "fossil", "galaxy", "garnet", "glacier", "granite", "harbor", "hazel", "heron", "honey", "horizon",
                           "indigo", "iris", "island", "ivory", "jade", "jasmine", "jungle", "kayak", "kelp", "kiwi", "lagoon", "lantern",
                           "lava", "lemon", "lilac", "linen", "lotus", "lunar", "magnet", "maple", "marble", "meadow", "meteor", "mint",
                           "mosaic", "nectar", "nebula", "nickel", "nutmeg", "oasis", "ocean", "olive", "onyx", "orbit", "orchid", "otter",
                           "paddle", "panda", "pebble", "pepper", "pine", "planet", "plume", "polar", "prism", "quartz", "quill", "radar",
                           "raven", "reef", "ripple", "river", "rocket", "saffron", "sage", "salmon", "sapphire", "satin", "shell", "sierra",
                           "silver", "solar", "spruce", "summit", "swan", "tango", "thistle", "thunder", "tiger", "topaz", "tulip", "tundra",
                           "velvet", "violet", "walnut", "willow", "zephyr", "zinnia"]

    public static func evaluate(_ password: String) -> PasswordStrength {
        var feedback: [String] = []
        let chars = Array(password)
        var pool = 0
        if chars.contains(where: { $0.isLowercase }) { pool += 26 }
        if chars.contains(where: { $0.isUppercase }) { pool += 26 }
        if chars.contains(where: { $0.isNumber }) { pool += 10 }
        if chars.contains(where: { !$0.isLetter && !$0.isNumber && $0.isASCII }) { pool += 33 }
        if chars.contains(where: { !$0.isASCII }) { pool += 100 }
        var bits = chars.isEmpty || pool == 0 ? 0 : Double(chars.count) * log2(Double(pool))
        // Penalise repetition and common patterns.
        let distinct = Set(chars).count
        if chars.count > 0, distinct * 2 < chars.count { bits *= 0.6; feedback.append("Avoid repeated characters.") }
        let lower = password.lowercased()
        if common.contains(lower) || common.contains(where: { lower.contains($0) && $0.count >= 6 }) {
            bits = min(bits, 10); feedback.append("This is a commonly used password.")
        }
        if lower.range(of: #"(0123|1234|2345|3456|4567|5678|6789|abcd|bcde|qwer|asdf|zxcv)"#, options: .regularExpression) != nil {
            bits *= 0.8; feedback.append("Avoid keyboard and number sequences.")
        }
        if chars.count < 12 { feedback.append("Use at least 12 characters.") }
        let rating: Rating = bits < 28 ? .veryWeak : bits < 40 ? .weak : bits < 60 ? .fair : bits < 90 ? .strong : .veryStrong
        return PasswordStrength(bits: bits, rating: rating, feedback: feedback)
    }
}

// MARK: - Product info (rename the product here)

public enum ProductInfo {
    /// Working name. Change here (and in Info.plist / project.yml) before release.
    public static let name = "Universal Archiver"
    public static let bundleIdentifier = "com.example.universalarchiver"
    public static let cliName = "archiver"
    public static let version = "0.1.0"

    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent(name, isDirectory: true)
    }
}

// MARK: - Diagnostics

/// Diagnostic log with redaction: file names and paths are replaced by stable placeholders unless
/// the user explicitly includes them when exporting.
public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog()
    public var isEnabled = false
    private var lines: [String] = []
    private let lock = NSLock()

    public func log(_ message: String, paths: [String] = []) {
        guard isEnabled else { return }
        var m = message
        for p in paths { m = m.replacingOccurrences(of: p, with: Self.redact(p)) }
        lock.lock()
        lines.append("\(ISO8601DateFormatter().string(from: Date())) \(m)")
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
        lock.unlock()
    }

    static func redact(_ path: String) -> String {
        let h = StreamingHasher(.sha256)
        h.update(Data(path.utf8))
        let ext = (path as NSString).pathExtension
        return "<path-\(h.finalizeHex().prefix(8))\(ext.isEmpty ? "" : "." + ext)>"
    }

    public func export() -> String {
        lock.lock(); defer { lock.unlock() }
        let p = SystemProfile.current()
        var header = ["\(ProductInfo.name) \(ProductInfo.version) diagnostics",
                      "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                      "Cores: \(p.logicalCores) (P: \(p.performanceCores.map(String.init) ?? "?"), E: \(p.efficiencyCores.map(String.init) ?? "?"))",
                      "Memory: \(ByteFormatting.string(p.physicalMemory))", ""]
        header += lines
        return header.joined(separator: "\n")
    }
}

// MARK: - Analysis & search

public struct ArchiveAnalysis: Sendable {
    public var largestFiles: [ArchiveEntry]
    /// Uncompressed bytes per file kind.
    public var bytesByKind: [(kind: FileKind, bytes: UInt64, count: Int)]
    public var directorySizes: [(path: String, bytes: UInt64)]
    /// Files that barely compressed (ratio ≥ 0.9), when compressed sizes are known.
    public var poorlyCompressed: [ArchiveEntry]
    public var overallRatio: Double?

    public init(listing: ArchiveListing, top: Int = 20) {
        let files = listing.entries.filter { $0.type == .file }
        largestFiles = Array(files.sorted { ($0.uncompressedSize ?? 0) > ($1.uncompressedSize ?? 0) }.prefix(top))
        var kinds: [FileKind: (UInt64, Int)] = [:]
        var dirs: [String: UInt64] = [:]
        for f in files {
            let k = FileClassifier.kind(forExtension: f.fileExtension)
            let s = f.uncompressedSize ?? 0
            kinds[k, default: (0, 0)].0 += s
            kinds[k, default: (0, 0)].1 += 1
            let top = f.normalizedPath.split(separator: "/").dropLast().first.map(String.init) ?? "(top level)"
            dirs[top, default: 0] += s
        }
        bytesByKind = kinds.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.bytes > $1.bytes }
        directorySizes = dirs.map { ($0.key, $0.value) }.sorted { $0.bytes > $1.bytes }
        poorlyCompressed = files.filter { ($0.compressionRatio ?? 0) >= 0.9 && ($0.uncompressedSize ?? 0) > 4096 }
            .sorted { ($0.uncompressedSize ?? 0) > ($1.uncompressedSize ?? 0) }
        if let u = listing.totalUncompressedSize, let c = listing.totalCompressedSize, u > 0 { overallRatio = Double(c) / Double(u) }
    }
}

public struct EntrySearch: Sendable {
    public var text: String = ""
    public var extensions: [String] = []
    public var kind: FileKind?
    public var folder: String?
    public var minSize: UInt64?
    public var maxSize: UInt64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var encryptedOnly: Bool = false

    public init(text: String = "") { self.text = text }

    public func matches(_ e: ArchiveEntry) -> Bool {
        if !text.isEmpty, e.normalizedPath.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
        if !extensions.isEmpty, !extensions.map({ $0.lowercased() }).contains(e.fileExtension) { return false }
        if let k = kind, FileClassifier.kind(forExtension: e.fileExtension) != k { return false }
        if let f = folder, !(e.parentPath == f || e.parentPath.hasPrefix(f + "/")) { return false }
        if let m = minSize, (e.uncompressedSize ?? 0) < m { return false }
        if let m = maxSize, (e.uncompressedSize ?? .max) > m { return false }
        if let d = modifiedAfter, (e.modificationDate ?? .distantPast) < d { return false }
        if let d = modifiedBefore, (e.modificationDate ?? .distantFuture) > d { return false }
        if encryptedOnly, !e.isEncrypted { return false }
        return true
    }
}

/// Searches inside text entries (bounded: per-file and total byte budgets). Only runs when asked.
final class ContentSearchSink: ExtractionSink {
    let needle: [UInt8]
    let perFileLimit: Int
    var budget: Int
    var matches: [String] = []
    init(needle: String, perFileLimit: Int = 4 << 20, totalBudget: Int = 512 << 20) {
        self.needle = Array(needle.lowercased().utf8)
        self.perFileLimit = perFileLimit
        budget = totalBudget
    }
    func begin(_ entry: ArchiveEntry, extras: EntryExtras) throws -> EntryDataWriter? {
        guard entry.type == .file, budget > 0 else { return nil }
        let k = FileClassifier.kind(forExtension: entry.fileExtension)
        guard k == .text || k == .sourceCode else { return nil }
        return W(self, entry.normalizedPath)
    }
    func finish() throws {}
    final class W: EntryDataWriter {
        unowned let s: ContentSearchSink
        let path: String
        var window: [UInt8] = []
        var seen = 0
        var found = false
        init(_ s: ContentSearchSink, _ p: String) { self.s = s; path = p }
        func write(_ bytes: UnsafeRawBufferPointer) throws {
            guard !found, seen < s.perFileLimit else { return }
            let take = min(bytes.count, s.perFileLimit - seen)
            seen += take
            s.budget -= take
            window += bytes.prefix(take).map { ($0 >= 65 && $0 <= 90) ? $0 + 32 : $0 }
            if window.count >= s.needle.count, contains(window, s.needle) { found = true }
            // Keep an overlap so matches spanning two blocks are found.
            if window.count > s.needle.count { window = Array(window.suffix(max(0, s.needle.count - 1))) }
        }
        private func contains(_ h: [UInt8], _ n: [UInt8]) -> Bool {
            guard !n.isEmpty, h.count >= n.count else { return n.isEmpty }
            for i in 0...(h.count - n.count) where h[i] == n[0] && Array(h[i..<(i + n.count)]) == n { return true }
            return false
        }
        func commit() throws { if found { s.matches.append(path) } }
        func abort() {}
    }
}

extension ArchiveService {
    /// Finds text entries containing `text` (case-insensitive ASCII), within resource limits.
    public func searchContents(_ url: URL, text: String, options: ReadOptions = ReadOptions(), progress: OperationProgress = OperationProgress()) throws -> [String] {
        let opened = try open(url, options: options, progress: progress)
        let sink = ContentSearchSink(needle: text)
        var notes: [String] = []
        _ = try withEngines(for: opened.detection.format, EngineRequirements(operations: .extract), notes: &notes) {
            try $0.extract(opened.source, selection: .all, into: sink, options: options, progress: progress)
        }
        return sink.matches
    }

    /// Extracts one entry into a private, per-session temporary folder for previewing. Never runs anything.
    public func extractForPreview(_ url: URL, entryPath: String, maxBytes: UInt64 = 512_000_000, options: ReadOptions = ReadOptions()) throws -> URL {
        let dir = PreviewCache.shared.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var opts = ExtractionOptions(linkPolicy: .skip, restoreExtendedAttributes: false, skipAppleDoubleArtifacts: false)
        opts.limits.maxTotalBytes = maxBytes
        opts.limits.maxEntryBytes = maxBytes
        let o = try extract(ExtractRequest(archive: url, destination: dir, mode: .here, selection: .paths([ArchivePath.normalizeForDisplay(entryPath)]),
                                           options: opts, readOptions: options))
        guard let rel = o.report.writtenFiles.first else { throw ArchiveError.invalidArgument("“\(entryPath)” has no previewable data.") }
        let file = dir.appendingPathComponent(rel)
        // Previews are read-only and never executable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        return file
    }
}

/// Owns the preview temp folder and removes it on exit.
public final class PreviewCache: @unchecked Sendable {
    public static let shared = PreviewCache()
    public let directory: URL
    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ua-preview-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func clear() {
        // Restore write permission so read-only previews can be deleted.
        if let en = FileManager.default.enumerator(atPath: directory.path) {
            while let rel = en.nextObject() as? String {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent(rel).path)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
