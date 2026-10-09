import Foundation
import ArchiveCore
import CArchive
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// libarchive constants that Swift cannot import (they are defined with casts in the C headers).
enum LA {
    static let ok: Int32 = 0
    static let eof: Int32 = 1
    static let retry: Int32 = -10
    static let warn: Int32 = -20
    static let failed: Int32 = -25
    static let fatal: Int32 = -30

    static let ifmt: UInt32 = 0o170000
    static let ifreg: UInt32 = 0o100000
    static let iflnk: UInt32 = 0o120000
    static let ifsock: UInt32 = 0o140000
    static let ifchr: UInt32 = 0o020000
    static let ifblk: UInt32 = 0o060000
    static let ifdir: UInt32 = 0o040000
    static let ififo: UInt32 = 0o010000

    static let readDiskRestoreATime: Int32 = 0x0001
    static let readDiskHonorNoDump: Int32 = 0x0002
    static let readDiskMacCopyfile: Int32 = 0x0004
    static let readDiskNoTraverseMounts: Int32 = 0x0008
    static let readDiskNoXattr: Int32 = 0x0010
    static let readDiskNoACL: Int32 = 0x0020
    static let readDiskNoFFlags: Int32 = 0x0040

    static let encryptionUnsupported: Int32 = -2
    static let encryptionDontKnow: Int32 = -1

    static func errorString(_ a: OpaquePointer?) -> String {
        guard let a, let s = archive_error_string(a) else { return "unknown error" }
        return String(cString: s)
    }

    static var versionString: String {
        String(cString: archive_version_details())
    }

    static var versionNumber: Int { Int(archive_version_number()) }

    /// Ensures libarchive converts names with a UTF-8 aware locale (it uses the C locale's
    /// character set for some conversions).
    static let localeConfigured: Bool = {
        if let cur = setlocale(LC_CTYPE, nil), String(cString: cur).uppercased().contains("UTF") { return true }
        for candidate in ["C.UTF-8", "en_US.UTF-8", "UTF-8"] {
            if setlocale(LC_CTYPE, candidate) != nil { return true }
        }
        return false
    }()
}

/// Maps libarchive error text onto user-facing errors. libarchive does not expose structured error
/// codes for most conditions, so the mapping is based on its (stable) messages.
enum LibArchiveErrorMapper {
    static func map(_ message: String, archive: URL, entry: String?, errnoValue: Int32) -> ArchiveError {
        let m = message.lowercased()
        if m.contains("incorrect passphrase") || m.contains("wrong password") || m.contains("bad password") {
            return .incorrectPassword(archive: archive.path)
        }
        if m.contains("passphrase required") || m.contains("passphrase is required") || m.contains("password required") {
            return .passwordRequired(archive: archive.path)
        }
        if m.contains("encrypt") && (m.contains("not supported") || m.contains("unsupported")) {
            return .unsupportedEncryption(method: message)
        }
        if m.contains("hmac") || m.contains("authentication") {
            return .authenticationFailed(entry: entry)
        }
        if (m.contains("unsupported") || m.contains("not supported") || m.contains("unknown")) && (m.contains("method") || m.contains("compression") || m.contains("filter") || m.contains("codec")) {
            return .unsupportedMethod(method: message, entry: entry)
        }
        if m.contains("crc") || m.contains("checksum") {
            return entry.map { .checksumMismatch(entry: $0) } ?? .damaged(details: message)
        }
        if m.contains("truncated") || m.contains("premature end") || m.contains("unexpected end") {
            return .truncated(details: message)
        }
        if m.contains("unrecognized archive format") || m.contains("unrecognised archive format") {
            return .notAnArchive(path: archive.path)
        }
        if m.contains("multivolume") || m.contains("multi-volume") || m.contains("missing volume") || m.contains("next volume") {
            return .missingVolume(expected: [])
        }
        if errnoValue == ENOENT { return .fileNotFound(path: archive.path) }
        if errnoValue == EACCES || errnoValue == EPERM { return .permissionDenied(path: archive.path) }
        if errnoValue == ENOSPC { return .insufficientSpace(needed: 0, available: 0) }
        if errnoValue == ENOMEM { return .damaged(details: "The archive requires more memory than allowed: \(message)") }
        return .damaged(details: message)
    }
}

/// Holds a password in a C buffer for the lifetime of a libarchive read handle.
final class PassphraseBox {
    let archiveURL: URL
    let provider: PasswordProvider?
    var buffers: [UnsafeMutablePointer<CChar>] = []
    var asked = 0
    var lastSupplied: Secret?

    init(archiveURL: URL, provider: PasswordProvider?) {
        self.archiveURL = archiveURL
        self.provider = provider
    }

