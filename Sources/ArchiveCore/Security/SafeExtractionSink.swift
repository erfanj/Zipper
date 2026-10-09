import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ConflictPolicy: String, Codable, Sendable, CaseIterable {
    /// Keep the existing item and write the new one under a numbered name ("file 2.txt"). Default.
    case keepBoth
    case replace
    case skip
    /// Replace only when the archived entry is newer than the existing file.
    case replaceIfOlder
    /// Ask the resolver for each conflict.
    case ask

    public var displayName: String {
        switch self {
        case .keepBoth: return "Keep both"
        case .replace: return "Replace"
        case .skip: return "Skip"
        case .replaceIfOlder: return "Replace older files"
        case .ask: return "Ask each time"
        }
    }
}

public enum ConflictDecision: Sendable {
    case replace
    case skip
    case keepBoth
}

public struct ConflictInfo: Sendable {
    public var archivePath: String
    public var existingPath: String
    public var existingIsDirectory: Bool
    public var existingModified: Date?
    public var existingSize: UInt64?
    public var entryModified: Date?
    public var entrySize: UInt64?
}

/// How symbolic links found in archives are handled.
public enum ExtractionLinkPolicy: String, Codable, Sendable, CaseIterable {
    /// Create links whose target stays inside the destination; block the rest. Default.
    case preserveSafe
    /// Never create links.
    case skip
    /// Create every link as stored (trusted archives only). Writes still never follow links.
    case preserveAll
}

public struct ExtractionOptions: Sendable {
    public var conflictPolicy: ConflictPolicy
    /// Consulted when `conflictPolicy == .ask`. Returns the decision and whether to apply it to all.
    public var conflictResolver: (@Sendable (ConflictInfo) -> (ConflictDecision, Bool))?
    public var linkPolicy: ExtractionLinkPolicy
    public var restorePermissions: Bool
    public var restoreTimestamps: Bool
    public var restoreExtendedAttributes: Bool
    /// Copy the archive's quarantine attribute to extracted files (macOS Gatekeeper behaviour).
    public var quarantineSource: URL?
    /// Skip `__MACOSX/` folders and `._` AppleDouble files. Skips are listed in the report.
    public var skipAppleDoubleArtifacts: Bool
    public var limits: SafetyLimits
    public var normalization: UnicodeNormalization
    /// Size of the archive on disk, for the expansion-ratio limit.
    public var archiveSize: UInt64

    public init(conflictPolicy: ConflictPolicy = .keepBoth,
                conflictResolver: (@Sendable (ConflictInfo) -> (ConflictDecision, Bool))? = nil,
                linkPolicy: ExtractionLinkPolicy = .preserveSafe,
                restorePermissions: Bool = true, restoreTimestamps: Bool = true,
                restoreExtendedAttributes: Bool = true, quarantineSource: URL? = nil,
                skipAppleDoubleArtifacts: Bool = true, limits: SafetyLimits = .default,
                normalization: UnicodeNormalization = .none, archiveSize: UInt64 = 0) {
        self.conflictPolicy = conflictPolicy
        self.conflictResolver = conflictResolver
        self.linkPolicy = linkPolicy
        self.restorePermissions = restorePermissions
        self.restoreTimestamps = restoreTimestamps
        self.restoreExtendedAttributes = restoreExtendedAttributes
        self.quarantineSource = quarantineSource
        self.skipAppleDoubleArtifacts = skipAppleDoubleArtifacts
        self.limits = limits
        self.normalization = normalization
        self.archiveSize = archiveSize
    }
}

/// What happened during an extraction.
public struct ExtractionReport: Codable, Sendable {
    public struct Item: Codable, Sendable, Hashable {
        public var path: String
        public var reason: String
    }
    public struct Rename: Codable, Sendable, Hashable {
        public var archivePath: String
        public var writtenAs: String
    }

