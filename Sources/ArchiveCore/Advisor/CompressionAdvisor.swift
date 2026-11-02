import Foundation
import CZlib

/// Measures how well a sample compresses with a given method. Implemented by engines so estimates
/// come from the real algorithm, not from assumptions.
public protocol SampleCompressor {
    /// Returns the compressed size of `data`, or nil if the method is unavailable.
    func compressedSize(of data: Data, method: CompressionMethod, level: Int) -> Int?
}

/// zlib-based measurement; always available.
public struct DeflateSampleCompressor: SampleCompressor {
    public init() {}
    public func compressedSize(of data: Data, method: CompressionMethod, level: Int) -> Int? {
        guard method == .deflate || method == .zlib else { return nil }
        var destLen = compressBound(uLong(data.count))
        var dest = [UInt8](repeating: 0, count: Int(destLen))
        let rc = data.withUnsafeBytes { src in
            compress2(&dest, &destLen, src.baseAddress!.assumingMemoryBound(to: Bytef.self), uLong(data.count), Int32(level))
        }
        return rc == Z_OK ? Int(destLen) : nil
    }
}

/// A bounded, measured description of the content to be compressed.
public struct ContentProfile: Sendable, Codable {
    public var totalBytes: UInt64
    public var fileCount: Int
    public var bytesByKind: [FileKind: UInt64]
    public var alreadyCompressedBytes: UInt64
    public var sampledBytes: Int
    /// Measured compressed size of the sample, per method.
    public var sampleCompressed: [String: Int]
    /// Wall-clock seconds per method for the sample (for time estimates).
    public var sampleSeconds: [String: Double]

    public var dominantKind: FileKind? {
        bytesByKind.max { $0.value < $1.value }?.key
    }

    public var alreadyCompressedFraction: Double {
        totalBytes == 0 ? 0 : Double(alreadyCompressedBytes) / Double(totalBytes)
    }

    public func measuredRatio(_ method: CompressionMethod) -> Double? {
        guard sampledBytes > 0, let c = sampleCompressed[method.rawValue] else { return nil }
        return Double(c) / Double(sampledBytes)
    }
}

public struct Recommendation: Sendable {
    public struct Option: Sendable {
        public var title: String
        public var explanation: String
        public var settings: CompressionSettings
        /// Estimated output size; an estimate extrapolated from a measured sample.
        public var estimatedBytes: UInt64?
        /// Estimated processing time in seconds (single-threaded sample rate; real runs may be faster).
        public var estimatedSeconds: Double?
    }

    public var primary: Option
    public var alternatives: [Option]
    /// What the estimate is based on (shown next to the numbers).
    public var basis: String
}

public enum AdvisorIntent: String, Codable, Sendable, CaseIterable {
    case general
    case shareWithWindows
    case smallestSize
    case fastest
    case macArchival
}

/// Offline compression advisor: classifies content, compresses a bounded sample with the candidate
/// algorithms, and recommends a format with an explanation. No network access, no ML model.
public enum CompressionAdvisor {
    public static func profile(_ collection: SourceCollection, sampleBudget: Int = 8 << 20, perFileSample: Int = 128 << 10,
                               compressor: SampleCompressor = DeflateSampleCompressor(),
                               methods: [CompressionMethod] = [.deflate]) -> ContentProfile {
        var byKind: [FileKind: UInt64] = [:]
        var compressed: UInt64 = 0
        var files = collection.items.filter { $0.type == .file }
        for f in files {
            let ext = (f.archivePath as NSString).pathExtension
            byKind[FileClassifier.kind(forExtension: ext), default: 0] += f.size
            if FileClassifier.isTypicallyCompressed(ext) { compressed += f.size }
        }
        // Sample evenly across files, weighting toward larger files, within the budget.
        files.sort { $0.size > $1.size }
        var sample = Data()
        let stride = max(1, files.count / 256)
        var i = 0
        while i < files.count, sample.count < sampleBudget {
            let f = files[i]
            if let fh = FileHandle(forReadingAtPath: f.url.path) {
                let want = min(perFileSample, sampleBudget - sample.count)
                // Read from the middle of large files to avoid header-only bias.
                if f.size > UInt64(want * 4) { try? fh.seekChecked(to: f.size / 2, path: f.url.path) }
                if let d = try? fh.readChunk(upTo: want, path: f.url.path) { sample.append(d) }
                try? fh.close()
            }
            i += stride
        }
        var results: [String: Int] = [:]
        var seconds: [String: Double] = [:]
        if !sample.isEmpty {
            for m in methods {
                let t0 = Date()
                if let c = compressor.compressedSize(of: sample, method: m, level: 6) {
                    results[m.rawValue] = c
                    seconds[m.rawValue] = Date().timeIntervalSince(t0)
                }
            }
        }
        return ContentProfile(totalBytes: collection.totalBytes, fileCount: collection.fileCount, bytesByKind: byKind,
                              alreadyCompressedBytes: compressed, sampledBytes: sample.count,
                              sampleCompressed: results, sampleSeconds: seconds)
    }

