import Foundation
import ArchiveCore
import ArchiverKit

/// What happens when the user opens an archive from Finder (double-click, Dock, "Open With").
enum OpenAction: String, Codable, CaseIterable, Identifiable {
    case browse, extract
    var id: Self { self }
    var label: String { self == .browse ? "Show its contents" : "Extract it right away" }
}

/// User preferences. Stored as JSON in UserDefaults; never contains passwords.
///
/// Decoding is tolerant: a missing key keeps its default, so adding a setting never resets the
/// others (the synthesized `Decodable` would throw and lose everything).
struct AppSettings: Codable, Equatable {
    // General
    var openAction: OpenAction = .browse
    var defaultExtractionDestination: String? = nil // nil = next to the archive
    var extractionMode: ExtractionMode = .smart
    var revealAfterExtraction = true
    var revealAfterCompression = true
    var notificationsEnabled = true
    // Compression
    var defaultFormat: FormatID = .zip
    var defaultLevel: CompressionLevel = .normal
    var defaultMetadata: MetadataMode = .standard
    var includeHiddenFiles = true
    var excludeClutterByDefault = true
    var verifyAfterCompression = false
    var defaultThreads: Int? = nil
    // Extraction
    var conflictPolicy: ConflictPolicy = .keepBoth
    var linkPolicy: ExtractionLinkPolicy = .preserveSafe
    var restorePermissions = true
    var restoreExtendedAttributes = true
    var skipMacOSXFolders = true
    var verifyAfterExtraction = false
    var extractNestedArchives = false
    var limits = SafetyLimits.default
    // Security & privacy
    var savePasswordsInKeychain = true
    var requireAuthenticationForPasswords = true
    var clearPreviewCacheOnQuit = true
    var historyEnabled = true
    var historyStoresPaths = true
    // Advanced
    var performanceMode: PerformanceMode = .balanced
    var filenameEncoding = ""
    var preferredEngines: [String: String] = [:]
    var diagnosticLogging = false

    static let defaultsKey = "settings.v2"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        openAction = v(.openAction, d.openAction)
        defaultExtractionDestination = v(.defaultExtractionDestination, d.defaultExtractionDestination)
        extractionMode = v(.extractionMode, d.extractionMode)
        revealAfterExtraction = v(.revealAfterExtraction, d.revealAfterExtraction)
        revealAfterCompression = v(.revealAfterCompression, d.revealAfterCompression)
        notificationsEnabled = v(.notificationsEnabled, d.notificationsEnabled)
        defaultFormat = v(.defaultFormat, d.defaultFormat)
        defaultLevel = v(.defaultLevel, d.defaultLevel)
        defaultMetadata = v(.defaultMetadata, d.defaultMetadata)
        includeHiddenFiles = v(.includeHiddenFiles, d.includeHiddenFiles)
        excludeClutterByDefault = v(.excludeClutterByDefault, d.excludeClutterByDefault)
        verifyAfterCompression = v(.verifyAfterCompression, d.verifyAfterCompression)
        defaultThreads = v(.defaultThreads, d.defaultThreads)
        conflictPolicy = v(.conflictPolicy, d.conflictPolicy)
        linkPolicy = v(.linkPolicy, d.linkPolicy)
        restorePermissions = v(.restorePermissions, d.restorePermissions)
        restoreExtendedAttributes = v(.restoreExtendedAttributes, d.restoreExtendedAttributes)
        skipMacOSXFolders = v(.skipMacOSXFolders, d.skipMacOSXFolders)
        verifyAfterExtraction = v(.verifyAfterExtraction, d.verifyAfterExtraction)
        extractNestedArchives = v(.extractNestedArchives, d.extractNestedArchives)
        limits = v(.limits, d.limits)
        savePasswordsInKeychain = v(.savePasswordsInKeychain, d.savePasswordsInKeychain)
        requireAuthenticationForPasswords = v(.requireAuthenticationForPasswords, d.requireAuthenticationForPasswords)
        clearPreviewCacheOnQuit = v(.clearPreviewCacheOnQuit, d.clearPreviewCacheOnQuit)
        historyEnabled = v(.historyEnabled, d.historyEnabled)
        historyStoresPaths = v(.historyStoresPaths, d.historyStoresPaths)
        performanceMode = v(.performanceMode, d.performanceMode)
        filenameEncoding = v(.filenameEncoding, d.filenameEncoding)
        preferredEngines = v(.preferredEngines, d.preferredEngines)
        diagnosticLogging = v(.diagnosticLogging, d.diagnosticLogging)
    }

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// The everyday compression choice, independent of the format.
enum CompressionLevel: String, Codable, CaseIterable, Identifiable {
    case fastest, normal, smallest
    var id: Self { self }

    var label: String {
        switch self {
        case .fastest: return "Faster"
        case .normal: return "Normal"
        case .smallest: return "Smaller"
        }
    }

    var help: String {
        switch self {
        case .fastest: return "Compresses quickly; files are a little larger."
        case .normal: return "A good balance of speed and size."
        case .smallest: return "Makes the smallest files; takes longer."
        }
    }

    /// The engine level (0–9) this choice maps to.
    var engineLevel: Int {
        switch self {
        case .fastest: return 1
        case .normal: return 6
        case .smallest: return 9
        }
    }

    init(engineLevel: Int) {
        switch engineLevel {
        case ..<4: self = .fastest
        case 4...7: self = .normal
        default: self = .smallest
        }
    }
}
