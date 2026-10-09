import XCTest
import ArchiveCore
import UATestSupport
@testable import ArchiveEngines

final class SevenZipEngineTests: XCTestCase {
    let engine = SevenZipEngine()

    override func setUpWithError() throws {
        try XCTSkipUnless(engine.descriptor.isAvailable, "7-Zip not installed: \(engine.descriptor.unavailableReason ?? "")")
    }

    func create(_ tree: URL, _ out: URL, format: FormatID, settings: CompressionSettings, password: String? = nil) throws -> CreateResult {
        let items = try SourceCollector.collect([tree], settings: settings).items
        return try engine.create(CreateRequest(output: out, format: format, items: items, settings: settings, password: password.map(Secret.init)),
                                 progress: OperationProgress())
    }

    func extract(_ source: ArchiveSource, to dest: URL, password: String? = nil) throws -> ExtractionReport {
        let sink = try SafeExtractionSink(destination: dest)
        try engine.extract(source, selection: .all, into: sink, options: ReadOptions(passwordProvider: password.map { FixedPasswordProvider($0) }),
                           progress: OperationProgress())
        try sink.finish()
        return sink.report
    }

    /// Acceptance test 5: encrypted 7z with encrypted file names.
    func testEncrypted7zHidesFilenames() throws {
        let work = TestFS.tempDir("7zenc")
        defer { try? FileManager.default.removeItem(at: work) }
        let tree = TestFS.sampleTree(in: work)
        let out = work.appendingPathComponent("secret.7z")
        let settings = CompressionSettings(format: .sevenZip, method: .lzma2, level: 5,
                                           encryption: .init(method: .sevenZipAES256, encryptFilenames: true))
        _ = try create(tree, out, format: .sevenZip, settings: settings, password: "pässwörd 🔑")

        // The names must not appear in the file.
        let raw = try Data(contentsOf: out)
        XCTAssertNil(raw.range(of: Data("readme.txt".utf8)))
        XCTAssertNil(raw.range(of: Data("readme".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })), "UTF-16 names must not leak either")

