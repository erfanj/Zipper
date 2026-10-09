import Foundation
import ArchiveCore
import ArchiveEngines

/// One change to an archive's contents. Paths are archive-internal, `/`-separated.
public enum ArchiveEdit: Sendable, Equatable {
    case add(files: [URL], toFolder: String)
    case delete(paths: [String])
    case rename(path: String, newName: String)
    case move(path: String, toFolder: String)
    case createFolder(path: String)
    case replace(path: String, with: URL)
}

public struct ModifyRequest: Sendable {
    public var archive: URL
    public var edits: [ArchiveEdit]
    public var readOptions: ReadOptions
    /// Password used to re-encrypt an encrypted archive (normally the same one used to open it).
    public var password: Secret?
    /// Signed packages (APK, IPA, JAR, PKG…) are refused unless this is set; their signature becomes invalid.
    public var allowSignedPackages: Bool

    public init(archive: URL, edits: [ArchiveEdit], readOptions: ReadOptions = ReadOptions(), password: Secret? = nil, allowSignedPackages: Bool = false) {
        self.archive = archive
        self.edits = edits
        self.readOptions = readOptions
        self.password = password
        self.allowSignedPackages = allowSignedPackages
    }
}

public struct ModifyOutcome: Sendable {
    public var archive: URL
    public var strategy: String
    public var verification: IntegrityReport
    public var entryCount: Int
    public var warnings: [String]
}

extension ArchiveService {
    static let signedPackages: Set<FormatID> = [.apk, .aab, .ipa, .jar, .war, .ear, .appx, .msix, .pkg, .xpi, .vsix]

    /// Applies edits transactionally: the result is built in a temporary file next to the original,
    /// verified (full decode + expected file list), and only then atomically swapped in. If anything
    /// fails, the original is untouched.
    public func modify(_ request: ModifyRequest, progress: OperationProgress = OperationProgress()) throws -> ModifyOutcome {
        let fm = FileManager.default
        let opened = try open(request.archive, options: request.readOptions, progress: OperationProgress())
        let format = opened.detection.format
        var warnings: [String] = []
        if opened.detection.multipart != nil {
            throw ArchiveError.notEditable(format: format, reason: "Multi-volume archives can't be edited in place.")
        }
        if Self.signedPackages.contains(format) {
            guard request.allowSignedPackages else {
                throw ArchiveError.notEditable(format: format, reason: "Changing a signed package invalidates its signature, so it would no longer install or run.")
            }
            warnings.append("The package's signature is no longer valid.")
        }
        // Editable only if some engine can both read and write the format.
        let canWrite = !registry.candidates(for: format, EngineRequirements(operations: .create)).isEmpty
        guard canWrite, FormatCatalog.descriptor(for: format)?.kind != .compressionStream else {
            throw ArchiveError.notEditable(format: format, reason: format == .rar ? "RAR archives can only be modified with the licensed RAR program." : "No installed engine can write this format.")
        }

        // Expected file set after the edits (used to verify the result).
        var expected = Set(opened.listing.entries.filter { $0.type != .directory }.map { $0.normalizedPath })
        for edit in request.edits {
            switch edit {
            case .delete(let paths):
                for p in paths.map(ArchivePath.normalizeForDisplay) { expected = expected.filter { $0 != p && !$0.hasPrefix(p + "/") } }
            case .rename(let path, let newName):
                let p = ArchivePath.normalizeForDisplay(path)
                let parent = (p as NSString).deletingLastPathComponent
                let np = ArchivePath.join(parent, newName)
                expected = Set(expected.map { $0 == p ? np : ($0.hasPrefix(p + "/") ? np + $0.dropFirst(p.count) : $0) })
            case .move(let path, let folder):
                let p = ArchivePath.normalizeForDisplay(path)
                let np = ArchivePath.join(ArchivePath.normalizeForDisplay(folder), (p as NSString).lastPathComponent)
                expected = Set(expected.map { $0 == p ? np : ($0.hasPrefix(p + "/") ? np + $0.dropFirst(p.count) : $0) })
            case .add(let files, let folder):
                for f in files {
                    let base = ArchivePath.join(ArchivePath.normalizeForDisplay(folder), f.lastPathComponent)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: f.path, isDirectory: &isDir), isDir.boolValue {
                        let en = fm.enumerator(atPath: f.path)
                        while let rel = en?.nextObject() as? String {
                            var d: ObjCBool = false
                            if fm.fileExists(atPath: f.appendingPathComponent(rel).path, isDirectory: &d), !d.boolValue { expected.insert(base + "/" + rel) }
                        }
                    } else { expected.insert(base) }
                }
            case .replace(let path, _):
                expected.insert(ArchivePath.normalizeForDisplay(path))
            case .createFolder:
                break
            }
        }

