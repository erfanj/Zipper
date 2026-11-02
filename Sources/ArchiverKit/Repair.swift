import Foundation
import ArchiveCore
import ArchiveEngines

/// One entry located by scanning a ZIP file's local headers.
struct ZipLocalEntry {
    var offset: Int          // of the local header in the damaged file
    var end: Int             // end of data (+ data descriptor)
    var name: [UInt8]
    var versionNeeded: UInt16
    var flags: UInt16
    var method: UInt16
    var time: UInt16
    var date: UInt16
    var crc: UInt32
    var compressedSize: UInt64
    var uncompressedSize: UInt64
    var localExtra: [UInt8]
}

/// Rebuilds a ZIP's central directory from its local file headers. Used when the central
/// directory is damaged or missing (e.g. a truncated download). Entry data is copied verbatim,
/// so encrypted entries stay encrypted and nothing is recompressed.
enum ZipRebuilder {
    static func u16(_ d: UnsafeRawBufferPointer, _ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    static func u32(_ d: UnsafeRawBufferPointer, _ o: Int) -> UInt32 { UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16 }
    static func u64(_ d: UnsafeRawBufferPointer, _ o: Int) -> UInt64 { UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32 }

    static func scan(_ data: Data) -> (entries: [ZipLocalEntry], problems: [String]) {
        var entries: [ZipLocalEntry] = []
        var problems: [String] = []
        data.withUnsafeBytes { d in
            let n = d.count
            var i = 0
            while i + 30 <= n {
                guard d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 0x03, d[i + 3] == 0x04 else { i += 1; continue }
                let flags = u16(d, i + 6)
                let nameLen = Int(u16(d, i + 26)), extraLen = Int(u16(d, i + 28))
                let dataStart = i + 30 + nameLen + extraLen
                guard dataStart <= n, nameLen > 0, nameLen < 65_536 else { i += 4; continue }
                let name = Array(d[(i + 30)..<(i + 30 + nameLen)])
                let extra = Array(d[(i + 30 + nameLen)..<dataStart])
                var crc = u32(d, i + 14)
                var csize = UInt64(u32(d, i + 18)), usize = UInt64(u32(d, i + 22))
                // ZIP64 extended sizes in the local extra field.
                var e = 0
                while e + 4 <= extra.count {
                    let id = UInt16(extra[e]) | UInt16(extra[e + 1]) << 8
                    let len = Int(UInt16(extra[e + 2]) | UInt16(extra[e + 3]) << 8)
                    if id == 0x0001, len >= 16, e + 4 + 16 <= extra.count {
                        extra.withUnsafeBytes { x in
                            usize = u64(x, e + 4)
                            csize = u64(x, e + 12)
                        }
                    }
                    e += 4 + len
                }
                var end: Int
                if flags & 0x8 != 0 {
                    // Sizes follow the data in a descriptor: find a descriptor whose size field matches.
                    var p = dataStart
                    var found = -1
                    while p + 16 <= n {
                        if d[p] == 0x50, d[p + 1] == 0x4B, d[p + 2] == 0x07, d[p + 3] == 0x08 {
                            let cs32 = UInt64(u32(d, p + 8))
                            if cs32 == UInt64(p - dataStart) { crc = u32(d, p + 4); csize = cs32; usize = UInt64(u32(d, p + 12)); found = p + 16; break }
                            if p + 24 <= n, u64(d, p + 8) == UInt64(p - dataStart) { crc = u32(d, p + 4); csize = u64(d, p + 8); usize = u64(d, p + 16); found = p + 24; break }
                        }
                        p += 1
                    }
                    guard found > 0 else {
                        problems.append("“\(String(decoding: name, as: UTF8.self))”: data descriptor not found; entry is truncated.")
                        i = dataStart
                        continue
                    }
                    end = found
                } else {
                    end = dataStart + Int(csize)
                    guard csize < UInt64(Int.max), end <= n else {
                        problems.append("“\(String(decoding: name, as: UTF8.self))”: entry is truncated (\(n - dataStart) of \(csize) bytes present).")
                        break
                    }
                }
                entries.append(ZipLocalEntry(offset: i, end: end, name: name, versionNeeded: u16(d, i + 4), flags: flags,
                                             method: u16(d, i + 8), time: u16(d, i + 10), date: u16(d, i + 12), crc: crc,
                                             compressedSize: csize, uncompressedSize: usize, localExtra: extra))
                i = end
            }
        }
        return (entries, problems)
    }

    /// Writes a new ZIP containing every structurally complete entry. Returns the number of entries.
    static func rebuild(from input: URL, to output: URL) throws -> (count: Int, problems: [String]) {
        let data = try Data(contentsOf: input, options: .alwaysMapped)
        let (entries, problems) = scan(data)
        guard !entries.isEmpty else { throw ArchiveError.damaged(details: "No intact ZIP entries were found.") }
        var out = Data()
        var central = Data()
        func le16(_ v: UInt16, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
        func le32(_ v: UInt32, _ d: inout Data) { for k in 0..<4 { d.append(UInt8((v >> (8 * UInt32(k))) & 0xFF)) } }
        func le64(_ v: UInt64, _ d: inout Data) { for k in 0..<8 { d.append(UInt8((v >> (8 * UInt64(k))) & 0xFF)) } }
        for e in entries {
            let newOffset = UInt64(out.count)
            out.append(data[e.offset..<e.end])
            // Central record: strip any local ZIP64 field and add our own when needed.
            var extra = Data()
            var k = 0
            while k + 4 <= e.localExtra.count {
                let id = UInt16(e.localExtra[k]) | UInt16(e.localExtra[k + 1]) << 8
                let len = Int(UInt16(e.localExtra[k + 2]) | UInt16(e.localExtra[k + 3]) << 8)
                guard k + 4 + len <= e.localExtra.count else { break }
                if id != 0x0001 { extra.append(contentsOf: e.localExtra[k..<(k + 4 + len)]) }
                k += 4 + len
            }
            let needs64 = e.compressedSize >= 0xFFFFFFFF || e.uncompressedSize >= 0xFFFFFFFF || newOffset >= 0xFFFFFFFF
            if needs64 {
                var z = Data()
                le16(0x0001, &z); le16(24, &z); le64(e.uncompressedSize, &z); le64(e.compressedSize, &z); le64(newOffset, &z)
                extra.append(z)
            }
            le32(0x02014B50, &central)
            le16(0x031E, &central)                       // made by: Unix, 3.0
            le16(max(e.versionNeeded, needs64 ? 45 : 20), &central)
            le16(e.flags, &central)
            le16(e.method, &central)
            le16(e.time, &central)
            le16(e.date, &central)
            le32(e.crc, &central)
            le32(needs64 ? 0xFFFFFFFF : UInt32(e.compressedSize), &central)
            le32(needs64 ? 0xFFFFFFFF : UInt32(e.uncompressedSize), &central)
            le16(UInt16(e.name.count), &central)
            le16(UInt16(extra.count), &central)
            le16(0, &central); le16(0, &central); le16(0, &central)
            le32(e.name.last == 0x2F ? 0o40755 << 16 | 0x10 : 0o100644 << 16, &central)
            le32(needs64 ? 0xFFFFFFFF : UInt32(newOffset), &central)
            central.append(contentsOf: e.name)
            central.append(extra)
        }
        let cdOffset = UInt64(out.count)
        out.append(central)
        let count = entries.count
        if count >= 0xFFFF || cdOffset >= 0xFFFFFFFF || UInt64(central.count) >= 0xFFFFFFFF {
            let z64 = UInt64(out.count)
            var r = Data()
            le32(0x06064B50, &r); le64(44, &r); le16(0x031E, &r); le16(45, &r); le32(0, &r); le32(0, &r)
            le64(UInt64(count), &r); le64(UInt64(count), &r); le64(UInt64(central.count), &r); le64(cdOffset, &r)
            le32(0x07064B50, &r); le32(0, &r); le64(z64, &r); le32(1, &r)
            out.append(r)
        }
        var eocd = Data()
        le32(0x06054B50, &eocd); le16(0, &eocd); le16(0, &eocd)
        le16(UInt16(min(count, 0xFFFF)), &eocd); le16(UInt16(min(count, 0xFFFF)), &eocd)
        le32(UInt32(min(UInt64(central.count), 0xFFFFFFFF)), &eocd)
        le32(UInt32(min(cdOffset, 0xFFFFFFFF)), &eocd)
        le16(0, &eocd)
        out.append(eocd)
        Leftovers.sweep(output.deletingLastPathComponent())
        let temp = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).ua-\(TempToken.make()).partial")
        try out.write(to: temp)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: temp)
            throw ArchiveError.destinationExists(path: output.path)
        }
        try FileManager.default.moveItem(at: temp, to: output)
        return (count, problems)
    }
}

