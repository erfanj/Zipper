import Foundation
import ArchiveCore
import ArchiveEngines
import ArchiverKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// `archiver` — command-line companion to Universal Archiver.
//
// Passwords are never accepted as arguments (they would be visible in the process list and shell
// history). They are read from the terminal with echo disabled, or from stdin with --password-stdin.

enum Exit: Int32 {
    case ok = 0, failure = 1, usage = 2, password = 3, integrity = 4, unsupported = 5, missingVolume = 6, safety = 7, io = 8, cancelled = 130

    static func code(for e: ArchiveError) -> Exit {
        switch e {
        case .passwordRequired, .incorrectPassword, .authenticationFailed: return .password
        case .damaged, .checksumMismatch, .truncated, .verificationFailed: return .integrity
        case .unsupportedFormat, .notAnArchive, .noEngineAvailable, .engineUnavailable, .operationNotSupported, .unsupportedMethod, .unsupportedEncryption, .notEditable: return .unsupported
        case .missingVolume: return .missingVolume
        case .safetyLimitExceeded, .unsafePath: return .safety
        case .io, .permissionDenied, .insufficientSpace, .fileNotFound, .destinationExists: return .io
        case .cancelled: return .cancelled
        case .invalidArgument: return .usage
        default: return .failure
        }
    }
}

struct UsageError: Error { let message: String }

/// Minimal argument parser: flags (--x), options (--x value / --x=value), positionals.
struct Args {
    var positionals: [String] = []
    var options: [String: [String]] = [:]
    var flags = Set<String>()
    static let valued: Set<String> = ["o", "output", "dest", "format", "f", "level", "l", "method", "encrypt", "split", "preset", "exclude",
                                      "include", "threads", "mode", "only", "conflict", "encoding", "algo", "manifest", "verify-manifest",
                                      "size", "to", "add", "delete", "rename", "mkdir", "move", "length", "max-size", "name", "intent",
                                      "dictionary", "word-size", "solid", "export", "import", "comment", "performance", "engine"]

    init(_ argv: [String]) throws {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" { positionals += argv[(i + 1)...]; break }
            if a.hasPrefix("--") || (a.hasPrefix("-") && a.count == 2) {
                var key = String(a.drop(while: { $0 == "-" }))
                var value: String?
                if let eq = key.firstIndex(of: "=") { value = String(key[key.index(after: eq)...]); key = String(key[..<eq]) }
                if Args.valued.contains(key) {
                    if value == nil {
                        guard i + 1 < argv.count else { throw UsageError(message: "--\(key) needs a value") }
                        i += 1
                        value = argv[i]
                    }
                    options[key, default: []].append(value!)
                } else {
                    if key == "password" { throw UsageError(message: "Passwords can't be given as arguments. Use --password-stdin or enter it when prompted.") }
                    flags.insert(key)
                }
            } else {
                positionals.append(a)
            }
            i += 1
        }
    }

    func opt(_ names: String...) -> String? { names.lazy.compactMap { options[$0]?.last }.first }
    func all(_ name: String) -> [String] { options[name] ?? [] }
    func has(_ name: String) -> Bool { flags.contains(name) }
}

// MARK: Output helpers

let isTTY = isatty(STDERR_FILENO) != 0
var jsonOutput = false
var quiet = false

func printErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func emitJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    if let d = try? enc.encode(value) { print(String(decoding: d, as: UTF8.self)) }
}

func attachProgress(_ p: OperationProgress) {
    guard isTTY, !quiet, !jsonOutput else { return }
    p.throttle = 0.2
    p.observe { s in
        var line = s.phase
        if let f = s.fraction { line += String(format: " %3.0f%%", f * 100) }
        line += "  \(ByteFormatting.string(s.processedBytes))"
        if s.bytesPerSecond > 0 { line += "  \(ByteFormatting.rate(s.bytesPerSecond))" }
        if let r = s.estimatedRemaining { line += "  ~\(ByteFormatting.duration(r)) left" }
        if let item = s.currentItem { line += "  \(item.count > 40 ? "…" + item.suffix(39) : item)" }
        FileHandle.standardError.write(Data(("\r\u{1B}[K" + line).utf8))
    }
}

