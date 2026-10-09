#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore
import ArchiveEngines
import ArchiverKit

struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            DetailRouter()
                .inspector(isPresented: $model.showInspector) {
                    InspectorPanel().inspectorColumnWidth(min: 240, ideal: 280, max: 380)
                }
        }
        .toolbar { MainToolbar() }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleOpen(urls)
            return true
        }
        .sheet(item: $model.passwordRequest) { req in PasswordSheet(request: req) }
        .sheet(item: $model.conflictRequest) { req in ConflictSheet(request: req) }
        .alert(item: $model.presentedError) { pe in
            Alert(title: Text(pe.error.title), message: Text(pe.error.explanation + (pe.error.suggestions.isEmpty ? "" : "\n\n" + pe.error.suggestions.joined(separator: "\n"))),
                  dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("What would you like to do with these items?", isPresented: Binding(get: { model.ambiguousDrop != nil }, set: { if !$0 { model.ambiguousDrop = nil } })) {
            Button("Compress All Items") {
                model.pendingCompression = model.ambiguousDrop ?? []
                model.selection = .compress
                model.ambiguousDrop = nil
            }
            Button("Extract the Archives") {
                let archives = (model.ambiguousDrop ?? []).filter { model.isArchive($0) }
                model.batchArchives = archives
                model.selection = .batch
                model.ambiguousDrop = nil
            }
            Button("Cancel", role: .cancel) { model.ambiguousDrop = nil }
        } message: {
            Text("Some of the dropped items are archives and some are not.")
        }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { if let urls = FilePicker.chooseItems(prompt: "Compress") { model.pendingCompression = urls; model.selection = .compress } } label: {
                Label("Compress", systemImage: "archivebox")
            }.help("Create an archive from files and folders")
            Button { if let u = FilePicker.chooseArchive() { model.quickExtract(u) } } label: {
                Label("Extract", systemImage: "tray.and.arrow.up")
            }.help("Extract an archive")
            Button { if let u = FilePicker.chooseArchive() { model.openArchive(u) } } label: {
                Label("Open", systemImage: "doc.viewfinder")
            }.help("Browse an archive without extracting it")
            if model.settings.uiLevel != .simple {
                Button { model.selection = .convert } label: { Label("Convert", systemImage: "arrow.triangle.2.circlepath") }
                Button { model.selection = .integrity } label: { Label("Test", systemImage: "checkmark.shield") }
                Button { model.selection = .repair } label: { Label("Repair", systemImage: "bandage") }
            }
            Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let _ = model.operationsVersion
        List(selection: $model.selection) {
            Label("Home", systemImage: "house").tag(SidebarItem.home)
            Section("Quick Actions") {
                Label("Compress Files", systemImage: "archivebox").tag(SidebarItem.compress)
                Label("Extract Archive", systemImage: "tray.and.arrow.up").tag(SidebarItem.extract)
                Label("Convert Archive", systemImage: "arrow.triangle.2.circlepath").tag(SidebarItem.convert)
                if model.settings.uiLevel != .simple {
                    Label("Batch Extract", systemImage: "square.stack.3d.up").tag(SidebarItem.batch)
                }
            }
            if !model.openedArchives.isEmpty {
                Section("Open Archives") {
                    ForEach(Array(model.openedArchives.keys).sorted { $0.lastPathComponent < $1.lastPathComponent }, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "doc.zipper").tag(SidebarItem.archive(url))
                            .contextMenu { Button("Close") { model.openedArchives[url] = nil; if model.selection == .archive(url) { model.selection = .home } } }
                    }
                }
            }
            if !model.recentArchives.isEmpty {
                Section("Recent Archives") {
                    ForEach(model.recentArchives.prefix(6), id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "clock")
                            .onTapGesture(count: 1) { model.openArchive(url) }
                            .contextMenu {
                                Button("Extract") { model.quickExtract(url) }
                                Button(model.favorites.contains(url) ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }
                    }
                }
            }
            if !model.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(model.favorites, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "star").onTapGesture { model.openArchive(url) }
                    }
                }
            }
            if model.settings.uiLevel != .simple {
                Section("Saved Presets") {
                    ForEach(model.userPresets) { p in Label(p.name, systemImage: "slider.horizontal.3").tag(SidebarItem.preset(p.id)) }
                    if model.userPresets.isEmpty { Text("Save settings as a preset from the Compress view.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Activity") {
                Label { Text("Active Operations") } icon: { Image(systemName: "bolt.horizontal") }
                    .badge(model.center.active.count)
                    .tag(SidebarItem.activeOperations)
                Label("Completed", systemImage: "checkmark.circle").tag(SidebarItem.completedOperations)
                Label("History", systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
            }
            Section("Tools") {
                Label("Integrity Verification", systemImage: "checkmark.shield").tag(SidebarItem.integrity)
                Label("Archive Repair", systemImage: "bandage").tag(SidebarItem.repair)
                Label("Checksum Tools", systemImage: "number").tag(SidebarItem.checksums)
                Label("Split / Join Files", systemImage: "square.split.2x1").tag(SidebarItem.splitJoin)
                if model.settings.uiLevel != .simple {
                    Label("Compare Archives", systemImage: "arrow.left.arrow.right").tag(SidebarItem.compare)
                    Label("Find Duplicates", systemImage: "doc.on.doc").tag(SidebarItem.duplicates)
                }
            }
            Section {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
        }
        .listStyle(.sidebar)
    }
}

struct DetailRouter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        switch model.selection ?? .home {
        case .home: WelcomeView()
        case .compress: CompressView()
        case .extract: ExtractView()
        case .convert: ConvertView()
        case .batch: BatchExtractView()
        case .archive(let url):
            if let state = model.openedArchives[url] { ArchiveBrowserView(state: state) } else { WelcomeView() }
        case .activeOperations: OperationsView(showFinished: false)
        case .completedOperations: OperationsView(showFinished: true)
        case .history: HistoryView()
        case .integrity: IntegrityView()
        case .repair: RepairView()
        case .checksums: ChecksumView()
        case .splitJoin: SplitJoinView()
        case .compare: CompareView()
        case .duplicates: DuplicatesView()
        case .preset(let id):
            if let p = model.userPresets.first(where: { $0.id == id }) { PresetDetailView(preset: p) } else { WelcomeView() }
        }
    }
}

