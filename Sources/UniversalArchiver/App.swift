#if os(macOS)
import SwiftUI
import AppKit
import UserNotifications
import ArchiveCore
import ArchiveEngines
import ArchiverKit

@main
struct UniversalArchiverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let m = AppModel()
        _model = State(initialValue: m)
        AppDelegate.model = m
    }

    var body: some Scene {
        WindowGroup(ProductInfo.name, id: "main") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra(isInserted: .constant(!model.center.active.isEmpty || model.operationsVersion < 0)) {
            MenuBarProgress().environment(model)
        } label: {
            Image(systemName: "archivebox.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Receives files from Finder, the Dock, Services and Apple Events.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Self.model?.handleOpen(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running while background operations are active.
        MainActor.assumeIsolated { Self.model?.center.active.isEmpty ?? true }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = MainActor.assumeIsolated { Self.model?.center.active.count ?? 0 }
        guard active > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "\(active) operation\(active == 1 ? " is" : "s are") still running."
        alert.informativeText = "Quitting cancels them. Incomplete archives and extracted files are removed; finished files are kept."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Cancel Operations and Quit")
        if alert.runModal() == .alertSecondButtonReturn {
            MainActor.assumeIsolated { Self.model?.center.active.forEach { $0.cancel() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if MainActor.assumeIsolated({ Self.model?.settings.clearPreviewCacheOnQuit ?? true }) { PreviewCache.shared.clear() }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let recents = MainActor.assumeIsolated { Self.model?.recentArchives.prefix(8).map { $0 } ?? [] }
        for url in recents {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            menu.addItem(item)
        }
        if !recents.isEmpty { menu.addItem(.separator()) }
        let compress = NSMenuItem(title: "Compress Files…", action: #selector(compressFiles), keyEquivalent: "")
        compress.target = self
        menu.addItem(compress)
        return menu
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task { @MainActor in Self.model?.openArchive(url) }
    }

    @objc func compressFiles() {
        Task { @MainActor in
            if let urls = FilePicker.chooseItems(prompt: "Compress") { Self.model?.pendingCompression = urls; Self.model?.selection = .compress }
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Archive…") {
                if let urls = FilePicker.chooseItems(prompt: "Compress") { model.pendingCompression = urls; model.selection = .compress }
            }
            .keyboardShortcut("n")
            Button("Open Archive…") {
                if let url = FilePicker.chooseArchive() { model.openArchive(url) }
            }
            .keyboardShortcut("o")
            Button("Extract Archive…") {
                if let url = FilePicker.chooseArchive() { model.quickExtract(url) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Archive") {
            Button("Test Integrity") { model.selection = .integrity }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Convert…") { model.selection = .convert }
            Button("Repair…") { model.selection = .repair }
            Divider()
            Button("Checksums…") { model.selection = .checksums }
            Button("Split or Join Files…") { model.selection = .splitJoin }
            Button("Compare Archives…") { model.selection = .compare }
            Button("Find Duplicates…") { model.selection = .duplicates }
            Divider()
            Button("Show Activity") { model.selection = .activeOperations }.keyboardShortcut("0", modifiers: [.command, .option])
            Button("Toggle Inspector") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

struct MenuBarProgress: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let _ = model.operationsVersion
        VStack(alignment: .leading, spacing: 10) {
            Text("Activity").font(.headline)
            if model.center.active.isEmpty { Text("No active operations").foregroundStyle(.secondary) }
            ForEach(model.center.active) { op in OperationRow(op: op, compact: true) }
        }
        .padding()
        .frame(width: 320)
    }
}
#endif