    public var destination: String
    public var filesWritten = 0
    public var directoriesCreated = 0
    public var symlinksCreated = 0
    public var hardlinksCreated = 0
    public var bytesWritten: UInt64 = 0
    public var skipped: [Item] = []
    /// Entries refused for security reasons.
    public var blocked: [Item] = []
    public var renamed: [Rename] = []
    public var replaced: [String] = []
    /// Extracted items that can run code (apps, executables, scripts, installers). Never executed.
    public var potentiallyExecutable: [String] = []
    public var warnings: [String] = []
    /// Relative paths (inside the destination) of every regular file written.
    public var writtenFiles: [String] = []
    /// Distinct top-level names created in the destination.
    public var topLevelItems: [String] = []
    public var engine: String?

    public init(destination: String) { self.destination = destination }
}

/// The only component that writes extracted data to disk.
///
/// Guarantees:
/// * every path is validated by `SafePath` and resolved component-by-component with `O_NOFOLLOW`,
///   so neither `..` nor symbolic links (pre-existing or created by the archive) can redirect a write
///   outside the destination;
/// * files are written to a temporary name and moved into place only when complete;
/// * existing files are never overwritten unless the conflict policy says so, and directories are
///   never deleted;
/// * size, count, ratio, disk-space and time limits are enforced on bytes actually produced;
/// * set-user-ID, set-group-ID and sticky bits are stripped; device nodes and FIFOs are never created.
public final class SafeExtractionSink: ExtractionSink {
    public let destination: URL
    public private(set) var options: ExtractionOptions
    public private(set) var report: ExtractionReport

    private let rootFD: Int32
    private var dirCache: [String: Int32] = [:]
    /// Archive directory path → renamed final component path (for keep-both directory conflicts).
    private var dirRemap: [String: [String]] = [:]
    /// Normalised archive path → final components (for hard links).
    private var finalPaths: [String: [String]] = [:]
    private var deferredDirs: [(components: [String], entry: ArchiveEntry)] = []
    private var createdDirs = Set<String>()
    private var topLevel = Set<String>()
    private var stickyDecision: ConflictDecision?
    private var entryCount = 0
    private var totalBytes: UInt64 = 0
    private var bytesSinceSpaceCheck: UInt64 = 0
    private let startTime = Date()
    private let quarantine: [UInt8]?
    private var activeWriter: FileWriter?
    private let progress: OperationProgress?

