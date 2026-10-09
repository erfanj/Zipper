import Foundation

/// The catalogue of formats Universal Archiver knows how to recognise.
///
/// Recognition is not support: a format listed here may have no engine able to open it on a given
/// machine. Use `EngineRegistry.capabilityMatrix()` for what is actually possible.
public enum FormatCatalog {
    private static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var chars = Array(s.replacingOccurrences(of: " ", with: ""))
        while chars.count >= 2 {
            out.append(UInt8(String(chars[0...1]), radix: 16)!)
            chars.removeFirst(2)
        }
        return out
    }

    public static let all: [FormatDescriptor] = {
        var d: [FormatDescriptor] = []
        // MARK: Category A — essential
        d.append(.init(id: .zip, name: "ZIP", kind: .archive, category: .essential,
                       extensions: ["zip", "zip64"],
                       signatures: [.init(bytes: hex("504B0304")), .init(bytes: hex("504B0506")), .init(bytes: hex("504B0708"))],
                       utis: ["public.zip-archive", "com.pkware.zip-archive"],
                       notes: "ZIP64 is handled transparently for archives and entries larger than 4 GB."))
        d.append(.init(id: .zipx, name: "ZIPX", kind: .archive, category: .essential,
                       extensions: ["zipx"], signatures: [.init(bytes: hex("504B0304"), strength: .weak)],
                       baseFormat: .zip, utis: ["com.winzip.zipx-archive"],
                       notes: "WinZip extended ZIP. Readable when the per-entry methods (LZMA, PPMd, XZ, BZip2, Zstandard) are supported by the selected engine. WinZip's proprietary JPEG/WavPack methods are not supported."))
        d.append(.init(id: .sevenZip, name: "7-Zip", kind: .archive, category: .essential,
                       extensions: ["7z"], signatures: [.init(bytes: hex("377ABCAF271C"))],
                       utis: ["org.7-zip.7-zip-archive"]))
        d.append(.init(id: .rar, name: "RAR", kind: .archive, category: .essential,
                       extensions: ["rar"],
                       signatures: [.init(bytes: hex("526172211A0700")), .init(bytes: hex("526172211A070100"))],
                       utis: ["com.rarlab.rar-archive"],
                       notes: "RAR 1.5–4.x (RAR4) and RAR 5. Creation requires the licensed RAR command-line tool."))
        d.append(.init(id: .tar, name: "TAR", kind: .archive, category: .essential,
                       extensions: ["tar"], signatures: [.init(offset: 257, ascii: "ustar")],
                       utis: ["public.tar-archive"]))
        d.append(.init(id: .gzip, name: "gzip", kind: .compressionStream, category: .essential,
                       extensions: ["gz", "gzip"], signatures: [.init(bytes: hex("1F8B"))], isMultiFile: false,
                       utis: ["org.gnu.gnu-zip-archive"]))
        d.append(.init(id: .bzip2, name: "bzip2", kind: .compressionStream, category: .essential,
                       extensions: ["bz2", "bzip2"], signatures: [.init(ascii: "BZh")], isMultiFile: false,
                       utis: ["public.bzip2-archive"]))
        d.append(.init(id: .xz, name: "XZ", kind: .compressionStream, category: .essential,
                       extensions: ["xz"], signatures: [.init(bytes: hex("FD377A585A00"))], isMultiFile: false,
                       utis: ["org.tukaani.xz-archive"]))
        d.append(.init(id: .lzma, name: "LZMA (alone)", kind: .compressionStream, category: .essential,
                       extensions: ["lzma"], signatures: [.init(bytes: hex("5D0000"), strength: .weak)], isMultiFile: false,
                       utis: ["org.tukaani.lzma-archive"]))
        d.append(.init(id: .zstd, name: "Zstandard", kind: .compressionStream, category: .essential,
                       extensions: ["zst", "zstd"], signatures: [.init(bytes: hex("28B52FFD"))], isMultiFile: false,
                       utis: ["org.facebook.zstandard-archive"]))
        d.append(.init(id: .lz4, name: "LZ4", kind: .compressionStream, category: .essential,
                       extensions: ["lz4"], signatures: [.init(bytes: hex("04224D18"))], isMultiFile: false,
                       utis: ["org.lz4.lz4-archive"]))
        d.append(.init(id: .brotli, name: "Brotli", kind: .compressionStream, category: .essential,
                       extensions: ["br"], isMultiFile: false, utis: ["org.brotli.brotli-archive"],
                       notes: "Brotli streams have no magic number; detection relies on the .br extension."))
        d.append(.init(id: .lzip, name: "Lzip", kind: .compressionStream, category: .essential,
                       extensions: ["lz"], signatures: [.init(ascii: "LZIP")], isMultiFile: false,
                       utis: ["org.nongnu.lzip-archive"]))
        d.append(.init(id: .unixCompress, name: "Unix compress", kind: .compressionStream, category: .essential,
                       extensions: ["z"], signatures: [.init(bytes: hex("1F9D"))], isMultiFile: false,
                       utis: ["public.z-archive"]))
        let tarLayers: [(FormatID, String, [String], FormatID)] = [
            (.tarGzip, "TAR + gzip", ["tar.gz", "tgz"], .gzip),
            (.tarBzip2, "TAR + bzip2", ["tar.bz2", "tbz", "tbz2", "tb2"], .bzip2),
            (.tarXz, "TAR + XZ", ["tar.xz", "txz"], .xz),
            (.tarLzma, "TAR + LZMA", ["tar.lzma", "tlz"], .lzma),
            (.tarZstd, "TAR + Zstandard", ["tar.zst", "tar.zstd", "tzst"], .zstd),
            (.tarLz4, "TAR + LZ4", ["tar.lz4"], .lz4),
            (.tarBrotli, "TAR + Brotli", ["tar.br"], .brotli),
            (.tarLzip, "TAR + Lzip", ["tar.lz"], .lzip),
            (.tarCompress, "TAR + compress", ["tar.z", "taz"], .unixCompress),
        ]
        for (id, name, exts, outer) in tarLayers {
            d.append(.init(id: id, name: name, kind: .compressedArchive, category: .essential,
                           extensions: exts, layers: [outer, .tar]))
        }

        // MARK: Category B — specialist
        d.append(.init(id: .cpio, name: "CPIO", kind: .archive, category: .specialist, extensions: ["cpio"],
                       signatures: [.init(ascii: "070707"), .init(ascii: "070701"), .init(ascii: "070702"),
                                    .init(bytes: hex("C771")), .init(bytes: hex("71C7"))],
                       utis: ["public.cpio-archive"]))
        d.append(.init(id: .xar, name: "XAR", kind: .archive, category: .specialist, extensions: ["xar"],
                       signatures: [.init(ascii: "xar!")], utis: ["com.apple.xar-archive"]))
        d.append(.init(id: .ar, name: "Unix ar", kind: .archive, category: .specialist, extensions: ["ar", "a"],
                       signatures: [.init(ascii: "!<arch>\n")]))
        d.append(.init(id: .cab, name: "Microsoft Cabinet", kind: .archive, category: .specialist, extensions: ["cab"],
                       signatures: [.init(ascii: "MSCF")], utis: ["com.microsoft.cab"]))
        d.append(.init(id: .lha, name: "LHA / LZH", kind: .archive, category: .specialist, extensions: ["lha", "lzh"],
                       signatures: [.init(offset: 2, ascii: "-lh"), .init(offset: 2, ascii: "-lz")]))
        d.append(.init(id: .arj, name: "ARJ", kind: .archive, category: .specialist, extensions: ["arj"],
                       signatures: [.init(bytes: hex("60EA"))]))
        d.append(.init(id: .ace, name: "ACE", kind: .archive, category: .specialist, extensions: ["ace"],
                       signatures: [.init(offset: 7, ascii: "**ACE**")],
                       notes: "No maintained, legally distributable ACE 2 decoder exists. ACE 1.x is readable through unar where installed."))
        d.append(.init(id: .wim, name: "Windows Imaging (WIM/ESD)", kind: .archive, category: .specialist, extensions: ["wim", "swm", "esd"],
                       signatures: [.init(ascii: "MSWIM\0\0\0")]))
        d.append(.init(id: .zpaq, name: "ZPAQ", kind: .archive, category: .specialist, extensions: ["zpaq"],
                       signatures: [.init(ascii: "7kSt"), .init(ascii: "zPQ")],
                       notes: "Readable when the zpaq reference tool is installed. Not bundled."))
        d.append(.init(id: .arc, name: "ARC", kind: .archive, category: .specialist, extensions: ["arc", "ark"],
                       signatures: [.init(bytes: hex("1A"), strength: .weak)]))
        d.append(.init(id: .zoo, name: "Zoo", kind: .archive, category: .specialist, extensions: ["zoo"],
                       signatures: [.init(ascii: "ZOO ")]))
        d.append(.init(id: .alz, name: "ALZip", kind: .archive, category: .specialist, extensions: ["alz"],
                       signatures: [.init(bytes: hex("414C5A01"))]))
        d.append(.init(id: .egg, name: "EGG", kind: .archive, category: .specialist, extensions: ["egg"],
                       signatures: [.init(ascii: "EGGA")]))
        d.append(.init(id: .lzop, name: "lzop", kind: .compressionStream, category: .specialist, extensions: ["lzo", "lzop"],
                       signatures: [.init(bytes: hex("894C5A4F000D0A1A0A"))], isMultiFile: false))
        d.append(.init(id: .lrzip, name: "lrzip", kind: .compressionStream, category: .specialist, extensions: ["lrz"],
                       signatures: [.init(ascii: "LRZI")], isMultiFile: false))
        d.append(.init(id: .nsis, name: "NSIS installer", kind: .package, category: .specialist, extensions: ["exe"],
                       signatures: [.init(bytes: hex("4D5A"), strength: .weak)],
                       notes: "Browsing only. Installers are never executed."))
        d.append(.init(id: .chm, name: "Compiled HTML Help", kind: .archive, category: .specialist, extensions: ["chm"],
                       signatures: [.init(ascii: "ITSF")]))
        d.append(.init(id: .msi, name: "Windows Installer", kind: .package, category: .specialist, extensions: ["msi", "msp"],
                       signatures: [.init(bytes: hex("D0CF11E0A1B11AE1"), strength: .weak)]))
        d.append(.init(id: .rpm, name: "RPM package", kind: .package, category: .specialist, extensions: ["rpm"],
                       signatures: [.init(bytes: hex("EDABEEDB"))]))
        d.append(.init(id: .deb, name: "Debian package", kind: .package, category: .specialist, extensions: ["deb", "udeb"],
                       signatures: [.init(ascii: "!<arch>\ndebian")], baseFormat: .ar))
        d.append(.init(id: .warc, name: "Web ARChive", kind: .archive, category: .specialist, extensions: ["warc"],
                       signatures: [.init(ascii: "WARC/")]))
        d.append(.init(id: .shar, name: "Shell archive", kind: .archive, category: .specialist, extensions: ["shar"],
                       signatures: [.init(ascii: "#!/bin/sh", strength: .weak)],
                       notes: "Shell archives are scripts. They are parsed, never executed."))

        // MARK: Category C — legacy Macintosh
        d.append(.init(id: .stuffIt, name: "StuffIt", kind: .archive, category: .legacyMac, extensions: ["sit"],
                       signatures: [.init(ascii: "SIT!"), .init(ascii: "StuffIt (c)1997"), .init(offset: 10, ascii: "rLau")],
                       utis: ["com.stuffit.archive.sit"]))
        d.append(.init(id: .stuffItX, name: "StuffIt X", kind: .archive, category: .legacyMac, extensions: ["sitx"],
                       signatures: [.init(ascii: "StuffIt!")], utis: ["com.stuffit.archive.sitx"],
                       notes: "Partial support only: some SITX compression methods and encryption are not implemented by any open decoder."))
        d.append(.init(id: .compactPro, name: "Compact Pro", kind: .archive, category: .legacyMac, extensions: ["cpt"],
                       signatures: [.init(bytes: hex("0101"), strength: .weak)]))
        d.append(.init(id: .packIt, name: "PackIt", kind: .archive, category: .legacyMac, extensions: ["pit"],
                       signatures: [.init(ascii: "PMag"), .init(ascii: "PMa4")]))
        d.append(.init(id: .diskDoubler, name: "DiskDoubler", kind: .archive, category: .legacyMac, extensions: ["dd"]))
        d.append(.init(id: .macBinary, name: "MacBinary", kind: .encoding, category: .legacyMac, extensions: ["macbin", "bin"],
                       isMultiFile: false, notes: "The .bin extension is ambiguous (CD images also use it); content is checked before MacBinary is assumed."))
        d.append(.init(id: .binHex, name: "BinHex 4", kind: .encoding, category: .legacyMac, extensions: ["hqx"],
                       signatures: [.init(ascii: "(This file must be converted with BinHex", strength: .weak)], isMultiFile: false,
                       utis: ["com.apple.binhex-archive"]))
        d.append(.init(id: .appleSingle, name: "AppleSingle", kind: .encoding, category: .legacyMac, extensions: ["as"],
                       signatures: [.init(bytes: hex("00051600"))], isMultiFile: false))
        d.append(.init(id: .appleDouble, name: "AppleDouble", kind: .encoding, category: .legacyMac, extensions: [],
                       signatures: [.init(bytes: hex("00051607"))], isMultiFile: false))

        // MARK: Category D — legacy computer formats / encodings
        d.append(.init(id: .amigaLZX, name: "Amiga LZX", kind: .archive, category: .legacyComputer, extensions: ["lzx"],
                       signatures: [.init(ascii: "LZX")]))
        d.append(.init(id: .adf, name: "Amiga Disk File", kind: .filesystemImage, category: .legacyComputer, extensions: ["adf"],
                       signatures: [.init(ascii: "DOS", strength: .weak)]))
        d.append(.init(id: .dms, name: "Amiga DiskMasher", kind: .diskImage, category: .legacyComputer, extensions: ["dms"],
                       signatures: [.init(ascii: "DMS!")]))
        d.append(.init(id: .powerPacker, name: "PowerPacker", kind: .compressionStream, category: .legacyComputer, extensions: ["pp"],
                       signatures: [.init(ascii: "PP20")], isMultiFile: false))
        d.append(.init(id: .lbr, name: "CP/M LBR", kind: .archive, category: .legacyComputer, extensions: ["lbr"]))
        d.append(.init(id: .squeeze, name: "Squeeze", kind: .compressionStream, category: .legacyComputer, extensions: ["sqz", "qqq"],
                       signatures: [.init(bytes: hex("76FF"))], isMultiFile: false))
        d.append(.init(id: .uuencode, name: "uuencode", kind: .encoding, category: .legacyComputer, extensions: ["uue", "uu"],
                       signatures: [.init(ascii: "begin ", strength: .weak)], isMultiFile: true))
        d.append(.init(id: .xxencode, name: "XXEncode", kind: .encoding, category: .legacyComputer, extensions: ["xxe"],
                       signatures: [.init(ascii: "begin ", strength: .weak)], isMultiFile: false))
        d.append(.init(id: .yEnc, name: "yEnc", kind: .encoding, category: .legacyComputer, extensions: ["yenc", "ync"],
                       signatures: [.init(ascii: "=ybegin ")], isMultiFile: false))

        // MARK: Category E — disk and filesystem images
        d.append(.init(id: .dmg, name: "Apple Disk Image", kind: .diskImage, category: .diskImage, extensions: ["dmg", "sparseimage", "sparsebundle"],
                       signatures: [.init(offset: 512, ascii: "koly", fromEnd: true)], utis: ["com.apple.disk-image-udif"],
                       notes: "Browsing and extraction are read-only and never mount the image. Mounting requires explicit consent and uses hdiutil."))
        d.append(.init(id: .iso, name: "ISO 9660", kind: .filesystemImage, category: .diskImage, extensions: ["iso", "cdr"],
                       signatures: [.init(offset: 0x8001, ascii: "CD001")], utis: ["public.iso-image"]))
        d.append(.init(id: .udf, name: "UDF", kind: .filesystemImage, category: .diskImage, extensions: ["udf"],
                       signatures: [.init(offset: 0x8001, ascii: "BEA01"), .init(offset: 0x8001, ascii: "NSR02"), .init(offset: 0x8001, ascii: "NSR03")]))
        d.append(.init(id: .rawImage, name: "Raw disk image", kind: .diskImage, category: .diskImage, extensions: ["img", "ima", "dd", "raw"]))
        d.append(.init(id: .vhd, name: "Virtual Hard Disk", kind: .diskImage, category: .diskImage, extensions: ["vhd"],
                       signatures: [.init(ascii: "conectix"), .init(offset: 512, ascii: "conectix", fromEnd: true)]))
        d.append(.init(id: .vhdx, name: "VHDX", kind: .diskImage, category: .diskImage, extensions: ["vhdx"],
                       signatures: [.init(ascii: "vhdxfile")]))
        d.append(.init(id: .vdi, name: "VirtualBox Disk Image", kind: .diskImage, category: .diskImage, extensions: ["vdi"],
                       signatures: [.init(offset: 0x40, bytes: hex("7F10DABE"))]))
        d.append(.init(id: .vmdk, name: "VMware Disk", kind: .diskImage, category: .diskImage, extensions: ["vmdk"],
                       signatures: [.init(ascii: "KDMV"), .init(ascii: "# Disk DescriptorFile")]))
        d.append(.init(id: .qcow2, name: "QEMU Copy-On-Write", kind: .diskImage, category: .diskImage, extensions: ["qcow2", "qcow"],
                       signatures: [.init(bytes: hex("514649FB"))]))
        d.append(.init(id: .squashfs, name: "SquashFS", kind: .filesystemImage, category: .diskImage, extensions: ["squashfs", "sqsh", "sfs"],
                       signatures: [.init(ascii: "hsqs"), .init(ascii: "sqsh")]))
        d.append(.init(id: .cramfs, name: "CramFS", kind: .filesystemImage, category: .diskImage, extensions: ["cramfs"],
                       signatures: [.init(bytes: hex("453DCD28")), .init(bytes: hex("28CD3D45"))]))
        d.append(.init(id: .apfs, name: "APFS volume image", kind: .filesystemImage, category: .diskImage, extensions: ["apfs"],
                       signatures: [.init(offset: 32, ascii: "NXSB")]))
        d.append(.init(id: .hfs, name: "HFS / HFS+ image", kind: .filesystemImage, category: .diskImage, extensions: ["hfs", "hfsx"],
                       signatures: [.init(offset: 1024, ascii: "H+"), .init(offset: 1024, ascii: "HX")]))
        d.append(.init(id: .fat, name: "FAT image", kind: .filesystemImage, category: .diskImage, extensions: ["fat"],
                       signatures: [.init(offset: 54, ascii: "FAT1"), .init(offset: 82, ascii: "FAT32")]))
        d.append(.init(id: .ntfs, name: "NTFS image", kind: .filesystemImage, category: .diskImage, extensions: ["ntfs"],
                       signatures: [.init(offset: 3, ascii: "NTFS    ")]))
        d.append(.init(id: .ext, name: "ext2/3/4 image", kind: .filesystemImage, category: .diskImage, extensions: ["ext2", "ext3", "ext4"],
                       signatures: [.init(offset: 1080, bytes: hex("53EF"))]))

        // MARK: Category F — packages
        let zipPackages: [(FormatID, String, [String], [String])] = [
            (.jar, "Java Archive", ["jar"], ["com.sun.java-archive"]),
            (.war, "Web Application Archive", ["war"], []),
            (.ear, "Enterprise Application Archive", ["ear"], []),
            (.apk, "Android Package", ["apk"], ["com.android.package-archive"]),
            (.aab, "Android App Bundle", ["aab"], []),
            (.ipa, "iOS App Archive", ["ipa"], ["com.apple.itunes.ipa"]),
            (.epub, "EPUB", ["epub"], ["org.idpf.epub-container"]),
            (.cbz, "Comic Book (ZIP)", ["cbz"], []),
            (.xpi, "Browser Extension", ["xpi"], []),
            (.vsix, "Visual Studio Extension", ["vsix"], []),
            (.appx, "Windows App Package", ["appx", "appxbundle"], []),
            (.msix, "MSIX Package", ["msix", "msixbundle"], []),
        ]
        for (id, name, exts, utis) in zipPackages {
            d.append(.init(id: id, name: name, kind: .package, category: .package, extensions: exts,
                           signatures: [.init(bytes: hex("504B0304"), strength: .weak)], baseFormat: .zip, utis: utis))
        }
        d.append(.init(id: .cbr, name: "Comic Book (RAR)", kind: .package, category: .package, extensions: ["cbr"],
                       signatures: [.init(bytes: hex("526172211A07"), strength: .weak)], baseFormat: .rar))
        d.append(.init(id: .cb7, name: "Comic Book (7z)", kind: .package, category: .package, extensions: ["cb7"],
                       signatures: [.init(bytes: hex("377ABCAF271C"), strength: .weak)], baseFormat: .sevenZip))
        d.append(.init(id: .cbt, name: "Comic Book (TAR)", kind: .package, category: .package, extensions: ["cbt"],
                       signatures: [.init(offset: 257, ascii: "ustar", strength: .weak)], baseFormat: .tar))
        d.append(.init(id: .pkg, name: "macOS Installer Package", kind: .package, category: .package, extensions: ["pkg", "mpkg"],
                       signatures: [.init(ascii: "xar!", strength: .weak)], baseFormat: .xar, utis: ["com.apple.installer-package-archive"],
                       notes: "Browsing and extraction only. Installers are never run, and modifying a signed package invalidates its signature."))

        // MARK: Category G — Apple Archive
        d.append(.init(id: .appleArchive, name: "Apple Archive", kind: .appleArchive, category: .appleNative, extensions: ["aar", "yaa"],
                       signatures: [.init(ascii: "AA01"), .init(ascii: "YAA1"), .init(ascii: "pbze"), .init(ascii: "pbz4"),
                                    .init(ascii: "pbzx"), .init(ascii: "pbzz"), .init(ascii: "pbzb")],
                       utis: ["com.apple.archive"]))
        d.append(.init(id: .appleEncryptedArchive, name: "Apple Encrypted Archive", kind: .appleArchive, category: .appleNative,
                       extensions: ["aea"], signatures: [.init(ascii: "AEA1")], utis: ["com.apple.encrypted-archive"]))
        return d
    }()

    private static let byID: [FormatID: FormatDescriptor] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    public static func descriptor(for id: FormatID) -> FormatDescriptor? { byID[id] }

    /// Formats whose extension list contains `ext` (lower-cased, without leading dot).
    public static func formats(forExtension ext: String) -> [FormatDescriptor] {
        let e = ext.lowercased()
        return all.filter { $0.extensions.contains(e) }
    }

    /// Longest extension suffix of `filename` that is known to the catalogue (handles `tar.gz`).
    public static func matchExtension(of filename: String) -> (ext: String, formats: [FormatDescriptor])? {
        let lower = filename.lowercased()
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        // Try two-component extensions first (tar.gz), then single.
        for take in stride(from: min(2, parts.count - 1), through: 1, by: -1) {
            let ext = parts.suffix(take).joined(separator: ".")
            let matches = formats(forExtension: ext)
            if !matches.isEmpty { return (ext, matches) }
        }
        return nil
    }
}
