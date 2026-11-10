import XCTest
import Foundation
import ArchiveCore
import ArchiveEngines
@testable import ArchiverKit
import UATestSupport

/// Conditions a careful user still runs into: work started back to back on the same archive, an
/// archive changed by another program while it is being edited, awkward file names, destinations
/// that can't be written, and empty inputs.
final class RobustnessTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = TestFS.tempDir("robust")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeZip(_ name: String = "a.zip", files: [String: String] = ["one.txt": "1", "two.txt": "2"]) throws -> URL {
        let src = dir.appendingPathComponent("src-\(UUID().uuidString)")
        for (p, c) in files { _ = TestFS.write(src, p, c) }
        var s = CompressionSettings(format: .zip)
        s.includeRootFolder = false
        let base = (name as NSString).deletingPathExtension
        _ = try ArchiveService().compress(CompressRequest(items: [src], destinationDirectory: dir, archiveName: base, settings: s))
        return dir.appendingPathComponent(name)
    }

    func names(_ archive: URL) throws -> Set<String> {
        Set(try ArchiveService().open(archive).listing.entries.filter { $0.type == .file }.map(\.normalizedPath))
    }

    // MARK: Concurrent edits

    /// The app runs operations concurrently: "Add" and then "Rename" (or two Adds, or an external
    /// edit being saved) on one archive used to each rebuild from the original, and the one that
    /// finished last silently discarded the other's change.
    func testConcurrentEditsOfOneArchiveAreAllApplied() throws {
        let zip = try makeZip()
        let service = ArchiveService()
        let extras = (0..<6).map { i in TestFS.write(dir, "extra\(i).txt", String(repeating: "x", count: 50_000 + i)) }
        let group = DispatchGroup()
        final class Failures: @unchecked Sendable { let lock = NSLock(); var list: [Error] = [] }
        let failed = Failures()
        for (i, file) in extras.enumerated() {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                var edits: [ArchiveEdit] = [.add(files: [file], toFolder: "")]
                if i == 0 { edits.append(.rename(path: "one.txt", newName: "uno.txt")) }
                do { _ = try service.modify(ModifyRequest(archive: zip, edits: edits)) } catch {
                    failed.lock.lock(); failed.list.append(error); failed.lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)
        XCTAssertTrue(failed.list.isEmpty, "\(failed.list)")
        let result = try names(zip)
        for i in 0..<6 { XCTAssertTrue(result.contains("extra\(i).txt"), "the edit adding extra\(i).txt was lost: \(result.sorted())") }
        XCTAssertTrue(result.contains("uno.txt"), "the rename was lost: \(result.sorted())")
        XCTAssertTrue(result.contains("two.txt"))
    }

    /// Another program (or another Zipper process) replacing the archive while an edit is being
    /// built must not be overwritten by a rebuild of the old contents.
    func testAnArchiveChangedByAnotherProgramMidEditIsNotOverwritten() throws {
        let zip = try makeZip(files: ["one.txt": "1", "big.bin": String(repeating: "z", count: 3_000_000)])
        let replacement = try makeZip("other.zip", files: ["theirs.txt": "written by someone else"])
        let progress = OperationProgress()
        var swapped = false
        progress.observe { s in
            // As soon as the rebuild starts compressing, someone else saves a new version.
            guard !swapped, s.phase.lowercased().contains("compress") || s.processedBytes > 0 else { return }
            swapped = true
            _ = rename(replacement.path, zip.path)
        }
        let added = TestFS.write(dir, "mine.txt", "mine")
        XCTAssertThrowsError(try ArchiveService().modify(ModifyRequest(archive: zip, edits: [.add(files: [added], toFolder: "")]), progress: progress))
        XCTAssertTrue(swapped, "the test didn't manage to change the archive mid-edit")
        XCTAssertEqual(try names(zip), ["theirs.txt"], "the other program's version must survive")
    }

    // MARK: Awkward names

    func roundTrip(_ names: [String], formats: [FormatID], file: StaticString = #filePath, line: UInt = #line) throws {
        let src = dir.appendingPathComponent("names-\(UUID().uuidString)")
        for n in names { _ = TestFS.write(src, n, n) }
        let service = ArchiveService()
        for format in formats where service.creationOptions(for: format).canCreate {
            let out = dir.appendingPathComponent("out-\(format.rawValue)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let made = try service.compress(CompressRequest(items: [src], destinationDirectory: out, settings: CompressionSettings(format: format)))
            let archive = try XCTUnwrap(made.archives.first?.outputs.first)
            let x = out.appendingPathComponent("x", isDirectory: true)
            _ = try service.extract(ExtractRequest(archive: archive, destination: x, mode: .here))
            XCTAssertEqual(TestFS.digestTree(x.appendingPathComponent(src.lastPathComponent)), TestFS.digestTree(src), "\(format)", file: file, line: line)
        }
    }

    func testAwkwardFileNamesRoundTrip() throws {
        try roundTrip(["-leading-dash.txt", "tab\there.txt", " leading space.txt", "trailing space .txt", "quote\"s.txt",
                       "colon:name.txt", "star*?.txt", "#hash%percent.txt", "Cafe\u{301}.txt" /* NFD */,
                       String(repeating: "L", count: 240) + ".txt", "日本語/深い/ファイル.txt", ".hidden", "emoji 🎉.txt"],
                      formats: [.zip, .sevenZip, .tarGzip])
    }

    /// 7-Zip receives its file list one name per line: a name with a line break was silently left out
    /// of 7z archives. ZIP and TAR keep it; 7z now refuses. (A backslash is extracted as a folder
    /// separator in every format, on purpose: Windows-made archives use it; see KnownLimitations.md.)
    func testLineBreaksInNamesAreKeptOrRefusedNeverLost() throws {
        let names = ["new\nline.txt", "ok.txt"]
        try roundTrip(names, formats: [.zip, .tarGzip])
        let service = ArchiveService()
        try XCTSkipUnless(service.creationOptions(for: .sevenZip).canCreate, "needs 7-Zip")
        let src = dir.appendingPathComponent("refused")
        for n in names { _ = TestFS.write(src, n, n) }
        XCTAssertThrowsError(try service.compress(CompressRequest(items: [src], destinationDirectory: dir, settings: CompressionSettings(format: .sevenZip)))) { e in
            XCTAssertEqual((e as? ArchiveError)?.code, "operation-not-supported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("refused.7z").path), "no partial archive")
    }

    // MARK: Destinations

    func testCompressingAFolderIntoItselfDoesNotIncludeTheArchive() throws {
        let src = TestFS.sampleTree(in: dir, name: "self")
        let made = try ArchiveService().compress(CompressRequest(items: [src], destinationDirectory: src, settings: CompressionSettings(format: .zip)))
        let archive = try XCTUnwrap(made.archives.first?.outputs.first)
        XCTAssertFalse(try names(archive).contains { $0.hasSuffix(".zip") }, "the archive contains itself")
        XCTAssertEqual(try ArchiveService().test(archive).result, .passed)
    }

    func testUnwritableAndInvalidDestinationsAreErrorsNotCrashes() throws {
        let zip = try makeZip()
        let file = TestFS.write(dir, "not-a-folder", "x")
        let service = ArchiveService()
        XCTAssertThrowsError(try service.extract(ExtractRequest(archive: zip, destination: file)))
        XCTAssertThrowsError(try service.compress(CompressRequest(items: [zip], destinationDirectory: file, settings: CompressionSettings(format: .zip))))
        guard getuid() != 0 else { return }  // root can write anywhere
        let ro = dir.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
        XCTAssertThrowsError(try service.extract(ExtractRequest(archive: zip, destination: ro)))
        XCTAssertThrowsError(try service.compress(CompressRequest(items: [zip], destinationDirectory: ro, settings: CompressionSettings(format: .zip))))
    }

    // MARK: Empty inputs

    func testEmptyFilesFoldersAndArchives() throws {
        let src = dir.appendingPathComponent("empties")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("nothing/inside"), withIntermediateDirectories: true)
        _ = TestFS.write(src, "zero.txt", "")
        let service = ArchiveService()
        for format in [FormatID.zip, .sevenZip, .tarGzip, .tar] where service.creationOptions(for: format).canCreate {
            let out = dir.appendingPathComponent("e-\(format.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let made = try service.compress(CompressRequest(items: [src], destinationDirectory: out, settings: CompressionSettings(format: format)))
            let archive = try XCTUnwrap(made.archives.first?.outputs.first)
            XCTAssertEqual(try service.test(archive).result, .passed, "\(format)")
            _ = try service.extract(ExtractRequest(archive: archive, destination: out.appendingPathComponent("x"), mode: .here))
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("x/empties/nothing/inside").path), "\(format): empty folders kept")
            XCTAssertEqual((try? Data(contentsOf: out.appendingPathComponent("x/empties/zero.txt")))?.count, 0, "\(format)")
        }
        // An archive with no entries at all (a valid 22-byte ZIP).
        let empty = dir.appendingPathComponent("empty.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: empty)
        let listing = try service.open(empty).listing
        XCTAssertEqual(listing.entries.count, 0)
        XCTAssertNoThrow(try service.test(empty))
        XCTAssertNoThrow(try service.extract(ExtractRequest(archive: empty, destination: dir.appendingPathComponent("from-empty"))))
    }

    func testZeroByteFileIsNotAnArchive() throws {
        let zero = TestFS.write(dir, "zero.zip", "")
        XCTAssertThrowsError(try ArchiveService().open(zero))
        XCTAssertThrowsError(try ArchiveService().extract(ExtractRequest(archive: zero, destination: dir)))
    }
}

/// A killed process (crash, force quit, power loss) can't remove its hidden partial output; the next
/// operation in that folder does, unless the process that made it is still running.
final class LeftoverTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = TestFS.tempDir("leftovers") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testLeftoversOfDeadProcessesAreRemovedAndNothingElse() throws {
        let fm = FileManager.default
        // A PID that isn't running: a child that has exited.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exit 0"]
        try p.run()
        p.waitUntilExit()
        let dead = p.processIdentifier
        let mine = getpid()
        let old = Date().addingTimeInterval(-3 * 24 * 3600)
        func make(_ name: String, dir isDir: Bool = false, date: Date? = nil) -> URL {
            let u = dir.appendingPathComponent(name)
            if isDir { try! fm.createDirectory(at: u, withIntermediateDirectories: true) } else { _ = fm.createFile(atPath: u.path, contents: Data("x".utf8)) }
            if let date { try! fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path) }
            return u
        }
        let removed = [
            make(".Photos.zip.ua-z\(dead)-0badf00d.partial"),
            make(".Photos.7z.ua-z\(dead)-12345678"),
            make(".ua-extract-z\(dead)-abcdef01", dir: true),
            make(".big.bin.ua-z\(dead)-00000001.partial"),
            make(".Photos.zip.ua-3377691788", date: old),            // before tokens, 3 days old
            make(".ua-extract-6F1A0C2E-3B4D-4E5F-8A9B-0C1D2E3F4A5B", dir: true, date: old),
        ]
        let kept = [
            make(".Photos.zip.ua-z\(mine)-0badf00d.partial"),       // this process: still in progress
            make(".Photos.zip.ua-3377691788.partial"),             // untagged but recent
            make("Photos.zip"), make(".DS_Store"), make(".hidden-ua-notes.txt"), make(".ua-list.txt"),
            make("my.ua-z\(dead)-0badf00d"),                        // not hidden: never Zipper's
        ]
        Leftovers.sweep(dir)
        for u in removed { XCTAssertFalse(fm.fileExists(atPath: u.path), "\(u.lastPathComponent) should have been removed") }
        for u in kept { XCTAssertTrue(fm.fileExists(atPath: u.path), "\(u.lastPathComponent) must be kept") }
    }

    func testCompressingIntoAFolderCleansUpAfterAKilledRun() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exit 0"]
        try p.run()
        p.waitUntilExit()
        let leftover = dir.appendingPathComponent(".Sample.zip.ua-z\(p.processIdentifier)-deadbeef.partial")
        _ = FileManager.default.createFile(atPath: leftover.path, contents: Data(count: 1 << 20))
        let src = TestFS.sampleTree(in: dir)
        _ = try ArchiveService().compress(CompressRequest(items: [src], destinationDirectory: dir, settings: CompressionSettings(format: .zip)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }
}

/// Rebuilding an archive from files on disk can't keep two entries with one name apart.
final class NameConflictTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = TestFS.tempDir("names") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testSameNameTwiceIsRefusedWithAClearReasonEverywhere() throws {
        var tar = TarBuilder()
        tar.add("notes.txt", content: "first")
        tar.add("notes.txt", content: "second")
        let archive = dir.appendingPathComponent("twice.tar")
        try tar.write(to: archive)
        let before = try Data(contentsOf: archive)
        let service = ArchiveService()
        XCTAssertThrowsError(try service.modify(ModifyRequest(archive: archive, edits: [.createFolder(path: "new")]))) { e in
            guard case .conflictingNames(let a, let b)? = e as? ArchiveError else { return XCTFail("\(e)") }
            XCTAssertEqual(a, "notes.txt")
            XCTAssertEqual(b, "notes.txt")
            XCTAssertTrue((e as? ArchiveError)?.explanation.contains("more than one item named") == true)
        }
        XCTAssertThrowsError(try service.convert(ConvertRequest(archive: archive, settings: CompressionSettings(format: .zip)))) { e in
            XCTAssertEqual((e as? ArchiveError)?.code, "conflicting-names")
        }
        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("twice.zip").path))
        // Extraction keeps both.
        let out = dir.appendingPathComponent("out")
        let o = try service.extract(ExtractRequest(archive: archive, destination: out, mode: .here))
        XCTAssertEqual(o.report.filesWritten, 2)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: out.path)), ["notes.txt", "notes 2.txt"])
    }

    func testCaseDifferencesAreFineOnACaseSensitiveDisk() throws {
        try XCTSkipIf(NameConflicts.isCaseInsensitive(dir), "this disk is case-insensitive")
        var tar = TarBuilder()
        tar.add("Readme.txt", content: "first")
        tar.add("README.TXT", content: "second")
        let archive = dir.appendingPathComponent("case.tar")
        try tar.write(to: archive)
        let o = try ArchiveService().modify(ModifyRequest(archive: archive, edits: [.rename(path: "Readme.txt", newName: "readme.txt")]))
        XCTAssertEqual(o.entryCount, 2)
        let names = try ArchiveService().open(archive).listing.entries.map(\.normalizedPath).sorted()
        XCTAssertEqual(names, ["README.TXT", "readme.txt"])
    }

    func testCaseConflictDetectionSeesFoldersToo() {
        XCTAssertNil(NameConflicts.caseConflict(in: ["a/b.txt", "a/c.txt", "d.txt"]))
        XCTAssertEqual(NameConflicts.caseConflict(in: ["Docs/a.txt", "docs/b.txt"])?.second, "docs")
        XCTAssertEqual(NameConflicts.caseConflict(in: ["x/Caf\u{E9}.txt", "x/Cafe\u{301}.txt"])?.first, "x/Caf\u{E9}.txt",
                       "composed and decomposed spellings are one name on a Mac")
    }

    func testSkippedFilesAreNotCountedAsExtracted() throws {
        let src = TestFS.sampleTree(in: dir, name: "S")
        let service = ArchiveService()
        _ = try service.compress(CompressRequest(items: [src], destinationDirectory: dir, settings: CompressionSettings(format: .zip)))
        let archive = dir.appendingPathComponent("S.zip")
        let out = dir.appendingPathComponent("out")
        let first = try service.extract(ExtractRequest(archive: archive, destination: out, mode: .here))
        XCTAssertGreaterThan(first.report.filesWritten, 5)
        var skip = ExtractionOptions()
        skip.conflictPolicy = .skip
        let second = try service.extract(ExtractRequest(archive: archive, destination: out, mode: .here, options: skip))
        XCTAssertEqual(second.report.filesWritten, 0, "nothing was written the second time")
        XCTAssertEqual(second.report.bytesWritten, 0)
        XCTAssertEqual(second.report.skipped.count, first.report.filesWritten)
    }
}

