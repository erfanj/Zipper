import XCTest
import UATestSupport

/// Runs the real `zipper` executable (built next to the test bundle) the way a user would.
final class CLITests: XCTestCase {
    var dir: URL!
    var src: URL!

    static var binary: URL? {
        #if os(macOS)
        let products = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?.bundleURL.deletingLastPathComponent()
        #else
        let products: URL? = Bundle.main.bundleURL
        #endif
        guard let u = products?.appendingPathComponent("zipper"), FileManager.default.isExecutableFile(atPath: u.path) else { return nil }
        return u
    }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.binary == nil, "the zipper executable isn't built next to the tests")
        dir = TestFS.tempDir("cli")
        src = TestFS.sampleTree(in: dir, name: "src")
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    @discardableResult
    func zipper(_ args: String..., stdin: String? = nil) throws -> (code: Int32, output: String) {
        let p = Process()
        p.executableURL = Self.binary
        p.arguments = args
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let input = Pipe()
        p.standardInput = input
        try p.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func sha(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    // MARK: --force never loses data

    func testForceDoesNotDeleteTheExistingArchiveWhenCompressionFails() throws {
        try zipper("compress", "src", "-o", "keep.zip")
        let keep = dir.appendingPathComponent("keep.zip")
        let before = try sha(keep)
        let r = try zipper("compress", "missing-input", "-o", "keep.zip", "--force")
        XCTAssertEqual(r.code, 8, r.output)
        XCTAssertEqual(try sha(keep), before, "the existing archive must survive a failed --force")
    }

    func testForceNeverDeletesAFolder() throws {
        let folder = dir.appendingPathComponent("important")
        _ = TestFS.write(folder, "thesis.txt", "do not lose me")
        let r = try zipper("compress", "src", "-o", "important", "--force")
        XCTAssertEqual(r.code, 2, r.output)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("thesis.txt"), encoding: .utf8), "do not lose me")
    }

    func testForceReplacesAFileAndAStaleSplitSet() throws {
        try zipper("compress", "src", "-o", "out.zip")
        let r = try zipper("compress", "src/readme.txt", "-o", "out.zip", "--force")
        XCTAssertEqual(r.code, 0, r.output)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("out") }
        XCTAssertEqual(names, ["out.zip"], "replaced in place, no “out 2.zip” left behind")
        XCTAssertTrue(try zipper("list", "out.zip").output.contains("readme.txt"))
    }

    func testWithoutForceAnExistingOutputIsAnError() throws {
        try zipper("compress", "src", "-o", "out.zip")
        XCTAssertEqual(try zipper("compress", "src", "-o", "out.zip").code, 8)
    }

    // MARK: Invalid values are rejected, never silently replaced

    func testInvalidOptionValuesAreUsageErrors() throws {
        let cases: [[String]] = [
            ["compress", "src", "-o", "a.zip", "--threads", "abc"],
            ["compress", "src", "-o", "a.zip", "--threads", "0"],
            ["compress", "src", "-o", "a.7z", "--word-size", "big"],
            ["compress", "src", "-o", "a.zip", "--performance", "turbo"],
            ["compress", "src", "-o", "a.zip", "--level", "12"],
            ["extract", "nothing.zip", "--max-size", "lots"],
            ["hash", "src/readme.txt", "--algo", "sha3"],
            ["advise", "src", "--intent", "nonsense"],
            ["genpass", "--length", "abc"],
            ["genpass", "--length", "0"],
            ["genpass", "--passphrase", "--length", "2"],
            ["extract", "x.zip", "--password", "hunter2"],
        ]
        for c in cases {
            let p = Process()
            p.executableURL = Self.binary
            p.arguments = c
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 2, "zipper \(c.joined(separator: " "))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.zip").path))
    }

    /// A mistyped option used to be ignored: `--encypt aes256` made an archive with no password,
    /// `--hide-name` left the names readable, and `-d out` extracted into the current folder.
    func testUnknownOptionsStopTheCommand() throws {
        let cases: [(args: [String], hint: String?)] = [
            (["compress", "src", "-o", "a.zip", "--encypt", "aes256"], "--encrypt"),
            (["compress", "src", "-o", "a.7z", "--hide-name"], "--hide-names"),
            (["compress", "src", "-o", "a.zip", "--verfy"], "--verify"),
            (["compress", "src", "-o", "a.zip", "--no-hiden"], "--no-hidden"),
            (["extract", "nothing.zip", "-d", "out"], nil),
            (["extract", "nothing.zip", "--overwrite"], nil),
            (["extract", "nothing.zip", "--verify=yes"], nil),
            (["list", "nothing.zip", "--bogus"], nil),
        ]
        for c in cases {
            let p = Process()
            p.executableURL = Self.binary
            p.arguments = c.args
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            let err = Pipe()
            p.standardError = err
            try p.run()
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 2, "zipper \(c.args.joined(separator: " ")): \(text)")
            if let hint = c.hint { XCTAssertTrue(text.contains("Did you mean \(hint)?"), "zipper \(c.args.joined(separator: " ")): \(text)") }
        }
        let made = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("a.") || $0 == "out" }
        XCTAssertEqual(made, [], "nothing is created by a command that was refused")

        // --help after a command shows the usage, and a name that starts with a dash still works after "--".
        let help = try zipper("extract", "--help")
        XCTAssertEqual(help.code, 0)
        XCTAssertTrue(help.output.contains("Usage:"))
        try Data("dash".utf8).write(to: dir.appendingPathComponent("-x"))
        let dashed = try zipper("compress", "-o", "dash.zip", "--", "-x")
        XCTAssertEqual(dashed.code, 0, dashed.output)
    }

    func testValidSpellingsStillWork() throws {
        XCTAssertEqual(try zipper("compress", "src", "-o", "p.zip", "--performance", "energy-saver", "--threads", "2").code, 0)
        let h = try zipper("hash", "src/readme.txt", "--algo", "SHA-512")
        XCTAssertEqual(h.code, 0, h.output)
        XCTAssertEqual(h.output.split(separator: " ").first?.count, 128)
    }

    // MARK: Folders where a file is expected

    func testFoldersAreReportedNotCrashedOn() throws {
        for args in [["list", "src"], ["test", "src"], ["info", "src"], ["extract", "src"], ["convert", "src", "--to", "7z"],
                     ["repair", "src"], ["analyze", "src"], ["duplicates", "src"], ["edit", "src", "--mkdir", "x"],
                     ["hash", "src"], ["split", "src", "--size", "1MB"]] {
            let p = Process()
            p.executableURL = Self.binary
            p.arguments = args
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationReason, .exit, "zipper \(args.joined(separator: " ")) crashed")
            XCTAssertNotEqual(p.terminationStatus, 0, "zipper \(args.joined(separator: " "))")
        }
    }

    // MARK: Extraction selection

    func testOnlyWithAPathThatIsNotInTheArchiveFailsAndLeavesNothing() throws {
        try zipper("compress", "src", "-o", "s.zip")
        let r = try zipper("extract", "s.zip", "-o", "out", "--only", "no/such/file")
        XCTAssertEqual(r.code, 2, r.output)
        let out = dir.appendingPathComponent("out")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? [], [])
    }

    // MARK: Round trip and exit codes

    func testCompressExtractRoundTripAndExitCodes() throws {
        XCTAssertEqual(try zipper("compress", "src", "-o", "r.7z", "--verify").code, 0)
        XCTAssertEqual(try zipper("extract", "r.7z", "-o", "x").code, 0)
        XCTAssertEqual(TestFS.digestTree(src), TestFS.digestTree(dir.appendingPathComponent("x/src")))
        XCTAssertEqual(try zipper("test", "r.7z").code, 0)
        XCTAssertEqual(try zipper("bogus-command").code, 2)
        XCTAssertEqual(try zipper("list", "missing.zip").code, 8)
    }
}
