import XCTest

/// Drives the real Zipper.app (Debug build) through its windows, menus, sidebar, sheets and
/// keyboard shortcuts. Built by project.yml (target ZipperUITests) and run on macOS CI.
///
/// Sample files are made by the app itself (Debug-only `-ZipperUITestOpen fixture:folder|zip`, see
/// UITestHooks in ZipperApp.swift) and opened the way a double-click in Finder opens them. Results
/// are checked in the app (Activity), not on disk: the test runner's own files can sit in its
/// container, which macOS protects from other apps.
final class ZipperUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ZipperUITesting", "YES", "-ApplePersistenceIgnoreState", "YES"]
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning { app.terminate() }
    }

    // MARK: Helpers

    /// `fixture` is "folder" or "zip".
    func launch(opening fixture: String? = nil) {
        app.launchArguments = ["-ZipperUITesting", "YES", "-ApplePersistenceIgnoreState", "YES"]
        if let fixture { app.launchArguments += ["-ZipperUITestOpen", "fixture:" + fixture] }
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

    /// Any element (cell text, button, row…) showing exactly `s`.
    func anything(_ s: String, in e: XCUIElement) -> XCUIElement {
        e.descendants(matching: .any).matching(NSPredicate(format: "value == %@ OR label == %@ OR title == %@", s, s, s)).firstMatch
    }

    /// An Activity row (its texts are combined into one element) mentioning `s`.
    func activity(_ s: String) -> XCUIElement {
        mainWindow.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)).firstMatch
    }

    func dumpOnFailure(_ ok: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard !ok else { return }
        print("UI-DUMP \(what):\n\(app.debugDescription)")
        XCTFail(what, file: file, line: line)
    }

    func waitGone(_ e: XCUIElement, _ timeout: TimeInterval = 10) -> Bool {
        let p = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: e)
        return XCTWaiter().wait(for: [p], timeout: timeout) == .completed
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
        // Bring Tools forward from its menu (the main window now covers it), close it, then close
        // the main window: the last window closing quits the app.
        menu("Tools", "Repair…")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitGone(toolsWindow), "⌘W didn't close the Tools window")
        XCTAssertTrue(mainWindow.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "closing the last window should quit")
    }

    func testQuitWithCommandQ() throws {
        launch()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    // MARK: Archive browser

    func testOpenBrowseSwitchAwayComeBackAndCloseAnArchive() throws {
        launch(opening: "zip")
        let main = mainWindow
        XCTAssertTrue(text("Sample.zip", in: sidebar(main)).waitForExistence(timeout: 20), "the archive didn't appear in the sidebar")
        // The archive holds one folder, "Sample"; open it, then "docs".
        let sample = anything("Sample", in: main)
        dumpOnFailure(sample.waitForExistence(timeout: 20), "the listing didn't load")
        sample.doubleClick()
        let docs = anything("docs", in: main)
        dumpOnFailure(docs.waitForExistence(timeout: 5), "double-clicking Sample didn't open it")
        docs.doubleClick()
        dumpOnFailure(anything("readme.md", in: main).waitForExistence(timeout: 5), "double-clicking docs didn't open it")
        // ⌘↑ goes up a level.
        main.typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(waitGone(anything("readme.md", in: main)), "⌘↑ didn't leave docs")
        XCTAssertTrue(anything("docs", in: main).waitForExistence(timeout: 5))
        // Away to Home and Activity, and back: the archive is still there.
        text("Home", in: sidebar(main)).click()
        XCTAssertTrue(text("Drop files here to compress them, or drop an archive to open it.", in: main).waitForExistence(timeout: 5))
        text("Activity", in: sidebar(main)).click()
        XCTAssertTrue(text("Nothing Running", in: main).waitForExistence(timeout: 5))
        text("Sample.zip", in: sidebar(main)).click()
        XCTAssertTrue(anything("docs", in: main).waitForExistence(timeout: 5), "coming back lost the place in the archive")
        // Show Info (⌘I) twice: the inspector opens and closes.
        main.typeKey("i", modifierFlags: .command)
        dumpOnFailure(anything("Engine", in: main).waitForExistence(timeout: 5), "the inspector didn't open")
        main.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(waitGone(anything("Engine", in: main)), "the inspector didn't close")
        // Archive › Test Integrity, then Archive › Close Archive.
        menu("Archive", "Test Integrity")
        dumpOnFailure(anything("Verified", in: main).waitForExistence(timeout: 30), "the status bar didn't report the test result")
        menu("Archive", "Close Archive")
        XCTAssertTrue(waitGone(text("Sample.zip", in: sidebar(main))), "the archive is still in the sidebar")
        XCTAssertTrue(text("Drop files here to compress them, or drop an archive to open it.", in: main).waitForExistence(timeout: 5))
    }

    func testExtractAllWithCommandE() throws {
        launch(opening: "zip")
        let main = mainWindow
        dumpOnFailure(anything("Sample", in: main).waitForExistence(timeout: 20), "the listing didn't load")
        main.typeKey("e", modifierFlags: .command)
        text("Activity", in: sidebar(main)).click()
        dumpOnFailure(activity("files extracted").waitForExistence(timeout: 30), "⌘E didn't extract (no finished extraction in Activity)")
        XCTAssertTrue(activity("Extract Sample.zip").exists)
    }

    // MARK: Sheets

    func testCompressSheetCancelsWithEscape() throws {
        launch(opening: "folder")
        let sheet = mainWindow.sheets.firstMatch
        dumpOnFailure(sheet.waitForExistence(timeout: 15), "opening a folder should start the Compress sheet")
        XCTAssertTrue(sheet.buttons["Compress"].exists)
        sheet.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitGone(sheet), "Escape didn't cancel the sheet")
        text("Activity", in: sidebar(mainWindow)).click()
        XCTAssertTrue(text("Nothing Running", in: mainWindow).waitForExistence(timeout: 5), "Cancel must not start anything")
    }

    func testCompressSheetCompressesAndActivityListsIt() throws {
        launch(opening: "folder")
        let sheet = mainWindow.sheets.firstMatch
        dumpOnFailure(sheet.waitForExistence(timeout: 15), "opening a folder should start the Compress sheet")
        let compress = sheet.buttons["Compress"]
        XCTAssertTrue(compress.isEnabled)
        compress.click()
        XCTAssertTrue(waitGone(sheet))
        text("Activity", in: sidebar(mainWindow)).click()
        dumpOnFailure(activity("Sample.zip").waitForExistence(timeout: 30), "Activity doesn't list the new Sample.zip")
    }
}