/// The app stays open for days: nothing may accumulate. Every kind of operation is run many times,
/// successes and failures alike, and open file descriptors and temporary items are counted.
final class ResourceHygieneTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = TestFS.tempDir("hygiene") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func openDescriptors() -> Int {
        let path = FileManager.default.fileExists(atPath: "/proc/self/fd") ? "/proc/self/fd" : "/dev/fd"
        return (try? FileManager.default.contentsOfDirectory(atPath: path))?.count ?? -1
    }

    /// Zipper's temporary items in the system temporary folder and in `dir`.
    func temporaryItems() -> [String] {
        let fm = FileManager.default
        let system = ((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? [])
            .filter { ($0.hasPrefix("ua-7z-") || $0.hasPrefix("ua-edit-")) }
        var local: [String] = []
        if let walker = fm.enumerator(atPath: dir.path) {
            while let rel = walker.nextObject() as? String {
                let name = (rel as NSString).lastPathComponent
                if name.hasPrefix(".ua-") || name.contains(".ua-") { local.append(rel) }
            }
        }
        return system + local
    }

    func testNothingAccumulatesOverManyOperations() throws {
        let service = ArchiveService()
        let src = TestFS.sampleTree(in: dir, name: "S")
        let extra = TestFS.write(dir, "extra.txt", "extra")
        let garbage = TestFS.writeBytes(dir, "garbage.zip", Data(repeating: 0x41, count: 4096))
        var formats: [FormatID] = [.zip, .tarGzip, .tarXz, .tarZstd]
        if service.creationOptions(for: .sevenZip).canCreate { formats.append(.sevenZip) }

        func cycle(_ i: Int) throws {
            let work = dir.appendingPathComponent("w\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let format = formats[i % formats.count]
            let made = try service.compress(CompressRequest(items: [src], destinationDirectory: work, settings: CompressionSettings(format: format)))
            let archive = made.archives[0].outputs[0]
            _ = try service.open(archive)
            _ = try service.test(archive)
            _ = try service.extract(ExtractRequest(archive: archive, destination: work.appendingPathComponent("x"), verifyAfterExtraction: true))
            _ = try service.extract(ExtractRequest(archive: archive, destination: work.appendingPathComponent("y"), mode: .here,
                                                   selection: .paths(["S/readme.txt"])))
            _ = try service.extractForPreview(archive, entryPath: "S/readme.txt")
            do {
                _ = try service.modify(ModifyRequest(archive: archive, edits: [.add(files: [extra], toFolder: "S"), .createFolder(path: "S/new")]))
                let session = try ExternalEditSession(service: service, archive: archive, entryPath: "S/readme.txt")
                session.discard()
            }
            _ = try service.findDuplicates(in: [archive])
            _ = try service.analyzeDamage(archive)
            if format == .zip {
                _ = try service.convert(ConvertRequest(archive: archive, settings: CompressionSettings(format: .tarGzip), destinationDirectory: work))
                let parts = try FileSplitter.split(archive, partSize: 4_000, into: work)
                try FileManager.default.removeItem(at: archive)
                _ = try FileSplitter.join(firstPart: parts.parts[0])
            }
            // Failures must clean up after themselves too.
            XCTAssertThrowsError(try service.open(garbage))
            XCTAssertThrowsError(try service.extract(ExtractRequest(archive: garbage, destination: work.appendingPathComponent("g"))))
            XCTAssertThrowsError(try service.extract(ExtractRequest(archive: work.appendingPathComponent("missing.zip"), destination: work)))
            XCTAssertThrowsError(try service.modify(ModifyRequest(archive: archive, edits: [.delete(paths: ["no/such/entry"])])))
            XCTAssertThrowsError(try service.compress(CompressRequest(items: [work.appendingPathComponent("missing")], destinationDirectory: work,
                                                                      settings: CompressionSettings(format: format))))
            let cancelled = OperationProgress()
            cancelled.cancel()
            XCTAssertThrowsError(try service.compress(CompressRequest(items: [src], destinationDirectory: work, archiveName: "cancelled",
                                                                      settings: CompressionSettings(format: format)), progress: cancelled))
            XCTAssertThrowsError(try service.extract(ExtractRequest(archive: archive, destination: work.appendingPathComponent("c")), progress: cancelled))
            var tiny = ExtractionOptions()
            tiny.limits.maxTotalBytes = 1_000
            XCTAssertThrowsError(try service.extract(ExtractRequest(archive: archive, destination: work.appendingPathComponent("limit"), options: tiny)))
        }

        // Warm up: caches, lazily opened descriptors and one-time probes settle here.
        for i in 0..<formats.count { try cycle(i) }
        PreviewCache.shared.clear()
        Thread.sleep(forTimeInterval: 0.5)   // cancelled libarchive handles are closed in the background
        let descriptorsBefore = openDescriptors()
        let itemsBefore = temporaryItems()

        let rounds = 60
        for i in 0..<rounds { try cycle(i + 100) }
        PreviewCache.shared.clear()
        Thread.sleep(forTimeInterval: 0.5)

        let leaked = openDescriptors() - descriptorsBefore
        XCTAssertLessThanOrEqual(leaked, 3, "\(leaked) file descriptors leaked over \(rounds) rounds of operations")
        let newItems = Set(temporaryItems()).subtracting(itemsBefore)
        XCTAssertTrue(newItems.isEmpty, "temporary items left behind: \(newItems.sorted().prefix(10))")
    }
}

/// One-character names ("x", "S", "é") crashed 7z and RAR creation and renaming on Linux:
/// NSString.deletingLastPathComponent traps on them in swift-corelibs-foundation.
final class ShortNameTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = TestFS.tempDir("short") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testArchivePathParent() {
        XCTAssertEqual(ArchivePath.parent(of: "a/b/c"), "a/b")
        XCTAssertEqual(ArchivePath.parent(of: "c"), "")
        XCTAssertEqual(ArchivePath.parent(of: "x"), "")
        XCTAssertEqual(ArchivePath.parent(of: "é/x"), "é")
        XCTAssertEqual(ArchivePath.parent(of: ""), "")
    }

    func testOneCharacterNamesInEveryFormatAndEdit() throws {
        let service = ArchiveService()
        let folder = dir.appendingPathComponent("S")
        _ = TestFS.write(folder, "x", "single-letter file")
        _ = TestFS.write(folder, "é/1", "nested single letters")
        let file = TestFS.write(dir, "y", "top-level single-letter file")
        for format in [FormatID.zip, .sevenZip, .tarGzip, .tar] where service.creationOptions(for: format).canCreate {
            let out = dir.appendingPathComponent("o-\(format.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let made = try service.compress(CompressRequest(items: [folder, file], destinationDirectory: out, archiveName: "a",
                                                            settings: CompressionSettings(format: format)))
            let archive = made.archives[0].outputs[0]
            let names = Set(try service.open(archive).listing.entries.filter { $0.type == .file }.map(\.normalizedPath))
            XCTAssertEqual(names, ["S/x", "S/é/1", "y"], "\(format)")
            _ = try service.modify(ModifyRequest(archive: archive, edits: [.rename(path: "y", newName: "z"), .rename(path: "S", newName: "T"),
                                                                           .delete(paths: ["T/x"]), .createFolder(path: "n")]))
            let after = Set(try service.open(archive).listing.entries.filter { $0.type == .file }.map(\.normalizedPath))
            XCTAssertEqual(after, ["T/é/1", "z"], "\(format)")
        }
    }
}
