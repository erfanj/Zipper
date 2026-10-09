#if os(macOS)
import SwiftUI
import AppKit
import ArchiveCore
import ArchiveEngines
import ArchiverKit

/// Quick extraction form. The password field only appears when the archive needs one.
struct ExtractView: View {
    @Environment(AppModel.self) private var model
    @State private var archive: URL?
    @State private var opened: OpenedArchive?
    @State private var loadError: ArchiveError?
    @State private var loading = false
    @State private var destination: URL?
    @State private var mode: ExtractionMode = .smart
    @State private var openWhenDone = true
    @State private var verify = false
    @State private var nested = false
    @State private var trashAfter = false
    @State private var conflict: ConflictPolicy = .keepBoth
    @State private var allowMount = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader("Extract Archive")
                if let archive {
                    Form {
                        LabeledContent("Archive") {
                            HStack { Image(systemName: "doc.zipper"); Text(archive.lastPathComponent) }
                        }
                        if loading { ProgressView("Reading archive…").controlSize(.small) }
                        if let o = opened {
                            LabeledContent("Contents", value: "\(o.listing.fileCount) files, \(o.listing.directoryCount) folders")
                            LabeledContent("Uncompressed size", value: formatBytes(o.listing.totalUncompressedSize))
                            if o.listing.properties.hasEncryptedEntries == true {
                                Label("Encrypted — you'll be asked for the password.", systemImage: "lock").foregroundStyle(.secondary)
                            }
                            if let mp = o.detection.multipart { LabeledContent("Volumes", value: "\(mp.volumes.count)") }
                            if let free = freeSpace(), let need = o.listing.totalUncompressedSize, need > free {
                                Label("Not enough free space: needs \(ByteFormatting.string(need)), \(ByteFormatting.string(free)) available.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                            let execs = o.listing.entries.filter { ExecutableContent.isPotentiallyExecutable(path: $0.normalizedPath, permissions: $0.permissions, header: []) }
                            if !execs.isEmpty {
                                Label("Contains \(execs.count) app(s), script(s) or program(s). They will not be opened automatically.", systemImage: "app.badge")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if let e = loadError { ErrorBanner(error: e) }
                        if let d = (try? FormatDetector.detect(archive))?.descriptor, d.id == .dmg {
                            Toggle("Allow mounting this disk image read-only if needed", isOn: $allowMount)
                        }
                        DestinationPicker(label: "Destination", url: $destination, placeholder: archive.deletingLastPathComponent().lastPathComponent)
                        Picker("Folder structure", selection: $mode) {
                            ForEach(ExtractionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .help("Smart Extract avoids a redundant folder when the archive already has a single top-level folder.")
                        Picker("If a file exists", selection: $conflict) {
                            ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        Toggle("Open destination when complete", isOn: $openWhenDone)
                        Toggle("Verify extracted files", isOn: $verify)
                        if model.settings.uiLevel != .simple {
                            Toggle("Also extract archives inside this archive", isOn: $nested)
                            Toggle("Move the archive to the Trash after a verified extraction", isOn: $trashAfter)
                                .disabled(!verify)
                        }
                        HStack {
                            Button("Browse Contents") { model.openArchive(archive) }
                            Spacer()
                            Button("Cancel") { self.archive = nil; model.selection = .home }.keyboardShortcut(.cancelAction)
                            Button("Extract") { extract() }.keyboardShortcut(.defaultAction).disabled(loadError != nil && opened == nil && !isPasswordError)
                        }
                    }
                    .formStyle(.grouped)
                } else {
                    DropZone(targeted: .constant(false))
                        .onTapGesture { if let u = FilePicker.chooseArchive() { setArchive(u) } }
                        .dropDestination(for: URL.self) { urls, _ in if let u = urls.first { setArchive(u) }; return true }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear {
            mode = model.settings.extractionMode
            conflict = model.settings.conflictPolicy
            verify = model.settings.verifyAfterExtraction
            nested = model.settings.extractNestedArchives
            openWhenDone = model.settings.openDestinationAfterExtraction
            destination = model.settings.defaultExtractionDestination.map { URL(fileURLWithPath: $0) }
            if let p = model.pendingExtraction { setArchive(p); model.pendingExtraction = nil }
        }
        .onChange(of: model.pendingExtraction) { _, p in if let p { setArchive(p); model.pendingExtraction = nil } }
    }

    var isPasswordError: Bool {
        if case .passwordRequired? = loadError { return true }
        return false
    }

    func freeSpace() -> UInt64? {
        let dir = destination ?? archive?.deletingLastPathComponent()
        guard let dir, let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else { return nil }
        return UInt64(v)
    }

    func setArchive(_ u: URL) {
        archive = u
        opened = nil
        loadError = nil
        loading = true
        let service = model.service
        // Listing without a password: archives with encrypted names report password-required here
        // and the user is asked once, when extraction starts.
        Task {
            let r = await offMain { try service.open(u, options: ReadOptions()) }
            loading = false
            switch r {
            case .success(let o): opened = o
            case .failure(let e): loadError = e
            }
        }
    }

    func extract() {
        guard let archive else { return }
        var options = model.extractionOptions()
        options.conflictPolicy = conflict
        if conflict == .ask { options.conflictResolver = model.extractionOptions().conflictResolver ?? { _ in (.keepBoth, false) } }
        let request = ExtractRequest(archive: archive, destination: destination, mode: mode, options: options,
                                     readOptions: model.readOptions(allowMount: allowMount), extractNestedArchives: nested,
                                     verifyAfterExtraction: verify, trashArchiveAfterVerification: trashAfter && verify)
        let service = model.service
        let open = openWhenDone
        model.run("Extract \(archive.lastPathComponent)", kind: .extract, inputs: [archive]) { progress in
            let o = try service.extract(request, progress: progress)
            if open { DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(o.createdItems) } }
            var summary = "\(o.report.filesWritten) files → \(o.createdItems.map(\.lastPathComponent).joined(separator: ", "))"
            if !o.report.blocked.isEmpty { summary += " · \(o.report.blocked.count) unsafe entries blocked" }
            if let v = o.verification { summary += v.passed ? " · verified" : " · verification found problems" }
            return summary
        }
        self.archive = nil
        opened = nil
    }
}

// MARK: Browser state

/// State for one open archive window/tab.
@MainActor
@Observable
final class BrowserState {
    let url: URL
    var opened: OpenedArchive?
    var error: ArchiveError?
    var loading = false
    var currentFolder = ""
    var searchText = ""
    var search = EntrySearch()
    var selection = Set<Int>()
    var viewMode: ViewMode = .list
    var sortOrder = [KeyPathComparator(\BrowserRow.name)]
    var integrity: IntegrityReport?
    var previewURL: URL?
    var showPreview = true
    var editSessions: [String: ExternalEditSession] = [:]

    enum ViewMode: String, CaseIterable { case list, columns, icons, gallery }

    init(url: URL) { self.url = url }

    var selectedEntry: ArchiveEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return opened?.listing.entries.first { $0.index == id }
    }

    func load(model: AppModel) {
        loading = true
        error = nil
        let service = model.service
        let options = model.readOptions()
        let u = url
        Task {
            let r = await offMain { try service.open(u, options: options) }
            loading = false
            switch r {
            case .success(let o): opened = o
            case .failure(let e): error = e
            }
        }
    }

    /// Rows for the current folder (or search results across the archive).
    func rows() -> [BrowserRow] {
        guard let l = opened?.listing else { return [] }
        if !searchText.isEmpty || search.kind != nil || search.encryptedOnly {
            var s = search
            s.text = searchText
            return l.entries.filter { $0.type != .directory && s.matches($0) }.map { BrowserRow(entry: $0, displayName: $0.normalizedPath) }.sorted(using: sortOrder)
        }
        return children(of: currentFolder, in: l).sorted(using: sortOrder)
    }

    func children(of folder: String, in l: ArchiveListing) -> [BrowserRow] {
        var rows: [BrowserRow] = []
        var seenDirs = Set<String>()
        for e in l.entries {
            let p = e.normalizedPath
            guard !p.isEmpty else { continue }
            let rel: Substring
            if folder.isEmpty { rel = Substring(p) } else {
                guard p.hasPrefix(folder + "/") else { continue }
                rel = p.dropFirst(folder.count + 1)
            }
            if let slash = rel.firstIndex(of: "/") {
                let dir = String(rel[..<slash])
                if seenDirs.insert(dir).inserted {
                    rows.append(BrowserRow(syntheticDirectory: ArchivePath.join(folder, dir), name: dir))
                }
            } else if e.type == .directory {
                if seenDirs.insert(String(rel)).inserted { rows.append(BrowserRow(entry: e, displayName: String(rel))) }
            } else {
                rows.append(BrowserRow(entry: e, displayName: String(rel)))
            }
        }
        // Folders first, like Finder.
        return rows
    }
}

struct BrowserRow: Identifiable, Hashable {
    var id: Int
    var name: String
    var path: String
    var isFolder: Bool
    var size: UInt64
    var packed: UInt64
    var ratio: Double
    var kind: String
    var modified: Date
    var encrypted: Bool
    var method: String
    var entry: ArchiveEntry?

    init(entry e: ArchiveEntry, displayName: String) {
        id = e.index
        name = displayName
        path = e.normalizedPath
        isFolder = e.type == .directory
        size = e.uncompressedSize ?? 0
        packed = e.compressedSize ?? 0
        ratio = e.compressionRatio ?? -1
        kind = e.type == .directory ? "Folder" : (e.type == .symlink ? "Alias" : FileClassifier.kind(forExtension: e.fileExtension).rawValue.capitalized)
        modified = e.modificationDate ?? .distantPast
        encrypted = e.isEncrypted
        method = e.method ?? ""
        entry = e
    }

    init(syntheticDirectory path: String, name: String) {
        id = -abs(path.hashValue % 1_000_000_000) - 1
        self.name = name
        self.path = path
        isFolder = true
        size = 0
        packed = 0
        ratio = -1
        kind = "Folder"
        modified = .distantPast
        encrypted = false
        method = ""
        entry = nil
    }
}
#endif
