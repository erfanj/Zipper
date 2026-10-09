import Foundation
import ArchiveCore
import CArchive
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A read handle over one archive (possibly multi-volume, possibly behind a Brotli layer).
final class LAReader {
    let a: OpaquePointer
    let source: ArchiveSource
    private let passBox: PassphraseBox
    private var cPaths: [UnsafeMutablePointer<CChar>?] = []
    private var brotli: BrotliReadContext?

    enum Input {
        case files
        case brotli
    }

    init(source: ArchiveSource, options: ReadOptions, raw: Bool, input: Input = .files) throws {
        _ = LA.localeConfigured
        guard let a = archive_read_new() else { throw ArchiveError.internalError("libarchive allocation failed") }
        self.a = a
        self.source = source
        passBox = PassphraseBox(archiveURL: source.url, provider: options.passwordProvider)
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        if raw { archive_read_support_format_raw(a) }
        if let enc = options.filenameEncoding, !enc.isEmpty {
            _ = archive_read_set_options(a, "hdrcharset=\(enc)")
        }
        archive_read_set_passphrase_callback(a, Unmanaged.passUnretained(passBox).toOpaque()) { _, ctx in
            guard let ctx else { return nil }
            return Unmanaged<PassphraseBox>.fromOpaque(ctx).takeUnretainedValue().next()
        }

        let rc: Int32
        switch input {
        case .brotli:
            let ctx = try BrotliReadContext(url: source.url)
            brotli = ctx
            rc = archive_read_open(a, Unmanaged.passUnretained(ctx).toOpaque(), nil, { _, ctx, buf in
                guard let ctx, let buf else { return -1 }
                let c = Unmanaged<BrotliReadContext>.fromOpaque(ctx).takeUnretainedValue()
                return c.read(buf)
            }, nil)
        case .files:
            for v in source.volumes {
                // Note: all stored properties are initialised, so throwing here runs deinit, which
                // frees the handle. Freeing it here as well would be a double free.
                guard FileManager.default.isReadableFile(atPath: v.path) else {
                    if FileManager.default.fileExists(atPath: v.path) { throw ArchiveError.permissionDenied(path: v.path) }
                    throw source.volumes.count > 1 ? ArchiveError.missingVolume(expected: [v.lastPathComponent]) : ArchiveError.fileNotFound(path: v.path)
                }
            }
            if source.volumes.count > 1 {
                cPaths = source.volumes.map { strdup($0.path) } + [nil]
                rc = cPaths.withUnsafeMutableBufferPointer { buf in
                    buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
                        archive_read_open_filenames(a, $0, 1 << 16)
                    }
                }
            } else {
                rc = archive_read_open_filename(a, source.url.path, 1 << 16)
            }
        }
        if rc != LA.ok {
            let msg = LA.errorString(a)
            let err = archive_errno(a)
            if let e = brotli?.error { throw e }
            throw LibArchiveErrorMapper.map(msg, archive: source.url, entry: nil, errnoValue: err)
        }
    }

    deinit {
        archive_read_free(a)
        for p in cPaths { free(p) }
    }

    var passwordUsed: Secret? { passBox.lastSupplied }
    var passwordWasRequested: Bool { passBox.asked > 0 }

    func error(entry: String?) -> ArchiveError {
        if let e = brotli?.error { return e }
        var e = LibArchiveErrorMapper.map(LA.errorString(a), archive: source.url, entry: entry, errnoValue: archive_errno(a))
        if case .passwordRequired = e, passBox.asked > 0, passBox.lastSupplied != nil {
            e = .incorrectPassword(archive: source.url.path)
        }
        if case .missingVolume = e, source.volumes.count > 0, let mp = MultipartDetector.detect(source.url) {
            e = .missingVolume(expected: mp.missing.isEmpty ? [mp.nextVolumeName] : mp.missing)
        }
        return e
    }

    /// Compressed bytes consumed so far (for progress).
    var compressedBytesRead: UInt64 {
        if let b = brotli { return b.compressedRead }
        let n = archive_filter_bytes(a, -1)
        return n > 0 ? UInt64(n) : 0
    }

    var formatName: String? { archive_format_name(a).map { String(cString: $0) } }

    var filterNames: [String] {
        var out: [String] = []
        let n = archive_filter_count(a)
        guard n > 1 else { return brotli != nil ? ["brotli"] : [] }
        for i in 0..<(n - 1) {
            if let s = archive_filter_name(a, i) { out.append(String(cString: s)) }
        }
        if brotli != nil { out.append("brotli") }
        return out
    }

    var hasEncryptedEntries: Bool? {
        let r = archive_read_has_encrypted_entries(a)
        return r < 0 ? nil : r != 0
    }
}

