import Foundation
import CZlib

/// The outcome of identifying a file.
public struct DetectionResult: Sendable, Hashable {
    public enum Basis: String, Sendable, Codable {
        /// Content signature and extension agree.
        case contentAndExtension
        /// Content signature only (extension missing or misleading).
        case content
        /// Extension only (format has no reliable signature, or content was unreadable).
        case extensionOnly
    }

    public var format: FormatID
    public var layers: [FormatID]
    public var basis: Basis
    public var multipart: MultipartSet?
    /// Other formats that matched less well.
    public var alternatives: [FormatID]

    public var descriptor: FormatDescriptor? { FormatCatalog.descriptor(for: format) }

    public func source(for url: URL) -> ArchiveSource {
        if let mp = multipart {
            return ArchiveSource(url: mp.firstVolume, volumes: mp.volumes, format: format, layers: layers)
        }
        return ArchiveSource(url: url, format: format, layers: layers)
    }
}

/// Identifies formats from content signatures first and extensions second.
public enum FormatDetector {
    /// Engines can register a probe that identifies the payload inside a compression stream
    /// (e.g. "is this .xz a tarball?"). Called only for compression streams.
    nonisolated(unsafe) public static var innerFormatProbe: ((URL, FormatID) -> FormatID?)?

    struct Sample {
        var head: [UInt8]
        var tail: [UInt8]
        var size: UInt64
    }

    static func readSample(_ url: URL, headBytes: Int = 0x8800) throws -> Sample {
        guard let fh = FileHandle(forReadingAtPath: url.path) else {
            if !FileManager.default.fileExists(atPath: url.path) { throw ArchiveError.fileNotFound(path: url.path) }
            throw ArchiveError.permissionDenied(path: url.path)
        }
        defer { try? fh.close() }
        let head = [UInt8](fh.readData(ofLength: headBytes))
        let size = fh.seekToEndOfFile()
        var tail: [UInt8] = []
        if size > UInt64(head.count) {
            let n = UInt64(min(1024, size))
            fh.seek(toFileOffset: size - n)
            tail = [UInt8](fh.readData(ofLength: Int(n)))
        } else {
            tail = Array(head.suffix(1024))
        }
        return Sample(head: head, tail: tail, size: size)
    }

    static func matches(_ sig: MagicSignature, _ s: Sample) -> Bool {
        if sig.fromEnd {
            let start = s.tail.count - sig.offset
            guard start >= 0, start + sig.bytes.count <= s.tail.count else { return false }
            return Array(s.tail[start..<start + sig.bytes.count]) == sig.bytes
        }
        guard sig.offset + sig.bytes.count <= s.head.count else { return false }
        return Array(s.head[sig.offset..<sig.offset + sig.bytes.count]) == sig.bytes
    }

    /// Formats whose signature matches the content, strongest first. Packages are excluded (they
    /// share their container's signature and are identified by extension).
    static func contentMatches(_ s: Sample) -> (strong: [FormatID], weak: [FormatID]) {
        var strong: [FormatID] = []
        var weak: [FormatID] = []
        for d in FormatCatalog.all where d.kind != .compressedArchive {
            for sig in d.signatures where matches(sig, s) {
                if sig.strength == .strong, d.kind != .package { strong.append(d.id) } else { weak.append(d.id) }
                break
            }
        }
        // RAR5's signature extends RAR4's; deb extends ar. Prefer the most specific (longest) match.
        if strong.contains(.deb) { strong.removeAll { $0 == .ar } }
        if strong.contains(.stuffItX) { strong.removeAll { $0 == .stuffIt } }
        return (strong, weak)
    }

