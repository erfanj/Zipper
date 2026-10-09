import XCTest
import ArchiveCore
import ArchiveEngines
@testable import ArchiverKit
import UATestSupport

final class ExtractionServiceTests: XCTestCase {
    let service = ArchiveService()
    var work: URL!

    override func setUp() { work = TestFS.tempDir("svc") }
    override func tearDown() { try? FileManager.default.removeItem(at: work) }

    func makeZip(_ items: [URL], name: String, settings: CompressionSettings = CompressionSettings(format: .zip)) throws -> URL {
        let o = try service.compress(CompressRequest(items: items, destinationDirectory: work, archiveName: name, settings: settings))
        return o.archives[0].outputs[0]
    }

    func testSmartExtractSingleRootDoesNotNest() throws {
        let tree = TestFS.sampleTree(in: work.appendingPathComponent("src"))
        let zip = try makeZip([tree], name: "one")
        let dest = work.appendingPathComponent("out")
        let o = try service.extract(ExtractRequest(archive: zip, destination: dest, mode: .smart, verifyAfterExtraction: true))
        XCTAssertEqual(o.createdItems.map(\.lastPathComponent), ["Sample"])
        XCTAssertEqual(TestFS.digestTree(dest.appendingPathComponent("Sample")), TestFS.digestTree(tree))
        XCTAssertEqual(o.verification?.passed, true, "\(o.verification?.mismatches ?? [])")
        XCTAssertEqual(o.verification?.filesChecked, 11)
        // Second time: the existing folder is kept and a numbered one is created.
        let o2 = try service.extract(ExtractRequest(archive: zip, destination: dest, mode: .smart, verifyAfterExtraction: true))
        XCTAssertEqual(o2.createdItems.map(\.lastPathComponent), ["Sample 2"])
        XCTAssertEqual(o2.verification?.passed, true)
        // No staging folders left behind.
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dest.path).contains { $0.hasPrefix(".ua-") })
    }

    func testSmartExtractMultipleRootsCreatesFolder() throws {
        let a = TestFS.write(work.appendingPathComponent("src"), "a.txt", "a")
        let b = TestFS.write(work.appendingPathComponent("src"), "b.txt", "b")
        let zip = try makeZip([a, b], name: "Loose Files")
        let dest = work.appendingPathComponent("out")
        let o = try service.extract(ExtractRequest(archive: zip, destination: dest, mode: .smart))
        XCTAssertEqual(o.createdItems.map(\.lastPathComponent), ["Loose Files"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Loose Files/a.txt").path))
    }

    func testExtractHereConflictPolicies() throws {
        let src = work.appendingPathComponent("src")
        let f = TestFS.write(src, "doc.txt", "from archive")
        let zip = try makeZip([f], name: "c")
        let dest = work.appendingPathComponent("out")
        TestFS.write(dest, "doc.txt", "existing")

        var opts = ExtractionOptions(conflictPolicy: .keepBoth)
        _ = try service.extract(ExtractRequest(archive: zip, destination: dest, mode: .here, options: opts))
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("doc.txt"), encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("doc 2.txt"), encoding: .utf8), "from archive")

        opts.conflictPolicy = .skip
        let o = try service.extract(ExtractRequest(archive: zip, destination: dest, mode: .here, options: opts))
        XCTAssertEqual(o.report.skipped.count, 1)

        opts.conflictPolicy = .replace
        _ = try service.extract(ExtractRequest(archive: zip, destination: dest, mode: .here, options: opts))
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("doc.txt"), encoding: .utf8), "from archive")

        // replaceIfOlder: existing file is newer → kept.
        TestFS.write(dest, "doc.txt", "newer local edit")
        opts.conflictPolicy = .replaceIfOlder
        _ = try service.extract(ExtractRequest(archive: zip, destination: dest, mode: .here, options: opts))
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("doc.txt"), encoding: .utf8), "newer local edit")

        // ask: resolver chooses replace for all.
        opts.conflictPolicy = .ask
        opts.conflictResolver = { _ in (.replace, true) }
        _ = try service.extract(ExtractRequest(archive: zip, destination: dest, mode: .here, options: opts))
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("doc.txt"), encoding: .utf8), "from archive")
    }

    func testHereMergesFolders() throws {
        let tree = work.appendingPathComponent("src/Proj")
        TestFS.write(tree, "new.txt", "n")
        let zip = try makeZip([tree], name: "m")
        let dest = work.appendingPathComponent("out")
        TestFS.write(dest, "Proj/old.txt", "o")
        _ = try service.extract(ExtractRequest(archive: zip, destination: dest, mode: .here))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Proj/old.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Proj/new.txt").path))
    }

    func testNestedExtractionIsBounded() throws {
        // inner.tar.gz inside middle.zip inside outer.7z (or zip if 7-Zip missing)
        let innerSrc = TestFS.write(work.appendingPathComponent("l0"), "deep.txt", "deep")
        let inner = try service.compress(CompressRequest(items: [innerSrc], destinationDirectory: work, archiveName: "inner", settings: CompressionSettings(format: .tarGzip))).archives[0].outputs[0]
        let middle = try makeZip([inner], name: "middle")
        let outer = try makeZip([middle], name: "outer")
        let dest = work.appendingPathComponent("out")
        let o = try service.extract(ExtractRequest(archive: outer, destination: dest, extractNestedArchives: true))
        XCTAssertEqual(o.nested.count, 1)
        XCTAssertEqual(o.nested.first?.nested.count, 1)
        let found = FileManager.default.enumerator(atPath: dest.path)?.allObjects.compactMap { $0 as? String }.filter { $0.hasSuffix("deep.txt") }
        XCTAssertEqual(found?.count, 1)

        // Depth limit of 1 stops before the innermost archive.
        var opts = ExtractionOptions()
        opts.limits.maxNestingDepth = 1
        let dest2 = work.appendingPathComponent("out2")
        let o2 = try service.extract(ExtractRequest(archive: outer, destination: dest2, options: opts, extractNestedArchives: true))
        XCTAssertEqual(o2.nested.count, 1)
        XCTAssertEqual(o2.nested.first?.nested.count, 0)
    }

    func testBatchExtraction() throws {
        var archives: [URL] = []
        for i in 0..<5 { archives.append(try makeZip([TestFS.write(work.appendingPathComponent("s\(i)"), "f\(i).txt", "\(i)")], name: "batch\(i)")) }
        let broken = work.appendingPathComponent("broken.zip")
        try Data("PK\u{3}\u{4}garbage".utf8).write(to: broken)
        archives.append(broken)
        let dest = work.appendingPathComponent("all")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let r = try service.extractBatch(BatchExtractRequest(archives: archives, sharedDestination: dest))
        XCTAssertEqual(r.succeeded, 5)
        XCTAssertEqual(r.failed, 1)
        let r2 = try service.extractBatch(BatchExtractRequest(archives: archives, sharedDestination: dest))
        XCTAssertEqual(r2.skipped, 5, "already extracted archives are skipped")
    }

    func testMissingVolumeIsReportedBeforeExtraction() throws {
        TestFS.write(work, "set.part1.rar", "x")
        TestFS.write(work, "set.part3.rar", "x")
        XCTAssertThrowsError(try service.extract(ExtractRequest(archive: work.appendingPathComponent("set.part1.rar")))) {
            XCTAssertEqual($0 as? ArchiveError, .missingVolume(expected: ["set.part2.rar"]))
        }
    }

    func testFallbackToSevenZipForEncrypted7z() throws {
        try XCTSkipUnless(service.registry.engine(.sevenZip)?.descriptor.isAvailable == true)
        let tree = TestFS.sampleTree(in: work.appendingPathComponent("src"))
        let s = CompressionSettings(format: .sevenZip, encryption: .init(method: .sevenZipAES256, encryptFilenames: false))
        let o = try service.compress(CompressRequest(items: [tree], destinationDirectory: work, archiveName: "e", settings: s, password: Secret("pw")))
        XCTAssertEqual(o.archives[0].engine, .sevenZip)
        // libarchive is tried first for 7z; it cannot decrypt, so the service falls back and says so.
        let x = try service.extract(ExtractRequest(archive: o.archives[0].outputs[0], destination: work.appendingPathComponent("x"),
                                                   readOptions: ReadOptions(passwordProvider: FixedPasswordProvider("pw"))))
        XCTAssertEqual(x.engine, .sevenZip)
        XCTAssertEqual(TestFS.digestTree(work.appendingPathComponent("x/Sample")), TestFS.digestTree(tree))
    }
}

