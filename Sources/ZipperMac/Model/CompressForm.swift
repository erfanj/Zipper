import Foundation
import Observation
import ArchiveCore
import ArchiveEngines
import ArchiverKit

/// State and rules of the "Compress" sheet. The view only binds to it; everything that decides
/// what is valid, what gets scanned and what request is sent lives here.
@MainActor
@Observable
final class CompressForm {
    // Strong on purpose: a form never outlives its sheet, and the model clears `sheet` when it closes.
    @ObservationIgnored private let model: AppModel

    var items: [URL]
    var archiveName = ""
    private(set) var settings: CompressionSettings
    /// The everyday Faster / Normal / Smaller choice, mapped onto the engine level.
    var level: CompressionLevel {
        get { CompressionLevel(engineLevel: settings.level) }
        set { settings.level = newValue.engineLevel; appliedPreset = nil }
    }
    var encrypt = false
    var password = ""
    var confirmation = ""
    var split = false
    var splitText = "100 MB"
    var destination: URL?
    var verify: Bool
    var excludeClutter: Bool
    var excludeDeveloperFiles = false
    var customExclusions = ""
    var showAdvanced = false

    private(set) var collection: SourceCollection?
    private(set) var isScanning = false
    private(set) var recommendation: Recommendation?
    private(set) var isAnalyzing = false
    /// Name of the preset the settings came from, until the user changes something.
    private(set) var appliedPreset: String?

    init(items: [URL], model: AppModel) {
        self.model = model
        self.items = items
        let s = model.settings
        var initial = CompressionSettings(format: s.defaultFormat, level: s.defaultLevel.engineLevel, metadata: s.defaultMetadata,
                                          includeHidden: s.includeHiddenFiles)
        initial.threads = s.defaultThreads
        settings = initial
        verify = s.verifyAfterCompression
        excludeClutter = s.excludeClutterByDefault
        normalizeForFormat()
    }

    // MARK: Formats

    /// Formats offered first: what most people need.
    static let primaryFormats: [FormatID] = [.zip, .sevenZip, .tarGzip, .tarXz, .tarZstd, .dmg, .appleArchive]
    /// Everything else that can be created, offered under "Other Formats".
    static let otherFormats: [FormatID] = [.tar, .tarBzip2, .tarLz4, .tarBrotli, .tarLzip, .appleEncryptedArchive, .rar,
                                           .iso, .cpio, .xar, .wim, .cbz, .epub, .jar]
    /// Single-file compression streams, offered when exactly one file is selected.
    static let streamFormats: [FormatID] = [.gzip, .xz, .zstd, .bzip2, .lz4, .brotli, .lzip, .lzma]

    func creatable(_ formats: [FormatID]) -> [FormatID] {
        formats.filter { model.service.creationOptions(for: $0).canCreate }
    }

