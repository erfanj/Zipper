import XCTest

/// Drives the real Zipper.app (Debug build) through its windows, menus, sidebar, sheets and
/// keyboard shortcuts. Built by project.yml (target ZipperUITests) and run on macOS CI.
///
/// Files are handed to the app with the Debug-only `-ZipperUITestOpen PATH` launch option (see
/// UITestHooks in ZipperApp.swift), the same path as a double-click in Finder.
final class ZipperUITests: XCTestCase {
    var app: XCUIApplication!
    var work: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        work = FileManager.default.temporaryDirectory.appendingPathComponent("ZipperUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-ZipperUITesting", "YES", "-ApplePersistenceIgnoreState", "YES"]
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning { app.terminate() }
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: Helpers

    func launch(opening path: URL? = nil) {
        if let path { app.launchArguments += ["-ZipperUITestOpen", path.path] }
        app.launch()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 20), "the main window didn't appear; windows: \(windowIDs)")
    }

    var windowIDs: [String] { app.windows.allElementsBoundByIndex.map { "\($0.identifier) “\($0.title)”" } }

    /// SwiftUI names a scene's window after its id ("main-AppWindow-1").
    func window(_ id: String) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier BEGINSWITH %@", id)).firstMatch
    }

    var mainWindow: XCUIElement { window("main") }
    var toolsWindow: XCUIElement { window("tools") }
    var settingsWindow: XCUIElement { app.windows.matching(NSPredicate(format: "identifier CONTAINS[c] 'settings'")).firstMatch }

    func menu(_ bar: String, _ item: String) {
        app.menuBarItems[bar].click()
        let i = app.menuBarItems[bar].menuItems[item]
        XCTAssertTrue(i.waitForExistence(timeout: 5), "no menu item \(bar) › \(item)")
        i.click()
    }

    func sidebar(_ window: XCUIElement) -> XCUIElement { window.outlines.firstMatch }

    func text(_ s: String, in e: XCUIElement) -> XCUIElement {
        e.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", s, s)).firstMatch
    }

    func waitGone(_ e: XCUIElement, _ timeout: TimeInterval = 10) -> Bool {
        let p = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        return XCTWaiter().wait(for: [p], timeout: timeout) == .completed
    }

    func makeSample() throws -> URL {
        let folder = work.appendingPathComponent("Sample")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs/sub"), withIntermediateDirectories: true)
        try Data("# Read me\n".utf8).write(to: folder.appendingPathComponent("docs/readme.md"))
        try Data(String(repeating: "deep ", count: 500).utf8).write(to: folder.appendingPathComponent("docs/sub/deep.txt"))
        try Data("alpha".utf8).write(to: folder.appendingPathComponent("a.txt"))
        return folder
    }

    func makeZip() throws -> URL {
        let folder = try makeSample()
        let zip = work.appendingPathComponent("Sample.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        try FileManager.default.removeItem(at: folder)
        return zip
    }

    // MARK: Main window and sidebar

    func testLaunchShowsHomeAndTheSidebarMovesBetweenHomeAndActivity() throws {
        launch()
        let main = mainWindow
        XCTAssertTrue(text("Drop files here to compress them, or drop an archive to open it.", in: main).waitForExistence(timeout: 10))
        for label in ["Compress", "Extract", "Open"] {
            XCTAssertTrue(main.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label + ".")).firstMatch.exists, "\(label) card")
        }
        // Home → Activity → Home → Activity, by clicking the sidebar.
        for _ in 0..<2 {
            text("Activity", in: sidebar(main)).click()
            XCTAssertTrue(text("Nothing Running", in: main).waitForExistence(timeout: 5))
            text("Home", in: sidebar(main)).click()
            XCTAssertTrue(text("Drop files here to compress them, or drop an archive to open it.", in: main).waitForExistence(timeout: 5))
        }
        // Tools › Activity (⌥⌘L) from the menu bar.
        main.typeKey("l", modifierFlags: [.command, .option])
        XCTAssertTrue(text("Nothing Running", in: main).waitForExistence(timeout: 5))
    }

    func testArchiveMenuIsDisabledWithoutAnOpenArchive() throws {
        launch()
        app.menuBarItems["Archive"].click()
        for item in ["Extract", "Extract To…", "Test Integrity", "Add Files…", "Delete…", "Close Archive"] {
            let i = app.menuBarItems["Archive"].menuItems[item]
            XCTAssertTrue(i.exists, "Archive › \(item) is missing")
            XCTAssertFalse(i.isEnabled, "Archive › \(item) should be disabled on Home")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: Tools window

    func testToolsWindowOpensFromTheMenuSwitchesToolsClosesAndReopens() throws {
        launch()
        menu("Tools", "Compare…")
        XCTAssertTrue(toolsWindow.waitForExistence(timeout: 10), "Tools window; windows: \(windowIDs)")
        let tools = toolsWindow
        XCTAssertTrue(text("Shows which files were added, removed or changed between two archives.", in: tools).waitForExistence(timeout: 5))
        let summaries = [
            "Test Integrity": "Decodes every file and checks the stored checksums",
            "Repair": "Recovers the readable files from a damaged archive",
            "Convert": "Re-packs archives in another format",
            "Batch Extract": "Extracts many archives at once.",
            "Checksums": "Calculates, compares and verifies file checksums.",
            "Split & Join": "Splits any file into numbered parts",
            "Find Duplicates": "Finds identical files inside and across archives",
            "Compare": "Shows which files were added, removed or changed",
        ]
        for (tool, summary) in summaries {
            text(tool, in: sidebar(tools)).click()
            XCTAssertTrue(tools.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", summary)).firstMatch.waitForExistence(timeout: 5),
                          "selecting \(tool) didn't show it")
        }
        // Close with ⌘W, then reopen from the menu: it comes back on the chosen tool.
        tools.click()
        tools.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitGone(toolsWindow), "⌘W didn't close the Tools window")
        XCTAssertTrue(mainWindow.exists, "closing Tools must not close the main window")
        menu("Tools", "Checksums…")
        XCTAssertTrue(toolsWindow.waitForExistence(timeout: 10))
        XCTAssertTrue(text("Calculates, compares and verifies file checksums.", in: toolsWindow).waitForExistence(timeout: 5))
        // The Home toolbar's Tools menu opens the same window.
        toolsWindow.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitGone(toolsWindow))
    }

    // MARK: Settings window

    func testSettingsOpensEveryTabAndCloses() throws {
        launch()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window; windows: \(windowIDs)")
        let s = settingsWindow
        let tabs: [(String, String)] = [("Compression", "Include hidden files"), ("Extraction", "Restore Defaults"),
                                        ("Privacy", "Keep a history of operations"), ("Advanced", "Show Supported Formats…"),
                                        ("General", "Show new archives in Finder")]
        for (tab, marker) in tabs {
            s.toolbars.buttons[tab].click()
            let found = s.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR title == %@ OR value == %@", marker, marker, marker)).firstMatch
            XCTAssertTrue(found.waitForExistence(timeout: 5), "\(tab) tab didn't show “\(marker)”")
        }
        // A sheet inside Settings opens and closes.
        s.toolbars.buttons["Advanced"].click()
        s.buttons["Show Supported Formats…"].click()
        XCTAssertTrue(s.sheets.firstMatch.waitForExistence(timeout: 5))
        s.sheets.firstMatch.buttons["Done"].click()
        XCTAssertTrue(waitGone(s.sheets.firstMatch))
        s.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitGone(settingsWindow), "⌘W didn't close Settings")
        XCTAssertTrue(mainWindow.exists)
    }

    // MARK: Closing windows and quitting

    func testClosingTheMainWindowQuitsOnlyWhenNothingElseIsOpen() throws {
        launch()
        // With Tools open, closing the main window keeps the app running…
        menu("Tools", "Repair…")
        XCTAssertTrue(toolsWindow.waitForExistence(timeout: 10))
        mainWindow.click()
        mainWindow.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitGone(mainWindow), "⌘W didn't close the main window")
        XCTAssertEqual(app.state, .runningForeground)
        // …and Tools › Activity brings the main window back, showing Activity.
        menu("Tools", "Activity")
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10), "the main window didn't come back")
        XCTAssertTrue(text("Nothing Running", in: mainWindow).waitForExistence(timeout: 5))
        // Close Tools, then the main window: the last window closing quits the app.
        toolsWindow.click()
        toolsWindow.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitGone(toolsWindow))
        mainWindow.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "closing the last window should quit")
    }

    func testQuitWithCommandQ() throws {
        launch()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    // MARK: Archive browser

    func testOpenBrowseSwitchAwayComeBackAndCloseAnArchive() throws {
        let zip = try makeZip()
        launch(opening: zip)
        let main = mainWindow
        XCTAssertTrue(text("Sample.zip", in: sidebar(main)).waitForExistence(timeout: 20), "the archive didn't appear in the sidebar")
        // ditto --keepParent puts everything in "Sample"; open it, then "docs".
        let sample = text("Sample", in: main.tables.firstMatch)
        XCTAssertTrue(sample.waitForExistence(timeout: 20), "listing didn't load")
        sample.doubleClick()
        let docs = text("docs", in: main.tables.firstMatch)
        XCTAssertTrue(docs.waitForExistence(timeout: 5))
        docs.doubleClick()
        XCTAssertTrue(text("readme.md", in: main.tables.firstMatch).waitForExistence(timeout: 5))
        // ⌘↑ goes up a level.
        main.typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(text("docs", in: main.tables.firstMatch).waitForExistence(timeout: 5))
        // Away to Home and Activity, and back: the archive is still there.
        text("Home", in: sidebar(main)).click()
        XCTAssertTrue(text("Drop files here to compress them, or drop an archive to open it.", in: main).waitForExistence(timeout: 5))
        text("Activity", in: sidebar(main)).click()
        XCTAssertTrue(text("Nothing Running", in: main).waitForExistence(timeout: 5))
        text("Sample.zip", in: sidebar(main)).click()
        XCTAssertTrue(main.tables.firstMatch.waitForExistence(timeout: 5))
        // Show Info (⌘I) twice: the inspector opens and closes.
        main.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(text("Engine", in: main).waitForExistence(timeout: 5), "the inspector didn't open")
        main.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(waitGone(text("Engine", in: main)), "the inspector didn't close")
        // Archive › Test Integrity, then Archive › Close Archive.
        menu("Archive", "Test Integrity")
        XCTAssertTrue(text("Verified", in: main).waitForExistence(timeout: 30), "the status bar didn't report the test result")
        menu("Archive", "Close Archive")
        XCTAssertTrue(waitGone(text("Sample.zip", in: sidebar(main))), "the archive is still in the sidebar")
        XCTAssertTrue(text("Drop files here to compress them, or drop an archive to open it.", in: main).waitForExistence(timeout: 5))
    }

    func testExtractAllFromTheBrowserToolbar() throws {
        let zip = try makeZip()
        launch(opening: zip)
        let main = mainWindow
        XCTAssertTrue(text("Sample", in: main.tables.firstMatch).waitForExistence(timeout: 20))
        main.typeKey("e", modifierFlags: .command)
        let out = work.appendingPathComponent("Sample/docs/sub/deep.txt")
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: out.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "⌘E didn't extract next to the archive")
    }

    // MARK: Sheets

    func testCompressSheetCancelsWithEscapeAndCompressesWithReturn() throws {
        let folder = try makeSample()
        launch(opening: folder)
        let main = mainWindow
        let sheet = main.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "opening a folder should start the Compress sheet")
        XCTAssertTrue(sheet.buttons["Compress"].exists)
        sheet.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitGone(sheet), "Escape didn't cancel the sheet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("Sample.zip").path), "Cancel must not create anything")
        app.terminate()

        launch(opening: folder)
        let again = mainWindow.sheets.firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 15))
        XCTAssertTrue(again.buttons["Compress"].isEnabled)
        again.buttons["Compress"].click()
        XCTAssertTrue(waitGone(again))
        let zip = work.appendingPathComponent("Sample.zip")
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: zip.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path), "Compress didn't create Sample.zip")
        // Activity lists the finished operation.
        text("Activity", in: sidebar(mainWindow)).click()
        // Each row combines its texts into one accessibility element.
        let row = mainWindow.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Compress Sample' OR value CONTAINS 'Compress Sample'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Activity doesn't list the compression")
    }
}
