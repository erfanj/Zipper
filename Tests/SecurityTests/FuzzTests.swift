import XCTest
import ArchiveCore
import ArchiveEngines
@testable import ArchiverKit
import UATestSupport

/// Mutation fuzzing: corrupt valid archives (bit flips, byte overwrites, truncation, splicing) and
/// open/test/extract them. The engine must report an error or succeed — never crash, hang or write
/// outside the destination. Iterations are deterministic (seeded) so failures reproduce.
final class FuzzTests: XCTestCase {
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    func testMutatedArchivesNeverCrashOrEscape() throws {
        let iterations = Int(ProcessInfo.processInfo.environment["UA_FUZZ_ITERATIONS"] ?? "60") ?? 60
        let service = ArchiveService()
        let work = TestFS.tempDir("fuzz")
        defer { try? FileManager.default.removeItem(at: work) }
        let tree = TestFS.sampleTree(in: work.appendingPathComponent("src"))
        var formats: [FormatID] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd, .tarLz4, .tarBrotli, .cpio, .gzip]
        if service.registry.engine(.sevenZip)?.descriptor.isAvailable == true { formats.append(.sevenZip) }
        var originals: [(FormatID, Data, String)] = []
        for f in formats {
            let items = f == .gzip ? [tree.appendingPathComponent("readme.txt")] : [tree]
            let o = try service.compress(CompressRequest(items: items, destinationDirectory: work, archiveName: "orig-\(f.rawValue.replacingOccurrences(of: ".", with: "_"))",
                                                         settings: CompressionSettings(format: f, level: 1)))
            let url = o.archives[0].outputs[0]
            originals.append((f, try Data(contentsOf: url), ArchiveService.fileExtension(for: f)))
            try FileManager.default.removeItem(at: url)
        }
        var rng = SplitMix64(state: 0x5EED)
        var outcomes: [String: Int] = [:]
        for i in 0..<iterations {
            for (format, original, ext) in originals {
                var d = original
                switch rng.next() % 5 {
                case 0: for _ in 0..<(1 + Int(rng.next() % 8)) { let p = Int(rng.next() % UInt64(d.count)); d[p] ^= UInt8(1 << (rng.next() % 8)) }
                case 1: let p = Int(rng.next() % UInt64(d.count)); d = d.prefix(p)
                case 2: let p = Int(rng.next() % UInt64(max(1, d.count - 16))); for k in 0..<16 where p + k < d.count { d[p + k] = UInt8(truncatingIfNeeded: rng.next()) }
                case 3: // header region damage
                    for _ in 0..<4 { let p = Int(rng.next() % UInt64(min(d.count, 600))); d[p] = UInt8(truncatingIfNeeded: rng.next()) }
                default: // tail (directory) damage
                    for _ in 0..<4 { let p = d.count - 1 - Int(rng.next() % UInt64(min(d.count, 300))); d[p] = UInt8(truncatingIfNeeded: rng.next()) }
                }
                let case_ = work.appendingPathComponent("case-\(i)-\(format.rawValue.replacingOccurrences(of: ".", with: "_"))")
                try FileManager.default.createDirectory(at: case_, withIntermediateDirectories: true)
                let file = case_.appendingPathComponent("m.\(ext)")
                try d.write(to: file)
                let dest = case_.appendingPathComponent("dest")
                var opts = ExtractionOptions()
                opts.limits.maxTotalBytes = 50_000_000
                opts.limits.maxEntryBytes = 20_000_000
                var result = "ok"
                do { _ = try service.test(file) } catch { result = "test-error" }
                do {
                    _ = try service.extract(ExtractRequest(archive: file, destination: dest, mode: .here, options: opts))
                } catch let e as ArchiveError {
                    result = e.code
                    XCTAssertNotEqual(e.code, "internal", "\(format) iteration \(i): \(e)")
                }
                outcomes[result, default: 0] += 1
                let siblings = try FileManager.default.contentsOfDirectory(atPath: case_.path).filter { $0 != "m.\(ext)" && $0 != "dest" }
                XCTAssertTrue(siblings.isEmpty, "\(format) iteration \(i) wrote outside dest: \(siblings)")
                try FileManager.default.removeItem(at: case_)
            }
        }
        print("Fuzz outcomes (\(iterations) iterations × \(originals.count) formats): \(outcomes.sorted { $0.key < $1.key })")
    }
}
