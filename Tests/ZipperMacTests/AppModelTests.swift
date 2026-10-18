import XCTest
import ArchiveCore
import ArchiverKit
@testable import ZipperMac

// The app's platform-neutral model layer: the archive browser's folder index, the compression and
// extraction forms' rules, and settings persistence. (The SwiftUI views themselves need macOS.)
//
// Test classes stay nonisolated and hop to the main actor inside each test: Linux's XCTest can't
// discover @MainActor test methods.

final class FolderIndexTests: XCTestCase {
    func listing(_ entries: [(String, EntryType)]) -> ArchiveListing {
        ArchiveListing(properties: ArchiveProperties(format: .zip, engine: .libarchive),
                       entries: entries.enumerated().map { i, e in ArchiveEntry(index: i, path: e.0, type: e.1, uncompressedSize: 10) })
    }

    func testImplicitFoldersAppearOnceWithUniqueIDs() {
        let idx = FolderIndex(listing: listing([("a/b/c.txt", .file), ("a/d.txt", .file), ("e.txt", .file), ("a/b/f.txt", .file)]))
        XCTAssertEqual(Set(idx.rows(in: "").map(\.name)), ["a", "e.txt"])
        XCTAssertEqual(Set(idx.rows(in: "a").map(\.name)), ["b", "d.txt"])
        XCTAssertEqual(Set(idx.rows(in: "a/b").map(\.name)), ["c.txt", "f.txt"])
        let all = idx.children.values.flatMap { $0 }
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "row IDs must be unique (Table selection depends on it)")
        XCTAssertEqual(idx.files.count, 4)
    }

    func testRealDirectoryEntryReplacesSyntheticFolder() {
        // The file comes first, so "docs" is created implicitly; the later directory entry must not duplicate it.
        let idx = FolderIndex(listing: listing([("docs/readme.md", .file), ("docs/", .directory)]))
        let root = idx.rows(in: "")
        XCTAssertEqual(root.count, 1)
        XCTAssertEqual(root.first?.path, "docs")
        XCTAssertNotNil(root.first?.entry, "the real directory entry (with its dates) replaces the synthetic row")
        XCTAssertEqual(idx.rows(in: "docs").map(\.name), ["readme.md"])
    }

    func testBrowserRowsPutFoldersFirstAndSearchTheWholeArchive() async {
        let index = FolderIndex(listing: listing([("b.txt", .file), ("a.txt", .file), ("z/", .directory), ("z/deep.txt", .file)]))
        await MainActor.run {
            let state = BrowserState(url: URL(fileURLWithPath: "/tmp/x.zip"))
            state.show(nil, index: index)
            XCTAssertEqual(state.rows.map(\.name), ["z", "a.txt", "b.txt"])
            state.searchText = "deep"
            XCTAssertEqual(state.rows.map(\.path), ["z/deep.txt"])
            state.searchText = ""
            state.open(folder: "z")
            XCTAssertEqual(state.rows.map(\.name), ["deep.txt"])
            state.goUp()
            XCTAssertEqual(state.currentFolder, "")
        }
    }
}

