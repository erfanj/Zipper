import Foundation
import ArchiveCore
import CArchive
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Engine backed by libarchive (BSD-2-Clause), linked in-process.
///
/// libarchive streams every format it supports, so memory use is bounded regardless of archive size.
/// All extraction goes through `SafeExtractionSink`; libarchive's own disk writer is never used.
public final class LibArchiveEngine: ArchiveEngine, @unchecked Sendable {
    public let descriptor: EngineDescriptor
    private let table: [FormatID: EngineFormatSupport]
    /// Write capabilities discovered at runtime (libarchive builds differ in which codecs they link).
    let writableFilters: Set<String>
    let zipMethods: [CompressionMethod]
    let zipEncryption: [EncryptionMethod]
    let sevenZipMethods: [CompressionMethod]
    let canWriteXar: Bool
    let zstdThreads: Bool
    let xzThreads: Bool
    let brotliAvailable: Bool

    public init(includeBrotli: Bool = true) {
        _ = LA.localeConfigured
        let probe = LibArchiveProbe()
        writableFilters = probe.filters
        zipMethods = probe.zipMethods
        zipEncryption = probe.zipEncryption
        sevenZipMethods = probe.sevenZipMethods
        canWriteXar = probe.xar
        zstdThreads = probe.zstdThreads
        xzThreads = probe.xzThreads
        brotliAvailable = includeBrotli
        let version = LA.versionString
        descriptor = EngineDescriptor(
            id: .libarchive, name: "libarchive", implementation: "C library linked in-process (\(version))",
            version: String(cString: archive_version_string()).replacingOccurrences(of: "libarchive ", with: ""),
            minimumVersion: "3.6.0", license: "BSD-2-Clause", licensingRestrictions: nil, isAvailable: LA.versionNumber >= 3_006_000,
            unavailableReason: LA.versionNumber >= 3_006_000 ? nil : "libarchive 3.6 or later is required",
            location: nil,
            isolation: "Runs in-process; never writes to disk itself. All output passes through the path-validating extraction sink with resource limits.")
        table = Self.buildTable(probe: probe)
        if FormatDetector.innerFormatProbe == nil {
            FormatDetector.innerFormatProbe = { url, outer in LibArchiveEngine.probeInner(url: url, outer: outer) }
        }
    }

    public var supportedFormats: [FormatID] { Array(table.keys).sorted() }
    public func support(for format: FormatID) -> EngineFormatSupport? { table[format] }

    // MARK: Capability table

