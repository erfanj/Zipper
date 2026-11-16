import XCTest
import Foundation
import ArchiveCore
import ArchiveEngines
@testable import ArchiverKit
import UATestSupport

/// "Safe" symbolic links must stay inside the destination when they are *followed*, not only when
/// their text is read. A link whose target passes through another link (up -> "..", then
/// escape -> "up/../secret") looks contained and isn't.
final class LinkChainTests: XCTestCase {
    var sandbox: URL!
    var dest: URL!
    var secret: URL!
    let service = ArchiveService()

    override func setUpWithError() throws {
        sandbox = TestFS.tempDir("links")
        dest = sandbox.appendingPathComponent("dest")
        secret = TestFS.write(sandbox, "secret.txt", "private data outside the destination")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: sandbox) }

    /// Every symbolic link below `root` must resolve to something inside `root` (or to nothing).
    func assertNoLinkLeavesTheDestination(_ root: URL, file: StaticString = #filePath, line: UInt = #line) {
        let fm = FileManager.default
        // On macOS the temporary folder is /var/folders/…, itself a link to /private/var/folders/….
        // Foundation drops "/private" from a path it resolved and keeps it on one it couldn't
        // resolve (a link loop), so both sides are compared without it.
        func comparable(_ path: String) -> String {
            for top in ["/var/", "/tmp/", "/etc/"] where path.hasPrefix("/private" + top) { return String(path.dropFirst("/private".count)) }
            return path
        }
        let rootPath = comparable(root.resolvingSymlinksInPath().path)
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
            let resolved = comparable(url.resolvingSymlinksInPath().path)
            XCTAssertTrue(resolved == rootPath || resolved.hasPrefix(rootPath + "/"),
                          "“\(comparable(url.path).dropFirst(rootPath.count))” -> \(resolved) leaves the destination", file: file, line: line)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                XCTAssertFalse(text.contains("private data"), "the link at \(url.lastPathComponent) reads a file outside the destination", file: file, line: line)
            }
        }
    }

    func extract(_ tar: TarBuilder, mode: ExtractionMode, name: String = "hostile.tar") throws -> ExtractionOutcome {
        let archive = sandbox.appendingPathComponent(name)
        try tar.write(to: archive)
        return try service.extract(ExtractRequest(archive: archive, destination: dest, mode: mode))
    }

    func testALinkThroughAnotherLinkCannotLeaveTheDestination() throws {
        for mode in [ExtractionMode.here, .newFolder, .smart] {
            try? FileManager.default.removeItem(at: dest)
            var tar = TarBuilder()
            tar.add("sub/", kind: .directory)
            tar.add("sub/inner.txt", content: "fine")
            tar.add("sub/up", kind: .symlink, link: "..")                       // the destination itself: allowed
            tar.add("sub/escape", kind: .symlink, link: "up/../secret.txt")     // text says sub/secret.txt; really ../secret.txt
            tar.add("sub/escape-dir", kind: .symlink, link: "up/..")
            let o = try extract(tar, mode: mode)
            assertNoLinkLeavesTheDestination(dest)
            XCTAssertTrue(o.report.blocked.contains { $0.path.contains("escape") }, "\(mode): the escaping links must be reported: \(o.report.blocked)")
            XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "private data outside the destination")
        }
    }

    func testOrderDoesNotMatter() throws {
        // The escaping link comes first, while the link it will pass through doesn't exist yet.
        var tar = TarBuilder()
        tar.add("sub/", kind: .directory)
        tar.add("sub/escape", kind: .symlink, link: "up/../secret.txt")
        tar.add("sub/up", kind: .symlink, link: "..")
        _ = try extract(tar, mode: .here)
        assertNoLinkLeavesTheDestination(dest)
    }

    func testDeepChainsCannotReachFarAboveTheDestination() throws {
        var tar = TarBuilder()
        tar.add("a/b/c/d/", kind: .directory)
        tar.add("a/b/c/d/top", kind: .symlink, link: "../../../..")              // the destination: allowed
        tar.add("a/b/c/d/far", kind: .symlink, link: "top/../../../..")          // three levels above it
        tar.add("a/b/c/d/hop", kind: .symlink, link: "top")                      // a link to a link: fine
        tar.add("a/b/c/d/far2", kind: .symlink, link: "hop/../..")               // through two links
        _ = try extract(tar, mode: .here)
        assertNoLinkLeavesTheDestination(dest)
        let d = dest.appendingPathComponent("a/b/c/d")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: d.appendingPathComponent("top").path), "a link that stays inside is kept")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: d.appendingPathComponent("hop").path), "a link to a contained link is kept")
    }

    func testLinkLoopsAreHarmless() throws {
        var tar = TarBuilder()
        tar.add("loop1", kind: .symlink, link: "loop2")
        tar.add("loop2", kind: .symlink, link: "loop1")
        tar.add("self", kind: .symlink, link: "self/../self")
        tar.add("ok.txt", content: "ok")
        XCTAssertNoThrow(try extract(tar, mode: .here))
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("ok.txt"), encoding: .utf8), "ok")
        assertNoLinkLeavesTheDestination(dest)
    }

    func testOrdinaryRelativeLinksStillWork() throws {
        var tar = TarBuilder()
        tar.add("lib/", kind: .directory)
        tar.add("lib/real.txt", content: "real")
        tar.add("lib/current", kind: .symlink, link: "real.txt")
        tar.add("bin/", kind: .directory)
        tar.add("bin/tool", kind: .symlink, link: "../lib/real.txt")
        tar.add("dangling", kind: .symlink, link: "lib/not-there-yet.txt")
        let o = try extract(tar, mode: .here)
        XCTAssertEqual(o.report.symlinksCreated, 3, "\(o.report.blocked)")
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("bin/tool"), encoding: .utf8), "real")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("dangling").path), "lib/not-there-yet.txt")
        XCTAssertTrue(o.report.blocked.isEmpty)
    }

    func testALinkThroughTheUsersOwnLinkIsNotCreated() throws {
        // The destination already has the user's link to somewhere else; an archive must not ride on it.
        let elsewhere = sandbox.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        _ = TestFS.write(elsewhere, "mine.txt", "private data in another folder")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dest.appendingPathComponent("shortcut").path, withDestinationPath: elsewhere.path)
        var tar = TarBuilder()
        tar.add("peek", kind: .symlink, link: "shortcut/mine.txt")
        _ = try extract(tar, mode: .here)
        XCTAssertNil(try? String(contentsOf: dest.appendingPathComponent("peek"), encoding: .utf8), "the archive's link reads through the user's own link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("shortcut").path), elsewhere.path, "the user's link is untouched")
    }
}

