#if os(macOS)
import SwiftUI
import AppKit
import Quartz
import Charts
import UniformTypeIdentifiers
import ArchiveCore
import ArchiveEngines
import ArchiverKit

/// Browse an archive like a folder: list / column / icon / gallery views, search, preview, drag out
/// to extract, drop in to add, and transactional editing.
struct ArchiveBrowserView: View {
    @Bindable var state: BrowserState
    @Environment(AppModel.self) private var model
    @State private var renaming: BrowserRow?
    @State private var newName = ""
    @State private var showAnalysis = false
    @State private var confirmDelete = false
    @State private var newFolderName = ""
    @State private var showNewFolder = false

    var body: some View {
        VStack(spacing: 0) {
            if let e = state.error {
                VStack(spacing: 12) {
                    ErrorBanner(error: e)
                    Button("Try Again") { state.load(model: model) }
                }
                .padding()
                .frame(maxWidth: 600)
                Spacer()
            } else if state.opened == nil {
                ProgressView("Reading \(state.url.lastPathComponent)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                breadcrumb
                Divider()
                HSplitView {
                    content.frame(minWidth: 380)
                    if state.showPreview {
                        PreviewPane(state: state).frame(minWidth: 240, idealWidth: 320)
                    }
                }
                Divider()
                statusBar
            }
        }
        .searchable(text: $state.searchText, placement: .toolbar, prompt: "Search in archive")
        .toolbar { browserToolbar }
        .navigationTitle(state.url.lastPathComponent)
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true }
        .sheet(item: $renaming) { row in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename “\(row.name)”").font(.headline)
                TextField("New name", text: $newName).onSubmit { rename(row) }
                HStack { Spacer(); Button("Cancel") { renaming = nil }; Button("Rename") { rename(row) }.keyboardShortcut(.defaultAction) }
            }.padding().frame(width: 360)
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { edit([.createFolder(path: ArchivePath.join(state.currentFolder, newFolderName))], title: "New folder") }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(state.selection.count) item(s) from the archive?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelection() }
        } message: { Text("The archive is rebuilt and verified before the original is replaced.") }
        .sheet(isPresented: $showAnalysis) { if let l = state.opened?.listing { AnalysisView(listing: l) } }
    }

    // MARK: Pieces

    var breadcrumb: some View {
        HStack(spacing: 4) {
            Button { state.currentFolder = "" } label: { Image(systemName: "doc.zipper"); Text(state.url.lastPathComponent) }.buttonStyle(.borderless)
            let parts = state.currentFolder.split(separator: "/").map(String.init)
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                Button(p) { state.currentFolder = parts[0...i].joined(separator: "/") }.buttonStyle(.borderless)
            }
            Spacer()
            Picker("View", selection: $state.viewMode) {
                Image(systemName: "list.bullet").tag(BrowserState.ViewMode.list).accessibilityLabel("List")
                Image(systemName: "rectangle.split.3x1").tag(BrowserState.ViewMode.columns).accessibilityLabel("Columns")
                Image(systemName: "square.grid.2x2").tag(BrowserState.ViewMode.icons).accessibilityLabel("Icons")
                Image(systemName: "photo.on.rectangle").tag(BrowserState.ViewMode.gallery).accessibilityLabel("Gallery")
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder var content: some View {
        let rows = state.rows()
        switch state.viewMode {
        case .list:
            Table(rows, selection: $state.selection, sortOrder: $state.sortOrder) {
                TableColumn("Name", value: \.name) { r in
                    Label { Text(r.name) } icon: { Image(nsImage: icon(for: r)).resizable().frame(width: 16, height: 16) }
                        .draggable(DraggedEntry(archive: state.url, path: r.path, isFolder: r.isFolder)) {
                            Label(r.name, systemImage: r.isFolder ? "folder" : "doc")
                        }
                }
                TableColumn("Size", value: \.size) { r in Text(r.isFolder ? "—" : ByteFormatting.string(r.size)).monospacedDigit() }.width(80)
                TableColumn("Packed", value: \.packed) { r in Text(r.isFolder || r.packed == 0 ? "—" : ByteFormatting.string(r.packed)).monospacedDigit() }.width(80)
                TableColumn("Ratio", value: \.ratio) { r in Text(r.ratio < 0 ? "—" : String(format: "%.0f%%", r.ratio * 100)).monospacedDigit() }.width(54)
                TableColumn("Kind", value: \.kind).width(80)
                TableColumn("Modified", value: \.modified) { r in Text(r.modified == .distantPast ? "—" : r.modified.formatted(date: .abbreviated, time: .shortened)) }.width(140)
                TableColumn("🔒", value: \.method) { r in if r.encrypted { Image(systemName: "lock.fill").accessibilityLabel("Encrypted") } }.width(26)
            }
            .contextMenu(forSelectionType: Int.self) { ids in contextMenu(ids) } primaryAction: { ids in open(ids) }
        case .columns:
            ColumnBrowser(state: state, iconFor: icon(for:))
        case .icons, .gallery:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: state.viewMode == .gallery ? 160 : 96))], spacing: 14) {
                    ForEach(rows) { r in
                        VStack(spacing: 4) {
                            if state.viewMode == .gallery, !r.isFolder, FileClassifier.kind(forExtension: (r.name as NSString).pathExtension) == .image {
                                ThumbnailView(archive: state.url, path: r.path)
                                    .frame(width: 150, height: 110)
                            } else {
                                Image(nsImage: icon(for: r)).resizable().frame(width: 56, height: 56)
                            }
                            Text(r.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .padding(6)
                        .background(state.selection.contains(r.id) ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { state.selection = [r.id] }
                        .onTapGesture(count: 2) { open([r.id]) }
                        .draggable(DraggedEntry(archive: state.url, path: r.path, isFolder: r.isFolder))
                        .contextMenu { contextMenu([r.id]) }
                    }
                }
                .padding()
            }
        }
    }

    var statusBar: some View {
        HStack {
            if let l = state.opened?.listing {
                Text("\(l.fileCount) files, \(l.directoryCount) folders · \(formatBytes(l.totalUncompressedSize))")
                if l.properties.hasEncryptedEntries == true { Label("Encrypted", systemImage: "lock").labelStyle(.titleAndIcon) }
                if let r = state.integrity { Label(r.result == .passed ? "Verified" : "Problems found", systemImage: r.result == .passed ? "checkmark.shield" : "exclamationmark.shield") }
            }
            Spacer()
            if !state.selection.isEmpty { Text("\(state.selection.count) selected") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ToolbarContentBuilder var browserToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { extract(selectedPaths(), ask: false) } label: { Label("Extract", systemImage: "tray.and.arrow.up") }
                .help(state.selection.isEmpty ? "Extract all" : "Extract selected items")
            Button { extract(selectedPaths(), ask: true) } label: { Label("Extract To…", systemImage: "folder.badge.plus") }
            Button { test() } label: { Label("Test", systemImage: "checkmark.shield") }
            if model.settings.uiLevel != .simple {
                Menu {
                    Button("Add Files…") { if let u = FilePicker.chooseItems(prompt: "Add") { add(u) } }
                    Button("New Folder…") { newFolderName = ""; showNewFolder = true }
                    Button("Rename…") { if let r = state.rows().first(where: { state.selection.contains($0.id) }) { newName = r.name; renaming = r } }
                        .disabled(state.selection.count != 1)
                    Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(state.selection.isEmpty)
                } label: { Label("Edit", systemImage: "pencil") }
                Button { showAnalysis = true } label: { Label("Analyze", systemImage: "chart.pie") }
            }
            Button { state.showPreview.toggle() } label: { Label("Preview", systemImage: "eye") }
        }
    }

    @ViewBuilder func contextMenu(_ ids: Set<Int>) -> some View {
        Button("Extract…") { state.selection = ids; extract(selectedPaths(), ask: true) }
        Button("Open") { open(ids) }
        if model.settings.uiLevel != .simple {
            Button("Edit in Default App") { state.selection = ids; editExternally() }.disabled(ids.count != 1)
            Button("Rename…") {
                if let r = state.rows().first(where: { ids.contains($0.id) }) { newName = r.name; renaming = r }
            }.disabled(ids.count != 1)
            Button("Delete…", role: .destructive) { state.selection = ids; confirmDelete = true }
        }
        Button("Copy Path") {
            let paths = state.rows().filter { ids.contains($0.id) }.map(\.path)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        }
    }

    // MARK: Actions

    func icon(for r: BrowserRow) -> NSImage {
        if r.isFolder { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (r.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    func selectedPaths() -> [String] {
        let rows = state.rows()
        return rows.filter { state.selection.contains($0.id) }.map(\.path)
    }

    func open(_ ids: Set<Int>) {
        guard let r = state.rows().first(where: { ids.contains($0.id) }) else { return }
        if r.isFolder { state.currentFolder = r.path; state.selection = []; return }
        // Nested archives open in a new browser tab after extracting them to the preview cache.
        let service = model.service
        let options = model.readOptions()
        let archive = state.url
        Task {
            let res = await offMain { try service.extractForPreview(archive, entryPath: r.path, options: options) }
            switch res {
            case .success(let file):
                if model.isArchive(file) { model.openArchive(file) } else {
                    // Opening a file from an archive never runs it: apps and scripts are revealed instead.
                    if ExecutableContent.isPotentiallyExecutable(path: file.path, permissions: nil, header: []) {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    } else {
                        NSWorkspace.shared.open(file)
                    }
                }
            case .failure(let e): model.present(e, context: "Open \(r.name)")
            }
        }
    }

    func extract(_ paths: [String], ask: Bool) {
        var dest: URL? = model.settings.defaultExtractionDestination.map { URL(fileURLWithPath: $0) }
        if ask {
            guard let d = FolderPicker.choose(prompt: "Extract", directory: state.url.deletingLastPathComponent()) else { return }
            dest = d
        }
        let request = ExtractRequest(archive: state.url, destination: dest, mode: paths.isEmpty ? model.settings.extractionMode : .here,
                                     selection: paths.isEmpty ? .all : .paths(Set(paths)), options: model.extractionOptions(),
                                     readOptions: model.readOptions(), verifyAfterExtraction: model.settings.verifyAfterExtraction)
        let service = model.service
        let reveal = model.settings.openDestinationAfterExtraction
        model.run("Extract from \(state.url.lastPathComponent)", kind: .extract, inputs: [state.url]) { p in
            let o = try service.extract(request, progress: p)
            if reveal { DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(o.createdItems) } }
            return "\(o.report.filesWritten) files extracted"
        }
    }

    func test() {
        let service = model.service
        let url = state.url
        let options = model.readOptions()
        let s = state
        model.run("Test \(url.lastPathComponent)", kind: .test, inputs: [url]) { p in
            let r = try service.test(url, options: options, progress: p)
            DispatchQueue.main.async { s.integrity = r }
            return "\(r.result.rawValue): \(r.filesVerified) of \(r.filesInspected) files verified"
        }
    }

    func edit(_ edits: [ArchiveEdit], title: String) {
        let service = model.service
        let req = ModifyRequest(archive: state.url, edits: edits, readOptions: model.readOptions())
        let s = state
        let m = model
        model.run("\(title) in \(state.url.lastPathComponent)", kind: .modify, inputs: [state.url]) { p in
            let o = try service.modify(req, progress: p)
            DispatchQueue.main.async { s.load(model: m) }
            return "Archive updated and verified (\(o.entryCount) entries)"
        }
    }

    func add(_ urls: [URL]) { edit([.add(files: urls, toFolder: state.currentFolder)], title: "Add files") }
    func deleteSelection() { edit([.delete(paths: selectedPaths())], title: "Delete") }
    func rename(_ row: BrowserRow) {
        renaming = nil
        guard !newName.isEmpty, newName != row.name else { return }
        edit([.rename(path: row.path, newName: newName)], title: "Rename")
    }

    func editExternally() {
        guard let path = selectedPaths().first else { return }
        let service = model.service
        let archive = state.url
        let options = model.readOptions()
        let s = state
        Task {
            let r = await offMain { try ExternalEditSession(service: service, archive: archive, entryPath: path, readOptions: options) }
            switch r {
            case .success(let session):
                s.editSessions[path] = session
                NSWorkspace.shared.open(session.fileURL)
                EditWatcher.watch(session: session, model: model, state: s)
            case .failure(let e): model.present(e, context: "Edit \(path)")
            }
        }
    }
}

/// Watches an externally edited file and offers to update the archive when it changes.
@MainActor
enum EditWatcher {
    static func watch(session: ExternalEditSession, model: AppModel, state: BrowserState) {
        Task {
            while state.editSessions[session.entryPath] != nil {
                try? await Task.sleep(for: .seconds(2))
                guard session.hasChanges() else { continue }
                let alert = NSAlert()
                alert.messageText = "“\((session.entryPath as NSString).lastPathComponent)” was modified."
                alert.informativeText = "Update it in “\(session.archive.lastPathComponent)”? The archive is rebuilt and verified before the original is replaced."
                alert.addButton(withTitle: "Update Archive")
                alert.addButton(withTitle: "Not Now")
                alert.addButton(withTitle: "Stop Watching")
                let r = alert.runModal()
                if r == .alertFirstButtonReturn {
                    let service = model.service
                    let options = model.readOptions()
                    model.run("Update \(session.archive.lastPathComponent)", kind: .modify, inputs: [session.archive]) { _ in
                        let o = try session.commit(using: service, readOptions: options)
                        DispatchQueue.main.async { state.load(model: model) }
                        return "Updated (\(o.verification.result.rawValue))"
                    }
                    try? await Task.sleep(for: .seconds(3))
                } else if r == .alertThirdButtonReturn {
                    session.discard()
                    state.editSessions[session.entryPath] = nil
                }
            }
        }
    }
}

/// Dragging an entry out of the browser extracts it (to a private temporary folder) and hands
/// Finder a real file.
struct DraggedEntry: Transferable {
    let archive: URL
    let path: String
    let isFolder: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { entry in
            let dir = PreviewCache.shared.directory.appendingPathComponent("drag-\(UUID().uuidString)")
            let service = ArchiveService()
            let o = try service.extract(ExtractRequest(archive: entry.archive, destination: dir, mode: .here,
                                                       selection: .paths([entry.path]), options: ExtractionOptions()))
            let name = (entry.path as NSString).lastPathComponent
            let url = o.createdItems.count == 1 && !entry.path.contains("/") ? o.createdItems[0] : dir.appendingPathComponent(entry.path)
            return SentTransferredFile(FileManager.default.fileExists(atPath: url.path) ? url : dir.appendingPathComponent(name))
        }
    }
}

/// Finder-style column browser.
struct ColumnBrowser: View {
    @Bindable var state: BrowserState
    let iconFor: (BrowserRow) -> NSImage

    var body: some View {
        let parts = state.currentFolder.split(separator: "/").map(String.init)
        let folders = [""] + parts.indices.map { parts[0...$0].joined(separator: "/") }
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(folders, id: \.self) { folder in
                    List(state.opened.map { state.children(of: folder, in: $0.listing) } ?? [], selection: Binding(get: { Set<Int>() }, set: { ids in
                        guard let id = ids.first, let row = state.opened.map({ state.children(of: folder, in: $0.listing) })?.first(where: { $0.id == id }) else { return }
                        if row.isFolder { state.currentFolder = row.path } else { state.currentFolder = folder; state.selection = [row.id] }
                    })) { r in
                        HStack {
                            Image(nsImage: iconFor(r)).resizable().frame(width: 16, height: 16)
                            Text(r.name)
                            Spacer()
                            if r.isFolder { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                        }
                        .tag(r.id)
                    }
                    .frame(width: 220)
                    Divider()
                }
            }
        }
    }
}

