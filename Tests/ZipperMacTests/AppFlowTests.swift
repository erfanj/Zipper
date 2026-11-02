import XCTest
import ArchiveCore
import ArchiveEngines
import ArchiverKit
@testable import ZipperMac

// End-to-end flows through the app model: the same calls the SwiftUI views and menu commands make
// (open, navigate, switch archives, close, compress, extract, edit, test, tools, settings, activity),
// against real archives on disk, with the operating system's UI replaced by a recording fake.
//
// Test classes stay nonisolated and hop to the main actor inside each test: Linux's XCTest can't
// discover @MainActor test methods.

/// Records everything the app asks of the operating system, and answers prompts from a script.
@MainActor
final class RecordingPlatform: PlatformServices {
    var errors: [(ArchiveError, String)] = []
    var revealed: [[URL]] = []
    var opened: [URL] = []
    var notifications: [String] = []
    var recentDocuments: [URL] = []
    var passwordRequests: [(URL, PasswordRequestReason)] = []
    var conflictRequests: [ConflictInfo] = []
    var dockUpdates: [(Double?, Int)] = []
    /// Answers for password prompts, in order; nil answers mean "Cancel".
    var passwords: [String?] = []
    var conflictAnswer = ConflictAnswer(decision: .replace, applyToAll: true)
    var appActive = true

    func askPassword(for archive: URL, reason: PasswordRequestReason, offerToRemember: Bool) -> PasswordAnswer? {
        passwordRequests.append((archive, reason))
        guard !passwords.isEmpty, let p = passwords.removeFirst() else { return nil }
        return PasswordAnswer(secret: Secret(p), remember: false)
    }

    func askConflict(_ info: ConflictInfo) -> ConflictAnswer {
        conflictRequests.append(info)
        return conflictAnswer
    }

    func showError(_ error: ArchiveError, context: String) { errors.append((error, context)) }
    func notify(title: String, body: String) { notifications.append(title) }
    var isAppActive: Bool { appActive }
    func updateDockProgress(fraction: Double?, activeCount: Int) { dockUpdates.append((fraction, activeCount)) }
    func reveal(_ urls: [URL]) { revealed.append(urls) }
    func open(_ url: URL) { opened.append(url) }
    func noteRecentDocument(_ url: URL) { recentDocuments.append(url) }
}

