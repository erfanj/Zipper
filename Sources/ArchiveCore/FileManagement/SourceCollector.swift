import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Classifies files by extension (cheap) for filtering and the advisor.
public enum FileClassifier {
    static let map: [FileKind: Set<String>] = [
        .text: ["txt", "md", "markdown", "csv", "tsv", "log", "json", "xml", "yaml", "yml", "ini", "cfg", "conf", "toml",
                "html", "htm", "css", "svg", "rtf", "tex", "srt", "vtt", "sql", "plist", "strings"],
        .sourceCode: ["swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cxx", "rs", "go", "java", "kt", "kts", "scala",
                      "py", "rb", "php", "js", "mjs", "cjs", "ts", "tsx", "jsx", "cs", "fs", "vb", "lua", "pl", "pm",
                      "sh", "bash", "zsh", "r", "jl", "dart", "hs", "ex", "exs", "erl", "clj", "el", "vue", "svelte",
                      "gradle", "cmake", "mk", "make", "dockerfile", "proto", "graphql", "ipynb"],
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "pages", "numbers", "key",
                    "epub", "rtfd"],
        .image: ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "tif", "tiff", "bmp", "raw", "cr2", "cr3",
                 "nef", "arw", "dng", "raf", "orf", "psd", "ico", "icns", "jxl"],
        .video: ["mp4", "m4v", "mov", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp", "hevc", "mts", "m2ts"],
        .audio: ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "ogg", "opus", "wma", "caf"],
        .archive: ["zip", "7z", "rar", "gz", "tgz", "bz2", "xz", "zst", "lz4", "br", "lz", "lzma", "tar", "dmg", "iso",
                   "cab", "jar", "apk", "ipa", "aar", "aea", "sit", "sitx", "cbz", "cbr", "zipx", "arj", "lzh", "wim"],
        .executable: ["app", "exe", "dll", "dylib", "so", "o", "a", "msi", "pkg", "bin"],
        .database: ["sqlite", "db", "sqlite3", "realm", "mdb", "accdb"],
    ]

    public static func kind(forExtension ext: String) -> FileKind {
        let e = ext.lowercased()
        for (k, set) in map where set.contains(e) { return k }
        return .other
    }

    /// Formats whose payload is already compressed; recompressing them gains little.
    public static func isTypicallyCompressed(_ ext: String) -> Bool {
        let e = ext.lowercased()
        let k = kind(forExtension: e)
        if k == .video || k == .archive { return true }
        if k == .image { return !["bmp", "tif", "tiff", "raw", "psd", "svg", "ico"].contains(e) }
        if k == .audio { return !["wav", "aiff", "aif", "caf"].contains(e) }
        return ["docx", "xlsx", "pptx", "odt", "ods", "odp", "pages", "numbers", "key", "epub", "pdf", "woff", "woff2"].contains(e)
    }
}

/// The enumerated inputs for an archive.
public struct SourceCollection: Sendable {
    public var items: [SourceItem]
    /// Items left out, with the reason (shown to the user; nothing is omitted silently).
    public var excluded: [(path: String, reason: String)]
    /// Files that could not be read.
    public var unreadable: [String]
    /// Cloud files whose contents are not on this Mac yet.
    public var notDownloaded: [URL]

    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.size } }
    public var fileCount: Int { items.filter { $0.type == .file }.count }
    public var directoryCount: Int { items.filter { $0.type == .directory }.count }
}

/// Walks the user's selection and produces archive entries, applying hidden-file, symlink,
/// metadata and filter settings.
public enum SourceCollector {
    static let macMetadataNames: Set<String> = [".DS_Store", ".localized", "Icon\r", ".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems"]

