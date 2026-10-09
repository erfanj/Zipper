import Foundation
import ArchiveCore

/// Engine that drives the official 7-Zip command-line program (`7zz`, LGPL-2.1 with the unRAR
/// restriction) as a separate process.
///
/// Used for: encrypted 7z (AES-256, header encryption), multi-volume creation, encrypted RAR
/// extraction, split ZIP sets, multithreaded LZMA2, and the disk/filesystem image formats 7-Zip
/// understands (DMG, ISO/UDF, VHD/VHDX, VMDK, VDI, QCOW, WIM, APFS, HFS+, NTFS, FAT, ext, SquashFS…).
///
/// Passwords are written to the helper's stdin in answer to its prompt, never passed as arguments.
/// Output is extracted into a private staging folder and imported through the safe sink.
public final class SevenZipEngine: ArchiveEngine, @unchecked Sendable {
    public let descriptor: EngineDescriptor
    let executable: URL?
    private(set) var table: [FormatID: EngineFormatSupport] = [:]
    let versionNumber: Double

    /// 7-Zip format names (as printed by `7z i`) mapped to our identifiers.
    static let nameMap: [String: [FormatID]] = [
        "7z": [.sevenZip, .cb7], "zip": [.zip, .zipx, .jar, .war, .ear, .apk, .aab, .ipa, .epub, .cbz, .xpi, .vsix, .appx, .msix],
        "Rar": [.rar, .cbr], "Rar5": [.rar, .cbr], "tar": [.tar, .cbt], "gzip": [.gzip, .tarGzip], "bzip2": [.bzip2, .tarBzip2],
        "xz": [.xz, .tarXz], "lzma": [.lzma, .tarLzma], "Z": [.unixCompress, .tarCompress], "zstd": [.zstd, .tarZstd],
        "Zstd": [.zstd, .tarZstd], "LZ4": [.lz4, .tarLz4], "lz4": [.lz4, .tarLz4], "Brotli": [.brotli, .tarBrotli],
        "Cab": [.cab], "Arj": [.arj], "Lzh": [.lha], "Cpio": [.cpio], "Ar": [.ar, .deb], "Rpm": [.rpm], "Xar": [.xar, .pkg],
        "wim": [.wim], "Chm": [.chm], "Compound": [.msi], "Nsis": [.nsis], "Iso": [.iso], "Udf": [.udf], "Dmg": [.dmg],
        "VHD": [.vhd], "VHDX": [.vhdx], "VMDK": [.vmdk], "VDI": [.vdi], "QCOW": [.qcow2], "APFS": [.apfs], "HFS": [.hfs],
        "NTFS": [.ntfs], "FAT": [.fat], "Ext": [.ext], "SquashFS": [.squashfs], "CramFS": [.cramfs], "Split": [],
    ]

