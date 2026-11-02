import Foundation
import ArchiveCore
import ArchiveEngines

public struct CompressRequest: Sendable {
    public var items: [URL]
    /// Defaults to the folder containing the first item.
    public var destinationDirectory: URL?
    /// Archive name without extension. Defaults to the preset's pattern or the item's name.
    public var archiveName: String?
    public var settings: CompressionSettings
    public var password: Secret?
    public var namePattern: String?
    public var verifyAfterCreation: Bool
    /// Move the source items to the Trash after the archive verified. Off by default.
    public var trashSourcesAfterVerification: Bool

    public init(items: [URL], destinationDirectory: URL? = nil, archiveName: String? = nil, settings: CompressionSettings,
                password: Secret? = nil, namePattern: String? = nil, verifyAfterCreation: Bool = false, trashSourcesAfterVerification: Bool = false) {
        self.items = items
        self.destinationDirectory = destinationDirectory
        self.archiveName = archiveName
        self.settings = settings
        self.password = password
        self.namePattern = namePattern
        self.verifyAfterCreation = verifyAfterCreation
        self.trashSourcesAfterVerification = trashSourcesAfterVerification
    }
}

public struct CreatedArchive: Sendable {
    public var outputs: [URL]
    public var inputBytes: UInt64
    public var outputBytes: UInt64
    public var entryCount: Int
    public var engine: EngineID
    public var verification: IntegrityReport?
    public var warnings: [String]

    /// Measured space savings (not an estimate).
    public var savings: Double? {
        inputBytes > 0 ? 1 - Double(outputBytes) / Double(inputBytes) : nil
    }
}

public struct CompressionOutcome: Sendable {
    public var archives: [CreatedArchive]
    public var excluded: [(path: String, reason: String)]
    public var unreadable: [String]
    public var warnings: [String]
    public var trashedSources: [URL]
}

extension ArchiveService {
    /// File extension used for new archives of `format`.
    public static func fileExtension(for format: FormatID) -> String {
        switch format {
        case .unixCompress: return "Z"
        case .tarCompress: return "tar.Z"
        default: return FormatCatalog.descriptor(for: format)?.primaryExtension ?? format.rawValue
        }
    }

    /// Splits the selection into archive groups according to the grouping setting.
    static func groups(_ items: [URL], grouping: ArchiveGrouping) -> [[URL]] {
        switch grouping {
        case .single: return [items]
        case .perItem: return items.map { [$0] }
        case .perFolder:
            var folders: [[URL]] = []
            var loose: [URL] = []
            for u in items {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { folders.append([u]) } else { loose.append(u) }
            }
            return folders + (loose.isEmpty ? [] : [loose])
        }
    }

    public func compress(_ request: CompressRequest, progress: OperationProgress = OperationProgress()) throws -> CompressionOutcome {
        guard !request.items.isEmpty else { throw ArchiveError.invalidArgument("Select at least one file or folder to compress.") }
        var settings = request.settings
        if settings.threads == nil { settings.threads = SystemProfile.current().threads(for: performanceMode) }
        var warnings: [String] = []
        if let enc = settings.encryption {
            guard let pw = request.password, !pw.isEmpty else { throw ArchiveError.invalidArgument("Enter a password to encrypt the archive.") }
            if enc.method == .zipCrypto {
                warnings.append("ZipCrypto is a legacy method that can be broken. Use AES-256 unless the recipient's software requires ZipCrypto.")
            }
            if enc.encryptFilenames, !creationOptions(for: settings.format).canEncryptFilenames {
                warnings.append("\(FormatCatalog.descriptor(for: settings.format)?.name ?? settings.format.rawValue) cannot hide file names; only file contents are encrypted.")
            }
        }
        let engine = try creationEngine(format: settings.format, settings: settings)
        let destDir = request.destinationDirectory ?? request.items[0].deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: destDir.path) else { throw ArchiveError.permissionDenied(path: destDir.path) }
        Leftovers.sweep(destDir)

        var outcome = CompressionOutcome(archives: [], excluded: [], unreadable: [], warnings: warnings, trashedSources: [])
        let groups = Self.groups(request.items, grouping: settings.grouping)
        progress.setPhase("Preparing")
        var collections: [(group: [URL], collection: SourceCollection)] = []
        for g in groups {
            var c = try SourceCollector.collect(g, settings: settings, progress: progress)
            if !c.notDownloaded.isEmpty {
                try CloudFiles.ensureDownloaded(c.notDownloaded, progress: progress)
                c = try SourceCollector.collect(g, settings: settings, progress: progress)
            }
            collections.append((g, c))
            outcome.excluded += c.excluded
            outcome.unreadable += c.unreadable
        }
        if !outcome.unreadable.isEmpty {
            throw ArchiveError.permissionDenied(path: outcome.unreadable[0])
        }
        let grandTotal = collections.reduce(UInt64(0)) { $0 + $1.collection.totalBytes }
        progress.setTotal(bytes: grandTotal, items: collections.reduce(0) { $0 + $1.collection.items.count })

