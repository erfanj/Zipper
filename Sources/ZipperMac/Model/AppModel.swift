import Foundation
import Observation
import ArchiveCore
import ArchiveEngines
import ArchiverKit

/// Destinations in the main window's sidebar. Deliberately short: tools live in the Tools
/// window and the menu bar, settings in the Settings window.
enum SidebarItem: Hashable {
    case home
    case archive(URL)
    case activity
}

/// The utilities shown in the Tools window.
enum Tool: String, CaseIterable, Identifiable, Hashable {
    case test, repair, convert, batchExtract, checksums, splitJoin, compare, duplicates

    var id: Self { self }

    var title: String {
        switch self {
        case .test: return "Test Integrity"
        case .repair: return "Repair"
        case .convert: return "Convert"
        case .batchExtract: return "Batch Extract"
        case .checksums: return "Checksums"
        case .splitJoin: return "Split & Join"
        case .compare: return "Compare"
        case .duplicates: return "Find Duplicates"
        }
    }

    var symbol: String {
        switch self {
        case .test: return "checkmark.shield"
        case .repair: return "bandage"
        case .convert: return "arrow.triangle.2.circlepath"
        case .batchExtract: return "square.stack.3d.up"
        case .checksums: return "number"
        case .splitJoin: return "square.split.2x1"
        case .compare: return "arrow.left.arrow.right"
        case .duplicates: return "doc.on.doc"
        }
    }

    var summary: String {
        switch self {
        case .test: return "Decodes every file and checks the stored checksums. Passing doesn't mean the files are free of malware."
        case .repair: return "Recovers the readable files from a damaged archive into a new folder. The damaged archive is never changed."
        case .convert: return "Re-packs archives in another format and checks every file by SHA-256 before finishing. Originals are kept unless you choose otherwise."
        case .batchExtract: return "Extracts many archives at once. Multi-part sets are extracted once."
        case .checksums: return "Calculates, compares and verifies file checksums."
        case .splitJoin: return "Splits any file into numbered parts (name.001, name.002…) with a SHA-256 manifest, or joins them back together."
        case .compare: return "Shows which files were added, removed or changed between two archives."
        case .duplicates: return "Finds identical files inside and across archives (by SHA-256). Nothing is deleted."
        }
    }
}

/// App-wide state. All mutation happens on the main actor; long work runs in `OperationCenter`.
@MainActor
@Observable
final class AppModel {
    let service: ArchiveService
    let center: OperationCenter
    let history: ActivityHistory
    let presetStore: PresetStore
    let passwordStore: PasswordStore?
    @ObservationIgnored let platform: PlatformServices
    @ObservationIgnored let defaults: UserDefaults
    var settings: AppSettings

    // Navigation
    var selection: SidebarItem? = .home
    var showInspector = false
    var openArchives: [BrowserState] = []
    var sheet: MainSheet?
    var selectedTool: Tool = .test
    /// Archives handed to the Tools window (for example several archives dropped at once).
    var toolInput: [URL] = []
    /// Items dropped together that mix archives and other files, awaiting the user's choice.
    var ambiguousDrop: [URL]?

    // Library
    var userPresets: [Preset] = []
    var recentArchives: [URL] = []

    /// Bumped whenever an operation starts, finishes or changes state (views showing operations read it).
    var operationsVersion = 0
    /// Bumped when the saved history changes other than through an operation (it's cleared).
    var historyVersion = 0

    /// Opens a window by scene id. Provided by the main window, which owns SwiftUI's `openWindow` action.
    @ObservationIgnored var openWindow: ((String) -> Void)?
    @ObservationIgnored private var promptQueue: [() -> Void] = []
    @ObservationIgnored private var isPrompting = false
    @ObservationIgnored private var progressTimer: Timer?

