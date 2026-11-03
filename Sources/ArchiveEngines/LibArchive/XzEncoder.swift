import Foundation
import ArchiveCore
import CLzma

/// Multithreaded .xz encoder used in place of libarchive's xz filter.
///
/// libarchive gives no control over the encoder's timeout. At high presets a whole block (3× the
/// dictionary, 192 MB at level 9) can be compressed inside `archive_write_close` without a single
/// callback, so a cancel or pause would wait for the entire block. With `lzma_mt.timeout`,
/// `lzma_code` returns at least every `timeoutMs` milliseconds, which lets `poll` honour
/// cancel/pause promptly. The thread count is also capped so that encoder memory stays within
/// a budget: at level 9 each thread needs roughly 1 GB.
final class XzEncoder {
    private var strm = lzma_stream()
    private var out = [UInt8](repeating: 0, count: 1 << 16)
    private let poll: () throws -> Void
    let threads: UInt32
    let memoryUsage: UInt64

    static let timeoutMs: UInt32 = 250

    init(preset: Int, threads requested: Int?, memoryBudget: UInt64 = ProcessInfo.processInfo.physicalMemory / 4, poll: @escaping () throws -> Void) throws {
        self.poll = poll
        var mt = lzma_mt()
        mt.flags = 0
        mt.block_size = 0                       // liblzma default: 3 × dictionary size
        mt.timeout = Self.timeoutMs
        mt.preset = UInt32(max(0, min(9, preset)))
        mt.filters = nil
        mt.check = LZMA_CHECK_CRC64
        var n = UInt32(max(1, requested.flatMap { $0 > 0 ? $0 : nil } ?? Int(lzma_cputhreads())))
        mt.threads = n
        // Reduce threads until the encoder fits the memory budget (at least one thread).
        while n > 1 {
            mt.threads = n
            let usage = lzma_stream_encoder_mt_memusage(&mt)
            if usage != UInt64.max, usage <= memoryBudget { break }
            n -= 1
        }
        mt.threads = n
        threads = n
        memoryUsage = lzma_stream_encoder_mt_memusage(&mt)
        let rc = lzma_stream_encoder_mt(&strm, &mt)
        guard rc == LZMA_OK else {
            lzma_end(&strm)
            throw rc == LZMA_MEM_ERROR ? ArchiveError.internalError("Not enough memory for the xz encoder")
                                       : ArchiveError.invalidArgument("xz encoder setup failed (code \(rc.rawValue))")
        }
    }

    deinit { lzma_end(&strm) }

    func process(_ input: UnsafeRawBufferPointer, finish: Bool, emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        strm.next_in = input.baseAddress?.assumingMemoryBound(to: UInt8.self)
        strm.avail_in = input.count
        defer { strm.next_in = nil; strm.avail_in = 0 }
        let action = finish ? LZMA_FINISH : LZMA_RUN
        while true {
            try poll()
            var produced = 0
            let rc: lzma_ret = out.withUnsafeMutableBufferPointer { ob in
                strm.next_out = ob.baseAddress
                strm.avail_out = ob.count
                let r = lzma_code(&strm, action)
                produced = ob.count - strm.avail_out
                strm.next_out = nil
                strm.avail_out = 0
                return r
            }
            if produced > 0 { try out.withUnsafeBytes { try emit(UnsafeRawBufferPointer(rebasing: $0[0..<produced])) } }
            switch rc {
            case LZMA_STREAM_END:
                return
            case LZMA_OK:
                // RUN: done once all input is consumed and the output buffer wasn't filled.
                if !finish, strm.avail_in == 0, produced < out.count { return }
            case LZMA_MEM_ERROR:
                throw ArchiveError.internalError("Out of memory while compressing with xz")
            default:
                throw ArchiveError.internalError("xz compression failed (code \(rc.rawValue))")
            }
        }
    }
}