public struct DamageAnalysis: Codable, Sendable {
    public var archive: String
    public var format: FormatID
    public var isDamaged: Bool
    public var problems: [String]
    public var missingVolumes: [String]
    /// Entries whose data decoded without errors.
    public var recoverableEntries: [String]
    /// Entries whose data could not be decoded.
    public var unrecoverableEntries: [String]
    /// Whether a structural rebuild (new ZIP with a reconstructed directory) is possible.
    public var canRebuildStructure: Bool
    public var canUseRecoveryRecord: Bool

    public var estimate: String {
        let total = recoverableEntries.count + unrecoverableEntries.count
        guard isDamaged else { return "No damage was found." }
        if total == 0 { return "No recoverable files were found." }
        return "\(recoverableEntries.count) of \(total) files appear recoverable. This is an estimate based on decoding each file; it does not guarantee their contents are complete."
    }
}

public struct RecoveryReport: Codable, Sendable {
    public var archive: String
    public var destination: String
    public var recovered: [String]
    public var failed: [ExtractionReport.Item]
    public var stoppedEarly: String?
    public var rebuiltArchive: String?
    public var notes: [String]

    public var textReport: String {
        var lines = ["Recovery Report", "", "Archive: \(archive)", "Recovered to: \(destination)", "",
                     "Files recovered: \(recovered.count)", "Files that could not be recovered: \(failed.count)"]
        if let r = rebuiltArchive { lines.append("Rebuilt archive: \(r)") }
        if let s = stoppedEarly { lines.append("Reading stopped early: \(s)") }
        for f in failed { lines.append("  ✗ \(f.path): \(f.reason)") }
        for n in notes { lines.append("Note: \(n)") }
        return lines.joined(separator: "\n")
    }
}