func endProgress() {
    if isTTY, !quiet, !jsonOutput { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
}

// MARK: Passwords

/// Reads a password from the terminal with echo turned off.
func readSecretFromTTY(_ prompt: String) -> Secret? {
    let fd = open("/dev/tty", O_RDWR)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    _ = prompt.withCString { write(fd, $0, strlen($0)) }
    var old = termios()
    tcgetattr(fd, &old)
    var noEcho = old
    noEcho.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(fd, TCSAFLUSH, &noEcho)
    defer {
        tcsetattr(fd, TCSAFLUSH, &old)
        _ = "\n".withCString { write(fd, $0, 1) }
    }
    var bytes: [UInt8] = []
    var c: UInt8 = 0
    while read(fd, &c, 1) == 1, c != 0x0A, c != 0x0D { bytes.append(c) }
    return bytes.isEmpty ? nil : Secret(bytes: bytes)
}

var stdinLines: [Secret] = []
var stdinLoaded = false

/// Lines of stdin (read once), used by --password-stdin. Line 1: password to open; line 2: new password.
func stdinSecret(_ index: Int) -> Secret? {
    if !stdinLoaded {
        stdinLoaded = true
        let data = FileHandle.standardInput.readDataToEndOfFile()
        var line: [UInt8] = []
        for b in data {
            if b == 0x0A { stdinLines.append(Secret(bytes: line)); line = [] } else if b != 0x0D { line.append(b) }
        }
        if !line.isEmpty { stdinLines.append(Secret(bytes: line)) }
    }
    return index < stdinLines.count ? stdinLines[index] : nil
}

final class CLIPasswordProvider: PasswordProvider, @unchecked Sendable {
    let fromStdin: Bool
    init(fromStdin: Bool) { self.fromStdin = fromStdin }
    func password(for archive: URL, reason: PasswordRequestReason) -> Secret? {
        if fromStdin { return reason == .required ? stdinSecret(0) : nil }
        if reason == .previousAttemptIncorrect { printErr("Incorrect password.") }
        return readSecretFromTTY("Password for \(archive.lastPathComponent): ")
    }
}

func newPassword(_ args: Args, sourceAlsoFromStdin: Bool) throws -> Secret {
    if args.has("password-stdin") {
        guard let s = stdinSecret(sourceAlsoFromStdin ? 1 : 0), !s.isEmpty else { throw UsageError(message: "No password on stdin.") }
        return s
    }
    guard let a = readSecretFromTTY("New password: "), let b = readSecretFromTTY("Repeat password: ") else {
        throw UsageError(message: "A password is required.")
    }
    guard a == b else { throw UsageError(message: "The passwords don't match.") }
    let strength = PasswordStrength.evaluate(a.unsafeStringValue)
    if strength.rating < .fair { printErr("Warning: \(strength.rating.label) password. \(strength.feedback.joined(separator: " "))") }
    return a
}

func readOptions(_ args: Args) -> ReadOptions {
    ReadOptions(passwordProvider: CLIPasswordProvider(fromStdin: args.has("password-stdin")), filenameEncoding: args.opt("encoding"),
                allowMountingDiskImages: args.has("allow-mount"))
}

func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }

// MARK: Commands

let service = ArchiveService()

func formatFor(_ s: String) throws -> FormatID {
    let lower = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    if let d = FormatCatalog.descriptor(for: FormatID(lower)) ?? FormatCatalog.descriptor(for: FormatID(s)) { return d.id }
    if let d = FormatCatalog.formats(forExtension: lower).first { return d.id }
    throw UsageError(message: "Unknown format “\(s)”. Run `archiver formats` for the list.")
}

func compressionSettings(_ args: Args, defaultFormat: FormatID) throws -> CompressionSettings {
    var s: CompressionSettings
    if let p = args.opt("preset") {
        guard let preset = BuiltInPresets.all.first(where: { $0.id == p || $0.id == "builtin." + p || $0.name.lowercased() == p.lowercased() }) else {
            throw UsageError(message: "Unknown preset “\(p)”. Run `archiver presets`.")
        }
        s = preset.settings
    } else {
        s = CompressionSettings(format: defaultFormat)
    }
    if let f = args.opt("format", "f") { s.format = try formatFor(f) } else if args.opt("preset") == nil { s.format = defaultFormat }
    if let l = args.opt("level", "l") {
        guard let v = Int(l), (0...9).contains(v) else { throw UsageError(message: "--level must be 0–9") }
        s.level = v
    }
    if let m = args.opt("method") { s.method = CompressionMethod(rawValue: m.lowercased()) }
    if let t = args.opt("threads") { s.threads = Int(t) }
    if let d = args.opt("dictionary") {
        guard let v = FileSplitter.parseSize(d) else { throw UsageError(message: "Invalid --dictionary") }
        s.dictionarySize = v
    }
    if let w = args.opt("word-size") { s.wordSize = Int(w) }
    if let solid = args.opt("solid") {
        switch solid.lowercased() {
        case "on", "yes": s.solid = .on
        case "off", "no": s.solid = .off
        default:
            guard let v = FileSplitter.parseSize(solid) else { throw UsageError(message: "--solid on|off|SIZE") }
            s.solid = .blockSize(v)
        }
    }
    if let split = args.opt("split") {
        guard let v = FileSplitter.parseSize(split) else { throw UsageError(message: "Invalid --split size (e.g. 100M, 4.7GB)") }
        s.splitVolumeSize = v
    }
    if let e = args.opt("encrypt") {
        let container = FormatCatalog.descriptor(for: s.format)?.effectiveContainer ?? s.format
        switch (e.lowercased(), container) {
        case ("aes256", .zip), ("aes", .zip): s.encryption = .init(method: .zipAES256)
        case ("aes128", .zip): s.encryption = .init(method: .zipAES128)
        case ("zipcrypto", .zip): s.encryption = .init(method: .zipCrypto)
        case (_, .sevenZip): s.encryption = .init(method: .sevenZipAES256, encryptFilenames: args.has("hide-names"))
        case (_, .appleEncryptedArchive): s.encryption = .init(method: .appleEncryptedArchive, encryptFilenames: true)
        case (_, .rar): s.encryption = .init(method: .rar5AES256, encryptFilenames: args.has("hide-names"))
        case (_, .dmg): s.encryption = .init(method: .dmgAES)
        default: throw UsageError(message: "--encrypt is not available for \(s.format). Use zip, 7z, aea, rar or dmg.")
        }
    }
    if args.has("hide-names"), s.encryption == nil { throw UsageError(message: "--hide-names requires --encrypt") }
    if args.has("no-hidden") { s.includeHidden = false }
    if args.has("cross-platform") { s.metadata = .crossPlatform; s.filenameNormalization = .nfc }
    if args.has("mac-metadata") { s.metadata = .macPreservation }
    if args.has("follow-links") { s.symlinks = .follow }
    if args.has("skip-links") { s.symlinks = .skip }
    if args.has("no-root-folder") { s.includeRootFolder = false }
    if args.has("per-item") { s.grouping = .perItem }
    if args.has("per-folder") { s.grouping = .perFolder }
    if let c = args.opt("comment") { s.comment = c }
    for g in args.all("exclude") { s.filters.append(FilterRule(.exclude, g.hasPrefix("re:") ? .regex(String(g.dropFirst(3))) : .glob(g))) }
    for g in args.all("include") { s.filters.append(FilterRule(.include, g.hasPrefix("re:") ? .regex(String(g.dropFirst(3))) : .glob(g))) }
    if args.has("exclude-clutter") { s.filters += FileFilter.commonExclusions }
    if args.has("exclude-dev") { s.filters += FileFilter.developerExclusions }
    return s
}

