import Foundation
import ArchiveCore
import CArchive
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Creates archives with libarchive. Output goes to a temporary file that is moved into place only
/// after libarchive has finished successfully.
final class LibArchiveWriter {
    let engine: LibArchiveEngine
    let request: CreateRequest
    let progress: OperationProgress
    var warnings: [String] = []

    init(engine: LibArchiveEngine, request: CreateRequest, progress: OperationProgress) {
        self.engine = engine
        self.request = request
        self.progress = progress
    }

    private var settings: CompressionSettings { request.settings }

    /// zstd levels for the 0…9 scale (0 and 1 = fastest; 9 = 19, the highest level that does not need --ultra memory).
    static let zstdLevels = [1, 1, 2, 3, 5, 7, 9, 12, 16, 19]

    func run() throws -> CreateResult {
        let format = request.format
        let container = FormatCatalog.descriptor(for: format)?.effectiveContainer ?? format
        guard let a = archive_write_new() else { throw ArchiveError.internalError("libarchive allocation failed") }
        defer { archive_write_free(a) }

        func check(_ rc: Int32, _ what: String) throws {
            if rc == LA.warn { warnings.append("\(what): \(LA.errorString(a))") }
            if rc < LA.warn { throw ArchiveError.invalidArgument("\(what) is not supported by this libarchive build: \(LA.errorString(a))") }
        }
        func option(_ module: String, _ key: String, _ value: String) throws {
            let rc = archive_write_set_option(a, module, key, value)
            if rc != LA.ok { throw ArchiveError.invalidArgument("Option \(module):\(key)=\(value) was rejected: \(LA.errorString(a))") }
        }
        let level = settings.clampedLevel
        var brotliQuality: Int?
        var isRaw = false
        var isZipFamily = false

        // Container
        switch container {
        case .zip:
            isZipFamily = true
            try check(archive_write_set_format_zip(a), "ZIP")
            let method = settings.method ?? (level == 0 ? .store : .deflate)
            guard engine.zipMethods.contains(method) else {
                throw ArchiveError.invalidArgument("ZIP with \(method.displayName) is not available in this libarchive build.")
            }
            let name = ["store": "store", "deflate": "deflate", "bzip2": "bzip2", "lzma": "lzma", "xz": "xz", "zstd": "zstd"][method.rawValue] ?? "deflate"
            try option("zip", "compression", name)
            if method != .store { _ = archive_write_set_option(a, "zip", "compression-level", String(level)) }
            // Always record names as UTF-8 with the language-encoding flag set.
            _ = archive_write_set_option(a, "zip", "hdrcharset", "UTF-8")
            if let enc = settings.encryption {
                guard request.password != nil else { throw ArchiveError.invalidArgument("A password is required for encryption.") }
                let v: String
                switch enc.method {
                case .zipAES256: v = "aes256"
                case .zipAES128: v = "aes128"
                case .zipCrypto: v = "zipcrypt"
                default: throw ArchiveError.invalidArgument("\(enc.method.displayName) can't be used with ZIP.")
                }
                guard engine.zipEncryption.contains(enc.method) else {
                    throw ArchiveError.invalidArgument("This libarchive build was compiled without ZIP encryption support.")
                }
                try option("zip", "encryption", v)
                if enc.encryptFilenames { warnings.append("ZIP cannot hide file names; only file contents are encrypted.") }
            }
        case .sevenZip:
            try check(archive_write_set_format_7zip(a), "7z")
            if settings.encryption != nil {
                throw ArchiveError.operationNotSupported(format: .sevenZip, operation: "encryption", reason: "libarchive cannot encrypt 7z archives; the 7-Zip engine is required.")
            }
            let method = settings.method ?? (level == 0 ? .store : .lzma2)
            let name = ["store": "store", "lzma2": "lzma2", "lzma": "lzma1", "deflate": "deflate", "bzip2": "bzip2", "ppmd": "ppmd", "zstd": "zstd"][method.rawValue]
            guard let name, engine.sevenZipMethods.contains(method) else {
                throw ArchiveError.invalidArgument("7z with \(method.displayName) is not available in this libarchive build.")
            }
            try option("7zip", "compression", name)
            _ = archive_write_set_option(a, "7zip", "compression-level", String(level))
        case .tar:
            try check(archive_write_set_format_pax_restricted(a), "TAR")
        case .cpio:
            try check(archive_write_set_format_cpio_newc(a), "CPIO")
        case .xar:
            try check(archive_write_set_format_xar(a), "XAR")
        case .ar:
            try check(archive_write_set_format_ar_bsd(a), "ar")
        case .iso:
            try check(archive_write_set_format_iso9660(a), "ISO 9660")
            _ = archive_write_set_option(a, "iso9660", "rockridge", "1")
            _ = archive_write_set_option(a, "iso9660", "joliet", "1")
        case .warc:
            try check(archive_write_set_format_warc(a), "WARC")
        case .shar:
            try check(archive_write_set_format_shar_dump(a), "shar")
        default:
            if let d = FormatCatalog.descriptor(for: format), d.kind == .compressedArchive {
                try check(archive_write_set_format_pax_restricted(a), "TAR")
            } else if let d = FormatCatalog.descriptor(for: format), d.kind == .compressionStream {
                try check(archive_write_set_format_raw(a), "raw stream")
                isRaw = true
            } else {
                throw ArchiveError.operationNotSupported(format: format, operation: "creation", reason: "libarchive cannot write this format.")
            }
        }
        if settings.encryption != nil, !isZipFamily {
            throw ArchiveError.operationNotSupported(format: format, operation: "encryption", reason: "Only ZIP and 7z (with the 7-Zip engine) support password protection; use Apple Encrypted Archive or 7z.")
        }

        // Compression layer for tarballs and streams.
        let outer: FormatID? = {
            if let d = FormatCatalog.descriptor(for: format) {
                if d.kind == .compressedArchive { return d.layers.first }
                if d.kind == .compressionStream { return format }
            }
            return nil
        }()
        if let outer {
            let threads = settings.threads.map(String.init) ?? "0"
            switch outer {
            case .gzip:
                try check(archive_write_add_filter_gzip(a), "gzip")
                try option("gzip", "compression-level", String(max(1, level)))
            case .bzip2:
                try check(archive_write_add_filter_bzip2(a), "bzip2")
                try option("bzip2", "compression-level", String(max(1, level)))
            case .xz:
                try check(archive_write_add_filter_xz(a), "xz")
                try option("xz", "compression-level", String(level))
                if engine.xzThreads { _ = archive_write_set_option(a, "xz", "threads", threads) }
            case .lzma:
                try check(archive_write_add_filter_lzma(a), "lzma")
                try option("lzma", "compression-level", String(level))
            case .zstd:
                try check(archive_write_add_filter_zstd(a), "zstd")
                try option("zstd", "compression-level", String(Self.zstdLevels[level]))
                if engine.zstdThreads { _ = archive_write_set_option(a, "zstd", "threads", threads) }
            case .lz4:
                try check(archive_write_add_filter_lz4(a), "lz4")
                try option("lz4", "compression-level", String(max(1, level)))
            case .lzip:
                try check(archive_write_add_filter_lzip(a), "lzip")
                try option("lzip", "compression-level", String(level))
            case .unixCompress:
                try check(archive_write_add_filter_compress(a), "compress")
            case .brotli:
                guard engine.brotliAvailable else { throw ArchiveError.noEngineAvailable(format: format, operation: "create", hint: nil) }
                brotliQuality = min(11, level + 2)
            default:
                throw ArchiveError.operationNotSupported(format: format, operation: "creation", reason: "Unknown compression layer.")
            }
        }

        let files = request.items.filter { $0.type == .file }
        if isRaw {
            guard request.items.count == 1, files.count == 1 else {
                throw ArchiveError.operationNotSupported(format: format, operation: "multiple files",
                    reason: "A \(FormatCatalog.descriptor(for: format)?.name ?? format.rawValue) stream holds exactly one file. Use the TAR variant (e.g. .tar\(format == .gzip ? ".gz" : "." + format.rawValue)) for folders or several files.")
            }
        }
        if let pw = request.password, settings.encryption != nil {
            let rc = pw.withCString { archive_write_set_passphrase(a, $0) }
            if rc != LA.ok { throw ArchiveError.invalidArgument("Could not set the password: \(LA.errorString(a))") }
        }

        // Output (temporary file, moved into place on success).
        let out = try AtomicOutputFile(request.output)
        let output: LAOutput
        do { output = try LAOutput(fd: out.fd, brotliQuality: brotliQuality, progress: progress) } catch { out.discard(); throw error }
        let ctx = Unmanaged.passUnretained(output).toOpaque()
        // No padding of the final block: tape-style 10 KB blocking only wastes space on disk.
        archive_write_set_bytes_in_last_block(a, 1)
        let openRC = archive_write_open(a, ctx, nil, { _, ctx, buf, len in
            guard let ctx else { return -1 }
            return Unmanaged<LAOutput>.fromOpaque(ctx).takeUnretainedValue().write(buf, len)
        }, nil)
        guard openRC == LA.ok else {
            out.discard()
            throw ArchiveError.io(path: request.output.path, code: archive_errno(a), message: LA.errorString(a))
        }

        let total = request.items.reduce(UInt64(0)) { $0 + $1.size }
        progress.setTotal(bytes: total, items: request.items.count)
        progress.setPhase("Compressing")
        var entryCount = 0
        do {
            try writeEntries(a, isRaw: isRaw, isEpub: format == .epub, output: output)
            entryCount = request.items.count
            if archive_write_close(a) != LA.ok {
                if let e = output.error { throw e }
                throw ArchiveError.io(path: request.output.path, code: archive_errno(a), message: LA.errorString(a))
            }
            try output.finish()
            if format == .epub {
                let normalized = try ZipFirstEntryNormalizer.normalize(try Data(contentsOf: out.tempURL))
                try normalized.write(to: out.tempURL)
            }
            try progress.checkCancelled()
            try out.commit()
        } catch {
            out.discard()
            throw error
        }
        progress.flush()
        return CreateResult(outputs: [request.output], inputBytes: total, outputBytes: output.bytes, entryCount: entryCount,
                            warnings: warnings, engine: .libarchive)
    }

