import XCTest
import ArchiveCore
import UATestSupport
@testable import ArchiveEngines

final class SpecialistEngineTests: XCTestCase {
    /// RAR creation through the user-installed, licensed `rar` tool; read back by an independent decoder.
    func testRarCreationWithLicensedTool() throws {
        let rar = RarEngine()
        try XCTSkipUnless(rar.descriptor.isAvailable, "rar not installed")
        let work = TestFS.tempDir("rarc")
        defer { try? FileManager.default.removeItem(at: work) }
        let tree = TestFS.sampleTree(in: work)
        for (enc, pw) in [(EncryptionSettings?.none, String?.none), (EncryptionSettings(method: .rar5AES256, encryptFilenames: true), "rar-secret")] {
            let s = CompressionSettings(format: .rar, level: 5, encryption: enc)
            let out = work.appendingPathComponent(enc == nil ? "plain.rar" : "enc.rar")
            let items = try SourceCollector.collect([tree], settings: s).items
            _ = try rar.create(CreateRequest(output: out, format: .rar, items: items, settings: s, password: pw.map(Secret.init)), progress: OperationProgress())
            // Independent reader: 7-Zip (with the RAR plugin) or unrar.
            let seven = SevenZipEngine()
            try XCTSkipUnless(seven.descriptor.isAvailable)
            let dest = work.appendingPathComponent("x-\(out.lastPathComponent)")
            let sink = try SafeExtractionSink(destination: dest)
            try seven.extract(ArchiveSource(url: out, format: .rar), selection: .all, into: sink,
                              options: ReadOptions(passwordProvider: FixedPasswordProvider(pw)), progress: OperationProgress())
            try sink.finish()
            XCTAssertEqual(TestFS.digestTree(dest.appendingPathComponent("Sample")), TestFS.digestTree(tree), out.lastPathComponent)
            if enc != nil {
                XCTAssertThrowsError(try seven.list(ArchiveSource(url: out, format: .rar), options: ReadOptions(), progress: OperationProgress()),
                                     "file names are hidden without the password")
            }
        }
    }

    func testOtherLibarchiveWritersRoundTrip() throws {
        let engine = LibArchiveEngine()
        let work = TestFS.tempDir("misc")
        defer { try? FileManager.default.removeItem(at: work) }
        let tree = TestFS.sampleTree(in: work)
        for (format, ext) in [(FormatID.iso, "iso"), (.ar, "a")] {
            var s = CompressionSettings(format: format)
            if format == .ar { s.includeRootFolder = false }
            var items = try SourceCollector.collect([tree], settings: s).items
            if format == .ar { items = items.filter { $0.type == .file && !$0.archivePath.contains("/") } } // ar is flat
            let out = work.appendingPathComponent("out.\(ext)")
            _ = try engine.create(CreateRequest(output: out, format: format, items: items, settings: s), progress: OperationProgress())
            let listing = try engine.list(ArchiveSource(url: out, format: format), options: ReadOptions(), progress: OperationProgress())
            XCTAssertEqual(listing.fileCount, items.filter { $0.type == .file }.count, "\(format)")
            let report = try engine.test(ArchiveSource(url: out, format: format), options: ReadOptions(), progress: OperationProgress())
            XCTAssertEqual(report.result, .passed, "\(format): \(report.textSummary)")
        }
        // ISO is also readable by an independent implementation.
        if let sevenZ = TestFS.which("7z") {
            let (rc, out) = try TestFS.run(sevenZ, ["t", work.appendingPathComponent("out.iso").path])
            XCTAssertEqual(rc, 0, out)
        }
    }
}
