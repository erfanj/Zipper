import Foundation
import ArchiveCore

/// Creates RAR archives with RARLAB's command-line `rar` program when the user has installed a
/// licensed copy. RAR creation code cannot be bundled: its license forbids it. Extraction of RAR is
/// handled by libarchive and 7-Zip.
public final class RarEngine: ArchiveEngine, @unchecked Sendable {
    public let descriptor: EngineDescriptor
    let executable: URL?

    public init(executable: URL? = HelperLocator.find(["rar"])) {
        self.executable = executable
        var version: String?
        if let exe = executable, let r = ProbeCache.run(exe, ["-iver"]) {
            version = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ").first { $0.first?.isNumber == true }
        }
        descriptor = EngineDescriptor(
            id: .rar, name: "RAR (RARLAB)", implementation: "User-installed command-line tool (rar)",
            version: version, minimumVersion: "5.0", license: "Proprietary (RARLAB)",
            licensingRestrictions: "Not bundled. Requires a copy of RAR installed and licensed by the user; Universal Archiver only invokes it.",
            isAvailable: executable != nil,
            unavailableReason: executable == nil ? "Install RAR from rarlab.com (or brew install --cask rar) to create RAR archives." : nil,
            location: executable?.path,
            isolation: "Separate process; reads only the files selected for compression.")
    }

    public var supportedFormats: [FormatID] { descriptor.isAvailable ? [.rar] : [] }

    public func support(for format: FormatID) -> EngineFormatSupport? {
        guard descriptor.isAvailable, format == .rar || format == .cbr else { return nil }
        return EngineFormatSupport(format: format, operations: [.create, .encrypt, .encryptFilenames, .createSplit, .repair, .multithreaded],
                                   compressionMethods: [.store], encryptionMethods: [.rar5AES256],
                                   limitations: ["Creation and repair only; extraction uses libarchive or 7-Zip.", "Repair uses the archive's recovery record when present."])
    }

    public func list(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> ArchiveListing {
        throw ArchiveError.operationNotSupported(format: .rar, operation: "listing", reason: "The RAR engine is used for creation only.")
    }

    public func extract(_ source: ArchiveSource, selection: EntrySelection, into sink: ExtractionSink, options: ReadOptions, progress: OperationProgress) throws {
        throw ArchiveError.operationNotSupported(format: .rar, operation: "extraction", reason: "The RAR engine is used for creation only.")
    }

    public func create(_ request: CreateRequest, progress: OperationProgress) throws -> CreateResult {
        guard let exe = executable else { throw ArchiveError.engineUnavailable(.rar, reason: descriptor.unavailableReason ?? "") }
        let s = request.settings
        // -ma5 RAR5, -m0..5 level, -idq quiet, -y yes, -ol store links, -scf? names in UTF-8 lists.
        var args = ["a", "-ma5", "-m\(min(5, max(0, (s.clampedLevel * 5 + 8) / 9)))", "-idq", "-y", "-scfl"] // -scfl: list files are UTF-8
        if s.symlinks == .preserve { args.append("-ol") }
        if let t = s.threads { args.append("-mt\(max(1, min(64, t)))") }
        if s.solid == .on { args.append("-s") }
        if let v = s.splitVolumeSize { args.append("-v\(max(1, v / 1000))k") }
        if let enc = s.encryption {
            guard request.password != nil else { throw ArchiveError.invalidArgument("A password is required for encryption.") }
            guard enc.method == .rar5AES256 else { throw ArchiveError.invalidArgument("RAR supports only its own AES-256 encryption.") }
            args.append(enc.encryptFilenames ? "-hp" : "-p")
        }
        let groups = Dictionary(grouping: request.items, by: { $0.baseDirectory.path })
        guard groups.count == 1, let (base, items) = groups.first else {
            throw ArchiveError.invalidArgument("RAR archives must be created from items in a single folder.")
        }
        let outDir = request.output.deletingLastPathComponent()
        let temp = outDir.appendingPathComponent(".\(request.output.deletingPathExtension().lastPathComponent).ua-\(UInt32.random(in: 0...UInt32.max)).rar")
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("ua-rar-\(UUID().uuidString).lst")
        defer { try? FileManager.default.removeItem(at: list) }
        let dirsWithChildren = Set(items.map { ($0.archivePath as NSString).deletingLastPathComponent })
        let rels = items.compactMap { item -> String? in
            if item.type == .directory, dirsWithChildren.contains(item.archivePath) { return nil }
            let p = item.url.standardizedFileURL.path
            let b = base.hasSuffix("/") ? base : base + "/"
            return p.hasPrefix(b) ? String(p.dropFirst(b.count)) : item.url.lastPathComponent
        }
        try rels.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        args += ["-r-", "--", temp.path, "@" + list.path]
        let proc = HelperProcess(exe, args)
        proc.workingDirectory = URL(fileURLWithPath: base)
        proc.progress = progress
        proc.onPasswordPrompt = { request.password }
        progress.setPhase("Compressing")
        let r = try proc.run()
        let produced = ((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).filter {
            $0.hasPrefix(temp.deletingPathExtension().lastPathComponent)
        }.sorted()
        guard r.status == 0 else {
            produced.forEach { try? FileManager.default.removeItem(at: outDir.appendingPathComponent($0)) }
            throw ArchiveError.externalTool(tool: "rar", exitCode: r.status, message: r.combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var outputs: [URL] = []
        var bytes: UInt64 = 0
        let stem = request.output.deletingPathExtension().lastPathComponent
        for p in produced {
            let suffix = String(p.dropFirst(temp.deletingPathExtension().lastPathComponent.count))
            let dest = outDir.appendingPathComponent(stem + suffix)
            guard !FileManager.default.fileExists(atPath: dest.path) else {
                produced.forEach { try? FileManager.default.removeItem(at: outDir.appendingPathComponent($0)) }
                throw ArchiveError.destinationExists(path: dest.path)
            }
            try FileManager.default.moveItem(at: outDir.appendingPathComponent(p), to: dest)
            outputs.append(dest)
            bytes += (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? UInt64) ?? 0
        }
        return CreateResult(outputs: outputs, inputBytes: request.items.reduce(0) { $0 + $1.size }, outputBytes: bytes,
                            entryCount: request.items.count, warnings: [], engine: id)
    }

    /// Runs `rar r` (repair) on a copy, writing the reconstructed archive next to it.
    public func repair(_ archive: URL, outputDirectory: URL, progress: OperationProgress) throws -> URL? {
        guard let exe = executable else { throw ArchiveError.engineUnavailable(.rar, reason: descriptor.unavailableReason ?? "") }
        let work = outputDirectory.appendingPathComponent(".ua-rar-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = work.appendingPathComponent(archive.lastPathComponent)
        try FileManager.default.copyItem(at: archive, to: copy)
        let proc = HelperProcess(exe, ["r", "-y", "-idq", "--", copy.path])
        proc.workingDirectory = work
        proc.progress = progress
        _ = try proc.run()
        let fixed = ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).first { $0.hasPrefix("fixed.") || $0.hasPrefix("rebuilt.") }
        guard let f = fixed else { return nil }
        let dest = outputDirectory.appendingPathComponent("Repaired " + archive.lastPathComponent)
        try FileManager.default.moveItem(at: work.appendingPathComponent(f), to: dest)
        return dest
    }
}
