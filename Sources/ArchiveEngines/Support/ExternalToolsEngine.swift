import Foundation
import ArchiveCore

/// Formats served by their reference command-line tools when the user has them installed
/// (they are not bundled): ZPAQ (`zpaq`, public domain/MIT), lrzip (`lrzip`, GPL — used only as a
/// separate program), lzop (`lzop`, GPL — separate program) and nomarch (ARC/ARK, GPL — separate
/// program; it decodes ARC variants that XADMaster does not).
///
/// Read-only. Output goes to a private staging folder and is imported through the safe sink.
public final class ExternalToolsEngine: ArchiveEngine, @unchecked Sendable {
    public let descriptor: EngineDescriptor
    let zpaq: URL?
    let lrzip: URL?
    let lzop: URL?
    let nomarch: URL?

    public init(zpaq: URL? = HelperLocator.find(["zpaq"]), lrzip: URL? = HelperLocator.find(["lrzip"]), lzop: URL? = HelperLocator.find(["lzop"]),
                nomarch: URL? = HelperLocator.find(["nomarch"])) {
        self.zpaq = zpaq
        self.lrzip = lrzip
        self.lzop = lzop
        self.nomarch = nomarch
        let found = [zpaq, lrzip, lzop, nomarch].compactMap { $0?.lastPathComponent }
        descriptor = EngineDescriptor(
            id: "external-tools", name: "Reference tools (zpaq, lrzip, lzop, nomarch)",
            implementation: "User-installed command-line programs: \(found.isEmpty ? "none found" : found.joined(separator: ", "))",
            version: nil, minimumVersion: nil, license: "Each tool's own license (not bundled; invoked as separate programs)",
            isAvailable: !found.isEmpty,
            unavailableReason: found.isEmpty ? "Install zpaq, lrzip or lzop (e.g. with Homebrew) to open these formats." : nil,
            location: nil,
            isolation: "Separate processes writing only into a private staging folder; results pass through the safe sink.")
    }

    public var supportedFormats: [FormatID] {
        var f: [FormatID] = []
        if zpaq != nil { f.append(.zpaq) }
        if lrzip != nil { f.append(.lrzip) }
        if lzop != nil { f.append(.lzop) }
        if nomarch != nil { f.append(.arc) }
        return f
    }

    public func support(for format: FormatID) -> EngineFormatSupport? {
        guard supportedFormats.contains(format) else { return nil }
        let limits: [String]
        switch format {
        case .zpaq: limits = ["Extracts the latest version stored in the journaling archive."]
        case .arc: limits = ["ARC has no folders; names are restored with their original case."]
        default: limits = ["A compression stream holds exactly one file."]
        }
        return EngineFormatSupport(format: format, operations: [.inspect, .extract, .test], limitations: limits)
    }

    private func tool(for format: FormatID) throws -> URL {
        switch format {
        case .zpaq: if let z = zpaq { return z }
        case .lrzip: if let l = lrzip { return l }
        case .lzop: if let l = lzop { return l }
        case .arc: if let n = nomarch { return n }
        default: break
        }
        throw ArchiveError.engineUnavailable(id, reason: descriptor.unavailableReason ?? "tool not installed")
    }

    private func streamName(_ source: ArchiveSource) -> String {
        let n = source.url.deletingPathExtension().lastPathComponent
        return n.isEmpty ? "data" : n
    }