    public init(destination: URL, options: ExtractionOptions = ExtractionOptions(), progress: OperationProgress? = nil) throws {
        self.destination = destination
        self.options = options
        self.progress = progress
        self.report = ExtractionReport(destination: destination.path)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.permissionDenied(path: destination.path)
        }
        let fd = POSIX.openRoot(destination.path)
        guard fd >= 0 else {
            throw ArchiveError.io(path: destination.path, code: errno, message: POSIX.errorMessage(errno))
        }
        rootFD = fd
        quarantine = options.quarantineSource.flatMap { POSIX.getXattr(path: $0.path, name: "com.apple.quarantine") }
        if let free = POSIX.availableBytes(fd: fd), free < options.limits.minimumFreeSpace {
            close(fd)
            throw ArchiveError.insufficientSpace(needed: options.limits.minimumFreeSpace, available: free)
        }
    }

    deinit {
        activeWriter?.abort()
        for fd in dirCache.values { close(fd) }
        close(rootFD)
    }

    /// Discards a partially written entry (used when the engine fails mid-entry or is cancelled).
    public func abortActive() {
        activeWriter?.abort()
        activeWriter = nil
    }

    // MARK: ExtractionSink

    public func begin(_ entry: ArchiveEntry, extras: EntryExtras) throws -> EntryDataWriter? {
        if let w = activeWriter { w.abort(); activeWriter = nil }
        if dirCache.count > 256 {
            // Bound descriptor usage; safe here because no writer holds a cached descriptor.
            for fd in dirCache.values { close(fd) }
            dirCache.removeAll()
        }
        try progress?.checkCancelled()
        if let maxDuration = options.limits.maxDuration, Date().timeIntervalSince(startTime) > maxDuration {
            throw ArchiveError.safetyLimitExceeded(.duration, limit: UInt64(maxDuration), observed: UInt64(Date().timeIntervalSince(startTime)))
        }
        entryCount += 1
        if entryCount > options.limits.maxEntryCount {
            throw ArchiveError.safetyLimitExceeded(.entryCount, limit: UInt64(options.limits.maxEntryCount), observed: UInt64(entryCount))
        }
        progress?.setCurrentItem(entry.normalizedPath)

        let components: [String]
        do {
            components = try SafePath.components(of: entry.path, normalization: options.normalization)
        } catch let r as SafePath.Rejection {
            if r == .empty { return nil }   // "./" or "/" — nothing to create
            report.blocked.append(.init(path: entry.path, reason: r.description))
            progress?.warning()
            return nil
        }

        if options.skipAppleDoubleArtifacts, isAppleDoubleArtifact(components) {
            report.skipped.append(.init(path: entry.path, reason: "macOS resource-fork metadata (__MACOSX / ._ file)"))
            return nil
        }

        if let declared = entry.uncompressedSize, declared > options.limits.maxEntryBytes {
            throw ArchiveError.safetyLimitExceeded(.entrySize, limit: options.limits.maxEntryBytes, observed: declared)
        }

        switch entry.type {
        case .directory:
            try ensureDirectory(components: components, archivePath: entry.normalizedPath)
            deferredDirs.append((try mappedComponents(components), entry))
            return nil
        case .file:
            return try beginFile(entry, components: components, extras: extras)
        case .symlink:
            try createSymlink(entry, components: components)
            return nil
        case .hardlink:
            try createHardlink(entry, components: components)
            return nil
        case .special:
            report.skipped.append(.init(path: entry.path, reason: "device, FIFO or socket entries are never created"))
            return nil
        }
    }

    public func finish() throws {
        if let w = activeWriter { w.abort(); activeWriter = nil }
        // Apply directory metadata deepest-first, after their contents were written.
        for (comps, entry) in deferredDirs.sorted(by: { $0.components.count > $1.components.count }) {
            guard let fd = try? openDirectory(comps, create: false) else { continue }
            if options.restorePermissions, let p = entry.permissions {
                _ = fchmod(fd, mode_t(p & 0o777) | 0o700)
            }
            if options.restoreTimestamps {
                POSIX.setTimes(fd: fd, modification: entry.modificationDate, access: entry.accessDate)
            }
        }
        report.topLevelItems = topLevel.sorted()
        for fd in dirCache.values { close(fd) }
        dirCache.removeAll()
    }

    // MARK: Files

    private func beginFile(_ entry: ArchiveEntry, components: [String], extras: EntryExtras) throws -> EntryDataWriter? {
        let parentComps = Array(components.dropLast())
        let parentFD: Int32
        let mappedParent: [String]
        do {
            mappedParent = try mappedComponents(parentComps)
            parentFD = try openDirectory(mappedParent, create: true)
        } catch let e as BlockedPath {
            report.blocked.append(.init(path: entry.path, reason: e.reason))
            progress?.warning()
            return nil
        }
        var name = components.last!
        var replaceExisting = false

        if let existing = POSIX.lstatAt(parentFD, name) {
            let info = ConflictInfo(archivePath: entry.normalizedPath,
                                    existingPath: (mappedParent + [name]).joined(separator: "/"),
                                    existingIsDirectory: existing.isDirectory, existingModified: existing.mtime,
                                    existingSize: existing.size, entryModified: entry.modificationDate,
                                    entrySize: entry.uncompressedSize)
            var decision = decide(info)
            if decision == .replace, existing.isDirectory { decision = .keepBoth } // never delete folders
            switch decision {
            case .skip:
                report.skipped.append(.init(path: entry.path, reason: "an item with the same name already exists"))
                return nil
            case .replace:
                replaceExisting = true
            case .keepBoth:
                name = uniqueName(for: name, in: parentFD)
                report.renamed.append(.init(archivePath: entry.normalizedPath, writtenAs: (mappedParent + [name]).joined(separator: "/")))
            }
        }

        let tmp = ".ua-\(POSIX.randomToken()).partial"
        let fd = POSIX.createExclusive(at: parentFD, tmp)
        guard fd >= 0 else {
            let code = errno
            if code == EACCES || code == EPERM { throw ArchiveError.permissionDenied(path: destination.appendingPathComponent(mappedParent.joined(separator: "/")).path) }
            throw ArchiveError.io(path: (mappedParent + [name]).joined(separator: "/"), code: code, message: POSIX.errorMessage(code))
        }
        let finalComponents = mappedParent + [name]
        let writer = FileWriter(sink: self, fd: fd, parentFD: parentFD, tmpName: tmp, finalName: name,
                                finalComponents: finalComponents, entry: entry, extras: extras, replace: replaceExisting)
        activeWriter = writer
        return writer
    }

    fileprivate func account(bytes: Int, entryTotal: UInt64, fd: Int32) throws {
        let n = UInt64(bytes)
        totalBytes += n
        bytesSinceSpaceCheck += n
        progress?.add(output: n)
        let lim = options.limits
        if entryTotal > lim.maxEntryBytes {
            throw ArchiveError.safetyLimitExceeded(.entrySize, limit: lim.maxEntryBytes, observed: entryTotal)
        }
        if totalBytes > lim.maxTotalBytes {
            throw ArchiveError.safetyLimitExceeded(.totalSize, limit: lim.maxTotalBytes, observed: totalBytes)
        }
        if totalBytes > lim.ratioGraceBytes, options.archiveSize > 0 {
            let ratio = totalBytes / max(1, options.archiveSize)
            if ratio > lim.maxExpansionRatio {
                throw ArchiveError.safetyLimitExceeded(.expansionRatio, limit: lim.maxExpansionRatio, observed: ratio)
            }
        }
        if bytesSinceSpaceCheck >= 64 << 20 {
            bytesSinceSpaceCheck = 0
            if let free = POSIX.availableBytes(fd: fd), free < lim.minimumFreeSpace {
                throw ArchiveError.insufficientSpace(needed: lim.minimumFreeSpace, available: free)
            }
            if let maxDuration = lim.maxDuration, Date().timeIntervalSince(startTime) > maxDuration {
                throw ArchiveError.safetyLimitExceeded(.duration, limit: UInt64(maxDuration), observed: UInt64(Date().timeIntervalSince(startTime)))
            }
            try progress?.checkCancelled()
        }
    }

    fileprivate func completed(_ w: FileWriter, bytes: UInt64, header: [UInt8]) {
        activeWriter = nil
        report.filesWritten += 1
        report.bytesWritten += bytes
        let rel = w.finalComponents.joined(separator: "/")
        report.writtenFiles.append(rel)
        if w.replace { report.replaced.append(rel) }
        finalPaths[w.entry.normalizedPath] = w.finalComponents
        topLevel.insert(w.finalComponents[0])
        if ExecutableContent.isPotentiallyExecutable(path: rel, permissions: w.entry.permissions, header: header) {
            report.potentiallyExecutable.append(rel)
        }
        progress?.itemCompleted()
    }

    fileprivate func writerFinished(_ w: FileWriter) {
        if activeWriter === w { activeWriter = nil }
    }

    fileprivate func applyFileMetadata(fd: Int32, entry: ArchiveEntry, extras: EntryExtras) {
        if options.restorePermissions, let p = entry.permissions {
            _ = fchmod(fd, (mode_t(p) & 0o777) | 0o400)
        } else {
            _ = fchmod(fd, 0o644)
        }
        if options.restoreExtendedAttributes {
            for (name, value) in extras.extendedAttributes where name != "com.apple.quarantine" {
                POSIX.setXattr(fd: fd, name: name, value: value)
            }
        }
        if let q = quarantine { POSIX.setXattr(fd: fd, name: "com.apple.quarantine", value: q) }
        if options.restoreTimestamps {
            POSIX.setTimes(fd: fd, modification: entry.modificationDate, access: entry.accessDate)
        }
    }

    // MARK: Directories

    private struct BlockedPath: Error { let reason: String }

    /// Applies keep-both renames of parent directories.
    private func mappedComponents(_ comps: [String]) throws -> [String] {
        var out: [String] = []
        for (i, c) in comps.enumerated() {
            let key = comps[0...i].joined(separator: "/")
            if let mapped = dirRemap[key] { out = mapped } else { out.append(c) }
        }
        return out
    }

    private func ensureDirectory(components: [String], archivePath: String) throws {
        do {
            let mapped = try mappedComponents(components)
            _ = try openDirectory(mapped, create: true, originalComponents: components)
        } catch let e as BlockedPath {
            report.blocked.append(.init(path: archivePath, reason: e.reason))
            progress?.warning()
        }
    }

    /// Opens (creating as needed) the directory at `comps` below the root without following links.
    private func openDirectory(_ comps: [String], create: Bool, originalComponents: [String]? = nil) throws -> Int32 {
        if comps.isEmpty { return rootFD }
        let key = comps.joined(separator: "/")
        if let fd = dirCache[key] { return fd }
        var fd = rootFD
        var path: [String] = []
        for (i, comp) in comps.enumerated() {
            path.append(comp)
            let k = path.joined(separator: "/")
            if let cached = dirCache[k] { fd = cached; continue }
            var next = POSIX.openDirectory(at: fd, comp)
            if next < 0 {
                let err = errno
                if err == ENOENT, create {
                    if mkdirat(fd, comp, 0o755) != 0, errno != EEXIST {
                        let e = errno
                        throw ArchiveError.io(path: k, code: e, message: POSIX.errorMessage(e))
                    }
                    next = POSIX.openDirectory(at: fd, comp)
                    if next >= 0 {
                        report.directoriesCreated += 1
                        createdDirs.insert(k)
                    }
                } else if err == ELOOP || err == ENOTDIR {
                    // Something that isn't a real directory is in the way.
                    if let st = POSIX.lstatAt(fd, comp), st.isSymlink {
                        throw BlockedPath(reason: "path passes through a symbolic link (“\(k)”)")
                    }
                    // A regular file with the same name: keep both by renaming this directory.
                    guard create else { throw BlockedPath(reason: "“\(k)” is not a folder") }
                    let newName = uniqueName(for: comp, in: fd)
                    if mkdirat(fd, newName, 0o755) != 0 {
                        let e = errno
                        throw ArchiveError.io(path: k, code: e, message: POSIX.errorMessage(e))
                    }
                    next = POSIX.openDirectory(at: fd, newName)
                    path[path.count - 1] = newName
                    let origKey = (originalComponents ?? comps)[0...i].joined(separator: "/")
                    dirRemap[origKey] = path
                    report.renamed.append(.init(archivePath: origKey, writtenAs: path.joined(separator: "/")))
                    report.directoriesCreated += 1
                }
            }
            guard next >= 0 else {
                let e = errno
                if e == EACCES || e == EPERM { throw ArchiveError.permissionDenied(path: destination.appendingPathComponent(k).path) }
                throw ArchiveError.io(path: k, code: e, message: POSIX.errorMessage(e))
            }
            dirCache[path.joined(separator: "/")] = next
            fd = next
        }
        topLevel.insert(path[0])
        return fd
    }

    // MARK: Links

    private func createSymlink(_ entry: ArchiveEntry, components: [String]) throws {
        guard let target = entry.linkTarget, !target.isEmpty else {
            report.skipped.append(.init(path: entry.path, reason: "symbolic link without a target"))
            return
        }
        switch options.linkPolicy {
        case .skip:
            report.skipped.append(.init(path: entry.path, reason: "symbolic links are disabled"))
            return
        case .preserveSafe:
            if SafePath.resolveLinkTarget(target, linkParent: Array(components.dropLast())) == nil {
                report.blocked.append(.init(path: entry.path, reason: "symbolic link points outside the destination (“\(target)”)"))
                progress?.warning()
                return
            }
        case .preserveAll:
            break
        }
        let parentFD: Int32
        let mappedParent: [String]
        do {
            mappedParent = try mappedComponents(Array(components.dropLast()))
            parentFD = try openDirectory(mappedParent, create: true)
        } catch let e as BlockedPath {
            report.blocked.append(.init(path: entry.path, reason: e.reason))
            return
        }
        var name = components.last!
        if POSIX.lstatAt(parentFD, name) != nil {
            // Links never replace existing items.
            name = uniqueName(for: name, in: parentFD)
            report.renamed.append(.init(archivePath: entry.normalizedPath, writtenAs: (mappedParent + [name]).joined(separator: "/")))
        }
        if symlinkat(target, parentFD, name) != 0 {
            report.warnings.append("Could not create link “\(entry.normalizedPath)”: \(POSIX.errorMessage(errno))")
            return
        }
        report.symlinksCreated += 1
        topLevel.insert((mappedParent + [name])[0])
        finalPaths[entry.normalizedPath] = mappedParent + [name]
    }

    private func createHardlink(_ entry: ArchiveEntry, components: [String]) throws {
        guard let target = entry.linkTarget,
              let targetComps = try? SafePath.components(of: target, normalization: options.normalization),
              let finalTarget = finalPaths[targetComps.joined(separator: "/")] ?? finalPaths[ArchivePath.normalizeForDisplay(target)]
        else {
            report.blocked.append(.init(path: entry.path, reason: "hard link target is not a file extracted from this archive"))
            return
        }
        let mappedParent = try mappedComponents(Array(components.dropLast()))
        let parentFD: Int32
        let targetParentFD: Int32
        do {
            parentFD = try openDirectory(mappedParent, create: true)
            targetParentFD = try openDirectory(Array(finalTarget.dropLast()), create: false)
        } catch let e as BlockedPath {
            report.blocked.append(.init(path: entry.path, reason: e.reason))
            return
        }
        var name = components.last!
        if POSIX.lstatAt(parentFD, name) != nil {
            name = uniqueName(for: name, in: parentFD)
            report.renamed.append(.init(archivePath: entry.normalizedPath, writtenAs: (mappedParent + [name]).joined(separator: "/")))
        }
        if linkat(targetParentFD, finalTarget.last!, parentFD, name, 0) != 0 {
            report.warnings.append("Could not create hard link “\(entry.normalizedPath)”: \(POSIX.errorMessage(errno))")
            return
        }
        report.hardlinksCreated += 1
        finalPaths[entry.normalizedPath] = mappedParent + [name]
    }

    // MARK: Helpers

    private func decide(_ info: ConflictInfo) -> ConflictDecision {
        if let d = stickyDecision { return d }
        switch options.conflictPolicy {
        case .keepBoth: return .keepBoth
        case .replace: return .replace
        case .skip: return .skip
        case .replaceIfOlder:
            if let a = info.entryModified, let b = info.existingModified { return a > b ? .replace : .skip }
            return .skip
        case .ask:
            guard let resolver = options.conflictResolver else { return .keepBoth }
            let (d, all) = resolver(info)
            if all { stickyDecision = d }
            return d
        }
    }

    private func uniqueName(for name: String, in dirfd: Int32) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        for i in 2..<100_000 {
            let candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            if POSIX.lstatAt(dirfd, candidate) == nil { return candidate }
        }
        return "\(stem) \(POSIX.randomToken())" + (ext.isEmpty ? "" : ".\(ext)")
    }

    private func isAppleDoubleArtifact(_ comps: [String]) -> Bool {
        if comps.first == "__MACOSX" { return true }
        if let last = comps.last, last.hasPrefix("._"), last.count > 2 { return true }
        return false
    }

    // MARK: Writer

    final class FileWriter: EntryDataWriter {
        weak var sink: SafeExtractionSink?
        let fd: Int32
        let parentFD: Int32
        let tmpName: String
        let finalName: String
        let finalComponents: [String]
        let entry: ArchiveEntry
        let extras: EntryExtras
        let replace: Bool
        var written: UInt64 = 0
        var header: [UInt8] = []
        var closed = false

        init(sink: SafeExtractionSink, fd: Int32, parentFD: Int32, tmpName: String, finalName: String,
             finalComponents: [String], entry: ArchiveEntry, extras: EntryExtras, replace: Bool) {
            self.sink = sink
            self.fd = fd
            self.parentFD = parentFD
            self.tmpName = tmpName
            self.finalName = finalName
            self.finalComponents = finalComponents
            self.entry = entry
            self.extras = extras
            self.replace = replace
        }

        func write(_ bytes: UnsafeRawBufferPointer) throws {
            guard !closed, bytes.count > 0, let base = bytes.baseAddress else { return }
            if header.count < 8 { header.append(contentsOf: bytes.prefix(8 - header.count)) }
            written += UInt64(bytes.count)
            try sink?.account(bytes: bytes.count, entryTotal: written, fd: fd)
            var off = 0
            while off < bytes.count {
                let n = Foundation.write(fd, base.advanced(by: off), bytes.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    let e = errno
                    if e == ENOSPC { throw ArchiveError.insufficientSpace(needed: written, available: 0) }
                    throw ArchiveError.io(path: finalComponents.joined(separator: "/"), code: e, message: POSIX.errorMessage(e))
                }
                off += n
            }
        }

        func commit() throws {
            guard !closed, let sink else { return }
            sink.applyFileMetadata(fd: fd, entry: entry, extras: extras)
            closed = true
            if close(fd) != 0 {
                let e = errno
                _ = unlinkat(parentFD, tmpName, 0)
                sink.writerFinished(self)
                throw ArchiveError.io(path: finalComponents.joined(separator: "/"), code: e, message: POSIX.errorMessage(e))
            }
            if replace {
                guard renameat(parentFD, tmpName, parentFD, finalName) == 0 else {
                    let e = errno
                    _ = unlinkat(parentFD, tmpName, 0)
                    sink.writerFinished(self)
                    throw ArchiveError.io(path: finalComponents.joined(separator: "/"), code: e, message: POSIX.errorMessage(e))
                }
            } else {
                // Atomic "create only if absent": link then unlink. Falls back to a checked rename on
                // filesystems without hard links (FAT/exFAT).
                if linkat(parentFD, tmpName, parentFD, finalName, 0) == 0 {
                    _ = unlinkat(parentFD, tmpName, 0)
                } else if errno == EEXIST {
                    _ = unlinkat(parentFD, tmpName, 0)
                    sink.writerFinished(self)
                    throw ArchiveError.destinationExists(path: finalComponents.joined(separator: "/"))
                } else {
                    guard POSIX.lstatAt(parentFD, finalName) == nil, renameat(parentFD, tmpName, parentFD, finalName) == 0 else {
                        let e = errno
                        _ = unlinkat(parentFD, tmpName, 0)
                        sink.writerFinished(self)
                        throw ArchiveError.io(path: finalComponents.joined(separator: "/"), code: e, message: POSIX.errorMessage(e))
                    }
                }
            }
            sink.completed(self, bytes: written, header: header)
        }

        func abort() {
            guard !closed else { return }
            closed = true
            close(fd)
            _ = unlinkat(parentFD, tmpName, 0)
            sink?.writerFinished(self)
        }

        deinit { abort() }
    }
}

