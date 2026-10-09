import XCTest
@testable import ArchiveCore
import UATestSupport

final class SafePathTests: XCTestCase {
    func testRejectsTraversal() {
        for bad in ["../evil", "a/../../evil", "..\\..\\evil.txt", "a/b/../../../x", "C:\\..\\x"] {
            XCTAssertThrowsError(try SafePath.components(of: bad), bad)
        }
    }

    func testAbsolutePathsBecomeRelative() throws {
        XCTAssertEqual(try SafePath.components(of: "/etc/passwd"), ["etc", "passwd"])
        XCTAssertEqual(try SafePath.components(of: "C:\\Windows\\x.dll"), ["Windows", "x.dll"])
        XCTAssertEqual(try SafePath.components(of: "./a//b/./c"), ["a", "b", "c"])
    }

    func testNulAndLongNames() {
        XCTAssertThrowsError(try SafePath.components(of: "a\u{0}b"))
        XCTAssertThrowsError(try SafePath.components(of: String(repeating: "x", count: 256)))
        XCTAssertNoThrow(try SafePath.components(of: String(repeating: "x", count: 255)))
    }

    func testLinkResolution() {
        XCTAssertEqual(SafePath.resolveLinkTarget("../b", linkParent: ["a", "x"]), ["a", "b"])
        XCTAssertNil(SafePath.resolveLinkTarget("../../..", linkParent: ["a"]))
        XCTAssertNil(SafePath.resolveLinkTarget("/etc/passwd", linkParent: []))
    }

    func testNormalization() throws {
        let nfd = "Cre\u{0300}me"
        XCTAssertEqual(try SafePath.components(of: nfd, normalization: .nfc), ["Crème"])
    }
}

final class GlobAndFilterTests: XCTestCase {
    func testGlob() {
        XCTAssertTrue(Glob.match("*.log", "debug.log"))
        XCTAssertFalse(Glob.match("*.log", "dir/debug.log"))
        XCTAssertTrue(Glob.match("**/*.log", "a/b/debug.log"))
        XCTAssertTrue(Glob.match("**/*.log", "debug.log"))
        XCTAssertTrue(Glob.match("file?.txt", "file1.txt"))
        XCTAssertTrue(Glob.match("[abc]*.swift", "bmain.swift"))
        XCTAssertFalse(Glob.match("[!abc]*.swift", "bmain.swift"))
        XCTAssertTrue(Glob.match("src/**", "src/a/b/c"))
    }

    func testFilterRules() {
        let f = FileFilter(rules: FileFilter.developerExclusions)
        XCTAssertTrue(f.prunes(FilterSubject(relativePath: "proj/node_modules", isDirectory: true)))
        XCTAssertTrue(f.prunes(FilterSubject(relativePath: "proj/.git", isDirectory: true)))
        XCTAssertFalse(f.includes(FilterSubject(relativePath: "proj/x.log", isDirectory: false)))
        XCTAssertTrue(f.includes(FilterSubject(relativePath: "proj/main.swift", isDirectory: false)))
        let inc = FileFilter(rules: [FilterRule(.include, .fileExtension(["jpg", "png"])), FilterRule(.exclude, .largerThan(1000))])
        XCTAssertTrue(inc.includes(FilterSubject(relativePath: "a.jpg", isDirectory: false, size: 10)))
        XCTAssertFalse(inc.includes(FilterSubject(relativePath: "a.txt", isDirectory: false, size: 10)))
        XCTAssertFalse(inc.includes(FilterSubject(relativePath: "a.png", isDirectory: false, size: 5000)))
        let re = FileFilter(rules: [FilterRule(.exclude, .regex("^build/.*\\.o$"))])
        XCTAssertFalse(re.includes(FilterSubject(relativePath: "build/x.o", isDirectory: false)))
    }

    func testCollectorReportsExclusions() throws {
        let dir = TestFS.tempDir("collect")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("P")
        TestFS.write(root, "a.txt", "a")
        TestFS.write(root, ".hidden", "h")
        TestFS.write(root, ".DS_Store", "x")
        TestFS.write(root, "node_modules/x.js", "x")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        var s = CompressionSettings(includeHidden: false, symlinks: .skip, filters: [FilterRule(.exclude, .glob("node_modules/"))])
        s.metadata = .crossPlatform
        let c = try SourceCollector.collect([root], settings: s)
        XCTAssertEqual(Set(c.items.map(\.archivePath)), ["P", "P/a.txt"])
        let reasons = Dictionary(c.excluded.map { ($0.path, $0.reason) }, uniquingKeysWith: { a, _ in a })
        XCTAssertNotNil(reasons["P/.hidden"])
        XCTAssertNotNil(reasons["P/.DS_Store"])
        XCTAssertNotNil(reasons["P/node_modules/"])
        XCTAssertNotNil(reasons["P/link"])
        var s2 = CompressionSettings()
        s2.includeRootFolder = false
        let c2 = try SourceCollector.collect([root], settings: s2)
        XCTAssertTrue(c2.items.contains { $0.archivePath == "a.txt" })
        XCTAssertTrue(c2.items.contains { $0.archivePath == "link" && $0.type == .symlink && $0.linkTarget == "a.txt" })
    }
}

