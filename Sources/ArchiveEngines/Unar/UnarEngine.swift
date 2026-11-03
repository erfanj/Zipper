import Foundation
import ArchiveCore

/// Engine for legacy and specialist formats via The Unarchiver's command-line tools (`lsar`, `unar`;
/// XADMaster, LGPL-2.1). Covers StuffIt (classic and 5; StuffIt X partially), Compact Pro, PackIt,
/// DiskDoubler, MacBinary, BinHex, AppleSingle, ARC, Zoo, ALZip, EGG, LBR, Squeeze, Amiga LZX/DMS/ADF,
/// PowerPacker, ACE 1.x and more.
///
/// The tools only accept passwords as command-line arguments, which would expose them in the process
/// list, so this engine deliberately does not handle encrypted archives; those are reported as
/// unsupported and routed to 7-Zip where possible.
public final class UnarEngine: ArchiveEngine, @unchecked Sendable {
    public let descriptor: EngineDescriptor
    let lsar: URL?
    let unar: URL?
    private let table: [FormatID: EngineFormatSupport]

    static let formats: [FormatID] = [
        .stuffIt, .stuffItX, .compactPro, .packIt, .diskDoubler, .macBinary, .binHex, .appleSingle, .appleDouble,
        .arc, .zoo, .alz, .egg, .lbr, .squeeze, .amigaLZX, .dms, .adf, .powerPacker, .ace, .arj, .lha, .cab,
        .uuencode, .yEnc, .xxencode, .nsis, .zip, .rar, .sevenZip, .tar, .gzip, .bzip2, .xz, .cpio, .iso, .lzma, .unixCompress,
        .warc, .chm, .msi, .lzop, .cbr, .cbz,
    ]

    public init(lsar: URL? = HelperLocator.find(["lsar"]), unar: URL? = HelperLocator.find(["unar"])) {
        self.lsar = lsar
        self.unar = unar
        var version: String?
        if let l = lsar, let r = ProbeCache.run(l, ["-v"]) {
            version = r.stdout.components(separatedBy: CharacterSet.whitespacesAndNewlines).first { $0.first?.isNumber == true }
        }
        let ok = lsar != nil && unar != nil
        descriptor = EngineDescriptor(
            id: .unar, name: "The Unarchiver (XADMaster)", implementation: "Separate helper processes (lsar / unar)",
            version: version, minimumVersion: "1.10", license: "LGPL-2.1-or-later",
            licensingRestrictions: nil, isAvailable: ok,
            unavailableReason: ok ? nil : "unar/lsar are not installed. Bundle them in Contents/Helpers or install with Homebrew (brew install unar).",
            location: lsar?.deletingLastPathComponent().path,
            isolation: "Separate process; extracts into a private staging folder that is validated and imported by the safe sink.")
        var t: [FormatID: EngineFormatSupport] = [:]
        for f in Self.formats {
            var limits = ["Encrypted archives are not handled by this engine (its tools require passwords on the command line)."]
            switch f {
            case .stuffItX: limits.append("StuffIt X: only some compression methods are implemented; encrypted and some newer archives cannot be read.")
            case .stuffIt: limits.append("StuffIt 1.5–5.5 supported; encrypted StuffIt archives are not.")
            case .ace: limits.append("ACE 1.x only; ACE 2 archives are not supported by any open decoder.")
            case .macBinary, .binHex, .appleSingle, .appleDouble: limits.append("Resource forks are written as AppleDouble (._) files on non-Mac volumes.")
            default: break
            }
            t[f] = EngineFormatSupport(format: f, operations: [.inspect, .extract, .test, .selectiveExtract, .preserveMetadata], limitations: limits)
        }
        table = ok ? t : [:]
    }

    public var supportedFormats: [FormatID] { Array(table.keys).sorted() }
    public func support(for format: FormatID) -> EngineFormatSupport? { table[format] }

    private func tools() throws -> (URL, URL) {
        guard let l = lsar, let u = unar, descriptor.isAvailable else {
            throw ArchiveError.engineUnavailable(.unar, reason: descriptor.unavailableReason ?? "not available")
        }
        return (l, u)
    }

