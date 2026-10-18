#if os(macOS)
import SwiftUI
import AppKit
import ArchiveCore
import ArchiverKit

/// The Tools window: utilities that most people need occasionally, kept out of the main window.
struct ToolsWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(ToolsState.self) private var tools

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<Tool?>(get: { model.selectedTool }, set: { if let t = $0 { model.selectedTool = t } })) {
                ForEach(Tool.allCases) { tool in
                    Label(tool.title, systemImage: tool.symbol).tag(tool)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            ToolDetail(tool: model.selectedTool)
                .id(model.selectedTool)
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(model.selectedTool.title)
        .task(id: model.toolInput) {
            guard !model.toolInput.isEmpty else { return }
            tools.receive(model.toolInput, for: model.selectedTool)
            model.toolInput = []
        }
    }
}

struct ToolDetail: View {
    let tool: Tool
    @Environment(ToolsState.self) private var tools

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tint)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.title).font(.title2.weight(.semibold))
                        Text(tool.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                switch tool {
                case .test: IntegrityToolView(tool: tools.test)
                case .repair: RepairToolView(tool: tools.repair)
                case .convert: ConvertToolView(tool: tools.convert)
                case .batchExtract: BatchToolView(tool: tools.batch)
                case .checksums: ChecksumToolView(tool: tools.checksums)
                case .splitJoin: SplitJoinToolView(tool: tools.splitJoin)
                case .compare: CompareToolView(tool: tools.compare)
                case .duplicates: DuplicatesToolView(tool: tools.duplicates)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The primary button of a tool, showing a spinner while the tool's work runs.
struct RunButton: View {
    let title: String
    let isRunning: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(disabled || isRunning)
            if isRunning { ProgressView().controlSize(.small) }
        }
    }
}

// MARK: Tools

struct IntegrityToolView: View {
    @Bindable var tool: IntegrityTool
    @Environment(AppModel.self) private var model

    var body: some View {
        FileListBox(urls: $tool.archives)
        RunButton(title: tool.archives.count > 1 ? "Test Archives" : "Test Archive", isRunning: tool.isRunning, disabled: tool.archives.isEmpty) { tool.run(model) }
        ForEach(Array(tool.reports.enumerated()), id: \.offset) { _, r in
            Label(r.result == .passed ? "\(r.archive): passed" : "\(r.archive): problems found",
                  systemImage: r.result == .passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(r.result == .passed ? .green : .orange)
                .font(.headline)
            ReportText(text: r.textSummary)
        }
        if !tool.reports.isEmpty {
            Button("Save Report…") { Panels.save(text: tool.reportText, suggestedName: "Integrity Report.txt") }
        }
    }
}

struct RepairToolView: View {
    @Bindable var tool: RepairTool
    @Environment(AppModel.self) private var model