// MARK: Welcome

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text("What would you like to do?")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.top, 32)
                HStack(spacing: 18) {
                    BigAction(title: "Compress Files", subtitle: "Create an archive", symbol: "archivebox") {
                        if let urls = FilePicker.chooseItems(prompt: "Compress") { model.pendingCompression = urls; model.selection = .compress }
                    }
                    BigAction(title: "Extract Archive", subtitle: "Get the files out", symbol: "tray.and.arrow.up") {
                        if let u = FilePicker.chooseArchive() { model.quickExtract(u) }
                    }
                    BigAction(title: "Open Archive", subtitle: "Browse without extracting", symbol: "doc.viewfinder") {
                        if let u = FilePicker.chooseArchive() { model.openArchive(u) }
                    }
                }
                DropZone(targeted: $targeted)
                    .dropDestination(for: URL.self) { urls, _ in
                        model.handleOpen(urls)
                        return true
                    } isTargeted: { targeted = $0 }
                HStack(alignment: .top, spacing: 24) {
                    if !model.recentArchives.isEmpty {
                        GroupBox("Recent Archives") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.recentArchives.prefix(6), id: \.self) { url in
                                    Button { model.openArchive(url) } label: {
                                        Label(url.lastPathComponent, systemImage: "doc.zipper").frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    GroupBox("Presets") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.allPresets.prefix(6)) { p in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name)
                                    Text(p.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let recent = model.history.all().prefix(5)
                    if !recent.isEmpty {
                        GroupBox("Recent Activity") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(recent)) { r in
                                    Label("\(r.kind.rawValue.capitalized): \(r.inputs.first.map { ($0 as NSString).lastPathComponent } ?? "")", systemImage: r.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                                        .lineLimit(1)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: 900)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

struct BigAction: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.tint)
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(width: 200, height: 150)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title). \(subtitle)"))
    }
}