        for (group, collection) in collections {
            try progress.checkCancelled()
            if FormatCatalog.descriptor(for: settings.format)?.kind == .compressionStream,
               collection.items.count != 1 || collection.items.first?.type != .file {
                let tarVariant = FormatCatalog.all.first { $0.kind == .compressedArchive && $0.layers.first == settings.format }
                throw ArchiveError.operationNotSupported(format: settings.format, operation: "folders or several files",
                    reason: "A \(FormatCatalog.descriptor(for: settings.format)?.name ?? "") stream holds a single file." + (tarVariant.map { " Use \($0.name) (.\($0.primaryExtension)) instead." } ?? ""))
            }
            let name: String = {
                if let n = request.archiveName, !n.isEmpty, groups.count == 1 { return n }
                if let pattern = request.namePattern {
                    let preset = Preset(id: "tmp", name: "", summary: "", settings: settings, namePattern: pattern)
                    return preset.archiveBaseName(for: group)
                }
                if group.count == 1 {
                    let u = group[0]
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                    // Streams keep the full file name ("notes.txt.gz"); containers drop the extension of a single file.
                    if isDir.boolValue || FormatCatalog.descriptor(for: settings.format)?.kind == .compressionStream { return u.lastPathComponent }
                    let stem = u.deletingPathExtension().lastPathComponent
                    return stem.isEmpty ? u.lastPathComponent : stem
                }
                return request.archiveName ?? "Archive"
            }()
            let output = Self.uniqueURL(in: destDir, name: name + "." + Self.fileExtension(for: settings.format),
                                        alsoTaken: settings.splitVolumeSize == nil ? [] : [".001"])
            let sub = OperationProgress()
            sub.throttle = 0.25
            let base = progress.snapshot.processedBytes
            let baseOut = progress.snapshot.outputBytes
            sub.observe { s in
                progress.setProcessed(base + s.processedBytes)
                progress.setOutput(baseOut + s.outputBytes)
                progress.setCurrentItem(s.currentItem)
            }
            progress.onCancel { sub.cancel() }
            progress.onPauseChange { $0 ? sub.pause() : sub.resume() }
            progress.setPhase("Compressing")
            let result = try engine.create(CreateRequest(output: output, format: settings.format, items: collection.items,
                                                         settings: settings, password: settings.encryption != nil ? request.password : nil),
                                           progress: sub)
            var created = CreatedArchive(outputs: result.outputs, inputBytes: result.inputBytes, outputBytes: result.outputBytes,
                                         entryCount: result.entryCount, engine: result.engine, verification: nil, warnings: result.warnings)
            if request.verifyAfterCreation, let first = result.outputs.first {
                progress.setPhase("Verifying")
                let opts = ReadOptions(passwordProvider: request.password.map { FixedPasswordProvider($0) })
                let report = try test(first, options: opts, progress: OperationProgress())
                created.verification = report
                if report.result != .passed {
                    throw ArchiveError.verificationFailed(details: report.issues.map(\.message).joined(separator: "; "))
                }
            }
            outcome.archives.append(created)
        }

        if request.trashSourcesAfterVerification {
            if request.verifyAfterCreation, outcome.archives.allSatisfy({ $0.verification?.result == .passed }), outcome.excluded.isEmpty {
                #if os(macOS)
                for u in request.items {
                    var out: NSURL?
                    if (try? FileManager.default.trashItem(at: u, resultingItemURL: &out)) != nil { outcome.trashedSources.append(u) }
                }
                #else
                outcome.warnings.append("Moving originals to the Trash is only available on macOS.")
                #endif
            } else {
                outcome.warnings.append("The original files were kept because the archive was not verified, or some items were excluded.")
            }
        }
        progress.flush()
        return outcome
    }
}

/// Handling of cloud-provider placeholders (iCloud Drive, Dropbox, OneDrive, Google Drive via File Provider).
public enum CloudFiles {
    /// Requests download of placeholders and waits (bounded) until their data is local.
    public static func ensureDownloaded(_ urls: [URL], timeout: TimeInterval = 600, progress: OperationProgress) throws {
        #if os(macOS)
        let fm = FileManager.default
        for u in urls { try? fm.startDownloadingUbiquitousItem(at: u) }
        progress.setPhase("Downloading from cloud storage")
        let deadline = Date().addingTimeInterval(timeout)
        var pending = urls
        while !pending.isEmpty {
            try progress.checkCancelled()
            pending = pending.filter { u in
                let v = try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                return v?.ubiquitousItemDownloadingStatus != .current
            }
            if pending.isEmpty { break }
            if Date() > deadline {
                throw ArchiveError.io(path: pending[0].path, code: 0, message: "\(pending.count) cloud file(s) did not finish downloading. Check your network connection and available disk space, then try again.")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        #endif
    }
}
