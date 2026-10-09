import Foundation

/// Resource limits applied to every extraction of untrusted archives.
///
/// The defaults are intended to stop decompression bombs and runaway archives while allowing
/// legitimate very large archives. Users can raise them deliberately for trusted files.
public struct SafetyLimits: Codable, Hashable, Sendable {
    public var maxTotalBytes: UInt64
    public var maxEntryCount: Int
    public var maxEntryBytes: UInt64
    /// Maximum output/input ratio. Only enforced once output exceeds `ratioGraceBytes`.
    public var maxExpansionRatio: UInt64
    public var ratioGraceBytes: UInt64
    public var maxNestingDepth: Int
    /// Wall-clock limit in seconds (nil = unlimited).
    public var maxDuration: TimeInterval?
    /// Extraction stops before free space on the destination volume drops below this.
    public var minimumFreeSpace: UInt64

    public init(maxTotalBytes: UInt64 = 500 * 1_000_000_000,
                maxEntryCount: Int = 2_000_000,
                maxEntryBytes: UInt64 = 256 * 1_000_000_000,
                maxExpansionRatio: UInt64 = 10_000,
                ratioGraceBytes: UInt64 = 1_000_000_000,
                maxNestingDepth: Int = 3,
                maxDuration: TimeInterval? = nil,
                minimumFreeSpace: UInt64 = 512 * 1_000_000) {
        self.maxTotalBytes = maxTotalBytes
        self.maxEntryCount = maxEntryCount
        self.maxEntryBytes = maxEntryBytes
        self.maxExpansionRatio = maxExpansionRatio
        self.ratioGraceBytes = ratioGraceBytes
        self.maxNestingDepth = maxNestingDepth
        self.maxDuration = maxDuration
        self.minimumFreeSpace = minimumFreeSpace
    }

    public static let `default` = SafetyLimits()

    /// For archives the user has explicitly marked as trusted. Disk-space protection remains.
    public static let trusted = SafetyLimits(maxTotalBytes: .max, maxEntryCount: .max, maxEntryBytes: .max,
                                             maxExpansionRatio: .max, ratioGraceBytes: .max, maxNestingDepth: 16,
                                             maxDuration: nil, minimumFreeSpace: 256 * 1_000_000)
}