    /// `supportDirectory` holds the history and presets files (tests pass a temporary folder so they
    /// never touch the user's own).
    init(platform: PlatformServices, defaults: UserDefaults = .standard, supportDirectory: URL = ProductInfo.applicationSupport) {
        self.platform = platform
        self.defaults = defaults
        let support = supportDirectory
        // Locals, not `self.settings`: @Observable properties can't be read before init completes.
        let loaded = AppSettings.load(from: defaults)
        let history = ActivityHistory(fileURL: support.appendingPathComponent("History.json"), isEnabled: loaded.historyEnabled)
        settings = loaded
        service = ArchiveService(registry: DefaultEngines.registry())
        self.history = history
        center = OperationCenter(mode: loaded.performanceMode, history: history)
        presetStore = PresetStore(fileURL: support.appendingPathComponent("Presets.json"))
        #if os(macOS)
        passwordStore = KeychainPasswordStore()
        #else
        passwordStore = nil
        #endif
        userPresets = presetStore.load()
        recentArchives = RecentItems.load(defaults: defaults)
        service.fallbackPolicy = .automatic
        center.onChange = { [weak self] in
            Task { @MainActor in self?.operationsChanged() }
        }
        applySettings()
    }

    // MARK: Settings

    /// Saves the settings and pushes them into the services. Called at launch and after every change.
    func applySettings() {
        settings.save(to: defaults)
        history.isEnabled = settings.historyEnabled
        center.mode = settings.performanceMode
        service.performanceMode = settings.performanceMode
        DiagnosticLog.shared.isEnabled = settings.diagnosticLogging
        var preferred: [FormatID: EngineID] = [:]
        for (format, engine) in settings.preferredEngines { preferred[FormatID(format)] = EngineID(rawValue: engine) }
        service.registry.preferred = preferred
    }

    var allPresets: [Preset] { BuiltInPresets.all + userPresets }

    /// Clears the saved history; every view listing it reloads.
    func clearHistory() {
        history.clear()
        historyVersion &+= 1
    }

    func savePresets() {
        do { try presetStore.save(userPresets) } catch { present(ArchiveError.wrap(error), context: "Saving presets") }
    }

    // MARK: Recent archives

    func noteRecent(_ url: URL) {
        recentArchives.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentArchives.insert(url, at: 0)
        if recentArchives.count > 12 { recentArchives.removeLast(recentArchives.count - 12) }
        RecentItems.save(recentArchives, defaults: defaults)
        platform.noteRecentDocument(url)
    }

    func clearRecents() {
        recentArchives = []
        RecentItems.save([], defaults: defaults)
    }

    // MARK: Opening files

    /// Files from Finder, the Dock icon, drag and drop, Services or File › Open.
    func handleOpen(_ urls: [URL]) {
        let archives = urls.filter { isArchive($0) }
        let others = urls.filter { !isArchive($0) }
        if !archives.isEmpty, !others.isEmpty {
            ambiguousDrop = urls
        } else if archives.count == 1 {
            if settings.openAction == .extract { quickExtract(archives[0]) } else { openArchive(archives[0]) }
        } else if archives.count > 1 {
            showTool(.batchExtract, input: ArchiveService.distinctArchives(archives))
        } else if !others.isEmpty {
            beginCompress(others)
        }
    }