        // Settings for the rebuilt archive, derived from the original.
        let encrypted = opened.listing.properties.hasEncryptedEntries == true
        var settings = CompressionSettings(format: format, level: 6)
        let methods = Set(opened.listing.entries.compactMap { $0.method?.lowercased() })
        if !methods.isEmpty, methods.allSatisfy({ $0.contains("store") || $0.contains("copy") }) { settings.method = .store; settings.level = 0 }
        if format == .sevenZip { settings.solid = opened.listing.properties.isSolid == false ? .off : .on }
        if encrypted {
            guard let pw = request.password ?? request.readOptions.passwordProvider?.password(for: request.archive, reason: .required) else {
                throw ArchiveError.passwordRequired(archive: request.archive.path)
            }
            let container = FormatCatalog.descriptor(for: format)?.effectiveContainer ?? format
            switch container {
            case .zip:
                settings.encryption = EncryptionSettings(method: .zipAES256)
                if opened.listing.entries.contains(where: { ($0.method ?? "").contains("ZipCrypto") }) {
                    warnings.append("Entries are re-encrypted with AES-256 (the original used legacy ZipCrypto).")
                }
            case .sevenZip:
                settings.encryption = EncryptionSettings(method: .sevenZipAES256, encryptFilenames: opened.listing.properties.hasEncryptedHeaders == true)
            case .appleEncryptedArchive:
                settings.encryption = EncryptionSettings(method: .appleEncryptedArchive, encryptFilenames: true)
            default:
                throw ArchiveError.notEditable(format: format, reason: "Encrypted archives of this type can't be rebuilt.")
            }
            return try rebuild(request, opened: opened, settings: settings, password: pw, expected: expected, warnings: warnings, progress: progress)
        }
        return try rebuild(request, opened: opened, settings: settings, password: nil, expected: expected, warnings: warnings, progress: progress)
    }

    private func rebuild(_ request: ModifyRequest, opened: OpenedArchive, settings: CompressionSettings, password: Secret?,
                         expected: Set<String>, warnings: [String], progress: OperationProgress) throws -> ModifyOutcome {
        let fm = FileManager.default
        let dir = request.archive.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: dir.path) else { throw ArchiveError.permissionDenied(path: dir.path) }
        let work = dir.appendingPathComponent(".ua-modify-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let tree = work.appendingPathComponent("tree", isDirectory: true)
        let out = work.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: tree, withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        // 1. Extract everything securely.
        progress.setPhase("Reading archive")
        let sink = try SafeExtractionSink(destination: tree, options: ExtractionOptions(conflictPolicy: .keepBoth, skipAppleDoubleArtifacts: false,
                                                                                        archiveSize: opened.source.totalSize), progress: progress)
        var notes: [String] = []
        _ = try withEngines(for: opened.detection.format, EngineRequirements(operations: .extract), notes: &notes) {
            try $0.extract(opened.source, selection: .all, into: sink, options: request.readOptions, progress: progress)
        }
        try sink.finish()
        if !sink.report.blocked.isEmpty {
            throw ArchiveError.notEditable(format: opened.detection.format, reason: "The archive contains entries with unsafe paths that would be lost by rebuilding it.")
        }

        // 2. Apply edits to the extracted tree (all paths validated against the tree root).
        func local(_ archivePath: String) throws -> URL {
            let comps = try SafePath.components(of: archivePath)
            return comps.reduce(tree) { $0.appendingPathComponent($1) }
        }
        for edit in request.edits {
            switch edit {
            case .delete(let paths):
                for p in paths {
                    let u = try local(p)
                    guard fm.fileExists(atPath: u.path) || (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil else {
                        throw ArchiveError.invalidArgument("“\(p)” is not in the archive.")
                    }
                    try fm.removeItem(at: u)
                }
            case .rename(let path, let newName):
                guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".." else {
                    throw ArchiveError.invalidArgument("“\(newName)” is not a valid name.")
                }
                let src = try local(path)
                let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
                guard !fm.fileExists(atPath: dst.path) else { throw ArchiveError.destinationExists(path: newName) }
                try fm.moveItem(at: src, to: dst)
            case .move(let path, let folder):
                let src = try local(path)
                let dstDir = folder.isEmpty ? tree : try local(folder)
                try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
                let dst = dstDir.appendingPathComponent(src.lastPathComponent)
                guard !fm.fileExists(atPath: dst.path) else { throw ArchiveError.destinationExists(path: dst.lastPathComponent) }
                try fm.moveItem(at: src, to: dst)
            case .createFolder(let path):
                try fm.createDirectory(at: try local(path), withIntermediateDirectories: true)
            case .add(let files, let folder):
                let dstDir = folder.isEmpty ? tree : try local(folder)
                try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
                for f in files {
                    let dst = dstDir.appendingPathComponent(f.lastPathComponent)
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.copyItem(at: f, to: dst)
                }
            case .replace(let path, let file):
                let dst = try local(path)
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file, to: dst)
            }
        }

        // 3. Recompress to a temporary archive.
        progress.setPhase("Writing archive")
        var s = settings
        s.includeRootFolder = false
        s.grouping = .single
        let items = ((try? fm.contentsOfDirectory(atPath: tree.path)) ?? []).sorted().map { tree.appendingPathComponent($0) }
        let engine = try creationEngine(format: opened.detection.format, settings: s)
        let collection = try SourceCollector.collect(items.isEmpty ? [] : items, settings: s, progress: progress)
        let tempArchive = out.appendingPathComponent(request.archive.lastPathComponent)
        _ = try engine.create(CreateRequest(output: tempArchive, format: opened.detection.format, items: collection.items, settings: s, password: password), progress: progress)

        // 4. Verify: full decode, and exactly the expected files.
        progress.setPhase("Verifying")
        let pwOpts = ReadOptions(passwordProvider: password.map { FixedPasswordProvider($0) })
        let report = try test(tempArchive, options: pwOpts, progress: OperationProgress())
        guard report.result == .passed else { throw ArchiveError.verificationFailed(details: report.issues.map(\.message).joined(separator: "; ")) }
        let newListing = try open(tempArchive, options: pwOpts, progress: OperationProgress()).listing
        let actual = Set(newListing.entries.filter { $0.type != .directory }.map { $0.normalizedPath })
        if actual != expected {
            let missing = expected.subtracting(actual).sorted().prefix(5)
            let extra = actual.subtracting(expected).sorted().prefix(5)
            throw ArchiveError.verificationFailed(details: "The updated archive does not contain exactly the expected files (missing: \(missing.joined(separator: ", ")); unexpected: \(extra.joined(separator: ", "))). The original was not changed.")
        }

        // 5. Atomically swap it in (the original survives any failure up to this point).
        _ = try fm.replaceItemAt(request.archive, withItemAt: tempArchive, backupItemName: nil, options: [])
        return ModifyOutcome(archive: request.archive, strategy: "rebuilt via verified temporary copy (\(engine.descriptor.name))",
                             verification: report, entryCount: newListing.entries.count, warnings: warnings)
    }
}

