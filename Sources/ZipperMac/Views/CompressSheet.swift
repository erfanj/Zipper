#if os(macOS)
import SwiftUI
import AppKit
import ArchiveCore
import ArchiverKit

/// The "Compress" sheet: name, format, compression level and the common options up front;
/// everything else behind "Advanced Options". Only settings the chosen format supports are shown.
struct CompressSheet: View {
    @Bindable var form: CompressForm
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showExcluded = false
    @State private var showSavePreset = false
    @State private var presetName = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                itemsSection
                mainSection
                securitySection
                Section {
                    DisclosureGroup("Advanced Options", isExpanded: $form.showAdvanced) { advanced }
                }
                if form.collection != nil { advisorSection }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 520, idealHeight: 640)
        .task(id: form.scanKey) { await form.scan() }
        .sheet(isPresented: $showExcluded) { ExcludedItemsView(collection: form.collection) }
        .alert("Save as Preset", isPresented: $showSavePreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") { savePreset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Presets keep these settings for next time. Passwords are never saved in presets.")
        }
    }

    // MARK: Sections

    private var itemsSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(nsImage: form.items.count == 1 ? FileIcons.icon(forFile: form.items[0]) : NSImage(named: NSImage.multipleDocumentsName) ?? FileIcons.folder)
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(itemsTitle).lineLimit(1).truncationMode(.middle)
                    Group {
                        if let c = form.collection {
                            Text("\(c.fileCount) file\(c.fileCount == 1 ? "" : "s"), \(c.directoryCount) folder\(c.directoryCount == 1 ? "" : "s") · \(ByteFormatting.string(c.totalBytes))")
                        } else if form.isScanning {
                            Text("Counting…")
                        } else {
                            Text(" ")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add…") { if let u = Panels.chooseItemsToCompress(prompt: "Add") { form.add(u) } }
                    .controlSize(.small)
            }
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in form.add(urls); return !urls.isEmpty }
            if let c = form.collection, !c.excluded.isEmpty {
                Button("\(c.excluded.count) item\(c.excluded.count == 1 ? "" : "s") will be left out…") { showExcluded = true }
                    .buttonStyle(.link)
            }
            if let c = form.collection, !c.notDownloaded.isEmpty {
                Label("\(c.notDownloaded.count) item\(c.notDownloaded.count == 1 ? " is" : "s are") in iCloud and will be downloaded first.", systemImage: "icloud.and.arrow.down")
                    .font(.caption)
            }
        }
    }

    private var itemsTitle: String {
        form.items.count == 1 ? form.items[0].lastPathComponent : "\(form.items.count) items"
    }

    private var mainSection: some View {
        Section {
            TextField("Name", text: $form.archiveName, prompt: Text(form.defaultName))
            Picker("Format", selection: $form.format) {
                ForEach(form.creatable(CompressForm.primaryFormats), id: \.self) { f in
                    Text(CompressForm.label(for: f)).tag(f)
                }
                Divider()
                ForEach(form.creatable(CompressForm.otherFormats), id: \.self) { f in
                    Text(CompressForm.label(for: f)).tag(f)
                }
                if form.isSingleFile {
                    Divider()
                    ForEach(form.creatable(CompressForm.streamFormats), id: \.self) { f in
                        Text(CompressForm.label(for: f) + " — single file").tag(f)
                    }
                }
            }
            if form.options.supportsLevel {
                Picker("Compression", selection: $form.level) {
                    ForEach(CompressionLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help(form.level.help)
            }
            DestinationRow(label: "Save to", url: form.destination, placeholder: "Same folder as the originals") { form.destination = $0 }
        } footer: {
            if let note = formatNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var formatNote: String? {
        switch form.format {
        case .zip: return "ZIP opens on every computer, including Windows, without extra software."
        case .sevenZip: return "7z makes smaller archives and can hide file names. Recipients may need a 7z app on Windows."
        case .dmg: return "A disk image opens like a drive on any Mac."
        case .appleArchive: return "Apple Archive is fast and keeps all Mac metadata; it opens only on Macs."
        case .rar: return "Creating RAR archives uses RARLAB's licensed RAR program."
        default:
            return FormatCatalog.descriptor(for: form.format)?.kind == .compressionStream ? "Compresses one file without putting it in an archive." : nil
        }
    }

    private var securitySection: some View {
        Section {
            Toggle("Encrypt with a password", isOn: Binding(get: { form.encrypt }, set: { form.setEncrypt($0) }))
                .disabled(!form.canEncrypt)
            if form.encrypt {
                let methods = form.options.encryptionMethods
                if methods.count > 1 {
                    Picker("Encryption", selection: $form.encryptionMethod) {
                        ForEach(methods, id: \.self) { m in Text(m.displayName).tag(Optional(m)) }
                    }
                }
                if form.options.canEncryptFilenames {
                    Toggle("Also hide the file names", isOn: $form.encryptFilenames)
                }
                NewPasswordFields(password: $form.password, confirmation: $form.confirmation)
                if let m = form.encryptionMethod {
                    Label(m.scopeExplanation, systemImage: m.isConsideredSecure ? "info.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(m.isConsideredSecure ? Color.secondary : Color.orange)
                }
            }
            if form.options.canSplit {
                Toggle("Split into parts", isOn: $form.split)
                if form.split {
                    LabeledContent("Part size") {
                        HStack {
                            TextField("Size", text: $form.splitText, prompt: Text("100 MB"))
                                .frame(width: 110)
                                .help("For example 250 MB, 1.5 GB or 4096 KB")
                            Menu("Common Sizes") {
                                ForEach(FileSplitter.presets.map { $0.0 }, id: \.self) { name in Button(name) { form.splitText = name } }
                            }
                            .fixedSize()
                        }
                    }
                }
            }
            Toggle("Check the archive after creating it", isOn: $form.verify)
        } footer: {
            if !form.canEncrypt {
                Text("\(FormatCatalog.descriptor(for: form.format)?.name ?? "This format") can't be encrypted. Choose ZIP or 7z for a password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var advanced: some View {
        let o = form.options
        if !o.methods.isEmpty {
            Picker("Method", selection: $form.method) {
                Text("Automatic").tag(CompressionMethod?.none)
                ForEach(o.methods, id: \.self) { Text($0.displayName).tag(Optional($0)) }
            }
        }
        if o.supportsLevel {
            LabeledContent("Level") {
                HStack {
                    Slider(value: Binding(get: { Double(form.engineLevel) }, set: { form.engineLevel = Int($0.rounded()) }), in: 0...9, step: 1) {
                        Text("Level")
                    } minimumValueLabel: {
                        Text("Fastest").font(.caption)
                    } maximumValueLabel: {
                        Text("Smallest").font(.caption)
                    }
                    .labelsHidden()
                    Text("\(form.engineLevel)").monospacedDigit().frame(width: 16)
                }
            }
        }
        if o.supportsDictionary {
            Picker("Dictionary size", selection: Binding(get: { form.dictionarySize ?? 0 }, set: { form.dictionarySize = $0 == 0 ? nil : $0 })) {
                Text("Automatic").tag(UInt64(0))
                ForEach([1, 4, 16, 32, 64, 128, 256, 512, 1024] as [UInt64], id: \.self) { mb in Text("\(mb) MB").tag(mb << 20) }
            }
        }
        if o.supportsWordSize {
            Picker("Word size", selection: Binding(get: { form.wordSize ?? 0 }, set: { form.wordSize = $0 == 0 ? nil : $0 })) {
                Text("Automatic").tag(0)
                ForEach([16, 32, 64, 128, 273], id: \.self) { Text("\($0)").tag($0) }
            }
        }
        if o.supportsSolid {
            Picker("Solid", selection: $form.solidChoice) {
                Text("Automatic").tag("auto")
                Text("On").tag("on")
                Text("Off").tag("off")
                Text("16 MB blocks").tag("16m")
                Text("256 MB blocks").tag("256m")
            }
            .help("Solid archives are smaller, but extracting one file means decompressing the files stored before it.")
        }
        if o.supportsThreads {
            Picker("Threads", selection: Binding(get: { form.threads ?? 0 }, set: { form.threads = $0 == 0 ? nil : $0 })) {
                Text("Automatic").tag(0)
                ForEach([1, 2, 4, 8, 12, 16].filter { $0 <= ProcessInfo.processInfo.activeProcessorCount }, id: \.self) { Text("\($0)").tag($0) }
            }
        }
        Picker("Mac metadata", selection: $form.metadata) {
            ForEach(MetadataMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .help(o.supportsMacMetadata ? "Mac Preservation keeps extended attributes and resource forks." : "This format can't store Mac metadata; Mac Preservation behaves like Standard.")
        if form.items.count == 1, !form.isSingleFile {
            Toggle("Include the folder itself", isOn: $form.includeRootFolder)
        }
        if form.items.count > 1 {
            Picker("Create", selection: $form.grouping) {
                Text("One archive with everything").tag(ArchiveGrouping.single)
                Text("One archive per item").tag(ArchiveGrouping.perItem)
                Text("One archive per folder").tag(ArchiveGrouping.perFolder)
            }
        }
        Toggle("Include hidden files", isOn: $form.includeHidden)
        Picker("Symbolic links", selection: $form.symlinks) {
            Text("Store as links").tag(SymlinkPolicy.preserve)
            Text("Store what they point to").tag(SymlinkPolicy.follow)
            Text("Leave out").tag(SymlinkPolicy.skip)
        }
        Toggle("Normalize file names for other systems", isOn: $form.normalizeNames)
            .help("Stores names in Unicode NFC, which Windows and Linux expect.")
        Toggle("Leave out .DS_Store, __MACOSX and Thumbs.db", isOn: $form.excludeClutter)
        Toggle("Leave out .git, node_modules, build folders and logs", isOn: $form.excludeDeveloperFiles)
        TextField("Also leave out", text: $form.customExclusions, prompt: Text("*.tmp, cache/"))
            .help("Comma-separated patterns. A trailing / matches folders. Start with re: for a regular expression.")
        if o.supportsComment {
            TextField("Comment", text: $form.comment)
        }
    }

    private var advisorSection: some View {
        Section("Suggestions") {
            if let r = form.recommendation {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.primary.title).font(.headline)
                        Spacer()
                        Button("Use") { form.apply(r.primary.settings) }
                    }
                    Text(r.primary.explanation).font(.callout)
                    if let b = r.primary.estimatedBytes { Text("Estimated size: about \(ByteFormatting.string(b))").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(r.alternatives, id: \.title) { alt in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alt.title)
                            Text(alt.explanation + (alt.estimatedBytes.map { " About \(ByteFormatting.string($0))." } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use") { form.apply(alt.settings) }.controlSize(.small)
                    }
                }
            } else {
                HStack {
                    Text("Not sure which format to choose?")
                    Spacer()
                    if form.isAnalyzing { ProgressView().controlSize(.small) }
                    Button("Suggest Settings") { Task { await form.recommend() } }
                        .disabled(form.isAnalyzing)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(model.allPresets) { p in
                    Button(p.name) { form.apply(p) }
                }
                Divider()
                Button("Save Current Settings as Preset…") { presetName = ""; showSavePreset = true }
            } label: {
                Text(form.appliedPreset ?? "Presets")
            }
            .fixedSize()
            .help("Apply a saved combination of settings")
            if let problem = form.problem, !form.items.isEmpty {
                Text(problem).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Compress") {
                form.start()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!form.canCreate)
        }
        .padding(16)
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.userPresets.append(form.makePreset(named: name))
        model.savePresets()
    }
}

struct ExcludedItemsView: View {
    let collection: SourceCollection?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Items left out of the archive").font(.headline).padding()
            List(Array((collection?.excluded ?? []).enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.path).lineLimit(1).truncationMode(.middle)
                    Text(e.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 420)
    }
}
#endif
