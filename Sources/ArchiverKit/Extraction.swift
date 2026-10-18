import Foundation
import ArchiveCore
import ArchiveEngines

/// How extracted items are placed in the destination folder.
public enum ExtractionMode: String, Codable, Sendable, CaseIterable {
    /// Put the archive's contents directly into the destination (merging folders, applying the
    /// conflict policy to files).
    case here
    /// Always create a folder named after the archive.
    case newFolder
    /// Create a folder only when the archive has more than one top-level item. Default.
    case smart

    public var displayName: String {
        switch self {
        case .here: return "Extract Here"
        case .newFolder: return "Extract to New Folder"
        case .smart: return "Smart Extract"
        }
    }
}

public struct ExtractRequest: Sendable {
    public var archive: URL
    /// Folder that receives the result. Defaults to the archive's folder.
    public var destination: URL?
    public var mode: ExtractionMode
    public var selection: EntrySelection
    public var options: ExtractionOptions
    public var readOptions: ReadOptions
    /// Extract archives found inside the archive, up to `options.limits.maxNestingDepth` levels.
    public var extractNestedArchives: Bool
    /// Compare the result with the archive's listing (sizes of every extracted file).
    public var verifyAfterExtraction: Bool
    /// Move the archive (all volumes) to the Trash after a fully verified extraction. Off by default.
    public var trashArchiveAfterVerification: Bool

    public init(archive: URL, destination: URL? = nil, mode: ExtractionMode = .smart, selection: EntrySelection = .all,
                options: ExtractionOptions = ExtractionOptions(), readOptions: ReadOptions = ReadOptions(),
                extractNestedArchives: Bool = false, verifyAfterExtraction: Bool = false, trashArchiveAfterVerification: Bool = false) {
        self.archive = archive
        self.destination = destination
        self.mode = mode
        self.selection = selection
        self.options = options
        self.readOptions = readOptions
        self.extractNestedArchives = extractNestedArchives
        self.verifyAfterExtraction = verifyAfterExtraction
        self.trashArchiveAfterVerification = trashArchiveAfterVerification
    }
}

public struct VerificationSummary: Codable, Sendable {
    public var filesChecked: Int
    public var mismatches: [String]
    public var passed: Bool { mismatches.isEmpty }
}

public struct ExtractionOutcome: Sendable {
    /// Items created in the destination folder (the new folder, or the top-level items).
    public var createdItems: [URL]
    public var destination: URL
    public var report: ExtractionReport
    public var engine: EngineID
    public var engineNotes: [String]
    public var verification: VerificationSummary?
    public var trashed: [URL]
    public var nested: [ExtractionOutcome]
    public var warnings: [String]
}

extension ArchiveService {
    /// Name for the folder that holds an archive's contents: "Project.tar.gz" → "Project",
    /// "backup.part1.rar" → "backup".
    public static func baseName(for archive: URL) -> String {
        if let mp = MultipartDetector.detect(archive) {
            let b = mp.baseName
            if let m = FormatCatalog.matchExtension(of: b), b.count > m.ext.count + 1 { return String(b.dropLast(m.ext.count + 1)) }
            return b
        }
        let name = archive.lastPathComponent
        if let m = FormatCatalog.matchExtension(of: name), name.count > m.ext.count + 1 {
            return String(name.dropLast(m.ext.count + 1))
        }
        let stripped = archive.deletingPathExtension().lastPathComponent
        return stripped.isEmpty ? name : stripped
    }

