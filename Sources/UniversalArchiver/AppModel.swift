#if os(macOS)
import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers
import UserNotifications
import ArchiveCore
import ArchiveEngines
import ArchiverKit

/// Sidebar destinations.
enum SidebarItem: Hashable {
    case home
    case compress
    case extract
    case convert
    case archive(URL)
    case activeOperations
    case completedOperations
    case integrity
    case repair
    case checksums
    case splitJoin
    case compare
    case duplicates
    case batch
    case history
    case preset(String)
}

/// A password request raised by a background operation and answered by the UI.
struct PasswordRequest: Identifiable {
    let id = UUID()
    let archive: URL
    let reason: PasswordRequestReason
}

struct ConflictRequest: Identifiable {
    let id = UUID()
    let info: ConflictInfo
}

/// Presentable error with technical details for the "Show Details" disclosure.
struct PresentedError: Identifiable {
    let id = UUID()
    let error: ArchiveError
    let context: String
}

/// Hands one answer from the main thread to a waiting worker thread.
final class AnswerBridge<T>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: T?

    func wait() -> T? {
        semaphore.wait()
        lock.lock(); defer { lock.unlock() }
        let v = value
        value = nil
        return v
    }

    func answer(_ v: T?) {
        lock.lock(); value = v; lock.unlock()
        semaphore.signal()
    }
}

/// App-wide state. All UI mutation happens on the main actor; long work runs in `OperationCenter`.
@MainActor
@Observable
final class AppModel {
    let service: ArchiveService
    let center: OperationCenter
    let history: ActivityHistory
    let presetStore: PresetStore
    let passwordStore: PasswordStore
    var settings: AppSettings

    var selection: SidebarItem? = .home
    var showInspector = false
    var userPresets: [Preset] = []
    var recentArchives: [URL] = []
    var favorites: [URL] = []
    /// Files waiting for the compression form.
    var pendingCompression: [URL] = []
    /// Archive waiting for the extraction form.
    var pendingExtraction: URL?
    var passwordRequest: PasswordRequest?
    var conflictRequest: ConflictRequest?
    var presentedError: PresentedError?
    var operationsVersion = 0
    var openedArchives: [URL: BrowserState] = [:]
    /// Ambiguous drop (archive vs. plain files) awaiting a choice.
    var ambiguousDrop: [URL]?

    // Bridges from worker threads to UI sheets (nonisolated: used from background threads).
    nonisolated let passwordBridge = AnswerBridge<Secret>()
    nonisolated let conflictBridge = AnswerBridge<(ConflictDecision, Bool)>()

    init() {
        let support = ProductInfo.applicationSupport
        settings = AppSettings.load()
        let registry = DefaultEngines.registry()
        service = ArchiveService(registry: registry)
        history = ActivityHistory(fileURL: support.appendingPathComponent("History.json"), isEnabled: settings.historyEnabled)
        center = OperationCenter(mode: settings.performanceMode, history: history)
        presetStore = PresetStore(fileURL: support.appendingPathComponent("Presets.json"))
        passwordStore = KeychainPasswordStore()
        userPresets = presetStore.load()
        recentArchives = Self.loadURLs("recentArchives")
        favorites = Self.loadURLs("favorites")
        service.performanceMode = settings.performanceMode
        service.fallbackPolicy = .automatic
        center.onChange = { [weak self] in
            Task { @MainActor in
                self?.operationsVersion &+= 1
                self?.updateDockProgress()
            }
        }
        DiagnosticLog.shared.isEnabled = settings.diagnosticLogging
    }

    // MARK: Persistence helpers

