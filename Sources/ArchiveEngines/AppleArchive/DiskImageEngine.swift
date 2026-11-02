import Foundation
import ArchiveCore

#if os(macOS)
/// Disk images through macOS's `hdiutil`: creating DMGs (optionally AES-encrypted), verifying them,
/// and — only with explicit user consent — mounting them read-only to extract contents that 7-Zip
/// cannot read (encrypted or APFS-based images).
///
/// Passwords are passed with `-stdinpass`, never as arguments. Images are attached with
/// `-readonly -nobrowse -noautoopen`, so nothing appears in Finder and nothing inside is executed.
public final class DiskImageEngine: ArchiveEngine, @unchecked Sendable {
    public let descriptor: EngineDescriptor
    let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    public init() {
        let ok = FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")
        descriptor = EngineDescriptor(
            id: .diskImage, name: "Disk Images (hdiutil)", implementation: "macOS system tool /usr/bin/hdiutil",
            version: nil, minimumVersion: "macOS 14", license: "Apple system component", isAvailable: ok,
            unavailableReason: ok ? nil : "hdiutil is missing", location: hdiutil.path,
            isolation: "Images are attached read-only, hidden from Finder, at a random private mount point, only after explicit consent, and detached afterwards.")
    }

    public var supportedFormats: [FormatID] { [.dmg] }

    public func support(for format: FormatID) -> EngineFormatSupport? {
        guard format == .dmg, descriptor.isAvailable else { return nil }
        return EngineFormatSupport(format: .dmg, operations: [.create, .encrypt, .test, .extract, .inspect, .decrypt],
                                   compressionMethods: [.zlib, .lzfse, .lzma, .bzip2, .store],
                                   encryptionMethods: [.dmgAES], decryptionMethods: [.dmgAES],
                                   limitations: ["Browsing/extraction mounts the image read-only and requires your permission each time.",
                                                 "Unencrypted DMGs are browsed without mounting through the 7-Zip engine when it is available."])
    }

    private func run(_ args: [String], password: Secret? = nil, progress: OperationProgress?) throws -> HelperProcess.Result {
        let p = HelperProcess(hdiutil, args)
        p.progress = progress
        // -stdinpass reads a NUL-terminated password from stdin.
        p.initialInput = password
        return try p.run()
    }