struct DropZone: View {
    @Binding var targeted: Bool
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc").font(.title2)
            Text("Drop files here to compress them, or archives to extract them")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 640, minHeight: 110)
        .background(targeted ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])).foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5)))
        .animation(.easeOut(duration: 0.15), value: targeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop zone")
    }
}

// MARK: Inspector

struct InspectorPanel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            if case .archive(let url)? = model.selection, let state = model.openedArchives[url] {
                ArchiveInfoDashboard(state: state)
            } else {
                Text("Select an archive to see its details.").foregroundStyle(.secondary).padding()
            }
        }
    }
}

struct ArchiveInfoDashboard: View {
    let state: BrowserState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Archive Information").font(.headline)
            if let o = state.opened {
                let l = o.listing
                let unknown = "Unknown"
                InfoRow("Filename", o.url.lastPathComponent)
                InfoRow("Format", (FormatCatalog.descriptor(for: o.detection.format)?.name ?? o.detection.format.rawValue) + (l.properties.formatDescription.map { " (\($0))" } ?? ""))
                InfoRow("Compression", l.properties.compressionMethods.isEmpty ? (l.properties.filters.isEmpty ? unknown : l.properties.filters.joined(separator: ", ")) : l.properties.compressionMethods.joined(separator: ", "))
                InfoRow("Encryption", l.properties.hasEncryptedEntries == true ? (l.properties.encryptionMethod ?? "Yes") : (l.properties.hasEncryptedEntries == false ? "None" : unknown))
                InfoRow("Encrypted filenames", l.properties.hasEncryptedHeaders.map { $0 ? "Yes" : "No" } ?? unknown)
                InfoRow("Original size", l.totalUncompressedSize.map(ByteFormatting.string) ?? unknown)
                InfoRow("Compressed size", l.properties.archiveSize.map(ByteFormatting.string) ?? unknown)
                if let t = l.totalUncompressedSize, t > 0, let s = l.properties.archiveSize {
                    InfoRow("Space savings", String(format: "%.1f%%", (1 - Double(s) / Double(t)) * 100))
                }
                InfoRow("Files", "\(l.fileCount)")
                InfoRow("Folders", "\(l.directoryCount)")
                InfoRow("Solid", l.properties.isSolid.map { $0 ? "Yes" : "No" } ?? unknown)
                InfoRow("Volumes", "\(o.detection.multipart?.volumes.count ?? 1)")
                InfoRow("Integrity", state.integrity.map { $0.result == .passed ? "Verified" : "Problems found" } ?? "Not tested")
                InfoRow("Engine", o.engine.rawValue)
                if let c = l.properties.comment { InfoRow("Comment", c) }
                ForEach(o.engineNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                if let sel = state.selectedEntry {
                    Divider()
                    Text("Selected Item").font(.headline)
                    InfoRow("Name", sel.name)
                    InfoRow("Size", sel.uncompressedSize.map(ByteFormatting.string) ?? unknown)
                    InfoRow("Packed", sel.compressedSize.map(ByteFormatting.string) ?? unknown)
                    InfoRow("Method", sel.method ?? unknown)
                    InfoRow("Modified", sel.modificationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? unknown)
                    InfoRow("Permissions", sel.permissions.map { String($0, radix: 8) } ?? unknown)
                    InfoRow("CRC-32", sel.crc32.map { String(format: "%08X", $0) } ?? unknown)
                    InfoRow("Encrypted", sel.isEncrypted ? "Yes" : "No")
                }
            } else {
                ProgressView()
            }
        }
        .padding()
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
