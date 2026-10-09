#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore
import ArchiveEngines
import ArchiverKit

enum DoubleClickAction: String, Codable, CaseIterable {
    case browse, extract
    var label: String { self == .browse ? "Open and browse contents" : "Extract with the default settings" }
}

/// User preferences. Stored as JSON in UserDefaults; never contains passwords.
struct AppSettings: Codable, Equatable {
    // General
    var defaultPresetID = BuiltInPresets.balanced.id
    var defaultExtractionDestination: String? = nil // nil = next to the archive
    var extractionMode: ExtractionMode = .smart
    var doubleClickAction: DoubleClickAction = .browse
    var openDestinationAfterExtraction = true
    var notificationsEnabled = true
    var showActivityAfterStarting = false
    var uiLevel: UILevel = .simple
    // Compression
    var defaultThreads: Int? = nil
    var defaultMetadata: MetadataMode = .standard
    var includeHiddenFiles = true
    var normalizeFilenamesNFC = true
    var excludeClutterByDefault = false
    var verifyAfterCompression = false
    // Extraction
    var conflictPolicy: ConflictPolicy = .keepBoth
    var linkPolicy: ExtractionLinkPolicy = .preserveSafe
    var restorePermissions = true
    var restoreExtendedAttributes = true
    var skipMacOSXFolders = true
    var verifyAfterExtraction = false
    var limits = SafetyLimits.default
    var extractNestedArchives = false
    // Security
    var savePasswordsInKeychain = true
    var requireAuthenticationForPasswords = true
    var defaultEncryption7z = true
    var clearPreviewCacheOnQuit = true
    // Performance
    var performanceMode: PerformanceMode = .balanced
    var maxConcurrentOperations: Int? = nil
    // Privacy & history
    var historyEnabled = true
    var historyStoresPaths = true
    var diagnosticLogging = false
    // Advanced
    var filenameEncoding = ""
    var preferredEngines: [String: String] = [:]

    enum UILevel: String, Codable, CaseIterable {
        case simple, advanced, expert
        var label: String { rawValue.capitalized }
    }

    static func load() -> AppSettings {
        guard let d = UserDefaults.standard.data(forKey: "settings.v1"), let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "settings.v1") }
    }
}


struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            GeneralSettings(settings: $model.settings).tabItem { Label("General", systemImage: "gearshape") }
            CompressionSettingsPane(settings: $model.settings).tabItem { Label("Compression", systemImage: "archivebox") }
            ExtractionSettingsPane(settings: $model.settings).tabItem { Label("Extraction", systemImage: "tray.and.arrow.down") }
            SecuritySettingsPane(settings: $model.settings).tabItem { Label("Security", systemImage: "lock") }
            PerformanceSettingsPane(settings: $model.settings).tabItem { Label("Performance", systemImage: "speedometer") }
            IntegrationsSettingsPane().tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
            AdvancedSettingsPane(settings: $model.settings).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 640, height: 520)
        .onChange(of: model.settings) { _, new in
            new.save()
            model.history.isEnabled = new.historyEnabled
            model.center.mode = new.performanceMode
            DiagnosticLog.shared.isEnabled = new.diagnosticLogging
            for (fmt, eng) in new.preferredEngines { model.service.registry.preferred[FormatID(fmt)] = EngineID(rawValue: eng) }
        }
    }
}

