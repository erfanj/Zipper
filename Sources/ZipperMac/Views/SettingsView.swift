#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore
import ArchiveEngines
import ArchiverKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            GeneralSettings(settings: $model.settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            CompressionSettingsPane(settings: $model.settings)
                .tabItem { Label("Compression", systemImage: "archivebox") }
            ExtractionSettingsPane(settings: $model.settings)
                .tabItem { Label("Extraction", systemImage: "tray.and.arrow.up") }
            PrivacySettingsPane(settings: $model.settings)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            AdvancedSettingsPane(settings: $model.settings)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 600, height: 500)
        .onChange(of: model.settings) { _, _ in model.applySettings() }
    }
}

private struct GeneralSettings: View {
    @Binding var settings: AppSettings
    @State private var defaultAppMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("When you open an archive", selection: $settings.openAction) {
                    ForEach(OpenAction.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show results in Finder", isOn: $settings.revealAfterExtraction)
                    .help("After extracting, select the extracted items in Finder.")
                Toggle("Show new archives in Finder", isOn: $settings.revealAfterCompression)
                Toggle("Notify me when work finishes in the background", isOn: $settings.notificationsEnabled)
            }
            Section("Finder") {
                LabeledContent("Quick Actions") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Compress, Extract Here and more appear when you Control-click files in Finder, under Quick Actions or Services.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Choose Which Appear…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                LabeledContent("Default app") {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Open Archives with Zipper…") {
                            Task { defaultAppMessage = await DefaultAppRegistration.makeDefault() }
                        }
                        if let defaultAppMessage { Text(defaultAppMessage).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CompressionSettingsPane: View {
    @Binding var settings: AppSettings
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("New archives") {
                Picker("Format", selection: $settings.defaultFormat) {
                    ForEach(CompressForm.primaryFormats.filter { model.service.creationOptions(for: $0).canCreate }, id: \.self) {
                        Text(CompressForm.label(for: $0)).tag($0)
                    }
                }
                Picker("Compression", selection: $settings.defaultLevel) {
                    ForEach(CompressionLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Mac metadata", selection: $settings.defaultMetadata) {
                    ForEach(MetadataMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Include hidden files", isOn: $settings.includeHiddenFiles)
                Toggle("Leave out .DS_Store, __MACOSX and Thumbs.db", isOn: $settings.excludeClutterByDefault)
                Toggle("Check archives after creating them", isOn: $settings.verifyAfterCompression)
            }
            Section("Your presets") {
                if model.userPresets.isEmpty {
                    Text("Save settings from the Compress window with Presets › Save Current Settings as Preset.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.userPresets) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                            Text(p.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Export…") {
                            if let data = try? PresetStore.export([p]) { Panels.save(data: data, suggestedName: "\(p.name).json") }
                        }
                        .controlSize(.small)
                        Button(role: .destructive) {
                            model.userPresets.removeAll { $0.id == p.id }
                            model.savePresets()
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete preset")
                            .accessibilityLabel("Delete \(p.name)")
                    }
                }
                Button("Import Presets…") { importPresets() }
            }
        }
        .formStyle(.grouped)
    }

    private func importPresets() {
        guard let url = Panels.chooseFiles(prompt: "Import", message: "Choose a presets file (.json).", multiple: false)?.first else { return }
        do {
            let imported = try PresetStore.importPresets(from: Data(contentsOf: url))
            let existing = Set(model.userPresets.map(\.id))
            model.userPresets += imported.filter { !existing.contains($0.id) }
            model.savePresets()
        } catch {
            model.present(ArchiveError.wrap(error), context: "Import presets")
        }
    }
}

private struct ExtractionSettingsPane: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Extract to") {
                    HStack {
                        Text(settings.defaultExtractionDestination.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Same folder as the archive")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            if let u = Panels.chooseFolder(prompt: "Choose") { settings.defaultExtractionDestination = u.path }
                        }
                        if settings.defaultExtractionDestination != nil {
                            Button("Reset") { settings.defaultExtractionDestination = nil }
                        }
                    }
                }
                Picker("Folders", selection: $settings.extractionMode) {
                    Text("Automatic").tag(ExtractionMode.smart)
                    Text("Always in a new folder").tag(ExtractionMode.newFolder)
                    Text("Directly in the destination").tag(ExtractionMode.here)
                }
                Picker("If an item exists", selection: $settings.conflictPolicy) {
                    ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Check extracted files", isOn: $settings.verifyAfterExtraction)
                Toggle("Also extract archives found inside archives", isOn: $settings.extractNestedArchives)
            }
            Section("Files from other systems") {
                Toggle("Skip __MACOSX folders and ._ files", isOn: $settings.skipMacOSXFolders)
                Toggle("Restore permissions", isOn: $settings.restorePermissions)
                Toggle("Restore extended attributes", isOn: $settings.restoreExtendedAttributes)
                Picker("Symbolic links", selection: $settings.linkPolicy) {
                    Text("Keep links that stay inside the folder").tag(ExtractionLinkPolicy.preserveSafe)
                    Text("Never create links").tag(ExtractionLinkPolicy.skip)
                    Text("Keep all links (trusted archives only)").tag(ExtractionLinkPolicy.preserveAll)
                }
            }
            Section {
                SizeField(label: "Largest total size", value: $settings.limits.maxTotalBytes)
                SizeField(label: "Largest single file", value: $settings.limits.maxEntryBytes)
                Stepper("At most \(settings.limits.maxEntryCount.formatted()) items", value: $settings.limits.maxEntryCount, in: 1000...50_000_000, step: 100_000)
                Stepper("Compression ratio up to \(settings.limits.maxExpansionRatio.formatted()):1", value: $settings.limits.maxExpansionRatio, in: 100...1_000_000, step: 1000)
                Stepper("Archives inside archives: \(settings.limits.maxNestingDepth) levels", value: $settings.limits.maxNestingDepth, in: 1...16)
                SizeField(label: "Always keep free", value: $settings.limits.minimumFreeSpace)
                Button("Restore Defaults") { settings.limits = .default }
            } header: {
                Text("Safety limits")
            } footer: {
                Text("These stop “zip bombs” and other hostile archives from filling your disk.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettingsPane: View {
    @Binding var settings: AppSettings
    @Environment(AppModel.self) private var model
    @State private var saved: [SavedPassword] = []

    struct SavedPassword: Identifiable {
        let key: String
        let label: String
        var id: String { key }
    }

    var body: some View {
        Form {
            Section("Passwords") {
                Toggle("Offer to save archive passwords in the keychain", isOn: $settings.savePasswordsInKeychain)
                Toggle("Require Touch ID or your login password to use them", isOn: $settings.requireAuthenticationForPasswords)
                    .disabled(!settings.savePasswordsInKeychain)
                if saved.isEmpty {
                    Text("No saved passwords.").foregroundStyle(.secondary)
                }
                ForEach(saved) { p in
                    HStack {
                        Label(p.label, systemImage: "key")
                        Spacer()
                        Button("Remove", role: .destructive) {
                            try? model.passwordStore?.delete(p.key)
                            reload()
                        }
                        .controlSize(.small)
                    }
                }
            }
            Section("History") {
                Toggle("Keep a history of operations", isOn: $settings.historyEnabled)
                Toggle("Include full paths (otherwise names only)", isOn: $settings.historyStoresPaths)
                    .disabled(!settings.historyEnabled)
                Toggle("Delete preview files when quitting", isOn: $settings.clearPreviewCacheOnQuit)
                Button("Clear History") { model.clearHistory() }
            }
            Section {
                Text("Zipper works entirely on this Mac. It has no account, analytics or advertising, and never sends file names, contents or passwords anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private func reload() {
        saved = (model.passwordStore?.allKeys() ?? []).map { SavedPassword(key: $0.key, label: $0.label) }
    }
}

private struct AdvancedSettingsPane: View {
    @Binding var settings: AppSettings
    @Environment(AppModel.self) private var model
    @State private var showFormats = false
    static let encodings = ["", "CP437", "CP850", "CP866", "CP1250", "CP1251", "CP1252", "CP1253", "CP1254", "CP1255", "CP1256",
                            "CP932", "Shift_JIS", "EUC-JP", "GBK", "GB18030", "BIG5", "EUC-KR", "CP949", "KOI8-R", "ISO-8859-1", "ISO-8859-2"]

    var body: some View {
        let profile = SystemProfile.current()
        Form {
            Section("Performance") {
                Picker("Speed", selection: $settings.performanceMode) {
                    ForEach(PerformanceMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text(description(settings.performanceMode)).font(.caption).foregroundStyle(.secondary)
                LabeledContent("This Mac", value: macDescription(profile))
                if profile.effectiveMode(settings.performanceMode) != settings.performanceMode {
                    Label("Using \(profile.effectiveMode(settings.performanceMode).displayName) for now because of Low Power Mode or heat.", systemImage: "thermometer.medium")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Compatibility") {
                Picker("Old file name encoding", selection: $settings.filenameEncoding) {
                    ForEach(Self.encodings, id: \.self) { Text($0.isEmpty ? "Automatic" : $0).tag($0) }
                }
                .help("For archives made on old Windows or Japanese/Chinese/Russian systems whose names look garbled.")
            }
            Section("Command line") {
                let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(ProductInfo.cliName)").path
                let command = "sudo ln -sf \"\(cli)\" /usr/local/bin/\(ProductInfo.cliName)"
                Text("To use `\(ProductInfo.cliName)` in Terminal, run:").font(.caption)
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
            Section("Engines") {
                ForEach(model.service.registry.engines.map(\.descriptor), id: \.id) { d in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: d.isAvailable ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(d.isAvailable ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name + (d.version.map { " \($0)" } ?? ""))
                            Text(d.unavailableReason ?? "\(d.implementation) · \(d.license)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Show Supported Formats…") { showFormats = true }
            }
            Section("Diagnostics") {
                Toggle("Keep a diagnostic log (file names are anonymized)", isOn: $settings.diagnosticLogging)
                Button("Save Diagnostic Log…") {
                    Panels.save(text: DiagnosticLog.shared.export(), suggestedName: "Zipper Diagnostics.txt")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showFormats) {
            VStack(spacing: 0) {
                FormatCapabilityTable(rows: model.service.registry.capabilityMatrix())
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showFormats = false }.keyboardShortcut(.defaultAction)
                }
                .padding()
            }
        }
    }

    private func description(_ m: PerformanceMode) -> String {
        switch m {
        case .maximum: return "Uses every core. Fastest; uses the most energy."
        case .balanced: return "Uses the performance cores and keeps your Mac responsive."
        case .energySaver: return "Runs on the efficiency cores. Slower, but easy on the battery."
        }
    }

    private func macDescription(_ p: SystemProfile) -> String {
        let cores: String
        if let perf = p.performanceCores, let eff = p.efficiencyCores {
            cores = "\(perf) performance and \(eff) efficiency cores"
        } else {
            cores = "\(p.logicalCores) cores"
        }
        return "\(cores), \(ByteFormatting.string(p.physicalMemory)) memory"
    }
}

struct FormatCapabilityTable: View {
    let rows: [FormatCapabilityRow]

    var body: some View {
        Table(rows) {
            TableColumn("Format") { r in Text(r.name) }
            TableColumn("Extensions") { r in Text(r.extensions.prefix(4).joined(separator: " ")).foregroundStyle(.secondary) }
            TableColumn("Open") { r in mark(r.availableOperations.contains(.extract)) }.width(44)
            TableColumn("Create") { r in mark(r.availableOperations.contains(.create)) }.width(50)
            TableColumn("Encrypt") { r in mark(r.availableOperations.contains(.encrypt)) }.width(56)
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    private func mark(_ b: Bool) -> some View {
        Image(systemName: b ? "checkmark" : "minus")
            .foregroundStyle(b ? .green : .secondary)
            .accessibilityLabel(b ? "Yes" : "No")
    }
}

/// A byte-size text field ("500 GB", "Unlimited") that commits on Return or when it loses focus.
struct SizeField: View {
    let label: String
    @Binding var value: UInt64
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 120)
                .focused($focused)
                .onAppear { text = display(value) }
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                // "Restore Defaults" changes the value from outside: show it, or committing the old
                // text on the next focus change would silently undo the restore.
                .onChange(of: value) { _, v in if !focused { text = display(v) } }
        }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("unl") || t == "∞" {
            value = .max
        } else if let v = FileSplitter.parseSize(t.replacingOccurrences(of: "bytes", with: "")) {
            value = v
        }
        text = display(value)
    }

    private func display(_ v: UInt64) -> String { v == .max ? "Unlimited" : ByteFormatting.string(v) }
}

/// Makes Zipper the default app for common archive types — only when the user asks.
@MainActor
enum DefaultAppRegistration {
    static let types: [UTType] = [
        .zip, UTType("org.7-zip.7-zip-archive"), UTType("com.rarlab.rar-archive"), UTType("public.tar-archive"), .gzip,
        UTType("org.tukaani.xz-archive"), UTType("public.bzip2-archive"), UTType("org.facebook.zstandard-archive"),
    ].compactMap { $0 }

    /// Asks for confirmation, registers the app and returns a message for the user (nil if cancelled).
    static func makeDefault() async -> String? {
        let alert = NSAlert()
        alert.messageText = "Open ZIP, 7z, RAR, TAR, gzip, XZ, bzip2 and Zstandard archives with Zipper?"
        alert.informativeText = "You can change this at any time in Finder with Get Info › Open with."
        alert.addButton(withTitle: "Use Zipper")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let app = Bundle.main.bundleURL
        var done = 0
        for t in types {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: t)
                done += 1
            } catch {
                continue
            }
        }
        return done == types.count ? "Zipper now opens these archives." : "Zipper now opens \(done) of \(types.count) archive types."
    }
}
#endif