extension ArchiveService {
    /// Step 1–4 of the recovery workflow: analyse the archive and estimate what can be recovered.
    public func analyzeDamage(_ url: URL, options: ReadOptions = ReadOptions(), progress: OperationProgress = OperationProgress()) throws -> DamageAnalysis {
        let detection = try detect(url)
        var a = DamageAnalysis(archive: url.lastPathComponent, format: detection.format, isDamaged: false, problems: [], missingVolumes: [],
                               recoverableEntries: [], unrecoverableEntries: [], canRebuildStructure: false,
                               canUseRecoveryRecord: detection.format == .rar && registry.engine(.rar)?.descriptor.isAvailable == true)
        if let mp = detection.multipart, !mp.isComplete {
            a.isDamaged = true
            a.missingVolumes = mp.missing
            a.problems.append(ArchiveError.missingVolume(expected: mp.missing).explanation)
        }
        let container = FormatCatalog.descriptor(for: detection.format)?.effectiveContainer ?? detection.format
        if container == .zip, detection.multipart == nil {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            let (entries, problems) = ZipRebuilder.scan(data)
            a.problems += problems
            a.problems += ZipStructure.problems(url)
            a.canRebuildStructure = !entries.isEmpty
        }
        // Decode everything in salvage mode, writing nothing.
        let log = SalvageLog()
        var opts = options
        opts.salvage = log
        let sink = VerifyingSink()
        let source = detection.source(for: url)
        var notes: [String] = []
        do {
            _ = try withEngines(for: detection.format, EngineRequirements(operations: .extract), notes: &notes) {
                try $0.extract(source, selection: .all, into: sink, options: opts, progress: progress)
            }
        } catch let e as ArchiveError {
            if case .cancelled = e { throw e }
            if case .passwordRequired = e { throw e }
            if case .incorrectPassword = e { throw e }
            a.problems.append(e.explanation)
        }
        a.recoverableEntries = Array(sink.digests.keys).sorted()
        if a.recoverableEntries.isEmpty { a.recoverableEntries = Array(sink.sizes.keys).sorted() }
        a.unrecoverableEntries = log.failures.map(\.path)
        if let s = log.stoppedEarly { a.problems.append("Reading stopped: \(s)") }
        a.problems += log.failures.map { "\($0.path): \($0.reason)" }
        a.isDamaged = !a.problems.isEmpty
        return a
    }