    /// Returns a URL in `dir` named `name` (or "name 2", "name 3"…) that does not exist yet.
    public static func uniqueURL(in dir: URL, name: String, isDirectory: Bool = false) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name, isDirectory: isDirectory)
        if !fm.fileExists(atPath: candidate.path) && (try? fm.destinationOfSymbolicLink(atPath: candidate.path)) == nil { return candidate }
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        // Keep compound extensions together ("Archive 2.tar.gz").
        var stem = isDirectory || ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var fullExt = ext
        if !isDirectory, let m = FormatCatalog.matchExtension(of: name), m.ext.contains(".") {
            stem = String(name.dropLast(m.ext.count + 1))
            fullExt = String(name.suffix(m.ext.count))
        }
        for i in 2..<100_000 {
            let n = fullExt.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(fullExt)"
            candidate = dir.appendingPathComponent(n, isDirectory: isDirectory)
            if !fm.fileExists(atPath: candidate.path) && (try? fm.destinationOfSymbolicLink(atPath: candidate.path)) == nil { return candidate }
        }
        return dir.appendingPathComponent("\(stem) \(UUID().uuidString)")
    }

    static func freeSpace(at url: URL) -> UInt64? {
        #if os(macOS)
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]), let c = v.volumeAvailableCapacityForImportantUsage {
            return UInt64(c)
        }
        #endif
        var s = statvfs()
        guard statvfs(url.path, &s) == 0 else { return nil }
        return UInt64(s.f_bavail) * UInt64(s.f_frsize)
    }

    /// Indexed formats can be listed cheaply before extraction (for space checks and verification).
    static func isCheaplyListable(_ format: FormatID) -> Bool {
        let container = FormatCatalog.descriptor(for: format)?.effectiveContainer ?? format
        return [.zip, .sevenZip, .rar, .xar, .iso, .cab, .dmg, .appleArchive].contains(container)
    }

    // MARK: Extract

    public func extract(_ request: ExtractRequest, progress: OperationProgress = OperationProgress()) throws -> ExtractionOutcome {
        try extract(request, progress: progress, depth: 0)
    }

    func extract(_ request: ExtractRequest, progress: OperationProgress, depth: Int) throws -> ExtractionOutcome {
        let fm = FileManager.default
        let detection = try detect(request.archive)
        if let mp = detection.multipart, !mp.isComplete { throw ArchiveError.missingVolume(expected: mp.missing) }
        let source = detection.source(for: request.archive)
        let parent = request.destination ?? request.archive.deletingLastPathComponent()
        do { try fm.createDirectory(at: parent, withIntermediateDirectories: true) } catch {
            throw ArchiveError.permissionDenied(path: parent.path)
        }
        guard fm.isWritableFile(atPath: parent.path) else { throw ArchiveError.permissionDenied(path: parent.path) }
        var warnings: [String] = []

        // Optional listing: cheap for indexed formats; required for verification.
        var listing: ArchiveListing?
        var notes: [String] = []
        if request.verifyAfterExtraction || Self.isCheaplyListable(detection.format) {
            listing = try? withEngines(for: detection.format, EngineRequirements(operations: .inspect), notes: &notes) {
                try $0.list(source, options: request.readOptions, progress: OperationProgress())
            }.0
            if let total = listing?.totalUncompressedSize, let free = Self.freeSpace(at: parent),
               total + request.options.limits.minimumFreeSpace > free, request.selection == .all {
                throw ArchiveError.insufficientSpace(needed: total, available: free)
            }
        }

        var options = request.options
        options.archiveSize = source.totalSize
        #if os(macOS)
        if options.quarantineSource == nil { options.quarantineSource = request.archive }
        #endif
        progress.setPhase("Extracting")
        if let t = listing?.totalUncompressedSize { progress.setTotal(bytes: source.totalSize, items: listing?.fileCount) ; _ = t }

        // Every attempt extracts into a fresh private staging folder on the destination volume, so a
        // failed attempt (or a fallback to another engine) never leaves partial output behind.
        var stagingURL: URL?
        var stageReport: ExtractionReport?
        let req = EngineRequirements(operations: .extract)
        let engineID: EngineID
        do {
            (_, engineID) = try withEngines(for: detection.format, req, notes: &notes) { engine -> Void in
                let staging = parent.appendingPathComponent(".ua-extract-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                do {
                    var stageOptions = options
                    stageOptions.conflictPolicy = .keepBoth
                    let sink = try SafeExtractionSink(destination: staging, options: stageOptions, progress: progress)
                    do {
                        try engine.extract(source, selection: request.selection, into: sink, options: request.readOptions, progress: progress)
                        try sink.finish()
                    } catch {
                        sink.abortActive()
                        throw error
                    }
                    var r = sink.report
                    r.engine = engine.descriptor.name
                    stageReport = r
                    stagingURL = staging
                } catch {
                    try? fm.removeItem(at: staging)
                    throw error
                }
            }
        } catch let e as ArchiveError {
            throw Self.reframeUnrecognised(e, detection: detection, url: request.archive)
        }
        guard let staging = stagingURL, var report = stageReport else { throw ArchiveError.internalError("extraction produced no result") }
        defer { try? fm.removeItem(at: staging) }

        // Restore the staging folder's permissions before it becomes user-visible.
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        let top = ((try? fm.contentsOfDirectory(atPath: staging.path)) ?? []).sorted()
        var created: [URL] = []
        var finalRoot = parent
        let base = Self.baseName(for: request.archive)

        switch request.mode {
        case .newFolder:
            fallthrough
        case .smart where top.count != 1:
            let folder = Self.uniqueURL(in: parent, name: base, isDirectory: true)
            try fm.moveItem(at: staging, to: folder)
            created = [folder]
            finalRoot = folder
        case .smart:
            // A single top-level item (usually a folder): move it up instead of nesting it.
            let item = staging.appendingPathComponent(top[0])
            let dest = Self.uniqueURL(in: parent, name: top[0], isDirectory: (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            try fm.moveItem(at: item, to: dest)
            created = [dest]
            if dest.lastPathComponent != top[0] {
                warnings.append("“\(top[0])” already existed, so the extracted item was named “\(dest.lastPathComponent)”.")
            }
            report.writtenFiles = report.writtenFiles.map { p in
                p == top[0] ? dest.lastPathComponent : (p.hasPrefix(top[0] + "/") ? dest.lastPathComponent + String(p.dropFirst(top[0].count)) : p)
            }
        case .here:
            // Merge into the destination through a second safe sink that applies the user's
            // conflict policy; files are renamed into place, not copied.
            let merge = try SafeExtractionSink(destination: parent, options: options, progress: progress)
            try StagingImporter.importTree(staging, into: merge, progress: progress)
            try merge.finish()
            let m = merge.report
            report.skipped += m.skipped
            report.blocked += m.blocked
            report.renamed += m.renamed
            report.replaced = m.replaced
            report.writtenFiles = m.writtenFiles
            created = m.topLevelItems.map { parent.appendingPathComponent($0) }
        }
        if request.mode == .newFolder || (request.mode == .smart && top.count != 1) {
            report.writtenFiles = report.writtenFiles.map { finalRoot.lastPathComponent + "/" + $0 }
        }
        report.destination = parent.path
        report.topLevelItems = created.map(\.lastPathComponent)

        // Verification against the listing.
        var verification: VerificationSummary?
        if request.verifyAfterExtraction, let listing {
            verification = verify(listing: listing, selection: request.selection, report: report, parent: parent, created: created, mode: request.mode, top: top)
            if verification?.passed == false { warnings.append("Verification found \(verification!.mismatches.count) problem(s).") }
        }

        // Optional: trash the archive once everything verifiably arrived.
        var trashed: [URL] = []
        if request.trashArchiveAfterVerification {
            if let v = verification, v.passed, report.blocked.isEmpty, report.skipped.filter({ !$0.reason.contains("macOS resource-fork") }).isEmpty, request.selection == .all {
                #if os(macOS)
                for vol in source.volumes {
                    var out: NSURL?
                    if (try? fm.trashItem(at: vol, resultingItemURL: &out)) != nil { trashed.append(vol) }
                }
                #else
                warnings.append("Moving the archive to the Trash is only available on macOS.")
                #endif
            } else {
                warnings.append("The archive was kept because the extraction could not be fully verified.")
            }
        }

        // Nested archives (bounded).
        var nested: [ExtractionOutcome] = []
        if request.extractNestedArchives, depth < request.options.limits.maxNestingDepth {
            var limits = request.options.limits
            limits.maxTotalBytes = limits.maxTotalBytes > report.bytesWritten ? limits.maxTotalBytes - report.bytesWritten : 0
            for rel in report.writtenFiles {
                try progress.checkCancelled()
                let url = parent.appendingPathComponent(rel)
                guard let d = try? FormatDetector.detect(url), d.basis == .contentAndExtension,
                      let kind = d.descriptor?.kind, [.archive, .compressedArchive, .compressionStream].contains(kind) else { continue }
                var sub = request
                sub.archive = url
                sub.destination = url.deletingLastPathComponent()
                sub.mode = .smart
                sub.selection = .all
                sub.trashArchiveAfterVerification = false
                sub.options.limits = limits
                do {
                    let o = try extract(sub, progress: progress, depth: depth + 1)
                    nested.append(o)
                    limits.maxTotalBytes = limits.maxTotalBytes > o.report.bytesWritten ? limits.maxTotalBytes - o.report.bytesWritten : 0
                } catch let e as ArchiveError {
                    if case .cancelled = e { throw e }
                    if case .safetyLimitExceeded = e { throw e }
                    warnings.append("Nested archive “\(rel)” was not extracted: \(e.explanation)")
                }
            }
        } else if request.extractNestedArchives {
            warnings.append("Nested archives deeper than \(request.options.limits.maxNestingDepth) levels were not extracted (safety limit).")
        }
        progress.flush()
        return ExtractionOutcome(createdItems: created, destination: parent, report: report, engine: engineID, engineNotes: notes,
                                 verification: verification, trashed: trashed, nested: nested, warnings: warnings)
    }

    func verify(listing: ArchiveListing, selection: EntrySelection, report: ExtractionReport, parent: URL, created: [URL],
                mode: ExtractionMode, top: [String]) -> VerificationSummary {
        var mismatches: [String] = []
        var checked = 0
        let blocked = Set(report.blocked.map { ArchivePath.normalizeForDisplay($0.path) } + report.skipped.map { ArchivePath.normalizeForDisplay($0.path) })
        let renamed = Dictionary(report.renamed.map { ($0.archivePath, $0.writtenAs) }, uniquingKeysWith: { a, _ in a })
        func location(of archivePath: String) -> URL {
            if let r = renamed[archivePath] { return parent.appendingPathComponent(r) }
            switch mode {
            case .here: return parent.appendingPathComponent(archivePath)
            case .newFolder: return created[0].appendingPathComponent(archivePath)
            case .smart:
                if top.count == 1, let first = created.first {
                    let comps = archivePath.split(separator: "/", maxSplits: 1)
                    return comps.count == 2 ? first.appendingPathComponent(String(comps[1])) : first
                }
                return created[0].appendingPathComponent(archivePath)
            }
        }
        for e in listing.entries where e.type == .file && selection.includes(e.path) {
            let p = e.normalizedPath
            if blocked.contains(p) { continue }
            if p.hasPrefix("__MACOSX/") || (p as NSString).lastPathComponent.hasPrefix("._") { continue }
            checked += 1
            let url = location(of: p)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                mismatches.append("\(p): missing after extraction")
                continue
            }
            if let expected = e.uncompressedSize, let actual = (attrs[.size] as? NSNumber)?.uint64Value, expected != actual {
                mismatches.append("\(p): expected \(expected) bytes, found \(actual)")
            }
        }
        return VerificationSummary(filesChecked: checked, mismatches: mismatches)
    }
}