final class DetectionTests: XCTestCase {
    func testCompoundExtensions() {
        XCTAssertEqual(FormatCatalog.matchExtension(of: "a.tar.gz")?.formats.first?.id, .tarGzip)
        XCTAssertEqual(FormatCatalog.matchExtension(of: "a.TGZ")?.formats.first?.id, .tarGzip)
        XCTAssertEqual(FormatCatalog.matchExtension(of: "x.tar.zst")?.formats.first?.id, .tarZstd)
        XCTAssertEqual(FormatCatalog.matchExtension(of: "x.tzst")?.formats.first?.id, .tarZstd)
        XCTAssertEqual(FormatCatalog.matchExtension(of: "x.Z")?.formats.first?.id, .unixCompress)
        XCTAssertEqual(FormatCatalog.matchExtension(of: "book.epub")?.formats.first?.id, .epub)
        XCTAssertNil(FormatCatalog.matchExtension(of: "noext"))
    }

    func testCatalogIsConsistent() {
        let ids = FormatCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate format ids")
        var seen: [String: FormatID] = [:]
        for d in FormatCatalog.all where d.kind != .package {
            for e in d.extensions {
                if let other = seen[e], other != d.id, !["bin", "img", "dd", "exe", "taz", "a"].contains(e) {
                    XCTFail("extension \(e) claimed by \(other) and \(d.id)")
                }
                seen[e] = d.id
            }
        }
    }

    func testContentBeatsMisleadingExtension() throws {
        let dir = TestFS.tempDir("detect")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A 7z signature in a file named .zip.
        let fake = dir.appendingPathComponent("really7z.zip")
        try Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4] + [UInt8](repeating: 0, count: 40)).write(to: fake)
        let r = try XCTUnwrap(FormatDetector.detect(fake))
        XCTAssertEqual(r.format, .sevenZip)
        XCTAssertEqual(r.basis, .content)
        // Gzip content with no extension is identified as gzip.
        let gz = dir.appendingPathComponent("data")
        try Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 3] + [UInt8](repeating: 0, count: 20)).write(to: gz)
        XCTAssertEqual(try FormatDetector.detect(gz)?.format, .gzip)
        // Unknown content, unknown extension.
        let txt = dir.appendingPathComponent("notes.qqq1")
        try Data("hello".utf8).write(to: txt)
        XCTAssertNil(try FormatDetector.detect(txt))
    }

    func testMultipartNaming() throws {
        let dir = TestFS.tempDir("mp")
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in ["b.part1.rar", "b.part2.rar", "b.part4.rar"] { TestFS.write(dir, n, "x") }
        let s = try XCTUnwrap(MultipartDetector.detect(dir.appendingPathComponent("b.part2.rar")))
        XCTAssertEqual(s.style, .rarParts)
        XCTAssertEqual(s.firstVolume.lastPathComponent, "b.part1.rar")
        XCTAssertEqual(s.missing, ["b.part3.rar"])

        for n in ["old.rar", "old.r00", "old.r01"] { TestFS.write(dir, n, "x") }
        let o = try XCTUnwrap(MultipartDetector.detect(dir.appendingPathComponent("old.r01")))
        XCTAssertEqual(o.volumes.map(\.lastPathComponent), ["old.rar", "old.r00", "old.r01"])
        XCTAssertNil(MultipartDetector.detect(dir.appendingPathComponent("single.rar")))

        for n in ["z.z01", "z.z02"] { TestFS.write(dir, n, "x") }
        let z = try XCTUnwrap(MultipartDetector.detect(dir.appendingPathComponent("z.z01")))
        XCTAssertEqual(z.missing, ["z.zip"], "the final .zip volume is required")

        for n in ["s.7z.001", "s.7z.002", "s.7z.003"] { TestFS.write(dir, n, "x") }
        let n = try XCTUnwrap(MultipartDetector.detect(dir.appendingPathComponent("s.7z.003")))
        XCTAssertEqual(n.firstVolume.lastPathComponent, "s.7z.001")
        XCTAssertTrue(n.isComplete)
        XCTAssertEqual(n.impliedFormat, .sevenZip)
        XCTAssertEqual(n.nextVolumeName, "s.7z.004")
    }
}

