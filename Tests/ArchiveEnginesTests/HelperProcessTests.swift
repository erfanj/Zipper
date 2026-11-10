import XCTest
import Foundation
import ArchiveCore
@testable import ArchiveEngines

/// Helper programs (7-Zip, lsar/unar, zpaq…) read files someone else made. A damaged or hostile
/// archive can make one ask for all the memory there is (lsar grew to 13 GB on a fuzzed 7z) or
/// loop for ever (unar does on a fuzzed .xz). Zipper stops such a helper. Most of these tests use
/// a script interpreter as the "helper"; the last one uses the real tools and the real file.
final class HelperLimitTests: XCTestCase {
    /// Present on every Mac and every Linux machine.
    static let perl: URL? = ["/usr/bin/perl", "/bin/perl"].map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    func perl() throws -> URL {
        guard let perl = Self.perl else { throw XCTSkip("perl isn't installed") }
        return perl
    }

    func testAHelperThatAsksForTooMuchMemoryIsStopped() throws {
        // Holds about 400 MB, then would sit there for a minute.
        let helper = HelperProcess(try perl(), ["-e", "my $x = 'a' x (400 * 1024 * 1024); sleep 60;"])
        helper.memoryLimit = 150 << 20
        let started = Date()
        XCTAssertThrowsError(try helper.run()) { error in
            guard case .safetyLimitExceeded(.helperMemory, let limit, let observed)? = error as? ArchiveError else {
                return XCTFail("expected the memory limit, got \(error)")
            }
            XCTAssertEqual(limit, 150 << 20)
            XCTAssertGreaterThan(observed, limit)
            XCTAssertTrue((error as? ArchiveError)?.explanation.contains("more memory") == true)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "stopped promptly, not after the helper's minute")
    }

