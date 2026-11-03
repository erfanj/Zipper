#if os(macOS)
import SwiftUI
import AppKit
import ArchiveCore
import ArchiverKit

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar { toolbar }
        // Dropping onto the window anywhere: files are compressed, archives opened.
        .dropDestination(for: URL.self) { urls, _ in
            model.handleOpen(urls)
            return !urls.isEmpty
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .compress(let form): CompressSheet(form: form)
            case .extract(let form): ExtractSheet(form: form)
            }
        }
        .confirmationDialog("What would you like to do?", isPresented: ambiguousDropPresented) {
            Button("Compress All Items") {
                let items = model.ambiguousDrop ?? []
                model.ambiguousDrop = nil
                model.beginCompress(items)
            }
            Button("Extract the Archives") {
                let archives = (model.ambiguousDrop ?? []).filter { model.isArchive($0) }
                model.ambiguousDrop = nil
                model.showTool(.batchExtract, input: ArchiveService.distinctArchives(archives))
            }
            Button("Cancel", role: .cancel) { model.ambiguousDrop = nil }
        } message: {
            Text("Some of these items are archives and some are not.")
        }
        .onAppear {
            model.openWindow = { id in openWindow(id: id) }
        }
    }

    private var ambiguousDropPresented: Binding<Bool> {
        Binding(get: { model.ambiguousDrop != nil }, set: { if !$0 { model.ambiguousDrop = nil } })
    }

    @ViewBuilder private var detail: some View {
        switch model.selection ?? .home {
        case .home:
            HomeView()
        case .archive(let url):
            if let state = model.archiveState(for: url) {
                ArchiveBrowserView(state: state).id(url)
            } else {
                HomeView()
            }
        case .activity:
            ActivityView()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The archive browser adds its own commands; these are for starting something new.
        if model.currentArchive == nil {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { if let urls = Panels.chooseItemsToCompress() { model.beginCompress(urls) } } label: {
                    Label("Compress", systemImage: "archivebox")
                }
                .help("Make an archive from files and folders (⌘N)")
                Button {
                    if let u = Panels.chooseArchive(prompt: "Extract", message: "Choose an archive to extract.") { model.beginExtract(u) }
                } label: {
                    Label("Extract", systemImage: "tray.and.arrow.up")
                }
                .help("Extract an archive (⇧⌘E)")
                Button { if let u = Panels.chooseArchive() { model.openArchive(u) } } label: {
                    Label("Open", systemImage: "doc.viewfinder")
                }
                .help("Look inside an archive without extracting it (⌘O)")
            }
        }
        // On Home only: with an archive open, its own commands lead (Tools stay in the menu bar).
        if model.currentArchive == nil {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(Tool.allCases) { tool in
                        Button { model.showTool(tool) } label: { Label(tool.title, systemImage: tool.symbol) }
                    }
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
                .help("Test, repair, convert, checksums and more")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            ActivityToolbarButton()
        }
    }
}

/// Shows that work is running and opens Activity. Always present, so the toolbar never jumps.
struct ActivityToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.operationsVersion
        let count = model.center.active.count
        Button { model.selection = .activity } label: {
            Label("Activity", systemImage: count > 0 ? "arrow.down.circle.dotted" : "clock.arrow.circlepath")
        }
        .help(count == 0 ? "Activity" : count == 1 ? "1 operation running" : "\(count) operations running")
        .overlay(alignment: .topTrailing) {
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.red, in: Circle())
                    .offset(x: 4, y: -2)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let _ = model.operationsVersion
        // ⌘-click on the selected row would deselect it, leaving nothing highlighted while the
        // detail still shows something; there is always a current destination.
        List(selection: Binding(get: { model.selection }, set: { if let s = $0 { model.selection = s } })) {
            Label("Home", systemImage: "house").tag(SidebarItem.home)
            if !model.openArchives.isEmpty {
                Section("Archives") {
                    ForEach(model.openArchives) { state in
                        ArchiveSidebarRow(state: state)
                            .tag(SidebarItem.archive(state.url))
                            .contextMenu {
                                Button("Extract") { model.extract(from: state, to: nil) }.disabled(state.opened == nil)
                                Button("Show in Finder") { model.platform.reveal([state.url]) }
                                Divider()
                                Button("Close") { model.closeArchive(state.url) }
                            }
                    }
                }
            }
            Section {
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .badge(model.center.active.count)
                    .tag(SidebarItem.activity)
            }
        }
        .listStyle(.sidebar)
    }
}

struct ArchiveSidebarRow: View {
    @Environment(AppModel.self) private var model
    let state: BrowserState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(state.displayName).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(nsImage: FileIcons.icon(forFile: state.url)).resizable().frame(width: 16, height: 16)
            }
            Spacer(minLength: 0)
            if state.isLoading || state.isTesting {
                ProgressView().controlSize(.mini)
            } else if state.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("This archive couldn't be read")
            } else if hovering {
                Button { model.closeArchive(state.url) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close")
                    .accessibilityLabel("Close \(state.displayName)")
            }
        }
        .onHover { hovering = $0 }
    }
}

// MARK: Home

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)
                    Text("Zipper")
                        .font(.largeTitle.weight(.semibold))
                    Text("Drop files here to compress them, or drop an archive to open it.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 36)

                HStack(spacing: 16) {
                    ActionCard(title: "Compress", subtitle: "Make an archive from files and folders", symbol: "archivebox") {
                        if let urls = Panels.chooseItemsToCompress() { model.beginCompress(urls) }
                    }
                    ActionCard(title: "Extract", subtitle: "Get the files out of an archive", symbol: "tray.and.arrow.up") {
                        if let u = Panels.chooseArchive(prompt: "Extract", message: "Choose an archive to extract.") { model.beginExtract(u) }
                    }
                    ActionCard(title: "Open", subtitle: "Look inside without extracting", symbol: "doc.viewfinder") {
                        if let u = Panels.chooseArchive() { model.openArchive(u) }
                    }
                }

                if !model.recentArchives.isEmpty {
                    RecentArchivesList()
                        .frame(maxWidth: 640)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            model.handleOpen(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        .navigationTitle("Zipper")
    }
}

struct ActionCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(height: 38)
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(width: 190, height: 150)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.background.secondary), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

struct RecentArchivesList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Archives").font(.headline)
                Spacer()
                Button("Clear") { model.clearRecents() }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
            VStack(spacing: 0) {
                ForEach(Array(model.recentArchives.prefix(8).enumerated()), id: \.element) { i, url in
                    if i > 0 { Divider() }
                    RecentArchiveRow(url: url)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
    }
}

struct RecentArchiveRow: View {
    @Environment(AppModel.self) private var model
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button { model.openArchive(url) } label: {
            HStack(spacing: 10) {
                Image(nsImage: FileIcons.icon(forFile: url)).resizable().frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(hovering ? Color.primary.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { model.openArchive(url) }
            Button("Extract") { model.quickExtract(url) }
            Button("Extract To…") {
                if let d = Panels.chooseFolder(prompt: "Extract", directory: url.deletingLastPathComponent()) {
                    model.extract(archive: url, destination: d, mode: model.settings.extractionMode)
                }
            }
            Divider()
            Button("Show in Finder") { model.platform.reveal([url]) }
        }
    }
}
#endif