    private func writeEntries(_ a: OpaquePointer, isRaw: Bool, isEpub: Bool, output: LAOutput) throws {
        guard let disk = archive_read_disk_new() else { throw ArchiveError.internalError("libarchive allocation failed") }
        defer { archive_read_free(disk) }
        var behavior: Int32 = 0
        switch settings.metadata {
        case .macPreservation: behavior = LA.readDiskMacCopyfile
        case .standard: behavior = LA.readDiskNoXattr | LA.readDiskNoACL | LA.readDiskNoFFlags
        case .crossPlatform: behavior = LA.readDiskNoXattr | LA.readDiskNoACL | LA.readDiskNoFFlags
        }
        archive_read_disk_set_behavior(disk, behavior)
        archive_read_disk_set_standard_lookup(disk)
        if settings.symlinks == .follow { archive_read_disk_set_symlink_logical(disk) } else { archive_read_disk_set_symlink_physical(disk) }

        guard let resolver = archive_entry_linkresolver_new() else { throw ArchiveError.internalError("libarchive allocation failed") }
        defer { archive_entry_linkresolver_free(resolver) }
        archive_entry_linkresolver_set_strategy(resolver, archive_format(a))

        var items = request.items
        if isEpub {
            // OCF: "mimetype" must be the first entry and stored uncompressed.
            if let i = items.firstIndex(where: { $0.archivePath == "mimetype" || $0.archivePath.hasSuffix("/mimetype") && $0.archivePath.split(separator: "/").count == 2 }) {
                items.insert(items.remove(at: i), at: 0)
            } else {
                warnings.append("No 'mimetype' file was found at the top level; the result will not be a valid EPUB.")
            }
        }

        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        for (n, item) in items.enumerated() {
            try progress.checkCancelled()
            progress.setCurrentItem(item.archivePath)
            guard var entry: OpaquePointer? = archive_entry_new() else { throw ArchiveError.internalError("allocation failed") }
            defer { if let e = entry { archive_entry_free(e) } }
            archive_entry_copy_sourcepath(entry, item.url.path)
            let rc = archive_read_disk_entry_from_file(disk, entry, -1, nil)
            if rc < LA.warn {
                warnings.append("Skipped “\(item.archivePath)”: \(LA.errorString(disk))")
                progress.warning()
                continue
            }
            var path = isRaw ? item.url.lastPathComponent : item.archivePath
            if item.type == .directory, !path.hasSuffix("/") { path += "/" }
            archive_entry_set_pathname_utf8(entry, path)
            if settings.metadata == .crossPlatform {
                archive_entry_set_uname(entry, nil)
                archive_entry_set_gname(entry, nil)
                archive_entry_set_uid(entry, 0)
                archive_entry_set_gid(entry, 0)
                archive_entry_copy_mac_metadata(entry, nil, 0)
            }
            if isEpub, n == 0, path == "mimetype" {
                _ = archive_write_zip_set_compression_store(a)
                // epubcheck rejects extra fields on the mimetype entry; drop timestamps/ownership.
                archive_entry_unset_mtime(entry)
                archive_entry_unset_atime(entry)
                archive_entry_unset_ctime(entry)
                archive_entry_unset_birthtime(entry)
            } else if isEpub, n == 1 {
                _ = archive_write_zip_set_compression_deflate(a)
            }
            var sparse: OpaquePointer?
            if !isRaw { archive_entry_linkify(resolver, &entry, &sparse) }
            guard let e = entry else { continue } // deferred by the link resolver
            try writeOne(a, entry: e, item: item, buffer: &buffer)
            if let s = sparse {
                // A deferred hard-link entry that now carries data.
                try writeOne(a, entry: s, item: item, buffer: &buffer)
            }
            progress.itemCompleted()
        }
        // Flush entries deferred by the link resolver.
        var entry: OpaquePointer?
        var sparse: OpaquePointer?
        while true {
            entry = nil
            archive_entry_linkify(resolver, &entry, &sparse)
            guard let e = entry else { break }
            let src = archive_entry_sourcepath(e).map { String(cString: $0) } ?? ""
            let item = request.items.first { $0.url.path == src } ?? request.items[0]
            try writeOne(a, entry: e, item: item, buffer: &buffer)
            archive_entry_free(e)
        }
    }

