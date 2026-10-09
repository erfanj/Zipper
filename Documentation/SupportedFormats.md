# Supported formats

Recognising a format is not the same as supporting it. This page states, per format, what has been
**verified by automated tests in this repository**, what is **implemented but not verified here**,
and what is **not supported**, with the reason.

* **Verified** — an automated test opens archives produced by an *independent* reference tool and
  extracts byte-identical files (forward interop), and/or archives created by Universal Archiver are
  read correctly by an independent tool (reverse interop). Test runs were made on Linux (x86_64)
  with the engines listed in [Dependencies.md](Dependencies.md); see [Testing.md](Testing.md).
* **Implemented** — the code path exists and is wired to an engine, but no fixture for that format
  could be produced in the build environment, or it needs macOS. Treat as unverified until tested.
* **Not supported** — no maintained, legally distributable decoder is integrated.

The machine-readable capability matrix (what each engine declares for each of the 97 catalogued
formats) is [FormatCapabilities.json](FormatCapabilities.json), generated with
`archiver formats --json` on the Linux build machine. It marks each engine as available or not,
and it does not include the macOS-only Apple Archive and disk-image engines. At run time the app shows the same matrix for the engines actually
installed (Settings › Advanced).

## Category A — essential modern formats

| Format | Read / extract | Create | Encryption | Evidence |
|---|---|---|---|---|
| ZIP / ZIP64 | **Verified** (Info-ZIP UTF-8, store, ZipCrypto; 7-Zip AES-128/256, BZip2, LZMA, PPMd, Deflate64¹) | **Verified** (read by Info-ZIP `unzip` and Python `zipfile`; >4 GB ZIP64 round trip) | AES-256/128 create **verified** (decrypted by 7-Zip); ZipCrypto create/read; ZIP cannot hide names | `ForwardInteropTests`, `ReverseInteropTests`, `CompressionServiceTests.testLargeFileOver4GBZip64` |
| Spanned ZIP (`.z01…/.zip`) | **Verified** (Info-ZIP `zip -s`) | Byte-split `.zip.001` via 7-Zip; classic spanned creation not supported | — | `infozip-split.zip` |
| Legacy ZIP names | **Verified**: CP437 decoded automatically; Shift-JIS with encoding override (CP932) | UTF-8 flag always set | — | `testLegacyFilenameEncodingOverride` |
| ZIPX | Implemented: entries using Store/Deflate/BZip2/LZMA/PPMd/XZ/Zstd | Not offered | — | — |
| 7z | **Verified** (LZMA2, PPMd, BZip2, non-solid, AES-256, AES-256 + encrypted headers, `.001` volumes) | **Verified** (libarchive and 7-Zip writers read by 7-Zip; split volumes) | AES-256 with encrypted file names **verified** (names absent from the file; listing fails without password) | `SevenZipEngineTests`, interop |
| RAR 5 | **Verified** (plain, solid, AES-256, encrypted headers, `.partN.rar` volumes) | Only with the user's licensed `rar` tool — **verified** incl. encrypted headers | Decrypt via 7-Zip engine | interop, `testRarCreationWithLicensedTool` |
| RAR 2.0–4.x | **Verified** on WinRAR-made samples (subdirs, solid, symlink, `.rar/.r00` and `.partN` volumes, AES-128, encrypted headers) | Not possible (RAR 7 removed RAR4 creation) | Decrypt via 7-Zip | `rar4/*` fixtures (rarfile test corpus) |
| TAR (GNU, pax, ustar) | **Verified** | **Verified** (read by GNU tar) | — | interop |
| gzip, bzip2, XZ, LZMA, Zstandard, LZ4, Brotli, Lzip, Unix compress (`.Z`) | **Verified** (single streams from the reference compressors) | **Verified** (output checked by `gzip -t`, `bzip2 -t`, `xz -t`, `zstd -t`, `lz4 -t`, `brotli -t`, `lzip -t`, `xz --format=lzma -t`); `.Z` round-trip | — | `testStreamsVerifiedByReferenceDecoders` |
| `.tar.gz/.tgz`, `.tar.bz2`, `.tar.xz`, `.tar.zst`, `.tar.lz4`, `.tar.br`, `.tar.lz`, `.tar.lzma`, `.tar.Z` | **Verified**, one step | **Verified** (gz/bz2/xz/zst/lz/lzma read by GNU tar; lz4/br/Z round-trip) | — | interop |

¹ Deflate64 is decoded by the 7-Zip engine after libarchive reports it as unsupported (automatic,
logged fallback).

## Category B — secondary and specialist formats

