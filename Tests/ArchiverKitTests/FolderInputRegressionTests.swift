import XCTest
import ArchiveCore
import ArchiveEngines
import ArchiverKit
import UATestSupport

/// A folder handed to code that expects a file (dropped on a tool, chosen by a Finder service, typed
/// on the command line) used to crash the process: FileHandle's old API traps on EISDIR. Every entry
/// point must now report an error instead.
final class FolderInputRegressionTests: XCTestCase {
    var dir: URL!
    var folder: URL!

    override func setUpWithError() throws {
        dir = TestFS.tempDir("folder-input")
        folder = TestFS.sampleTree(in: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func assertNotAnArchive(_ what: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), what) { e in
            guard case .notAnArchive? = e as? ArchiveError else { return XCTFail("\(what): \(e)") }
        }
    }

    func testEveryArchiveReaderRejectsAFolder() throws {
        let service = ArchiveService()
        XCTAssertNil(try? FormatDetector.detect(folder))
        assertNotAnArchive("open") { _ = try service.open(folder) }
        assertNotAnArchive("test") { _ = try service.test(folder) }
        assertNotAnArchive("extract") { _ = try service.extract(ExtractRequest(archive: folder, destination: dir)) }
        assertNotAnArchive("analyze damage") { _ = try service.analyzeDamage(folder) }
        assertNotAnArchive("duplicates") { _ = try service.findDuplicates(in: [folder]) }
        assertNotAnArchive("convert") { _ = try service.convert(ConvertRequest(archive: folder, settings: CompressionSettings(format: .sevenZip))) }
        assertNotAnArchive("modify") { _ = try service.modify(ModifyRequest(archive: folder, edits: [.createFolder(path: "x")])) }
    }

    func testHashingAndSplittingAFolderReportAnError() {
        XCTAssertThrowsError(try StreamingHasher.hashFile(at: folder, algorithm: .sha256)) { e in
            XCTAssertEqual((e as? ArchiveError)?.code, "invalid-argument")
        }
        XCTAssertThrowsError(try ChecksumManifest.generate(for: [folder], base: dir, algorithm: .sha256))
        XCTAssertThrowsError(try FileSplitter.split(folder, partSize: 1_000_000)) { e in
            XCTAssertEqual((e as? ArchiveError)?.code, "invalid-argument")
        }
    }

    func testOneKilobyteIsAnAcceptedPartSize() throws {
        let file = TestFS.writeBytes(dir, "data.bin", Data(repeating: 7, count: 5_000))
        let r = try FileSplitter.split(file, partSize: FileSplitter.parseSize("1 KB")!)
        XCTAssertEqual(r.parts.count, 5)
    }

    func testReadErrorsBecomeArchiveErrors() throws {
        let fh = try XCTUnwrap(FileHandle(forReadingAtPath: folder.path))
        defer { try? fh.close() }
        XCTAssertThrowsError(try fh.readChunk(upTo: 16, path: folder.path)) { e in
            guard case .io(_, let code, let message)? = e as? ArchiveError else { return XCTFail("\(e)") }
            XCTAssertEqual(code, EISDIR)
            XCTAssertEqual(message, "It's a folder, not a file.")
        }
    }
}