    private func writeOne(_ a: OpaquePointer, entry: OpaquePointer, item: SourceItem, buffer: inout [UInt8]) throws {
        let rc = archive_write_header(a, entry)
        if rc == LA.warn { warnings.append("“\(item.archivePath)”: \(LA.errorString(a))") }
        if rc < LA.warn {
            if rc == LA.fatal { throw ArchiveError.io(path: item.archivePath, code: archive_errno(a), message: LA.errorString(a)) }
            warnings.append("Skipped “\(item.archivePath)”: \(LA.errorString(a))")
            progress.warning()
            return
        }
        let ft = UInt32(archive_entry_filetype(entry))
        guard ft & LA.ifmt == LA.ifreg, archive_entry_size(entry) > 0 else { return }
        let src = archive_entry_sourcepath(entry).map { String(cString: $0) } ?? item.url.path
        let fd = open(src, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw ArchiveError.io(path: src, code: errno, message: String(cString: strerror(errno)))
        }
        defer { close(fd) }
        var remaining = archive_entry_size(entry)
        while remaining > 0 {
            try progress.checkCancelled()
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, min($0.count, Int(remaining))) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ArchiveError.io(path: src, code: errno, message: String(cString: strerror(errno)))
            }
            if n == 0 {
                // The file shrank while being archived; pad so the archive stays consistent, and warn.
                warnings.append("“\(item.archivePath)” changed while it was being archived.")
                break
            }
            let w = buffer.withUnsafeBytes { archive_write_data(a, $0.baseAddress, n) }
            if w < 0 {
                throw ArchiveError.io(path: item.archivePath, code: archive_errno(a), message: LA.errorString(a))
            }
            remaining -= Int64(n)
            progress.add(processed: UInt64(n))
        }
    }
}
