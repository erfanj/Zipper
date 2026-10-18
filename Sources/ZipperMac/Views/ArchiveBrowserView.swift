#if os(macOS)
import SwiftUI
import AppKit
import Charts
import QuickLook  // with SwiftUI, provides .quickLookPreview
import UniformTypeIdentifiers
import ArchiveCore
import ArchiveEngines
import ArchiverKit

/// Browse an archive like a Finder folder. Space previews with Quick Look, double-click opens,
/// dragging items out extracts them, and dropping files in adds them (after confirmation).
struct ArchiveBrowserView: View {
    @Bindable var state: BrowserState
    @Environment(AppModel.self) private var model

    @State private var quickLookURL: URL?
    @State private var renameTarget: BrowserRow?
    @State private var newName = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var confirmDelete = false
    @State private var pendingAdd: [URL] = []
    @State private var changedSession: EditPrompt?
    @State private var showAnalysis = false

    struct EditPrompt: Identifiable {
        let id = UUID()
        let session: ExternalEditSession
    }

    // The modifiers are split into two stages (window chrome, then dialogs) with named bindings:
    // one long chain of closure-heavy modifiers is more than the type checker handles in time.
    var body: some View {
        dialogs(on: chrome(on: content))
    }

    private func chrome<V: View>(on view: V) -> some View {
        @Bindable var model = model
        return view
            .navigationTitle(state.displayName)
            .navigationSubtitle(subtitle)
            .searchable(text: $state.searchText, placement: .toolbar, prompt: "Search in archive")
            .toolbar { toolbar }
            .inspector(isPresented: $model.showInspector) { inspector }
            .quickLookPreview($quickLookURL)
            .dropDestination(for: URL.self, action: acceptDrop)
            .sheet(isPresented: $showAnalysis) { analysis }
            .onChange(of: state.pendingCommand) { _, command in run(command) }
    }