struct CompressJSON: Encodable {
    struct A: Encodable { var outputs: [String]; var inputBytes: UInt64; var outputBytes: UInt64; var entries: Int; var engine: String; var verified: Bool?; var warnings: [String] }
    var archives: [A]
    var excluded: [[String: String]]
    var warnings: [String]
}

func cmdCompress(_ args: Args) throws -> Exit {
    guard !args.positionals.isEmpty else { throw UsageError(message: "archiver compress ITEMS… [-o OUTPUT | --format F --dest DIR]") }
    let items = args.positionals.map(url)
    var dest: URL? = args.opt("dest").map(url)
    var name: String? = args.opt("name")
    var defaultFormat = FormatID.zip
    if let out = args.opt("output", "o") {
        let o = url(out)
        dest = o.deletingLastPathComponent()
        if let m = FormatCatalog.matchExtension(of: o.lastPathComponent) {
            defaultFormat = m.formats.first!.id
            name = String(o.lastPathComponent.dropLast(m.ext.count + 1))
        } else {
            name = o.lastPathComponent
        }
        if FileManager.default.fileExists(atPath: o.path), !args.has("force") {
            throw ArchiveError.destinationExists(path: o.path)
        }
        if args.has("force") { try? FileManager.default.removeItem(at: o) }
    }
    let settings = try compressionSettings(args, defaultFormat: defaultFormat)
    let pw = settings.encryption != nil ? try newPassword(args, sourceAlsoFromStdin: false) : nil
    if let perf = args.opt("performance"), let m = PerformanceMode(rawValue: perf) { service.performanceMode = m }
    let p = OperationProgress()
    attachProgress(p)
    installSignalHandler(p)
    let outcome = try service.compress(CompressRequest(items: items, destinationDirectory: dest, archiveName: name, settings: settings,
                                                       password: pw, verifyAfterCreation: args.has("verify")), progress: p)
    endProgress()
    if jsonOutput {
        emitJSON(CompressJSON(archives: outcome.archives.map { .init(outputs: $0.outputs.map(\.path), inputBytes: $0.inputBytes, outputBytes: $0.outputBytes,
                                                                     entries: $0.entryCount, engine: $0.engine.rawValue,
                                                                     verified: $0.verification.map { $0.result == .passed }, warnings: $0.warnings) },
                              excluded: outcome.excluded.map { ["path": $0.path, "reason": $0.reason] }, warnings: outcome.warnings))
    } else if !quiet {
        for a in outcome.archives {
            let savings = a.savings.map { $0 > -0.0005 ? String(format: " (%.1f%% smaller)", $0 * 100) : String(format: " (%.1f%% larger — the content was already compressed or very small)", -$0 * 100) } ?? ""
            print("Created \(a.outputs.map(\.lastPathComponent).joined(separator: ", ")) — \(ByteFormatting.string(a.inputBytes)) → \(ByteFormatting.string(a.outputBytes))\(savings) [\(a.engine)]")
            if let v = a.verification { print("  Verification: \(v.result.rawValue)") }
            a.warnings.forEach { print("  Warning: \($0)") }
        }
        if !outcome.excluded.isEmpty {
            print("\(outcome.excluded.count) item(s) excluded:")
            outcome.excluded.prefix(20).forEach { print("  \($0.path) — \($0.reason)") }
            if outcome.excluded.count > 20 { print("  …") }
        }
        outcome.warnings.forEach { print("Warning: \($0)") }
    }
    return .ok
}

func extractionOptions(_ args: Args) throws -> ExtractionOptions {
    var o = ExtractionOptions()
    switch args.opt("conflict")?.lowercased() {
    case nil, "keep-both": o.conflictPolicy = .keepBoth
    case "replace", "overwrite": o.conflictPolicy = .replace
    case "skip": o.conflictPolicy = .skip
    case "newer", "replace-older": o.conflictPolicy = .replaceIfOlder
    default: throw UsageError(message: "--conflict keep-both|replace|skip|newer")
    }
    if args.has("trusted") { o.limits = .trusted; o.linkPolicy = .preserveAll }
    if args.has("no-links") { o.linkPolicy = .skip }
    if let m = args.opt("max-size"), let v = FileSplitter.parseSize(m) { o.limits.maxTotalBytes = v }
    if args.has("keep-macosx") { o.skipAppleDoubleArtifacts = false }
    if args.has("no-permissions") { o.restorePermissions = false }
    return o
}