private struct GeneralSettings: View {
    @Binding var settings: AppSettings
    var body: some View {
        Form {
            Picker("Interface", selection: $settings.uiLevel) {
                ForEach(AppSettings.UILevel.allCases, id: \.self) { Text($0.label) }
            }
            .help("Simple shows everyday options; Advanced adds conversion, editing and presets; Expert shows every compression parameter.")
            Picker("Default compression", selection: $settings.defaultPresetID) {
                ForEach(BuiltInPresets.all) { Text($0.name).tag($0.id) }
            }
            Picker("When I open an archive", selection: $settings.doubleClickAction) {
                ForEach(DoubleClickAction.allCases, id: \.self) { Text($0.label) }
            }
            Picker("Folder structure", selection: $settings.extractionMode) {
                ForEach(ExtractionMode.allCases, id: \.self) { Text($0.displayName) }
            }
            LabeledContent("Extract to") {
                HStack {
                    Text(settings.defaultExtractionDestination ?? "Same folder as the archive").foregroundStyle(.secondary)
                    Button("Choose…") {
                        if let u = FolderPicker.choose(prompt: "Choose") { settings.defaultExtractionDestination = u.path }
                    }
                    if settings.defaultExtractionDestination != nil { Button("Reset") { settings.defaultExtractionDestination = nil } }
                }
            }
            Toggle("Open the destination folder after extracting", isOn: $settings.openDestinationAfterExtraction)
            Toggle("Show notifications when operations finish in the background", isOn: $settings.notificationsEnabled)
            Toggle("Show Activity when an operation starts", isOn: $settings.showActivityAfterStarting)
        }
        .formStyle(.grouped)
    }
}