/// Waits (without blocking the main actor) until `condition` holds.
func eventually(_ what: String, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line,
                _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await MainActor.run(body: condition) { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for: \(what)", file: file, line: line)
}

class AppFlowTestCase: XCTestCase {
    var dir: URL!
    /// docs/readme.md, docs/sub/deep.txt, a.txt, b.txt, inner.zip (containing inner.txt)
    var zip: URL!
    var tarGz: URL!
    var source: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-flow-\(UUID().uuidString)")
        source = dir.appendingPathComponent("Project")
        let fm = FileManager.default
        try fm.createDirectory(at: source.appendingPathComponent("docs/sub"), withIntermediateDirectories: true)
        try Data("# Readme\n".utf8).write(to: source.appendingPathComponent("docs/readme.md"))
        try Data(String(repeating: "deep ", count: 2000).utf8).write(to: source.appendingPathComponent("docs/sub/deep.txt"))
        try Data("alpha".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data("bravo".utf8).write(to: source.appendingPathComponent("b.txt"))
        let innerDir = dir.appendingPathComponent("innersrc")
        try fm.createDirectory(at: innerDir, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: innerDir.appendingPathComponent("inner.txt"))
        let service = ArchiveService()
        _ = try service.compress(CompressRequest(items: [innerDir.appendingPathComponent("inner.txt")], destinationDirectory: source,
                                                 archiveName: "inner", settings: CompressionSettings(format: .zip)))
        var flat = CompressionSettings(format: .zip)
        flat.includeRootFolder = false
        _ = try service.compress(CompressRequest(items: [source], destinationDirectory: dir, archiveName: "Project", settings: flat))
        zip = dir.appendingPathComponent("Project.zip")
        var tgz = CompressionSettings(format: .tarGzip)
        tgz.includeRootFolder = false
        _ = try service.compress(CompressRequest(items: [source], destinationDirectory: dir, archiveName: "Project", settings: tgz))
        tarGz = dir.appendingPathComponent("Project.tar.gz")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    func makeModel(_ platform: RecordingPlatform? = nil) -> AppModel {
        let model = AppModel(platform: platform ?? RecordingPlatform(), defaults: UserDefaults(suiteName: "ZipperFlow-\(UUID().uuidString)")!,
                             supportDirectory: dir.appendingPathComponent("Support"))
        var s = model.settings
        s.historyEnabled = false   // keep the developer's real history file untouched
        s.savePasswordsInKeychain = false
        model.settings = s
        model.applySettings()
        return model
    }

    /// Opens an archive the way File › Open does and waits for its listing.
    func openAndWait(_ model: AppModel, _ url: URL, file: StaticString = #filePath, line: UInt = #line) async -> BrowserState {
        await MainActor.run { model.openArchive(url) }
        await eventually("\(url.lastPathComponent) to load", file: file, line: line) {
            guard let s = model.archiveState(for: url) else { return false }
            return !s.isLoading && (s.opened != nil || s.error != nil)
        }
        return await MainActor.run { model.archiveState(for: url)! }
    }

    func waitForIdle(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) async {
        await eventually("operations to finish", timeout: 60, file: file, line: line) { !model.hasActiveOperations }
        // Completion handlers hop to the main actor; let them run.
        for _ in 0..<5 { await MainActor.run {}; try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}

// MARK: - Navigation: windows, sidebar, folders, back and forth

final class NavigationFlowTests: AppFlowTestCase {
    func testLaunchStartsAtHomeWithNothingOpen() async {
        await MainActor.run {
            let model = makeModel()
            XCTAssertEqual(model.selection, .home)
            XCTAssertTrue(model.openArchives.isEmpty)
            XCTAssertNil(model.currentArchive)
            XCTAssertNil(model.sheet)
            XCTAssertFalse(model.hasActiveOperations)
        }
    }

    func testBrowseFoldersBreadcrumbsSearchAndViewModes() async {
        let model = await MainActor.run { makeModel() }
        let state = await openAndWait(model, zip)
        await MainActor.run {
            XCTAssertNil(state.error)
            XCTAssertEqual(model.selection, .archive(zip))
            XCTAssertTrue(model.currentArchive === state)
            XCTAssertEqual(state.rows.map(\.name), ["docs", "a.txt", "b.txt", "inner.zip"])
            // Double-click a folder, then a subfolder.
            let docs = state.rows.first { $0.name == "docs" }!
            model.open(docs, in: state)
            XCTAssertEqual(state.currentFolder, "docs")
            XCTAssertEqual(state.rows.map(\.name), ["sub", "readme.md"])
            model.open(state.rows.first { $0.name == "sub" }!, in: state)
            XCTAssertEqual(state.pathComponents, ["docs", "sub"])
            XCTAssertEqual(state.rows.map(\.name), ["deep.txt"])
            // ⌘↑ twice, and once more at the root does nothing.
            state.goUp()
            XCTAssertEqual(state.currentFolder, "docs")
            state.goUp()
            XCTAssertEqual(state.currentFolder, "")
            state.goUp()
            XCTAssertEqual(state.currentFolder, "")
            // Breadcrumb jump back down, then to the root.
            state.open(folder: "docs/sub")
            state.open(folder: "")
            XCTAssertEqual(state.rows.count, 4)
            // Search covers the whole archive and is cleared by navigating.
            state.searchText = "deep"
            XCTAssertEqual(state.rows.map(\.path), ["docs/sub/deep.txt"])
            state.open(folder: "docs")
            XCTAssertEqual(state.searchText, "")
            // View modes don't lose the place.
            for mode in BrowserState.ViewMode.allCases {
                state.viewMode = mode
                XCTAssertEqual(state.currentFolder, "docs")
                XCTAssertEqual(state.rows(in: "docs").map(\.name), ["sub", "readme.md"])
            }
        }
    }

    func testSwitchingBetweenArchivesKeepsEachOnesPlaceAndClosingPicksANeighbour() async {
        let model = await MainActor.run { makeModel() }
        let first = await openAndWait(model, zip)
        await MainActor.run { first.open(folder: "docs"); first.selection = [first.rows.first { $0.name == "readme.md" }!.id] }
        let second = await openAndWait(model, tarGz)
        await MainActor.run {
            XCTAssertEqual(model.openArchives.count, 2)
            XCTAssertEqual(model.selection, .archive(tarGz))
            // Activity, Home, then back to the first archive: its folder and selection are kept.
            model.selection = .activity
            XCTAssertNil(model.currentArchive)
            model.selection = .home
            XCTAssertNil(model.currentArchive)
            model.selection = .archive(zip)
            XCTAssertTrue(model.currentArchive === first)
            XCTAssertEqual(first.currentFolder, "docs")
            XCTAssertEqual(first.selectedRows.map(\.name), ["readme.md"])
            // Opening an archive that's already open just selects it.
            model.openArchive(tarGz)
            XCTAssertEqual(model.openArchives.count, 2)
            XCTAssertTrue(model.currentArchive === second)
            // Close the selected one: the other is shown. Close the last: Home.
            model.closeArchive(tarGz)
            XCTAssertEqual(model.selection, .archive(zip))
            model.closeArchive(zip)
            XCTAssertEqual(model.selection, .home)
            XCTAssertTrue(model.openArchives.isEmpty)
            // Closing something that isn't open is harmless.
            model.closeArchive(zip)
            XCTAssertEqual(model.selection, .home)
        }
    }

    func testClosingAnArchiveThatIsNotSelectedKeepsTheCurrentView() async {
        let model = await MainActor.run { makeModel() }
        _ = await openAndWait(model, zip)
        _ = await openAndWait(model, tarGz)
        await MainActor.run {
            model.selection = .activity
            model.closeArchive(zip)
            XCTAssertEqual(model.selection, .activity)
            XCTAssertEqual(model.openArchives.map(\.url), [tarGz])
        }
    }

    func testReopeningAfterCloseStartsFresh() async {
        let model = await MainActor.run { makeModel() }
        let first = await openAndWait(model, zip)
        await MainActor.run { first.open(folder: "docs"); model.closeArchive(zip) }
        let again = await openAndWait(model, zip)
        await MainActor.run {
            XCTAssertFalse(first === again)
            XCTAssertEqual(again.currentFolder, "")
        }
    }

    func testBrokenArchiveShowsAnErrorAndTryAgainRecovers() async throws {
        let broken = dir.appendingPathComponent("Broken.zip")
        try Data("PK\u{3}\u{4} definitely not a zip".utf8).write(to: broken)
        let model = await MainActor.run { makeModel() }
        let state = await openAndWait(model, broken)
        await MainActor.run {
            XCTAssertNotNil(state.error, "a damaged archive shows an inline error, not an empty listing")
            XCTAssertNil(state.opened)
            XCTAssertTrue(state.rows.isEmpty)
            XCTAssertFalse(state.isEditable)
        }
        // The user fixes the file, then clicks "Try Again" (or opens it again from Finder).
        try FileManager.default.removeItem(at: broken)
        try FileManager.default.copyItem(at: zip, to: broken)
        await MainActor.run { model.openArchive(broken) }
        await eventually("reload after fixing the file") { state.opened != nil && !state.isLoading }
        await MainActor.run {
            XCTAssertNil(state.error)
            XCTAssertEqual(model.openArchives.count, 1)
        }
    }

    func testOpeningANestedArchiveAddsItToTheSidebar() async {
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        let state = await openAndWait(model, zip)
        await MainActor.run { model.open(state.rows.first { $0.name == "inner.zip" }!, in: state) }
        await eventually("the nested archive to open") { model.openArchives.count == 2 }
        let inner = await MainActor.run { model.openArchives[1] }
        await eventually("the nested archive to load") { inner.opened != nil }
        await MainActor.run {
            XCTAssertEqual(model.selection, .archive(inner.url))
            XCTAssertEqual(inner.rows.map(\.name), ["inner.txt"])
            XCTAssertTrue(platform.opened.isEmpty, "archives open in Zipper, not in another app")
        }
    }

    func testDoubleClickingADocumentOpensItAndScriptsAreOnlyRevealed() async throws {
        let scriptSource = dir.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scriptSource, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: scriptSource.appendingPathComponent("run.sh"))
        try Data("notes".utf8).write(to: scriptSource.appendingPathComponent("notes.txt"))
        _ = try ArchiveService().compress(CompressRequest(items: [scriptSource], destinationDirectory: dir, settings: CompressionSettings(format: .zip)))
        let archive = dir.appendingPathComponent("scripts.zip")
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        let state = await openAndWait(model, archive)
        await MainActor.run {
            state.open(folder: "scripts")
            model.open(state.rows.first { $0.name == "notes.txt" }!, in: state)
            model.open(state.rows.first { $0.name == "run.sh" }!, in: state)
        }
        await eventually("both double-clicks to be handled") { platform.opened.count + platform.revealed.count == 2 }
        await MainActor.run {
            XCTAssertEqual(platform.opened.map(\.lastPathComponent), ["notes.txt"])
            XCTAssertEqual(platform.revealed.flatMap { $0 }.map(\.lastPathComponent), ["run.sh"], "scripts are never run")
        }
    }

    func testRecentArchivesAreDedupedCappedAndClearable() async {
        await MainActor.run {
            let platform = RecordingPlatform()
            let model = makeModel(platform)
            let urls = (0..<15).map { dir.appendingPathComponent("r\($0).zip") }
            for u in urls { model.noteRecent(u) }
            model.noteRecent(urls[3])
            XCTAssertEqual(model.recentArchives.count, 12)
            XCTAssertEqual(model.recentArchives.first, urls[3], "reopening moves an archive to the top")
            XCTAssertEqual(Set(model.recentArchives).count, 12, "no duplicates")
            model.clearRecents()
            XCTAssertTrue(model.recentArchives.isEmpty)
        }
    }

    func testRecentArchivesSurviveARelaunch() async throws {
        let suite = "ZipperFlowRecents-\(UUID().uuidString)"
        await MainActor.run {
            let model = AppModel(platform: RecordingPlatform(), defaults: UserDefaults(suiteName: suite)!, supportDirectory: dir.appendingPathComponent("Support"))
            model.noteRecent(zip)
            model.noteRecent(tarGz)
        }
        await MainActor.run {
            let relaunched = AppModel(platform: RecordingPlatform(), defaults: UserDefaults(suiteName: suite)!, supportDirectory: dir.appendingPathComponent("Support"))
            XCTAssertEqual(relaunched.recentArchives.map(\.lastPathComponent), ["Project.tar.gz", "Project.zip"])
        }
    }
}

// MARK: - Dropping and opening files (Finder, Dock, drag and drop, Services)

final class OpenFlowTests: AppFlowTestCase {
    func testOneArchiveOpensOrExtractsDependingOnTheSetting() async {
        let model = await MainActor.run { makeModel() }
        await MainActor.run { model.handleOpen([zip]) }
        await eventually("browse") { model.currentArchive?.opened != nil }
        await MainActor.run {
            model.closeArchive(zip)
            model.settings.openAction = .extract
            model.settings.revealAfterExtraction = false
            model.applySettings()
            model.handleOpen([zip])
            XCTAssertTrue(model.openArchives.isEmpty, "extract-on-open doesn't open a browser")
        }
        await waitForIdle(model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Project/docs/sub/deep.txt").path) ||
                      FileManager.default.fileExists(atPath: dir.appendingPathComponent("Project 2/docs/sub/deep.txt").path))
    }

    func testFilesStartACompressSheetAndCancellingLeavesNothingBehind() async {
        await MainActor.run {
            let model = makeModel()
            model.handleOpen([source.appendingPathComponent("a.txt"), source.appendingPathComponent("docs")])
            guard case .compress(let form)? = model.sheet else { return XCTFail("expected the compress sheet") }
            XCTAssertEqual(form.items.count, 2)
            // Cancel (the sheet's binding sets it to nil), then open it again: a fresh form.
            model.sheet = nil
            XCTAssertFalse(model.hasActiveOperations)
            model.beginCompress([source])
            guard case .compress(let again)? = model.sheet else { return XCTFail("expected the compress sheet") }
            XCTAssertFalse(form === again)
            XCTAssertEqual(again.items, [source])
            model.beginCompress([])
            XCTAssertTrue(model.sheet.map { if case .compress(let f) = $0 { return f === again } else { return false } } ?? false,
                          "an empty selection doesn't replace the sheet")
        }
    }

    func testMixedDropAsksAndEachAnswerDoesTheRightThing() async {
        await MainActor.run {
            let model = makeModel()
            var toolsOpened = 0
            model.openWindow = { id in if id == "tools" { toolsOpened += 1 } }
            let mixed = [zip!, source.appendingPathComponent("a.txt")]
            model.handleOpen(mixed)
            XCTAssertEqual(model.ambiguousDrop, mixed)
            XCTAssertNil(model.sheet)
            // Cancel.
            model.ambiguousDrop = nil
            // Again, "Extract the Archives".
            model.handleOpen(mixed)
            let archives = (model.ambiguousDrop ?? []).filter { model.isArchive($0) }
            model.ambiguousDrop = nil
            model.showTool(.batchExtract, input: ArchiveService.distinctArchives(archives))
            XCTAssertEqual(model.selectedTool, .batchExtract)
            XCTAssertEqual(model.toolInput, [zip])
            XCTAssertEqual(toolsOpened, 1)
        }
    }

    func testSeveralArchivesGoToBatchExtract() async {
        await MainActor.run {
            let model = makeModel()
            model.handleOpen([zip, tarGz])
            XCTAssertEqual(model.selectedTool, .batchExtract)
            XCTAssertEqual(Set(model.toolInput), [zip, tarGz])
            XCTAssertTrue(model.openArchives.isEmpty)
            let tools = ToolsState()
            tools.receive(model.toolInput, for: model.selectedTool)
            XCTAssertEqual(Set(tools.batch.archives), [zip, tarGz])
        }
    }

    func testFoldersAndOfficeDocumentsAreCompressedNotOpened() async throws {
        let docs = ["Report.docx", "Budget.xlsx", "Slides.key", "Letter.odt", "Model.3mf"].map { dir.appendingPathComponent($0) }
        for d in docs { try FileManager.default.copyItem(at: zip, to: d) }
        let noExtension = dir.appendingPathComponent("download")
        try FileManager.default.copyItem(at: zip, to: noExtension)
        let jar = dir.appendingPathComponent("tool.jar")
        try FileManager.default.copyItem(at: zip, to: jar)
        await MainActor.run {
            let model = makeModel()
            XCTAssertFalse(model.isArchive(source), "folders are compressed")
            for d in docs { XCTAssertFalse(model.isArchive(d), "\(d.lastPathComponent) is a document built on ZIP, not an archive") }
            XCTAssertTrue(model.isArchive(zip))
            XCTAssertTrue(model.isArchive(jar), "packages named as such are archives")
            XCTAssertTrue(model.isArchive(noExtension), "a ZIP without an extension is still an archive")
            XCTAssertFalse(model.isArchive(dir.appendingPathComponent("missing.zip")))
            // Dropped on the window: a document starts the Compress sheet.
            model.handleOpen([docs[0]])
            guard case .compress(let form)? = model.sheet else { return XCTFail("a dropped .docx should be compressed") }
            XCTAssertEqual(form.items, [docs[0]])
            XCTAssertTrue(model.openArchives.isEmpty)
        }
    }
}

// MARK: - Sheets: compress and extract

final class SheetFlowTests: AppFlowTestCase {
    func testCompressSheetCreatesTheArchiveAndRecordsActivity() async throws {
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        await MainActor.run {
            model.beginCompress([source])
            guard case .compress(let form)? = model.sheet else { return XCTFail("no sheet") }
            form.format = .sevenZip
            form.archiveName = "Made by the sheet"
            form.verify = true
            XCTAssertTrue(form.canCreate, form.problem ?? "")
            form.start()
            model.sheet = nil
        }
        await waitForIdle(model)
        let out = dir.appendingPathComponent("Made by the sheet.7z")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        await MainActor.run {
            XCTAssertTrue(platform.errors.isEmpty, "\(platform.errors.map(\.0.explanation))")
            let finished = model.center.finished
            XCTAssertEqual(finished.count, 1)
            XCTAssertEqual(finished.first?.state, .succeeded)
            XCTAssertEqual(platform.revealed.last, [out], "new archives are shown in Finder by default")
            XCTAssertTrue(platform.notifications.isEmpty, "no notification while the app is active")
            model.center.clearFinished()
            XCTAssertTrue(model.center.finished.isEmpty)
        }
        let listing = try ArchiveService().open(out).listing
        XCTAssertTrue(listing.entries.contains { $0.normalizedPath.hasSuffix("docs/sub/deep.txt") })
    }

    func testCompressingTheSameItemsTwiceNeverOverwrites() async throws {
        let model = await MainActor.run { makeModel() }
        for _ in 0..<2 {
            await MainActor.run {
                let form = CompressForm(items: [source.appendingPathComponent("a.txt")], model: model)
                form.format = .zip
                form.start()
            }
            await waitForIdle(model)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.zip").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("a 2.zip").path))
    }

    func testCompressingTwiceWithSplitPartsNeverFails() async throws {
        try XCTSkipUnless(ArchiveService().creationOptions(for: .zip).canSplit, "splitting needs the 7-Zip engine")
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        for _ in 0..<2 {
            await MainActor.run {
                let form = CompressForm(items: [source], model: model)
                form.format = .zip
                form.split = true
                form.splitText = "8 KB"
                XCTAssertTrue(form.canCreate, form.problem ?? "")
                form.start()
            }
            await waitForIdle(model)
        }
        await MainActor.run {
            XCTAssertTrue(platform.errors.isEmpty, "second split compress failed: \(platform.errors.map(\.0.explanation))")
        }
        // "Project.zip" (the fixture) is taken, so the sets are "Project 2.zip.001…" and "Project 3.zip.001…".
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Project 2.zip.001").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Project 3.zip.001").path))
    }

    func testCompressSheetClearsPasswordsAfterStarting() async {
        await MainActor.run {
            let model = makeModel()
            let form = CompressForm(items: [source], model: model)
            form.format = .zip
            form.setEncrypt(true)
            form.password = "Correct-Horse-9"
            form.confirmation = "Correct-Horse-9"
            form.start()
            XCTAssertEqual(form.password, "")
            XCTAssertEqual(form.confirmation, "")
        }
        // (Let the background operation finish before the folder is removed.)
        let model = await MainActor.run { makeModel() }
        await waitForIdle(model)
    }

    func testCompressFormScanningSettlesAfterAnInterruptedScan() async {
        let form = await MainActor.run { CompressForm(items: [source], model: makeModel()) }
        // The sheet's .task(id: scanKey) cancels a scan when the inputs change mid-scan.
        let task = Task { await form.scan() }
        task.cancel()
        await task.value
        await MainActor.run { form.items = [] }
        await form.scan()
        await MainActor.run {
            XCTAssertFalse(form.isScanning, "the “Counting…” spinner must not stay on")
            XCTAssertNil(form.collection)
        }
    }

    func testCompressFormPresetsRoundTrip() async {
        await MainActor.run {
            let model = makeModel()
            let form = CompressForm(items: [source], model: model)
            let smallest = BuiltInPresets.all.first { $0.name.lowercased().contains("smallest") }!
            form.apply(smallest)
            XCTAssertEqual(form.appliedPreset, smallest.name)
            form.level = .fastest
            XCTAssertNil(form.appliedPreset, "changing a setting means it's no longer the preset")
            let mine = form.makePreset(named: "Mine")
            XCTAssertNil(mine.settings.threads, "presets don't pin the thread count")
            let before = model.userPresets.count
            model.userPresets.append(mine)
            XCTAssertEqual(model.allPresets.count, BuiltInPresets.all.count + before + 1)
        }
    }

    func testExtractSheetExtractsWithItsOwnChoices() async throws {
        let dest = dir.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        let form = await MainActor.run { () -> ExtractForm in
            model.beginExtract(zip)
            guard case .extract(let f)? = model.sheet else { fatalError("no extract sheet") }
            XCTAssertEqual(model.recentArchives.first, zip, "extracting counts as using the archive")
            return f
        }
        await form.load()
        await MainActor.run {
            XCTAssertNil(form.loadError)
            XCTAssertTrue(form.canExtract)
            XCTAssertFalse(form.needsPassword)
            XCTAssertEqual(form.opened?.listing.fileCount, 5)
            form.setDestination(dest)
            form.mode = .newFolder
            form.revealWhenDone = false
            form.verify = true
            form.start()
            model.sheet = nil
        }
        await waitForIdle(model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Project/docs/sub/deep.txt").path))
        await MainActor.run {
            XCTAssertTrue(platform.revealed.isEmpty, "the sheet's “Show in Finder” switch was off")
            XCTAssertTrue(platform.errors.isEmpty)
        }
    }

    func testExtractSheetShowContentsOpensTheBrowser() async {
        let model = await MainActor.run { makeModel() }
        await MainActor.run {
            model.beginExtract(zip)
            guard case .extract(let f)? = model.sheet else { return XCTFail("no sheet") }
            // "Show Contents"
            model.openArchive(f.archive)
            model.sheet = nil
        }
        await eventually("browser") { model.currentArchive?.opened != nil }
    }
}

// MARK: - Editing an open archive

final class EditFlowTests: AppFlowTestCase {
    func testAddRenameNewFolderAndDeleteUpdateTheBrowser() async throws {
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        let state = await openAndWait(model, zip)
        let editable = await MainActor.run { state.isEditable }
        XCTAssertTrue(editable)
        let extra = dir.appendingPathComponent("extra.txt")
        try Data("extra".utf8).write(to: extra)

        // Add into the current folder.
        await MainActor.run { state.open(folder: "docs"); model.add([extra], to: state) }
        await waitForIdle(model)
        await eventually("listing to include extra.txt") { state.rows.contains { $0.name == "extra.txt" } }
        await MainActor.run { XCTAssertEqual(state.currentFolder, "docs", "the user stays where they were") }

        // Rename.
        await MainActor.run { model.rename(state.rows.first { $0.name == "extra.txt" }!, to: "renamed.txt", in: state) }
        await waitForIdle(model)
        await eventually("rename to show") { state.rows.contains { $0.name == "renamed.txt" } }

        // Invalid renames are ignored without starting anything.
        await MainActor.run {
            let row = state.rows.first { $0.name == "renamed.txt" }!
            model.rename(row, to: "  ", in: state)
            model.rename(row, to: "a/b", in: state)
            model.rename(row, to: "renamed.txt", in: state)
            XCTAssertFalse(model.hasActiveOperations)
        }

        // New folder.
        await MainActor.run { model.createFolder(named: "Fresh", in: state) }
        await waitForIdle(model)
        await eventually("new folder") { state.rows.contains { $0.name == "Fresh" && $0.isFolder } }

        // Delete the selection.
        await MainActor.run {
            state.selection = [state.rows.first { $0.name == "renamed.txt" }!.id]
            model.deleteSelection(in: state)
            XCTAssertTrue(state.selection.isEmpty)
        }
        await waitForIdle(model)
        await eventually("deletion to show") { !state.rows.contains { $0.name == "renamed.txt" } && !state.isLoading }
        await MainActor.run { XCTAssertTrue(platform.errors.isEmpty, "\(platform.errors.map(\.0.explanation))") }
        let names = try ArchiveService().open(zip).listing.entries.map(\.normalizedPath)
        XCTAssertTrue(names.contains("docs/Fresh"))
        XCTAssertFalse(names.contains { $0.contains("renamed") || $0.contains("extra") })
    }

    func testSelectionFollowsTheSameItemsAfterTheArchiveIsRebuilt() async throws {
        let model = await MainActor.run { makeModel() }
        let state = await openAndWait(model, zip)
        let extra = dir.appendingPathComponent("0-first.txt")
        try Data("first".utf8).write(to: extra)
        await MainActor.run {
            state.selection = [state.rows.first { $0.name == "b.txt" }!.id]
            model.add([extra], to: state)
        }
        await waitForIdle(model)
        await eventually("listing to include the added file") { state.rows.contains { $0.name == "0-first.txt" } }
        await MainActor.run {
            // Whatever is highlighted is what ⌘⌫ deletes, so it must still be b.txt (or nothing).
            XCTAssertTrue(state.selectedRows.allSatisfy { $0.name == "b.txt" },
                          "after the rebuild the selection points at \(state.selectedRows.map(\.path)) instead of b.txt")
        }
    }

    func testFailedEditReportsAnErrorAndLeavesTheArchiveUntouched() async throws {
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        let state = await openAndWait(model, zip)
        let before = try Data(contentsOf: zip)
        await MainActor.run { model.add([dir.appendingPathComponent("does-not-exist.txt")], to: state) }
        await waitForIdle(model)
        await eventually("the error alert") { !platform.errors.isEmpty }
        XCTAssertEqual(try Data(contentsOf: zip), before)
        await MainActor.run {
            XCTAssertEqual(model.center.finished.last?.state, .failed)
            XCTAssertNotNil(state.opened, "the browser keeps showing the archive")
        }
    }

    func testStreamsAndMultipartArchivesAreReadOnly() async throws {
        let gz = dir.appendingPathComponent("a.txt.gz")
        _ = try ArchiveService().compress(CompressRequest(items: [source.appendingPathComponent("a.txt")], destinationDirectory: dir,
                                                          settings: CompressionSettings(format: .gzip)))
        let model = await MainActor.run { makeModel() }
        let state = await openAndWait(model, gz)
        await MainActor.run {
            XCTAssertNotNil(state.opened)
            XCTAssertFalse(state.isEditable)
        }
    }

    func testEditingInAnotherAppAndCommittingUpdatesTheArchive() async throws {
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        let state = await openAndWait(model, zip)
        final class Box: @unchecked Sendable { var session: ExternalEditSession? }
        let box = Box()
        await MainActor.run {
            model.editExternally(state.rows.first { $0.name == "a.txt" }!, in: state) { s in
                if box.session == nil { box.session = s }
            }
        }
        await eventually("the temporary copy to open") { !platform.opened.isEmpty }
        let file = await MainActor.run { platform.opened[0] }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "alpha")
        try Data("alpha, edited".utf8).write(to: file)
        await eventually("the change to be noticed", timeout: 15) { box.session != nil }
        await MainActor.run { model.commit(box.session!, in: state) }
        await waitForIdle(model)
        let out = dir.appendingPathComponent("check")
        _ = try ArchiveService().extract(ExtractRequest(archive: zip, destination: out, mode: .here, selection: .paths(["a.txt"])))
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8), "alpha, edited")
        // Closing the archive ends the session and removes the temporary copy.
        await MainActor.run { model.closeArchive(zip) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testQuickLookPreviewExtractsJustThatFile() async {
        let model = await MainActor.run { makeModel() }
        let state = await openAndWait(model, zip)
        let row = await MainActor.run { state.rows.first { $0.name == "a.txt" }! }
        let r = await model.previewFile(for: row, in: state)
        guard case .success(let url) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "alpha")
    }
}