        // Listing without the password fails with password-required.
        XCTAssertThrowsError(try engine.list(ArchiveSource(url: out, format: .sevenZip), options: ReadOptions(), progress: OperationProgress())) {
            XCTAssertEqual(($0 as? ArchiveError)?.code, "password-required", "\($0)")
        }
        // Independent check with the reference tool: listing without a password reveals nothing.
        if let sevenZ = TestFS.which("7z") {
            let (_, text) = try TestFS.run(sevenZ, ["l", "-slt", "-p", out.path], stdin: "\n")
            XCTAssertFalse(text.contains("readme.txt"))
        }
        // Wrong password.
        XCTAssertThrowsError(try engine.list(ArchiveSource(url: out, format: .sevenZip), options: ReadOptions(passwordProvider: FixedPasswordProvider("nope")), progress: OperationProgress())) {
            XCTAssertEqual(($0 as? ArchiveError)?.code, "incorrect-password", "\($0)")
        }
        let listing = try engine.list(ArchiveSource(url: out, format: .sevenZip), options: ReadOptions(passwordProvider: FixedPasswordProvider("pässwörd 🔑")), progress: OperationProgress())
        XCTAssertEqual(listing.fileCount, 11)
        XCTAssertEqual(listing.properties.hasEncryptedHeaders, true)
        let dest = work.appendingPathComponent("x")
        _ = try extract(ArchiveSource(url: out, format: .sevenZip), to: dest, password: "pässwörd 🔑")
        XCTAssertEqual(TestFS.digestTree(dest.appendingPathComponent("Sample")), TestFS.digestTree(tree))
        let report = try engine.test(ArchiveSource(url: out, format: .sevenZip), options: ReadOptions(passwordProvider: FixedPasswordProvider("pässwörd 🔑")), progress: OperationProgress())
        XCTAssertEqual(report.result, .passed, report.textSummary)
    }

    /// Acceptance test 6: multipart creation, extraction and missing-volume detection.
    func testMultipartCreateExtractAndMissingVolume() throws {
        let work = TestFS.tempDir("7zsplit")
        defer { try? FileManager.default.removeItem(at: work) }
        let tree = work.appendingPathComponent("Big")
        var rng = SystemRandomNumberGenerator()
        TestFS.writeBytes(tree, "noise.bin", Data((0..<600_000).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        TestFS.write(tree, "text.txt", "hello")
        let out = work.appendingPathComponent("big.7z")
        var settings = CompressionSettings(format: .sevenZip, level: 1)
        settings.splitVolumeSize = 200_000
        let result = try create(tree, out, format: .sevenZip, settings: settings)
        XCTAssertGreaterThanOrEqual(result.outputs.count, 3)
        XCTAssertEqual(result.outputs.first?.lastPathComponent, "big.7z.001")

        let first = work.appendingPathComponent("big.7z.002") // opening any volume works
        let det = try XCTUnwrap(FormatDetector.detect(first))
        XCTAssertEqual(det.format, .sevenZip)
        let mp = try XCTUnwrap(det.multipart)
        XCTAssertEqual(mp.volumes.count, result.outputs.count)
        XCTAssertTrue(mp.isComplete)
        _ = try extract(det.source(for: first), to: work.appendingPathComponent("x"))
        XCTAssertEqual(TestFS.digestTree(work.appendingPathComponent("x/Big")), TestFS.digestTree(tree))

        // Remove a middle volume: detection reports it, extraction fails with missing-volume.
        try FileManager.default.removeItem(at: work.appendingPathComponent("big.7z.002"))
        let det2 = try XCTUnwrap(FormatDetector.detect(work.appendingPathComponent("big.7z.001")))
        XCTAssertEqual(det2.multipart?.missing, ["big.7z.002"])
        XCTAssertThrowsError(try extract(det2.source(for: work.appendingPathComponent("big.7z.001")), to: work.appendingPathComponent("y"))) { err in
            let code = (err as? ArchiveError)?.code
            XCTAssertTrue(code == "missing-volume" || code == "truncated" || code == "damaged", "\(err)")
        }
    }

    func testZipAES256ReadableByReferenceUnzip() throws {
        let work = TestFS.tempDir("7zzipaes")
        defer { try? FileManager.default.removeItem(at: work) }
        let tree = TestFS.sampleTree(in: work)
        let out = work.appendingPathComponent("aes.zip")
        _ = try create(tree, out, format: .zip, settings: CompressionSettings(format: .zip, encryption: .init(method: .zipAES256)), password: "s3cret")
        // libarchive (independent implementation) must decrypt it.
        let la = LibArchiveEngine()
        let sink = try SafeExtractionSink(destination: work.appendingPathComponent("la"))
        try la.extract(ArchiveSource(url: out, format: .zip), selection: .all, into: sink,
                       options: ReadOptions(passwordProvider: FixedPasswordProvider("s3cret")), progress: OperationProgress())
        try sink.finish()
        XCTAssertEqual(TestFS.digestTree(work.appendingPathComponent("la/Sample")), TestFS.digestTree(tree))
    }

    func testEncryptedRar5FromReferenceTool() throws {
        guard let rar = TestFS.which("rar") else { throw XCTSkip("rar not installed") }
        let work = TestFS.tempDir("rar5")
        defer { try? FileManager.default.removeItem(at: work) }
        let tree = TestFS.sampleTree(in: work)
        let out = work.appendingPathComponent("enc.rar")
        // -hp encrypts headers too. The password is given on the command line only to the reference tool in tests.
        let (rc, log) = try TestFS.run(rar, ["a", "-ma5", "-hpTopSecret", "-r", "-ep1", out.path, tree.path])
        XCTAssertEqual(rc, 0, log)
        XCTAssertThrowsError(try engine.list(ArchiveSource(url: out, format: .rar), options: ReadOptions(), progress: OperationProgress()))
        let listing = try engine.list(ArchiveSource(url: out, format: .rar), options: ReadOptions(passwordProvider: FixedPasswordProvider("TopSecret")), progress: OperationProgress())
        XCTAssertEqual(listing.fileCount, 11)
        _ = try extract(ArchiveSource(url: out, format: .rar), to: work.appendingPathComponent("x"), password: "TopSecret")
        XCTAssertEqual(TestFS.digestTree(work.appendingPathComponent("x/Sample")), TestFS.digestTree(tree))
    }

    func testSelectiveExtraction() throws {
        let work = TestFS.tempDir("7zsel")
        defer { try? FileManager.default.removeItem(at: work) }
        let tree = TestFS.sampleTree(in: work)
        let out = work.appendingPathComponent("s.7z")
        _ = try create(tree, out, format: .sevenZip, settings: CompressionSettings(format: .sevenZip))
        let sink = try SafeExtractionSink(destination: work.appendingPathComponent("x"))
        try engine.extract(ArchiveSource(url: out, format: .sevenZip), selection: .paths(["Sample/docs/中文"]), into: sink,
                           options: ReadOptions(), progress: OperationProgress())
        try sink.finish()
        XCTAssertEqual(sink.report.filesWritten, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("x/Sample/docs/中文/文件.txt").path))
    }
}