    private func dialogs<V: View>(on view: V) -> some View {
        view
            .confirmationDialog(addTitle, isPresented: addPresented) {
                Button("Add") { confirmAdd() }
                Button("Cancel", role: .cancel) { pendingAdd = [] }
            } message: {
                Text("The archive is rebuilt and checked before the original is replaced.")
            }
            .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { model.deleteSelection(in: state) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The archive is rebuilt without them and checked before the original is replaced. This can't be undone.")
            }
            .alert("Rename", isPresented: renamePresented) {
                TextField("Name", text: $newName)
                Button("Rename") { confirmRename() }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: {
                Text("Enter a new name for “\(renameTarget?.name ?? "")”.")
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Name", text: $newFolderName)
                Button("Create") { model.createFolder(named: newFolderName, in: state) }
                Button("Cancel", role: .cancel) {}
            }
            .alert(item: $changedSession, content: updatePrompt)
    }

    private var inspector: some View {
        ArchiveInspector(state: state)
            .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
    }

    @ViewBuilder private var analysis: some View {
        if let listing = state.opened?.listing { AnalysisView(listing: listing) }
    }

    private var addPresented: Binding<Bool> {
        Binding(get: { !pendingAdd.isEmpty }, set: { if !$0 { pendingAdd = [] } })
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private func acceptDrop(_ urls: [URL], _ location: CGPoint) -> Bool {
        guard state.isEditable, !urls.isEmpty else { return false }
        pendingAdd = urls
        return true
    }

    private func confirmAdd() {
        model.add(pendingAdd, to: state)
        pendingAdd = []
    }

    private func confirmRename() {
        if let r = renameTarget { model.rename(r, to: newName, in: state) }
        renameTarget = nil
    }

    private func run(_ command: BrowserCommand?) {
        guard let command else { return }
        state.pendingCommand = nil
        perform(command)
    }

    private func updatePrompt(_ prompt: EditPrompt) -> Alert {
        let name = (prompt.session.entryPath as NSString).lastPathComponent
        return Alert(title: Text("Update “\(name)” in the archive?"),
                     message: Text("You changed “\(name)”. The archive is rebuilt and checked before the original is replaced."),
                     primaryButton: .default(Text("Update Archive")) { model.commit(prompt.session, in: state) },
                     secondaryButton: .cancel(Text("Not Now")))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let error = state.error {
            VStack(spacing: 16) {
                ErrorBanner(error: error).frame(maxWidth: 560)
                Button("Try Again") { state.load(using: model) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.opened == nil {
            ProgressView("Reading “\(state.displayName)”…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                PathBar(state: state)
                Divider()
                Group {
                    switch state.viewMode {
                    case .list: listView
                    case .columns: ColumnBrowser(state: state, onOpen: { model.open($0, in: state) })
                    case .icons: IconGrid(state: state, onOpen: { model.open($0, in: state) }, menu: { contextMenu(for: $0) })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar(state: state)
            }
        }
    }

    private var listView: some View {
        let rows = state.rows
        return Table(of: BrowserRow.self, selection: $state.selection, sortOrder: $state.sortOrder) {
            TableColumn("Name", value: \.sortName) { r in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.icon(for: r)).resizable().frame(width: 16, height: 16)
                    Text(r.name).lineLimit(1).truncationMode(.middle)
                    if r.encrypted {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Encrypted")
                            .accessibilityLabel("Encrypted")
                    }
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Size", value: \.size) { r in
                Text(r.isFolder ? "--" : ByteFormatting.string(r.size)).monospacedDigit().foregroundStyle(r.isFolder ? .secondary : .primary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Compressed", value: \.packed) { r in
                Text(r.isFolder || r.packed == 0 ? "--" : ByteFormatting.string(r.packed)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Kind", value: \.kind) { r in Text(r.kind).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 120)
            TableColumn("Date Modified", value: \.modified) { r in
                Text(r.modified == .distantPast ? "--" : r.modified.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 150)
        } rows: {
            ForEach(rows) { r in
                TableRow(r).draggable(DraggedEntry(archive: state.url, path: r.path, isFolder: r.isFolder,
                                                   service: model.service, readOptions: model.readOptions()))
            }
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            let selected = ids.compactMap { state.row(id: $0) }
            contextMenu(for: selected)
        } primaryAction: { ids in
            if let first = ids.compactMap({ state.row(id: $0) }).first { model.open(first, in: state) }
        }
        .onKeyPress(.space) {
            quickLook()
            return .handled
        }
        .onKeyPress(.return) {
            guard let r = state.selectedRows.first else { return .ignored }
            model.open(r, in: state)
            return .handled
        }
    }

    @ViewBuilder private func contextMenu(for rows: [BrowserRow]) -> some View {
        let single = rows.count == 1 ? rows.first : nil
        if let r = single {
            Button("Open") { model.open(r, in: state) }
            if !r.isFolder { Button("Quick Look") { state.selection = [r.id]; quickLook() } }
        }
        Button(rows.isEmpty ? "Extract All To…" : "Extract To…") { extractTo(rows) }
        if state.isEditable {
            if let r = single, !r.isFolder {
                Button("Edit in Default App") { editExternally(r) }
            }
            Divider()
            if let r = single { Button("Rename…") { beginRename(r) } }
            if !rows.isEmpty {
                Button("Delete…", role: .destructive) { state.selection = Set(rows.map(\.id)); confirmDelete = true }
            }
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rows.map(\.path).joined(separator: "\n"), forType: .string)
        }
        .disabled(rows.isEmpty)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.extract(from: state, to: nil) } label: {
                Label(state.selection.isEmpty ? "Extract All" : "Extract", systemImage: "tray.and.arrow.up")
            }
            .help(state.selection.isEmpty ? "Extract everything next to the archive (⌘E)" : "Extract the selected items (⌘E)")
            .disabled(state.opened == nil)

            Button { extractTo(state.selectedRows) } label: { Label("Extract To…", systemImage: "folder.badge.plus") }
                .help("Choose where to extract (⌥⌘E)")
                .disabled(state.opened == nil)

            Button { addFiles() } label: { Label("Add", systemImage: "plus") }
                .help(state.isEditable ? "Add files to the archive (⌥⌘A)" : "This archive can't be changed")
                .disabled(!state.isEditable || state.opened == nil)

            Picker("View", selection: $state.viewMode) {
                Label("List", systemImage: "list.bullet").tag(BrowserState.ViewMode.list)
                Label("Columns", systemImage: "rectangle.split.3x1").tag(BrowserState.ViewMode.columns)
                Label("Icons", systemImage: "square.grid.2x2").tag(BrowserState.ViewMode.icons)
            }
            .pickerStyle(.segmented)
            .help("View as list, columns or icons")

            Button { model.showInspector.toggle() } label: { Label("Info", systemImage: "info.circle") }
                .help("Show archive information (⌘I)")

            Menu {
                Button("Test Integrity") { model.test(state) }.disabled(state.opened == nil || state.isTesting)
                Button("New Folder…") { newFolderName = ""; showNewFolder = true }.disabled(!state.isEditable)
                Button("Show Analysis…") { showAnalysis = true }.disabled(state.opened == nil)
                Divider()
                Button("Show in Finder") { model.platform.reveal([state.url]) }
                Button("Close Archive") { model.closeArchive(state.url) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions")
        }
    }

    // MARK: Actions

    private var subtitle: String {
        guard let o = state.opened else { return "" }
        return FormatCatalog.descriptor(for: o.detection.format)?.name ?? o.detection.format.rawValue
    }

    private var addTitle: String {
        pendingAdd.count == 1 ? "Add “\(pendingAdd[0].lastPathComponent)” to “\(state.displayName)”?" : "Add \(pendingAdd.count) items to “\(state.displayName)”?"
    }

    private var deleteTitle: String {
        let n = state.selection.count
        return n == 1 ? "Delete “\(state.selectedRows.first?.name ?? "")” from the archive?" : "Delete \(n) items from the archive?"
    }

    private func perform(_ command: BrowserCommand) {
        switch command {
        case .addFiles: addFiles()
        case .newFolder: newFolderName = ""; showNewFolder = true
        case .rename: if let r = state.selectedRows.first { beginRename(r) }
        case .delete: if !state.selection.isEmpty { confirmDelete = true }
        case .quickLook: quickLook()
        }
    }

    private func addFiles() {
        guard state.isEditable, let urls = Panels.chooseItemsToCompress(prompt: "Add") else { return }
        model.add(urls, to: state)
    }

    private func extractTo(_ rows: [BrowserRow]) {
        guard let dest = Panels.chooseFolder(prompt: "Extract", directory: state.url.deletingLastPathComponent()) else { return }
        state.selection = Set(rows.map(\.id))
        model.extract(from: state, to: dest)
    }

    private func beginRename(_ row: BrowserRow) {
        newName = row.name
        renameTarget = row
    }

    private func quickLook() {
        guard let row = state.selectedRows.first, !row.isFolder else { return }
        Task {
            switch await model.previewFile(for: row, in: state) {
            case .success(let url): quickLookURL = url
            case .failure(let e): model.present(e, context: "Quick Look “\(row.name)”")
            }
        }
    }

    private func editExternally(_ row: BrowserRow) {
        model.editExternally(row, in: state) { session in
            changedSession = EditPrompt(session: session)
        }
    }
}

// MARK: Pieces

/// "Archive › Folder › Subfolder", with an Up button, like Finder's path bar.
struct PathBar: View {
    @Bindable var state: BrowserState

    var body: some View {
        HStack(spacing: 4) {
            Button { state.goUp() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(state.currentFolder.isEmpty)
                .help("Enclosing folder")
                .accessibilityLabel("Enclosing folder")
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button { state.open(folder: "") } label: {
                Label {
                    Text(state.displayName)
                } icon: {
                    Image(nsImage: FileIcons.icon(forFile: state.url)).resizable().frame(width: 14, height: 14)
                }
            }
            .buttonStyle(.borderless)
            let parts = state.pathComponents
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                Button(part) { state.open(folder: parts[0...i].joined(separator: "/")) }
                    .buttonStyle(.borderless)
            }
            Spacer()
            if !state.searchText.isEmpty {
                Text("Searching the whole archive").font(.caption).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

struct StatusBar: View {
    let state: BrowserState

    var body: some View {
        HStack(spacing: 12) {
            if let l = state.opened?.listing {
                Text("\(l.fileCount) file\(l.fileCount == 1 ? "" : "s"), \(l.directoryCount) folder\(l.directoryCount == 1 ? "" : "s") · \(formatBytes(l.totalUncompressedSize))")
                if l.properties.hasEncryptedEntries == true {
                    Label("Encrypted", systemImage: "lock.fill")
                }
                if state.isTesting {
                    ProgressView().controlSize(.mini)
                    Text("Testing…")
                } else if let r = state.integrity {
                    Label(r.result == .passed ? "Verified" : "Problems found", systemImage: r.result == .passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.result == .passed ? .green : .orange)
                }
            }
            Spacer()
            if !state.selection.isEmpty {
                let selected = state.selectedRows
                let bytes = selected.reduce(UInt64(0)) { $0 + $1.size }
                Text("\(selected.count) selected\(bytes > 0 ? " · \(ByteFormatting.string(bytes))" : "")")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// Finder-style column view: each column lists a folder; the selected path is highlighted.
struct ColumnBrowser: View {
    @Bindable var state: BrowserState
    let onOpen: (BrowserRow) -> Void

    var body: some View {
        let parts = state.pathComponents
        let folders = [""] + parts.indices.map { parts[0...$0].joined(separator: "/") }
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(folders.enumerated()), id: \.element) { depth, folder in
                        let rows = state.rows(in: folder)
                        let highlighted: Int? = {
                            if depth + 1 < folders.count { return rows.first { $0.path == folders[depth + 1] }?.id }
                            return state.selection.first.flatMap { id in rows.contains { $0.id == id } ? id : nil }
                        }()
                        List(selection: Binding<Int?>(get: { highlighted }, set: { id in
                            guard let id, let row = rows.first(where: { $0.id == id }) else { return }
                            if row.isFolder {
                                state.currentFolder = row.path
                                state.selection = []
                            } else {
                                state.currentFolder = folder
                                state.selection = [row.id]
                            }
                        })) {
                            ForEach(rows) { r in
                                HStack(spacing: 6) {
                                    Image(nsImage: FileIcons.icon(for: r)).resizable().frame(width: 16, height: 16)
                                    Text(r.name).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    if r.isFolder { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                                }
                                .tag(r.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { onOpen(r) }
                            }
                        }
                        .frame(width: 230)
                        .id(folder)
                        Divider()
                    }
                }
            }
            .onChange(of: state.currentFolder) { _, f in
                withAnimation { proxy.scrollTo(f, anchor: .trailing) }
            }
        }
    }
}

struct IconGrid<MenuContent: View>: View {
    @Bindable var state: BrowserState
    let onOpen: (BrowserRow) -> Void
    @ViewBuilder let menu: ([BrowserRow]) -> MenuContent
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
                ForEach(state.rows) { r in
                    let selected = state.selection.contains(r.id)
                    VStack(spacing: 4) {
                        Image(nsImage: FileIcons.icon(for: r))
                            .resizable()
                            .frame(width: 56, height: 56)
                            .padding(4)
                            .background(selected ? Color.secondary.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        Text(r.name)
                            .font(.callout)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .frame(width: 104)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onOpen(r) }
                    .onTapGesture { state.selection = [r.id] }
                    .draggable(DraggedEntry(archive: state.url, path: r.path, isFolder: r.isFolder,
                                            service: model.service, readOptions: model.readOptions()))
                    .contextMenu { menu([r]) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding()
        }
        .contentShape(Rectangle())
        .onTapGesture { state.selection = [] }
    }
}

/// Dragging an entry out extracts it to a private temporary folder and hands Finder a real file.
struct DraggedEntry: Transferable {
    let archive: URL
    let path: String
    let isFolder: Bool
    let service: ArchiveService
    let readOptions: ReadOptions

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { entry in
            let dir = PreviewCache.shared.directory.appendingPathComponent("drag-\(UUID().uuidString)", isDirectory: true)
            let o = try entry.service.extract(ExtractRequest(archive: entry.archive, destination: dir, mode: .here,
                                                             selection: .paths([entry.path]),
                                                             options: ExtractionOptions(linkPolicy: .preserveSafe),
                                                             readOptions: entry.readOptions))
            // The entry keeps its folder path inside the extraction folder; hand over the item itself.
            let item = dir.appendingPathComponent(entry.path)
            guard FileManager.default.fileExists(atPath: item.path) else {
                guard let first = o.createdItems.first else { throw ArchiveError.invalidArgument("Nothing to drag.") }
                return SentTransferredFile(first)
            }
            return SentTransferredFile(item)
        }
    }
}

// MARK: Inspector

struct ArchiveInspector: View {
    let state: BrowserState

    var body: some View {
        Form {
            if let o = state.opened {
                let l = o.listing
                let p = l.properties
                Section("Archive") {
                    LabeledContent("Format", value: FormatCatalog.descriptor(for: o.detection.format)?.name ?? o.detection.format.rawValue)
                    LabeledContent("Compression", value: p.compressionMethods.isEmpty ? (p.filters.isEmpty ? "Unknown" : p.filters.joined(separator: ", ")) : p.compressionMethods.joined(separator: ", "))
                    LabeledContent("Encryption", value: p.hasEncryptedEntries == true ? (p.encryptionMethod ?? "Yes") : (p.hasEncryptedEntries == false ? "None" : "Unknown"))
                    if p.hasEncryptedHeaders == true { LabeledContent("File names", value: "Encrypted") }
                    LabeledContent("Size", value: formatBytes(l.totalUncompressedSize))
                    LabeledContent("On disk", value: formatBytes(p.archiveSize))
                    if let t = l.totalUncompressedSize, t > 0, let s = p.archiveSize {
                        LabeledContent("Saved", value: String(format: "%.0f%%", max(0, (1 - Double(s) / Double(t)) * 100)))
                    }
                    LabeledContent("Items", value: "\(l.fileCount) files, \(l.directoryCount) folders")
                    if let solid = p.isSolid { LabeledContent("Solid", value: solid ? "Yes" : "No") }
                    if let mp = o.detection.multipart { LabeledContent("Parts", value: "\(mp.volumes.count)") }
                    LabeledContent("Integrity", value: state.integrity.map { $0.result == .passed ? "Verified" : "Problems found" } ?? "Not tested")
                    LabeledContent("Engine", value: o.engine.rawValue)
                    if let c = p.comment, !c.isEmpty { LabeledContent("Comment") { Text(c).textSelection(.enabled) } }
                }
                if !o.engineNotes.isEmpty {
                    Section("Notes") {
                        ForEach(o.engineNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let e = state.selectedEntry {
                    Section("Selected Item") {
                        LabeledContent("Name") { Text(e.name).textSelection(.enabled) }
                        LabeledContent("Size", value: formatBytes(e.uncompressedSize))
                        LabeledContent("Compressed", value: formatBytes(e.compressedSize))
                        if let m = e.method { LabeledContent("Method", value: m) }
                        if let d = e.modificationDate { LabeledContent("Modified", value: d.formatted(date: .abbreviated, time: .shortened)) }
                        if let perm = e.permissions { LabeledContent("Permissions", value: String(perm & 0o7777, radix: 8)) }
                        if let crc = e.crc32 { LabeledContent("CRC-32", value: String(format: "%08X", crc)) }
                        LabeledContent("Encrypted", value: e.isEncrypted ? "Yes" : "No")
                    }
                }
            } else {
                Text("Reading the archive…").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Analysis

struct KindBar: Identifiable {
    let name: String
    let bytes: Double
    var id: String { name }
}

/// Where the space goes: by file type, largest files and top-level folders.
struct AnalysisView: View {
    let listing: ArchiveListing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let a = ArchiveAnalysis(listing: listing)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Archive Analysis").font(.title2.weight(.semibold))
                    if let r = a.overallRatio { Text(String(format: "The archive is %.1f%% of the original size.", r * 100)).foregroundStyle(.secondary) }
                    Text("Space by type").font(.headline)
                    let bars = a.bytesByKind.map { KindBar(name: $0.kind.rawValue.capitalized, bytes: Double($0.bytes)) }
                    Chart(bars) { k in
                        BarMark(x: .value("Size", k.bytes), y: .value("Type", k.name))
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel { if let d = value.as(Double.self) { Text(ByteFormatting.string(UInt64(max(0, d)))) } }
                        }
                    }
                    .frame(height: CGFloat(max(1, bars.count)) * 26 + 30)
                    .accessibilityLabel("Space used by each file type")
                    Text("Largest files").font(.headline)
                    ForEach(a.largestFiles.prefix(10)) { f in
                        HStack {
                            Text(f.normalizedPath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(formatBytes(f.uncompressedSize)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Text("Top-level folders").font(.headline)
                    ForEach(Array(a.directorySizes.prefix(10).enumerated()), id: \.offset) { _, d in
                        HStack {
                            Text(d.path)
                            Spacer()
                            Text(ByteFormatting.string(d.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if !a.poorlyCompressed.isEmpty {
                        Text("Barely compressed (\(a.poorlyCompressed.count))").font(.headline)
                        Text("Usually photos, videos or archives, which are already compressed.").font(.caption).foregroundStyle(.secondary)
                        ForEach(a.poorlyCompressed.prefix(10)) { f in Text(f.normalizedPath).font(.callout).lineLimit(1).truncationMode(.middle) }
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 620, height: 640)
    }
}
#endif