    public init(executable: URL? = HelperLocator.find(["7zz", "7z"])) {
        self.executable = executable
        var version: String?
        var number = 0.0
        var creatable = Set<String>()
        var readable = Set<String>()
        if let exe = executable, let info = ProbeCache.run(exe, ["i"]), info.status == 0 {
            let text = info.stdout
            if let m = text.range(of: #"7-Zip (\(z\) )?([0-9]+\.[0-9]+)"#, options: .regularExpression) {
                let s = String(text[m])
                version = s.components(separatedBy: " ").last
                number = Double(version ?? "") ?? 0
            }
            var inFormats = false
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("Formats:") { inFormats = true; continue }
                if line.hasPrefix("Codecs:") { break }
                guard inFormats else { continue }
                var tokens = line.split(separator: " ").map(String.init)
                guard tokens.count >= 3, Int(tokens[0]) != nil else { continue }
                let flags = tokens[1]
                tokens.removeFirst(2)
                // Creatable formats print an extra update-flags token such as "w...0" / "wu.n1".
                if let t = tokens.first, t.count == 5, t.last?.isNumber == true, t.first == "w" || t.first == "." { tokens.removeFirst() }
                guard let name = tokens.first else { continue }
                readable.insert(name)
                if flags.hasPrefix("C") { creatable.insert(name) }
            }
        }
        versionNumber = number
        let usable = executable != nil && number >= 21
        descriptor = EngineDescriptor(
            id: .sevenZip, name: "7-Zip", implementation: "Separate helper process (\(executable?.lastPathComponent ?? "7zz"))",
            version: version, minimumVersion: "21.00", license: "LGPL-2.1-or-later (+ unRAR restriction; BSD-3 for some codecs)",
            licensingRestrictions: "The bundled unRAR code may only be used to extract RAR archives, not to create a RAR-compatible compressor.",
            isAvailable: usable,
            unavailableReason: executable == nil ? "7-Zip (7zz) is not installed. Bundle it in Contents/Helpers or install it with Homebrew (brew install sevenzip)."
                : (number < 21 ? "7-Zip \(version ?? "?") is too old; 21.00 or later is required." : nil),
            location: executable?.path,
            isolation: "Separate process with a minimal environment. Writes only into a private staging folder; results are validated and imported by the safe sink. Free-space watchdog stops runaway output.")
        if usable { table = Self.buildTable(readable: readable, creatable: creatable) }
    }

    public var supportedFormats: [FormatID] { Array(table.keys).sorted() }
    public func support(for format: FormatID) -> EngineFormatSupport? { table[format] }

    static func buildTable(readable: Set<String>, creatable: Set<String>) -> [FormatID: EngineFormatSupport] {
        var t: [FormatID: EngineFormatSupport] = [:]
        let read: EngineOperations = [.inspect, .extract, .test, .selectiveExtract, .readSplit]
        for name in readable {
            for f in nameMap[name] ?? [] {
                var ops = read
                var dec: [EncryptionMethod] = []
                var enc: [EncryptionMethod] = []
                var methods: [CompressionMethod] = []
                var limits: [String] = []
                let isPackage = FormatCatalog.descriptor(for: f)?.kind == .package && f != .cb7
                if creatable.contains(name), !isPackage {
                    ops.formUnion([.create, .multithreaded])
                }
                switch f {
                case .sevenZip:
                    ops.formUnion([.encrypt, .decrypt, .encryptFilenames, .createSplit, .modify, .repair])
                    enc = [.sevenZipAES256]; dec = [.sevenZipAES256]
                    methods = [.lzma2, .lzma, .ppmd, .bzip2, .deflate, .store]
                    ops.remove(.repair)
                case .zip:
                    ops.formUnion([.encrypt, .decrypt, .createSplit, .modify])
                    enc = [.zipAES256, .zipAES128, .zipCrypto]; dec = [.zipCrypto, .zipAES128, .zipAES256]
                    methods = [.deflate, .deflate64, .bzip2, .lzma, .ppmd, .store]
                    limits = ["Split ZIPs are created as .zip.001, .zip.002 … (byte-split), which 7-Zip-compatible tools read. Classic spanned .z01 sets can be read but not created."]
                case .rar:
                    ops.insert(.decrypt)
                    dec = [.rar4AES128, .rar5AES256]
                    limits = ["Extraction only. RAR creation requires the licensed RAR program."]
                case .tar, .gzip, .bzip2, .xz, .wim, .tarGzip, .tarBzip2, .tarXz:
                    if creatable.contains(name) { ops.insert(.createSplit) }
                case .dmg:
                    limits = ["Reads the file systems inside the image without mounting it. Encrypted DMGs and some APFS images require mounting with Disk Utility."]
                case .apfs, .hfs, .ntfs, .fat, .ext, .squashfs, .cramfs, .iso, .udf, .vhd, .vhdx, .vmdk, .vdi, .qcow2:
                    limits = ["Browsing and extraction only; the image is never mounted or modified."]
                case .nsis, .msi:
                    limits = ["Installer contents are listed and extracted; the installer is never run."]
                default: break
                }
                if f == .tarGzip || f == .tarBzip2 || f == .tarXz || f == .tarZstd {
                    // Compound tarballs are handled by 7-Zip as two layers; one-step extraction is done by libarchive.
                    ops.subtract([.create, .createSplit])
                }
                t[f] = EngineFormatSupport(format: f, operations: ops, compressionMethods: methods, encryptionMethods: enc,
                                           decryptionMethods: dec, threading: "Multithreaded LZMA2/BZip2/Deflate compression.",
                                           limitations: limits)
            }
        }
        return t
    }

    func exe() throws -> URL {
        guard descriptor.isAvailable, let e = executable else {
            throw ArchiveError.engineUnavailable(.sevenZip, reason: descriptor.unavailableReason ?? "not available")
        }
        return e
    }

    // MARK: Password handling

    /// Runs a 7-Zip command, answering password prompts from the provider and retrying on a wrong password.
    func runWithPassword(_ args: [String], source: URL, options: ReadOptions, progress: OperationProgress?,
                         cwd: URL? = nil, onOutput: ((String) -> Void)? = nil) throws -> HelperProcess.Result {
        var reason = PasswordRequestReason.required
        for _ in 0..<5 {
            var supplied: Secret?
            var declined = false
            let proc = HelperProcess(try exe(), args)
            proc.workingDirectory = cwd
            proc.progress = progress
            proc.onStdoutChunk = onOutput
            proc.onPasswordPrompt = {
                // 7-Zip may prompt more than once per run (e.g. while probing the archive type);
                // the user is asked only once per attempt.
                if let s = supplied { return s }
                guard let s = options.passwordProvider?.password(for: source, reason: reason) else { declined = true; return nil }
                supplied = s
                return s
            }
            var r = try proc.run()
            if declined || (r.status == -100 && supplied == nil) {
                if reason == .previousAttemptIncorrect { throw ArchiveError.incorrectPassword(archive: source.path) }
                throw ArchiveError.passwordRequired(archive: source.path)
            }
            if supplied != nil, Self.isWrongPassword(r.combined) || (r.status >= 2 && r.combined.contains("Headers Error") && args.first != "t") {
                reason = .previousAttemptIncorrect
                continue
            }
            r.passwordSupplied = supplied != nil
            return r
        }
        throw ArchiveError.incorrectPassword(archive: source.path)
    }

    static func isWrongPassword(_ text: String) -> Bool {
        text.contains("Wrong password") || text.contains("Cannot open encrypted archive")
    }

    static func mapFailure(_ r: HelperProcess.Result, archive: URL, entry: String? = nil) -> ArchiveError {
        let t = r.combined
        if isWrongPassword(t) { return .incorrectPassword(archive: archive.path) }
        if t.contains("Missing volume") || t.contains("Unavailable data") || t.contains("Unexpected end of archive") && t.contains("volume") {
            return .missingVolume(expected: MultipartDetector.detect(archive).map { $0.missing.isEmpty ? [$0.nextVolumeName] : $0.missing } ?? [])
        }
        if t.contains("Unsupported Method") || t.contains("Unsupported method") { return .unsupportedMethod(method: firstErrorLine(t) ?? "unknown", entry: entry) }
        if t.contains("CRC Failed") { return .checksumMismatch(entry: firstErrorLine(t) ?? entry ?? "an entry") }
        if t.contains("Unexpected end of archive") || t.contains("Unexpected end of data") { return .truncated(details: firstErrorLine(t) ?? "") }
        if t.contains("Can not open the file as archive") || t.contains("Cannot open the file as archive") || t.contains("Can't open as archive") {
            if t.contains("Headers Error") { return .damaged(details: "The archive headers are damaged, or the password is wrong.") }
            return .notAnArchive(path: archive.path)
        }
        if t.contains("Data Error") || t.contains("Headers Error") { return .damaged(details: firstErrorLine(t) ?? "Data error") }
        if t.contains("There is not enough space") || t.contains("No space left") { return .insufficientSpace(needed: 0, available: 0) }
        if t.contains("Can not open output file") || t.contains("Permission denied") { return .permissionDenied(path: archive.path) }
        return .externalTool(tool: "7-Zip", exitCode: r.status, message: firstErrorLine(t) ?? "exit code \(r.status)")
    }

    static func firstErrorLine(_ t: String) -> String? {
        let lines = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let i = lines.firstIndex(where: { $0.hasPrefix("ERROR:") || $0.contains("Error") || $0.contains("ERROR") }) else { return nil }
        // "Command Line Error:" and similar put the detail on the next line.
        if lines[i].hasSuffix(":"), i + 1 < lines.count { return lines[i] + " " + lines[i + 1] }
        return lines[i]
    }

    static let commonSwitches = ["-sccUTF-8", "-scsUTF-16LE", "-bd", "-bb0", "-y"]

    /// Writes a 7-Zip list file. UTF-16LE is used because 7-Zip 23 rejects UTF-8 list files that
    /// contain characters outside the Basic Multilingual Plane (emoji, some CJK).
    static func writeListFile(_ paths: [String], to url: URL) throws {
        var data = Data()
        for (i, p) in paths.enumerated() {
            if i > 0 { data.append(contentsOf: [0x0A, 0x00]) }
            for unit in p.utf16 { data.append(UInt8(unit & 0xFF)); data.append(UInt8(unit >> 8)) }
        }
        try data.write(to: url)
    }

    // MARK: Listing

    public func list(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> ArchiveListing {
        let r = try runWithPassword(["l", "-slt"] + Self.commonSwitches + typeSwitch(source) + ["--", source.url.path],
                                    source: source.url, options: options, progress: progress)
        if r.status >= 2 { throw Self.mapFailure(r, archive: source.url) }
        var listing = Self.parseListing(r.stdout, source: source)
        // 7-Zip only asks for a password while listing when the file list itself is encrypted.
        listing.properties.hasEncryptedHeaders = r.passwordSupplied
        if r.passwordSupplied { listing.properties.hasEncryptedEntries = true }
        return listing
    }

    func typeSwitch(_ s: ArchiveSource) -> [String] {
        // Let 7-Zip auto-detect, except where our detection is more specific about the container.
        switch s.format {
        case .dmg: return ["-tdmg"]
        default: return []
        }
    }

    static func parseListing(_ text: String, source: ArchiveSource) -> ArchiveListing {
        var props = ArchiveProperties(format: source.format, archiveSize: source.totalSize, volumeCount: source.volumes.count, engine: .sevenZip)
        var entries: [ArchiveEntry] = []
        let parts = text.components(separatedBy: "\n----------\n")
        let header = parts.first ?? ""
        let body = parts.count > 1 ? parts[1...].joined(separator: "\n----------\n") : ""
        func kv(_ block: String) -> [String: String] {
            var d: [String: String] = [:]
            for line in block.components(separatedBy: "\n") {
                guard let r = line.range(of: " = ") else { continue }
                d[String(line[..<r.lowerBound])] = String(line[r.upperBound...])
            }
            return d
        }
        // Archive properties: the last "--" block in the header region.
        let archBlocks = header.components(separatedBy: "\n--\n")
        let arch = kv(archBlocks.last ?? header)
        props.formatDescription = arch["Type"]
        if let m = arch["Method"] { props.compressionMethods = m.components(separatedBy: " ").filter { !$0.isEmpty } }
        props.isSolid = arch["Solid"].map { $0 == "+" }
        if let m = arch["Method"], m.contains("AES") { props.encryptionMethod = m.contains("7zAES") ? "AES-256 (7-Zip)" : "AES" }
        if arch["Encrypted"] == "+" { props.hasEncryptedEntries = true }
        props.comment = arch["Comment"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func date(_ s: String?) -> Date? {
            guard let s, !s.isEmpty else { return nil }
            let main = String(s.prefix(19))
            guard var d = df.date(from: main) else { return nil }
            if s.count > 20, let frac = Double("0" + s.dropFirst(19)) { d.addTimeInterval(frac) }
            return d
        }
        for (i, block) in body.components(separatedBy: "\n\n").enumerated() {
            let d = kv(block)
            guard let path = d["Path"] else { continue }
            let attrs = d["Attributes"] ?? ""
            var type: EntryType = d["Folder"] == "+" || attrs.hasPrefix("D") ? .directory : .file
            var perms: UInt16?
            // Attributes look like "A_ -rw-r--r--" or "D_ drwxr-xr-x"; parse the Unix mode when present.
            if let modeStr = attrs.split(separator: " ").last, modeStr.count == 10 {
                let chars = Array(modeStr)
                if chars[0] == "l" { type = .symlink }
                var p: UInt16 = 0
                let bits: [UInt16] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
                for (k, b) in bits.enumerated() where chars[k + 1] != "-" { p |= b }
                perms = p
            }
            var linkTarget = d["Symbolic Link"]
            if linkTarget != nil, !(linkTarget?.isEmpty ?? true) { type = .symlink }
            if let h = d["Hard Link"], !h.isEmpty { linkTarget = h; type = .hardlink }
            let encrypted = d["Encrypted"] == "+"
            if encrypted { props.hasEncryptedEntries = true }
            let entry = ArchiveEntry(
                index: i, path: path, type: type,
                uncompressedSize: d["Size"].flatMap(UInt64.init),
                compressedSize: d["Packed Size"].flatMap(UInt64.init),
                modificationDate: date(d["Modified"]), creationDate: date(d["Created"]), accessDate: date(d["Accessed"]),
                permissions: perms, ownerName: d["User"], groupName: d["Group"], isEncrypted: encrypted,
                method: d["Method"], crc32: d["CRC"].flatMap { UInt32($0, radix: 16) }, linkTarget: linkTarget,
                comment: d["Comment"])
            entries.append(entry)
        }
        // Single-stream formats: 7-Zip reports one unnamed item.
        if FormatCatalog.descriptor(for: source.format)?.kind == .compressionStream, entries.count == 1, entries[0].path.isEmpty {
            entries[0].path = source.url.deletingPathExtension().lastPathComponent
        }
        if props.hasEncryptedEntries == nil { props.hasEncryptedEntries = false }
        return ArchiveListing(properties: props, entries: entries)
    }

    // MARK: Extraction

    public func extract(_ source: ArchiveSource, selection: EntrySelection, into sink: ExtractionSink,
                        options: ReadOptions, progress: OperationProgress) throws {
        let destination = (sink as? SafeExtractionSink)?.destination ?? FileManager.default.temporaryDirectory
        let staging = try StagingDirectory(near: destination)
        defer { staging.remove() }

        var args = ["x", "-o" + staging.url.path, "-bsp1"] + Self.commonSwitches + typeSwitch(source)
        var listFile: URL?
        if case .paths(let set) = selection {
            if set.contains(where: { $0.contains("*") || $0.contains("?") }) {
                // Wildcard characters in names: extract everything and filter while importing.
            } else {
                let lf = staging.url.appendingPathComponent(".ua-list.txt")
                try Self.writeListFile(set.sorted(), to: lf)
                listFile = lf
            }
        }
        // A list file must be given as -i@file: after "--" an @name would be taken literally.
        if let lf = listFile { args.append("-i@" + lf.path) }
        args += ["--", source.url.path]

        // Watchdog: stop the helper before it fills the disk.
        let limits = (sink as? SafeExtractionSink)?.options.limits ?? .default
        let watchdog = DiskWatchdog(path: staging.url.path, minimumFree: limits.minimumFreeSpace, progress: progress)
        watchdog.start()
        defer { watchdog.stop() }
        progress.setPhase("Extracting")
        let total = source.totalSize
        let r: HelperProcess.Result
        do {
            r = try runWithPassword(args, source: source.url, options: options, progress: progress) { chunk in
                if let pct = Self.lastPercent(chunk) { progress.setProcessed(UInt64(Double(total) * Double(pct) / 100)) }
            }
        } catch ArchiveError.cancelled {
            throw watchdog.tripped ?? ArchiveError.cancelled
        }
        if let w = watchdog.tripped { throw w }
        if r.status >= 2 { throw Self.mapFailure(r, archive: source.url) }
        if let lf = listFile { try? FileManager.default.removeItem(at: lf) }
        if r.status == 1 { progress.warning() }

        // Import into the destination through the sink.
        try importStaged(staging.url, selection: listFile == nil ? selection : .all, sink: sink, progress: progress)
    }

    func importStaged(_ staging: URL, selection: EntrySelection, sink: ExtractionSink, progress: OperationProgress) throws {
        if case .paths = selection {
            let filtered = FilteringSink(base: sink, selection: selection)
            try StagingImporter.importTree(staging, into: filtered, progress: progress)
        } else {
            try StagingImporter.importTree(staging, into: sink, progress: progress)
        }
    }

    static func lastPercent(_ s: String) -> Int? {
        var last: Int?
        var digits = ""
        for c in s {
            if c.isNumber { digits.append(c) } else {
                if c == "%", let n = Int(digits) { last = n }
                digits = ""
            }
        }
        return last
    }

    // MARK: Test

    public func test(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> IntegrityReport {
        let listing = try list(source, options: options, progress: progress)
        let total = source.totalSize
        let r = try runWithPassword(["t", "-bsp1"] + Self.commonSwitches + typeSwitch(source) + ["--", source.url.path],
                                    source: source.url, options: options, progress: progress) { chunk in
            if let pct = Self.lastPercent(chunk) { progress.setProcessed(UInt64(Double(total) * Double(pct) / 100)) }
        }
        var report = IntegrityReport(archive: source.url.lastPathComponent, format: source.format, engine: id)
        report.filesInspected = listing.fileCount
        report.directories = listing.directoryCount
        report.encrypted = listing.properties.hasEncryptedEntries ?? false
        report.volumes = source.volumes.count
        report.bytesVerified = listing.totalUncompressedSize ?? 0
        report.checks = ["Every entry fully decoded by 7-Zip", "Stored CRC-32 values", "Encryption padding/authentication where the format provides it"]
        if r.status == 0 {
            report.filesVerified = listing.fileCount
        } else {
            let lines = r.combined.components(separatedBy: "\n").filter { $0.hasPrefix("ERROR:") || $0.contains("CRC Failed") || $0.contains("Data Error") || $0.contains("Unexpected end") || $0.contains("Headers Error") || $0.contains("Wrong password") }
            if lines.isEmpty {
                let e = Self.mapFailure(r, archive: source.url)
                report.issues.append(.init(entry: nil, message: e.explanation, code: e.code))
            }
            for l in lines {
                let e = Self.mapFailure(HelperProcess.Result(status: r.status, stdout: l, stderr: "", wasCancelled: false), archive: source.url)
                report.issues.append(.init(entry: l.components(separatedBy: " : ").last, message: l.trimmingCharacters(in: .whitespaces), code: e.code))
            }
            report.filesVerified = max(0, listing.fileCount - report.issues.count)
        }
        return report
    }

    // MARK: Creation

    public func create(_ request: CreateRequest, progress: OperationProgress) throws -> CreateResult {
        let exe = try exe()
        let settings = request.settings
        let container = FormatCatalog.descriptor(for: request.format)?.effectiveContainer ?? request.format
        let typeArg: String
        switch container {
        case .sevenZip: typeArg = "-t7z"
        case .zip: typeArg = "-tzip"
        case .tar: typeArg = "-ttar"
        case .wim: typeArg = "-twim"
        case .gzip: typeArg = "-tgzip"
        case .bzip2: typeArg = "-tbzip2"
        case .xz: typeArg = "-txz"
        default:
            throw ArchiveError.operationNotSupported(format: request.format, operation: "creation", reason: "7-Zip cannot create this format.")
        }
        let level = settings.clampedLevel
        var args = ["a", typeArg, "-mx=\(level)", "-bsp1", "-ssp"] + Self.commonSwitches
        if settings.symlinks == .preserve { args.append("-snl") }
        if let t = settings.threads { args.append("-mmt=\(max(1, t))") } else { args.append("-mmt=on") }
        let method = settings.method
        switch container {
        case .sevenZip:
            if let m = method {
                let name = ["lzma2": "LZMA2", "lzma": "LZMA", "ppmd": "PPMd", "bzip2": "BZip2", "deflate": "Deflate", "store": "Copy"][m.rawValue]
                guard let name else { throw ArchiveError.invalidArgument("7z cannot use \(m.displayName).") }
                args.append("-m0=\(name)")
            }
            if let d = settings.dictionarySize { args.append("-md=\(d)b") }
            if let w = settings.wordSize { args.append("-mfb=\(w)") }
            switch settings.solid {
            case .off?: args.append("-ms=off")
            case .on?: args.append("-ms=on")
            case .blockSize(let b)?: args.append("-ms=\(b)b")
            case nil: break
            }
            if let mem = settings.memoryLimit { args.append("-mmemuse=\(mem)b") }
        case .zip:
            if let m = method {
                let name = ["deflate": "Deflate", "deflate64": "Deflate64", "bzip2": "BZip2", "lzma": "LZMA", "ppmd": "PPMd", "store": "Copy"][m.rawValue]
                guard let name else { throw ArchiveError.invalidArgument("ZIP via 7-Zip cannot use \(m.displayName).") }
                args.append("-mm=\(name)")
            }
            args.append("-mcu=on") // UTF-8 names
            if settings.metadata == .crossPlatform { args += ["-mtc=off", "-mta=off"] }
        default: break
        }
        var needsPassword = false
        if let enc = settings.encryption {
            guard request.password != nil else { throw ArchiveError.invalidArgument("A password is required for encryption.") }
            switch (container, enc.method) {
            case (.sevenZip, .sevenZipAES256):
                if enc.encryptFilenames { args.append("-mhe=on") }
            case (.zip, .zipAES256): args.append("-mem=AES256")
            case (.zip, .zipAES128): args.append("-mem=AES128")
            case (.zip, .zipCrypto): args.append("-mem=ZipCrypto")
            default: throw ArchiveError.invalidArgument("\(enc.method.displayName) can't be used with this format.")
            }
            args.append("-p")
            needsPassword = true
        }
        if let v = settings.splitVolumeSize {
            guard v >= 1024 else { throw ArchiveError.invalidArgument("Volumes must be at least 1 KB.") }
            args.append("-v\(v)b")
        }
        if let c = settings.comment, container == .zip, !c.isEmpty {
            // 7-Zip has no switch for ZIP comments; reported rather than silently dropped.
            progress.warning()
        }

        // Group items by base directory: 7-Zip stores paths relative to its working directory.
        let groups = Dictionary(grouping: request.items, by: { $0.baseDirectory.path })
        let outDir = request.output.deletingLastPathComponent()
        let tempName = ".\(request.output.lastPathComponent).ua-\(UInt32.random(in: 0...UInt32.max))"
        let tempURL = outDir.appendingPathComponent(tempName)
        var cleanup = [URL]()
        defer { for u in cleanup { try? FileManager.default.removeItem(at: u) } }
        let total = request.items.reduce(UInt64(0)) { $0 + $1.size }
        progress.setTotal(bytes: total, items: request.items.count)
        progress.setPhase("Compressing")
        var warnings: [String] = []

        for (i, (base, items)) in groups.sorted(by: { $0.key < $1.key }).enumerated() {
            let listURL = FileManager.default.temporaryDirectory.appendingPathComponent("ua-7z-list-\(UUID().uuidString).txt")
            cleanup.append(listURL)
            // Pass files, links and *empty* folders explicitly: naming a non-empty folder would make
            // 7-Zip add everything inside it, including items the user's filters excluded.
            let dirsWithChildren = Set(items.map { ($0.archivePath as NSString).deletingLastPathComponent })
            let paths = items.compactMap { item -> String? in
                let rel = relativePath(item.url, to: URL(fileURLWithPath: base))
                if item.type == .directory, dirsWithChildren.contains(item.archivePath) { return nil }
                return rel
            }
            try Self.writeListFile(paths, to: listURL)
            if i > 0, settings.splitVolumeSize != nil {
                throw ArchiveError.invalidArgument("Split archives must be created from items in a single folder.")
            }
            let proc = HelperProcess(exe, args + ["-i@" + listURL.path, "--", tempURL.path])
            proc.workingDirectory = URL(fileURLWithPath: base)
            proc.progress = progress
            proc.onStdoutChunk = { chunk in
                if let pct = Self.lastPercent(chunk) { progress.setProcessed(UInt64(Double(total) * Double(pct) / 100)) }
            }
            var prompts = 0
            proc.onPasswordPrompt = {
                guard needsPassword, let pw = request.password else { return nil }
                prompts += 1
                return pw
            }
            let r = try proc.run()
            if r.status >= 2 || r.status < 0 {
                removeTemp(tempURL)
                throw Self.mapFailure(r, archive: request.output)
            }
            if r.status == 1 {
                warnings.append(contentsOf: r.combined.components(separatedBy: "\n").filter { $0.hasPrefix("WARNING") || $0.contains("cannot") })
            }
        }

        // Move results into place.
        var outputs: [URL] = []
        var outBytes: UInt64 = 0
        if settings.splitVolumeSize != nil {
            let vols = ((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? [])
                .filter { $0.hasPrefix(tempName + ".") }.sorted()
            for v in vols {
                let suffix = String(v.dropFirst(tempName.count))
                let dest = outDir.appendingPathComponent(request.output.lastPathComponent + suffix)
                guard !FileManager.default.fileExists(atPath: dest.path) else {
                    vols.forEach { try? FileManager.default.removeItem(at: outDir.appendingPathComponent($0)) }
                    throw ArchiveError.destinationExists(path: dest.path)
                }
                try FileManager.default.moveItem(at: outDir.appendingPathComponent(v), to: dest)
                outputs.append(dest)
                outBytes += (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? UInt64) ?? 0
            }
        } else {
            guard !FileManager.default.fileExists(atPath: request.output.path) else {
                removeTemp(tempURL)
                throw ArchiveError.destinationExists(path: request.output.path)
            }
            try FileManager.default.moveItem(at: tempURL, to: request.output)
            outputs = [request.output]
            outBytes = (try? FileManager.default.attributesOfItem(atPath: request.output.path)[.size] as? UInt64) ?? 0
        }
        progress.setOutput(outBytes)
        progress.setProcessed(total)
        return CreateResult(outputs: outputs, inputBytes: total, outputBytes: outBytes, entryCount: request.items.count,
                            warnings: warnings, engine: id)
    }

    private func removeTemp(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    private func relativePath(_ url: URL, to base: URL) -> String {
        let p = url.standardizedFileURL.path
        let b = base.standardizedFileURL.path.hasSuffix("/") ? base.standardizedFileURL.path : base.standardizedFileURL.path + "/"
        return p.hasPrefix(b) ? String(p.dropFirst(b.count)) : url.lastPathComponent
    }

    // MARK: Modification (transactional; operates on a copy)

    /// Deletes entries from a copy of the archive at `workingCopy`.
    func delete(paths: [String], in workingCopy: URL, options: ReadOptions, progress: OperationProgress) throws {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("ua-7z-del-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: list) }
        try Self.writeListFile(paths, to: list)
        let r = try runWithPassword(["d"] + Self.commonSwitches + ["-i@" + list.path, "--", workingCopy.path],
                                    source: workingCopy, options: options, progress: progress)
        if r.status >= 2 { throw Self.mapFailure(r, archive: workingCopy) }
    }

    /// Renames entries in a copy of the archive.
    func rename(_ pairs: [(from: String, to: String)], in workingCopy: URL, options: ReadOptions, progress: OperationProgress) throws {
        var args = ["rn"] + Self.commonSwitches + ["--", workingCopy.path]
        for (f, t) in pairs { args += [f, t] }
        let r = try runWithPassword(args, source: workingCopy, options: options, progress: progress)
        if r.status >= 2 { throw Self.mapFailure(r, archive: workingCopy) }
    }

    /// Adds files (relative to `base`) into a copy of the archive at the given archive folder.
    func add(_ relPaths: [String], base: URL, to workingCopy: URL, settings: CompressionSettings, password: Secret?,
             options: ReadOptions, progress: OperationProgress) throws {
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("ua-7z-add-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: list) }
        try Self.writeListFile(relPaths, to: list)
        var args = ["a", "-mx=\(settings.clampedLevel)", "-snl"] + Self.commonSwitches
        if password != nil {
            args.append("-p")
            if settings.encryption?.encryptFilenames == true { args.append("-mhe=on") }
            if FormatDetectorShim.isZip(workingCopy) { args.append("-mem=AES256") }
        }
        args += ["-i@" + list.path, "--", workingCopy.path]
        let proc = HelperProcess(try exe(), args)
        proc.workingDirectory = base
        proc.progress = progress
        proc.onPasswordPrompt = { password ?? options.passwordProvider?.password(for: workingCopy, reason: .required) }
        let r = try proc.run()
        if r.status >= 2 { throw Self.mapFailure(r, archive: workingCopy) }
    }
}

enum FormatDetectorShim {
    static func isZip(_ url: URL) -> Bool {
        (try? FormatDetector.detect(url))?.map { FormatCatalog.descriptor(for: $0.format)?.effectiveContainer == .zip } ?? false
    }
}

/// Passes through only the selected entries (used when a helper extracted more than requested).
final class FilteringSink: ExtractionSink {
    let base: ExtractionSink
    let selection: EntrySelection
    init(base: ExtractionSink, selection: EntrySelection) {
        self.base = base
        self.selection = selection
    }
    func begin(_ entry: ArchiveEntry, extras: EntryExtras) throws -> EntryDataWriter? {
        guard selection.includes(entry.path) || entry.type == .directory && isAncestorOfSelection(entry.path) else { return nil }
        return try base.begin(entry, extras: extras)
    }
    func importFile(_ entry: ArchiveEntry, extras: EntryExtras, from url: URL) throws {
        guard selection.includes(entry.path) else { return }
        try base.importFile(entry, extras: extras, from: url)
    }
    func finish() throws { try base.finish() }
    private func isAncestorOfSelection(_ path: String) -> Bool {
        guard case .paths(let set) = selection else { return true }
        let p = ArchivePath.normalizeForDisplay(path) + "/"
        return set.contains { $0.hasPrefix(p) }
    }
}

/// Polls free space while a helper writes, and stops it before the disk fills up.
final class DiskWatchdog {
    let path: String
    let minimumFree: UInt64
    let progress: OperationProgress
    private var timer: DispatchSourceTimer?
    private(set) var tripped: ArchiveError?

    init(path: String, minimumFree: UInt64, progress: OperationProgress) {
        self.path = path
        self.minimumFree = minimumFree
        self.progress = progress
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            var s = statvfs()
            if statvfs(self.path, &s) == 0 {
                let free = UInt64(s.f_bavail) * UInt64(s.f_frsize)
                if free < self.minimumFree, self.tripped == nil {
                    self.tripped = .insufficientSpace(needed: self.minimumFree, available: free)
                    self.progress.cancel()
                }
            }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