    static func loadURLs(_ key: String) -> [URL] {
        (UserDefaults.standard.array(forKey: key) as? [Data] ?? []).compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    static func saveURLs(_ urls: [URL], key: String) {
        let data = urls.compactMap { try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        UserDefaults.standard.set(data, forKey: key)
    }

    func noteRecent(_ url: URL) {
        recentArchives.removeAll { $0 == url }
        recentArchives.insert(url, at: 0)
        if recentArchives.count > 20 { recentArchives.removeLast(recentArchives.count - 20) }
        Self.saveURLs(recentArchives, key: "recentArchives")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func toggleFavorite(_ url: URL) {
        if favorites.contains(url) { favorites.removeAll { $0 == url } } else { favorites.append(url) }
        Self.saveURLs(favorites, key: "favorites")
    }

    func savePresets() {
        do { try presetStore.save(userPresets) } catch { present(ArchiveError.wrap(error), context: "Saving presets") }
    }

    var allPresets: [Preset] { BuiltInPresets.all + userPresets }

    // MARK: Opening files

    /// Handles files from Finder, the Dock icon, drag and drop or Open…
    func handleOpen(_ urls: [URL]) {
        let archives = urls.filter { isArchive($0) }
        let others = urls.filter { !isArchive($0) }
        if !archives.isEmpty, !others.isEmpty {
            ambiguousDrop = urls
        } else if !archives.isEmpty {
            if archives.count == 1 {
                if settings.doubleClickAction == .extract { quickExtract(archives[0]) } else { openArchive(archives[0]) }
            } else {
                selection = .batch
                batchArchives = ArchiveService.distinctArchives(archives)
            }
        } else if !others.isEmpty {
            pendingCompression = others
            selection = .compress
        }
    }

    var batchArchives: [URL] = []

    func isArchive(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            // App bundles and packages are folders: treat as files to compress.
            return false
        }
        guard let d = try? FormatDetector.detect(url) else { return false }
        // Office documents etc. are ZIPs inside; only treat them as archives when the extension says so.
        if d.basis == .content, let kind = d.descriptor?.kind, kind == .archive, FormatCatalog.matchExtension(of: url.lastPathComponent) == nil {
            return true
        }
        return d.basis != .content || d.descriptor?.category != .package
    }

    func openArchive(_ url: URL) {
        noteRecent(url)
        if openedArchives[url] == nil { openedArchives[url] = BrowserState(url: url) }
        selection = .archive(url)
        openedArchives[url]?.load(model: self)
    }

    func quickExtract(_ url: URL) {
        noteRecent(url)
        pendingExtraction = url
        selection = .extract
    }

    // MARK: Background operations

    /// Read options whose password provider asks the user (after the Keychain).
    func readOptions(allowMount: Bool = false) -> ReadOptions {
        let store = settings.savePasswordsInKeychain ? passwordStore : nil
        let provider = StoredPasswordProvider(store: store) { @Sendable [weak self] url, reason in
            self?.requestPasswordFromWorker(url, reason: reason)
        }
        return ReadOptions(passwordProvider: CachingPasswordProvider(upstream: provider), filenameEncoding: settings.filenameEncoding.isEmpty ? nil : settings.filenameEncoding,
                           allowMountingDiskImages: allowMount)
    }

    /// Called on a worker thread; blocks it until the user answers the sheet.
    nonisolated func requestPasswordFromWorker(_ url: URL, reason: PasswordRequestReason) -> Secret? {
        precondition(!Thread.isMainThread, "password prompts must not block the main thread")
        Task { @MainActor in self.passwordRequest = PasswordRequest(archive: url, reason: reason) }
        return passwordBridge.wait()
    }

    func answerPassword(_ secret: Secret?, remember: Bool) {
        if let s = secret, remember, settings.savePasswordsInKeychain, let req = passwordRequest {
            try? passwordStore.save(s, for: passwordKey(for: req.archive), label: req.archive.lastPathComponent,
                                   requireAuthentication: settings.requireAuthenticationForPasswords)
        }
        passwordRequest = nil
        passwordBridge.answer(secret)
    }

    nonisolated func requestConflictDecision(_ info: ConflictInfo) -> (ConflictDecision, Bool) {
        precondition(!Thread.isMainThread)
        Task { @MainActor in self.conflictRequest = ConflictRequest(info: info) }
        return conflictBridge.wait() ?? (.keepBoth, false)
    }

    func answerConflict(_ d: ConflictDecision, applyToAll: Bool) {
        conflictRequest = nil
        conflictBridge.answer((d, applyToAll))
    }

    func extractionOptions() -> ExtractionOptions {
        var o = ExtractionOptions(conflictPolicy: settings.conflictPolicy, linkPolicy: settings.linkPolicy,
                                  restorePermissions: settings.restorePermissions, restoreTimestamps: true,
                                  restoreExtendedAttributes: settings.restoreExtendedAttributes,
                                  skipAppleDoubleArtifacts: settings.skipMacOSXFolders, limits: settings.limits)
        if settings.conflictPolicy == .ask {
            o.conflictResolver = { @Sendable [weak self] info in self?.requestConflictDecision(info) ?? (.keepBoth, false) }
        }
        return o
    }

    /// Enqueues work and reports failures with a readable alert and a notification.
    @discardableResult
    func run(_ title: String, kind: HistoryRecord.Kind, inputs: [URL], reveal: (@Sendable (String) -> URL?)? = nil,
             work: @escaping @Sendable (OperationProgress) throws -> String) -> QueuedOperation {
        center.mode = settings.performanceMode
        service.performanceMode = settings.performanceMode
        let op = center.enqueue(title, kind: kind, inputs: settings.historyStoresPaths ? inputs.map(\.path) : inputs.map(\.lastPathComponent), work: work)
        let previous = op.onChange
        op.onChange = { [weak self] o in
            previous?(o)
            let state = o.state
            let summary = o.summary
            let error = o.error
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .succeeded:
                    self.notify(title: "\(title) — Done", body: summary ?? "")
                case .failed:
                    if let e = error { self.present(e, context: title) }
                    self.notify(title: "\(title) — Failed", body: error?.title ?? "")
                default: break
                }
            }
        }
        selection = settings.showActivityAfterStarting ? .activeOperations : selection
        return op
    }

    func present(_ e: ArchiveError, context: String) {
        if case .cancelled = e { return }
        presentedError = PresentedError(error: e, context: context)
    }

    func notify(title: String, body: String) {
        guard settings.notificationsEnabled, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Dock

    private var dockProgress: NSProgressIndicator?

    func updateDockProgress() {
        let tile = NSApp.dockTile
        guard let fraction = center.overallFraction else {
            tile.contentView = nil
            tile.badgeLabel = nil
            tile.display()
            return
        }
        if dockProgress == nil {
            let image = NSImageView(image: NSApp.applicationIconImage)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
            image.frame = container.bounds
            let bar = NSProgressIndicator(frame: NSRect(x: 12, y: 8, width: 104, height: 14))
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            container.addSubview(image)
            container.addSubview(bar)
            tile.contentView = container
            dockProgress = bar
        }
        dockProgress?.doubleValue = fraction
        let n = center.active.count
        tile.badgeLabel = n > 1 ? "\(n)" : nil
        tile.display()
        if center.active.isEmpty { dockProgress = nil }
    }
}
#endif