final class FormTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-form-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("folder/a.txt"))
        try Data("hello".utf8).write(to: dir.appendingPathComponent("single.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    static func makeModel() -> AppModel {
        AppModel(platform: HeadlessPlatform(), defaults: UserDefaults(suiteName: "ZipperTests-\(UUID().uuidString)")!)
    }

    func testEncryptionRequiresMatchingPasswords() async {
        let folder = dir.appendingPathComponent("folder")
        await MainActor.run {
            let form = CompressForm(items: [folder], model: Self.makeModel())
            form.format = .zip
            XCTAssertTrue(form.canCreate)
            form.setEncrypt(true)
            XCTAssertFalse(form.canCreate)
            form.password = "correct horse"
            form.confirmation = "correct hose"
            XCTAssertEqual(form.problem, "The passwords don't match.")
            form.confirmation = "correct horse"
            XCTAssertTrue(form.canCreate)
            XCTAssertNotNil(form.makeRequest().settings.encryption)
        }
    }

    func testInvalidSplitSizeIsRejectedEvenWhenEncrypting() async throws {
        let folder = dir.appendingPathComponent("folder")
        let canSplit = await MainActor.run { () -> Bool in
            let form = CompressForm(items: [folder], model: Self.makeModel())
            form.format = .zip
            return form.options.canSplit
        }
        try XCTSkipUnless(canSplit, "splitting needs the 7-Zip engine")
        await MainActor.run {
            let form = CompressForm(items: [folder], model: Self.makeModel())
            form.format = .zip
            form.setEncrypt(true)
            form.password = "pw"
            form.confirmation = "pw"
            form.split = true
            form.splitText = "lots"
            XCTAssertFalse(form.canCreate, "the old form skipped this check whenever encryption was on")
            form.splitText = "10 MB"
            XCTAssertTrue(form.canCreate)
            XCTAssertEqual(form.makeRequest().settings.splitVolumeSize, FileSplitter.parseSize("10 MB"))
        }
    }

    func testStreamFormatsNeedASingleFile() async {
        let folder = dir.appendingPathComponent("folder")
        let single = dir.appendingPathComponent("single.txt")
        await MainActor.run {
            let model = Self.makeModel()
            let folderForm = CompressForm(items: [folder], model: model)
            folderForm.format = .gzip
            XCTAssertFalse(folderForm.canCreate)
            let fileForm = CompressForm(items: [single], model: model)
            XCTAssertTrue(fileForm.isSingleFile)
            fileForm.format = .gzip
            XCTAssertTrue(fileForm.canCreate)
            XCTAssertEqual(fileForm.defaultName, "single.txt", "streams keep the full file name (single.txt.gz)")
        }
    }

    func testChangingFormatDropsUnsupportedSettings() async {
        let folder = dir.appendingPathComponent("folder")
        await MainActor.run {
            let form = CompressForm(items: [folder], model: Self.makeModel())
            form.format = .zip
            form.method = .store
            form.setEncrypt(true)
            XCTAssertNotNil(form.encryptionMethod)
            form.format = .tarXz
            // Whatever remains must be something the new format supports ("store" isn't an XZ method).
            if let m = form.method { XCTAssertTrue(form.options.methods.contains(m), "\(m) isn't a tar.xz method") }
            XCTAssertNotEqual(form.method, .store)
            XCTAssertFalse(form.encrypt, "tar.xz can't be encrypted")
            XCTAssertNil(form.makeRequest().settings.encryption)
        }
    }

    func testScanKeyIgnoresCompressionLevel() async {
        let folder = dir.appendingPathComponent("folder")
        await MainActor.run {
            let form = CompressForm(items: [folder], model: Self.makeModel())
            let key = form.scanKey
            form.level = .smallest
            XCTAssertEqual(form.scanKey, key, "changing the level must not rescan the files")
            form.excludeDeveloperFiles = true
            XCTAssertNotEqual(form.scanKey, key, "changing exclusions must rescan")
        }
    }

    func testLevelMapsToEngineLevels() {
        XCTAssertEqual(CompressionLevel.fastest.engineLevel, 1)
        XCTAssertEqual(CompressionLevel(engineLevel: 6), .normal)
        XCTAssertEqual(CompressionLevel(engineLevel: 9), .smallest)
        XCTAssertEqual(CompressionLevel(engineLevel: 0), .fastest)
    }

    func testExtractFormRefusesFilesThatAreNotArchives() async throws {
        let garbage = dir.appendingPathComponent("not-an-archive.bin")
        try Data(repeating: 0x41, count: 64).write(to: garbage)
        let form = await MainActor.run { ExtractForm(archive: garbage, model: Self.makeModel()) }
        await form.load()
        await MainActor.run {
            XCTAssertNotNil(form.loadError)
            XCTAssertFalse(form.canExtract)
        }
    }
}

final class SettingsTests: XCTestCase {
    func testMissingKeysKeepTheirDefaults() throws {
        // A settings file written by an older version (only some keys) must not reset everything.
        let json = #"{"openAction":"extract","revealAfterExtraction":false}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.openAction, .extract)
        XCTAssertFalse(s.revealAfterExtraction)
        XCTAssertEqual(s.defaultFormat, .zip)
        XCTAssertTrue(s.excludeClutterByDefault)
        XCTAssertEqual(s.limits, SafetyLimits.default)
    }

    func testRoundTripThroughUserDefaults() {
        let defaults = UserDefaults(suiteName: "ZipperSettings-\(UUID().uuidString)")!
        var s = AppSettings()
        s.defaultLevel = .smallest
        s.filenameEncoding = "CP932"
        s.save(to: defaults)
        XCTAssertEqual(AppSettings.load(from: defaults), s)
    }

    func testUnreadableSettingsFallBackToDefaults() {
        let defaults = UserDefaults(suiteName: "ZipperSettings-\(UUID().uuidString)")!
        defaults.set(Data("not json".utf8), forKey: AppSettings.defaultsKey)
        XCTAssertEqual(AppSettings.load(from: defaults), AppSettings())
    }
}