    /// Identifies `url`. Returns nil if nothing matches.
    public static func detect(_ url: URL) throws -> DetectionResult? {
        let multipart = MultipartDetector.detect(url)
        let contentURL = multipart?.firstVolume ?? url
        let readURL = FileManager.default.fileExists(atPath: contentURL.path) ? contentURL : (multipart?.volumes.first ?? url)
        let sample = try readSample(readURL)
        let (strong, weak) = contentMatches(sample)

        // Extension: for multipart sets use the implied format / base name.
        var extFormats: [FormatDescriptor] = []
        if let mp = multipart {
            if let implied = mp.impliedFormat, let d = FormatCatalog.descriptor(for: implied) { extFormats = [d] }
            if let m = FormatCatalog.matchExtension(of: mp.baseName) { extFormats += m.formats }
        } else if let m = FormatCatalog.matchExtension(of: url.lastPathComponent) {
            extFormats = m.formats
        }

        var result: DetectionResult?

        // 1. Extension agrees with a content match (including packages over their container,
        //    and compressed tarballs over their outer stream).
        for d in extFormats {
            let container = d.effectiveContainer
            if strong.contains(d.id) || strong.contains(container) || (d.kind == .package && weak.contains(d.id) && strong.contains(where: { $0 == d.baseFormat })) {
                result = DetectionResult(format: d.id, layers: d.layers, basis: .contentAndExtension, multipart: multipart, alternatives: [])
                break
            }
            if d.kind == .compressedArchive, let outer = d.layers.first, strong.contains(outer) || (outer == .brotli) {
                result = DetectionResult(format: d.id, layers: d.layers, basis: outer == .brotli ? .extensionOnly : .contentAndExtension,
                                         multipart: multipart, alternatives: [])
                break
            }
        }

        // 2. Strong content match wins over a misleading or missing extension.
        if result == nil, let first = strong.first {
            result = DetectionResult(format: first, layers: [], basis: .content, multipart: multipart, alternatives: Array(strong.dropFirst()))
        }

        // 3. Weak content + matching extension, or extension alone.
        if result == nil, let d = extFormats.first(where: { weak.contains($0.id) }) ?? extFormats.first {
            result = DetectionResult(format: d.id, layers: d.layers, basis: weak.contains(d.id) ? .contentAndExtension : .extensionOnly,
                                     multipart: multipart, alternatives: extFormats.dropFirst().map(\.id))
        }

        guard var r = result else { return nil }

        // A compression stream may carry a tarball even without a .tar.* name (e.g. "data.gz").
        if let d = r.descriptor, d.kind == .compressionStream {
            if let inner = probeInner(readURL, outer: r.format, sample: sample), inner == .tar,
               let compound = FormatCatalog.all.first(where: { $0.kind == .compressedArchive && $0.layers == [r.format, .tar] }) {
                r = DetectionResult(format: compound.id, layers: compound.layers, basis: r.basis, multipart: multipart, alternatives: [r.format])
            }
        }
        // Content says ZIP but extension says EPUB etc.: package format already chosen above.
        return r
    }

    static func probeInner(_ url: URL, outer: FormatID, sample: Sample) -> FormatID? {
        if outer == .gzip, let tarCheck = gunzipHeaderIsTar(sample.head) { return tarCheck ? .tar : nil }
        return innerFormatProbe?(url, outer)
    }

    /// Inflates the beginning of a gzip stream and checks for a tar header.
    static func gunzipHeaderIsTar(_ head: [UInt8]) -> Bool? {
        guard head.count > 18 else { return nil }
        var stream = z_stream()
        var out = [UInt8](repeating: 0, count: 1024)
        var input = head
        let ok = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard ok == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        let produced: Int = input.withUnsafeMutableBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                stream.next_in = inBuf.baseAddress
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                _ = inflate(&stream, Z_SYNC_FLUSH)
                return outBuf.count - Int(stream.avail_out)
            }
        }
        guard produced >= 262 else { return produced > 0 ? false : nil }
        let magic = Array(out[257..<262])
        if magic == Array("ustar".utf8) { return true }
        // Old V7 tar: check the header checksum.
        return tarChecksumValid(Array(out[0..<512]))
    }

    static func tarChecksumValid(_ block: [UInt8]) -> Bool {
        guard block.count >= 512 else { return false }
        let field = block[148..<156]
        let str = String(decoding: field.filter { $0 != 0 && $0 != 0x20 }, as: UTF8.self)
        guard let stored = Int(str, radix: 8) else { return false }
        var sum = 0
        for (i, b) in block.prefix(512).enumerated() { sum += (148..<156).contains(i) ? 0x20 : Int(b) }
        return sum == stored && block[0] != 0
    }
}
