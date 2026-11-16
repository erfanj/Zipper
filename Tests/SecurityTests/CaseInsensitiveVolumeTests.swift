import XCTest
import Foundation
import ArchiveCore
import ArchiveEngines
@testable import ArchiverKit
import UATestSupport

/// A Mac's disk is case-insensitive by default: "Readme.txt" and "README.TXT" are one file there,
/// though an archive made on Linux can hold both. These tests run wherever the test folder is
/// case-insensitive: on a Mac always, on Linux when UA_CASE_INSENSITIVE_DIR names such a mount.
final class CaseInsensitiveVolumeTests: XCTestCase {
    var sandbox: URL!
    var dest: URL!
    let service = ArchiveService()
    let fm = FileManager.default

    override func setUpWithError() throws {
        guard let dir = TestFS.caseInsensitiveDir("vol") else {
            throw XCTSkip("needs a case-insensitive volume (a Mac, or UA_CASE_INSENSITIVE_DIR)")
        }
        sandbox = dir
        dest = sandbox.appendingPathComponent("dest", isDirectory: true)
    }

    override func tearDown() { if let sandbox { try? fm.removeItem(at: sandbox) } }

    /// Contents of every regular file below `root`, whatever it ended up being called.
    func contents(of root: URL) -> [String] {
        var out: [String] = []
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            if let s = try? String(contentsOf: url, encoding: .utf8) { out.append(s) }
        }
        return out.sorted()
    }

    func collidingTar() throws -> URL {
        var tar = TarBuilder()
        tar.add("Readme.txt", content: "first")
        tar.add("README.TXT", content: "second")
        tar.add("readme.txt", content: "third")
        tar.add("Docs/", kind: .directory)
        tar.add("Docs/a.txt", content: "in Docs")
        tar.add("docs/a.txt", content: "in docs")
        tar.add("docs/b.txt", content: "only in docs")
        let url = sandbox.appendingPathComponent("Colliding.tar")
        try tar.write(to: url)
        return url
    }

    func testNamesThatDifferOnlyByCaseAreAllExtracted() throws {
        let archive = try collidingTar()
        for mode in [ExtractionMode.here, .newFolder, .smart] {
            try? fm.removeItem(at: dest)
            let o = try service.extract(ExtractRequest(archive: archive, destination: dest, mode: mode))
            XCTAssertEqual(contents(of: dest), ["first", "in Docs", "in docs", "only in docs", "second", "third"],
                           "\(mode): every file's data must be on disk, none overwritten by a same-name sibling")
            XCTAssertEqual(o.report.filesWritten, 6, "\(mode)")
            XCTAssertGreaterThanOrEqual(o.report.renamed.count, 3, "\(mode): the renames are reported: \(o.report.renamed)")
        }
    }

    func testVerificationUnderstandsTheRenames() throws {
        let o = try service.extract(ExtractRequest(archive: try collidingTar(), destination: dest, mode: .here, verifyAfterExtraction: true))
        XCTAssertEqual(contents(of: dest).count, 6)
        XCTAssertEqual(o.verification?.passed, true, "every file was written correctly, under another name: \(o.verification?.mismatches ?? [])")
    }

    func testExistingFilesAreProtectedWhateverTheirCase() throws {
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: dest.appendingPathComponent("NOTES.TXT"))
        var tar = TarBuilder()
        tar.add("notes.txt", content: "from the archive")
        let archive = sandbox.appendingPathComponent("n.tar")
        try tar.write(to: archive)

        _ = try service.extract(ExtractRequest(archive: archive, destination: dest, mode: .here))   // keep both
        XCTAssertEqual(contents(of: dest), ["from the archive", "mine"])

        var skip = ExtractionOptions()
        skip.conflictPolicy = .skip
        let skipped = try service.extract(ExtractRequest(archive: archive, destination: dest, mode: .here, options: skip))
        XCTAssertEqual(skipped.report.filesWritten, 0)
        XCTAssertEqual(contents(of: dest), ["from the archive", "mine"])

        var replace = ExtractionOptions()
        replace.conflictPolicy = .replace
        _ = try service.extract(ExtractRequest(archive: archive, destination: dest, mode: .here, options: replace))
        XCTAssertTrue(contents(of: dest).contains("from the archive"))
        XCTAssertFalse(contents(of: dest).contains("mine"), "Replace replaces the same-named file")
    }

    /// The classic case-insensitive attack: create a link called "Up", then write to "up/…".
    func testALinkCannotBeWrittenThroughUnderAnotherSpelling() throws {
        let outside = sandbox.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        var tar = TarBuilder()
        tar.add("Up", kind: .symlink, link: outside.path)
        tar.add("up/pwned.txt", content: "written through the link")
        tar.add("UP/pwned2.txt", content: "written through the link")
        tar.add("Inner", kind: .symlink, link: "target")
        tar.add("target/", kind: .directory)
        tar.add("INNER/through.txt", content: "through an inside link")
        let archive = sandbox.appendingPathComponent("attack.tar")
        try tar.write(to: archive)
        for policy in [ExtractionLinkPolicy.preserveSafe, .preserveAll] {
            try? fm.removeItem(at: dest)
            var options = ExtractionOptions()
            options.linkPolicy = policy
            _ = try service.extract(ExtractRequest(archive: archive, destination: dest, mode: .here, options: options))
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), [], "\(policy): something was written through the link")
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: dest.appendingPathComponent("target").path), [],
                           "\(policy): writes never follow links, even ones that stay inside")
        }
    }

    // MARK: Editing

    func makeZip(_ files: [String: String], name: String = "edit.zip") throws -> URL {
        let src = sandbox.appendingPathComponent("src-\(UUID().uuidString.prefix(6))")
        for (p, c) in files { _ = TestFS.write(src, p, c) }
        var s = CompressionSettings(format: .zip)
        s.includeRootFolder = false
        _ = try service.compress(CompressRequest(items: [src], destinationDirectory: sandbox,
                                                 archiveName: (name as NSString).deletingPathExtension, settings: s))
        return sandbox.appendingPathComponent(name)
    }

    func names(_ archive: URL) throws -> [String] {
        try service.open(archive).listing.entries.filter { $0.type == .file }.map(\.normalizedPath).sorted()
    }

    func testRenamingOnlyTheCaseOfAnEntryWorks() throws {
        let zip = try makeZip(["report.txt": "r", "other.txt": "o"])
        _ = try service.modify(ModifyRequest(archive: zip, edits: [.rename(path: "report.txt", newName: "Report.TXT")]))
        XCTAssertEqual(try names(zip), ["Report.TXT", "other.txt"])
        // A real clash is still refused.
        XCTAssertThrowsError(try service.modify(ModifyRequest(archive: zip, edits: [.rename(path: "other.txt", newName: "REPORT.txt")])))
        XCTAssertEqual(try names(zip), ["Report.TXT", "other.txt"])
    }

    func testAnArchiveWithCollidingNamesIsNotSilentlyRewritten() throws {
        let archive = try collidingTar()
        let before = try Data(contentsOf: archive)
        let extra = TestFS.write(sandbox, "extra.txt", "extra")
        XCTAssertThrowsError(try service.modify(ModifyRequest(archive: archive, edits: [.add(files: [extra], toFolder: "")]))) { e in
            guard case .conflictingNames(let first, let second)? = e as? ArchiveError else { return XCTFail("expected a clear reason, got \(e)") }
            XCTAssertNotEqual(first, second)
            XCTAssertEqual(first.lowercased(), second.lowercased())
            XCTAssertTrue((e as? ArchiveError)?.explanation.contains("upper and lower case") == true)
        }
        XCTAssertEqual(try Data(contentsOf: archive), before, "the archive is untouched")
    }

    func testConvertingAnArchiveWithCollidingNamesFailsClearlyAndLeavesNothing() throws {
        let archive = try collidingTar()
        let out = sandbox.appendingPathComponent("converted", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            let o = try service.convert(ConvertRequest(archive: archive, settings: CompressionSettings(format: .zip), destinationDirectory: out))
            // If it does convert, every entry must be there under its own name.
            let listed = try service.open(try XCTUnwrap(o.created.outputs.first)).listing.entries.filter { $0.type == .file }
            XCTAssertEqual(listed.count, 6)
            XCTAssertTrue(listed.contains { $0.normalizedPath == "README.TXT" } && listed.contains { $0.normalizedPath == "readme.txt" },
                          "a conversion must not rename entries: \(listed.map(\.normalizedPath))")
        } catch {
            let text = (error as? ArchiveError)?.explanation ?? "\(error)"
            XCTAssertTrue(text.contains("upper and lower case"), "the reason should mention names differing by case: \(text)")
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), [], "nothing is left behind")
        }
    }

    func testCompressingASelectionKeepsEachName() throws {
        // What the user sees in Finder is what goes in, with its spelling.
        let src = sandbox.appendingPathComponent("Mixed")
        _ = TestFS.write(src, "CamelCase.TXT", "x")
        _ = TestFS.write(src, "lower/UPPER.md", "y")
        _ = try service.compress(CompressRequest(items: [src], destinationDirectory: sandbox, settings: CompressionSettings(format: .zip)))
        let listed = try names(sandbox.appendingPathComponent("Mixed.zip")).map { $0.lowercased() }
        XCTAssertEqual(listed, ["mixed/camelcase.txt", "mixed/lower/upper.md"])
    }
}