    private static func buildTable(probe: LibArchiveProbe) -> [FormatID: EngineFormatSupport] {
        var t: [FormatID: EngineFormatSupport] = [:]
        let read: EngineOperations = [.inspect, .extract, .test, .selectiveExtract, .streamingRead]
        let rw: EngineOperations = read.union([.create, .modify, .streamingWrite, .preserveMetadata])
        let streamNote = "Streaming: memory use is bounded and independent of archive size."

        var zipOps = rw.union([.decrypt, .readSplit])
        if !probe.zipEncryption.isEmpty { zipOps.insert(.encrypt) }
        t[.zip] = .init(format: .zip, operations: zipOps, compressionMethods: probe.zipMethods,
                        encryptionMethods: probe.zipEncryption, decryptionMethods: [.zipCrypto, .zipAES128, .zipAES256],
                        memory: "Bounded (< 64 MB).", threading: "Single-threaded.", streaming: streamNote,
                        limitations: ["Split (.z01) ZIP sets are read through the 7-Zip engine.",
                                      "Deflate64, PPMd, WavPack and JPEG entries in ZIPX are not decoded by libarchive."])
        t[.zipx] = .init(format: .zipx, operations: read.union([.decrypt]), decryptionMethods: [.zipCrypto, .zipAES128, .zipAES256],
                         limitations: ["Only entries using Store, Deflate, BZip2, LZMA, XZ or Zstandard are readable."])
        t[.sevenZip] = .init(format: .sevenZip, operations: rw.subtracting([.preserveMetadata]).union([.readSplit]),
                             compressionMethods: probe.sevenZipMethods,
                             memory: "Proportional to the LZMA dictionary (up to ~1.5 GB for 1 GB dictionaries).",
                             threading: "Single-threaded.",
                             limitations: ["Encrypted 7z archives require the 7-Zip engine.", "Cannot create multi-volume or encrypted 7z."])
        t[.rar] = .init(format: .rar, operations: read.union([.readSplit]),
                        limitations: ["Encrypted RAR archives require the 7-Zip engine.", "RAR creation requires the licensed RAR tool."])
        t[.tar] = .init(format: .tar, operations: rw.union([.readSplit]), compressionMethods: [.store], streaming: streamNote)

        let filterFor: [(FormatID, FormatID, String, CompressionMethod)] = [
            (.tarGzip, .gzip, "gzip", .deflate), (.tarBzip2, .bzip2, "bzip2", .bzip2), (.tarXz, .xz, "xz", .xz),
            (.tarLzma, .lzma, "lzma", .lzma), (.tarZstd, .zstd, "zstd", .zstd), (.tarLz4, .lz4, "lz4", .lz4),
            (.tarLzip, .lzip, "lzip", .lzip), (.tarCompress, .unixCompress, "compress", .lzw),
        ]
        for (tarID, streamID, filter, method) in filterFor {
            let canWrite = probe.filters.contains(filter)
            var ops = read.union([.readSplit])
            if canWrite { ops.formUnion([.create, .modify, .streamingWrite, .preserveMetadata]) }
            if (filter == "zstd" && probe.zstdThreads) || (filter == "xz" && probe.xzThreads) { ops.insert(.multithreaded) }
            t[tarID] = .init(format: tarID, operations: ops, compressionMethods: canWrite ? [method] : [], streaming: streamNote,
                             limitations: canWrite ? [] : ["This libarchive build cannot write \(filter)."])
            var sops = read.union([.readSplit])
            if canWrite { sops.formUnion([.create, .streamingWrite]) }
            if (filter == "zstd" && probe.zstdThreads) || (filter == "xz" && probe.xzThreads) { sops.insert(.multithreaded) }
            t[streamID] = .init(format: streamID, operations: sops, compressionMethods: canWrite ? [method] : [], streaming: streamNote,
                                limitations: ["A compression stream holds exactly one file."])
        }
        // Brotli has no libarchive filter; it is layered in with Google's reference library.
        t[.brotli] = .init(format: .brotli, operations: read.union([.create, .streamingWrite]), compressionMethods: [.brotli],
                           streaming: streamNote, limitations: ["Implemented with the Brotli reference library (MIT) layered under libarchive.", "A compression stream holds exactly one file."])
        t[.tarBrotli] = .init(format: .tarBrotli, operations: rw, compressionMethods: [.brotli], streaming: streamNote,
                              limitations: ["Implemented with the Brotli reference library (MIT) layered under libarchive."])
        t[.cpio] = .init(format: .cpio, operations: rw)
        t[.ar] = .init(format: .ar, operations: rw.subtracting([.preserveMetadata]))
        t[.deb] = .init(format: .deb, operations: read, limitations: ["Shows the package's control and data archives; install scripts are never run."])
        if probe.xar {
            t[.xar] = .init(format: .xar, operations: rw)
            t[.pkg] = .init(format: .pkg, operations: read, limitations: ["Read-only; modifying a signed installer invalidates its signature."])
        } else {
            t[.xar] = .init(format: .xar, operations: read)
            t[.pkg] = .init(format: .pkg, operations: read)
        }
        t[.cab] = .init(format: .cab, operations: read)
        t[.lha] = .init(format: .lha, operations: read)
        t[.iso] = .init(format: .iso, operations: read.union([.create]), compressionMethods: [.store],
                        limitations: ["ISO creation produces ISO 9660 with Rock Ridge and Joliet extensions."])
        t[.rpm] = .init(format: .rpm, operations: read, limitations: ["Payload is listed and extracted; scriptlets are never executed."])
        t[.warc] = .init(format: .warc, operations: rw.subtracting([.preserveMetadata]))
        t[.shar] = .init(format: .shar, operations: [.create], limitations: ["Shell archives are written only; reading would require executing a script."])
        t[.uuencode] = .init(format: .uuencode, operations: read)
        // Packages built on ZIP / RAR / 7z / TAR inherit the container's support (see EngineRegistry),
        // but creation profiles are declared explicitly where libarchive can produce a valid package.
        for pkg: FormatID in [.jar, .war, .ear, .cbz, .epub, .xpi, .vsix] {
            t[pkg] = .init(format: pkg, operations: read.union([.create]), compressionMethods: [.deflate, .store],
                           limitations: pkg == .epub ? ["EPUB creation stores the 'mimetype' file first and uncompressed, as the OCF specification requires. Content validity is not checked."] : [])
        }
        for pkg: FormatID in [.apk, .aab, .ipa, .appx, .msix] {
            t[pkg] = .init(format: pkg, operations: read, limitations: ["Signed packages are read-only: re-packing invalidates the signature."])
        }
        t[.cbr] = .init(format: .cbr, operations: read)
        t[.cb7] = .init(format: .cb7, operations: read.union([.create]), compressionMethods: probe.sevenZipMethods)
        t[.cbt] = .init(format: .cbt, operations: read.union([.create]))
        return t
    }