final class CompressionServiceTests: XCTestCase {
    let service = ArchiveService()
    var work: URL!
    override func setUp() { work = TestFS.tempDir("cmp") }
    override func tearDown() { try? FileManager.default.removeItem(at: work) }

    func testPerItemGroupingAndNaming() throws {
        let a = TestFS.write(work.appendingPathComponent("in"), "Report.pdf", "pdf")
        let b = work.appendingPathComponent("in/Photos")
        TestFS.write(b, "x.jpg", "jpg")
        var s = CompressionSettings(format: .zip)
        s.grouping = .perItem
        let o = try service.compress(CompressRequest(items: [a, b], destinationDirectory: work, settings: s))
        XCTAssertEqual(Set(o.archives.flatMap(\.outputs).map(\.lastPathComponent)), ["Report.zip", "Photos.zip"])
        // Again: unique names, never overwriting.
        let o2 = try service.compress(CompressRequest(items: [a], destinationDirectory: work, settings: s))
        XCTAssertEqual(o2.archives[0].outputs[0].lastPathComponent, "Report 2.zip")
    }

    func testCompoundNameUniqueness() {
        let dir = work!
        TestFS.write(dir, "A.tar.gz", "x")
        XCTAssertEqual(ArchiveService.uniqueURL(in: dir, name: "A.tar.gz").lastPathComponent, "A 2.tar.gz")
        XCTAssertEqual(ArchiveService.baseName(for: dir.appendingPathComponent("A.tar.gz")), "A")
        XCTAssertEqual(ArchiveService.baseName(for: dir.appendingPathComponent("x.part1.rar")), "x")
    }