    var isSingleFile: Bool {
        guard items.count == 1 else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: items[0].path, isDirectory: &isDir) && !isDir.boolValue
    }

    var format: FormatID {
        get { settings.format }
        set {
            guard newValue != settings.format else { return }
            settings.format = newValue
            appliedPreset = nil
            normalizeForFormat()
        }
    }

    var options: CreationOptions { model.service.creationOptions(for: settings.format) }

    static func label(for format: FormatID) -> String {
        let name = FormatCatalog.descriptor(for: format)?.name ?? format.rawValue
        return "\(name) (.\(ArchiveService.fileExtension(for: format)))"
    }

    /// Drops settings the new format can't honour, so the form never shows an impossible state.
    private func normalizeForFormat() {
        let o = options
        if let m = settings.method, !o.methods.contains(m) { settings.method = nil }
        if !o.supportsSolid { settings.solid = nil }
        if !o.supportsDictionary { settings.dictionarySize = nil }
        if !o.supportsWordSize { settings.wordSize = nil }
        if !o.supportsComment { settings.comment = nil }
        if let e = settings.encryption, !o.encryptionMethods.contains(e.method) { settings.encryption = nil }
        if encrypt, settings.encryption == nil, let first = o.encryptionMethods.first {
            settings.encryption = EncryptionSettings(method: first, encryptFilenames: o.canEncryptFilenames)
        }
        if o.encryptionMethods.isEmpty { encrypt = false }
        if !o.canSplit { split = false }
    }

    // MARK: Encryption

    var canEncrypt: Bool { !options.encryptionMethods.isEmpty }

    func setEncrypt(_ on: Bool) {
        encrypt = on
        if on, settings.encryption == nil, let first = options.encryptionMethods.first {
            settings.encryption = EncryptionSettings(method: first, encryptFilenames: options.canEncryptFilenames)
        }
    }

    var encryptionMethod: EncryptionMethod? {
        get { settings.encryption?.method }
        set {
            guard let m = newValue else { settings.encryption = nil; return }
            settings.encryption = EncryptionSettings(method: m, encryptFilenames: settings.encryption?.encryptFilenames ?? options.canEncryptFilenames)
        }
    }

    var encryptFilenames: Bool {
        get { settings.encryption?.encryptFilenames ?? false }
        set { settings.encryption?.encryptFilenames = newValue }
    }

    // MARK: Advanced settings (each change marks the settings as customised)

    var method: CompressionMethod? {
        get { settings.method }
        set { settings.method = newValue; appliedPreset = nil }
    }

    var engineLevel: Int {
        get { settings.level }
        set { settings.level = min(9, max(0, newValue)); appliedPreset = nil }
    }

    var dictionarySize: UInt64? {
        get { settings.dictionarySize }
        set { settings.dictionarySize = newValue; appliedPreset = nil }
    }

    var wordSize: Int? {
        get { settings.wordSize }
        set { settings.wordSize = newValue; appliedPreset = nil }
    }

    /// "auto", "on", "off", "16m", "256m".
    var solidChoice: String {
        get {
            switch settings.solid {
            case nil: return "auto"
            case .on?: return "on"
            case .off?: return "off"
            case .blockSize(let b)?: return b <= 16 << 20 ? "16m" : "256m"
            }
        }
        set {
            switch newValue {
            case "on": settings.solid = .on
            case "off": settings.solid = .off
            case "16m": settings.solid = .blockSize(16 << 20)
            case "256m": settings.solid = .blockSize(256 << 20)
            default: settings.solid = nil
            }
            appliedPreset = nil
        }
    }

    var threads: Int? {
        get { settings.threads }
        set { settings.threads = newValue }
    }

    var metadata: MetadataMode {
        get { settings.metadata }
        set { settings.metadata = newValue; appliedPreset = nil }
    }

    var includeHidden: Bool {
        get { settings.includeHidden }
        set { settings.includeHidden = newValue }
    }

    var symlinks: SymlinkPolicy {
        get { settings.symlinks }
        set { settings.symlinks = newValue }
    }

    var includeRootFolder: Bool {
        get { settings.includeRootFolder }
        set { settings.includeRootFolder = newValue }
    }

    var grouping: ArchiveGrouping {
        get { settings.grouping }
        set { settings.grouping = newValue }
    }

    var normalizeNames: Bool {
        get { settings.filenameNormalization == .nfc }
        set { settings.filenameNormalization = newValue ? .nfc : .none }
    }

    var comment: String {
        get { settings.comment ?? "" }
        set { settings.comment = newValue.isEmpty ? nil : newValue }
    }

    // MARK: Presets

    func apply(_ preset: Preset) {
        settings = preset.settings
        if settings.threads == nil { settings.threads = model.settings.defaultThreads }
        normalizeForFormat()
        encrypt = preset.promptsForPassword || preset.settings.encryption != nil
        if encrypt { setEncrypt(true) }
        if preset.postActions.contains(.verifyArchive) { verify = true }
        // The preset's own exclusions are part of its settings; the clutter toggle stays as the user set it.
        appliedPreset = preset.name
    }

    func apply(_ s: CompressionSettings) {
        settings = s
        normalizeForFormat()
        encrypt = s.encryption != nil
        appliedPreset = nil
    }

    func makePreset(named name: String) -> Preset {
        var s = effectiveSettings()
        s.threads = nil
        return Preset(id: "user." + UUID().uuidString, name: name, summary: "\(Self.label(for: s.format)), \(level.label.lowercased())",
                      settings: s, postActions: verify ? [.verifyArchive] : [], promptsForPassword: encrypt)
    }

    // MARK: Validation

    var defaultName: String {
        guard items.count == 1 else { return "Archive" }
        let u = items[0]
        if u.hasDirectoryPath || FormatCatalog.descriptor(for: settings.format)?.kind == .compressionStream { return u.lastPathComponent }
        let stem = u.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? u.lastPathComponent : stem
    }

    var splitSize: UInt64? { split ? FileSplitter.parseSize(splitText) : nil }

    /// Why the archive can't be created yet, or nil when it can.
    var problem: String? {
        if items.isEmpty { return "Add files or folders to compress." }
        if !options.canCreate { return "This format can't be created with the engines installed on this Mac." }
        if FormatCatalog.descriptor(for: settings.format)?.kind == .compressionStream, !isSingleFile {
            return "\(FormatCatalog.descriptor(for: settings.format)?.name ?? "This format") holds a single file. Choose a TAR-based format for folders."
        }
        if encrypt {
            if password.isEmpty { return "Enter a password." }
            if password != confirmation { return "The passwords don't match." }
            // Split ZIPs are made by 7-Zip, which refuses non-ASCII ZIP passwords.
            if split, FormatCatalog.descriptor(for: settings.format)?.effectiveContainer == .zip, !password.allSatisfy(\.isASCII) {
                return "Split ZIP archives need a password in plain ASCII (no accented letters, emoji or other scripts). Change the password, or use the 7z format."
            }
        }
        if split, FileSplitter.parseSize(splitText) == nil { return "Enter a part size such as 100 MB or 1.5 GB." }
        if archiveName.contains("/") || archiveName.contains(":") { return "Archive names can't contain “/” or “:”." }
        return nil
    }

    var canCreate: Bool { problem == nil }

    // MARK: Request

    func effectiveSettings() -> CompressionSettings {
        var s = settings
        if !encrypt { s.encryption = nil }
        s.splitVolumeSize = splitSize
        if excludeClutter { s.filters += FileFilter.commonExclusions }
        if excludeDeveloperFiles { s.filters += FileFilter.developerExclusions }
        for g in customExclusions.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !g.isEmpty {
            s.filters.append(FilterRule(.exclude, g.hasPrefix("re:") ? .regex(String(g.dropFirst(3))) : .glob(g)))
        }
        return s
    }

    func makeRequest() -> CompressRequest {
        let trimmed = archiveName.trimmingCharacters(in: .whitespaces)
        return CompressRequest(items: items, destinationDirectory: destination, archiveName: trimmed.isEmpty ? nil : trimmed,
                               settings: effectiveSettings(), password: encrypt ? Secret(password) : nil,
                               verifyAfterCreation: verify)
    }

    // MARK: Scanning (what will be included)

    /// Only the inputs that change what gets collected; compression levels don't trigger a rescan.
    struct ScanKey: Equatable {
        var items: [URL]
        var includeHidden: Bool
        var symlinks: SymlinkPolicy
        var includeRootFolder: Bool
        var filters: [FilterRule]
    }

    var scanKey: ScanKey {
        let s = effectiveSettings()
        return ScanKey(items: items, includeHidden: s.includeHidden, symlinks: s.symlinks, includeRootFolder: s.includeRootFolder, filters: s.filters)
    }

    /// Collects the sources in the background. Run from `.task(id: scanKey)`, which cancels a
    /// superseded scan, so a slow old scan can never overwrite a newer result.
    func scan() async {
        guard !items.isEmpty else {
            // A scan superseded mid-way never cleared the flag; don't leave "Counting…" showing.
            isScanning = false
            collection = nil
            recommendation = nil
            return
        }
        isScanning = true
        let urls = items
        let s = effectiveSettings()
        let r = await offMain { try SourceCollector.collect(urls, settings: s) }
        guard !Task.isCancelled else { return }
        isScanning = false
        if case .success(let c) = r { collection = c } else { collection = nil }
        recommendation = nil
    }

    func recommend() async {
        guard let c = collection else { return }
        isAnalyzing = true
        let r = await offMain { () -> Recommendation in
            let p = CompressionAdvisor.profile(c, compressor: LibArchiveSampleCompressor(), methods: [.deflate, .lzma2, .zstd])
            return CompressionAdvisor.recommend(p)
        }
        isAnalyzing = false
        if case .success(let rec) = r { recommendation = rec }
    }

    func add(_ urls: [URL]) {
        let existing = Set(items.map(\.standardizedFileURL))
        items += urls.filter { !existing.contains($0.standardizedFileURL) }
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
    }

    // MARK: Running

    /// Starts the compression in the background and clears secrets from the form.
    func start() {
        let request = makeRequest()
        let service = model.service
        let reveal = model.settings.revealAfterCompression
        let platform = model.platform
        let title = "Compress \(items.count == 1 ? items[0].lastPathComponent : "\(items.count) items")"
        model.run(title, kind: .compress, inputs: items, onSuccess: nil) { progress in
            let o = try service.compress(request, progress: progress)
            let outputs = o.archives.flatMap(\.outputs)
            if reveal, !outputs.isEmpty {
                Task { @MainActor in platform.reveal(outputs) }
            }
            let saved = o.archives.reduce(Int64(0)) { $0 + Int64($1.inputBytes) - Int64($1.outputBytes) }
            return outputs.map(\.lastPathComponent).joined(separator: ", ") + (saved > 0 ? " — saved \(ByteFormatting.string(UInt64(saved)))" : "")
        }
        password = ""
        confirmation = ""
    }
}