/// Preview of the selected entry: Quick Look for documents/media, syntax-friendly text view for code.
struct PreviewPane: View {
    @Bindable var state: BrowserState
    @Environment(AppModel.self) private var model
    @State private var file: URL?
    @State private var text: String?
    @State private var error: ArchiveError?
    @State private var loading = false

    var body: some View {
        VStack {
            if let e = state.selectedEntry, e.type == .file {
                if loading { ProgressView() }
                else if let text { CodeTextView(text: text) }
                else if let file { QuickLookView(url: file) }
                else if let error { ErrorBanner(error: error).padding() }
                if (e.uncompressedSize ?? 0) > 512_000_000 {
                    Text("Large file: preview disabled.").foregroundStyle(.secondary)
                }
                if state.opened?.listing.properties.isSolid == true {
                    Text("Solid archive: previewing decompresses the data stored before this file.").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Select a file to preview it.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: state.selectedEntry?.index) { await load() }
    }

    func load() async {
        file = nil; text = nil; error = nil
        guard let e = state.selectedEntry, e.type == .file, (e.uncompressedSize ?? 0) <= 512_000_000 else { return }
        loading = true
        let service = model.service
        let options = model.readOptions()
        let url = state.url
        let r = await offMain { try service.extractForPreview(url, entryPath: e.path, options: options) }
        loading = false
        switch r {
        case .success(let f):
            let kind = FileClassifier.kind(forExtension: f.pathExtension)
            if kind == .sourceCode || (kind == .text && !["html", "htm", "svg", "rtf"].contains(f.pathExtension.lowercased())),
               let d = try? Data(contentsOf: f, options: .alwaysMapped), d.count < 4_000_000 {
                text = String(decoding: d, as: UTF8.self)
            } else {
                file = f
            }
        case .failure(let err): error = err
        }
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) { v.previewItem = url as NSURL }
}

/// Monospaced text with line numbers and find (via the standard find bar).
struct CodeTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.string = numbered(text)
        return scroll
    }
    func updateNSView(_ v: NSScrollView, context: Context) {
        (v.documentView as? NSTextView)?.string = numbered(text)
    }
    func numbered(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let width = String(lines.count).count
        return lines.prefix(50_000).enumerated().map { i, l in
            let n = String(i + 1)
            return String(repeating: " ", count: width - n.count) + n + "  " + l
        }.joined(separator: "\n")
    }
}