final class IntegrityTests: XCTestCase {
    func testKnownDigests() {
        let h = StreamingHasher(.sha256)
        h.update(Data("abc".utf8))
        XCTAssertEqual(h.finalizeHex(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let m = StreamingHasher(.md5)
        m.update(Data("abc".utf8))
        XCTAssertEqual(m.finalizeHex(), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF43926)
        let s5 = StreamingHasher(.sha512)
        s5.update(Data("abc".utf8))
        XCTAssertTrue(s5.finalizeHex().hasPrefix("ddaf35a193617aba"))
        XCTAssertFalse(HashAlgorithm.md5.isCollisionResistant)
        XCTAssertNotNil(HashAlgorithm.crc32.note)
    }
}

final class PresetTests: XCTestCase {
    func testExportContainsNoSecretsAndRoundTrips() throws {
        let data = try PresetStore.export(BuiltInPresets.all)
        func keys(_ v: Any) -> [String] {
            if let d = v as? [String: Any] { return d.keys + d.values.flatMap(keys) }
            if let a = v as? [Any] { return a.flatMap(keys) }
            return []
        }
        let allKeys = Set(keys(try JSONSerialization.jsonObject(with: data)).map { $0.lowercased() })
        XCTAssertTrue(allKeys.isDisjoint(with: ["password", "passphrase", "secret", "key"]), "presets must not serialise secrets: \(allKeys)")
        let back = try PresetStore.importPresets(from: data)
        XCTAssertEqual(back.count, BuiltInPresets.all.count)
        XCTAssertTrue(back.allSatisfy { !$0.isBuiltIn && !$0.id.hasPrefix("builtin.") })
        XCTAssertEqual(back.first { $0.name == "Secure" }?.settings.encryption?.method, .sevenZipAES256)
    }

    func testNamePattern() {
        let p = Preset(id: "x", name: "x", summary: "", settings: CompressionSettings(), namePattern: "{name} {date}")
        let d = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 3, day: 7).date!
        XCTAssertEqual(p.archiveBaseName(for: [URL(fileURLWithPath: "/tmp/Report.pdf")], date: d), "Report 2026-03-07")
        XCTAssertEqual(p.archiveBaseName(for: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")], date: d), "Archive 2026-03-07")
    }
}

final class AdvisorTests: XCTestCase {
    func testRecommendsStoreForCompressedMedia() throws {
        let dir = TestFS.tempDir("adv")
        defer { try? FileManager.default.removeItem(at: dir) }
        var rng = SystemRandomNumberGenerator()
        for i in 0..<5 { TestFS.writeBytes(dir, "IMG_\(i).jpg", Data((0..<200_000).map { _ in UInt8.random(in: 0...255, using: &rng) })) }
        let c = try SourceCollector.collect([dir], settings: CompressionSettings())
        let p = CompressionAdvisor.profile(c)
        XCTAssertGreaterThan(p.alreadyCompressedFraction, 0.9)
        let r = CompressionAdvisor.recommend(p)
        XCTAssertEqual(r.primary.settings.method, .store)
        XCTAssertTrue(r.basis.contains("sample"))
    }

    func testRecommends7zForText() throws {
        let dir = TestFS.tempDir("adv2")
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<20 { TestFS.write(dir, "src/file\(i).swift", String(repeating: "let value\(i) = compute(\(i)) // comment\n", count: 400)) }
        let c = try SourceCollector.collect([dir], settings: CompressionSettings())
        let p = CompressionAdvisor.profile(c)
        let r = CompressionAdvisor.recommend(p)
        XCTAssertEqual(r.primary.settings.format, .sevenZip)
        // The default (zlib) sampler measures Deflate only; other methods get no invented estimate.
        XCTAssertNil(r.primary.estimatedBytes)
        XCTAssertNotNil(r.alternatives.first { $0.settings.format == .zip }?.estimatedBytes)
        XCTAssertTrue(r.alternatives.contains { $0.settings.format == .zip })
        XCTAssertLessThan(p.measuredRatio(.deflate) ?? 1, 0.2, "text measured as highly compressible")
    }
}

final class ProgressTests: XCTestCase {
    func testPauseBlocksAndCancelReleases() throws {
        let p = OperationProgress()
        p.pause()
        let exp = expectation(description: "released")
        DispatchQueue.global().async {
            do { try p.checkCancelled(); XCTFail("should throw") } catch { exp.fulfill() }
        }
        Thread.sleep(forTimeInterval: 0.3)
        p.cancel()
        wait(for: [exp], timeout: 3)
    }
}