| Format | Status | Engine | Notes |
|---|---|---|---|
| CPIO (newc, odc, bin) | **Verified** read (GNU cpio) and create (round trip) | libarchive | |
| ar / Debian `.deb` | **Verified** read (`ar`, `dpkg-deb`); ar create round-trip | libarchive | Install scripts are never run |
| CAB | **Verified** read (gcab) | libarchive, 7-Zip | |
| LHA / LZH | **Verified** read (jlha) | libarchive, 7-Zip | |
| ARJ | **Verified** read (arj) | 7-Zip | |
| ARC | **Verified** read (arc 5.21) | nomarch (fallback from unar) | |
| ZPAQ | **Verified** read (zpaq 7.15) | zpaq tool (user-installed) | Extracts latest version |
| WIM / ESD | **Verified** read and create (7-Zip) | 7-Zip | |
| lzop, lrzip | **Verified** read | lzop / lrzip tools (user-installed) | Single streams |
| XAR / macOS `.pkg` | XAR create/read round-trip verified; Apple-made `.pkg` not tested | libarchive | Installers are never run |
| ISO 9660 (Joliet/Rock Ridge) | **Verified** read (xorriso) and create (read by 7-Zip) | libarchive | |
| WARC | Implemented (read) | libarchive | Writer withdrawn: it dropped entries in testing |
| RPM, CHM, MSI, NSIS | Implemented (read) | libarchive / 7-Zip | Scriptlets/installers never executed |
| ACE | 1.x implemented via unar; **ACE 2 not supported** (no open decoder) | unar | |
| Zoo, ALZ, EGG | Implemented via unar; no fixtures available | unar | |
| SHAR | Create implemented; reading deliberately unsupported (would require executing a script) | libarchive | |
| PAQ / LPAQ, PEA, BH, UCL | **Not supported**: no maintained, distributable decoder integrated | — | |

## Category C — legacy Macintosh formats

StuffIt (1.5–5.5), StuffIt X (partial), Compact Pro, PackIt, DiskDoubler, MacBinary, BinHex 4,
AppleSingle/AppleDouble are **implemented** through The Unarchiver's `unar`/`lsar` (XADMaster),
which is the most complete open implementation. They are **not verified here**: no tool that creates
these formats runs on Linux, and the BinHex encoder available (`macutils`) produced empty output.
Known limits: encrypted StuffIt archives are not supported; StuffIt X support is partial (some
methods and all encryption unavailable); resource forks are restored as native forks on macOS
(`unar -k visible` writes them as AppleDouble on other volumes).

## Category D — legacy computer formats and encodings

uuencode is **verified** (read). Amiga LZX, ADF, DMS, PowerPacker, LBR, Squeeze, yEnc and
XXEncode are implemented via unar and unverified (no creators available). 

## Category E — disk and filesystem images

| Image | Status |
|---|---|
| VHD, VHDX, VMDK, VDI, QCOW2 | **Verified** read (images made with `qemu-img`; the FAT file system inside is browsed and extracted) |
| FAT, NTFS, ext4, SquashFS | **Verified** read (mkfs.fat+mtools, mkntfs+ntfscp, mke2fs -d, mksquashfs) |
| ISO 9660 | **Verified** read and create |
| DMG | Implemented: browsed without mounting via 7-Zip (HFS+/APFS partly); encrypted or unreadable DMGs mounted read-only with `hdiutil` **only with explicit consent**; DMG creation (optionally AES-256) via `hdiutil`. macOS only; not verified here |
| UDF, APFS, HFS+, CramFS, raw `.img` | Implemented via 7-Zip; not verified here |
| NRG, MDF, CDI, ISZ, DAA | **Not supported** |

Extracting a disk image, browsing its file system, mounting it and converting it are separate
operations: browsing/extraction never mounts; mounting needs consent and is read-only, hidden from
Finder and detached afterwards; converting images is not offered.

## Category F — developer and software packages

JAR/WAR/EAR, APK/AAB, IPA, EPUB, CBZ/CBR/CB7/CBT, DEB, RPM, PKG, XPI, VSIX, APPX/MSIX are
recognised by extension and opened through their container (EPUB and CBZ **verified**). Creation
profiles: **EPUB verified** (`mimetype` stored first, uncompressed, without extra fields — checked
against the OCF rules), CBZ/CB7/CBT, JAR/WAR/EAR/XPI/VSIX (ZIP with the right extension; content is
not validated). Signed packages (APK, IPA, JAR, APPX, MSIX, PKG) are read-only unless the user
explicitly accepts that editing invalidates the signature.

## Category G — Apple Archive

`.aar` (LZFSE, LZMA, LZ4, zlib, LZBITMAP, store) and `.aea` (Apple Encrypted Archive, password
profile HKDF-SHA256 + AES-CTR + HMAC with scrypt) are **implemented** with the AppleArchive
framework (macOS 13+). This code compiles only on macOS and has **not been built or tested** in the
Linux environment used for this delivery.

## Category H — multipart archives

**Verified**: `.partN.rar` (RAR3 and RAR5), `.rar/.r00/.r01`, `.z01…/.zip` (spanned ZIP),
`.7z.001…`, generic `.001` byte-split sets; identification of the starting volume; missing-volume
detection with the exact missing file names before extraction starts; one password prompt per set;
creation of 7z and ZIP volumes (7-Zip) and RAR volumes (licensed `rar`), with size presets and custom
sizes in KB/MB/GB/TB (`FileSplitter.parseSize`).