struct ExtractJSON: Encodable {
    var archive: String
    var created: [String]
    var engine: String
    var report: ExtractionReport
    var verification: VerificationSummary?
    var warnings: [String]
    var notes: [String]
}

func cmdExtract(_ args: Args) throws -> Exit {
    guard !args.positionals.isEmpty else { throw UsageError(message: "archiver extract ARCHIVE… [-o DIR]") }
    let archives = ArchiveService.distinctArchives(args.positionals.map(url))
    let mode: ExtractionMode
    switch args.opt("mode")?.lowercased() {
    case nil, "smart": mode = .smart
    case "here": mode = .here
    case "folder", "new-folder": mode = .newFolder
    default: throw UsageError(message: "--mode smart|here|folder")
    }
    let selection: EntrySelection = args.all("only").isEmpty ? .all : .paths(Set(args.all("only").map(ArchivePath.normalizeForDisplay)))
    let options = try extractionOptions(args)
    var results: [ExtractJSON] = []
    var worst = Exit.ok
    let caching = CachingPasswordProvider(upstream: CLIPasswordProvider(fromStdin: args.has("password-stdin")))
    for a in archives {
        let p = OperationProgress()
        attachProgress(p)
        installSignalHandler(p)
        var ro = readOptions(args)
        ro.passwordProvider = caching
        do {
            let o = try service.extract(ExtractRequest(archive: a, destination: args.opt("output", "o").map(url), mode: mode, selection: selection,
                                                       options: options, readOptions: ro, extractNestedArchives: args.has("nested"),
                                                       verifyAfterExtraction: args.has("verify"), trashArchiveAfterVerification: args.has("trash-after")), progress: p)
            endProgress()
            results.append(ExtractJSON(archive: a.path, created: o.createdItems.map(\.path), engine: o.engine.rawValue, report: o.report,
                                       verification: o.verification, warnings: o.warnings, notes: o.engineNotes))
            if !jsonOutput, !quiet {
                print("Extracted \(a.lastPathComponent) → \(o.createdItems.map(\.lastPathComponent).joined(separator: ", ")) (\(o.report.filesWritten) files, \(ByteFormatting.string(o.report.bytesWritten)))")
                for b in o.report.blocked { print("  Blocked: \(b.path) — \(b.reason)") }
                for s in o.report.skipped.prefix(20) { print("  Skipped: \(s.path) — \(s.reason)") }
                for r in o.report.renamed.prefix(20) { print("  Renamed: \(r.archivePath) → \(r.writtenAs)") }
                if !o.report.potentiallyExecutable.isEmpty {
                    print("  Note: \(o.report.potentiallyExecutable.count) extracted item(s) can run code (apps, scripts or programs). They were not opened.")
                }
                if let v = o.verification { print("  Verification: \(v.passed ? "passed" : "FAILED") (\(v.filesChecked) files)"); v.mismatches.forEach { print("    \($0)") } }
                (o.warnings + o.engineNotes).forEach { print("  \($0)") }
            }
            if !o.report.blocked.isEmpty, worst == .ok { worst = .safety }
        } catch {
            endProgress()
            let e = ArchiveError.wrap(error)
            report(e, context: a.lastPathComponent)
            worst = Exit.code(for: e)
            if case .cancelled = e { break }
        }
    }
    if jsonOutput { emitJSON(results) }
    return worst
}

struct ListJSON: Encodable {
    var archive: String
    var format: String
    var engine: String
    var properties: ArchiveProperties
    var entries: [ArchiveEntry]
    var multipart: MultipartSet?
}

func cmdList(_ args: Args) throws -> Exit {
    guard let path = args.positionals.first else { throw UsageError(message: "archiver list ARCHIVE") }
    let opened = try service.open(url(path), options: readOptions(args))
    if jsonOutput {
        emitJSON(ListJSON(archive: path, format: opened.detection.format.rawValue, engine: opened.engine.rawValue,
                          properties: opened.listing.properties, entries: opened.listing.entries, multipart: opened.detection.multipart))
        return .ok
    }
    let l = opened.listing
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm"
    for e in l.entries {
        let size = e.type == .directory ? "<dir>" : (e.uncompressedSize.map { String($0) } ?? "?")
        let date = e.modificationDate.map { df.string(from: $0) } ?? "                "
        let flag = e.isEncrypted ? "*" : " "
        let link = e.linkTarget.map { " -> \($0)" } ?? ""
        print("\(date)  \(size.padding(toLength: 12, withPad: " ", startingAt: 0)) \(flag) \(e.path)\(link)")
    }
    print("")
    print("\(l.fileCount) files, \(l.directoryCount) folders, \(l.totalUncompressedSize.map(ByteFormatting.string) ?? "unknown size")")
    print("Format: \(FormatCatalog.descriptor(for: opened.detection.format)?.name ?? opened.detection.format.rawValue)\(l.properties.formatDescription.map { " (\($0))" } ?? "") — engine: \(opened.engine)")
    if l.properties.hasEncryptedEntries == true { print("Encrypted: yes\(l.properties.hasEncryptedHeaders == true ? " (file names hidden)" : "")") }
    if let mp = opened.detection.multipart { print("Volumes: \(mp.volumes.count)") }
    opened.engineNotes.forEach { print($0) }
    return .ok
}