    /// Steps 5–7: recover readable files into a separate folder (never touching the source), and,
    /// for ZIP, also write a rebuilt archive.
    public func recover(_ url: URL, to destinationParent: URL, selection: EntrySelection = .all, rebuildZip: Bool = true,
                        options: ReadOptions = ReadOptions(), progress: OperationProgress = OperationProgress()) throws -> RecoveryReport {
        let fm = FileManager.default
        let detection = try detect(url)
        let folder = Self.uniqueURL(in: destinationParent, name: "Recovered from \(Self.baseName(for: url))", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = RecoveryReport(archive: url.lastPathComponent, destination: folder.path, recovered: [], failed: [], notes: [])
        let container = FormatCatalog.descriptor(for: detection.format)?.effectiveContainer ?? detection.format

        var source = detection.source(for: url)
        if container == .zip, rebuildZip, detection.multipart == nil {
            let rebuilt = Self.uniqueURL(in: destinationParent, name: "\(Self.baseName(for: url)) (rebuilt).zip")
            if let r = try? ZipRebuilder.rebuild(from: url, to: rebuilt) {
                report.rebuiltArchive = rebuilt.path
                report.notes.append("A new ZIP with a reconstructed directory of \(r.count) entries was written; damaged entries in it still fail their CRC check.")
                source = ArchiveSource(url: rebuilt, format: .zip)
            }
        }
        if detection.format == .rar, let rar = registry.engine(.rar) as? RarEngine, rar.descriptor.isAvailable {
            if let fixed = try? rar.repair(url, outputDirectory: destinationParent, progress: progress) {
                report.notes.append("RAR's recovery record produced “\(fixed.lastPathComponent)”.")
                source = ArchiveSource(url: fixed, format: .rar)
            }
        }
        let log = SalvageLog()
        var opts = options
        opts.salvage = log
        let sink = try SafeExtractionSink(destination: folder, options: ExtractionOptions(archiveSize: source.totalSize), progress: progress)
        var notes: [String] = []
        do {
            _ = try withEngines(for: source.format, EngineRequirements(operations: .extract), notes: &notes) {
                try $0.extract(source, selection: selection, into: sink, options: opts, progress: progress)
            }
        } catch let e as ArchiveError {
            if case .cancelled = e { throw e }
            if case .passwordRequired = e { throw e }
            if case .incorrectPassword = e { throw e }
            report.stoppedEarly = e.explanation
        }
        sink.abortActive()
        try sink.finish()
        report.recovered = sink.report.writtenFiles
        report.failed = log.failures.map { .init(path: $0.path, reason: $0.reason) } + sink.report.blocked
        if let s = log.stoppedEarly { report.stoppedEarly = s }
        report.notes += notes
        return report
    }
}

/// Checks a ZIP's end-of-central-directory record and central directory. Some decoders (including
/// libarchive) can still read entries without a central directory, but most applications —
/// Finder, Windows Explorer, unzip — cannot, so a missing or damaged directory is reported.
enum ZipStructure {
    static func problems(_ url: URL) -> [String] {
        guard !SafeFileIO.isDirectory(url), let fh = FileHandle(forReadingAtPath: url.path) else { return [] }
        defer { try? fh.close() }
        // A read error is not structural damage: report nothing here and let the decoder report it.
        return (try? check(fh, url.path)) ?? []
    }

    private static func check(_ fh: FileHandle, _ path: String) throws -> [String] {
        let size = try fh.seekToEndChecked(path: path)
        guard size >= 22 else { return ["The file is too small to be a ZIP archive."] }
        let tailLen = min(size, 65_557)
        try fh.seekChecked(to: size - tailLen, path: path)
        let tail = [UInt8](try fh.readChunk(upTo: Int(tailLen), path: path))
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else {
            return ["The ZIP's central directory (its table of contents) is missing — the file is probably incomplete. Most apps can't open it; Repair can rebuild it."]
        }
        func u32(_ a: [UInt8], _ o: Int) -> UInt64 { UInt64(a[o]) | UInt64(a[o + 1]) << 8 | UInt64(a[o + 2]) << 16 | UInt64(a[o + 3]) << 24 }
        var cdSize = u32(tail, eocd + 12)
        var cdOffset = u32(tail, eocd + 16)
        if cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF {
            // ZIP64: locator precedes the EOCD.
            guard eocd >= 20, tail[eocd - 20] == 0x50, tail[eocd - 19] == 0x4B, tail[eocd - 18] == 0x06, tail[eocd - 17] == 0x07 else {
                return ["The ZIP64 end-of-directory locator is missing or damaged."]
            }
            let loc = u32(tail, eocd - 20 + 8) | u32(tail, eocd - 20 + 12) << 32
            try fh.seekChecked(to: loc, path: path)
            let rec = [UInt8](try fh.readChunk(upTo: 56, path: path))
            guard rec.count == 56, rec[0] == 0x50, rec[1] == 0x4B, rec[2] == 0x06, rec[3] == 0x06 else { return ["The ZIP64 end-of-directory record is damaged."] }
            cdSize = u32(rec, 40) | u32(rec, 44) << 32
            cdOffset = u32(rec, 48) | u32(rec, 52) << 32
        }
        let eocdAbs = size - tailLen + UInt64(eocd)
        guard cdOffset + cdSize <= eocdAbs else {
            return ["The central directory points beyond the end of the file — the archive is truncated or damaged."]
        }
        try fh.seekChecked(to: cdOffset, path: path)
        let sig = [UInt8](try fh.readChunk(upTo: 4, path: path))
        if sig == [0x50, 0x4B, 0x01, 0x02] || cdSize == 0 { return [] }
        // Data prepended to the archive (self-extractors) shifts offsets; accept a directory found by size.
        if eocdAbs >= cdSize {
            try fh.seekChecked(to: eocdAbs - cdSize, path: path)
            if [UInt8](try fh.readChunk(upTo: 4, path: path)) == [0x50, 0x4B, 0x01, 0x02] { return [] }
        }
        return ["The ZIP's central directory is damaged."]
    }
}