/// Feeds Brotli-decoded bytes to libarchive's read callback.
final class BrotliReadContext {
    let decoder: BrotliDecoder
    var error: ArchiveError?
    init(url: URL) throws { decoder = try BrotliDecoder(url: url) }
    var compressedRead: UInt64 { decoder.compressedRead }

    func read(_ buf: UnsafeMutablePointer<UnsafeRawPointer?>) -> Int {
        do {
            let n = try decoder.nextChunk()
            decoder.outputBuffer.withUnsafeBytes { buf.pointee = $0.baseAddress }
            return n
        } catch let e as ArchiveError {
            error = e
            return -1
        } catch {
            return -1
        }
    }
}

/// Output for libarchive writers: counts bytes, optionally Brotli-compresses, writes to a descriptor.
final class LAOutput {
    let fd: Int32
    private(set) var bytes: UInt64 = 0
    var error: ArchiveError?
    let brotli: BrotliEncoder?
    let progress: OperationProgress?

    init(fd: Int32, brotliQuality: Int?, progress: OperationProgress?) throws {
        self.fd = fd
        self.progress = progress
        brotli = try brotliQuality.map { try BrotliEncoder(quality: $0) }
    }

    func write(_ ptr: UnsafeRawPointer?, _ len: Int) -> Int {
        guard let ptr, len > 0 else { return 0 }
        do {
            let buf = UnsafeRawBufferPointer(start: ptr, count: len)
            if let b = brotli {
                try b.process(buf, finish: false) { try rawWrite($0) }
            } else {
                try rawWrite(buf)
            }
            return len
        } catch let e as ArchiveError {
            error = e
            return -1
        } catch {
            return -1
        }
    }

    func finish() throws {
        if let b = brotli {
            try b.process(UnsafeRawBufferPointer(start: nil, count: 0), finish: true) { try rawWrite($0) }
        }
        if let error { throw error }
    }

    private func rawWrite(_ buf: UnsafeRawBufferPointer) throws {
        var off = 0
        while off < buf.count {
            let n = Foundation.write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
            if n < 0 {
                if errno == EINTR { continue }
                let e = errno
                throw e == ENOSPC ? ArchiveError.insufficientSpace(needed: 0, available: POSIX_available(fd)) : ArchiveError.io(path: "", code: e, message: String(cString: strerror(e)))
            }
            off += n
        }
        bytes += UInt64(buf.count)
        progress?.setOutput(bytes)
    }
}

func POSIX_available(_ fd: Int32) -> UInt64 {
    var s = statvfs()
    guard fstatvfs(fd, &s) == 0 else { return 0 }
    return UInt64(s.f_bavail) * UInt64(s.f_frsize)
}

/// Writes an output file to a temporary sibling and moves it into place only on success.
final class AtomicOutputFile {
    let finalURL: URL
    let tempURL: URL
    let fd: Int32
    private var done = false

    init(_ url: URL) throws {
        finalURL = url
        let dir = url.deletingLastPathComponent()
        tempURL = dir.appendingPathComponent(".\(url.lastPathComponent).ua-\(UInt32.random(in: 0...UInt32.max)).partial")
        fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let e = errno
            if e == EACCES || e == EPERM || e == EROFS { throw ArchiveError.permissionDenied(path: dir.path) }
            throw ArchiveError.io(path: dir.path, code: e, message: String(cString: strerror(e)))
        }
    }

    /// Moves the finished file into place without replacing an existing file.
    func commit() throws {
        guard !done else { return }
        done = true
        if fsync(fd) != 0 { /* best effort */ }
        close(fd)
        if link(tempURL.path, finalURL.path) == 0 {
            unlink(tempURL.path)
        } else if errno == EEXIST {
            unlink(tempURL.path)
            throw ArchiveError.destinationExists(path: finalURL.path)
        } else {
            guard !FileManager.default.fileExists(atPath: finalURL.path), rename(tempURL.path, finalURL.path) == 0 else {
                let e = errno
                unlink(tempURL.path)
                throw ArchiveError.io(path: finalURL.path, code: e, message: String(cString: strerror(e)))
            }
        }
    }

    func discard() {
        guard !done else { return }
        done = true
        close(fd)
        unlink(tempURL.path)
    }

    deinit { discard() }
}