func cmdInfo(_ args: Args) throws -> Exit {
    guard let path = args.positionals.first else { throw UsageError(message: "archiver info ARCHIVE") }
    let u = url(path)
    let opened = try service.open(u, options: readOptions(args))
    let l = opened.listing
    let unknown = "Unknown"
    let savings: String = {
        guard let total = l.totalUncompressedSize, total > 0, let size = l.properties.archiveSize else { return unknown }
        return String(format: "%.1f%%", (1 - Double(size) / Double(total)) * 100)
    }()
    var info: [(String, String)] = [
        ("Filename", u.lastPathComponent),
        ("Format", (FormatCatalog.descriptor(for: opened.detection.format)?.name ?? opened.detection.format.rawValue) + (l.properties.formatDescription.map { " (\($0))" } ?? "")),
        ("Detected by", opened.detection.basis.rawValue),
        ("Compression", l.properties.compressionMethods.isEmpty ? (l.properties.filters.isEmpty ? unknown : l.properties.filters.joined(separator: ", ")) : l.properties.compressionMethods.joined(separator: ", ")),
        ("Encryption", l.properties.hasEncryptedEntries == true ? (l.properties.encryptionMethod ?? "Yes") : (l.properties.hasEncryptedEntries == false ? "None" : unknown)),
        ("Encrypted filenames", l.properties.hasEncryptedHeaders.map { $0 ? "Yes" : "No" } ?? unknown),
        ("Original size", l.totalUncompressedSize.map(ByteFormatting.string) ?? unknown),
        ("Compressed size", l.properties.archiveSize.map(ByteFormatting.string) ?? unknown),
        ("Space savings", savings),
        ("Files", String(l.fileCount)),
        ("Folders", String(l.directoryCount)),
        ("Solid", l.properties.isSolid.map { $0 ? "Yes" : "No" } ?? unknown),
        ("Volumes", String(opened.detection.multipart?.volumes.count ?? 1)),
        ("Engine", opened.engine.rawValue),
        ("Integrity", "Not tested (run `archiver test`)"),
    ]
    if let c = l.properties.comment { info.append(("Comment", c)) }
    if jsonOutput { emitJSON(Dictionary(info, uniquingKeysWith: { a, _ in a })); return .ok }
    print("Archive Information\n")
    for (k, v) in info { print("\(k):\n  \(v)") }
    return .ok
}

func cmdTest(_ args: Args) throws -> Exit {
    guard !args.positionals.isEmpty else { throw UsageError(message: "archiver test ARCHIVE…") }
    var worst = Exit.ok
    var reports: [IntegrityReport] = []
    for path in args.positionals {
        let p = OperationProgress()
        attachProgress(p)
        installSignalHandler(p)
        do {
            let r = try service.test(url(path), options: readOptions(args), progress: p)
            endProgress()
            reports.append(r)
            if !jsonOutput { print(r.textSummary); print("") }
            if r.result == .failed { worst = r.issues.contains { $0.code == "missing-volume" } ? .missingVolume : .integrity }
        } catch {
            endProgress()
            let e = ArchiveError.wrap(error)
            report(e, context: path)
            worst = Exit.code(for: e)
        }
    }
    if jsonOutput { emitJSON(reports) }
    return worst
}

func cmdConvert(_ args: Args) throws -> Exit {
    guard let path = args.positionals.first, let to = args.opt("to", "format") else { throw UsageError(message: "archiver convert ARCHIVE --to FORMAT") }
    var settings = try compressionSettings(args, defaultFormat: try formatFor(to))
    settings.format = try formatFor(to)
    let src = url(path)
    let sourceEncrypted = (try? service.open(src, options: ReadOptions()).listing.properties.hasEncryptedEntries) ?? true
    let pw = settings.encryption != nil ? try newPassword(args, sourceAlsoFromStdin: sourceEncrypted == true && args.has("password-stdin")) : nil
    let p = OperationProgress()
    attachProgress(p)
    installSignalHandler(p)
    let preview = try? service.open(src, options: readOptions(args))
    if let l = preview?.listing, !jsonOutput {
        for w in service.conversionWarnings(from: l, to: settings) { print("Note — \(w.feature): \(w.message)") }
    }
    let o = try service.convert(ConvertRequest(archive: src, settings: settings, destinationDirectory: args.opt("dest", "o").map(url),
                                               readOptions: readOptions(args), newPassword: pw), progress: p)
    endProgress()
    if jsonOutput {
        emitJSON(["output": o.created.outputs.first?.path ?? "", "identical": String(o.comparison.identical.count),
                  "warnings": o.warnings.map(\.message).joined(separator: " | ")])
    } else {
        print("Converted to \(o.created.outputs.map(\.lastPathComponent).joined(separator: ", ")) — \(o.comparison.identical.count) files verified identical by SHA-256.")
    }
    return .ok
}