    func testEncryptionRequiresPasswordAndUnsupportedCombosAreExplained() {
        let f = TestFS.write(work, "a.txt", "a")
        XCTAssertThrowsError(try service.compress(CompressRequest(items: [f], settings: CompressionSettings(format: .zip, encryption: .init(method: .zipAES256))))) {
            XCTAssertEqual(($0 as? ArchiveError)?.code, "invalid-argument")
        }
        XCTAssertThrowsError(try service.compress(CompressRequest(items: [f], settings: CompressionSettings(format: .tarGzip, encryption: .init(method: .zipAES256)), password: Secret("x")))) {
            XCTAssertEqual(($0 as? ArchiveError)?.code, "operation-not-supported", "\($0)")
        }
        XCTAssertThrowsError(try service.compress(CompressRequest(items: [work], settings: CompressionSettings(format: .gzip)))) {
            XCTAssertTrue(($0 as? ArchiveError)?.explanation.contains("TAR") == true, "\($0)")
        }
    }

    func testCreationOptionsAreFormatAware() {
        let zip = service.creationOptions(for: .zip)
        XCTAssertTrue(zip.canCreate)
        XCTAssertFalse(zip.supportsDictionary)
        XCTAssertTrue(zip.encryptionMethods.contains(.zipAES256))
        XCTAssertFalse(zip.canEncryptFilenames)
        let gz = service.creationOptions(for: .gzip)
        XCTAssertTrue(gz.singleFileOnly)
        XCTAssertTrue(gz.encryptionMethods.isEmpty)
        let tar = service.creationOptions(for: .tar)
        XCTAssertFalse(tar.supportsLevel)
        if service.registry.engine(.sevenZip)?.descriptor.isAvailable == true {
            let sz = service.creationOptions(for: .sevenZip)
            XCTAssertTrue(sz.canEncryptFilenames)
            XCTAssertTrue(sz.canSplit)
            XCTAssertTrue(sz.supportsDictionary)
        }
    }

