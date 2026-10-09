import Foundation
import ArchiveCore
import CArchive

/// Measures real compressed sizes of a sample with libarchive's codecs (and Brotli), for the
/// compression advisor. LZMA2 is measured through the XZ container, which uses the same codec as 7z.
public struct LibArchiveSampleCompressor: SampleCompressor {
    public init() {}

    final class Sink { var count = 0 }

    public func compressedSize(of data: Data, method: CompressionMethod, level: Int) -> Int? {
        if method == .store { return data.count }
        if method == .brotli {
            guard let enc = try? BrotliEncoder(quality: min(11, level + 2)) else { return nil }
            var n = 0
            try? data.withUnsafeBytes { try enc.process($0, finish: true) { n += $0.count } }
            return n
        }
        guard let a = archive_write_new() else { return nil }
        let sink = Sink()
        // archive_write_free may flush through the callback, so the sink must outlive it.
        defer { withExtendedLifetime(sink) { _ = archive_write_free(a) } }
        archive_write_set_format_raw(a)
        let rc: Int32
        switch method {
        case .deflate, .zlib: rc = archive_write_add_filter_gzip(a)
        case .bzip2: rc = archive_write_add_filter_bzip2(a)
        case .xz, .lzma2: rc = archive_write_add_filter_xz(a)
        case .lzma: rc = archive_write_add_filter_lzma(a)
        case .zstd: rc = archive_write_add_filter_zstd(a)
        case .lz4: rc = archive_write_add_filter_lz4(a)
        default: return nil
        }
        guard rc == LA.ok else { return nil }
        let filter = ["deflate": "gzip", "zlib": "gzip", "bzip2": "bzip2", "xz": "xz", "lzma2": "xz", "lzma": "lzma", "zstd": "zstd", "lz4": "lz4"][method.rawValue]!
        let lvl = filter == "zstd" ? LibArchiveWriter.zstdLevels[min(9, max(0, level))] : max(1, min(9, level))
        _ = archive_write_set_filter_option(a, filter, "compression-level", String(lvl))
        archive_write_set_bytes_in_last_block(a, 1)
        let ctx = Unmanaged.passUnretained(sink).toOpaque()
        guard archive_write_open(a, ctx, nil, { _, ctx, _, len in
            Unmanaged<Sink>.fromOpaque(ctx!).takeUnretainedValue().count += len
            return len
        }, nil) == LA.ok else { return nil }
        guard let e = archive_entry_new() else { return nil }
        defer { archive_entry_free(e) }
        archive_entry_set_pathname(e, "sample")
        archive_entry_set_filetype(e, UInt32(LA.ifreg))
        archive_entry_set_size(e, Int64(data.count))
        archive_entry_set_perm(e, 0o644)
        guard archive_write_header(a, e) == LA.ok else { return nil }
        _ = data.withUnsafeBytes { archive_write_data(a, $0.baseAddress, data.count) }
        archive_write_close(a)
        return sink.count
    }
}
