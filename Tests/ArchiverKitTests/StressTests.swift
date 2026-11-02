import XCTest
import ArchiveCore
import ArchiveEngines
@testable import ArchiverKit
import UATestSupport

/// Acceptance tests 16 and 17, plus stress cases from the specification. Heavier variants are
/// enabled with UA_RUN_LARGE_TESTS=1.
final class StressTests: XCTestCase {
    let service = ArchiveService()
    var work: URL!
    override func setUp() { work = TestFS.tempDir("stress") }
    override func tearDown() { try? FileManager.default.removeItem(at: work) }

    var large: Bool { ProcessInfo.processInfo.environment["UA_RUN_LARGE_TESTS"] == "1" }

    func randomFile(_ name: String, bytes: Int) -> URL {
        let url = work.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try! FileHandle(forWritingTo: url)
        let random = FileHandle(forReadingAtPath: "/dev/urandom")!
        var left = bytes
        while left > 0 {
            let n = min(left, 4 << 20)
            fh.write(random.readData(ofLength: n))
            left -= n
        }
        try! fh.close()
        try? random.close()
        return url
    }

    /// Acceptance test 17: cancelling never leaves a corrupt "finished" output behind.
    func testCancelledCompressionLeavesNoOutput() throws {
        let src = work.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        _ = randomFile("src/a.bin", bytes: 64 << 20)
        _ = randomFile("src/b.bin", bytes: 64 << 20)
        let out = work.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // tar.xz at level 9 uses one 192 MB block: without a cancellable encoder, all of the work
        // would happen inside archive_write_close and a cancel would wait for it (~100 s here).
        for format in [FormatID.zip, .tarXz, .tarZstd, .tarBzip2] {
            for delay in [0.3, 1.5] {
                let p = OperationProgress()
                let cancelledAt = LockedBox<Date?>(nil)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { cancelledAt.value = Date(); p.cancel() }
                XCTAssertThrowsError(try service.compress(CompressRequest(items: [src], destinationDirectory: out, settings: CompressionSettings(format: format, level: 9)), progress: p)) {
                    XCTAssertEqual($0 as? ArchiveError, .cancelled, "\(format): \($0)")
                }
                if let t = cancelledAt.value {
                    XCTAssertLessThan(Date().timeIntervalSince(t), 5, "\(format) after \(delay) s: cancellation must take effect promptly")
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "\(format): no partial or temporary files")
            }
        }
    }

    func testCancelledExtractionLeavesNoPartialOutput() throws {
        let src = work.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<6 { _ = randomFile("src/f\(i).bin", bytes: 24 << 20) }
        let zip = try service.compress(CompressRequest(items: [src], destinationDirectory: work, settings: CompressionSettings(format: .tarXz, level: 0))).archives[0].outputs[0]
        let dest = work.appendingPathComponent("dest")
        let p = OperationProgress()
        p.throttle = 0
        // Cancel deterministically once part of the data has been written.
        p.observe { s in if s.outputBytes > 30 << 20 { p.cancel() } }
        XCTAssertThrowsError(try service.extract(ExtractRequest(archive: zip, destination: dest, mode: .smart), progress: p)) {
            XCTAssertEqual($0 as? ArchiveError, .cancelled, "\($0)")
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? [], [], "smart/new-folder extraction is all-or-nothing")
    }

    func testPauseAndResumeCompletesCorrectly() throws {
        let f = randomFile("p.bin", bytes: 48 << 20)
        let p = OperationProgress()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { p.pause() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
            XCTAssertTrue(p.isPaused)
            p.resume()
        }
        let o = try service.compress(CompressRequest(items: [f], destinationDirectory: work, settings: CompressionSettings(format: .zip, level: 1), verifyAfterCreation: true), progress: p)
        XCTAssertEqual(o.archives[0].verification?.result, .passed)
    }

