#if os(macOS)
import SwiftUI
import AppKit
import ArchiveCore
import ArchiverKit

@main
struct ZipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @State private var tools = ToolsState()

    init() {
        let model = AppModel(platform: MacPlatform())
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        // A single main window: archives open as items in its sidebar, so Finder, the Dock and
        // Services always have one obvious place to send files.
        Window(ProductInfo.name, id: "main") {
            MainWindow()
                .environment(model)
                .environment(tools)
        }
        .defaultSize(width: 1000, height: 640)
        .commands { AppCommands(model: model) }

        Window("Tools", id: "tools") {
            ToolsWindow()
                .environment(model)
                .environment(tools)
        }
        .defaultSize(width: 880, height: 600)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Receives files from Finder, the Dock and Services, and guards quitting while work is running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model = Self.model else { return }
        model.handleOpen(urls)
        model.openWindow?("main")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.model?.openWindow?("main") }
        return true
    }

    /// Quit when the last window closes, unless operations are still running in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(Self.model?.hasActiveOperations ?? false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.hasActiveOperations else { return .terminateNow }
        let count = model.center.active.count
        let alert = NSAlert()
        alert.messageText = count == 1 ? "An operation is still running." : "\(count) operations are still running."
        alert.informativeText = "If you quit, they are cancelled. Partly written archives and extracted files are removed; finished files are kept."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Quit Anyway")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.cancelAllOperations()
        // Give cancelled operations a moment to remove their partial output, then quit.
        Task { @MainActor in
            var waited = 0
            while model.hasActiveOperations, waited < 50 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Self.model?.settings.clearPreviewCacheOnQuit ?? true { PreviewCache.shared.clear() }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for url in (Self.model?.recentArchives ?? []).prefix(8) {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        let compress = NSMenuItem(title: "New Archive…", action: #selector(newArchive), keyEquivalent: "")
        compress.target = self
        menu.addItem(compress)
        return menu
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let model = Self.model else { return }
        model.openArchive(url)
        model.openWindow?("main")
    }

    @objc private func newArchive() {
        guard let model = Self.model else { return }
        NSApp.activate()
        model.openWindow?("main")
        if let urls = Panels.chooseItemsToCompress() { model.beginCompress(urls) }
    }
}

/// Menu-bar commands. Archive commands act on the archive shown in the main window.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            MainWindowButton("New Archive…") {
                if let urls = Panels.chooseItemsToCompress() { model.beginCompress(urls) }
            }
            .keyboardShortcut("n")
            MainWindowButton("Open…") {
                if let url = Panels.chooseArchive() { model.openArchive(url) }
            }
            .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(model.recentArchives, id: \.self) { url in
                    MainWindowButton(url.lastPathComponent) { model.openArchive(url) }
                }
                Divider()
                Button("Clear Menu") { model.clearRecents() }
                    .disabled(model.recentArchives.isEmpty)
            }
            Divider()
            MainWindowButton("Extract Archive…") {
                if let url = Panels.chooseArchive(prompt: "Extract", message: "Choose an archive to extract.") { model.beginExtract(url) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        CommandMenu("Archive") {
            let archive = model.currentArchive
            let ready = archive?.opened != nil
            let editable = ready && (archive?.isEditable ?? false)
            Button("Extract") { if let a = archive { model.extract(from: a, to: nil) } }
                .keyboardShortcut("e")
                .disabled(!ready)
            Button("Extract To…") {
                if let a = archive, let dest = Panels.chooseFolder(prompt: "Extract", directory: a.url.deletingLastPathComponent()) {
                    model.extract(from: a, to: dest)
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(!ready)
            Button("Test Integrity") { if let a = archive { model.test(a) } }
                .keyboardShortcut("t")
                .disabled(!ready)
            Divider()
            Button("Add Files…") { archive?.pendingCommand = .addFiles }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!editable)
            Button("New Folder…") { archive?.pendingCommand = .newFolder }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!editable)
            Button("Rename…") { archive?.pendingCommand = .rename }
                .disabled(!editable || archive?.selection.count != 1)
            Button("Delete…") { archive?.pendingCommand = .delete }
                .keyboardShortcut(.delete)
                .disabled(!editable || (archive?.selection.isEmpty ?? true))
            Divider()
            Button("Quick Look") { archive?.pendingCommand = .quickLook }
                .keyboardShortcut("y")
                .disabled(archive?.selectedEntry == nil)
            Button(model.showInspector ? "Hide Info" : "Show Info") { model.showInspector.toggle() }
                .keyboardShortcut("i")
                .disabled(archive == nil)
            Button("Show in Finder") { if let a = archive { model.platform.reveal([a.url]) } }
                .disabled(archive == nil)
            Divider()
            Button("Close Archive") { if let a = archive { model.closeArchive(a.url) } }
                .disabled(archive == nil)
        }

        CommandMenu("Tools") {
            ForEach(Tool.allCases) { tool in
                WindowButton("\(tool.title)…", windowID: "tools") { model.selectedTool = tool }
            }
            Divider()
            MainWindowButton("Activity") { model.selection = .activity }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}

/// A menu item that brings a window forward (opening it if it was closed), then acts.
/// It is a View so it can use SwiftUI's `openWindow` action.
struct WindowButton: View {
    let title: String
    let windowID: String
    let action: () -> Void
    @Environment(\.openWindow) private var openWindow

    init(_ title: String, windowID: String, action: @escaping () -> Void) {
        self.title = title
        self.windowID = windowID
        self.action = action
    }

    var body: some View {
        Button(title) {
            openWindow(id: windowID)
            action()
        }
    }
}

struct MainWindowButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        WindowButton(title, windowID: "main", action: action)
    }
}
#endif