/// Heuristics for content that can run code. This is a warning aid, not malware detection.
public enum ExecutableContent {
    public static let riskyExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "fish", "pl", "py", "rb", "php",
        "scpt", "scptd", "applescript", "workflow", "action", "terminal", "pkg", "mpkg", "dmg",
        "jar", "exe", "msi", "bat", "cmd", "com", "ps1", "vbs", "js", "jse", "wsf", "scr", "dylib",
        "so", "kext", "plugin", "bundle", "osax", "prefpane", "saver", "webloc", "inetloc", "fileloc",
    ]

    public static func isPotentiallyExecutable(path: String, permissions: UInt16?, header: [UInt8]) -> Bool {
        let comps = path.split(separator: "/")
        if comps.contains(where: { $0.lowercased().hasSuffix(".app") }) { return true }
        let ext = (path as NSString).pathExtension.lowercased()
        if riskyExtensions.contains(ext) { return true }
        if let p = permissions, p & 0o111 != 0 { return true }
        if header.count >= 2, header[0] == 0x23, header[1] == 0x21 { return true } // "#!"
        if header.count >= 4 {
            let magic = UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3])
            let machO: Set<UInt32> = [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA]
            if machO.contains(magic) { return true }
            if header[0] == 0x7F, header[1] == 0x45, header[2] == 0x4C, header[3] == 0x46 { return true } // ELF
            if header[0] == 0x4D, header[1] == 0x5A { return true } // PE "MZ"
        }
        return false
    }
}