    // MARK: Listing

    public func list(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> ArchiveListing {
        let reader = try makeReader(source, options)
        var entries: [ArchiveEntry] = []
        var entryPtr: OpaquePointer?
        let rawName = rawEntryName(source)
        var index = 0
        progress.setTotal(bytes: source.totalSize, items: nil)
        while true {
            try progress.checkCancelled()
            let r = archive_read_next_header(reader.a, &entryPtr)
            if r == LA.eof { break }
            if r == LA.retry { continue }
            if r < LA.warn { throw reader.error(entry: nil) }
            guard let e = entryPtr else { break }
            var entry = ArchiveEntry.from(libarchive: e, index: index)
            if isRaw(source) { entry.path = rawName; entry.type = .file }
            entries.append(entry)
            index += 1
            // Skipping data is required to reach the next header; for solid/streamed formats this
            // decodes the data, which also verifies it is readable.
            let s = archive_read_data_skip(reader.a)
            if s < LA.warn {
                let err = reader.error(entry: entry.path)
                // Encrypted entries can be listed without a password in formats with plain headers.
                if case .passwordRequired = err { continue }
                if case .incorrectPassword = err { continue }
                throw err
            }
            progress.setProcessed(reader.compressedBytesRead)
        }
        var props = ArchiveProperties(format: source.format, formatDescription: reader.formatName, filters: reader.filterNames,
                                      archiveSize: source.totalSize, hasEncryptedEntries: reader.hasEncryptedEntries ?? entries.contains(where: \.isEncrypted),
                                      hasEncryptedHeaders: false, volumeCount: source.volumes.count, engine: id)
        if entries.contains(where: \.isEncrypted) { props.encryptionMethod = source.format == .zip ? "ZIP (method recorded per entry)" : "Yes" }
        if isRaw(source) {
            props.filters = reader.filterNames
            if entries.count == 1 { entries[0].compressedSize = source.totalSize }
        }
        return ArchiveListing(properties: props, entries: entries)
    }

    // MARK: Extraction

    public func extract(_ source: ArchiveSource, selection: EntrySelection, into sink: ExtractionSink,
                        options: ReadOptions, progress: OperationProgress) throws {
        let reader = try makeReader(source, options)
        var entryPtr: OpaquePointer?
        let rawName = rawEntryName(source)
        var index = 0
        let zeros = [UInt8](repeating: 0, count: 1 << 16)
        progress.setTotal(bytes: progress.snapshot.totalBytes ?? source.totalSize, items: nil)
        while true {
            try progress.checkCancelled()
            let r = archive_read_next_header(reader.a, &entryPtr)
            if r == LA.eof { break }
            if r == LA.retry { continue }
            if r == LA.warn { progress.warning() }
            if r < LA.warn {
                if let log = options.salvage {
                    // Unreadable header: nothing after this point can be located reliably.
                    log.stopped(reader.error(entry: nil).explanation)
                    break
                }
                throw reader.error(entry: nil)
            }
            guard let e = entryPtr else { break }
            var entry = ArchiveEntry.from(libarchive: e, index: index)
            index += 1
            if isRaw(source) { entry.path = rawName; entry.type = .file }
            guard selection.includes(entry.path) else { continue }
            let extras = EntryExtras(extendedAttributes: ArchiveEntry.xattrs(of: e))
            guard let writer = try sink.begin(entry, extras: extras) else { continue }
            var buf: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            var position: Int64 = 0
            do {
                while true {
                    let d = archive_read_data_block(reader.a, &buf, &size, &offset)
                    if d == LA.eof { break }
                    if d == LA.retry { continue }
                    if d < LA.warn { throw reader.error(entry: entry.path) }
                    // Sparse holes: materialise as zeros so the result matches the original size.
                    while offset > position {
                        let n = Int(min(Int64(zeros.count), offset - position))
                        try zeros.withUnsafeBytes { try writer.write(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                        position += Int64(n)
                    }
                    if size > 0, let buf {
                        try writer.write(UnsafeRawBufferPointer(start: buf, count: size))
                        position += Int64(size)
                    }
                    progress.setProcessed(reader.compressedBytesRead)
                }
                // Trailing hole in a sparse file.
                if archive_entry_size_is_set(e) != 0 {
                    let declared = archive_entry_size(e)
                    while declared > position, archive_entry_sparse_count(e) > 0 {
                        let n = Int(min(Int64(zeros.count), declared - position))
                        try zeros.withUnsafeBytes { try writer.write(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                        position += Int64(n)
                    }
                }
                try writer.commit()
            } catch {
                writer.abort()
                if let log = options.salvage, let ae = error as? ArchiveError, Self.isEntryLevel(ae) {
                    log.record(entry.normalizedPath, ae.explanation)
                    continue
                }
                throw error
            }
        }
        progress.setProcessed(reader.compressedBytesRead)
    }

    /// Errors confined to one entry's data, after which reading can continue with the next entry.
    static func isEntryLevel(_ e: ArchiveError) -> Bool {
        switch e {
        case .checksumMismatch, .damaged, .unsupportedMethod, .authenticationFailed, .truncated: return true
        default: return false
        }
    }

    public func test(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> IntegrityReport {
        let sink = VerifyingSink()
        var report = IntegrityReport(archive: source.url.lastPathComponent, format: source.format, engine: id)
        do {
            try extract(source, selection: .all, into: sink, options: options, progress: progress)
        } catch let e as ArchiveError {
            switch e {
            case .cancelled, .passwordRequired, .incorrectPassword: throw e
            default: report.issues.append(.init(entry: sink.currentEntry, message: e.explanation, code: e.code))
            }
        }
        report.filesInspected = sink.files
        report.directories = sink.directories
        report.filesVerified = sink.files - sink.failedFiles - (report.issues.isEmpty ? 0 : 1)
        report.bytesVerified = sink.bytes
        report.encrypted = sink.sawEncrypted
        report.volumes = source.volumes.count
        report.checks = Self.checks(for: source)
        return report
    }

    static func checks(for source: ArchiveSource) -> [String] {
        var c = ["Every entry fully decoded"]
        switch source.format {
        case .zip, .zipx, .jar, .epub, .cbz, .apk, .ipa: c.append("CRC-32 of every entry"); c.append("AES authentication codes (encrypted entries)")
        case .sevenZip: c.append("CRC-32 of every stream and file")
        case .rar: c.append("CRC-32 / BLAKE2 of every file (as stored)")
        default: break
        }
        if source.layers.contains(.gzip) || source.format == .gzip { c.append("gzip CRC-32 and length") }
        if source.layers.contains(.xz) || source.format == .xz { c.append("XZ integrity check") }
        if source.layers.contains(.bzip2) || source.format == .bzip2 { c.append("bzip2 block CRCs") }
        if source.layers.contains(.zstd) || source.format == .zstd { c.append("Zstandard frame checksum (if present)") }
        if source.layers.contains(.tar) || source.format == .tar { c.append("TAR header checksums") }
        return c
    }

    // MARK: Creation

    public func create(_ request: CreateRequest, progress: OperationProgress) throws -> CreateResult {
        try LibArchiveWriter(engine: self, request: request, progress: progress).run()
    }

    // MARK: Helpers

    func isRaw(_ s: ArchiveSource) -> Bool {
        let kind = FormatCatalog.descriptor(for: s.format)?.kind
        return kind == .compressionStream || kind == .encoding
    }

    func usesBrotli(_ s: ArchiveSource) -> Bool {
        s.format == .brotli || s.format == .tarBrotli
    }

    func makeReader(_ source: ArchiveSource, _ options: ReadOptions) throws -> LAReader {
        try LAReader(source: source, options: options, raw: isRaw(source), input: usesBrotli(source) ? .brotli : .files)
    }

    /// Name for the single payload of a compression stream: the archive name minus its extension.
    func rawEntryName(_ s: ArchiveSource) -> String {
        // uuencode / xxencode record the original name in their "begin MODE NAME" line.
        if FormatCatalog.descriptor(for: s.format)?.kind == .encoding, let fh = FileHandle(forReadingAtPath: s.url.path) {
            let head = String(decoding: fh.readData(ofLength: 4096), as: UTF8.self)
            try? fh.close()
            for line in head.split(whereSeparator: \.isNewline) where line.hasPrefix("begin ") {
                let parts = line.split(separator: " ", maxSplits: 2)
                if parts.count == 3 { return String(parts[2]).trimmingCharacters(in: .whitespaces) }
            }
        }
        let name = s.url.lastPathComponent
        if let m = FormatCatalog.matchExtension(of: name), name.count > m.ext.count + 1 {
            let stripped = String(name.dropLast(m.ext.count + 1))
            if ["tgz", "tbz", "tbz2", "txz", "tzst", "tlz"].contains(m.ext) { return stripped + ".tar" }
            return stripped
        }
        return name + ".out"
    }

    /// Identifies a tarball inside a compression stream.
    static func probeInner(url: URL, outer: FormatID) -> FormatID? {
        guard outer != .brotli else { return nil }
        guard let a = archive_read_new() else { return nil }
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        guard archive_read_open_filename(a, url.path, 1 << 16) == LA.ok else { return nil }
        var e: OpaquePointer?
        guard archive_read_next_header(a, &e) == LA.ok, let name = archive_format_name(a) else { return nil }
        let n = String(cString: name).lowercased()
        if n.contains("tar") || n.contains("ustar") || n.contains("pax") || n.contains("gnu") { return .tar }
        if n.contains("cpio") { return .cpio }
        return nil
    }
}

/// Runtime probe of which writers this libarchive build provides.
struct LibArchiveProbe {
    var filters = Set<String>()
    var zipMethods: [CompressionMethod] = []
    var zipEncryption: [EncryptionMethod] = []
    var sevenZipMethods: [CompressionMethod] = []
    var xar = false
    var zstdThreads = false
    var xzThreads = false

    init() {
        func withWriter(_ body: (OpaquePointer) -> Void) {
            guard let a = archive_write_new() else { return }
            body(a)
            archive_write_free(a)
        }
        let filterFns: [(String, (OpaquePointer) -> Int32)] = [
            ("gzip", { archive_write_add_filter_gzip($0) }), ("bzip2", { archive_write_add_filter_bzip2($0) }),
            ("xz", { archive_write_add_filter_xz($0) }), ("lzma", { archive_write_add_filter_lzma($0) }),
            ("zstd", { archive_write_add_filter_zstd($0) }), ("lz4", { archive_write_add_filter_lz4($0) }),
            ("lzip", { archive_write_add_filter_lzip($0) }), ("compress", { archive_write_add_filter_compress($0) }),
        ]
        for (name, fn) in filterFns {
            withWriter { a in
                // ARCHIVE_WARN means the filter would shell out to an external program; we don't use those.
                if fn(a) == LA.ok { filters.insert(name) }
            }
        }
        withWriter { a in
            archive_write_add_filter_zstd(a)
            zstdThreads = archive_write_set_filter_option(a, "zstd", "threads", "2") == LA.ok
        }
        withWriter { a in
            archive_write_add_filter_xz(a)
            xzThreads = archive_write_set_filter_option(a, "xz", "threads", "2") == LA.ok
        }
        withWriter { a in
            archive_write_set_format_zip(a)
            for (m, opt) in [(CompressionMethod.store, "store"), (.deflate, "deflate"), (.bzip2, "bzip2"), (.lzma, "lzma"), (.xz, "xz"), (.zstd, "zstd")] {
                if archive_write_set_format_option(a, "zip", "compression", opt) == LA.ok { zipMethods.append(m) }
            }
            for (m, opt) in [(EncryptionMethod.zipAES256, "aes256"), (.zipAES128, "aes128"), (.zipCrypto, "zipcrypt")] {
                if archive_write_set_format_option(a, "zip", "encryption", opt) == LA.ok { zipEncryption.append(m) }
            }
        }
        withWriter { a in
            archive_write_set_format_7zip(a)
            for (m, opt) in [(CompressionMethod.store, "store"), (.lzma2, "lzma2"), (.lzma, "lzma1"), (.deflate, "deflate"), (.bzip2, "bzip2"), (.ppmd, "ppmd"), (.zstd, "zstd")] {
                if archive_write_set_format_option(a, "7zip", "compression", opt) == LA.ok { sevenZipMethods.append(m) }
            }
        }
        withWriter { a in xar = archive_write_set_format_xar(a) == LA.ok }
    }
}
