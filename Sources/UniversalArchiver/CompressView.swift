#if os(macOS)
import SwiftUI
import AppKit
import ArchiveCore
import ArchiveEngines
import ArchiverKit

/// The compression workflow: a compact form for everyday use, with advanced settings revealed on
/// demand. Only settings meaningful for the selected format are shown.
struct CompressView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [URL] = []
    @State private var archiveName = ""
    @State private var presetID = BuiltInPresets.balanced.id
    @State private var settings = BuiltInPresets.balanced.settings
    @State private var encrypt = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var split = false
    @State private var splitText = "100 MB"
    @State private var destination: URL?
    @State private var showAdvanced = false
    @State private var verify = false
    @State private var excludeClutter = false
    @State private var excludeDev = false
    @State private var customExcludes = ""
    @State private var collection: SourceCollection?
    @State private var scanning = false
    @State private var recommendation: Recommendation?
    @State private var analyzing = false
    @State private var showExcluded = false
    @State private var savePresetName = ""
    @State private var showSavePreset = false

    static let commonFormats: [FormatID] = [.zip, .sevenZip, .tarGzip, .tarXz, .tarZstd, .tarBzip2, .tarLz4, .tarBrotli, .tar,
                                             .appleArchive, .appleEncryptedArchive, .dmg, .rar, .cbz, .jar, .epub, .iso, .cpio, .xar, .wim]
    static let streamFormats: [FormatID] = [.gzip, .xz, .zstd, .bzip2, .lz4, .brotli, .lzip, .lzma]

    var options: CreationOptions { model.service.creationOptions(for: settings.format) }
    var expert: Bool { model.settings.uiLevel == .expert }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader("Create Archive")
                if items.isEmpty {
                    DropZone(targeted: .constant(false))
                        .onTapGesture { if let u = FilePicker.chooseItems(prompt: "Add") { items = u } }
                        .dropDestination(for: URL.self) { urls, _ in items = urls; return true }
                } else {
                    selectionSummary
                    form
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear(perform: adoptPending)
        .onChange(of: model.pendingCompression) { _, _ in adoptPending() }
        .onChange(of: settings) { _, _ in rescan() }
        .onChange(of: items) { _, _ in rescan() }
        .sheet(isPresented: $showExcluded) { ExcludedList(collection: collection) }
        .alert("Save Preset", isPresented: $showSavePreset) {
            TextField("Preset name", text: $savePresetName)
            Button("Save") { savePreset() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Presets store settings only, never passwords.") }
    }

    // MARK: Sections

    var selectionSummary: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let c = collection {
                        Text("Selected: \(c.fileCount) file\(c.fileCount == 1 ? "" : "s"), \(c.directoryCount) folder\(c.directoryCount == 1 ? "" : "s")")
                        Text("·").foregroundStyle(.secondary)
                        Text("Total size: \(ByteFormatting.string(c.totalBytes))")
                    } else if scanning {
                        ProgressView().controlSize(.small)
                        Text("Scanning…")
                    }
                    Spacer()
                    Button("Add…") { if let u = FilePicker.chooseItems(prompt: "Add") { items += u } }
                    Button("Clear") { items = []; collection = nil }
                }
                Text(items.prefix(4).map(\.lastPathComponent).joined(separator: ", ") + (items.count > 4 ? " and \(items.count - 4) more" : ""))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if let c = collection, !c.excluded.isEmpty {
                    Button("\(c.excluded.count) item\(c.excluded.count == 1 ? "" : "s") will be left out — Review") { showExcluded = true }
                        .buttonStyle(.link)
                }
                if let c = collection, !c.notDownloaded.isEmpty {
                    Label("\(c.notDownloaded.count) cloud file(s) will be downloaded first.", systemImage: "icloud.and.arrow.down").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dropDestination(for: URL.self) { urls, _ in items += urls; return true }
    }

    var form: some View {
        Form {
            TextField("Archive name", text: $archiveName, prompt: Text(defaultName))
            Picker("Format", selection: $settings.format) {
                ForEach(Self.commonFormats.filter { model.service.creationOptions(for: $0).canCreate }, id: \.self) { f in
                    Text(formatLabel(f)).tag(f)
                }
                if items.count == 1, collection?.directoryCount == 0 {
                    Divider()
                    ForEach(Self.streamFormats.filter { model.service.creationOptions(for: $0).canCreate }, id: \.self) { f in
                        Text(formatLabel(f) + " (single file)").tag(f)
                    }
                }
            }
            Picker("Compression", selection: $presetID) {
                ForEach(model.allPresets) { Text($0.name).tag($0.id) }
                Text("Custom").tag("custom")
            }
            .onChange(of: presetID) { _, id in applyPreset(id) }

            if !options.encryptionMethods.isEmpty {
                Toggle("Encrypt archive", isOn: $encrypt)
                if encrypt { encryptionSection }
            }
            if options.canSplit {
                Toggle("Split archive", isOn: $split)
                if split {
                    LabeledContent("Part size") {
                        HStack {
                            TextField("Size", text: $splitText).frame(width: 110).help("e.g. 250 MB, 1.5 GB, 4096 KB, 2 TB")
                            Menu("Presets") {
                                ForEach(FileSplitter.presets.map { $0.0 }, id: \.self) { name in Button(name) { splitText = name } }
                            }
                            .fixedSize()
                            if FileSplitter.parseSize(splitText) == nil { Text("Invalid size").foregroundStyle(.red).font(.caption) }
                        }
                    }
                }
            }
            DestinationPicker(label: "Destination", url: $destination, placeholder: "Same folder as the originals")
            Toggle("Verify the archive after creating it", isOn: $verify)
            DisclosureGroup("Advanced Options", isExpanded: $showAdvanced) { advanced }
            advisorSection
            HStack {
                if model.settings.uiLevel != .simple {
                    Button("Save as Preset…") { showSavePreset = true }
                }
                Spacer()
                Button("Cancel") { items = []; model.selection = .home }
                    .keyboardShortcut(.cancelAction)
                Button("Create Archive") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .formStyle(.grouped)
    }

    var encryptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Method", selection: Binding(get: { settings.encryption?.method ?? options.encryptionMethods.first! },
                                                 set: { settings.encryption = EncryptionSettings(method: $0, encryptFilenames: settings.encryption?.encryptFilenames ?? false) })) {
                ForEach(options.encryptionMethods, id: \.self) { m in Text(m.displayName).tag(m) }
            }
            if options.canEncryptFilenames {
                Toggle("Encrypt file names", isOn: Binding(get: { settings.encryption?.encryptFilenames ?? false },
                                                           set: { settings.encryption?.encryptFilenames = $0 }))
            }
            if let m = settings.encryption?.method {
                Label(m.scopeExplanation, systemImage: m.isConsideredSecure ? "info.circle" : "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(m.isConsideredSecure ? Color.secondary : Color.orange)
            }
            NewPasswordFields(password: $password, confirmation: $confirmation)
        }
        .onAppear {
            if settings.encryption == nil, let first = options.encryptionMethods.first {
                settings.encryption = EncryptionSettings(method: first, encryptFilenames: options.canEncryptFilenames)
            }
        }
    }

    @ViewBuilder var advanced: some View {
        if !options.methods.isEmpty {
            Picker("Method", selection: Binding(get: { settings.method ?? options.methods.first! }, set: { settings.method = $0; presetID = "custom" })) {
                ForEach(options.methods, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
        if options.supportsLevel {
            LabeledContent("Level") {
                HStack {
                    Text("Fastest").font(.caption)
                    Slider(value: Binding(get: { Double(settings.level) }, set: { settings.level = Int($0); presetID = "custom" }), in: 0...9, step: 1)
                    Text("Smallest").font(.caption)
                    Text("\(settings.level)").monospacedDigit().frame(width: 18)
                }
            }
        }
        if expert, options.supportsDictionary {
            Picker("Dictionary size", selection: Binding(get: { settings.dictionarySize ?? 0 }, set: { settings.dictionarySize = $0 == 0 ? nil : $0 })) {
                Text("Automatic").tag(UInt64(0))
                ForEach([1, 4, 16, 32, 64, 128, 256, 512, 1024] as [UInt64], id: \.self) { mb in Text("\(mb) MB").tag(mb << 20) }
            }
        }
        if expert, options.supportsWordSize {
            Picker("Word size", selection: Binding(get: { settings.wordSize ?? 0 }, set: { settings.wordSize = $0 == 0 ? nil : $0 })) {
                Text("Automatic").tag(0)
                ForEach([16, 32, 64, 128, 273], id: \.self) { Text("\($0)").tag($0) }
            }
        }
        if options.supportsSolid {
            Picker("Solid archive", selection: Binding(get: { solidTag }, set: { setSolid($0) })) {
                Text("Automatic").tag("auto"); Text("On").tag("on"); Text("Off").tag("off"); Text("16 MB blocks").tag("16m"); Text("256 MB blocks").tag("256m")
            }
        }
        if options.supportsThreads {
            Picker("Threads", selection: Binding(get: { settings.threads ?? 0 }, set: { settings.threads = $0 == 0 ? nil : $0 })) {
                Text("Automatic (\(model.settings.performanceMode.displayName))").tag(0)
                ForEach([1, 2, 4, 8, 16].filter { $0 <= ProcessInfo.processInfo.activeProcessorCount }, id: \.self) { Text("\($0)").tag($0) }
            }
        }
        Picker("Metadata", selection: $settings.metadata) {
            ForEach(MetadataMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .help(options.supportsMacMetadata ? "Mac Preservation stores extended attributes and resource forks." : "This format can't store macOS extended attributes; Mac Preservation behaves like Standard.")
        Toggle("Include hidden files", isOn: $settings.includeHidden)
        Picker("Symbolic links", selection: $settings.symlinks) {
            Text("Store as links").tag(SymlinkPolicy.preserve)
            Text("Store the files they point to").tag(SymlinkPolicy.follow)
            Text("Leave out").tag(SymlinkPolicy.skip)
        }
        if items.count == 1 {
            Toggle("Include the enclosing folder", isOn: $settings.includeRootFolder)
        }
        if items.count > 1 {
            Picker("Create", selection: $settings.grouping) {
                Text("One archive with everything").tag(ArchiveGrouping.single)
                Text("One archive per item").tag(ArchiveGrouping.perItem)
                Text("One archive per folder").tag(ArchiveGrouping.perFolder)
            }
        }
        Picker("File names", selection: $settings.filenameNormalization) {
            Text("Keep as is").tag(UnicodeNormalization.none)
            Text("Normalize (NFC, best for sharing)").tag(UnicodeNormalization.nfc)
        }
        Toggle("Leave out .DS_Store, __MACOSX, Thumbs.db", isOn: $excludeClutter)
        Toggle("Leave out .git, node_modules, build folders and logs", isOn: $excludeDev)
        TextField("Other exclusions", text: $customExcludes, prompt: Text("*.tmp, cache/, re:^tmp_"))
            .help("Comma-separated globs. A trailing / matches folders. Prefix with re: for a regular expression.")
        if options.supportsComment {
            TextField("Comment", text: Binding(get: { settings.comment ?? "" }, set: { settings.comment = $0.isEmpty ? nil : $0 }))
        }
    }

    var advisorSection: some View {
        Section {
            if let r = recommendation {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Recommended: \(r.primary.title)").font(.headline)
                        Spacer()
                        Button("Use") { apply(r.primary.settings) }
                    }
                    Text(r.primary.explanation).font(.callout)
                    if let b = r.primary.estimatedBytes { Text("Estimated size ≈ \(ByteFormatting.string(b)) (estimate)").font(.caption) }
                    ForEach(r.alternatives, id: \.title) { alt in
                        HStack {
                            Text("\(alt.explanation)\(alt.estimatedBytes.map { " ≈ \(ByteFormatting.string($0))" } ?? "")").font(.caption)
                            Spacer()
                            Button("Use \(alt.title)") { apply(alt.settings) }.controlSize(.small)
                        }
                    }
                    Text(r.basis).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("Not sure which format to use?")
                    Spacer()
                    if analyzing { ProgressView().controlSize(.small) }
                    Button("Recommend Settings") { analyze() }.disabled(analyzing || collection == nil)
                }
            }
        }
    }

    // MARK: Logic

    var defaultName: String {
        if items.count == 1 { return items[0].hasDirectoryPath ? items[0].lastPathComponent : items[0].deletingPathExtension().lastPathComponent }
        return "Archive"
    }

    var canCreate: Bool {
        guard !items.isEmpty, options.canCreate else { return false }
        if encrypt { return !password.isEmpty && password == confirmation }
        if split { return FileSplitter.parseSize(splitText) != nil }
        return true
    }

    func formatLabel(_ f: FormatID) -> String {
        let d = FormatCatalog.descriptor(for: f)
        return "\(d?.name ?? f.rawValue) (.\(ArchiveService.fileExtension(for: f)))"
    }

    var solidTag: String {
        switch settings.solid {
        case nil: return "auto"
        case .on?: return "on"
        case .off?: return "off"
        case .blockSize(let b)?: return b <= 16 << 20 ? "16m" : "256m"
        }
    }

    func setSolid(_ t: String) {
        switch t {
        case "on": settings.solid = .on
        case "off": settings.solid = .off
        case "16m": settings.solid = .blockSize(16 << 20)
        case "256m": settings.solid = .blockSize(256 << 20)
        default: settings.solid = nil
        }
    }

    func adoptPending() {
        guard !model.pendingCompression.isEmpty else { return }
        items = model.pendingCompression
        model.pendingCompression = []
        if presetID == BuiltInPresets.balanced.id { applyPreset(model.settings.defaultPresetID) }
    }

    func applyPreset(_ id: String) {
        guard let p = model.allPresets.first(where: { $0.id == id }) else { return }
        presetID = id
        apply(p.settings)
        encrypt = p.promptsForPassword || p.settings.encryption != nil
        if p.postActions.contains(.verifyArchive) { verify = true }
    }

    func apply(_ s: CompressionSettings) {
        settings = s
        if model.settings.excludeClutterByDefault { excludeClutter = true }
        encrypt = s.encryption != nil
    }

    func effectiveSettings() -> CompressionSettings {
        var s = settings
        if !encrypt { s.encryption = nil }
        s.splitVolumeSize = split ? FileSplitter.parseSize(splitText) : nil
        if excludeClutter { s.filters += FileFilter.commonExclusions }
        if excludeDev { s.filters += FileFilter.developerExclusions }
        for g in customExcludes.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !g.isEmpty {
            s.filters.append(FilterRule(.exclude, g.hasPrefix("re:") ? .regex(String(g.dropFirst(3))) : .glob(g)))
        }
        if s.threads == nil { s.threads = model.settings.defaultThreads }
        return s
    }

    func rescan() {
        guard !items.isEmpty else { collection = nil; return }
        scanning = true
        let urls = items
        let s = effectiveSettings()
        Task {
            let r = await offMain { try SourceCollector.collect(urls, settings: s) }
            scanning = false
            if case .success(let c) = r { collection = c }
        }
    }

    func analyze() {
        guard let c = collection else { return }
        analyzing = true
        Task {
            let r = await offMain { () -> Recommendation in
                let p = CompressionAdvisor.profile(c, compressor: LibArchiveSampleCompressor(), methods: [.deflate, .lzma2, .zstd])
                return CompressionAdvisor.recommend(p)
            }
            analyzing = false
            if case .success(let rec) = r { recommendation = rec }
        }
    }

    func savePreset() {
        let name = savePresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var s = effectiveSettings()
        s.splitVolumeSize = split ? s.splitVolumeSize : nil
        model.userPresets.append(Preset(id: "user." + UUID().uuidString, name: name, summary: "\(formatLabel(s.format)), level \(s.level)",
                                        settings: s, postActions: verify ? [.verifyArchive] : [], promptsForPassword: encrypt))
        model.savePresets()
        savePresetName = ""
    }

    func create() {
        let request = CompressRequest(items: items, destinationDirectory: destination, archiveName: archiveName.isEmpty ? nil : archiveName,
                                      settings: effectiveSettings(), password: encrypt ? Secret(password) : nil,
                                      verifyAfterCreation: verify || model.settings.verifyAfterCompression)
        let service = model.service
        let title = "Compress \(items.count == 1 ? items[0].lastPathComponent : "\(items.count) items")"
        model.run(title, kind: .compress, inputs: items) { progress in
            let o = try service.compress(request, progress: progress)
            let outs = o.archives.flatMap(\.outputs)
            let saved = o.archives.reduce(Int64(0)) { $0 + Int64($1.inputBytes) - Int64($1.outputBytes) }
            DispatchQueue.main.async { if let first = outs.first { NSWorkspace.shared.activateFileViewerSelecting([first]) } }
            return "\(outs.map(\.lastPathComponent).joined(separator: ", "))\(saved > 0 ? " — saved \(ByteFormatting.string(UInt64(saved)))" : "")"
        }
        password = ""
        confirmation = ""
        items = []
        collection = nil
    }
}

struct ExcludedList: View {
    let collection: SourceCollection?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            Text("Items that will be left out").font(.headline)
            List(Array((collection?.excluded ?? []).enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading) {
                    Text(e.path)
                    Text(e.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(width: 520, height: 420)
    }
}

struct PresetDetailView: View {
    let preset: Preset
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            SectionHeader(preset.name, preset.summary)
            LabeledContent("Format", value: FormatCatalog.descriptor(for: preset.settings.format)?.name ?? preset.settings.format.rawValue)
            LabeledContent("Level", value: "\(preset.settings.level)")
            LabeledContent("Encryption", value: preset.settings.encryption?.method.displayName ?? "None")
            LabeledContent("Exclusions", value: preset.settings.filters.map(\.displayText).joined(separator: "; ").ifEmpty("None"))
            HStack {
                Button("Use…") {
                    if let urls = FilePicker.chooseItems(prompt: "Compress") { model.pendingCompression = urls; model.selection = .compress }
                }
                Button("Export…") { if let d = try? PresetStore.export([preset]) { ExportPanel.save(data: d, name: "\(preset.name).json") } }
                Button("Delete", role: .destructive) {
                    model.userPresets.removeAll { $0.id == preset.id }
                    model.savePresets()
                    model.selection = .home
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
#endif