    public static func collect(_ urls: [URL], settings: CompressionSettings, progress: OperationProgress? = nil) throws -> SourceCollection {
        let walker = Walker(settings: settings, progress: progress)
        let fm = FileManager.default
        let single = urls.count == 1
        for root in urls {
            try progress?.checkCancelled()
            let rootURL = root.standardizedFileURL
            let attrs: [FileAttributeKey: Any]
            do { attrs = try fm.attributesOfItem(atPath: rootURL.path) } catch {
                throw ArchiveError.fileNotFound(path: rootURL.path)
            }
            let type = attrs[.type] as? FileAttributeType
            let base = rootURL.deletingLastPathComponent()
            let rootName = settings.filenameNormalization.apply(rootURL.lastPathComponent)
            let isDir = type == .typeDirectory || (type == .typeSymbolicLink && settings.symlinks == .follow && isDirectory(rootURL))
            if isDir {
                let stripRoot = single && !settings.includeRootFolder
                if stripRoot {
                    walker.walk(rootURL, prefix: "", base: rootURL)
                } else {
                    walker.add(rootURL, archivePath: rootName, base: base, isRoot: true)
                }
            } else {
                walker.add(rootURL, archivePath: rootName, base: base, isRoot: true)
            }
        }
        try progress?.checkCancelled()
        return walker.out
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    final class Walker {
        var out = SourceCollection(items: [], excluded: [], unreadable: [], notDownloaded: [])
        let settings: CompressionSettings
        let filter: FileFilter
        let progress: OperationProgress?
        var visited = Set<String>()

        init(settings: CompressionSettings, progress: OperationProgress?) {
            self.settings = settings
            self.filter = FileFilter(rules: settings.filters)
            self.progress = progress
        }

        func walk(_ dir: URL, prefix: String, base: URL) {
            // Loop detection by device + inode (stat follows links). Path-based checks fail on very
            // long paths, which would wrongly drop deep folders.
            var st = stat()
            if stat(dir.path, &st) == 0 {
                guard visited.insert("\(st.st_dev):\(st.st_ino)").inserted else {
                    out.excluded.append((prefix, "symbolic link loop"))
                    return
                }
            }
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() } catch {
                out.unreadable.append(dir.path)
                return
            }
            for name in names {
                if progress?.isCancelled == true { return }
                let archivePath = ArchivePath.join(prefix, settings.filenameNormalization.apply(name))
                add(dir.appendingPathComponent(name), archivePath: archivePath, base: base, isRoot: false)
            }
        }

        func add(_ url: URL, archivePath: String, base: URL, isRoot: Bool) {
            let fm = FileManager.default
            let name = url.lastPathComponent
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
                out.unreadable.append(url.path)
                return
            }
            var type = attrs[.type] as? FileAttributeType
            let mdate = attrs[.modificationDate] as? Date
            var size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

            // Explicitly selected items are never dropped by the hidden/metadata switches.
            if !isRoot {
                if !settings.includeHidden, name.hasPrefix(".") {
                    out.excluded.append((archivePath, "hidden file (hidden files are turned off)"))
                    return
                }
                if settings.metadata == .crossPlatform, SourceCollector.macMetadataNames.contains(name) || name.hasPrefix("._") {
                    out.excluded.append((archivePath, "macOS metadata file (Cross-Platform mode)"))
                    return
                }
            }
            #if os(macOS)
            if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               let status = values.ubiquitousItemDownloadingStatus, status == .notDownloaded {
                out.notDownloaded.append(url)
            }
            #endif

            var linkTarget: String?
            if type == .typeSymbolicLink {
                switch settings.symlinks {
                case .skip:
                    out.excluded.append((archivePath, "symbolic link (links are set to be skipped)"))
                    return
                case .preserve:
                    linkTarget = try? fm.destinationOfSymbolicLink(atPath: url.path)
                case .follow:
                    guard let resolved = try? fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path) else {
                        out.excluded.append((archivePath, "broken symbolic link"))
                        return
                    }
                    type = resolved[.type] as? FileAttributeType
                    size = (resolved[.size] as? NSNumber)?.uint64Value ?? 0
                }
            }

            let isDir = type == .typeDirectory
            let subject = FilterSubject(relativePath: archivePath, isDirectory: isDir, size: size, modificationDate: mdate)
            if !isRoot {
                if isDir, filter.prunes(subject) {
                    out.excluded.append((archivePath + "/", "excluded by filter"))
                    return
                }
                if !filter.includes(subject) {
                    out.excluded.append((archivePath, "excluded by filter"))
                    return
                }
            }

            if linkTarget != nil {
                out.items.append(SourceItem(url: url, archivePath: archivePath, type: .symlink, size: 0, linkTarget: linkTarget,
                                            modificationDate: mdate, baseDirectory: base))
            } else if isDir {
                out.items.append(SourceItem(url: url, archivePath: archivePath, type: .directory, size: 0, modificationDate: mdate, baseDirectory: base))
                walk(url, prefix: archivePath, base: base)
            } else if type == .typeRegular {
                out.items.append(SourceItem(url: url, archivePath: archivePath, type: .file, size: size, modificationDate: mdate, baseDirectory: base))
                progress?.setCurrentItem(archivePath)
            } else {
                out.excluded.append((archivePath, "special file (device, socket or FIFO)"))
            }
        }
    }
}