    func testLowDiskSpaceStopsBeforeFillingTheDisk() throws {
        let f = TestFS.write(work, "a.txt", String(repeating: "x", count: 10_000))
        let zip = try service.compress(CompressRequest(items: [f], destinationDirectory: work, settings: CompressionSettings(format: .zip))).archives[0].outputs[0]
        var opts = ExtractionOptions()
        opts.limits.minimumFreeSpace = .max / 2 // simulate a nearly full disk
        let dest = work.appendingPathComponent("dest")
        XCTAssertThrowsError(try service.extract(ExtractRequest(archive: zip, destination: dest, options: opts))) {
            XCTAssertEqual(($0 as? ArchiveError)?.code, "insufficient-space", "\($0)")
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dest.path))?.filter { !$0.hasPrefix(".") } ?? [], [])
    }

    func testManySmallFiles() throws {
        let count = large ? 200_000 : 20_000
        let src = work.appendingPathComponent("many")
        for d in 0..<(count / 1000) {
            let dir = src.appendingPathComponent("d\(d)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<1000 { FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(i).txt").path, contents: Data("\(d)-\(i)".utf8)) }
        }
        let t0 = Date()
        let zip = try service.compress(CompressRequest(items: [src], destinationDirectory: work, settings: CompressionSettings(format: .zip, level: 1))).archives[0].outputs[0]
        let t1 = Date()
        let listing = try service.open(zip).listing
        XCTAssertEqual(listing.fileCount, count)
        let o = try service.extract(ExtractRequest(archive: zip, destination: work.appendingPathComponent("x")))
        XCTAssertEqual(o.report.filesWritten, count)
        print("many small files: \(count) files compressed in \(String(format: "%.1f", t1.timeIntervalSince(t0))) s, extracted in \(String(format: "%.1f", Date().timeIntervalSince(t1))) s")
    }

    func testDeepDirectoriesAndLongNames() throws {
        // As deep as the platform allows: 40 levels on Linux (PATH_MAX 4096). macOS caps paths at 1024
        // bytes, which leaves room for about a dozen levels plus the long file name and extraction's
        // staging folder.
        #if os(macOS)
        let pathMax = 1024
        #else
        let pathMax = 4096
        #endif
        let levels = min(40, (pathMax - work.path.utf8.count - 400) / 52)
        var dir = work.appendingPathComponent("deep")
        for i in 0..<levels { dir = dir.appendingPathComponent("level-\(i)-" + String(repeating: "d", count: 40)) }
        let longName = String(repeating: "长", count: 80) + ".txt" // 244 bytes in UTF-8
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: dir.appendingPathComponent(longName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(longName).path))
        let c = try SourceCollector.collect([work.appendingPathComponent("deep")], settings: CompressionSettings())
        XCTAssertEqual(c.fileCount, 1, "collected: \(c.items.count) items, unreadable \(c.unreadable.map { $0.utf8.count }), excluded \(c.excluded)")
        for format in [FormatID.zip, .tarGzip] {
            let a = try service.compress(CompressRequest(items: [work.appendingPathComponent("deep")], destinationDirectory: work, settings: CompressionSettings(format: format))).archives[0].outputs[0]
            let dest = work.appendingPathComponent("x-\(format.rawValue)")
            let listing = try service.open(a).listing
            XCTAssertEqual(listing.fileCount, 1, "\(format): \(listing.entries.map(\.path).suffix(2))")
            let o = try service.extract(ExtractRequest(archive: a, destination: dest, verifyAfterExtraction: true))
            XCTAssertEqual(o.report.filesWritten, 1, "\(format): \(o.report)")
            XCTAssertEqual(o.verification?.passed, true)
        }
    }

    /// Acceptance test 16: memory stays bounded while extracting an archive much larger than the
    /// buffers used. Measured as the growth of resident memory during the operation.
    func testStreamingKeepsMemoryBounded() throws {
        let size = large ? 2_000 << 20 : 300 << 20
        let f = randomFile("big.bin", bytes: size)
        let a = try service.compress(CompressRequest(items: [f], destinationDirectory: work, settings: CompressionSettings(format: .tarZstd, level: 1))).archives[0].outputs[0]
        try FileManager.default.removeItem(at: f)
        let before = residentMemory()
        // The sampler owns `peak` until it has stopped (`stopped`), so reading it isn't a data race.
        final class Peak: @unchecked Sendable { var value: UInt64 = 0 }
        let peakBox = Peak()
        peakBox.value = before
        let done = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while done.wait(timeout: .now() + 0.05) == .timedOut { peakBox.value = max(peakBox.value, residentMemory()) }
            stopped.signal()
        }
        _ = try service.extract(ExtractRequest(archive: a, destination: work.appendingPathComponent("x")))
        done.signal()
        stopped.wait()
        let peak = peakBox.value
        let growth = peak > before ? peak - before : 0
        print("streaming extraction of \(size >> 20) MB: resident memory grew by \(growth >> 20) MB")
        XCTAssertLessThan(growth, 150 << 20, "extraction must stream, not buffer the archive")
    }
}

func residentMemory() -> UInt64 {
    #if os(Linux)
    guard let s = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8), let pages = s.split(separator: " ").dropFirst().first.flatMap({ UInt64($0) }) else { return 0 }
    return pages * 4096
    #else
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    #endif
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