func cmdHash(_ args: Args) throws -> Exit {
    if let m = args.opt("verify-manifest") {
        let r = try ChecksumManifest.verify(manifest: url(m))
        if jsonOutput { emitJSON(["ok": r.ok, "mismatched": r.mismatched, "missing": r.missing]) } else {
            r.ok.forEach { print("\($0): OK") }
            r.mismatched.forEach { print("\($0): FAILED") }
            r.missing.forEach { print("\($0): MISSING") }
        }
        return r.passed ? .ok : .integrity
    }
    guard !args.positionals.isEmpty else { throw UsageError(message: "archiver hash FILES… [--algo sha256] [--manifest OUT]") }
    let algo = HashAlgorithm(rawValue: (args.opt("algo") ?? "sha256").lowercased().replacingOccurrences(of: "-", with: "")) ?? .sha256
    if let note = algo.note, !quiet { printErr("Note: \(algo.displayName) — \(note)") }
    let files = args.positionals.map(url)
    if let m = args.opt("manifest") {
        let text = try ChecksumManifest.generate(for: files, base: url(m).deletingLastPathComponent(), algorithm: algo)
        try text.write(to: url(m), atomically: true, encoding: .utf8)
        if !quiet { print("Wrote \(m)") }
        return .ok
    }
    var out: [String: String] = [:]
    for f in files {
        let d = try StreamingHasher.hashFile(at: f, algorithm: algo)
        out[f.path] = d
        if !jsonOutput { print("\(d)  \(f.lastPathComponent)") }
    }
    if jsonOutput { emitJSON(out) }
    return .ok
}

func cmdFormats(_ args: Args) throws -> Exit {
    let matrix = service.registry.capabilityMatrix()
    if jsonOutput {
        struct Doc: Encodable { var generatedBy: String; var engines: [EngineDescriptor]; var formats: [FormatCapabilityRow] }
        emitJSON(Doc(generatedBy: "\(ProductInfo.cliName) formats --json", engines: service.registry.engines.map(\.descriptor), formats: matrix))
        return .ok
    }
    for cat in FormatCategory.allCases {
        print("\n\(cat.displayName)")
        for row in matrix where row.category == cat {
            let ops = row.availableOperations
            func m(_ o: EngineOperations, _ s: String) -> String { ops.contains(o) ? s : "-" }
            let flags = m(.extract, "R") + m(.create, "W") + m(.encrypt, "E") + m(.decrypt, "D") + m(.createSplit, "S") + m(.modify, "M")
            let engines = row.engines.filter(\.available).map(\.engine.rawValue).joined(separator: ",")
            print("  \(flags)  \(row.name.padding(toLength: 30, withPad: " ", startingAt: 0)) .\(row.extensions.joined(separator: " .").padding(toLength: 30, withPad: " ", startingAt: 0)) \(engines.isEmpty ? "(no engine installed)" : engines)")
        }
    }
    print("\nR read  W write  E encrypt  D decrypt  S split  M modify. Recognition alone is not support: rows marked “no engine installed” are detected but cannot be opened on this machine.")
    return .ok
}

func cmdEngines(_ args: Args) throws -> Exit {
    let ds = service.registry.engines.map(\.descriptor)
    if jsonOutput { emitJSON(ds); return .ok }
    for d in ds {
        print("\(d.isAvailable ? "✓" : "✗") \(d.name) \(d.version ?? "") — \(d.implementation)")
        print("    License: \(d.license)")
        if let r = d.licensingRestrictions { print("    Restrictions: \(r)") }
        if let r = d.unavailableReason { print("    Unavailable: \(r)") }
        print("    Isolation: \(d.isolation)")
    }
    return .ok
}

func cmdSplit(_ args: Args) throws -> Exit {
    guard let f = args.positionals.first, let sz = args.opt("size"), let size = FileSplitter.parseSize(sz) else {
        throw UsageError(message: "archiver split FILE --size 100M")
    }
    let p = OperationProgress()
    attachProgress(p)
    let r = try FileSplitter.split(url(f), partSize: size, into: args.opt("dest", "o").map(url), progress: p)
    endProgress()
    if jsonOutput { emitJSON(["parts": r.parts.map(\.path), "sha256": [r.sha256]]) } else {
        print("Split into \(r.parts.count) parts. SHA-256 \(r.sha256)\(r.manifest.map { " (manifest: \($0.lastPathComponent))" } ?? "")")
    }
    return .ok
}

func cmdJoin(_ args: Args) throws -> Exit {
    guard let f = args.positionals.first else { throw UsageError(message: "archiver join FILE.001") }
    let p = OperationProgress()
    attachProgress(p)
    let r = try FileSplitter.join(firstPart: url(f), to: args.opt("output", "o").map(url), progress: p)
    endProgress()
    print("Joined into \(r.output.lastPathComponent). SHA-256 \(r.sha256) — \(r.matchedManifest == true ? "matches manifest" : (r.matchedManifest == nil ? "no manifest to compare" : "MISMATCH"))")
    return .ok
}

func cmdCompare(_ args: Args) throws -> Exit {
    guard args.positionals.count == 2 else { throw UsageError(message: "archiver compare A B [--content]") }
    let r = try service.compare(url(args.positionals[0]), url(args.positionals[1]), mode: args.has("content") ? .content : .metadata,
                                leftOptions: readOptions(args), rightOptions: readOptions(args))
    if jsonOutput { emitJSON(r) } else if args.has("csv") { print(r.csvReport) } else { print(r.textReport) }
    return r.isIdentical ? .ok : .failure
}