    func testLargeFileOver4GBZip64() throws {
        // Acceptance test 13. Sparse 4.3 GB file: compresses quickly and checks ZIP64 handling end to end.
        guard ProcessInfo.processInfo.environment["UA_RUN_LARGE_TESTS"] == "1" else { throw XCTSkip("Set UA_RUN_LARGE_TESTS=1 to run the >4 GB test") }
        let big = work.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let fh = try FileHandle(forWritingTo: big)
        try fh.truncate(atOffset: 4_400_000_000)
        try fh.seek(toOffset: 4_300_000_000)
        fh.write(Data("tail marker".utf8))
        try fh.close()
        let o = try service.compress(CompressRequest(items: [big], destinationDirectory: work, settings: CompressionSettings(format: .zip, level: 1)))
        let zip = o.archives[0].outputs[0]
        let l = try service.open(zip).listing
        XCTAssertEqual(l.entries.first?.uncompressedSize, 4_400_000_000)
        let report = try service.test(zip)
        XCTAssertEqual(report.result, .passed)
        let x = try service.extract(ExtractRequest(archive: zip, destination: work.appendingPathComponent("x"), verifyAfterExtraction: true))
        XCTAssertEqual(x.verification?.passed, true)
        if let unzip = TestFS.which("unzip") {
            let (rc, out) = try TestFS.run(unzip, ["-t", zip.path])
            XCTAssertEqual(rc, 0, out)
        }
    }
}

final class ToolsTests: XCTestCase {
    let service = ArchiveService()
    var work: URL!
    override func setUp() { work = TestFS.tempDir("tools") }
    override func tearDown() { try? FileManager.default.removeItem(at: work) }

