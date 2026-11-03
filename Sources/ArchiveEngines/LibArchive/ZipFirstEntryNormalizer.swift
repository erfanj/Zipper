import Foundation
import ArchiveCore

/// Rewrites the first entry of a ZIP file so its local header has no extra field and no trailing
/// data descriptor, shifting every later offset. Required for EPUB's `mimetype` entry (OCF) which
/// libarchive always writes with timestamp/ownership extra fields.
enum ZipFirstEntryNormalizer {
    struct Failure: Error { let reason: String }

    static func normalize(_ data: Data) throws -> Data {
        var d = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 }
        func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
        func put16(_ o: Int, _ v: Int) { d[o] = UInt8(v & 0xFF); d[o + 1] = UInt8((v >> 8) & 0xFF) }
        func put32(_ o: Int, _ v: UInt32) { for i in 0..<4 { d[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
        func put64(_ o: Int, _ v: UInt64) { for i in 0..<8 { d[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) } }

        guard d.count > 30, u32(0) == 0x04034B50 else { throw Failure(reason: "not a ZIP local header") }
        // Locate end of central directory.
        var eocd = -1
        var i = d.count - 22
        while i >= max(0, d.count - 22 - 65535) {
            if u32(i) == 0x06054B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure(reason: "no end of central directory") }
        var cdOffset = UInt64(u32(eocd + 16))
        var zip64EOCD = -1
        if eocd >= 20, u32(eocd - 20) == 0x07064B50 {
            zip64EOCD = Int(u64(eocd - 20 + 8))
            guard zip64EOCD + 56 <= d.count, u32(zip64EOCD) == 0x06064B50 else { throw Failure(reason: "bad ZIP64 record") }
            cdOffset = u64(zip64EOCD + 48)
        }
        let cd = Int(cdOffset)
        guard cd + 46 <= d.count, u32(cd) == 0x02014B50 else { throw Failure(reason: "bad central directory") }
        // First central entry describes the first local entry.
        let crc = u32(cd + 16)
        let csize = u32(cd + 20)
        let usize = u32(cd + 24)
        guard csize != 0xFFFFFFFF else { throw Failure(reason: "first entry too large") }

        let flags = u16(6)
        let nameLen = u16(26)
        let extraLen = u16(28)
        let dataStart = 30 + nameLen + extraLen
        let dataEnd = dataStart + Int(csize)
        var descriptorLen = 0
        if flags & 0x8 != 0 {
            descriptorLen = u32(dataEnd) == 0x08074B50 ? 16 : 12
            // ZIP64 descriptors carry 8-byte sizes.
            if descriptorLen == 16, dataEnd + 24 <= d.count, u32(dataEnd + 24) == 0x04034B50 || u32(dataEnd + 24) == 0x02014B50 { descriptorLen = 24 }
        }
        let delta = extraLen + descriptorLen
        if delta == 0 { return data }

        // New first entry.
        var header = Array(d[0..<30 + nameLen])
        header[6] = UInt8(flags & ~0x8 & 0xFF)
        header[7] = UInt8((flags & ~0x8) >> 8)
        func set32(_ arr: inout [UInt8], _ o: Int, _ v: UInt32) { for k in 0..<4 { arr[o + k] = UInt8((v >> (8 * UInt32(k))) & 0xFF) } }
        set32(&header, 14, crc)
        set32(&header, 18, csize)
        set32(&header, 22, usize)
        header[28] = 0
        header[29] = 0
        var out = header + Array(d[dataStart..<dataEnd])
        let restStart = dataEnd + descriptorLen
        // Shift offsets in the central directory (everything after the first entry moved by -delta).
        let entries = zip64EOCD >= 0 ? Int(u64(zip64EOCD + 32)) : u16(eocd + 10)
        var p = cd
        for _ in 0..<entries {
            guard u32(p) == 0x02014B50 else { throw Failure(reason: "central directory entry signature") }
            let n = u16(p + 28), x = u16(p + 30), c = u16(p + 32)
            let rel = u32(p + 42)
            if rel == 0xFFFFFFFF {
                // ZIP64 extra: find the offset field (after any 64-bit sizes that are present).
                var e = p + 46 + n
                let end = e + x
                while e + 4 <= end {
                    let id = u16(e), len = u16(e + 2)
                    if id == 0x0001 {
                        var f = e + 4
                        if u32(p + 24) == 0xFFFFFFFF { f += 8 }
                        if u32(p + 20) == 0xFFFFFFFF { f += 8 }
                        let old = u64(f)
                        if old > 0 { put64(f, old - UInt64(delta)) }
                    }
                    e += 4 + len
                }
            } else if rel > 0 {
                put32(p + 42, rel - UInt32(delta))
            }
            p += 46 + n + x + c
        }
        if zip64EOCD >= 0 {
            put64(zip64EOCD + 48, cdOffset - UInt64(delta))
            put64(eocd - 20 + 8, UInt64(zip64EOCD - delta))
            if u32(eocd + 16) != 0xFFFFFFFF { put32(eocd + 16, UInt32(cdOffset) - UInt32(delta)) }
        } else {
            put32(eocd + 16, UInt32(cdOffset) - UInt32(delta))
        }
        out += d[restStart...]
        return Data(out)
    }
}
