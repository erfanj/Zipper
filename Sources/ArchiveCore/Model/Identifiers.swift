import Foundation

/// A stable identifier for an archive, stream, image or package format (for example `zip`, `tar.gz`, `7z`).
///
/// Identifiers are open-ended strings so that new providers can introduce formats without changing
/// this module. Well-known identifiers are exposed as static members.
public struct FormatID: RawRepresentable, Hashable, Codable, Sendable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { self.rawValue = raw }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (lhs: FormatID, rhs: FormatID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public extension FormatID {
    // Category A — essential containers and streams
    static let zip: FormatID = "zip"
    static let zipx: FormatID = "zipx"
    static let sevenZip: FormatID = "7z"
    static let rar: FormatID = "rar"
    static let tar: FormatID = "tar"
    static let gzip: FormatID = "gz"
    static let bzip2: FormatID = "bz2"
    static let xz: FormatID = "xz"
    static let lzma: FormatID = "lzma"
    static let zstd: FormatID = "zst"
    static let lz4: FormatID = "lz4"
    static let brotli: FormatID = "br"
    static let lzip: FormatID = "lz"
    static let unixCompress: FormatID = "Z"
    static let tarGzip: FormatID = "tar.gz"
    static let tarBzip2: FormatID = "tar.bz2"
    static let tarXz: FormatID = "tar.xz"
    static let tarLzma: FormatID = "tar.lzma"
    static let tarZstd: FormatID = "tar.zst"
    static let tarLz4: FormatID = "tar.lz4"
    static let tarBrotli: FormatID = "tar.br"
    static let tarLzip: FormatID = "tar.lz"
    static let tarCompress: FormatID = "tar.Z"
    // Category B
    static let cpio: FormatID = "cpio"
    static let xar: FormatID = "xar"
    static let ar: FormatID = "ar"
    static let cab: FormatID = "cab"
    static let lha: FormatID = "lha"
    static let arj: FormatID = "arj"
    static let ace: FormatID = "ace"
    static let wim: FormatID = "wim"
    static let zpaq: FormatID = "zpaq"
    static let arc: FormatID = "arc"
    static let zoo: FormatID = "zoo"
    static let alz: FormatID = "alz"
    static let egg: FormatID = "egg"
    static let lzop: FormatID = "lzo"
    static let lrzip: FormatID = "lrz"
    static let nsis: FormatID = "nsis"
    static let chm: FormatID = "chm"
    static let msi: FormatID = "msi"
    static let rpm: FormatID = "rpm"
    static let deb: FormatID = "deb"
    static let warc: FormatID = "warc"
    static let shar: FormatID = "shar"
    // Category C — legacy Macintosh
    static let stuffIt: FormatID = "sit"
    static let stuffItX: FormatID = "sitx"
    static let compactPro: FormatID = "cpt"
    static let packIt: FormatID = "pit"
    static let diskDoubler: FormatID = "dd"
    static let macBinary: FormatID = "bin.macbinary"
    static let binHex: FormatID = "hqx"
    static let appleSingle: FormatID = "applesingle"
    static let appleDouble: FormatID = "appledouble"
    // Category D — legacy computer formats / encodings
    static let amigaLZX: FormatID = "lzx"
    static let adf: FormatID = "adf"
    static let dms: FormatID = "dms"
    static let powerPacker: FormatID = "pp"
    static let lbr: FormatID = "lbr"
    static let squeeze: FormatID = "sqz"
    static let uuencode: FormatID = "uue"
    static let xxencode: FormatID = "xxe"
    static let yEnc: FormatID = "yenc"
    // Category E — disk and filesystem images
    static let dmg: FormatID = "dmg"
    static let iso: FormatID = "iso"
    static let udf: FormatID = "udf"
    static let rawImage: FormatID = "img"
    static let vhd: FormatID = "vhd"
    static let vhdx: FormatID = "vhdx"
    static let vdi: FormatID = "vdi"
    static let vmdk: FormatID = "vmdk"
    static let qcow2: FormatID = "qcow2"
    static let squashfs: FormatID = "squashfs"
    static let cramfs: FormatID = "cramfs"
    static let apfs: FormatID = "apfs"
    static let hfs: FormatID = "hfs"
    static let fat: FormatID = "fat"
    static let ntfs: FormatID = "ntfs"
    static let ext: FormatID = "ext"
    // Category F — packages built on other containers
    static let jar: FormatID = "jar"
    static let war: FormatID = "war"
    static let ear: FormatID = "ear"
    static let apk: FormatID = "apk"
    static let aab: FormatID = "aab"
    static let ipa: FormatID = "ipa"
    static let epub: FormatID = "epub"
    static let cbz: FormatID = "cbz"
    static let cbr: FormatID = "cbr"
    static let cb7: FormatID = "cb7"
    static let cbt: FormatID = "cbt"
    static let pkg: FormatID = "pkg"
    static let xpi: FormatID = "xpi"
    static let vsix: FormatID = "vsix"
    static let appx: FormatID = "appx"
    static let msix: FormatID = "msix"
    // Category G — Apple Archive
    static let appleArchive: FormatID = "aar"
    static let appleEncryptedArchive: FormatID = "aea"
}

/// Identifies an engine implementation (for example `libarchive` or `7zip`).
public struct EngineID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let libarchive: EngineID = "libarchive"
    public static let sevenZip: EngineID = "7zip"
    public static let brotli: EngineID = "brotli"
    public static let unar: EngineID = "unar"
    public static let rar: EngineID = "rar"
    public static let appleArchive: EngineID = "applearchive"
    public static let diskImage: EngineID = "hdiutil"
}