// MARK: - Archive commands: extract, test, cancel, pause

final class OperationFlowTests: AppFlowTestCase {
    func testExtractSelectionAndExtractAll() async throws {
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        let state = await openAndWait(model, zip)
        let selected = dir.appendingPathComponent("selected", isDirectory: true)
        let all = dir.appendingPathComponent("all", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: all, withIntermediateDirectories: true)
        await MainActor.run {
            state.selection = [state.rows.first { $0.name == "b.txt" }!.id]
            model.extract(from: state, to: selected)
        }
        await waitForIdle(model)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: selected.path), ["b.txt"])
        await MainActor.run {
            state.selection = []
            model.extract(from: state, to: all)
        }
        await waitForIdle(model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: all.appendingPathComponent("Project/docs/sub/deep.txt").path))
        await MainActor.run { XCTAssertTrue(platform.errors.isEmpty) }
    }

    func testTestIntegrityMarksTheArchiveVerified() async {
        let model = await MainActor.run { makeModel() }
        let state = await openAndWait(model, zip)
        await MainActor.run {
            model.test(state)
            XCTAssertTrue(state.isTesting)
        }
        await waitForIdle(model)
        await eventually("the integrity result") { state.integrity != nil && !state.isTesting }
        await MainActor.run { XCTAssertEqual(state.integrity?.result, .passed) }
    }

    func testConflictsAskTheUserWhenSetToAsk() async throws {
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        let dest = dir.appendingPathComponent("conflicts", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dest.appendingPathComponent("a.txt"))
        await MainActor.run {
            platform.conflictAnswer = ConflictAnswer(decision: .replace, applyToAll: true)
            model.extract(archive: zip, destination: dest, mode: .here, selection: .paths(["a.txt"]), conflict: .ask, reveal: false)
        }
        await waitForIdle(model)
        await MainActor.run { XCTAssertEqual(platform.conflictRequests.count, 1) }
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8), "alpha")
    }

    func testPasswordPromptRetriesAfterAWrongPasswordAndCancelIsSilent() async throws {
        let service = ArchiveService()
        try XCTSkipUnless(service.creationOptions(for: .sevenZip).encryptionMethods.contains(.sevenZipAES256), "needs 7-Zip")
        let encrypted = dir.appendingPathComponent("Secret.7z")
        var s = CompressionSettings(format: .sevenZip)
        s.encryption = EncryptionSettings(method: .sevenZipAES256, encryptFilenames: true)
        _ = try service.compress(CompressRequest(items: [source], destinationDirectory: dir, archiveName: "Secret", settings: s,
                                                 password: Secret("right-password")))
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }

        // Wrong, then right: the browser opens.
        await MainActor.run { platform.passwords = ["wrong", "right-password"] }
        let state = await openAndWait(model, encrypted)
        await MainActor.run {
            XCTAssertNil(state.error, "\(String(describing: state.error))")
            XCTAssertEqual(platform.passwordRequests.map(\.1), [.required, .previousAttemptIncorrect])
            XCTAssertTrue(state.rows.contains { $0.name == "Project" })
        }

        // Cancel: an inline "password required" state, never an alert.
        await MainActor.run { model.closeArchive(encrypted); platform.passwords = [nil] }
        let cancelled = await openAndWait(model, encrypted)
        await MainActor.run {
            XCTAssertNotNil(cancelled.error)
            XCTAssertTrue(platform.errors.isEmpty)
        }

        // The extract sheet doesn't ask while reading the listing, only when extraction starts.
        let form = await MainActor.run { () -> ExtractForm in
            platform.passwordRequests = []
            return ExtractForm(archive: encrypted, model: model)
        }
        await form.load()
        await MainActor.run {
            XCTAssertTrue(form.needsPassword)
            XCTAssertTrue(form.canExtract)
            XCTAssertTrue(platform.passwordRequests.isEmpty)
        }
    }

    func testCancellingARunningOperationLeavesNoOutput() async throws {
        let big = dir.appendingPathComponent("big", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<6 {
            let bytes = (0..<(8 << 20)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            try Data(bytes).write(to: big.appendingPathComponent("r\(i).bin"))
        }
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        let op = await MainActor.run { () -> QueuedOperation in
            let form = CompressForm(items: [big], model: model)
            form.format = .tarXz
            form.level = .smallest
            form.start()
            return model.center.active[0]
        }
        await eventually("the operation to start") { op.state == .running }
        op.cancel()
        await waitForIdle(model)
        XCTAssertEqual(op.state, .cancelled)
        await MainActor.run { XCTAssertTrue(platform.errors.isEmpty, "a cancellation is not an error") }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("big") && $0 != "big" }
        XCTAssertEqual(leftovers, [], "no partial archive is left behind")
    }

    func testPausedOperationCanBeResumedOrStopped() async throws {
        let big = dir.appendingPathComponent("pausable", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 0..<4 { try Data(repeating: UInt8(i), count: 16 << 20).write(to: big.appendingPathComponent("z\(i).bin")) }
        let model = await MainActor.run { makeModel() }
        func start() async -> QueuedOperation {
            await MainActor.run {
                let form = CompressForm(items: [big], model: model)
                form.format = .tarXz
                form.level = .smallest
                form.start()
                return model.center.active.last!
            }
        }
        // Pause then resume: it completes.
        let a = await start()
        await eventually("running") { a.state == .running }
        a.pause()
        XCTAssertEqual(a.state, .paused)
        a.resume()
        await waitForIdle(model)
        XCTAssertEqual(a.state, .succeeded)
        // Pause then stop (the Activity row's ✕ while paused): it must not hang.
        let b = await start()
        await eventually("running") { b.state == .running }
        b.pause()
        b.cancel()
        await waitForIdle(model)
        XCTAssertEqual(b.state, .cancelled)
    }

    func testQuitWhileWorkingCancelsEverything() async throws {
        let model = await MainActor.run { makeModel() }
        let count = await MainActor.run { () -> Int in
            for _ in 0..<3 {
                let form = CompressForm(items: [source], model: model)
                form.format = .tarXz
                form.start()
            }
            return model.cancelAllOperations()
        }
        XCTAssertGreaterThanOrEqual(count, 0)
        await waitForIdle(model)
        await MainActor.run { XCTAssertFalse(model.hasActiveOperations) }
    }

    func testBackgroundCompletionNotifiesOnlyWhenTheAppIsInactiveAndEnabled() async {
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        await MainActor.run {
            platform.appActive = false
            let form = CompressForm(items: [source.appendingPathComponent("a.txt")], model: model)
            form.start()
        }
        await waitForIdle(model)
        await MainActor.run {
            XCTAssertEqual(platform.notifications.count, 1)
            model.settings.notificationsEnabled = false
            model.applySettings()
            let form = CompressForm(items: [source.appendingPathComponent("b.txt")], model: model)
            form.start()
        }
        await waitForIdle(model)
        await MainActor.run { XCTAssertEqual(platform.notifications.count, 1, "notifications were turned off") }
    }
}

// MARK: - Tools window

final class ToolsFlowTests: AppFlowTestCase {
    func testSwitchingToolsKeepsEachToolsInputsAndResults() async {
        let model = await MainActor.run { makeModel() }
        let tools = await MainActor.run { ToolsState() }
        await MainActor.run {
            model.selectedTool = .test
            tools.test.archives = [zip]
            tools.test.run(model)
        }
        await waitForIdle(model)
        await eventually("report") { !tools.test.reports.isEmpty && !tools.test.isRunning }
        await MainActor.run {
            // Go through every other tool, then back.
            for t in Tool.allCases { model.selectedTool = t }
            tools.compare.left = zip
            model.selectedTool = .test
            XCTAssertEqual(tools.test.archives, [zip])
            XCTAssertEqual(tools.test.reports.first?.result, .passed)
            model.selectedTool = .compare
            XCTAssertEqual(tools.compare.left, zip)
            for t in Tool.allCases {
                XCTAssertFalse(t.title.isEmpty)
                XCTAssertFalse(t.summary.isEmpty)
                XCTAssertFalse(t.symbol.isEmpty)
            }
        }
    }

    func testIntegrityToolReportsDamagedAndUnreadableArchives() async throws {
        let notArchive = dir.appendingPathComponent("plain.zip")
        try Data(repeating: 1, count: 100).write(to: notArchive)
        let model = await MainActor.run { makeModel() }
        let tools = await MainActor.run { ToolsState() }
        await MainActor.run { tools.test.archives = [zip, notArchive]; tools.test.run(model) }
        await waitForIdle(model)
        await eventually("reports") { tools.test.reports.count == 2 }
        await MainActor.run {
            XCTAssertEqual(tools.test.reports[0].result, .passed)
            XCTAssertNotEqual(tools.test.reports[1].result, .passed)
            XCTAssertFalse(tools.test.reportText.isEmpty)
        }
    }

    func testRepairAnalyzeAndRecover() async throws {
        var bytes = try Data(contentsOf: zip)
        let cd = bytes.range(of: Data([0x50, 0x4B, 0x01, 0x02]))!.lowerBound
        bytes = bytes.prefix(cd)
        let damaged = dir.appendingPathComponent("Damaged.zip")
        try bytes.write(to: damaged)
        let out = dir.appendingPathComponent("recovered", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let model = await MainActor.run { makeModel() }
        let tools = await MainActor.run { ToolsState() }
        await MainActor.run { tools.repair.setArchive(damaged); tools.repair.analyze(model) }
        await waitForIdle(model)
        await eventually("analysis") { tools.repair.analysis != nil && !tools.repair.isRunning }
        await MainActor.run {
            XCTAssertEqual(tools.repair.analysis?.isDamaged, true)
            tools.repair.recover(model, to: out)
        }
        await waitForIdle(model)
        await eventually("recovery report") { tools.repair.report != nil }
        await MainActor.run { XCTAssertGreaterThanOrEqual(tools.repair.report?.recovered.count ?? 0, 4) }
        // Choosing another archive clears the old results.
        await MainActor.run {
            tools.repair.setArchive(zip)
            XCTAssertNil(tools.repair.analysis)
            XCTAssertNil(tools.repair.report)
        }
    }

    func testRepairResultsForAnArchiveTheUserSwitchedAwayFromAreDropped() async throws {
        let model = await MainActor.run { makeModel() }
        let tools = await MainActor.run { ToolsState() }
        await MainActor.run {
            tools.repair.setArchive(tarGz)
            tools.repair.analyze(model)
            // The user picks a different archive while the analysis runs.
            tools.repair.setArchive(zip)
        }
        await waitForIdle(model)
        await MainActor.run {
            if let a = tools.repair.analysis {
                XCTAssertEqual(a.archive, zip.lastPathComponent, "the analysis shown belongs to \(a.archive), not to the chosen archive")
            }
        }
    }

    func testConvertBatchExtractCompareAndDuplicates() async throws {
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        let tools = await MainActor.run { ToolsState() }
        // Convert ZIP → (first preset).
        await MainActor.run {
            tools.convert.archives = [zip]
            tools.convert.presetIndex = ConversionPresets.all.firstIndex { $0.settings.encryption == nil && $0.settings.format != .zip } ?? 0
            XCTAssertNil(tools.convert.problem)
        }
        await tools.convert.refreshWarnings(model)
        await MainActor.run {
            tools.convert.run(model)
            XCTAssertTrue(tools.convert.archives.isEmpty)
        }
        await waitForIdle(model)
        await MainActor.run { XCTAssertTrue(platform.errors.isEmpty, "\(platform.errors.map(\.0.explanation))") }

        // Batch extract both archives into one folder, one folder each; then again (skipped).
        let dest = dir.appendingPathComponent("batch", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        await MainActor.run {
            tools.batch.archives = [zip, tarGz]
            tools.batch.destination = dest
            tools.batch.run(model)
        }
        await waitForIdle(model)
        await eventually("batch report") { tools.batch.report != nil && !tools.batch.isRunning }
        await MainActor.run {
            XCTAssertEqual(tools.batch.report?.succeeded, 2)
            tools.batch.run(model)
        }
        await waitForIdle(model)
        await eventually("second batch report") { tools.batch.report != nil && !tools.batch.isRunning }
        await MainActor.run { XCTAssertEqual(tools.batch.report?.skipped, 2, "already-extracted archives are skipped") }

        // Compare: same content in two formats.
        await MainActor.run {
            tools.compare.left = zip
            tools.compare.right = tarGz
            tools.compare.compareContents = true
            tools.compare.run(model)
        }
        await waitForIdle(model)
        await eventually("comparison") { tools.compare.result != nil }
        await MainActor.run { XCTAssertEqual(tools.compare.result?.isIdentical, true) }

        // Duplicates: every file appears in both archives.
        await MainActor.run { tools.duplicates.archives = [zip, tarGz]; tools.duplicates.run(model) }
        await waitForIdle(model)
        await eventually("duplicates") { !tools.duplicates.groups.isEmpty }
        await MainActor.run { XCTAssertFalse(tools.duplicates.reportText.isEmpty) }
    }

    func testBatchExtractDoesNotSkipADifferentArchiveWithTheSameName() async throws {
        let model = await MainActor.run { makeModel() }
        let tools = await MainActor.run { ToolsState() }
        let dest = dir.appendingPathComponent("same-name", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        await MainActor.run {
            tools.batch.archives = [zip, tarGz]   // Project.zip and Project.tar.gz
            tools.batch.destination = dest
            tools.batch.skipAlreadyExtracted = true
            tools.batch.run(model)
        }
        await waitForIdle(model)
        await eventually("batch report") { tools.batch.report != nil && !tools.batch.isRunning }
        await MainActor.run {
            XCTAssertEqual(tools.batch.report?.succeeded, 2, tools.batch.report?.textReport ?? "")
            XCTAssertEqual(tools.batch.report?.skipped, 0)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dest.path)), ["Project", "Project 2"])
    }

    func testChecksumsCalculateManifestAndVerify() async throws {
        let model = await MainActor.run { makeModel() }
        let tool = await MainActor.run { ChecksumTool() }
        let a = source.appendingPathComponent("a.txt")
        await MainActor.run { tool.files = [a]; tool.calculate(model) }
        await waitForIdle(model)
        await eventually("checksum") { tool.results.count == 1 }
        await MainActor.run {
            let digest = tool.results[0].digest
            XCTAssertEqual(digest, "8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8")
            tool.expected = digest.uppercased() + "\n"
            XCTAssertEqual(tool.matches(tool.results[0]), true)
            tool.expected = "nope"
            XCTAssertEqual(tool.matches(tool.results[0]), false)
            tool.expected = ""
            XCTAssertNil(tool.matches(tool.results[0]))
        }
        let manifest = dir.appendingPathComponent("Project/checksums.sha256")
        let text = try await MainActor.run { try tool.manifestText() }
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        await tool.verify(manifest: manifest, model: model)
        await MainActor.run { XCTAssertEqual(tool.verification?.passed, true) }
        // Results belong to the files they were calculated for.
        await MainActor.run {
            tool.files = [source.appendingPathComponent("b.txt")]
            XCTAssertTrue(tool.results.allSatisfy { tool.files.contains($0.file) },
                          "results for files no longer in the list are still shown")
        }
    }

    func testChecksumFileForAFolderSelectionDoesNotFail() async throws {
        let model = await MainActor.run { makeModel() }
        let tool = await MainActor.run { ChecksumTool() }
        await MainActor.run {
            // Services and drops can hand the tool a folder along with files.
            tool.files = [source.appendingPathComponent("a.txt"), source.appendingPathComponent("docs", isDirectory: true)]
            do { _ = try tool.manifestText() } catch { XCTFail("Save Checksum File… failed: \(error)") }
            tool.calculate(model)
        }
        await waitForIdle(model)
        await eventually("checksum") { !tool.results.isEmpty }
    }

    func testSplitAndJoin() async throws {
        let platform = await MainActor.run { RecordingPlatform() }
        let model = await MainActor.run { makeModel(platform) }
        let tool = await MainActor.run { SplitJoinTool() }
        let file = source.appendingPathComponent("docs/sub/deep.txt")
        await MainActor.run {
            tool.partSize = "nonsense"
            XCTAssertFalse(tool.isValidSize)
            tool.partSize = "4 KB"
            XCTAssertTrue(tool.isValidSize)
            tool.split(file, model: model)
        }
        await waitForIdle(model)
        let first = file.deletingLastPathComponent().appendingPathComponent("deep.txt.001")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        let original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        await MainActor.run { tool.join(first, model: model) }
        await waitForIdle(model)
        XCTAssertEqual(try Data(contentsOf: file), original)
        await MainActor.run {
            XCTAssertTrue(platform.errors.isEmpty)
            XCTAssertEqual(model.center.finished.last?.summary, "Joined and verified")
        }
    }
}

// MARK: - Settings

final class SettingsFlowTests: AppFlowTestCase {
    func testChangedSettingsPersistAcrossRelaunchAndReachTheServices() async {
        let suite = "ZipperFlowSettings-\(UUID().uuidString)"
        await MainActor.run {
            let model = AppModel(platform: RecordingPlatform(), defaults: UserDefaults(suiteName: suite)!, supportDirectory: dir.appendingPathComponent("Support"))
            model.settings.defaultFormat = .sevenZip
            model.settings.performanceMode = .energySaver
            model.settings.conflictPolicy = .skip
            model.settings.preferredEngines = ["zip": "7zip"]
            model.applySettings()
            XCTAssertEqual(model.service.performanceMode, .energySaver)
            XCTAssertEqual(model.center.mode, .energySaver)
            XCTAssertEqual(model.service.registry.preferred[.zip], EngineID(rawValue: "7zip"))
            XCTAssertEqual(model.extractionOptions().conflictPolicy, .skip)
        }
        await MainActor.run {
            let relaunched = AppModel(platform: RecordingPlatform(), defaults: UserDefaults(suiteName: suite)!, supportDirectory: dir.appendingPathComponent("Support"))
            XCTAssertEqual(relaunched.settings.defaultFormat, .sevenZip)
            XCTAssertEqual(relaunched.settings.performanceMode, .energySaver)
            XCTAssertEqual(CompressForm(items: [source], model: relaunched).format, .sevenZip, "new sheets use the default format")
        }
    }

    func testHistoryRecordsOperationsAndClearingRefreshesEveryList() async {
        let model = await MainActor.run { () -> AppModel in
            let m = makeModel()   // history lives in this test's own folder
            m.settings.historyEnabled = true
            m.settings.historyStoresPaths = false
            m.applySettings()
            CompressForm(items: [source.appendingPathComponent("a.txt")], model: m).start()
            return m
        }
        await waitForIdle(model)
        await MainActor.run {
            let records = model.history.all()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.inputs, ["a.txt"], "names only when “Include full paths” is off")
            let before = model.historyVersion
            model.clearHistory()   // Settings › Privacy and Activity › History both call this
            XCTAssertNotEqual(model.historyVersion, before, "Activity › History reloads when the version changes")
            XCTAssertTrue(model.history.all().isEmpty)
        }
    }

    func testExtractFormStartsFromTheSettings() async {
        await MainActor.run {
            let model = makeModel()
            model.settings.extractionMode = .newFolder
            model.settings.verifyAfterExtraction = true
            model.settings.defaultExtractionDestination = dir.path
            model.applySettings()
            let form = ExtractForm(archive: zip, model: model)
            XCTAssertEqual(form.mode, .newFolder)
            XCTAssertTrue(form.verify)
            XCTAssertEqual(form.effectiveDestination.standardizedFileURL.path, dir.standardizedFileURL.path)
            form.setDestination(nil)
            XCTAssertEqual(form.effectiveDestination.standardizedFileURL.path, zip.deletingLastPathComponent().standardizedFileURL.path)
        }
    }
}

// MARK: - The browser with hostile and huge archives

final class BrowserRobustnessTests: XCTestCase {
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    func listing(_ paths: [(String, EntryType)]) -> ArchiveListing {
        ArchiveListing(properties: ArchiveProperties(format: .zip, engine: .libarchive),
                       entries: paths.enumerated().map { i, e in ArchiveEntry(index: i, path: e.0, type: e.1, uncompressedSize: 1) })
    }

    /// Walks every folder of the index the way a user clicking through the browser would.
    @MainActor
    func walk(_ state: BrowserState, file: StaticString = #filePath, line: UInt = #line) -> Int {
        var seen = 0
        var queue = [""]
        var visited = Set<String>()
        while let folder = queue.popLast() {
            guard visited.insert(folder).inserted else { continue }
            XCTAssertLessThan(visited.count, 100_000, "folder walk doesn't terminate", file: file, line: line)
            state.open(folder: folder)
            for r in state.rows {
                seen += 1
                XCTAssertFalse(r.name.isEmpty, "a row with no name in “\(folder)”", file: file, line: line)
                if r.isFolder { queue.append(r.path) }
            }
            state.goUp()
        }
        return seen
    }

    func testHostilePathsNeitherCrashNorLoop() async {
        let index = FolderIndex(listing: listing([
            ("../../etc/passwd", .file), ("/abs/file.txt", .file), ("a//b.txt", .file), ("./c.txt", .file),
            ("dup.txt", .file), ("dup.txt", .file), ("dir/", .directory), ("dir", .directory), ("x/./y.txt", .file),
            ("", .file), (".", .directory), ("..", .directory), ("deep/" + String(repeating: "d/", count: 300) + "f.txt", .file),
            ("win\\style\\path.txt", .file), ("dir/inner.txt", .file),
        ]))
        await MainActor.run {
            let state = BrowserState(url: URL(fileURLWithPath: "/tmp/hostile.zip"))
            state.show(nil, index: index)
            XCTAssertGreaterThan(walk(state), 5)
            state.searchText = "passwd"
            _ = state.rows
            state.searchText = ""
            for mode in BrowserState.ViewMode.allCases { state.viewMode = mode; _ = state.rows(in: "") }
        }
    }

    func testEveryFixtureCanBeBrowsed() async throws {
        let fm = FileManager.default
        let service = ArchiveService()
        var opened = 0
        let urls = (fm.enumerator(at: Self.fixtures, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath && !(try! $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false) }
        for url in urls {
            guard let o = try? service.open(url) else { continue }   // encrypted, unsupported or deliberately broken
            opened += 1
            let index = FolderIndex(listing: o.listing)
            await MainActor.run {
                let state = BrowserState(url: url)
                state.show(o, index: index)
                _ = walk(state)
            }
        }
        XCTAssertGreaterThan(opened, 30, "expected to browse most fixtures")
    }

    func testHugeArchiveIndexesAndBrowsesQuickly() async {
        var paths: [(String, EntryType)] = []
        for d in 0..<2_000 {
            for f in 0..<100 { paths.append(("folder\(d)/file\(f).txt", .file)) }
            paths.append(("folder\(d)/", .directory))   // directory entries after their files (as some tools write them)
        }
        let big = listing(paths)
        let start = Date()
        let index = FolderIndex(listing: big)
        let built = Date().timeIntervalSince(start)
        XCTAssertLessThan(built, 10, "indexing 202,000 entries took \(built) s")
        await MainActor.run {
            let state = BrowserState(url: URL(fileURLWithPath: "/tmp/huge.zip"))
            state.show(nil, index: index)
            let t = Date()
            XCTAssertEqual(state.rows.count, 2_000)
            state.open(folder: "folder1999")
            XCTAssertEqual(state.rows.count, 100)
            state.searchText = "file99.txt"
            XCTAssertEqual(state.rows.count, 2_000)
            XCTAssertLessThan(Date().timeIntervalSince(t), 10, "browsing the huge archive is too slow")
        }
    }
}

// MARK: - Nothing outlives its use (the app runs for days)

final class LifetimeTests: AppFlowTestCase {
    func testArchiveServiceIsFreedAfterUse() throws {
        weak var weakService: ArchiveService?
        try {
            let service = ArchiveService()
            weakService = service
            let out = dir.appendingPathComponent("lifetime", isDirectory: true)
            _ = try service.compress(CompressRequest(items: [source], destinationDirectory: out.deletingLastPathComponent(),
                                                     archiveName: "life", settings: CompressionSettings(format: .zip)))
            _ = try service.extract(ExtractRequest(archive: zip, destination: out))
            _ = try service.test(tarGz)
            _ = try service.modify(ModifyRequest(archive: dir.appendingPathComponent("life.zip"), edits: [.createFolder(path: "x")]))
        }()
        XCTAssertNil(weakService, "ArchiveService (and its engines) leaked")
    }

    /// Compressing linked the operation's progress and a per-archive child progress both ways (a
    /// retain cycle), so every compression — finished or cancelled — leaked both, with their handlers.
    func testCompressionFreesItsProgressObjects() throws {
        let big = dir.appendingPathComponent("big", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        var rng = SystemRandomNumberGenerator()
        try Data((0..<(24 << 20)).map { _ in UInt8.random(in: 0...255, using: &rng) }).write(to: big.appendingPathComponent("r.bin"))
        for cancelMidway in [false, true] {
            weak var weakProgress: OperationProgress?
            try {
                let p = OperationProgress()
                weakProgress = p
                if cancelMidway { DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { p.cancel() } }
                let request = CompressRequest(items: [cancelMidway ? big : source], destinationDirectory: dir,
                                              archiveName: "p\(cancelMidway)", settings: CompressionSettings(format: .tarBzip2, level: 9))
                if cancelMidway {
                    XCTAssertThrowsError(try ArchiveService().compress(request, progress: p))
                } else {
                    _ = try ArchiveService().compress(request, progress: p)
                }
            }()
            // After a cancellation the libarchive handle is closed on a background queue.
            let deadline = Date().addingTimeInterval(10)
            while weakProgress != nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            XCTAssertNil(weakProgress, "the progress object leaked (cancelled midway: \(cancelMidway))")
        }
    }

    func testAppModelIsFreedAfterOpeningEditingAndClosing() async throws {
        weak var weakModel: AppModel?
        weak var weakState: BrowserState?
        do {
            let model = await MainActor.run { makeModel() }
            await MainActor.run { weakModel = model }
            let state = await openAndWait(model, zip)
            await MainActor.run {
                weakState = state
                model.test(state)
                model.createFolder(named: "New", in: state)
            }
            await waitForIdle(model)
            await MainActor.run {
                model.beginCompress([source])
                model.sheet = nil                 // the sheet closes
                model.closeArchive(zip)
                model.center.clearFinished()
            }
        }
        // Let pending main-actor work (completion handlers, reloads) drain.
        for _ in 0..<20 { await MainActor.run {}; try? await Task.sleep(nanoseconds: 50_000_000) }
        await MainActor.run {
            XCTAssertNil(weakState, "a closed archive's BrowserState leaked")
            XCTAssertNil(weakModel, "AppModel leaked")
        }
    }
}