    public static func recommend(_ p: ContentProfile, intent: AdvisorIntent = .general) -> Recommendation {
        func estimate(_ m: CompressionMethod) -> (UInt64?, Double?) {
            guard let r = p.measuredRatio(m) else { return (nil, nil) }
            let size = UInt64(Double(p.totalBytes) * r)
            var secs: Double?
            if let s = p.sampleSeconds[m.rawValue], p.sampledBytes > 0 {
                secs = s * Double(p.totalBytes) / Double(p.sampledBytes)
            }
            return (size, secs)
        }
        func option(_ title: String, _ why: String, _ settings: CompressionSettings, _ m: CompressionMethod) -> Recommendation.Option {
            let (b, s) = estimate(m)
            return .init(title: title, explanation: why, settings: settings, estimatedBytes: b, estimatedSeconds: s)
        }

        let zip = CompressionSettings(format: .zip, method: .deflate, level: 6)
        let zipStore = CompressionSettings(format: .zip, method: .store, level: 0)
        let sevenZ = CompressionSettings(format: .sevenZip, method: .lzma2, level: 7, solid: .on)
        let zstd = CompressionSettings(format: .tarZstd, method: .zstd, level: 3)
        let macTar = CompressionSettings(format: .tarXz, method: .xz, level: 6, metadata: .macPreservation)

        let incompressible = p.alreadyCompressedFraction > 0.8 || (p.measuredRatio(.deflate).map { $0 > 0.95 } ?? false)
        let kind = p.dominantKind
        let texty = kind == .text || kind == .sourceCode || kind == .database

        var primary: Recommendation.Option
        var alts: [Recommendation.Option] = []

        switch intent {
        case .shareWithWindows:
            primary = option("ZIP", "Opens with the built-in tools on Windows, macOS and Linux.", incompressible ? zipStore : zip, incompressible ? .store : .deflate)
        case .fastest:
            primary = option("Zstandard (tar.zst)", "Very fast compression and extraction with a good ratio; best for large datasets moving between Macs and Linux.", zstd, .zstd)
            alts.append(option("ZIP (store)", "No compression at all: as fast as copying.", zipStore, .store))
        case .macArchival:
            primary = option("TAR + XZ (Mac Preservation)", "Keeps extended attributes, permissions and symbolic links for restoring on a Mac.", macTar, .xz)
        case .smallestSize:
            primary = option("7z — Smallest", "LZMA2 with a solid block usually gives the smallest files, at the cost of time.", sevenZ, .lzma2)
        case .general:
            if incompressible {
                primary = option("ZIP — Store", "Most of this content (photos, video, audio or archives) is already compressed. Storing it without recompression is much faster and the file would barely shrink.", zipStore, .store)
            } else if texty {
                primary = option("7z — Balanced", "Your selection is mostly \(kind == .sourceCode ? "source code" : "text and documents"). 7z typically compresses this considerably better than ZIP, but takes longer.", sevenZ, .lzma2)
                alts.append(option("ZIP", "Need maximum compatibility? Use ZIP instead.", zip, .deflate))
            } else {
                primary = option("ZIP — Balanced", "A good balance of size and speed that anyone can open.", zip, .deflate)
                alts.append(option("7z", "Smaller files, slower to create; recipients need a 7z-capable app.", sevenZ, .lzma2))
            }
            alts.append(option("Zstandard", "Need faster processing? Try Zstandard.", zstd, .zstd))
        }
        if intent != .shareWithWindows, primary.settings.format != .zip {
            alts.append(option("ZIP", "Need maximum compatibility? Use ZIP instead.", zip, .deflate))
        }
        // De-duplicate alternatives by title.
        var seen = Set<String>([primary.title])
        alts = alts.filter { seen.insert($0.title).inserted }

        let basis = p.sampledBytes > 0
            ? "Estimates extrapolated from compressing a \(ByteFormatting.string(UInt64(p.sampledBytes))) sample of your files. Actual results will differ."
            : "No sample could be read; no size estimate is available."
        return Recommendation(primary: primary, alternatives: alts, basis: basis)
    }
}
