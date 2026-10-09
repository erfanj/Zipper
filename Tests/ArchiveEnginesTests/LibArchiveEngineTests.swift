import XCTest
import ArchiveCore
@testable import ArchiveEngines

final class LibArchiveEngineTests: XCTestCase {
    let engine = LibArchiveEngine()

    func roundTrip(_ format: FormatID, ext: String, method: CompressionMethod? = nil, level: Int = 5,
                   encryption: EncryptionSettings? = nil, password: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let work = TestFS.tempDir("rt-\(format.rawValue)")
        defer { try? FileManager.default.removeItem(at: work) }
        let tree = TestFS.sampleTree(in: work)
        var settings = CompressionSettings(format: format, method: method, level: level, encryption: encryption)
        settings.includeRootFolder = true
        let collection = try SourceCollector.collect([tree], settings: settings)
        let out = work.appendingPathComponent("out.\(ext)")
        let result = try engine.create(CreateRequest(output: out, format: format, items: collection.items, settings: settings,
                                                     password: password.map(Secret.init)), progress: OperationProgress())
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), file: file, line: line)
        XCTAssertGreaterThan(result.outputBytes, 0, file: file, line: line)

        let detection = try XCTUnwrap(FormatDetector.detect(out), file: file, line: line)
        let effective = FormatCatalog.descriptor(for: format)?.effectiveContainer ?? format
        XCTAssertTrue(detection.format == format || detection.format == effective, "detected \(detection.format) for \(format)", file: file, line: line)
        let source = ArchiveSource(url: out, format: format, layers: FormatCatalog.descriptor(for: format)?.layers ?? [])
        let opts = ReadOptions(passwordProvider: password.map { FixedPasswordProvider($0) })
        let listing = try engine.list(source, options: opts, progress: OperationProgress())
        XCTAssertEqual(listing.fileCount, 11, file: file, line: line)
        if encryption != nil { XCTAssertTrue(listing.entries.contains { $0.isEncrypted }, file: file, line: line) }

        let dest = work.appendingPathComponent("extracted")
        let sink = try SafeExtractionSink(destination: dest)
        try engine.extract(source, selection: .all, into: sink, options: ReadOptions(passwordProvider: password.map { FixedPasswordProvider($0) }), progress: OperationProgress())
        try sink.finish()
        XCTAssertEqual(sink.report.blocked.count, 0, file: file, line: line)
        XCTAssertEqual(TestFS.digestTree(dest.appendingPathComponent("Sample")), TestFS.digestTree(tree), file: file, line: line)
        XCTAssertTrue(TestFS.directories(dest).contains("Sample/empty"), "empty directory preserved", file: file, line: line)

        let report = try engine.test(source, options: ReadOptions(passwordProvider: password.map { FixedPasswordProvider($0) }), progress: OperationProgress())
        XCTAssertEqual(report.result, .passed, report.textSummary, file: file, line: line)
        XCTAssertEqual(report.filesVerified, 11, file: file, line: line)
    }

    func testZipDeflate() throws { try roundTrip(.zip, ext: "zip", method: .deflate) }
    func testZipStore() throws { try roundTrip(.zip, ext: "zip", method: .store, level: 0) }
    func testZipAES256() throws {
        try XCTSkipUnless(engine.zipEncryption.contains(.zipAES256), "libarchive built without crypto")
        try roundTrip(.zip, ext: "zip", encryption: .init(method: .zipAES256), password: "correct horse battery staple")
    }
    func testSevenZipLZMA2() throws { try roundTrip(.sevenZip, ext: "7z", method: .lzma2, level: 7) }
    func testTar() throws { try roundTrip(.tar, ext: "tar") }
    func testTarGz() throws { try roundTrip(.tarGzip, ext: "tar.gz") }
    func testTarBz2() throws { try roundTrip(.tarBzip2, ext: "tar.bz2") }
    func testTarXz() throws { try roundTrip(.tarXz, ext: "tar.xz") }
    func testTarZstd() throws { try roundTrip(.tarZstd, ext: "tar.zst") }
    func testTarLz4() throws { try roundTrip(.tarLz4, ext: "tar.lz4") }
    func testTarLzip() throws {
        try XCTSkipUnless(engine.writableFilters.contains("lzip"))
        try roundTrip(.tarLzip, ext: "tar.lz")
    }
    func testTarLzma() throws { try roundTrip(.tarLzma, ext: "tar.lzma") }
    func testTarCompress() throws { try roundTrip(.tarCompress, ext: "tar.Z") }
    func testTarBrotli() throws { try roundTrip(.tarBrotli, ext: "tar.br") }
    func testCpio() throws { try roundTrip(.cpio, ext: "cpio") }
    func testXar() throws {
        try XCTSkipUnless(engine.canWriteXar)
        try roundTrip(.xar, ext: "xar")
    }

    func testSingleStreams() throws {
        let work = TestFS.tempDir("streams")
        defer { try? FileManager.default.removeItem(at: work) }
        let file = TestFS.write(work, "notes.txt", String(repeating: "stream payload ", count: 5000))
        let digest = try StreamingHasher.hashFile(at: file, algorithm: .sha256)
        for (format, ext) in [(FormatID.gzip, "gz"), (.bzip2, "bz2"), (.xz, "xz"), (.zstd, "zst"), (.lz4, "lz4"), (.lzma, "lzma"),
                              (.lzip, "lz"), (.unixCompress, "Z"), (.brotli, "br")] {
            if format == .lzip, !engine.writableFilters.contains("lzip") { continue }
            let settings = CompressionSettings(format: format, level: 6)
            let items = try SourceCollector.collect([file], settings: settings).items
            let out = work.appendingPathComponent("notes.txt.\(ext)")
            _ = try engine.create(CreateRequest(output: out, format: format, items: items, settings: settings), progress: OperationProgress())
            let det = try XCTUnwrap(FormatDetector.detect(out))
            XCTAssertEqual(det.format, format, "detect \(ext)")
            let dest = work.appendingPathComponent("x-\(ext)")
            let sink = try SafeExtractionSink(destination: dest)
            try engine.extract(det.source(for: out), selection: .all, into: sink, options: ReadOptions(), progress: OperationProgress())
            try sink.finish()
            XCTAssertEqual(try StreamingHasher.hashFile(at: dest.appendingPathComponent("notes.txt"), algorithm: .sha256), digest, ext)
        }
    }

    func testRawStreamRejectsMultipleFiles() throws {
        let work = TestFS.tempDir("raw-multi")
        defer { try? FileManager.default.removeItem(at: work) }
        let tree = TestFS.sampleTree(in: work)
        let settings = CompressionSettings(format: .gzip)
        let items = try SourceCollector.collect([tree], settings: settings).items
        XCTAssertThrowsError(try engine.create(CreateRequest(output: work.appendingPathComponent("x.gz"), format: .gzip, items: items, settings: settings), progress: OperationProgress()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("x.gz").path), "no partial output left behind")
    }

    func testWrongPasswordIsReportedAsIncorrect() throws {
        try XCTSkipUnless(engine.zipEncryption.contains(.zipAES256))
        let work = TestFS.tempDir("pw")
        defer { try? FileManager.default.removeItem(at: work) }
        let f = TestFS.write(work, "secret.txt", "top secret")
        let settings = CompressionSettings(format: .zip, encryption: .init(method: .zipAES256))
        let out = work.appendingPathComponent("s.zip")
        _ = try engine.create(CreateRequest(output: out, format: .zip, items: try SourceCollector.collect([f], settings: settings).items,
                                            settings: settings, password: Secret("right")), progress: OperationProgress())
        let sink = try SafeExtractionSink(destination: work.appendingPathComponent("o"))
        XCTAssertThrowsError(try engine.extract(ArchiveSource(url: out, format: .zip), selection: .all, into: sink,
                                                options: ReadOptions(passwordProvider: FixedPasswordProvider("wrong")), progress: OperationProgress())) { err in
            XCTAssertEqual((err as? ArchiveError)?.code, "incorrect-password", "\(err)")
        }
        let sink2 = try SafeExtractionSink(destination: work.appendingPathComponent("o2"))
        XCTAssertThrowsError(try engine.extract(ArchiveSource(url: out, format: .zip), selection: .all, into: sink2,
                                                options: ReadOptions(), progress: OperationProgress())) { err in
            XCTAssertEqual((err as? ArchiveError)?.code, "password-required", "\(err)")
        }
        // No partially decrypted file left behind.
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("o/secret.txt").path))
    }

    func testSelectiveExtraction() throws {
        let work = TestFS.tempDir("sel")
        defer { try? FileManager.default.removeItem(at: work) }
        let root = work.appendingPathComponent("many")
        for i in 0..<2000 { TestFS.write(root, "dir\(i % 20)/file\(i).txt", "content \(i)") }
        let settings = CompressionSettings(format: .zip)
        let out = work.appendingPathComponent("many.zip")
        _ = try engine.create(CreateRequest(output: out, format: .zip, items: try SourceCollector.collect([root], settings: settings).items,
                                            settings: settings), progress: OperationProgress())
        let dest = work.appendingPathComponent("one")
        let sink = try SafeExtractionSink(destination: dest)
        try engine.extract(ArchiveSource(url: out, format: .zip), selection: .paths(["many/dir7/file1407.txt"]), into: sink,
                           options: ReadOptions(), progress: OperationProgress())
        try sink.finish()
        XCTAssertEqual(sink.report.filesWritten, 1)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("many/dir7/file1407.txt"), encoding: .utf8), "content 1407")
    }

    func testEpubProfileStoresMimetypeFirst() throws {
        let work = TestFS.tempDir("epub")
        defer { try? FileManager.default.removeItem(at: work) }
        let book = work.appendingPathComponent("Book")
        TestFS.write(book, "META-INF/container.xml", "<container/>")
        TestFS.write(book, "OEBPS/content.opf", "<package/>")
        TestFS.write(book, "mimetype", "application/epub+zip")
        var settings = CompressionSettings(format: .epub)
        settings.includeRootFolder = false
        let out = work.appendingPathComponent("book.epub")
        _ = try engine.create(CreateRequest(output: out, format: .epub, items: try SourceCollector.collect([book], settings: settings).items,
                                            settings: settings), progress: OperationProgress())
        let data = try Data(contentsOf: out)
        // Local header: name at offset 30, method (stored = 0) at offset 8.
        XCTAssertEqual(String(decoding: data[30..<38], as: UTF8.self), "mimetype")
        XCTAssertEqual(data[8], 0)
        XCTAssertEqual(String(decoding: data[38..<58], as: UTF8.self), "application/epub+zip")
    }
}
