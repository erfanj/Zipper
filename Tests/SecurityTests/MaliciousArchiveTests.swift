import XCTest
import ArchiveCore
import ArchiveEngines
@testable import ArchiverKit
import UATestSupport

/// Acceptance test 15 and the specification's security test list. Every archive here is hostile;
/// the assertions check that nothing is written outside the chosen destination, that limits stop
/// resource exhaustion without leaving partial output, and that failures are reported, not crashes.
final class MaliciousArchiveTests: XCTestCase {
    static let fixtures: URL = {
        let here = URL(fileURLWithPath: #filePath)
        let dir = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Malicious")
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("zip-slip.zip").path) {
            let script = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/make-malicious-fixtures.py")
            _ = try? TestFS.run("/usr/bin/python3", ["-I", script.path, dir.path])
        }
        return dir
    }()

    var sandbox: URL!
    var dest: URL!
    let service = ArchiveService()

    override func setUp() {
        sandbox = TestFS.tempDir("sec")
        dest = sandbox.appendingPathComponent("dest")
        for f in ["/tmp/ua-escaped-absolute.txt", "/tmp/ua-escaped-tar-abs.txt", "/tmp/ua-through-link.txt"] { try? FileManager.default.removeItem(atPath: f) }
    }
    override func tearDown() { try? FileManager.default.removeItem(at: sandbox) }

    func fixture(_ name: String) -> URL { Self.fixtures.appendingPathComponent(name) }

