import Foundation
import Observation
import ArchiveCore
import ArchiverKit
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// One row in the archive browser: an entry, or a folder that only exists implicitly in the paths.
struct BrowserRow: Identifiable, Hashable, Sendable {
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
    var isSymlink: Bool
    var entry: ArchiveEntry?

    init(entry e: ArchiveEntry, displayName: String) {
        id = e.index
        name = displayName
        path = e.normalizedPath
        isFolder = e.type == .directory
        size = e.uncompressedSize ?? 0
        packed = e.compressedSize ?? 0
        ratio = e.compressionRatio ?? -1
        isSymlink = e.type == .symlink
        kind = isFolder ? "Folder" : (isSymlink ? "Alias" : Self.kindName(forExtension: e.fileExtension))
        modified = e.modificationDate ?? .distantPast
        encrypted = e.isEncrypted
        entry = e
    }

    init(folder path: String, name: String, id: Int) {
        self.id = id
        self.name = name
        self.path = path
        isFolder = true
        size = 0
        packed = 0
        ratio = -1
        kind = "Folder"
        modified = .distantPast
        encrypted = false
        isSymlink = false
        entry = nil
    }

    /// Finder's description of a file type ("PDF document", "JPEG image") where available.
    static func kindName(forExtension ext: String) -> String {
        #if canImport(UniformTypeIdentifiers)
        if !ext.isEmpty, let t = UTType(filenameExtension: ext), let d = t.localizedDescription { return d }
        #endif
        switch FileClassifier.kind(forExtension: ext) {
        case .text: return "Text"
        case .sourceCode: return "Source code"
        case .document: return "Document"
        case .image: return "Image"
        case .video: return "Movie"
        case .audio: return "Audio"
        case .archive: return "Archive"
        case .executable: return "Program"
        case .database: return "Database"
        case .other: return ext.isEmpty ? "Document" : "\(ext.uppercased()) file"
        }
    }

    // Sort keys for `Table` columns (non-optional, so every column is sortable).
    var sortName: String { name.lowercased() }
}

/// The archive's folder hierarchy, built once per listing so browsing large archives stays fast.
struct FolderIndex: Sendable {
    /// Children of each folder ("" is the root), unsorted.
    private(set) var children: [String: [BrowserRow]] = [:]
    /// Every file, for searching.
    private(set) var files: [BrowserRow] = []
    private(set) var rowsByID: [Int: BrowserRow] = [:]

    init(listing: ArchiveListing) {
        var seen = Set<String>()
        var nextSyntheticID = -1
        func addFolderChain(_ path: String) {
            // Make sure every ancestor folder appears in its parent, even if the archive has no entry for it.
            var components: [String] = []
            for part in path.split(separator: "/").map(String.init) {
                let parent = components.joined(separator: "/")
                components.append(part)
                let full = components.joined(separator: "/")
                if seen.insert(full).inserted {
                    let row = BrowserRow(folder: full, name: part, id: nextSyntheticID)
                    nextSyntheticID -= 1
                    children[parent, default: []].append(row)
                    rowsByID[row.id] = row
                }
            }
        }
        for e in listing.entries {
            let path = e.normalizedPath
            guard !path.isEmpty else { continue }
            let (parent, name) = Self.split(path)
            if !parent.isEmpty { addFolderChain(parent) }
            if e.type == .directory {
                // A real directory entry replaces the synthetic row (it has dates and permissions).
                if seen.insert(path).inserted {
                    let row = BrowserRow(entry: e, displayName: name)
                    children[parent, default: []].append(row)
                    rowsByID[row.id] = row
                } else if let i = children[parent]?.firstIndex(where: { $0.path == path && $0.entry == nil }) {
                    let old = children[parent]![i]
                    var row = BrowserRow(entry: e, displayName: name)
                    row.id = old.id
                    children[parent]![i] = row
                    rowsByID[row.id] = row
                }
            } else {
                let row = BrowserRow(entry: e, displayName: name)
                children[parent, default: []].append(row)
                files.append(row)
                rowsByID[row.id] = row
            }
        }
    }

    func rows(in folder: String) -> [BrowserRow] { children[folder] ?? [] }

    /// "a/b/c" → ("a/b", "c"); "c" → ("", "c"). Archive paths are always "/"-separated.
    static func split(_ path: String) -> (parent: String, name: String) {
        guard let i = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<i]), String(path[path.index(after: i)...]))
    }
}

/// Commands sent from the menu bar to the archive browser.
enum BrowserCommand: Equatable {
    case addFiles, newFolder, rename, delete, quickLook
}

/// State of one open archive in the main window.
@MainActor
@Observable
final class BrowserState: Identifiable {
    enum ViewMode: String, CaseIterable, Identifiable {
        case list, columns, icons
        var id: Self { self }
    }