    func testAHelperWithinItsLimitIsLeftAlone() throws {
        let helper = HelperProcess(try perl(), ["-e", "my $x = 'a' x (20 * 1024 * 1024); select(undef, undef, undef, 1.5); print 'done';"])
        helper.memoryLimit = 600 << 20
        let result = try helper.run()
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "done")
    }

    func testWithoutALimitNothingIsWatched() throws {
        // What creating an archive uses: the memory follows from the user's own settings.
        let helper = HelperProcess(try perl(), ["-e", "my $x = 'a' x (200 * 1024 * 1024); select(undef, undef, undef, 1.0); print length($x);"])
        helper.memoryLimit = nil
        let result = try helper.run()
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "\(200 * 1024 * 1024)")
    }

    func testPausingAndResumingDoesNotDisarmTheGuard() throws {
        // A paused helper is suspended (SIGSTOP). Once resumed it grows, and is stopped like any other.
        // (The size is a variable so that perl builds the string when it runs, not while compiling.)
        let progress = OperationProgress()
        let helper = HelperProcess(try perl(), ["-e", "select(undef, undef, undef, 0.5); my $n = 400 * 1024 * 1024; my $x = 'a' x $n; sleep 60;"])
        helper.memoryLimit = 150 << 20
        helper.progress = progress
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { progress.pause() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { progress.resume() }
        let started = Date()
        XCTAssertThrowsError(try helper.run()) { error in
            guard case .safetyLimitExceeded(.helperMemory, _, _)? = error as? ArchiveError else {
                return XCTFail("expected the memory limit, got \(error)")
            }
        }
        let took = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(took, 1.4, "it can't have grown while it was paused")
        XCTAssertLessThan(took, 30)
    }

    // MARK: Time

    func testAHelperThatNeverFinishesIsStopped() throws {
        let helper = HelperProcess(try perl(), ["-e", "while (1) { }"])
        helper.timeLimit = 1.5
        let started = Date()
        XCTAssertThrowsError(try helper.run()) { error in
            guard case .safetyLimitExceeded(.helperTime, let limit, _)? = error as? ArchiveError else {
                return XCTFail("expected the time limit, got \(error)")
            }
            XCTAssertEqual(limit, 2, "1.5 s, rounded for the message")
            XCTAssertTrue((error as? ArchiveError)?.explanation.contains("stopped after 2 seconds") == true, "\((error as? ArchiveError)?.explanation ?? "")")
        }
        let took = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(took, 1.4)
        XCTAssertLessThan(took, 15)
    }

    func testTimeSpentPausedDoesNotCount() throws {
        let progress = OperationProgress()
        let helper = HelperProcess(try perl(), ["-e", "while (1) { }"])
        helper.timeLimit = 1.5
        helper.progress = progress
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { progress.pause() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.3) { progress.resume() }
        let started = Date()
        XCTAssertThrowsError(try helper.run()) { error in
            guard case .safetyLimitExceeded(.helperTime, _, _)? = error as? ArchiveError else { return XCTFail("\(error)") }
        }
        let took = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(took, 4.0, "0.3 s running, 3 s paused, then the remaining 1.2 s")
        XCTAssertLessThan(took, 20)
    }

    func testAHelperThatFinishesInTimeIsLeftAlone() throws {
        let helper = HelperProcess(try perl(), ["-e", "select(undef, undef, undef, 0.8); print 'done';"])
        helper.timeLimit = 30
        let result = try helper.run()
        XCTAssertEqual(result.stdout, "done")
        XCTAssertNil(HelperProcess(try perl(), []).timeLimit, "no time limit unless a tool is known to need one")
    }

    /// A 3 KB damaged .xz, found by fuzzing: The Unarchiver's tools decode it for ever (all of one
    /// processor, no output, no memory growth). With them installed, testing and extracting it
    /// through that engine must end; here with a 2-second allowance instead of two minutes.
    func testADamagedArchiveCannotKeepTheUnarchiverBusyForEver() throws {
        let engine = UnarEngine(baseTimeLimit: 2)
        guard engine.descriptor.isAvailable else { throw XCTSkip("unar and lsar aren't installed") }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Malicious/helper-spin.xz")
        let source = ArchiveSource(url: fixture, format: .xz)
        XCTAssertEqual(engine.timeLimit(for: source), 2.09, accuracy: 0.02, "two seconds, plus half a minute per megabyte of a 3 KB file")
        XCTAssertEqual(UnarEngine().timeLimit(for: source), 120.09, accuracy: 0.02)

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ua-spin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let started = Date()
        do {
            let report = try engine.test(source, options: ReadOptions(), progress: OperationProgress())
            XCTAssertFalse(report.issues.isEmpty, "a damaged stream can't test as sound")
        } catch let error as ArchiveError {
            // This version of the tools loops; another may report the damage itself.
            if case .safetyLimitExceeded(let kind, _, _) = error { XCTAssertEqual(kind, .helperTime) }
        }
        XCTAssertThrowsError(try engine.extract(source, selection: .all, into: try SafeExtractionSink(destination: work.appendingPathComponent("out")),
                                                options: ReadOptions(), progress: OperationProgress()))
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "the helper was left running")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        XCTAssertTrue(left.allSatisfy { $0 == "out" }, "staging folders are removed: \(left)")
    }

    func testCancellingStopsAHelperThatIsOnlyListing() throws {
        let progress = OperationProgress()
        let helper = HelperProcess(try perl(), ["-e", "sleep 60;"])
        helper.progress = progress
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { progress.cancel() }
        let started = Date()
        XCTAssertThrowsError(try helper.run()) { error in
            guard case .cancelled? = error as? ArchiveError else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testMemoryIsMeasuredInBytesBothWays() throws {
        let own = ProcessInfo.processInfo.processIdentifier
        let direct = try XCTUnwrap(HelperProcess.residentMemory(of: own))
        XCTAssertGreaterThan(direct, 4 << 20, "a test process holds more than 4 MB")
        XCTAssertLessThan(direct, ProcessInfo.processInfo.physicalMemory)
        guard let fromPS = HelperProcess.residentMemoryFromPS(own) else { throw XCTSkip("/bin/ps isn't available") }
        XCTAssertLessThan(abs(Double(direct) - Double(fromPS)) / Double(direct), 0.3, "\(direct) against \(fromPS) from ps")
        XCTAssertNil(HelperProcess.residentMemoryFromPS(0x3FFF_FFF0), "no such process")
    }

    func testTheDefaultLimitLeavesRoomForRealArchives() {
        // The largest dictionaries in use are 1.5 GB (7z) and 1 GB (RAR 5).
        XCTAssertGreaterThanOrEqual(HelperProcess.defaultMemoryLimit, 2 << 30)
        XCTAssertLessThanOrEqual(HelperProcess.defaultMemoryLimit, max(2 << 30, ProcessInfo.processInfo.physicalMemory / 2))
        XCTAssertEqual(HelperProcess(URL(fileURLWithPath: "/bin/sh"), []).memoryLimit, HelperProcess.defaultMemoryLimit)
    }
}