func cmdRepair(_ args: Args) throws -> Exit {
    guard let f = args.positionals.first else { throw UsageError(message: "archiver repair ARCHIVE [-o DIR] [--analyze]") }
    let u = url(f)
    let a = try service.analyzeDamage(u, options: readOptions(args))
    if args.has("analyze") || !a.isDamaged {
        if jsonOutput { emitJSON(a) } else {
            print("Damage analysis for \(a.archive): \(a.isDamaged ? "damaged" : "no damage found")")
            a.problems.forEach { print("  • \($0)") }
            print(a.estimate)
        }
        return a.isDamaged ? .integrity : .ok
    }
    let r = try service.recover(u, to: args.opt("output", "o").map(url) ?? u.deletingLastPathComponent(), options: readOptions(args))
    if jsonOutput { emitJSON(r) } else { print(r.textReport) }
    return r.failed.isEmpty && r.stoppedEarly == nil ? .ok : .integrity
}

func cmdEdit(_ args: Args) throws -> Exit {
    guard let f = args.positionals.first else { throw UsageError(message: "archiver edit ARCHIVE --add FILE[:FOLDER] --delete PATH --rename PATH=NAME --move PATH=FOLDER --mkdir PATH") }
    var edits: [ArchiveEdit] = []
    for a in args.all("add") {
        let parts = a.split(separator: ":", maxSplits: 1).map(String.init)
        edits.append(.add(files: [url(parts[0])], toFolder: parts.count > 1 ? parts[1] : ""))
    }
    if !args.all("delete").isEmpty { edits.append(.delete(paths: args.all("delete"))) }
    for r in args.all("rename") {
        let p = r.split(separator: "=", maxSplits: 1).map(String.init)
        guard p.count == 2 else { throw UsageError(message: "--rename PATH=NEWNAME") }
        edits.append(.rename(path: p[0], newName: p[1]))
    }
    for r in args.all("move") {
        let p = r.split(separator: "=", maxSplits: 1).map(String.init)
        guard p.count == 2 else { throw UsageError(message: "--move PATH=FOLDER") }
        edits.append(.move(path: p[0], toFolder: p[1]))
    }
    for m in args.all("mkdir") { edits.append(.createFolder(path: m)) }
    guard !edits.isEmpty else { throw UsageError(message: "No edits given.") }
    let ro = readOptions(args)
    let o = try service.modify(ModifyRequest(archive: url(f), edits: edits, readOptions: ro, password: nil, allowSignedPackages: args.has("allow-signed")))
    print("Updated \(o.archive.lastPathComponent): \(o.entryCount) entries, verification \(o.verification.result.rawValue). (\(o.strategy))")
    o.warnings.forEach { print("Warning: \($0)") }
    return .ok
}

func cmdAdvise(_ args: Args) throws -> Exit {
    guard !args.positionals.isEmpty else { throw UsageError(message: "archiver advise ITEMS… [--intent general|windows|smallest|fastest|mac]") }
    let c = try SourceCollector.collect(args.positionals.map(url), settings: CompressionSettings())
    let intent: AdvisorIntent = ["windows": .shareWithWindows, "smallest": .smallestSize, "fastest": .fastest, "mac": .macArchival][args.opt("intent") ?? ""] ?? .general
    let profile = CompressionAdvisor.profile(c, compressor: LibArchiveSampleCompressor(), methods: [.deflate, .lzma2, .zstd, .xz])
    let rec = CompressionAdvisor.recommend(profile, intent: intent)
    func line(_ o: Recommendation.Option) -> String {
        var s = "\(o.title): \(o.explanation)"
        if let b = o.estimatedBytes { s += " Estimated size ≈ \(ByteFormatting.string(b))." }
        return s
    }
    print("Selection: \(c.fileCount) files, \(ByteFormatting.string(c.totalBytes))")
    print("Recommended — \(line(rec.primary))")
    rec.alternatives.forEach { print("  Alternative — \(line($0))") }
    print(rec.basis)
    return .ok
}

func cmdAnalyze(_ args: Args) throws -> Exit {
    guard let f = args.positionals.first else { throw UsageError(message: "archiver analyze ARCHIVE") }
    let l = try service.open(url(f), options: readOptions(args)).listing
    let a = ArchiveAnalysis(listing: l)
    print("Largest files:")
    a.largestFiles.prefix(10).forEach { print("  \(ByteFormatting.string($0.uncompressedSize ?? 0).padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.path)") }
    print("By type:")
    a.bytesByKind.forEach { print("  \($0.kind.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(ByteFormatting.string($0.bytes)) in \($0.count) files") }
    print("By top-level folder:")
    a.directorySizes.prefix(10).forEach { print("  \(ByteFormatting.string($0.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.path)") }
    if let r = a.overallRatio { print(String(format: "Compressed to %.1f%% of original size.", r * 100)) }
    if !a.poorlyCompressed.isEmpty { print("\(a.poorlyCompressed.count) files compressed poorly (already-compressed data).") }
    return .ok
}

func cmdDuplicates(_ args: Args) throws -> Exit {
    guard !args.positionals.isEmpty else { throw UsageError(message: "archiver duplicates ARCHIVE…") }
    let groups = try service.findDuplicates(in: args.positionals.map(url), options: readOptions(args))
    if jsonOutput { emitJSON(groups); return .ok }
    if groups.isEmpty { print("No duplicate files found.") }
    for g in groups {
        print("\(ByteFormatting.string(g.size)) × \(g.members.count)  sha256:\(g.sha256.prefix(16))…")
        g.members.forEach { print("    \($0.archive): \($0.path)") }
    }
    return .ok
}

