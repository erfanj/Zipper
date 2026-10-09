import Foundation
import ArchiveCore
import CBrotli

/// Streaming Brotli encoder that forwards compressed bytes to `emit`.
final class BrotliEncoder {
    private let state: OpaquePointer
    private var out = [UInt8](repeating: 0, count: 1 << 16)

    init(quality: Int, windowBits: Int = 22) throws {
        guard let s = BrotliEncoderCreateInstance(nil, nil, nil) else { throw ArchiveError.internalError("Brotli encoder allocation failed") }
        state = s
        BrotliEncoderSetParameter(state, BROTLI_PARAM_QUALITY, UInt32(max(0, min(11, quality))))
        BrotliEncoderSetParameter(state, BROTLI_PARAM_LGWIN, UInt32(max(10, min(24, windowBits))))
    }

    deinit { BrotliEncoderDestroyInstance(state) }

    func process(_ input: UnsafeRawBufferPointer, finish: Bool, emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        var availIn = input.count
        var nextIn: UnsafePointer<UInt8>? = input.baseAddress?.assumingMemoryBound(to: UInt8.self)
        let op = finish ? BROTLI_OPERATION_FINISH : BROTLI_OPERATION_PROCESS
        repeat {
            var produced = 0
            let ok: Bool = out.withUnsafeMutableBufferPointer { ob in
                var availOut = ob.count
                var nextOut: UnsafeMutablePointer<UInt8>? = ob.baseAddress
                let r = BrotliEncoderCompressStream(state, op, &availIn, &nextIn, &availOut, &nextOut, nil)
                produced = ob.count - availOut
                return r != 0
            }
            guard ok else { throw ArchiveError.internalError("Brotli compression failed") }
            if produced > 0 { try out.withUnsafeBytes { try emit(UnsafeRawBufferPointer(rebasing: $0[0..<produced])) } }
        } while availIn > 0 || BrotliEncoderHasMoreOutput(state) != 0 || (finish && BrotliEncoderIsFinished(state) == 0)
    }
}

/// Pull-based Brotli decoder over a file, with an output bound for bomb protection.
final class BrotliDecoder {
    private let state: OpaquePointer
    private let handle: FileHandle
    private var input = [UInt8]()
    private var inputOffset = 0
    private(set) var outputBuffer = [UInt8](repeating: 0, count: 1 << 17)
    private(set) var finished = false
    private(set) var compressedRead: UInt64 = 0
    private var eofInput = false

    init(url: URL) throws {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { throw ArchiveError.fileNotFound(path: url.path) }
        handle = fh
        guard let s = BrotliDecoderCreateInstance(nil, nil, nil) else { throw ArchiveError.internalError("Brotli decoder allocation failed") }
        state = s
    }

    deinit {
        BrotliDecoderDestroyInstance(state)
        try? handle.close()
    }

    /// Decodes the next chunk. Returns the number of valid bytes in `outputBuffer` (0 at end).
    func nextChunk() throws -> Int {
        if finished { return 0 }
        while true {
            if inputOffset >= input.count, !eofInput {
                let d = handle.readData(ofLength: 1 << 16)
                if d.isEmpty { eofInput = true } else {
                    input = [UInt8](d)
                    inputOffset = 0
                    compressedRead += UInt64(d.count)
                }
            }
            var produced = 0
            var result: BrotliDecoderResult = BROTLI_DECODER_RESULT_ERROR
            input.withUnsafeBufferPointer { ib in
                outputBuffer.withUnsafeMutableBufferPointer { ob in
                    var availIn = ib.count - inputOffset
                    var nextIn: UnsafePointer<UInt8>? = ib.baseAddress.map { $0 + inputOffset }
                    var availOut = ob.count
                    var nextOut: UnsafeMutablePointer<UInt8>? = ob.baseAddress
                    result = BrotliDecoderDecompressStream(state, &availIn, &nextIn, &availOut, &nextOut, nil)
                    inputOffset = ib.count - availIn
                    produced = ob.count - availOut
                }
            }
            switch result {
            case BROTLI_DECODER_RESULT_SUCCESS:
                finished = true
                return produced
            case BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT:
                return produced
            case BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT:
                if produced > 0 { return produced }
                if eofInput { throw ArchiveError.truncated(details: "The Brotli stream ends before its end marker.") }
            default:
                let code = BrotliDecoderGetErrorCode(state)
                let msg = BrotliDecoderErrorString(code).map { String(cString: $0) } ?? "decoder error"
                throw ArchiveError.damaged(details: "Brotli: \(msg)")
            }
        }
    }

    static var version: String {
        let v = BrotliDecoderVersion()
        return "\(v >> 24).\((v >> 12) & 0xFFF).\(v & 0xFFF)"
    }
}