    public func list(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> ArchiveListing {
        try withMounted(source, options: options, progress: progress) { mount in
            var entries: [ArchiveEntry] = []
            let fm = FileManager.default
            let en = fm.enumerator(at: mount, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey, .isSymbolicLinkKey], options: [])
            var i = 0
            while let u = en?.nextObject() as? URL {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey, .isSymbolicLinkKey])
                let rel = String(u.path.dropFirst(mount.path.count + 1))
                let type: EntryType = v?.isSymbolicLink == true ? .symlink : (v?.isDirectory == true ? .directory : .file)
                entries.append(ArchiveEntry(index: i, path: rel, type: type, uncompressedSize: v?.fileSize.map(UInt64.init),
                                            modificationDate: v?.contentModificationDate))
                i += 1
            }
            return ArchiveListing(properties: ArchiveProperties(format: .dmg, formatDescription: "Apple Disk Image (mounted read-only)",
                                                                archiveSize: source.totalSize, engine: id), entries: entries)
        }
    }

    public func extract(_ source: ArchiveSource, selection: EntrySelection, into sink: ExtractionSink,
                        options: ReadOptions, progress: OperationProgress) throws {
        try withMounted(source, options: options, progress: progress) { mount in
            let target: ExtractionSink = selection == .all ? sink : FilteringSink(base: sink, selection: selection)
            // importFile falls back to copying because the mount is a different volume.
            try StagingImporter.importTree(mount, into: target, progress: progress)
        }
    }

    public func test(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> IntegrityReport {
        let r = try run(["verify", "-quiet", source.url.path], progress: progress)
        var report = IntegrityReport(archive: source.url.lastPathComponent, format: .dmg, engine: id)
        report.checks = ["hdiutil verify (image checksum)"]
        if r.status != 0 { report.issues.append(.init(entry: nil, message: r.combined.trimmingCharacters(in: .whitespacesAndNewlines), code: "damaged")) }
        return report
    }

    private func withMounted<T>(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress, _ body: (URL) throws -> T) throws -> T {
        guard options.allowMountingDiskImages else {
            throw ArchiveError.operationNotSupported(format: .dmg, operation: "mounting",
                reason: "Reading this disk image requires mounting it read-only. \(ProductInfo.name) only does that with your permission.")
        }
        let mountRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ua-mounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: mountRoot) }
        let encrypted = (try? run(["isencrypted", source.url.path], progress: nil))?.stdout.contains("encrypted: YES") ?? false
        var args = ["attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-mountrandom", mountRoot.path, "-plist"]
        var password: Secret?
        if encrypted {
            guard let pw = options.passwordProvider?.password(for: source.url, reason: .required) else {
                throw ArchiveError.passwordRequired(archive: source.url.path)
            }
            password = pw
            args.append("-stdinpass")
        }
        args.append(source.url.path)
        let r = try run(args, password: password, progress: progress)
        guard r.status == 0 else {
            if encrypted, r.combined.contains("Authentication error") { throw ArchiveError.incorrectPassword(archive: source.url.path) }
            throw ArchiveError.externalTool(tool: "hdiutil", exitCode: r.status, message: r.combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Parse mount points from the plist output.
        var mounts: [URL] = []
        if let data = r.stdout.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let ents = plist["system-entities"] as? [[String: Any]] {
            mounts = ents.compactMap { $0["mount-point"] as? String }.map { URL(fileURLWithPath: $0) }
        }
        defer { for m in mounts { _ = try? run(["detach", m.path, "-force"], progress: nil) } }
        guard let first = mounts.first else { throw ArchiveError.damaged(details: "The disk image has no mountable volume.") }
        return try body(first)
    }

    public func create(_ request: CreateRequest, progress: OperationProgress) throws -> CreateResult {
        let s = request.settings
        let parent = request.output.deletingLastPathComponent()
        let src = parent.appendingPathComponent(".ua-dmg-\(TempToken.make())")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: src) }
        for item in request.items {
            let dest = src.appendingPathComponent(item.archivePath)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch item.type {
            case .directory: try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            case .symlink: try FileManager.default.createSymbolicLink(atPath: dest.path, withDestinationPath: item.linkTarget ?? "")
            default: do { try FileManager.default.linkItem(at: item.url, to: dest) } catch { try FileManager.default.copyItem(at: item.url, to: dest) }
            }
        }
        let format: String
        switch s.method {
        case .store?: format = "UDRO"
        case .bzip2?: format = "UDBZ"
        case .lzfse?: format = "ULFO"
        case .lzma?: format = "ULMO"
        default: format = "UDZO"
        }
        let temp = parent.appendingPathComponent(".\(request.output.deletingPathExtension().lastPathComponent).ua-\(TempToken.make()).dmg")
        var args = ["create", "-quiet", "-fs", "APFS", "-format", format, "-volname", request.output.deletingPathExtension().lastPathComponent,
                    "-srcfolder", src.path]
        if s.encryption != nil {
            guard request.password != nil else { throw ArchiveError.invalidArgument("A password is required for an encrypted disk image.") }
            args += ["-encryption", "AES-256", "-stdinpass"]
        }
        args.append(temp.path)
        progress.setPhase("Creating disk image")
        let r = try run(args, password: s.encryption != nil ? request.password : nil, progress: progress)
        guard r.status == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw ArchiveError.externalTool(tool: "hdiutil", exitCode: r.status, message: r.combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !FileManager.default.fileExists(atPath: request.output.path) else {
            try? FileManager.default.removeItem(at: temp)
            throw ArchiveError.destinationExists(path: request.output.path)
        }
        try FileManager.default.moveItem(at: temp, to: request.output)
        let size = (try? FileManager.default.attributesOfItem(atPath: request.output.path)[.size] as? UInt64) ?? 0
        return CreateResult(outputs: [request.output], inputBytes: request.items.reduce(0) { $0 + $1.size }, outputBytes: size,
                            entryCount: request.items.count, warnings: [], engine: id)
    }
}
#endif