    public func list(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> ArchiveListing {
        let (lsar, _) = try tools()
        var args = ["-j"]
        if let enc = options.filenameEncoding { args += ["-e", enc] }
        args += ["--", source.url.path]
        let r = try HelperProcess(lsar, args).run()
        guard let data = r.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Self.map(r, source.url)
        }
        if r.status != 0, (json["lsarContents"] as? [Any])?.isEmpty ?? true { throw Self.map(r, source.url) }
        let formatName = json["lsarFormatName"] as? String
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var entries: [ArchiveEntry] = []
        var anyEncrypted = false
        for (i, item) in ((json["lsarContents"] as? [[String: Any]]) ?? []).enumerated() {
            let name = item["XADFileName"] as? String ?? ""
            let isDir = (item["XADIsDirectory"] as? Int ?? 0) != 0
            let isLink = (item["XADIsLink"] as? Int ?? 0) != 0
            let enc = (item["XADIsEncrypted"] as? Int ?? 0) != 0
            anyEncrypted = anyEncrypted || enc
            let perms = (item["XADPosixPermissions"] as? Int).map { UInt16(truncatingIfNeeded: $0 & 0o7777) }
            let isResourceFork = (item["XADIsResourceFork"] as? Int ?? 0) != 0
            let e = ArchiveEntry(
                index: i, path: isResourceFork ? name + "/..namedfork/rsrc" : name,
                type: isDir ? .directory : (isLink ? .symlink : .file),
                uncompressedSize: (item["XADFileSize"] as? NSNumber)?.uint64Value,
                compressedSize: (item["XADCompressedSize"] as? NSNumber)?.uint64Value,
                modificationDate: (item["XADLastModificationDate"] as? String).flatMap(df.date(from:)),
                creationDate: (item["XADCreationDate"] as? String).flatMap(df.date(from:)),
                permissions: perms, isEncrypted: enc, method: item["XADCompressionName"] as? String,
                linkTarget: item["XADLinkDestination"] as? String, comment: item["XADComment"] as? String)
            entries.append(e)
        }
        let props = ArchiveProperties(format: source.format, formatDescription: formatName, archiveSize: source.totalSize,
                                      isSolid: nil, hasEncryptedEntries: anyEncrypted, volumeCount: source.volumes.count, engine: id)
        return ArchiveListing(properties: props, entries: entries)
    }

    public func extract(_ source: ArchiveSource, selection: EntrySelection, into sink: ExtractionSink,
                        options: ReadOptions, progress: OperationProgress) throws {
        let (_, unar) = try tools()
        let listing = try list(source, options: options, progress: progress)
        if listing.properties.hasEncryptedEntries == true {
            throw ArchiveError.unsupportedEncryption(method: "encrypted \(listing.properties.formatDescription ?? source.format.rawValue) archive (try the 7-Zip engine)")
        }
        let destination = (sink as? SafeExtractionSink)?.destination ?? FileManager.default.temporaryDirectory
        let staging = try StagingDirectory(near: destination)
        defer { staging.remove() }
        // -D: never create an enclosing folder; -q quiet; -k: write resource forks as AppleDouble files
        // off-Mac, native forks on macOS; -no-recursion: don't unpack nested archives silently.
        var args = ["-o", staging.url.path, "-D", "-q", "-no-recursion", "-f"]
        #if os(macOS)
        args += ["-k", "visible"]
        #endif
        if let enc = options.filenameEncoding { args += ["-e", enc] }
        args += ["--", source.url.path]
        let limits = (sink as? SafeExtractionSink)?.options.limits ?? .default
        let watchdog = DiskWatchdog(path: staging.url.path, minimumFree: limits.minimumFreeSpace, progress: progress)
        watchdog.start()
        defer { watchdog.stop() }
        let proc = HelperProcess(unar, args)
        proc.progress = progress
        let r: HelperProcess.Result
        do { r = try proc.run() } catch ArchiveError.cancelled { throw watchdog.tripped ?? .cancelled }
        if let w = watchdog.tripped { throw w }
        if r.status != 0 { throw Self.map(r, source.url) }
        var byPath: [String: ArchiveEntry] = [:]
        for e in listing.entries { byPath[e.normalizedPath] = e }
        let target: ExtractionSink = selection == .all ? sink : FilteringSink(base: sink, selection: selection)
        try StagingImporter.importTree(staging.url, into: target, listing: byPath, progress: progress)
    }

    public func test(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> IntegrityReport {
        let (lsar, _) = try tools()
        let listing = try list(source, options: options, progress: progress)
        let r = try HelperProcess(lsar, ["-t", "--", source.url.path]).run()
        var report = IntegrityReport(archive: source.url.lastPathComponent, format: source.format, engine: id)
        report.filesInspected = listing.fileCount
        report.directories = listing.directoryCount
        report.encrypted = listing.properties.hasEncryptedEntries ?? false
        report.checks = ["Every entry decoded by XADMaster", "Stored checksums where the format has them"]
        let failures = r.stdout.components(separatedBy: "\n").filter { $0.contains("... ") && !$0.hasSuffix("OK.") && !$0.hasSuffix("OK") && !$0.contains("Unknown.") && !$0.isEmpty }
        for f in failures { report.issues.append(.init(entry: f.components(separatedBy: "... ").first?.trimmingCharacters(in: .whitespaces), message: f, code: "damaged")) }
        if r.status != 0, failures.isEmpty { report.issues.append(.init(entry: nil, message: Self.map(r, source.url).explanation, code: "damaged")) }
        report.filesVerified = max(0, listing.fileCount - report.issues.count)
        report.bytesVerified = listing.totalUncompressedSize ?? 0
        return report
    }

    static func map(_ r: HelperProcess.Result, _ url: URL) -> ArchiveError {
        let t = r.combined
        if t.contains("password") || t.contains("encrypted") { return .unsupportedEncryption(method: "encrypted archive") }
        if t.contains("Couldn't recognize the archive format") || t.contains("Couldn't open archive") { return .notAnArchive(path: url.path) }
        if t.contains("Unsupported") || t.contains("not supported") { return .unsupportedMethod(method: t.trimmingCharacters(in: .whitespacesAndNewlines), entry: nil) }
        if t.contains("Archive parsing failed") || t.contains("Data is corrupted") || t.contains("Checksum") { return .damaged(details: t.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return .externalTool(tool: "unar", exitCode: r.status, message: t.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