    func testConversionZipTo7zVerifiesContent() throws {
        let tree = TestFS.sampleTree(in: work.appendingPathComponent("src"))
        let zip = try service.compress(CompressRequest(items: [tree], destinationDirectory: work, archiveName: "conv", settings: CompressionSettings(format: .zip))).archives[0].outputs[0]
        let target = service.registry.engine(.sevenZip)?.descriptor.isAvailable == true ? FormatID.sevenZip : .tarXz
        let o = try service.convert(ConvertRequest(archive: zip, settings: CompressionSettings(format: target)))
        XCTAssertEqual(o.comparison.identical.count, 11)
        XCTAssertTrue(o.comparison.removed.isEmpty && o.comparison.modified.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path), "original untouched")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: work.path).contains { $0.hasPrefix(".ua-") })
    }

    func testConversionWarnings() {
        let listing = ArchiveListing(properties: ArchiveProperties(format: .sevenZip, hasEncryptedEntries: true, hasEncryptedHeaders: true, engine: .sevenZip),
                                     entries: [ArchiveEntry(index: 0, path: "a", type: .file, isEncrypted: true),
                                               ArchiveEntry(index: 1, path: "l", type: .hardlink, linkTarget: "a")])
        let w = service.conversionWarnings(from: listing, to: CompressionSettings(format: .zip))
        let features = Set(w.map(\.feature))
        XCTAssertTrue(features.isSuperset(of: ["Encryption", "Filename protection", "Hard links"]), "\(features)")
    }

    func testTransactionalModification() throws {
        let tree = work.appendingPathComponent("src/Doc")
        TestFS.write(tree, "a.txt", "a")
        TestFS.write(tree, "sub/b.txt", "b")
        TestFS.write(tree, "old.txt", "old")
        let zip = try service.compress(CompressRequest(items: [tree], destinationDirectory: work, archiveName: "edit", settings: CompressionSettings(format: .zip))).archives[0].outputs[0]
        let extra = TestFS.write(work.appendingPathComponent("add"), "new.txt", "new")
        let o = try service.modify(ModifyRequest(archive: zip, edits: [
            .add(files: [extra], toFolder: "Doc/sub"),
            .delete(paths: ["Doc/old.txt"]),
            .rename(path: "Doc/a.txt", newName: "renamed.txt"),
            .move(path: "Doc/sub/b.txt", toFolder: "Doc"),
            .createFolder(path: "Doc/empty"),
        ]))
        XCTAssertEqual(o.verification.result, .passed)
        let paths = Set(try service.open(zip).listing.entries.map(\.normalizedPath))
        XCTAssertTrue(paths.isSuperset(of: ["Doc/renamed.txt", "Doc/b.txt", "Doc/sub/new.txt", "Doc/empty"]), "\(paths)")
        XCTAssertFalse(paths.contains("Doc/old.txt"))
        XCTAssertFalse(paths.contains("Doc/a.txt"))
        // A failing edit leaves the original byte-for-byte intact.
        let before = try Data(contentsOf: zip)
        XCTAssertThrowsError(try service.modify(ModifyRequest(archive: zip, edits: [.delete(paths: ["Doc/does-not-exist"])])))
        XCTAssertThrowsError(try service.modify(ModifyRequest(archive: zip, edits: [.rename(path: "Doc/b.txt", newName: "../escape")])))
        XCTAssertEqual(try Data(contentsOf: zip), before)
    }

    func testModifyEncryptedZipKeepsEncryption() throws {
        let f = TestFS.write(work.appendingPathComponent("src"), "secret.txt", "s")
        let zip = try service.compress(CompressRequest(items: [f], destinationDirectory: work, archiveName: "enc",
                                                       settings: CompressionSettings(format: .zip, encryption: .init(method: .zipAES256)), password: Secret("pw"))).archives[0].outputs[0]
        let add = TestFS.write(work.appendingPathComponent("add"), "more.txt", "m")
        let o = try service.modify(ModifyRequest(archive: zip, edits: [.add(files: [add], toFolder: "")],
                                                 readOptions: ReadOptions(passwordProvider: FixedPasswordProvider("pw"))))
        XCTAssertEqual(o.verification.result, .passed)
        let l = try service.open(zip, options: ReadOptions(passwordProvider: FixedPasswordProvider("pw"))).listing
        XCTAssertTrue(l.entries.filter { $0.type == .file }.allSatisfy(\.isEncrypted))
    }

    func testRefusesToEditRarAndSignedPackages() throws {
        let f = TestFS.write(work, "a.txt", "a")
        let jar = try service.compress(CompressRequest(items: [f], destinationDirectory: work, archiveName: "app", settings: CompressionSettings(format: .jar))).archives[0].outputs[0]
        XCTAssertThrowsError(try service.modify(ModifyRequest(archive: jar, edits: [.createFolder(path: "x")]))) {
            XCTAssertEqual(($0 as? ArchiveError)?.code, "not-editable")
        }
    }

    func testZipRepairRebuildsCentralDirectory() throws {
        let tree = TestFS.sampleTree(in: work.appendingPathComponent("src"))
        let zip = try service.compress(CompressRequest(items: [tree], destinationDirectory: work, archiveName: "dmg", settings: CompressionSettings(format: .zip))).archives[0].outputs[0]
        // Simulate an interrupted download: chop off the central directory.
        var data = try Data(contentsOf: zip)
        let cd = data.lastRange(of: Data([0x50, 0x4B, 0x01, 0x02]))!
        let firstCD = data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))!
        _ = cd
        data = data.prefix(firstCD.lowerBound + 10)
        let damaged = work.appendingPathComponent("damaged.zip")
        try data.write(to: damaged)

        let report = try service.test(damaged)
        XCTAssertEqual(report.result, .failed)
        let analysis = try service.analyzeDamage(damaged)
        XCTAssertTrue(analysis.isDamaged)
        XCTAssertTrue(analysis.canRebuildStructure)
        let rec = try service.recover(damaged, to: work)
        let rebuilt = try XCTUnwrap(rec.rebuiltArchive)
        XCTAssertEqual(try service.test(URL(fileURLWithPath: rebuilt)).result, .passed)
        XCTAssertEqual(rec.recovered.count, 11)
        XCTAssertEqual(TestFS.digestTree(URL(fileURLWithPath: rec.destination).appendingPathComponent("Sample")), TestFS.digestTree(tree))
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path), "damaged source is never modified")
    }

    func testSalvageSkipsCorruptEntry() throws {
        let src = work.appendingPathComponent("src")
        TestFS.write(src, "good1.txt", String(repeating: "good one ", count: 2000))
        TestFS.write(src, "bad.txt", String(repeating: "will be corrupted ", count: 2000))
        TestFS.write(src, "good2.txt", String(repeating: "good two ", count: 2000))
        var s = CompressionSettings(format: .zip)
        s.includeRootFolder = false
        let zip = try service.compress(CompressRequest(items: [src], destinationDirectory: work, archiveName: "salv", settings: s)).archives[0].outputs[0]
        var data = try Data(contentsOf: zip)
        let r = data.range(of: Data("bad.txt".utf8))!
        // Corrupt compressed bytes of bad.txt's data (just after its local header name).
        for i in (r.upperBound + 40)..<(r.upperBound + 60) { data[i] ^= 0xFF }
        try data.write(to: zip)
        let rec = try service.recover(zip, to: work, rebuildZip: false)
        XCTAssertEqual(Set(rec.recovered), ["good1.txt", "good2.txt"])
        XCTAssertEqual(rec.failed.map(\.path), ["bad.txt"])
    }

    func testSplitAndJoin() throws {
        var rng = SystemRandomNumberGenerator()
        let f = TestFS.writeBytes(work, "big.bin", Data((0..<250_000).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        let digest = try StreamingHasher.hashFile(at: f, algorithm: .sha256)
        let parts = work.appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        let r = try FileSplitter.split(f, partSize: 100_000, into: parts)
        XCTAssertEqual(r.parts.map(\.lastPathComponent), ["big.bin.001", "big.bin.002", "big.bin.003"])
        XCTAssertEqual(r.sha256, digest)
        let j = try FileSplitter.join(firstPart: r.parts[0])
        XCTAssertEqual(j.matchedManifest, true)
        XCTAssertEqual(try StreamingHasher.hashFile(at: j.output, algorithm: .sha256), digest)
        // A damaged part is detected by the manifest.
        try FileManager.default.removeItem(at: j.output)
        var d = try Data(contentsOf: r.parts[1]); d[10] ^= 1; try d.write(to: r.parts[1])
        XCTAssertThrowsError(try FileSplitter.join(firstPart: r.parts[0])) { XCTAssertEqual(($0 as? ArchiveError)?.code, "verification-failed") }
        try FileManager.default.removeItem(at: r.parts[2])
        XCTAssertThrowsError(try FileSplitter.join(firstPart: r.parts[0]))
        XCTAssertEqual(FileSplitter.parseSize("1.5 GB"), 1_500_000_000)
        XCTAssertEqual(FileSplitter.parseSize("4096K"), 4_096_000)
        XCTAssertEqual(FileSplitter.parseSize("1MiB"), 1_048_576)
    }

    func testChecksumManifestRoundTripAndTraversalSafety() throws {
        let a = TestFS.write(work, "a.txt", "alpha")
        let b = TestFS.write(work, "sub/b.txt", "beta")
        let text = try ChecksumManifest.generate(for: [a, b], base: work, algorithm: .sha256)
        let m = work.appendingPathComponent("SHA256SUMS.sha256")
        try (text + "0000000000000000000000000000000000000000000000000000000000000000  ../../etc/passwd\n").write(to: m, atomically: true, encoding: .utf8)
        let r = try ChecksumManifest.verify(manifest: m)
        XCTAssertEqual(Set(r.ok), ["a.txt", "sub/b.txt"])
        XCTAssertEqual(r.missing, ["../../etc/passwd"], "paths escaping the manifest folder are never read")
        let bsd = ChecksumManifest.parse("SHA256 (x y.txt) = ABCDEF")
        XCTAssertEqual(bsd.first?.path, "x y.txt")
        XCTAssertEqual(bsd.first?.algorithm, .sha256)
    }

    func testCompareAndDuplicates() throws {
        let s1 = work.appendingPathComponent("v1")
        TestFS.write(s1, "same.txt", "same")
        TestFS.write(s1, "changed.txt", "one")
        TestFS.write(s1, "removed.txt", "bye")
        TestFS.write(s1, "dup1.txt", "duplicate content")
        TestFS.write(s1, "dup2.txt", "duplicate content")
        let s2 = work.appendingPathComponent("v2")
        TestFS.write(s2, "same.txt", "same")
        TestFS.write(s2, "changed.txt", "two")
        TestFS.write(s2, "added.txt", "hi")
        var s = CompressionSettings(format: .zip)
        s.includeRootFolder = false
        let a = try service.compress(CompressRequest(items: [s1], destinationDirectory: work, archiveName: "a", settings: s)).archives[0].outputs[0]
        let b = try service.compress(CompressRequest(items: [s2], destinationDirectory: work, archiveName: "b", settings: CompressionSettings(format: .tarGzip, includeRootFolder: false))).archives[0].outputs[0]
        let c = try service.compare(a, b, mode: .content)
        XCTAssertEqual(c.added, ["added.txt"])
        XCTAssertEqual(Set(c.removed), ["removed.txt", "dup1.txt", "dup2.txt"])
        XCTAssertEqual(c.modified.map(\.path), ["changed.txt"])
        XCTAssertEqual(c.identical, ["same.txt"])
        XCTAssertTrue(c.csvReport.contains("added,\"added.txt\""))
        let dups = try service.findDuplicates(in: [a])
        XCTAssertEqual(dups.count, 1)
        XCTAssertEqual(Set(dups[0].members.map(\.path)), ["dup1.txt", "dup2.txt"])
    }

    func testContentSearchAndPreview() throws {
        let src = work.appendingPathComponent("s")
        TestFS.write(src, "notes/readme.md", "The quick brown FOX jumps")
        TestFS.write(src, "notes/other.txt", "nothing here")
        let zip = try service.compress(CompressRequest(items: [src], destinationDirectory: work, archiveName: "search", settings: CompressionSettings(format: .zip))).archives[0].outputs[0]
        XCTAssertEqual(try service.searchContents(zip, text: "fox"), ["s/notes/readme.md"])
        let preview = try service.extractForPreview(zip, entryPath: "s/notes/readme.md")
        XCTAssertEqual(try String(contentsOf: preview, encoding: .utf8), "The quick brown FOX jumps")
        let perms = (try FileManager.default.attributesOfItem(atPath: preview.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o400, "previews are read-only and never executable")
        PreviewCache.shared.clear()
    }

    func testPasswordTools() {
        let p = PasswordGenerator.generate(length: 24)
        XCTAssertEqual(p.count, 24)
        XCTAssertTrue(p.contains { $0.isUppercase } && p.contains { $0.isNumber })
        XCTAssertNotEqual(PasswordGenerator.generate(), PasswordGenerator.generate())
        XCTAssertEqual(PasswordStrength.evaluate("password").rating, .veryWeak)
        XCTAssertEqual(PasswordStrength.evaluate("123456789").rating, .veryWeak)
        XCTAssertGreaterThanOrEqual(PasswordStrength.evaluate(p).rating, .strong)
        XCTAssertGreaterThanOrEqual(PasswordStrength.evaluate(PasswordGenerator.passphrase()).rating, .strong)
        let store = InMemoryPasswordStore()
        try? store.save(Secret("x"), for: "k", label: "L", requireAuthentication: false)
        XCTAssertEqual(store.password(for: "k", prompt: nil), Secret("x"))
    }

    func testHistoryNeverStoresContents() throws {
        let h = ActivityHistory(fileURL: work.appendingPathComponent("history.json"))
        h.add(HistoryRecord(kind: .extract, inputs: ["/tmp/a.zip"], output: "/tmp/a", succeeded: true, summary: "3 files", duration: 1))
        XCTAssertEqual(h.all().count, 1)
        h.isEnabled = false
        h.add(HistoryRecord(kind: .extract, inputs: ["/tmp/b.zip"], output: nil, succeeded: true, summary: "", duration: 1))
        XCTAssertEqual(h.all().count, 1, "disabled history records nothing")
        h.clear()
        XCTAssertEqual(h.all().count, 0)
    }

    func testOperationCenterRunsAndCancels() throws {
        let center = OperationCenter(mode: .balanced)
        let done = expectation(description: "done")
        let op = center.enqueue("sleepy", kind: .test) { p in
            for _ in 0..<100 { try p.checkCancelled(); Thread.sleep(forTimeInterval: 0.02) }
            return "finished"
        }
        op.onChange = { o in if [.cancelled, .succeeded, .failed].contains(o.state) { done.fulfill() } }
        Thread.sleep(forTimeInterval: 0.1)
        op.pause()
        XCTAssertEqual(op.state, .paused)
        op.resume()
        op.cancel()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(op.state, .cancelled)
    }

    func testCapabilityMatrixIsHonest() {
        let rows = service.registry.capabilityMatrix()
        XCTAssertEqual(rows.count, FormatCatalog.all.count)
        // Formats with no engine must show no operations.
        for r in rows where r.engines.filter(\.available).isEmpty { XCTAssertTrue(r.availableOperations.isEmpty, r.format.rawValue) }
        let zip = rows.first { $0.format == .zip }!
        XCTAssertTrue(zip.availableOperations.isSuperset(of: [.extract, .create, .test]))
        // RAR creation only with the licensed tool.
        let rar = rows.first { $0.format == .rar }!
        XCTAssertEqual(rar.availableOperations.contains(.create), service.registry.engine(.rar)?.descriptor.isAvailable == true)
    }
}