    let url: URL
    nonisolated var id: URL { url }
    private(set) var opened: OpenedArchive?
    private(set) var index: FolderIndex?
    private(set) var error: ArchiveError?
    private(set) var isLoading = false
    var currentFolder = ""
    var searchText = ""
    var selection = Set<Int>()
    var viewMode: ViewMode = .list
    var sortOrder = [KeyPathComparator(\BrowserRow.sortName)]
    var integrity: IntegrityReport?
    var isTesting = false
    /// A menu-bar command for the browser view to carry out (it owns the dialogs those commands show).
    var pendingCommand: BrowserCommand?
    /// Files opened for editing in another app, by archive path.
    var editSessions: [String: ExternalEditSession] = [:]

    @ObservationIgnored private var rowCache: (key: RowKey, rows: [BrowserRow])?

    private struct RowKey: Equatable {
        var folder: String
        var search: String
        var sort: [KeyPathComparator<BrowserRow>]
        var generation: Int
    }
    @ObservationIgnored private var generation = 0

    init(url: URL) { self.url = url }

    var displayName: String { url.lastPathComponent }

    func load(using model: AppModel) {
        isLoading = true
        error = nil
        let service = model.service
        let options = model.readOptions()
        let u = url
        Task {
            let r = await offMain { () -> (OpenedArchive, FolderIndex) in
                let o = try service.open(u, options: options)
                return (o, FolderIndex(listing: o.listing))
            }
            isLoading = false
            switch r {
            case .success(let (o, idx)):
                show(o, index: idx)
                Self.reportForSmokeTest("opened \(u.lastPathComponent) \(o.listing.fileCount)")
            case .failure(let e):
                error = e
                Self.reportForSmokeTest("failed \(u.lastPathComponent) \(e.code)")
            }
        }
    }

    /// Scripts/smoke-test-app.sh sets ZIPPER_SMOKE_REPORT to learn whether opening an archive really
    /// worked (the browser shows failures inline, so a running process alone proves nothing).
    static func reportForSmokeTest(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["ZIPPER_SMOKE_REPORT"], !path.isEmpty else { return }
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            _ = FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// Shows a (re)loaded listing, keeping the user's place when the folder still exists (e.g. after an edit).
    func show(_ opened: OpenedArchive?, index idx: FolderIndex) {
        self.opened = opened
        index = idx
        generation += 1
        if !currentFolder.isEmpty, idx.children[currentFolder] == nil { currentFolder = "" }
        selection = selection.filter { idx.rowsByID[$0] != nil }
    }

    /// Rows for the current folder, or search results across the whole archive. Folders come first.
    var rows: [BrowserRow] {
        guard let index else { return [] }
        let key = RowKey(folder: currentFolder, search: searchText, sort: sortOrder, generation: generation)
        if let cache = rowCache, cache.key == key { return cache.rows }
        let source: [BrowserRow]
        if searchText.isEmpty {
            source = index.rows(in: currentFolder)
        } else {
            let search = EntrySearch(text: searchText)
            source = index.files.filter { $0.entry.map(search.matches) ?? false }
                .map { var r = $0; r.name = r.path; return r }
        }
        let sorted = source.sorted(using: sortOrder)
        let result = sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
        rowCache = (key, result)
        return result
    }

    func rows(in folder: String) -> [BrowserRow] {
        let r = index?.rows(in: folder) ?? []
        let sorted = r.sorted { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending }
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    func row(id: Int) -> BrowserRow? { index?.rowsByID[id] }

    var selectedRows: [BrowserRow] { selection.compactMap(row(id:)) }

    /// The single selected file's entry (for the inspector and previews).
    var selectedEntry: ArchiveEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return row(id: id)?.entry
    }

    /// Archive paths of the selection; empty means "everything".
    var selectedPaths: [String] { selectedRows.map(\.path) }

    var pathComponents: [String] { currentFolder.split(separator: "/").map(String.init) }

    func open(folder path: String) {
        currentFolder = path
        searchText = ""
        selection = []
    }

    func goUp() {
        guard !currentFolder.isEmpty else { return }
        open(folder: FolderIndex.split(currentFolder).parent)
    }

    var isEditable: Bool {
        guard let format = opened?.detection.format else { return false }
        return opened?.detection.multipart == nil && FormatCatalog.descriptor(for: format)?.kind != .compressionStream
    }

    func discardEditSessions() {
        editSessions.values.forEach { $0.discard() }
        editSessions = [:]
    }
}

/// Runs throwing work off the main actor and returns its result there.
func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, ArchiveError> {
    await Task.detached(priority: .userInitiated) {
        do { return .success(try work()) } catch { return .failure(ArchiveError.wrap(error)) }
    }.value
}

func formatBytes(_ v: UInt64?) -> String { v.map(ByteFormatting.string) ?? "Unknown" }