    /// Whether a dropped or opened file should be treated as an archive rather than compressed.
    func isArchive(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        // Folders, apps and other bundles are things to compress.
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return false }
        guard let d = try? FormatDetector.detect(url), let descriptor = d.descriptor else { return false }
        // Office documents, apps and similar packages are ZIPs inside; treat them as archives only
        // when their extension says so (e.g. .jar, .epub), never because of their content alone.
        if descriptor.category == .package, d.basis == .content { return false }
        // Content-only detection of a ZIP in a file whose extension names something else
        // (.docx, .xlsx, .pptx, .pages, .key, .odt, .sketch, .3mf…) means a document built on ZIP:
        // it is detected as plain ZIP, not as a package, so the check above doesn't catch it.
        if d.basis == .content, descriptor.effectiveContainer == .zip, !url.pathExtension.isEmpty { return false }
        return true
    }

    func archiveState(for url: URL) -> BrowserState? {
        openArchives.first { $0.url == url }
    }

    func openArchive(_ url: URL) {
        noteRecent(url)
        if let existing = archiveState(for: url) {
            selection = .archive(url)
            if existing.error != nil { existing.load(using: self) }
            return
        }
        let state = BrowserState(url: url)
        openArchives.append(state)
        selection = .archive(url)
        state.load(using: self)
    }

    func closeArchive(_ url: URL) {
        guard let i = openArchives.firstIndex(where: { $0.url == url }) else { return }
        openArchives[i].discardEditSessions()
        openArchives.remove(at: i)
        if selection == .archive(url) {
            selection = openArchives.isEmpty ? .home : .archive(openArchives[min(i, openArchives.count - 1)].url)
        }
    }

    /// The archive shown in the main window, if any.
    var currentArchive: BrowserState? {
        guard case .archive(let url)? = selection else { return nil }
        return archiveState(for: url)
    }

    func beginCompress(_ items: [URL]) {
        guard !items.isEmpty else { return }
        sheet = .compress(CompressForm(items: items, model: self))
    }

    func beginExtract(_ archive: URL) {
        noteRecent(archive)
        sheet = .extract(ExtractForm(archive: archive, model: self))
    }

    func showTool(_ tool: Tool, input: [URL] = []) {
        selectedTool = tool
        if !input.isEmpty { toolInput = input }
        openWindow?("tools")
    }

    // MARK: Options for operations

    /// Read options whose password provider tries the Keychain, then asks the user.
    func readOptions(allowMountingDiskImages: Bool = false) -> ReadOptions {
        let store = settings.savePasswordsInKeychain ? passwordStore : nil
        // @Sendable: worker threads call this, so it must not inherit the main actor's isolation.
        let provider = StoredPasswordProvider(store: store) { @Sendable [weak self] url, reason in
            self?.requestPasswordFromWorker(url, reason: reason)
        }
        return ReadOptions(passwordProvider: CachingPasswordProvider(upstream: provider),
                           filenameEncoding: settings.filenameEncoding.isEmpty ? nil : settings.filenameEncoding,
                           allowMountingDiskImages: allowMountingDiskImages)
    }

    func extractionOptions(conflictPolicy: ConflictPolicy? = nil) -> ExtractionOptions {
        var o = ExtractionOptions(conflictPolicy: conflictPolicy ?? settings.conflictPolicy, linkPolicy: settings.linkPolicy,
                                  restorePermissions: settings.restorePermissions, restoreTimestamps: true,
                                  restoreExtendedAttributes: settings.restoreExtendedAttributes,
                                  skipAppleDoubleArtifacts: settings.skipMacOSXFolders, limits: settings.limits)
        if o.conflictPolicy == .ask {
            o.conflictResolver = { [weak self] info in
                guard let self else { return (.keepBoth, false) }
                let a = self.requestConflictFromWorker(info)
                return (a.decision, a.applyToAll)
            }
        }
        return o
    }

    var defaultExtractionDestination: URL? {
        settings.defaultExtractionDestination.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: Prompts from worker threads

    /// Called on a worker thread; blocks it (never the main thread) until the user answers.
    nonisolated func requestPasswordFromWorker(_ url: URL, reason: PasswordRequestReason) -> Secret? {
        // Waiting on the main thread for a prompt that needs the main thread would deadlock.
        guard !Thread.isMainThread else { return nil }
        let box = AnswerBox<Secret>()
        Task { @MainActor in
            self.enqueuePrompt {
                let offer = self.settings.savePasswordsInKeychain && self.passwordStore != nil
                guard let answer = self.platform.askPassword(for: url, reason: reason, offerToRemember: offer) else {
                    box.answer(nil)
                    return
                }
                if answer.remember, offer {
                    try? self.passwordStore?.save(answer.secret, for: passwordKey(for: url), label: url.lastPathComponent,
                                                  requireAuthentication: self.settings.requireAuthenticationForPasswords)
                }
                box.answer(answer.secret)
            }
        }
        return box.wait()
    }

    nonisolated func requestConflictFromWorker(_ info: ConflictInfo) -> ConflictAnswer {
        guard !Thread.isMainThread else { return ConflictAnswer(decision: .keepBoth, applyToAll: false) }
        let box = AnswerBox<ConflictAnswer>()
        Task { @MainActor in
            self.enqueuePrompt { box.answer(self.platform.askConflict(info)) }
        }
        return box.wait() ?? ConflictAnswer(decision: .keepBoth, applyToAll: false)
    }

    /// Modal prompts run one at a time, in the order they were requested, so concurrent
    /// operations never stack dialogs on top of each other.
    private func enqueuePrompt(_ prompt: @escaping () -> Void) {
        promptQueue.append(prompt)
        runNextPrompt()
    }

    private func runNextPrompt() {
        guard !isPrompting, !promptQueue.isEmpty else { return }
        isPrompting = true
        let prompt = promptQueue.removeFirst()
        prompt()
        isPrompting = false
        if !promptQueue.isEmpty {
            Task { @MainActor in self.runNextPrompt() }
        }
    }

    // MARK: Running operations

    /// Enqueues background work, reports failures and posts a notification when the app is inactive.
    /// `onSuccess` gets the operation's summary; `onFinish` runs after any outcome. Both run on the main actor.
    @discardableResult
    func run(_ title: String, kind: HistoryRecord.Kind, inputs: [URL],
             onSuccess: (@MainActor @Sendable (String) -> Void)? = nil,
             onFinish: (@MainActor @Sendable () -> Void)? = nil,
             work: @escaping @Sendable (OperationProgress) throws -> String) -> QueuedOperation {
        let names = settings.historyStoresPaths ? inputs.map(\.path) : inputs.map(\.lastPathComponent)
        return center.enqueue(title, kind: kind, inputs: names, onStateChange: { [weak self] o in
            let state = o.state
            guard state == .succeeded || state == .failed || state == .cancelled else { return }
            let summary = o.summary ?? ""
            let error = o.error
            Task { @MainActor in
                onFinish?()
                guard let self else { return }
                if state == .succeeded {
                    onSuccess?(summary)
                    self.notify(title: "\(title) — Done", body: summary)
                } else if state == .failed, let error {
                    self.present(error, context: title)
                    self.notify(title: "\(title) — Failed", body: error.title)
                }
            }
        }, work: work)
    }

    /// Shows an error unless it is a cancellation (which the user asked for).
    func present(_ error: ArchiveError, context: String) {
        if case .cancelled = error { return }
        enqueuePrompt { self.platform.showError(error, context: context) }
    }

    private func notify(title: String, body: String) {
        guard settings.notificationsEnabled, !platform.isAppActive else { return }
        platform.notify(title: title, body: body)
    }

    // MARK: Activity

    var hasActiveOperations: Bool { !center.active.isEmpty }

    private func operationsChanged() {
        operationsVersion &+= 1
        updateProgressIndicators()
        if hasActiveOperations, progressTimer == nil {
            // Operations report progress continuously; the Dock tile is refreshed twice a second.
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateProgressIndicators() }
            }
        } else if !hasActiveOperations {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func updateProgressIndicators() {
        platform.updateDockProgress(fraction: center.overallFraction, activeCount: center.active.count)
    }

    /// Cancels everything (used when quitting) and reports how many operations were running.
    @discardableResult
    func cancelAllOperations() -> Int {
        let active = center.active
        active.forEach { $0.cancel() }
        return active.count
    }
}

/// A sheet shown over the main window.
enum MainSheet: Identifiable {
    case compress(CompressForm)
    case extract(ExtractForm)

    var id: ObjectIdentifier {
        switch self {
        case .compress(let f): return ObjectIdentifier(f)
        case .extract(let f): return ObjectIdentifier(f)
        }
    }
}

/// Persists recently opened archives. On macOS bookmarks follow files that are moved or renamed.
enum RecentItems {
    static let key = "recentArchives"

    static func load(defaults: UserDefaults = .standard) -> [URL] {
        #if os(macOS)
        return (defaults.array(forKey: key) as? [Data] ?? []).compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                     bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
        #else
        return (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        #endif
    }

    static func save(_ urls: [URL], defaults: UserDefaults = .standard) {
        #if os(macOS)
        defaults.set(urls.compactMap { try? $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }, forKey: key)
        #else
        defaults.set(urls.map(\.path), forKey: key)
        #endif
    }
}