    /// Nothing may appear next to `dest`, in /tmp under known names, or anywhere above.
    func assertContained(file: StaticString = #filePath, line: UInt = #line) {
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.path)) ?? []
        XCTAssertTrue(siblings.filter { !$0.hasPrefix(".ua-") }.allSatisfy { $0 == "dest" }, "something was written outside the destination: \(siblings)", file: file, line: line)
        XCTAssertTrue(siblings.filter { $0.hasPrefix(".ua-") }.isEmpty, "staging folders must be cleaned up: \(siblings)", file: file, line: line)
        for f in ["/tmp/ua-escaped-absolute.txt", "/tmp/ua-escaped-tar-abs.txt", "/tmp/ua-through-link.txt", "/tmp/ua-zip-through-link.txt"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: f), "\(f) escaped", file: file, line: line)
        }
        let parentFiles = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.deletingLastPathComponent().path)) ?? []
        XCTAssertFalse(parentFiles.contains { $0.hasPrefix("escaped") }, file: file, line: line)
    }

    func extract(_ name: String, options: ExtractionOptions = ExtractionOptions(), mode: ExtractionMode = .here) throws -> ExtractionOutcome {
        try service.extract(ExtractRequest(archive: fixture(name), destination: dest, mode: mode, options: options))
    }

    func testZipSlip() throws {
        let o = try extract("zip-slip.zip")
        assertContained()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("good.txt").path))
        // Traversal entries are blocked; the absolute one is made relative inside dest.
        XCTAssertGreaterThanOrEqual(o.report.blocked.count, 3, "\(o.report.blocked)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("tmp/ua-escaped-absolute.txt").path))
    }

    func testTarSlip() throws {
        let o = try extract("tar-slip.tar")
        assertContained()
        XCTAssertEqual(o.report.blocked.count, 2, "\(o.report.blocked)")
    }

    func testSymlinkEscape() throws {
        let o = try extract("symlink-escape.tar")
        assertContained()
        // Escaping links are refused; writes "through" them are blocked; the safe internal link exists.
        XCTAssertTrue(o.report.blocked.contains { $0.path == "evil-link" })
        XCTAssertTrue(o.report.blocked.contains { $0.path == "rel-link" })
        let safe = try FileManager.default.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("safe-link").path)
        XCTAssertEqual(safe, "target.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/ua-through-link.txt"))
    }

    func testSymlinkEscapeEvenWhenLinksTrusted() throws {
        // With links allowed, the escaping link is created, but writing through it is still impossible
        // because every path component is opened with O_NOFOLLOW.
        var opts = ExtractionOptions()
        opts.linkPolicy = .preserveAll
        let o = try extract("symlink-escape.tar", options: opts)
        assertContained()
        XCTAssertTrue(o.report.blocked.contains { $0.path.hasPrefix("evil-link/") }, "\(o.report.blocked)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/ua-through-link.txt"))
    }

    func testZipSymlinkThroughLink() throws {
        _ = try extract("zip-symlink.zip")
        assertContained()
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/etc/ua-zip-through-link.txt"))
    }

    func testHardlinkEscape() throws {
        let o = try extract("hardlink-escape.tar")
        assertContained()
        XCTAssertEqual(o.report.blocked.count, 2, "\(o.report.blocked)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("passwd-link").path))
    }

    func testSpecialFilesAndSetuid() throws {
        let o = try extract("special-files.tar")
        assertContained()
        XCTAssertEqual(o.report.skipped.filter { $0.reason.contains("device") }.count, 2)
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent("suid-script.sh").path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o7000, 0, "set-user-ID bit must be stripped")
        XCTAssertTrue(o.report.potentiallyExecutable.contains("suid-script.sh"))
    }

    func testDecompressionBombStopsAtLimitWithoutPartialOutput() throws {
        var opts = ExtractionOptions()
        opts.limits.maxTotalBytes = 200_000_000
        let start = Date()
        XCTAssertThrowsError(try extract("bomb.tar.gz", options: opts, mode: .smart)) { err in
            guard case .safetyLimitExceeded(.totalSize, _, _)? = err as? ArchiveError else { return XCTFail("\(err)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
        assertContained()
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dest.path))?.count ?? 0, 0, "no partial output remains")
    }

    func testExpansionRatioLimit() throws {
        var opts = ExtractionOptions()
        opts.limits.maxExpansionRatio = 100
        opts.limits.ratioGraceBytes = 10_000_000
        XCTAssertThrowsError(try extract("bomb.tar.gz", options: opts)) { err in
            guard case .safetyLimitExceeded(.expansionRatio, _, _)? = err as? ArchiveError else { return XCTFail("\(err)") }
        }
        assertContained()
    }

    func testLyingSizeIsBounded() throws {
        var opts = ExtractionOptions()
        opts.limits.maxEntryBytes = 1_000_000
        do {
            _ = try extract("lying-size.zip", options: opts)
        } catch let e as ArchiveError {
            // Either the limit or a size/CRC mismatch stops it — never a 50 MB file.
            XCTAssertTrue(["safety-limit", "damaged", "checksum-mismatch", "truncated"].contains(e.code), "\(e)")
        }
        assertContained()
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent("liar.bin").path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThanOrEqual(size, 1_000_000)
    }

    func testEntryCountLimit() throws {
        var opts = ExtractionOptions()
        opts.limits.maxEntryCount = 1000
        XCTAssertThrowsError(try extract("many-entries.zip", options: opts, mode: .smart)) {
            guard case .safetyLimitExceeded(.entryCount, _, _)? = $0 as? ArchiveError else { return XCTFail("\($0)") }
        }
        assertContained()
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dest.path))?.count ?? 0, 0)
    }

    func testMalformedInputsFailCleanly() throws {
        for name in ["malformed.zip", "malformed.7z", "malformed.tar.gz", "truncated.tar.xz", "huge-declared.tar", "bad-encryption.zip"] {
            do {
                _ = try service.open(fixture(name))
                _ = try extract(name)
            } catch let e as ArchiveError {
                XCTAssertFalse(e.explanation.isEmpty, name)
                XCTAssertNotEqual(e.code, "internal", "\(name): \(e)")
            }
            assertContained()
        }
    }

    func testDeepNestingIsBounded() throws {
        var opts = ExtractionOptions()
        opts.limits.maxNestingDepth = 3
        let o = try service.extract(ExtractRequest(archive: fixture("nested-deep.zip"), destination: dest, options: opts, extractNestedArchives: true))
        var depth = 0
        var cur: ExtractionOutcome? = o
        while let c = cur, let next = c.nested.first { depth += 1; cur = next }
        XCTAssertEqual(depth, 3)
        assertContained()
    }

    func testDuplicateNamesNeverOverwriteSilently() throws {
        let o = try extract("duplicates.zip")
        let names = try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
        XCTAssertEqual(names, ["same 2.txt", "same.txt"])
        XCTAssertEqual(o.report.renamed.count, 1)
    }

    func testDestinationSymlinkPlantedBeforeExtraction() throws {
        // A pre-existing symlink inside the destination must not redirect writes either.
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let outside = sandbox.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dest.appendingPathComponent("dir"), withDestinationURL: outside)
        let src = sandbox.appendingPathComponent("src/dir")
        TestFS.write(src, "payload.txt", "x")
        let zip = try service.compress(CompressRequest(items: [src], destinationDirectory: sandbox, archiveName: "p", settings: CompressionSettings(format: .zip))).archives[0].outputs[0]
        let o = try service.extract(ExtractRequest(archive: zip, destination: dest, mode: .here))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("payload.txt").path))
        XCTAssertTrue(o.report.blocked.contains { $0.reason.contains("symbolic link") }, "\(o.report.blocked)")
    }

    func testHelperEngineOutputIsAlsoValidated() throws {
        // Force the 7-Zip engine for the traversal archive: its output goes through the same sink.
        try XCTSkipUnless(service.registry.engine(.sevenZip)?.descriptor.isAvailable == true)
        service.registry.preferred[.zip] = .sevenZip
        service.registry.preferred[.tar] = .sevenZip
        defer { service.registry.preferred = [:] }
        _ = try extract("zip-slip.zip")
        _ = try? extract("symlink-escape.tar")
        assertContained()
    }
}
