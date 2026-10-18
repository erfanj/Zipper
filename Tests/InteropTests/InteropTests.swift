import XCTest
import ArchiveCore
import ArchiveEngines
@testable import ArchiverKit
import UATestSupport

/// Archives created by independent reference tools (see Scripts/make-interop-fixtures.sh) must be
/// opened, tested and extracted with byte-identical results.
final class ForwardInteropTests: XCTestCase {
    struct Manifest: Decodable {
        struct Fixture: Decodable {
            var file: String
            var format: String
            var payload: String
            var password: String?
            var encoding: String?
            var note: String?
        }
        var fixtures: [Fixture]
    }

    static let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Interop")

    func expected(_ payload: String) -> [String: String]? {
        let r = Self.root
        func digests(_ dir: URL, prefix: String) -> [String: String] {
            Dictionary(TestFS.digestTree(dir).map { (prefix + $0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        func sha(_ data: Data) -> String { let h = StreamingHasher(.sha256); h.update(data); return h.finalizeHex() }
        switch payload {
        case "unicode", "image-unicode": return digests(r.appendingPathComponent("payload-unicode/payload"), prefix: payload == "unicode" ? "payload/" : "")
        case "simple": return digests(r.appendingPathComponent("payload-simple/simple"), prefix: "simple/")
        case "flat-simple": return digests(r.appendingPathComponent("payload-simple/simple"), prefix: "")
        default:
            if payload.hasPrefix("single:") {
                let name = String(payload.dropFirst(7))
                let src = name == "big.bin" ? r.appendingPathComponent("payload-unicode/big.bin") : r.appendingPathComponent("payload-single/notes.txt")
                return [name: (try? StreamingHasher.hashFile(at: src, algorithm: .sha256)) ?? ""]
            }
            if payload.hasPrefix("raw:") {
                let parts = payload.dropFirst(4).split(separator: "=", maxSplits: 1)
                return [String(parts[0]).precomposedStringWithCanonicalMapping: sha(Data(String(parts[1]).replacingOccurrences(of: "\\n", with: "\n").utf8))]
            }
            if payload.hasPrefix("disk-of:") {
                // 7-Zip presents a virtual disk's contents; verifying the FAT files inside is enough.
                return digests(r.appendingPathComponent("payload-simple/simple"), prefix: "")
            }
            return nil // verify-only, deb, epub: structural checks below
        }
    }

    func testAllReferenceFixtures() throws {
        let manifestURL = Self.root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw XCTSkip("Run Scripts/make-interop-fixtures.sh first") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let service = ArchiveService()
        let work = TestFS.tempDir("interop")
        defer { try? FileManager.default.removeItem(at: work) }
        var rows: [String] = []
        var passed = 0, missing = 0
        for fx in manifest.fixtures {
            let url = Self.root.appendingPathComponent(fx.file)
            guard FileManager.default.fileExists(atPath: url.path) else { missing += 1; rows.append("SKIP  \(fx.file) (not generated on this machine)"); continue }
            let ro = ReadOptions(passwordProvider: fx.password.map { FixedPasswordProvider($0) }, filenameEncoding: fx.encoding)
            do {
                let opened = try service.open(url, options: ro)
                let report = try service.test(url, options: ro)
                guard report.result == .passed else { throw FixtureFailure(report: report) }
                let dest = work.appendingPathComponent(UUID().uuidString)
                let o = try service.extract(ExtractRequest(archive: url, destination: dest, mode: .here, readOptions: ro))
                let got = Dictionary(TestFS.digestTree(dest).map { ($0.key.precomposedStringWithCanonicalMapping, $0.value) }, uniquingKeysWith: { a, _ in a })
                if let exp = expected(fx.payload) {
                    let expN = Dictionary(exp.map { ($0.key.precomposedStringWithCanonicalMapping, $0.value) }, uniquingKeysWith: { a, _ in a })
                    // Disk images may contain extra system files (lost+found, $MFT…); everything expected must match.
                    for (path, digest) in expN {
                        // Some legacy formats upper/lower-case names; compare case-insensitively when exact match fails.
                        let match = got[path] ?? got.first { $0.key.lowercased() == path.lowercased() || $0.key.hasSuffix("/" + path) }?.value
                        guard match == digest else {
                            throw ArchiveError.verificationFailed(details: "\(path): \(match == nil ? "missing" : "content differs"); got \(got.keys.sorted().prefix(12))")
                        }
                    }
                } else if fx.payload == "verify-only" {
                    guard o.report.filesWritten > 0 else { throw ArchiveError.verificationFailed(details: "nothing extracted") }
                } else if fx.payload == "deb" {
                    guard opened.listing.entries.contains(where: { $0.path.hasPrefix("control.tar") }), opened.listing.entries.contains(where: { $0.path.hasPrefix("data.tar") }) else {
                        throw ArchiveError.verificationFailed(details: "deb members missing")
                    }
                } else if fx.payload == "epub" {
                    guard got["mimetype"] != nil, got["META-INF/container.xml"] != nil else { throw ArchiveError.verificationFailed(details: "epub structure") }
                }
                passed += 1
                rows.append("PASS  \(fx.file.padding(toLength: 34, withPad: " ", startingAt: 0)) \(opened.engine.rawValue)/\(o.engine.rawValue)\(fx.note.map { "  (\($0))" } ?? "")")
            } catch {
                let failure = error as? FixtureFailure
                let e = failure?.error ?? ArchiveError.wrap(error)
                if let reason = Self.missingHelper(for: fx, error: e, codes: failure?.codes ?? [e.code]) {
                    missing += 1
                    rows.append("SKIP  \(fx.file) (\(reason))")
                    continue
                }
                rows.append("FAIL  \(fx.file): \(e)")
                XCTFail("\(fx.file): \(e)")
            }
        }
        print("Interop results: \(passed) passed, \(missing) skipped, \(manifest.fixtures.count - passed - missing) failed\n" + rows.joined(separator: "\n"))
    }

    /// A failed integrity test, keeping the issue codes.
    struct FixtureFailure: Error {
        let report: IntegrityReport
        var codes: Set<String> { Set(report.issues.map(\.code)) }
        var error: ArchiveError { .verificationFailed(details: report.issues.map(\.message).joined(separator: "; ")) }
    }

    static let sevenZip = SevenZipEngine()

    /// Fixtures that need an optional helper this machine doesn't have are skipped with the reason,
    /// never reported as passed (a missing tool is not a defect in Zipper).
    static func missingHelper(for fx: Manifest.Fixture, error: ArchiveError, codes: Set<String>) -> String? {
        if case .noEngineAvailable = error { return "no engine for this format is installed" }
        // Encrypted 7z and 7-Zip-only methods such as Deflate64 need 7-Zip; libarchive can't decode them.
        if !sevenZip.descriptor.isAvailable, !codes.isDisjoint(with: ["unsupported-encryption", "unsupported-method"]) {
            return "needs 7-Zip: \(sevenZip.descriptor.unavailableReason ?? "not installed")"
        }
        if fx.format == "rar", !hasRarCodec { return "7-Zip's RAR codec is not installed (Linux: 7zip-rar)" }
        if fx.format == "arc", HelperLocator.find(["nomarch"]) == nil { return "nomarch is not installed" }
        return nil
    }

    /// Whether the installed 7-Zip can decode RAR (codec 40305, Rar5). Distribution builds of 7-Zip
    /// often ship the RAR codec separately; the official macOS 7zz bundled with Zipper includes it.
    static let hasRarCodec: Bool = {
        guard let exe = TestFS.sevenZip else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["i"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("40305")
    }()

    func testLegacyFilenameEncodingOverride() throws {
        let url = Self.root.appendingPathComponent("zip/legacy-shiftjis.zip")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let service = ArchiveService()
        let auto = try service.open(url).listing.entries.first?.path
        XCTAssertNotEqual(auto, "日本語.txt", "without a hint the bytes are not Shift-JIS-decoded")
        let fixed = try service.open(url, options: ReadOptions(filenameEncoding: "CP932")).listing.entries.first?.path
        XCTAssertEqual(fixed, "日本語.txt")
        let cp437 = try service.open(Self.root.appendingPathComponent("zip/legacy-cp437.zip")).listing.entries.first?.path
        XCTAssertEqual(cp437, "Café.txt", "ZIP's default code page 437 is decoded automatically")
    }
}

/// Archives created by Zipper must be readable by independent tools.
final class ReverseInteropTests: XCTestCase {
    let service = ArchiveService()
    var work: URL!
    var tree: URL!
    override func setUp() {
        work = TestFS.tempDir("rev")
        tree = TestFS.sampleTree(in: work.appendingPathComponent("src"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: work) }

    func make(_ s: CompressionSettings, password: String? = nil) throws -> URL {
        try service.compress(CompressRequest(items: [tree], destinationDirectory: work, settings: s, password: password.map(Secret.init))).archives[0].outputs[0]
    }

    func assertSameTree(_ dir: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(TestFS.digestTree(dir.appendingPathComponent("Sample")), TestFS.digestTree(tree), file: file, line: line)
    }

    /// Acceptance test 19 (proxy): Info-ZIP unzip and Python's zipfile read our ZIPs; names use the UTF-8 flag.
    func testZipReadByInfoZipAndPython() throws {
        let zip = try make(CompressionSettings(format: .zip))
        if let unzip = TestFS.which("unzip") {
            let (rc, out) = try TestFS.run(unzip, ["-t", zip.path])
            XCTAssertEqual(rc, 0, out)
            let dest = work.appendingPathComponent("unzip")
            let (rc2, out2) = try TestFS.run(unzip, ["-q", zip.path, "-d", dest.path])
            XCTAssertEqual(rc2, 0, out2)
            assertSameTree(dest)
        }
        // Every non-ASCII entry name must carry the language-encoding (UTF-8) flag, which Windows
        // Explorer and macOS Archive Utility require to show names correctly.
        let py = """
        import zipfile, sys
        z = zipfile.ZipFile(sys.argv[1])
        bad = [i.filename for i in z.infolist() if not i.filename.isascii() and not (i.flag_bits & 0x800)]
        assert not bad, bad
        assert all(i.compress_type in (0, 8) for i in z.infolist()), "only Store/Deflate for maximum compatibility"
        assert z.testzip() is None
        print(len(z.infolist()))
        """
        let (rc, out) = try TestFS.run("/usr/bin/python3", ["-I", "-c", py, zip.path])
        XCTAssertEqual(rc, 0, out)
    }

    /// Acceptance test 4: AES-256 ZIP decrypted by an independent implementation (7-Zip).
    func testAESZipDecryptedBy7Zip() throws {
        guard let sevenZ = TestFS.sevenZip else { throw XCTSkip("7-Zip 21 or later is not installed") }
        // Created with libarchive specifically (7-Zip would be testing itself).
        service.registry.preferred[.zip] = .libarchive
        let zip = try make(CompressionSettings(format: .zip, encryption: .init(method: .zipAES256)), password: "Ünïcode-pässwörd")
        let (rcl, list) = try TestFS.run(sevenZ, ["l", "-slt", zip.path])
        XCTAssertEqual(rcl, 0, list)
        XCTAssertTrue(list.contains("AES-256"), list)
        let dest = work.appendingPathComponent("7z")
        // No -p switch: a bare "-p" means an empty password; 7-Zip prompts and reads stdin instead.
        let (rc, out) = try TestFS.run(sevenZ, ["x", "-y", "-o" + dest.path, zip.path], stdin: "Ünïcode-pässwörd\n")
        XCTAssertEqual(rc, 0, out)
        assertSameTree(dest)
        let (rcw, _) = try TestFS.run(sevenZ, ["t", zip.path], stdin: "wrong\n")
        XCTAssertNotEqual(rcw, 0, "wrong password must fail")
    }

    func test7zReadBy7Zip() throws {
        guard let sevenZ = TestFS.sevenZip else { throw XCTSkip("7-Zip 21 or later is not installed") }
        for engine in [EngineID.libarchive, .sevenZip] {
            service.registry.preferred[.sevenZip] = engine
            let a = try make(CompressionSettings(format: .sevenZip, method: .lzma2))
            let (rc, out) = try TestFS.run(sevenZ, ["t", a.path])
            XCTAssertEqual(rc, 0, "\(engine): \(out)")
            try FileManager.default.removeItem(at: a)
        }
    }

    func testTarballsReadByGNUTar() throws {
        guard let tar = TestFS.which("tar") else { throw XCTSkip("tar missing") }
        let cases: [(FormatID, [String])] = [(.tar, []), (.tarGzip, ["-z"]), (.tarBzip2, ["-j"]), (.tarXz, ["-J"]), (.tarZstd, ["--zstd"]), (.tarLzip, ["--lzip"]), (.tarLzma, ["--lzma"])]
        for (f, flag) in cases {
            if f == .tarLzip, TestFS.which("lzip") == nil { continue }
            let a = try make(CompressionSettings(format: f))
            let dest = work.appendingPathComponent("gnutar-\(f.rawValue)")
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let (rc, out) = try TestFS.run(tar, ["-x"] + flag + ["-f", a.path, "-C", dest.path])
            XCTAssertEqual(rc, 0, "\(f): \(out)")
            assertSameTree(dest)
            try FileManager.default.removeItem(at: a)
        }
    }

    func testStreamsVerifiedByReferenceDecoders() throws {
        let file = tree.appendingPathComponent("readme.txt")
        let cases: [(FormatID, String, [String])] = [(.gzip, "gzip", ["-t"]), (.bzip2, "bzip2", ["-t"]), (.xz, "xz", ["-t"]), (.zstd, "zstd", ["-t", "-q"]),
                                                     (.lz4, "lz4", ["-t", "-q"]), (.brotli, "brotli", ["-t"]), (.lzip, "lzip", ["-t"]), (.lzma, "xz", ["-t", "--format=lzma"])]
        for (f, tool, args) in cases {
            guard let t = TestFS.which(tool) else { continue }
            if f == .lzip, service.creationOptions(for: .lzip).canCreate == false { continue }
            let a = try service.compress(CompressRequest(items: [file], destinationDirectory: work, settings: CompressionSettings(format: f))).archives[0].outputs[0]
            let (rc, out) = try TestFS.run(t, args + [a.path])
            XCTAssertEqual(rc, 0, "\(f) via \(tool): \(out)")
            try FileManager.default.removeItem(at: a)
        }
    }

    func testSplit7zReadBy7Zip() throws {
        guard let sevenZ = TestFS.sevenZip, service.registry.engine(.sevenZip)?.descriptor.isAvailable == true else { throw XCTSkip("7-Zip missing") }
        // Store (level 0) so the size is predictable: the sample data compresses extremely well.
        var s = CompressionSettings(format: .sevenZip, level: 0)
        s.splitVolumeSize = 50_000
        let o = try service.compress(CompressRequest(items: [tree], destinationDirectory: work, settings: s))
        XCTAssertGreaterThan(o.archives[0].outputs.count, 1)
        let (rc, out) = try TestFS.run(sevenZ, ["t", o.archives[0].outputs[0].path])
        XCTAssertEqual(rc, 0, out)
    }

    func testEpubIsValidPerOCF() throws {
        let book = work.appendingPathComponent("Book")
        TestFS.write(book, "mimetype", "application/epub+zip")
        TestFS.write(book, "META-INF/container.xml", "<container/>")
        TestFS.write(book, "OEBPS/content.opf", "<package/>")
        var s = CompressionSettings(format: .epub)
        s.includeRootFolder = false
        let epub = try service.compress(CompressRequest(items: [book], destinationDirectory: work, settings: s)).archives[0].outputs[0]
        let py = """
        import zipfile, sys, struct
        d = open(sys.argv[1], 'rb').read()
        sig, ver, flag, meth, t, dt, crc, cs, us, nl, el = struct.unpack('<IHHHHHIIIHH', d[:30])
        assert d[30:30+nl] == b'mimetype', d[30:30+nl]
        assert meth == 0 and el == 0 and not (flag & 8), (meth, el, flag)
        assert d[30+nl:30+nl+20] == b'application/epub+zip'
        z = zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None
        """
        let (rc, out) = try TestFS.run("/usr/bin/python3", ["-I", "-c", py, epub.path])
        XCTAssertEqual(rc, 0, out)
        if let unzip = TestFS.which("unzip") { XCTAssertEqual(try TestFS.run(unzip, ["-t", epub.path]).0, 0) }
    }

    /// Acceptance test 18 (portable part): permissions, symlinks and modification times survive a
    /// TAR round trip, and are readable by GNU tar.
    func testMetadataPreservationInTar() throws {
        let src = work.appendingPathComponent("meta/M")
        let script = TestFS.write(src, "run.sh", "#!/bin/sh\necho hi\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: script.path)
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: script.path)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("link").path, withDestinationPath: "run.sh")
        let a = try service.compress(CompressRequest(items: [src], destinationDirectory: work, settings: CompressionSettings(format: .tarXz, metadata: .macPreservation))).archives[0].outputs[0]
        let dest = work.appendingPathComponent("metaout")
        _ = try service.extract(ExtractRequest(archive: a, destination: dest))
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent("M/run.sh").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o750)
        XCTAssertEqual((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, old.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("M/link").path), "run.sh")
        if let tar = TestFS.which("tar") {
            let (rc, out) = try TestFS.run(tar, ["-tvJf", a.path])
            XCTAssertEqual(rc, 0, out)
            XCTAssertTrue(out.contains("rwxr-x---"), out)
            XCTAssertTrue(out.contains("link -> run.sh"), out)
        }
    }
}