func cmdPresets(_ args: Args) throws -> Exit {
    if let e = args.opt("export") {
        try PresetStore.export(BuiltInPresets.all).write(to: url(e))
        print("Exported \(BuiltInPresets.all.count) presets to \(e) (presets never contain passwords).")
        return .ok
    }
    for p in BuiltInPresets.all { print("\(p.id.replacingOccurrences(of: "builtin.", with: "").padding(toLength: 14, withPad: " ", startingAt: 0)) \(p.name) — \(p.summary)") }
    return .ok
}

func cmdGenpass(_ args: Args) throws -> Exit {
    let pw = args.has("passphrase") ? PasswordGenerator.passphrase(words: Int(args.opt("length") ?? "6") ?? 6)
        : PasswordGenerator.generate(length: Int(args.opt("length") ?? "20") ?? 20, symbols: !args.has("no-symbols"))
    print(pw)
    let s = PasswordStrength.evaluate(pw)
    if !quiet { printErr("Strength: \(s.rating.label) (~\(Int(s.bits)) bits)") }
    return .ok
}

func report(_ e: ArchiveError, context: String) {
    if jsonOutput {
        emitJSON(["error": e.code, "title": e.title, "message": e.explanation, "context": context])
        return
    }
    printErr("\(context): \(e.title). \(e.explanation)")
    for s in e.suggestions { printErr("  • \(s)") }
}

// MARK: Signals

var activeProgress: OperationProgress?
func installSignalHandler(_ p: OperationProgress) {
    activeProgress = p
    signal(SIGINT) { _ in activeProgress?.cancel() }
}

let usage = """
\(ProductInfo.cliName) — \(ProductInfo.name) command-line companion (\(ProductInfo.version))

Usage:
  archiver compress ITEMS… -o OUT.ext | --format FMT [--dest DIR]
                   [--level 0-9] [--method M] [--encrypt aes256|aes128|zipcrypto] [--hide-names]
                   [--split SIZE] [--preset NAME] [--per-item|--per-folder] [--exclude GLOB]…
                   [--no-hidden] [--cross-platform|--mac-metadata] [--threads N] [--verify]
  archiver extract ARCHIVE… [-o DIR] [--mode smart|here|folder] [--only PATH]…
                   [--conflict keep-both|replace|skip|newer] [--nested] [--verify] [--trusted]
  archiver list ARCHIVE            archiver info ARCHIVE          archiver test ARCHIVE…
  archiver convert ARCHIVE --to FMT [compress options]
  archiver edit ARCHIVE --add FILE[:FOLDER] --delete PATH --rename PATH=NAME --move PATH=FOLDER --mkdir PATH
  archiver repair ARCHIVE [--analyze] [-o DIR]
  archiver compare A B [--content] [--csv]
  archiver duplicates ARCHIVE…     archiver analyze ARCHIVE       archiver advise ITEMS…
  archiver hash FILES… [--algo sha256|sha512|crc32|md5|sha1] [--manifest OUT] | --verify-manifest FILE
  archiver split FILE --size 100M  archiver join FILE.001
  archiver formats                 archiver engines               archiver presets [--export FILE]
  archiver genpass [--length N] [--passphrase]

Common options: --json  --quiet  --password-stdin  --encoding CHARSET  --allow-mount
Passwords are read from the terminal (hidden) or from stdin with --password-stdin; never from arguments.
Exit codes: 0 ok, 1 failure, 2 usage, 3 password, 4 integrity, 5 unsupported, 6 missing volume, 7 safety, 8 I/O, 130 cancelled.
"""

// MARK: Main

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first, !["-h", "--help", "help"].contains(command) else {
    print(usage)
    exit(argv.isEmpty ? Exit.usage.rawValue : Exit.ok.rawValue)
}
if command == "--version" || command == "version" {
    print("\(ProductInfo.cliName) \(ProductInfo.version)")
    exit(0)
}

let code: Exit
do {
    let args = try Args(Array(argv.dropFirst()))
    jsonOutput = args.has("json")
    quiet = args.has("quiet") || args.has("q")
    switch command {
    case "compress", "c", "a": code = try cmdCompress(args)
    case "extract", "x", "e": code = try cmdExtract(args)
    case "list", "l", "ls": code = try cmdList(args)
    case "info": code = try cmdInfo(args)
    case "test", "t": code = try cmdTest(args)
    case "convert": code = try cmdConvert(args)
    case "hash", "checksum": code = try cmdHash(args)
    case "formats": code = try cmdFormats(args)
    case "engines": code = try cmdEngines(args)
    case "split": code = try cmdSplit(args)
    case "join": code = try cmdJoin(args)
    case "compare", "diff": code = try cmdCompare(args)
    case "repair": code = try cmdRepair(args)
    case "edit": code = try cmdEdit(args)
    case "advise": code = try cmdAdvise(args)
    case "analyze": code = try cmdAnalyze(args)
    case "duplicates", "dupes": code = try cmdDuplicates(args)
    case "presets": code = try cmdPresets(args)
    case "genpass": code = try cmdGenpass(args)
    default: throw UsageError(message: "Unknown command “\(command)”.")
    }
} catch let e as UsageError {
    printErr("Error: \(e.message)")
    printErr("Run `archiver help` for usage.")
    code = .usage
} catch {
    endProgress()
    let e = ArchiveError.wrap(error)
    report(e, context: command)
    code = Exit.code(for: e)
}
PreviewCache.shared.clear()
exit(code.rawValue)