struct ThumbnailView: View {
    let archive: URL
    let path: String
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() } else { ProgressView().controlSize(.small) }
        }
        .task {
            let r = await offMain { try ArchiveService().extractForPreview(archive, entryPath: path, maxBytes: 50_000_000) }
            if case .success(let f) = r { image = NSImage(contentsOf: f) }
        }
    }
}

struct KindBar: Identifiable {
    let name: String
    let bytes: Double
    var id: String { name }
}

/// Visual analysis: largest files, type distribution, compression effectiveness.
struct AnalysisView: View {
    let listing: ArchiveListing
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let a = ArchiveAnalysis(listing: listing)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { SectionHeader("Archive Analysis"); Button("Done") { dismiss() } }
                if let r = a.overallRatio { Text(String(format: "Compressed to %.1f%% of the original size.", r * 100)) }
                Text("Space by file type").font(.headline)
                let bars = a.bytesByKind.map { KindBar(name: $0.kind.rawValue.capitalized, bytes: Double($0.bytes)) }
                Chart(bars) { k in
                    BarMark(x: .value("Bytes", k.bytes), y: .value("Type", k.name))
                }
                .accessibilityLabel("Space used by each file type")
                .frame(height: CGFloat(max(1, a.bytesByKind.count)) * 28 + 20)
                Text("Largest files").font(.headline)
                ForEach(a.largestFiles.prefix(10)) { f in
                    HStack { Text(f.normalizedPath).lineLimit(1).truncationMode(.middle); Spacer(); Text(formatBytes(f.uncompressedSize)).monospacedDigit() }
                }
                Text("Top-level folders").font(.headline)
                ForEach(Array(a.directorySizes.prefix(10).enumerated()), id: \.offset) { _, d in
                    HStack { Text(d.path); Spacer(); Text(ByteFormatting.string(d.bytes)).monospacedDigit() }
                }
                if !a.poorlyCompressed.isEmpty {
                    Text("Compressed poorly (\(a.poorlyCompressed.count))").font(.headline)
                    Text("These are usually already-compressed media or archives.").font(.caption).foregroundStyle(.secondary)
                    ForEach(a.poorlyCompressed.prefix(10)) { f in Text(f.normalizedPath).font(.callout) }
                }
            }
            .padding(24)
        }
        .frame(width: 620, height: 640)
    }
}
#endif