/// Supports "Edit in external app": an entry is extracted to a private temporary file; when the
/// file changes on disk the caller can ask the user and apply `.replace` to the archive.
public final class ExternalEditSession: @unchecked Sendable {
    public let archive: URL
    public let entryPath: String
    public let fileURL: URL
    private var originalDigest: String
    private let directory: URL

    public init(service: ArchiveService, archive: URL, entryPath: String, readOptions: ReadOptions = ReadOptions()) throws {
        self.archive = archive
        self.entryPath = ArchivePath.normalizeForDisplay(entryPath)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ua-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let outcome = try service.extract(ExtractRequest(archive: archive, destination: directory, mode: .here,
                                                         selection: .paths([self.entryPath]), readOptions: readOptions))
        guard let rel = outcome.report.writtenFiles.first else { throw ArchiveError.invalidArgument("“\(entryPath)” is not a file in the archive.") }
        fileURL = directory.appendingPathComponent(rel)
        originalDigest = try StreamingHasher.hashFile(at: fileURL, algorithm: .sha256)
    }

    /// Whether the temporary copy differs from what was extracted.
    public func hasChanges() -> Bool {
        guard let d = try? StreamingHasher.hashFile(at: fileURL, algorithm: .sha256) else { return false }
        return d != originalDigest
    }

    /// Writes the edited file back into the archive (transactionally).
    public func commit(using service: ArchiveService, readOptions: ReadOptions = ReadOptions(), password: Secret? = nil) throws -> ModifyOutcome {
        let outcome = try service.modify(ModifyRequest(archive: archive, edits: [.replace(path: entryPath, with: fileURL)],
                                                       readOptions: readOptions, password: password))
        originalDigest = try StreamingHasher.hashFile(at: fileURL, algorithm: .sha256)
        return outcome
    }

    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { discard() }
}