/// "Edit in Default App" hands a temporary copy to the system to open. The system *runs* some
/// things instead of opening them: a file with its executable bit set and no known type goes to
/// Terminal, a .command file is run, a .terminal file can carry a command. Nothing from an archive
/// may be run that way.
final class ExternalEditSafetyTests: XCTestCase {
    var dir: URL!
    let service = ArchiveService()

    override func setUpWithError() throws { dir = TestFS.tempDir("edit-safety") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func makeArchive() throws -> URL {
        var tar = TarBuilder()
        tar.add("configure", content: "#!/bin/sh\necho pwned > /tmp/ua-edit-ran\n", mode: 0o755)
        tar.add("notes.txt", content: "plain notes", mode: 0o644)
        tar.add("build.sh", content: "#!/bin/sh\necho build\n", mode: 0o755)
        tar.add("Install.command", content: "#!/bin/sh\necho hi\n", mode: 0o755)
        tar.add("Settings.terminal", content: "<plist/>", mode: 0o644)
        tar.add("Shortcut.webloc", content: "<plist/>", mode: 0o644)
        let url = dir.appendingPathComponent("tools.tar")
        try tar.write(to: url)
        return url
    }

    func testTheCopyHandedToTheSystemIsNeverExecutable() throws {
        let archive = try makeArchive()
        for entry in ["configure", "build.sh", "notes.txt"] {
            let session = try ExternalEditSession(service: service, archive: archive, entryPath: entry)
            defer { session.discard() }
            let mode = (try FileManager.default.attributesOfItem(atPath: session.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(mode & 0o111, 0, "\(entry): the temporary copy must not be executable (mode \(String(mode, radix: 8)))")
            XCTAssertNotEqual(mode & 0o200, 0, "\(entry): it must be writable, to be edited")
        }
    }

    func testThingsThatRunWhenOpenedAreNotOpened() throws {
        let archive = try makeArchive()
        for entry in ["Install.command", "Settings.terminal", "Shortcut.webloc"] {
            XCTAssertThrowsError(try ExternalEditSession(service: service, archive: archive, entryPath: entry), entry) { e in
                XCTAssertEqual((e as? ArchiveError)?.code, "invalid-argument", "\(entry): \(e)")
            }
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("ua-edit-") }
        for l in leftovers {
            let inside = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.appendingPathComponent(l).path)) ?? []
            XCTAssertFalse(inside.contains { $0.hasSuffix(".command") || $0.hasSuffix(".terminal") || $0.hasSuffix(".webloc") }, "a refused entry was left in \(l)")
        }
    }

    func testEditingAScriptKeepsItExecutableInTheArchive() throws {
        let archive = try makeArchive()
        let session = try ExternalEditSession(service: service, archive: archive, entryPath: "build.sh")
        try Data("#!/bin/sh\necho edited\n".utf8).write(to: session.fileURL)
        XCTAssertTrue(session.hasChanges())
        _ = try session.commit(using: service)
        session.discard()
        let entry = try XCTUnwrap(service.open(archive).listing.entries.first { $0.normalizedPath == "build.sh" })
        XCTAssertEqual((entry.permissions ?? 0) & 0o777, 0o755, "the edit must not change the entry's permissions")
        let out = dir.appendingPathComponent("out")
        _ = try service.extract(ExtractRequest(archive: archive, destination: out, mode: .here, selection: .paths(["build.sh"])))
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("build.sh"), encoding: .utf8), "#!/bin/sh\necho edited\n")
    }
}