private struct CompressionSettingsPane: View {
    @Binding var settings: AppSettings
    var body: some View {
        Form {
            Picker("Metadata", selection: $settings.defaultMetadata) {
                ForEach(MetadataMode.allCases, id: \.self) { Text($0.displayName) }
            }
            Toggle("Include hidden files", isOn: $settings.includeHiddenFiles)
            Toggle("Normalize file names to NFC (recommended for sharing)", isOn: $settings.normalizeFilenamesNFC)
            Toggle("Exclude .DS_Store, __MACOSX and Thumbs.db by default", isOn: $settings.excludeClutterByDefault)
            Toggle("Verify archives after creating them", isOn: $settings.verifyAfterCompression)
            Picker("Threads", selection: Binding(get: { settings.defaultThreads ?? 0 }, set: { settings.defaultThreads = $0 == 0 ? nil : $0 })) {
                Text("Automatic").tag(0)
                ForEach([1, 2, 4, 6, 8, 12, 16, 24, 32].filter { $0 <= ProcessInfo.processInfo.activeProcessorCount }, id: \.self) { Text("\($0)").tag($0) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExtractionSettingsPane: View {
    @Binding var settings: AppSettings
    var body: some View {
        Form {
            Picker("When a file already exists", selection: $settings.conflictPolicy) {
                ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.displayName) }
            }
            Picker("Symbolic links", selection: $settings.linkPolicy) {
                Text("Keep links that stay inside the folder").tag(ExtractionLinkPolicy.preserveSafe)
                Text("Never create links").tag(ExtractionLinkPolicy.skip)
                Text("Keep all links (trusted archives only)").tag(ExtractionLinkPolicy.preserveAll)
            }
            Toggle("Restore permissions", isOn: $settings.restorePermissions)
            Toggle("Restore extended attributes", isOn: $settings.restoreExtendedAttributes)
            Toggle("Skip __MACOSX folders and ._ files", isOn: $settings.skipMacOSXFolders)
            Toggle("Verify extracted files", isOn: $settings.verifyAfterExtraction)
            Toggle("Extract archives found inside archives", isOn: $settings.extractNestedArchives)
            Section("Safety limits") {
                SizeField(label: "Maximum total size", value: $settings.limits.maxTotalBytes)
                SizeField(label: "Maximum single file", value: $settings.limits.maxEntryBytes)
                Stepper("Maximum files: \(settings.limits.maxEntryCount)", value: $settings.limits.maxEntryCount, in: 1000...50_000_000, step: 100_000)
                Stepper("Maximum compression ratio: \(settings.limits.maxExpansionRatio):1", value: $settings.limits.maxExpansionRatio, in: 100...1_000_000, step: 1000)
                Stepper("Maximum nesting depth: \(settings.limits.maxNestingDepth)", value: $settings.limits.maxNestingDepth, in: 1...16)
                SizeField(label: "Keep free on disk", value: $settings.limits.minimumFreeSpace)
                Button("Restore Defaults") { settings.limits = .default }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SecuritySettingsPane: View {
    @Binding var settings: AppSettings
    @Environment(AppModel.self) private var model
    @State private var keys: [(key: String, label: String)] = []

    var body: some View {
        Form {
            Toggle("Offer to save archive passwords in the Keychain", isOn: $settings.savePasswordsInKeychain)
            Toggle("Require Touch ID or your login password to use saved passwords", isOn: $settings.requireAuthenticationForPasswords)
                .disabled(!settings.savePasswordsInKeychain)
            Toggle("Prefer 7z with encrypted file names for new encrypted archives", isOn: $settings.defaultEncryption7z)
            Toggle("Delete preview files when quitting", isOn: $settings.clearPreviewCacheOnQuit)
            Section("Saved passwords") {
                if keys.isEmpty { Text("No saved passwords.").foregroundStyle(.secondary) }
                ForEach(keys, id: \.key) { k in
                    HStack {
                        Text(k.label)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            try? model.passwordStore.delete(k.key)
                            keys = model.passwordStore.allKeys()
                        }
                    }
                }
            }
            Section("Privacy") {
                Toggle("Keep a history of operations", isOn: $settings.historyEnabled)
                Toggle("Store full paths in history (otherwise names only)", isOn: $settings.historyStoresPaths)
                Button("Clear History") { model.history.clear() }
                Text("Universal Archiver works offline. It has no account, analytics or advertising, and never uploads file names, contents or passwords.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { keys = model.passwordStore.allKeys() }
    }
}

private struct PerformanceSettingsPane: View {
    @Binding var settings: AppSettings
    var body: some View {
        let profile = SystemProfile.current()
        Form {
            Picker("Mode", selection: $settings.performanceMode) {
                ForEach(PerformanceMode.allCases, id: \.self) { Text($0.displayName) }
            }
            .pickerStyle(.radioGroup)
            Text(description(settings.performanceMode)).font(.footnote).foregroundStyle(.secondary)
            LabeledContent("This Mac") {
                Text("\(profile.performanceCores.map { "\($0) performance + " } ?? "")\(profile.efficiencyCores.map { "\($0) efficiency cores" } ?? "\(profile.logicalCores) cores"), \(ByteFormatting.string(profile.physicalMemory)) memory")
            }
            LabeledContent("Threads used now") { Text("\(profile.threads(for: settings.performanceMode))") }
            if profile.effectiveMode(settings.performanceMode) != settings.performanceMode {
                Label("Temporarily using \(profile.effectiveMode(settings.performanceMode).displayName) because of Low Power Mode or thermal pressure.", systemImage: "thermometer.medium")
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }

    func description(_ m: PerformanceMode) -> String {
        switch m {
        case .maximum: return "Uses every core at user-initiated priority. Fastest; uses the most energy."
        case .balanced: return "Uses the performance cores at utility priority, keeping the Mac responsive."
        case .energySaver: return "Runs on the efficiency cores at background priority. Slower, but gentle on battery."
        }
    }
}

private struct IntegrationsSettingsPane: View {
    @State private var message: String?
    let cliPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/archiver").path

    var body: some View {
        Form {
            Section("Finder") {
                Text("Quick Actions (Compress, Extract Here, Extract To…, Test Archive, Calculate SHA-256…) appear in Finder's context menu under Quick Actions and Services. Enable or disable them in System Settings › Keyboard › Keyboard Shortcuts › Services.")
                    .font(.footnote)
                Button("Open Keyboard Shortcuts Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            }
            Section("Default app") {
                Text("Universal Archiver doesn't change your default apps on its own.").font(.footnote).foregroundStyle(.secondary)
                Button("Make Universal Archiver the default for common archives…") {
                    DefaultAppRegistration.makeDefault { message = $0 }
                }
                if let message { Text(message).font(.footnote) }
            }
            Section("Command-line tool") {
                Text("To use `archiver` in Terminal, run:").font(.footnote)
                Text("sudo ln -sf \"\(cliPath)\" /usr/local/bin/archiver").font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("sudo ln -sf \"\(cliPath)\" /usr/local/bin/archiver", forType: .string)
                }
            }
            Section("Shortcuts") {
                Text("Actions for compressing, extracting, converting, verifying, checksums and presets are available in the Shortcuts app.").font(.footnote)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettingsPane: View {
    @Binding var settings: AppSettings
    @Environment(AppModel.self) private var model
    static let encodings = ["", "CP437", "CP850", "CP866", "CP1250", "CP1251", "CP1252", "CP1253", "CP1254", "CP1255", "CP1256", "CP932", "Shift_JIS", "EUC-JP", "GBK", "GB18030", "BIG5", "EUC-KR", "CP949", "KOI8-R", "ISO-8859-1", "ISO-8859-2"]

    var body: some View {
        Form {
            Picker("Legacy file name encoding", selection: $settings.filenameEncoding) {
                ForEach(Self.encodings, id: \.self) { Text($0.isEmpty ? "Automatic (UTF-8, then CP437 for ZIP)" : $0).tag($0) }
            }
            Toggle("Diagnostic logging (file names are anonymised)", isOn: $settings.diagnosticLogging)
            Button("Export Diagnostics…") { ExportPanel.save(text: DiagnosticLog.shared.export(), name: "UniversalArchiver-diagnostics.txt") }
            Section("Engines") {
                ForEach(model.service.registry.engines.map(\.descriptor), id: \.id) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: d.isAvailable ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(d.isAvailable ? .green : .secondary)
                            Text(d.name).bold()
                            Text(d.version ?? "").foregroundStyle(.secondary)
                        }
                        Text(d.implementation + " · " + d.license).font(.caption).foregroundStyle(.secondary)
                        if let r = d.unavailableReason { Text(r).font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
            Section("Format capabilities") {
                FormatCapabilityTable(rows: model.service.registry.capabilityMatrix())
                    .frame(minHeight: 260)
            }
        }
        .formStyle(.grouped)
    }
}

struct FormatCapabilityTable: View {
    let rows: [FormatCapabilityRow]
    var body: some View {
        Table(rows) {
            TableColumn("Format") { r in Text(r.name) }
            TableColumn("Extensions") { r in Text(r.extensions.prefix(4).joined(separator: " ")).foregroundStyle(.secondary) }
            TableColumn("Open") { r in mark(r.availableOperations.contains(.extract)) }.width(40)
            TableColumn("Create") { r in mark(r.availableOperations.contains(.create)) }.width(46)
            TableColumn("Encrypt") { r in mark(r.availableOperations.contains(.encrypt)) }.width(52)
            TableColumn("Engines") { r in Text(r.engines.filter(\.available).map(\.engine.rawValue).joined(separator: ", ")).font(.caption) }
        }
    }
    func mark(_ b: Bool) -> some View { Image(systemName: b ? "checkmark" : "minus").foregroundStyle(b ? .green : .secondary) }
}

struct SizeField: View {
    let label: String
    @Binding var value: UInt64
    @State private var text = ""
    var body: some View {
        LabeledContent(label) {
            TextField("", text: $text)
                .frame(width: 120)
                .onAppear { text = value == .max ? "Unlimited" : ByteFormatting.string(value) }
                .onSubmit {
                    if text.lowercased().hasPrefix("unl") { value = .max } else if let v = FileSplitter.parseSize(text.replacingOccurrences(of: "bytes", with: "")) { value = v }
                    text = value == .max ? "Unlimited" : ByteFormatting.string(value)
                }
        }
    }
}
#endif
