#if os(macOS)
import SwiftUI
import AppKit
import ArchiveCore
import ArchiveEngines
import ArchiverKit

/// A reusable "pick files, then act" container for the tools.
struct ToolScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title, subtitle)
                content
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

struct ArchiveListPicker: View {
    @Binding var urls: [URL]
    var multiple = true
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if urls.isEmpty { Text("Drop archives here or choose them.").foregroundStyle(.secondary) }
                ForEach(urls, id: \.self) { u in
                    HStack { Image(systemName: "doc.zipper"); Text(u.lastPathComponent); Spacer()
                        Button { urls.removeAll { $0 == u } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless) }
                }
                Button("Choose…") { if let a = FilePicker.chooseArchives(multiple: multiple) { urls = multiple ? urls + a : a } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dropDestination(for: URL.self) { dropped, _ in urls = multiple ? urls + dropped : Array(dropped.prefix(1)); return true }
    }
}

// MARK: Integrity

struct IntegrityView: View {
    @Environment(AppModel.self) private var model
    @State private var urls: [URL] = []
    @State private var reports: [IntegrityReport] = []
    @State private var running = false

    var body: some View {
        ToolScaffold(title: "Integrity Verification", subtitle: "Decodes every file and checks stored checksums. A pass does not mean the content is free of malware.") {
            ArchiveListPicker(urls: $urls)
            Button("Test \(urls.count == 1 ? "Archive" : "Archives")") { run() }.disabled(urls.isEmpty || running)
            ForEach(Array(reports.enumerated()), id: \.offset) { _, r in
                GroupBox {
                    Text(r.textSummary).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !reports.isEmpty { Button("Export Report…") { ExportPanel.save(text: reports.map(\.textSummary).joined(separator: "\n\n"), name: "Integrity Report.txt") } }
        }
    }

    func run() {
        running = true
        reports = []
        let service = model.service
        let options = model.readOptions()
        let list = urls
        model.run("Test \(list.count) archive(s)", kind: .test, inputs: list) { p in
            var out: [IntegrityReport] = []
            for u in list {
                do { out.append(try service.test(u, options: options, progress: p)) } catch {
                    let e = ArchiveError.wrap(error)
                    if case .cancelled = e { throw e }
                    var r = IntegrityReport(archive: u.lastPathComponent, format: "unknown", engine: "none")
                    r.issues.append(.init(entry: nil, message: e.explanation, code: e.code))
                    out.append(r)
                }
            }
            let snapshot = out
            DispatchQueue.main.async { reports = snapshot; running = false }
            return "\(out.filter { $0.result == .passed }.count) passed, \(out.filter { $0.result == .failed }.count) failed"
        }
    }
}

// MARK: Repair

struct RepairView: View {
    @Environment(AppModel.self) private var model
    @State private var urls: [URL] = []
    @State private var analysis: DamageAnalysis?
    @State private var report: RecoveryReport?

    var body: some View {
        ToolScaffold(title: "Archive Repair", subtitle: "Analyses a damaged archive and recovers readable files into a separate folder. The damaged file is never modified.") {
            ArchiveListPicker(urls: $urls, multiple: false)
            HStack {
                Button("Analyze") { analyze() }.disabled(urls.isEmpty)
                Button("Recover Files…") { recover() }.disabled(analysis?.isDamaged != true)
            }
            if let a = analysis {
                GroupBox("Analysis") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.estimate).font(.headline)
                        ForEach(a.problems, id: \.self) { Text("• " + $0).font(.callout) }
                        if !a.missingVolumes.isEmpty { Text("Missing parts: " + a.missingVolumes.joined(separator: ", ")) }
                        if a.canRebuildStructure { Label("The ZIP directory can be rebuilt.", systemImage: "wrench.adjustable") }
                        if a.canUseRecoveryRecord { Label("RAR recovery record repair is available.", systemImage: "cross.case") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let r = report {
                GroupBox("Recovery Report") {
                    Text(r.textReport).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Show Recovered Files") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.destination)]) }
                    Button("Export Report…") { ExportPanel.save(text: r.textReport, name: "Recovery Report.txt") }
                }
            }
        }
    }

    func analyze() {
        guard let u = urls.first else { return }
        let service = model.service
        let options = model.readOptions()
        model.run("Analyze \(u.lastPathComponent)", kind: .repair, inputs: [u]) { p in
            let a = try service.analyzeDamage(u, options: options, progress: p)
            DispatchQueue.main.async { analysis = a }
            return a.estimate
        }
    }

    func recover() {
        guard let u = urls.first, let dest = FolderPicker.choose(prompt: "Recover Here", message: "Choose where to put the recovered files", directory: u.deletingLastPathComponent()) else { return }
        let service = model.service
        let options = model.readOptions()
        model.run("Recover from \(u.lastPathComponent)", kind: .repair, inputs: [u]) { p in
            let r = try service.recover(u, to: dest, options: options, progress: p)
            DispatchQueue.main.async { report = r }
            return "\(r.recovered.count) files recovered, \(r.failed.count) not recoverable"
        }
    }
}

// MARK: Checksums

struct ChecksumView: View {
    @Environment(AppModel.self) private var model
    @State private var files: [URL] = []
    @State private var algorithm: HashAlgorithm = .sha256
    @State private var results: [(String, String)] = []
    @State private var compareWith = ""
    @State private var verifyResult: ChecksumManifest.VerifyResult?

    var body: some View {
        ToolScaffold(title: "Checksum Tools", subtitle: "Calculate, compare and verify checksums.") {
            HStack {
                Button("Choose Files…") { if let u = FilePicker.chooseItems(prompt: "Choose") { files = u.filter { !$0.hasDirectoryPath } } }
                Picker("Algorithm", selection: $algorithm) {
                    ForEach(HashAlgorithm.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.fixedSize()
                Button("Calculate") { calculate() }.disabled(files.isEmpty)
            }
            if let note = algorithm.note { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            TextField("Paste an expected checksum to compare", text: $compareWith)
            ForEach(Array(results.enumerated()), id: \.offset) { _, pair in
                let (name, digest) = pair
                HStack {
                    VStack(alignment: .leading) {
                        Text(name).bold()
                        Text(digest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    Spacer()
                    if !compareWith.isEmpty {
                        let match = compareWith.trimmingCharacters(in: .whitespaces).lowercased() == digest
                        Label(match ? "Match" : "No match", systemImage: match ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(match ? .green : .red)
                    }
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(digest, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Save Manifest…") { saveManifest() }.disabled(files.isEmpty)
                Button("Verify Manifest…") { verifyManifest() }
            }
            if let v = verifyResult {
                Label("\(v.ok.count) OK, \(v.mismatched.count) mismatched, \(v.missing.count) missing", systemImage: v.passed ? "checkmark.seal" : "exclamationmark.triangle")
                ForEach(v.mismatched + v.missing, id: \.self) { Text($0).font(.caption) }
            }
        }
    }

    func calculate() {
        let list = files
        let alg = algorithm
        model.run("Checksums (\(alg.displayName))", kind: .checksum, inputs: list) { p in
            var out: [(String, String)] = []
            for f in list { out.append((f.lastPathComponent, try StreamingHasher.hashFile(at: f, algorithm: alg, progress: p))) }
            let snapshot = out
            DispatchQueue.main.async { results = snapshot }
            return "\(out.count) file(s)"
        }
    }

    func saveManifest() {
        guard let base = files.first?.deletingLastPathComponent() else { return }
        do {
            let text = try ChecksumManifest.generate(for: files, base: base, algorithm: algorithm)
            ExportPanel.save(text: text, name: "checksums.\(algorithm.manifestExtension)")
        } catch { model.present(ArchiveError.wrap(error), context: "Manifest") }
    }

    func verifyManifest() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let m = p.url else { return }
        Task {
            let r = await offMain { try ChecksumManifest.verify(manifest: m) }
            switch r {
            case .success(let v): verifyResult = v
            case .failure(let e): model.present(e, context: "Verify manifest")
            }
        }
    }
}

// MARK: Split / join

struct SplitJoinView: View {
    @Environment(AppModel.self) private var model
    @State private var size = "100 MB"
    var body: some View {
        ToolScaffold(title: "Split / Join Files", subtitle: "Splits any file into numbered parts (name.001, name.002…) with a SHA-256 manifest. This is not the same as a multi-part ZIP or 7z: the parts must be joined before use.") {
            GroupBox("Split") {
                HStack {
                    TextField("Part size", text: $size).frame(width: 120)
                    Menu("Presets") { ForEach(FileSplitter.presets.map { $0.0 }, id: \.self) { name in Button(name) { size = name } } }.fixedSize()
                    Button("Choose File and Split…") { split() }.disabled(FileSplitter.parseSize(size) == nil)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Join") {
                HStack {
                    Text("Choose the first part (name.001). The result is verified against the manifest when present.")
                    Button("Choose and Join…") { join() }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func split() {
        let p = NSOpenPanel()
        guard p.runModal() == .OK, let f = p.url, let s = FileSplitter.parseSize(size) else { return }
        model.run("Split \(f.lastPathComponent)", kind: .split, inputs: [f]) { prog in
            let r = try FileSplitter.split(f, partSize: s, progress: prog)
            return "\(r.parts.count) parts"
        }
    }

    func join() {
        let p = NSOpenPanel()
        guard p.runModal() == .OK, let f = p.url else { return }
        model.run("Join \(f.lastPathComponent)", kind: .join, inputs: [f]) { prog in
            let r = try FileSplitter.join(firstPart: f, progress: prog)
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([r.output]) }
            return r.matchedManifest == true ? "Joined and verified" : "Joined (no manifest to verify against)"
        }
    }
}

// MARK: Compare & duplicates

struct CompareView: View {
    @Environment(AppModel.self) private var model
    @State private var left: [URL] = []
    @State private var right: [URL] = []
    @State private var content = false
    @State private var result: ComparisonResult?
    var body: some View {
        ToolScaffold(title: "Compare Archives", subtitle: "Shows added, removed, modified and identical files.") {
            HStack(alignment: .top) { ArchiveListPicker(urls: $left, multiple: false); ArchiveListPicker(urls: $right, multiple: false) }
            Toggle("Compare contents (decompresses both archives; slower but exact)", isOn: $content)
            Button("Compare") { compare() }.disabled(left.isEmpty || right.isEmpty)
            if let r = result {
                Text("Identical \(r.identical.count) · Added \(r.added.count) · Removed \(r.removed.count) · Modified \(r.modified.count)").font(.headline)
                List {
                    ForEach(r.added, id: \.self) { Label($0, systemImage: "plus.circle").foregroundStyle(.green) }
                    ForEach(r.removed, id: \.self) { Label($0, systemImage: "minus.circle").foregroundStyle(.red) }
                    ForEach(r.modified, id: \.path) { Label("\($0.path) — \($0.reason)", systemImage: "pencil.circle").foregroundStyle(.orange) }
                }.frame(minHeight: 240)
                HStack {
                    Button("Export Text…") { ExportPanel.save(text: r.textReport, name: "Comparison.txt") }
                    Button("Export CSV…") { ExportPanel.save(text: r.csvReport, name: "Comparison.csv") }
                }
            }
        }
    }
    func compare() {
        guard let a = left.first, let b = right.first else { return }
        let service = model.service
        let o = model.readOptions()
        let mode: ComparisonMode = content ? .content : .metadata
        model.run("Compare archives", kind: .compare, inputs: [a, b]) { p in
            let r = try service.compare(a, b, mode: mode, leftOptions: o, rightOptions: o, progress: p)
            DispatchQueue.main.async { result = r }
            return r.isIdentical ? "Identical" : "\(r.added.count + r.removed.count + r.modified.count) differences"
        }
    }
}

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var urls: [URL] = []
    @State private var groups: [DuplicateGroup] = []
    var body: some View {
        ToolScaffold(title: "Find Duplicates", subtitle: "Finds identical files (by SHA-256) inside and across archives. Nothing is deleted.") {
            ArchiveListPicker(urls: $urls)
            Button("Find Duplicates") { find() }.disabled(urls.isEmpty)
            ForEach(groups, id: \.sha256) { g in
                GroupBox("\(g.members.count) × \(ByteFormatting.string(g.size))") {
                    VStack(alignment: .leading) { ForEach(g.members, id: \.self) { Text("\($0.archive): \($0.path)").font(.callout) } }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !groups.isEmpty {
                Button("Export Report…") {
                    let text = groups.map { g in "\(g.sha256) \(g.size) bytes\n" + g.members.map { "  \($0.archive): \($0.path)" }.joined(separator: "\n") }.joined(separator: "\n")
                    ExportPanel.save(text: text, name: "Duplicates.txt")
                }
            }
        }
    }
    func find() {
        let service = model.service
        let list = urls
        let o = model.readOptions()
        model.run("Find duplicates", kind: .compare, inputs: list) { p in
            let g = try service.findDuplicates(in: list, options: o, progress: p)
            DispatchQueue.main.async { groups = g }
            return "\(g.count) group(s) of duplicates"
        }
    }
}

// MARK: Convert & batch

struct ConvertView: View {
    @Environment(AppModel.self) private var model
    @State private var urls: [URL] = []
    @State private var presetIndex = 0
    @State private var warnings: [ConversionWarning] = []
    @State private var password = ""
    @State private var confirmation = ""
    @State private var trashOriginals = false

    var body: some View {
        ToolScaffold(title: "Convert Archives", subtitle: "Extracts securely, recompresses, then verifies every file by SHA-256 before finishing. Originals are kept unless you choose otherwise.") {
            ArchiveListPicker(urls: $urls)
            Picker("Convert to", selection: $presetIndex) {
                ForEach(Array(ConversionPresets.all.enumerated()), id: \.offset) { i, p in Text(p.name).tag(i) }
            }
            if ConversionPresets.all[presetIndex].settings.encryption != nil { NewPasswordFields(password: $password, confirmation: $confirmation) }
            Toggle("Move originals to the Trash after successful verification", isOn: $trashOriginals)
            ForEach(warnings, id: \.self) { w in Label("\(w.feature): \(w.message)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
            Button("Convert") { convert() }.disabled(urls.isEmpty || (ConversionPresets.all[presetIndex].settings.encryption != nil && (password.isEmpty || password != confirmation)))
        }
        .onChange(of: urls) { _, _ in checkWarnings() }
        .onChange(of: presetIndex) { _, _ in checkWarnings() }
    }

    func checkWarnings() {
        let service = model.service
        let list = urls
        let target = ConversionPresets.all[presetIndex].settings
        Task {
            let r = await offMain { () -> [ConversionWarning] in
                var all = Set<ConversionWarning>()
                for u in list { if let l = try? service.open(u).listing { all.formUnion(service.conversionWarnings(from: l, to: target)) } }
                return Array(all)
            }
            if case .success(let w) = r { warnings = w }
        }
    }

    func convert() {
        let service = model.service
        let options = model.readOptions()
        let settings = ConversionPresets.all[presetIndex].settings
        let pw = settings.encryption != nil ? Secret(password) : nil
        let trash = trashOriginals
        for u in urls {
            model.run("Convert \(u.lastPathComponent)", kind: .convert, inputs: [u]) { p in
                let o = try service.convert(ConvertRequest(archive: u, settings: settings, readOptions: options, newPassword: pw, trashOriginalAfterVerification: trash), progress: p)
                return "\(o.created.outputs.first?.lastPathComponent ?? "") — \(o.comparison.identical.count) files verified"
            }
        }
        urls = []
        password = ""
        confirmation = ""
    }
}

struct BatchExtractView: View {
    @Environment(AppModel.self) private var model
    @State private var destination: URL?
    @State private var perArchive = true
    @State private var skipExisting = true
    @State private var report: BatchReport?

    var body: some View {
        @Bindable var model = model
        ToolScaffold(title: "Batch Extract", subtitle: "Extract many archives in one operation. Multi-part sets are extracted once.") {
            ArchiveListPicker(urls: $model.batchArchives)
            DestinationPicker(label: "Destination", url: $destination, placeholder: "Next to each archive")
            Toggle("Put each archive in its own folder", isOn: $perArchive)
            Toggle("Skip archives that were already extracted", isOn: $skipExisting)
            Button("Extract \(model.batchArchives.count) Archive(s)") { run() }.disabled(model.batchArchives.isEmpty)
            if let r = report {
                GroupBox("Completion Report") { Text(r.textReport).font(.system(.callout, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Export Report…") { ExportPanel.save(text: r.textReport, name: "Batch Report.txt") }
            }
        }
    }

    func run() {
        let req = BatchExtractRequest(archives: model.batchArchives, sharedDestination: destination, folderPerArchive: perArchive,
                                      skipAlreadyExtracted: skipExisting, continueOnError: true, options: model.extractionOptions(), readOptions: model.readOptions())
        let service = model.service
        model.run("Batch extract \(req.archives.count) archives", kind: .extract, inputs: req.archives) { p in
            let r = try service.extractBatch(req, progress: p)
            DispatchQueue.main.async { report = r }
            return "\(r.succeeded) extracted, \(r.skipped) skipped, \(r.failed) failed"
        }
    }
}
#endif
