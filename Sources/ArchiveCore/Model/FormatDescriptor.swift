import Foundation

/// What kind of thing a format is. These are deliberately distinct: a compression stream holds one
/// payload, an archive container holds many entries, a disk image holds a block device, and so on.
public enum FormatKind: String, Codable, Sendable, CaseIterable {
    /// A multi-entry container (ZIP, 7z, RAR, TAR, CPIO…).
    case archive
    /// A single-payload compression stream (gzip, xz, zstd…).
    case compressionStream
    /// A container wrapped in a compression stream (tar.gz, tar.zst…). Extracted in one step.
    case compressedArchive
    /// A block-level disk image (DMG, VHD, VMDK, QCOW2…).
    case diskImage
    /// A filesystem image whose files can be browsed (ISO 9660, SquashFS, ext4, FAT…).
    case filesystemImage
    /// A software or document package that uses another container (JAR, APK, EPUB, PKG, DEB…).
    case package
    /// A text/binary encoding of a single file (uuencode, BinHex, yEnc…).
    case encoding
    /// Apple Archive and Apple Encrypted Archive.
    case appleArchive

    public var displayName: String {
        switch self {
        case .archive: return "Archive container"
        case .compressionStream: return "Compression stream"
        case .compressedArchive: return "Compressed archive"
        case .diskImage: return "Disk image"
        case .filesystemImage: return "Filesystem image"
        case .package: return "Package"
        case .encoding: return "Encoded file"
        case .appleArchive: return "Apple Archive"
        }
    }
}

/// The specification's grouping of formats, used for documentation and the capability matrix.
public enum FormatCategory: String, Codable, Sendable, CaseIterable {
    case essential = "A"
    case specialist = "B"
    case legacyMac = "C"
    case legacyComputer = "D"
    case diskImage = "E"
    case package = "F"
    case appleNative = "G"

    public var displayName: String {
        switch self {
        case .essential: return "Essential modern formats"
        case .specialist: return "Secondary and specialist formats"
        case .legacyMac: return "Legacy Macintosh formats"
        case .legacyComputer: return "Legacy computer formats and encodings"
        case .diskImage: return "Disk and filesystem images"
        case .package: return "Developer and software packages"
        case .appleNative: return "Native Apple archives"
        }
    }
}

/// A byte signature used for content-based detection.
public struct MagicSignature: Codable, Hashable, Sendable {
    public enum Strength: String, Codable, Sendable {
        /// Unique enough to identify the format on its own.
        case strong
        /// Short or shared; only used together with a matching extension.
        case weak
    }

    public var offset: Int
    public var bytes: [UInt8]
    /// When true, `offset` is measured backwards from the end of the file.
    public var fromEnd: Bool
    public var strength: Strength

    public init(offset: Int = 0, bytes: [UInt8], fromEnd: Bool = false, strength: Strength = .strong) {
        self.offset = offset
        self.bytes = bytes
        self.fromEnd = fromEnd
        self.strength = strength
    }

    public init(offset: Int = 0, ascii: String, fromEnd: Bool = false, strength: Strength = .strong) {
        self.init(offset: offset, bytes: Array(ascii.utf8), fromEnd: fromEnd, strength: strength)
    }
}

/// Static description of a format: how to recognise it and what it is.
/// What can be *done* with a format is described by engines (see `EngineFormatSupport`).
public struct FormatDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: FormatID
    public var name: String
    public var kind: FormatKind
    public var category: FormatCategory
    /// Lower-case extensions without the leading dot. Compound extensions such as `tar.gz` are allowed.
    public var extensions: [String]
    public var signatures: [MagicSignature]
    /// For packages built on another container (JAR → ZIP, CBR → RAR, PKG → XAR).
    public var baseFormat: FormatID?
    /// For compressed archives: the layers from outermost to innermost (tar.gz → [gz, tar]).
    public var layers: [FormatID]
    /// Whether the format can hold more than one file.
    public var isMultiFile: Bool
    /// Uniform Type Identifiers.
    public var utis: [String]
    public var notes: String?

    public init(
        id: FormatID, name: String, kind: FormatKind, category: FormatCategory,
        extensions: [String], signatures: [MagicSignature] = [], baseFormat: FormatID? = nil,
        layers: [FormatID] = [], isMultiFile: Bool = true, utis: [String] = [], notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.category = category
        self.extensions = extensions
        self.signatures = signatures
        self.baseFormat = baseFormat
        self.layers = layers
        self.isMultiFile = isMultiFile
        self.utis = utis
        self.notes = notes
    }

    /// The format whose engine support applies to this one (packages resolve to their container).
    public var effectiveContainer: FormatID { baseFormat ?? id }
    public var primaryExtension: String { extensions.first ?? id.rawValue }
}