    var body: some View {
        FileListBox(urls: Binding(get: { tool.archive.map { [$0] } ?? [] }, set: { tool.setArchive($0.first) }),
                    prompt: "Drop a damaged archive here or click Choose.", multiple: false)
        HStack {
            RunButton(title: "Analyze", isRunning: tool.isRunning, disabled: tool.archive == nil) { tool.analyze(model) }
            Button("Recover Files…") {
                guard let a = tool.archive,
                      let dest = Panels.chooseFolder(prompt: "Recover Here", message: "Choose where to put the recovered files.", directory: a.deletingLastPathComponent())
                else { return }
                tool.recover(model, to: dest)
            }
            .disabled(tool.archive == nil || tool.isRunning)
        }
        if let a = tool.analysis {
            GroupBox("Analysis") {
                VStack(alignment: .leading, spacing: 6) {
                    Label(a.estimate, systemImage: a.isDamaged ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .foregroundStyle(a.isDamaged ? .orange : .green)
                        .font(.headline)
                    ForEach(a.problems, id: \.self) { Text("• " + $0).font(.callout) }
                    if !a.missingVolumes.isEmpty { Text("Missing parts: " + a.missingVolumes.joined(separator: ", ")).font(.callout) }
                    if a.canRebuildStructure { Label("The ZIP directory can be rebuilt.", systemImage: "wrench.adjustable").font(.callout) }
                    if a.canUseRecoveryRecord { Label("The RAR recovery record can be used.", systemImage: "cross.case").font(.callout) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
        if let r = tool.report {
            Text("Recovery Report").font(.headline)
            ReportText(text: r.textReport)
            HStack {
                Button("Show Recovered Files") { model.platform.reveal([URL(fileURLWithPath: r.destination)]) }
                Button("Save Report…") { Panels.save(text: r.textReport, suggestedName: "Recovery Report.txt") }
            }
        }
    }
}

struct ConvertToolView: View {
    @Bindable var tool: ConvertTool
    @Environment(AppModel.self) private var model

    var body: some View {
        FileListBox(urls: $tool.archives)
        Form {
            Picker("Convert to", selection: $tool.presetIndex) {
                ForEach(Array(ConversionPresets.all.enumerated()), id: \.offset) { i, p in Text(p.name).tag(i) }
            }
            if tool.needsPassword {
                NewPasswordFields(password: $tool.password, confirmation: $tool.confirmation)
            }
            Toggle("Move the originals to the Trash after checking the new archives", isOn: $tool.trashOriginals)
        }
        .formStyle(.grouped)
        .frame(minHeight: tool.needsPassword ? 260 : 130)
        ForEach(tool.warnings, id: \.self) { w in
            Label("\(w.feature): \(w.message)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        }
        HStack {
            RunButton(title: tool.archives.count > 1 ? "Convert \(tool.archives.count) Archives" : "Convert", isRunning: false, disabled: tool.problem != nil) { tool.run(model) }
            if let p = tool.problem, !tool.archives.isEmpty { Text(p).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: WarningKey(archives: tool.archives, preset: tool.presetIndex)) { await tool.refreshWarnings(model) }
    }

    struct WarningKey: Equatable {
        let archives: [URL]
        let preset: Int
    }
}

struct BatchToolView: View {
    @Bindable var tool: BatchTool
    @Environment(AppModel.self) private var model

    var body: some View {
        FileListBox(urls: $tool.archives)
        Form {
            DestinationRow(label: "Extract to", url: tool.destination, placeholder: "Next to each archive") { tool.destination = $0 }
            Toggle("Put each archive in its own folder", isOn: $tool.folderPerArchive)
            Toggle("Skip archives that were already extracted", isOn: $tool.skipAlreadyExtracted)
        }
        .formStyle(.grouped)
        .frame(minHeight: 150)
        RunButton(title: "Extract \(tool.archives.count) Archive\(tool.archives.count == 1 ? "" : "s")", isRunning: tool.isRunning, disabled: tool.archives.isEmpty) { tool.run(model) }
        if let r = tool.report {
            Text("Report").font(.headline)
            ReportText(text: r.textReport)
            Button("Save Report…") { Panels.save(text: r.textReport, suggestedName: "Batch Report.txt") }
        }
    }
}

struct ChecksumToolView: View {
    @Bindable var tool: ChecksumTool
    @Environment(AppModel.self) private var model

    var body: some View {
        FileListBox(urls: $tool.files, prompt: "Drop files here or click Add.")
        HStack {
            Picker("Algorithm", selection: $tool.algorithm) {
                ForEach(HashAlgorithm.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .fixedSize()
            RunButton(title: "Calculate", isRunning: tool.isRunning, disabled: tool.files.isEmpty) { tool.calculate(model) }
        }
        if let note = tool.algorithm.note {
            Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
        if !tool.results.isEmpty {
            TextField("Paste an expected checksum to compare", text: $tool.expected)
                .textFieldStyle(.roundedBorder)
            VStack(spacing: 0) {
                ForEach(tool.results) { r in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.file.lastPathComponent).bold()
                            Text(r.digest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        Spacer()
                        if let match = tool.matches(r) {
                            Label(match ? "Matches" : "Doesn't match", systemImage: match ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(match ? .green : .red)
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(r.digest, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy checksum")
                            .accessibilityLabel("Copy checksum of \(r.file.lastPathComponent)")
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
        HStack {
            Button("Save Checksum File…") {
                do { Panels.save(text: try tool.manifestText(), suggestedName: tool.manifestFileName) } catch { model.present(ArchiveError.wrap(error), context: "Checksum file") }
            }
            .disabled(tool.files.isEmpty)
            Button("Verify a Checksum File…") {
                if let m = Panels.chooseFiles(prompt: "Verify", message: "Choose a checksum file (.sha256, .md5…).", multiple: false)?.first {
                    Task { await tool.verify(manifest: m, model: model) }
                }
            }
        }
        if let v = tool.verification {
            Label("\(v.ok.count) OK, \(v.mismatched.count) changed, \(v.missing.count) missing", systemImage: v.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(v.passed ? .green : .orange)
            ForEach(v.mismatched + v.missing, id: \.self) { Text($0).font(.caption) }
        }
    }
}

struct SplitJoinToolView: View {
    @Bindable var tool: SplitJoinTool
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox("Split a File") {
            HStack {
                TextField("Part size", text: $tool.partSize).frame(width: 110)
                Menu("Common Sizes") {
                    ForEach(FileSplitter.presets.map { $0.0 }, id: \.self) { name in Button(name) { tool.partSize = name } }
                }
                .fixedSize()
                Spacer()
                Button("Choose File and Split…") {
                    if let f = Panels.chooseFiles(prompt: "Split", multiple: false)?.first { tool.split(f, model: model) }
                }
                .disabled(!tool.isValidSize)
            }
            .padding(4)
        }
        GroupBox("Join Parts") {
            HStack {
                Text("Choose the first part (name.001). The result is checked against the checksum file when there is one.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Choose and Join…") {
                    if let f = Panels.chooseFiles(prompt: "Join", message: "Choose the first part (name.001).", multiple: false)?.first { tool.join(f, model: model) }
                }
            }
            .padding(4)
        }
        Text("Split parts are not multi-part ZIP or 7z archives: they must be joined before the file can be used. To make a multi-part archive, use “Split into parts” when compressing.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct CompareToolView: View {
    @Bindable var tool: CompareTool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading) {
                Text("Original").font(.headline)
                FileListBox(urls: Binding(get: { tool.left.map { [$0] } ?? [] }, set: { tool.left = $0.first }), prompt: "Drop an archive here.", multiple: false)
            }
            VStack(alignment: .leading) {
                Text("Changed").font(.headline)
                FileListBox(urls: Binding(get: { tool.right.map { [$0] } ?? [] }, set: { tool.right = $0.first }), prompt: "Drop an archive here.", multiple: false)
            }
        }
        Toggle("Compare file contents (slower, exact)", isOn: $tool.compareContents)
        RunButton(title: "Compare", isRunning: tool.isRunning, disabled: tool.left == nil || tool.right == nil) { tool.run(model) }
        if let r = tool.result {
            Text(r.isIdentical ? "The archives contain the same files." : "\(r.added.count) added · \(r.removed.count) removed · \(r.modified.count) changed · \(r.identical.count) identical")
                .font(.headline)
            if !r.isIdentical {
                List {
                    ForEach(r.added, id: \.self) { Label($0, systemImage: "plus.circle.fill").foregroundStyle(.green) }
                    ForEach(r.removed, id: \.self) { Label($0, systemImage: "minus.circle.fill").foregroundStyle(.red) }
                    ForEach(r.modified, id: \.path) { Label("\($0.path) — \($0.reason)", systemImage: "pencil.circle.fill").foregroundStyle(.orange) }
                }
                .frame(minHeight: 240)
            }
            HStack {
                Button("Save as Text…") { Panels.save(text: r.textReport, suggestedName: "Comparison.txt") }
                Button("Save as CSV…") { Panels.save(text: r.csvReport, suggestedName: "Comparison.csv") }
            }
        }
    }
}

struct DuplicatesToolView: View {
    @Bindable var tool: DuplicatesTool
    @Environment(AppModel.self) private var model

    var body: some View {
        FileListBox(urls: $tool.archives)
        RunButton(title: "Find Duplicates", isRunning: tool.isRunning, disabled: tool.archives.isEmpty) { tool.run(model) }
        if !tool.groups.isEmpty {
            ForEach(tool.groups, id: \.sha256) { g in
                GroupBox("\(g.members.count) copies · \(ByteFormatting.string(g.size)) each") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(g.members, id: \.self) { m in
                            Text("\(m.archive) › \(m.path)").font(.callout).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button("Save Report…") { Panels.save(text: tool.reportText, suggestedName: "Duplicates.txt") }
        }
    }
}
#endif