/// A compression method. Open-ended so providers can add methods.
public struct CompressionMethod: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let store: CompressionMethod = "store"
    public static let deflate: CompressionMethod = "deflate"
    public static let deflate64: CompressionMethod = "deflate64"
    public static let bzip2: CompressionMethod = "bzip2"
    public static let lzma: CompressionMethod = "lzma"
    public static let lzma2: CompressionMethod = "lzma2"
    public static let ppmd: CompressionMethod = "ppmd"
    public static let xz: CompressionMethod = "xz"
    public static let zstd: CompressionMethod = "zstd"
    public static let lz4: CompressionMethod = "lz4"
    public static let brotli: CompressionMethod = "brotli"
    public static let lzip: CompressionMethod = "lzip"
    public static let lzw: CompressionMethod = "lzw"
    public static let lzfse: CompressionMethod = "lzfse"
    public static let lzbitmap: CompressionMethod = "lzbitmap"
    public static let zlib: CompressionMethod = "zlib"

    public var displayName: String {
        switch self {
        case .store: return "Store (no compression)"
        case .deflate: return "Deflate"
        case .deflate64: return "Deflate64"
        case .bzip2: return "BZip2"
        case .lzma: return "LZMA"
        case .lzma2: return "LZMA2"
        case .ppmd: return "PPMd"
        case .xz: return "XZ"
        case .zstd: return "Zstandard"
        case .lz4: return "LZ4"
        case .brotli: return "Brotli"
        case .lzip: return "Lzip"
        case .lzw: return "LZW (Unix compress)"
        case .lzfse: return "LZFSE"
        case .lzbitmap: return "LZBITMAP"
        case .zlib: return "zlib"
        default: return rawValue
        }
    }
}

/// An encryption scheme as defined by a specific archive standard.
public struct EncryptionMethod: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Traditional PKWARE encryption. Broken; decryption plus explicitly labelled compatibility creation only.
    public static let zipCrypto: EncryptionMethod = "zipcrypto"
    /// WinZip AE-x AES-128.
    public static let zipAES128: EncryptionMethod = "zip-aes128"
    /// WinZip AE-x AES-256 (PBKDF2-HMAC-SHA1, HMAC-SHA1-80 authentication).
    public static let zipAES256: EncryptionMethod = "zip-aes256"
    /// 7z AES-256 (SHA-256 key stretching, CBC). Optional header (filename) encryption.
    public static let sevenZipAES256: EncryptionMethod = "7z-aes256"
    /// RAR 5 AES-256 (PBKDF2-HMAC-SHA256).
    public static let rar5AES256: EncryptionMethod = "rar5-aes256"
    /// RAR 2.9–4.x AES-128.
    public static let rar4AES128: EncryptionMethod = "rar4-aes128"
    /// Apple Encrypted Archive (HKDF-SHA256, AES-CTR, HMAC; password profile uses scrypt).
    public static let appleEncryptedArchive: EncryptionMethod = "aea"
    /// Encrypted disk image (AES-128/256 via hdiutil).
    public static let dmgAES: EncryptionMethod = "dmg-aes"

    public var displayName: String {
        switch self {
        case .zipCrypto: return "ZipCrypto (legacy, insecure)"
        case .zipAES128: return "AES-128 (WinZip compatible)"
        case .zipAES256: return "AES-256 (WinZip compatible)"
        case .sevenZipAES256: return "AES-256 (7-Zip)"
        case .rar5AES256: return "AES-256 (RAR 5)"
        case .rar4AES128: return "AES-128 (RAR 4)"
        case .appleEncryptedArchive: return "Apple Encrypted Archive"
        case .dmgAES: return "Encrypted Disk Image (AES)"
        default: return rawValue
        }
    }

    /// Whether the method is considered cryptographically sound today.
    public var isConsideredSecure: Bool {
        self != .zipCrypto
    }

    /// Plain-language description of what the method protects and what it does not.
    public var scopeExplanation: String {
        switch self {
        case .zipCrypto:
            return "ZipCrypto can be broken with known-plaintext attacks. Use it only when the recipient's software cannot open AES-encrypted ZIP files. File names, sizes and dates remain visible."
        case .zipAES128, .zipAES256:
            return "File contents are encrypted and authenticated. File names, folder structure, sizes and dates remain visible to anyone who has the archive."
        case .sevenZipAES256:
            return "File contents are encrypted. When “Encrypt file names” is enabled the archive's file list is also encrypted, so names, sizes and dates are hidden without the password."
        case .rar5AES256, .rar4AES128:
            return "File contents are encrypted. File names are hidden only when header encryption was enabled when the archive was created."
        case .appleEncryptedArchive:
            return "The whole archive, including file names and metadata, is encrypted and authenticated. Readable on macOS 13 or later."
        case .dmgAES:
            return "The whole disk image, including file names, is encrypted. Readable on macOS only."
        default:
            return ""
        }
    }
}