    public func list(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> ArchiveListing {
        let exe = try tool(for: source.format)
        var entries: [ArchiveEntry] = []
        if source.format == .zpaq {
            let r = try HelperProcess(exe, ["l", source.url.path]).run()
            guard r.status == 0 else { throw ArchiveError.damaged(details: r.combined.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            // "- 2026-10-09 17:17:12          390  0644 simple/HELLO.TXT"
            for line in r.stdout.components(separatedBy: "\n") where line.hasPrefix("- ") {
                let parts = line.dropFirst(2).split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
                guard parts.count == 5 else { continue }
                let path = String(parts[4])
                let isDir = path.hasSuffix("/")
                entries.append(ArchiveEntry(index: entries.count, path: path, type: isDir ? .directory : .file,
                                            uncompressedSize: UInt64(parts[2]), modificationDate: df.date(from: "\(parts[0]) \(parts[1])"),
                                            permissions: UInt16(parts[3], radix: 8)))
            }
        } else if source.format == .arc {
            let r = try HelperProcess(exe, ["-l", "-U", source.url.path]).run()
            guard r.status == 0 else { throw ArchiveError.damaged(details: r.combined.trimmingCharacters(in: .whitespacesAndNewlines)) }
            for line in r.stdout.components(separatedBy: "\n") {
                let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 2, let size = parts[1].split(separator: " ").first.flatMap({ UInt64($0) }) else { continue }
                entries.append(ArchiveEntry(index: entries.count, path: parts[0], type: .file, uncompressedSize: size))
            }
        } else {
            entries = [ArchiveEntry(index: 0, path: streamName(source), type: .file, compressedSize: source.totalSize)]
        }
        return ArchiveListing(properties: ArchiveProperties(format: source.format, formatDescription: FormatCatalog.descriptor(for: source.format)?.name,
                                                            archiveSize: source.totalSize, hasEncryptedEntries: false, engine: id), entries: entries)
    }

    public func extract(_ source: ArchiveSource, selection: EntrySelection, into sink: ExtractionSink, options: ReadOptions, progress: OperationProgress) throws {
        let exe = try tool(for: source.format)
        let destination = (sink as? SafeExtractionSink)?.destination ?? FileManager.default.temporaryDirectory
        let staging = try StagingDirectory(near: destination)
        defer { staging.remove() }
        let args: [String]
        switch source.format {
        case .zpaq: args = ["x", source.url.path, "-to", staging.url.path]
        case .arc: args = ["-U", source.url.path] // extracts into its working directory (the staging folder)
        case .lrzip: args = ["-d", "-q", "-o", staging.url.appendingPathComponent(streamName(source)).path, source.url.path]
        default: args = ["-d", "-q", "-o", staging.url.appendingPathComponent(streamName(source)).path, source.url.path]
        }
        let limits = (sink as? SafeExtractionSink)?.options.limits ?? .default
        let watchdog = DiskWatchdog(path: staging.url.path, minimumFree: limits.minimumFreeSpace, progress: progress)
        watchdog.start()
        defer { watchdog.stop() }
        let p = HelperProcess(exe, args)
        p.workingDirectory = staging.url
        p.progress = progress
        let r: HelperProcess.Result
        do { r = try p.run() } catch ArchiveError.cancelled { throw watchdog.tripped ?? .cancelled }
        if let w = watchdog.tripped { throw w }
        guard r.status == 0 else { throw ArchiveError.damaged(details: r.combined.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let target: ExtractionSink = selection == .all ? sink : FilteringSink(base: sink, selection: selection)
        try StagingImporter.importTree(staging.url, into: target, progress: progress)
    }

    public func test(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> IntegrityReport {
        let exe = try tool(for: source.format)
        let listing = try list(source, options: options, progress: progress)
        let args: [String]
        switch source.format {
        case .zpaq: args = ["x", source.url.path, "-test"]
        case .arc: args = ["-t", source.url.path]
        default: args = ["-t", source.url.path]
        }
        let r = try HelperProcess(exe, args).run()
        var report = IntegrityReport(archive: source.url.lastPathComponent, format: source.format, engine: id)
        report.filesInspected = listing.fileCount
        report.checks = ["Full decode by \(exe.lastPathComponent)"]
        if r.status != 0 { report.issues.append(.init(entry: nil, message: r.combined.trimmingCharacters(in: .whitespacesAndNewlines), code: "damaged")) }
        report.filesVerified = r.status == 0 ? listing.fileCount : 0
        return report
    }
}