    func next() -> UnsafePointer<CChar>? {
        guard let provider, asked < 8 else { return nil }
        let reason: PasswordRequestReason = asked == 0 ? .required : .previousAttemptIncorrect
        asked += 1
        guard let secret = provider.password(for: archiveURL, reason: reason) else { return nil }
        lastSupplied = secret
        let buf = secret.withCString { p -> UnsafeMutablePointer<CChar> in
            let n = strlen(p)
            let b = UnsafeMutablePointer<CChar>.allocate(capacity: n + 1)
            b.initialize(from: p, count: n + 1)
            return b
        }
        buffers.append(buf)
        return UnsafePointer(buf)
    }

    deinit {
        for b in buffers {
            let n = strlen(b)
            memset(b, 0, n)
            b.deallocate()
        }
    }
}

extension ArchiveEntry {
    /// Builds a model entry from a libarchive entry.
    static func from(libarchive e: OpaquePointer, index: Int, rawNameFallbackEncoding: String.Encoding = .isoLatin1) -> ArchiveEntry {
        var path: String
        if let p = archive_entry_pathname_utf8(e) {
            path = String(cString: p)
        } else if let p = archive_entry_pathname(e) {
            let bytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: strlen(p)))
            path = String(bytes: bytes, encoding: .utf8) ?? CP437.decode(bytes)
        } else {
            path = ""
        }
        let ft = UInt32(archive_entry_filetype(e))
        var type: EntryType
        switch ft & LA.ifmt {
        case LA.ifdir: type = .directory
        case LA.iflnk: type = .symlink
        case LA.ifreg, 0: type = .file
        default: type = .special
        }
        var linkTarget: String?
        if let h = archive_entry_hardlink_utf8(e) ?? archive_entry_hardlink(e) {
            linkTarget = String(cString: h)
            // A hard link with a payload (cpio "newc" style) is materialised as a file.
            if !(archive_entry_size_is_set(e) != 0 && archive_entry_size(e) > 0) { type = .hardlink }
        }
        if type == .symlink, let s = archive_entry_symlink_utf8(e) ?? archive_entry_symlink(e) {
            linkTarget = String(cString: s)
        }
        if type == .file, path.hasSuffix("/") { type = .directory }
        let size: UInt64? = archive_entry_size_is_set(e) != 0 ? UInt64(max(0, archive_entry_size(e))) : nil
        func date(_ isSet: Int32, _ sec: Int, _ nsec: Int) -> Date? {
            isSet != 0 ? Date(timeIntervalSince1970: Double(sec) + Double(nsec) / 1e9) : nil
        }
        let mtime = date(archive_entry_mtime_is_set(e), Int(archive_entry_mtime(e)), Int(archive_entry_mtime_nsec(e)))
        let btime = date(archive_entry_birthtime_is_set(e), Int(archive_entry_birthtime(e)), Int(archive_entry_birthtime_nsec(e)))
        let atime = date(archive_entry_atime_is_set(e), Int(archive_entry_atime(e)), Int(archive_entry_atime_nsec(e)))
        var xattrNames: [String] = []
        if archive_entry_xattr_reset(e) > 0 {
            var name: UnsafePointer<CChar>?
            var value: UnsafeRawPointer?
            var len = 0
            while archive_entry_xattr_next(e, &name, &value, &len) == LA.ok {
                if let name { xattrNames.append(String(cString: name)) }
            }
        }
        let perm = UInt16(truncatingIfNeeded: archive_entry_perm(e))
        return ArchiveEntry(
            index: index, path: path, type: type,
            uncompressedSize: type == .file ? size : (type == .directory ? 0 : size),
            compressedSize: nil, modificationDate: mtime, creationDate: btime, accessDate: atime,
            permissions: perm == 0 && type != .file ? nil : perm,
            ownerName: archive_entry_uname(e).map { String(cString: $0) },
            groupName: archive_entry_gname(e).map { String(cString: $0) },
            uid: Int(archive_entry_uid(e)),
            gid: Int(archive_entry_gid(e)),
            isEncrypted: archive_entry_is_encrypted(e) != 0,
            linkTarget: linkTarget, extendedAttributeNames: xattrNames)
    }

    static func xattrs(of e: OpaquePointer) -> [(name: String, value: [UInt8])] {
        var out: [(String, [UInt8])] = []
        guard archive_entry_xattr_reset(e) > 0 else { return out }
        var name: UnsafePointer<CChar>?
        var value: UnsafeRawPointer?
        var len = 0
        while archive_entry_xattr_next(e, &name, &value, &len) == LA.ok {
            guard let name else { continue }
            let bytes = value.map { Array(UnsafeRawBufferPointer(start: $0, count: len)) } ?? []
            out.append((String(cString: name), bytes))
        }
        return out
    }
}

/// IBM code page 437 — the ZIP specification's default filename encoding when the UTF-8 flag is not set.
enum CP437 {
    static let high: [Character] = Array("ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}")

    static func decode(_ bytes: [UInt8]) -> String {
        var s = ""
        for b in bytes {
            if b < 0x80 { s.unicodeScalars.append(Unicode.Scalar(b)) } else { s.append(high[Int(b) - 0x80]) }
        }
        return s
    }
}
