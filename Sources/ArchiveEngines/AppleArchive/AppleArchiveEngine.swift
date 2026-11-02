import Foundation
import ArchiveCore

#if canImport(AppleArchive)
import AppleArchive
import System

/// Apple Archive (.aar) and Apple Encrypted Archive (.aea) using Apple's AppleArchive framework.
///
/// NOTE: this file only compiles on macOS. It was written against the documented AppleArchive
/// Swift API and must be built and tested on a Mac (see Documentation/Testing.md).
@available(macOS 13.0, *)
public final class AppleArchiveEngine: ArchiveEngine, @unchecked Sendable {
    public let descriptor = EngineDescriptor(
        id: .appleArchive, name: "Apple Archive", implementation: "AppleArchive.framework (system)",
        version: ProcessInfo.processInfo.operatingSystemVersionString, minimumVersion: "macOS 13",
        license: "Apple system framework", isAvailable: true,
        isolation: "In-process system framework. Extracts into a private staging folder that is validated and imported by the safe sink.")

    public init() {}

    public var supportedFormats: [FormatID] { [.appleArchive, .appleEncryptedArchive] }

    public func support(for format: FormatID) -> EngineFormatSupport? {
        switch format {
        case .appleArchive:
            return EngineFormatSupport(format: format, operations: [.inspect, .extract, .test, .create, .preserveMetadata, .multithreaded, .streamingRead, .streamingWrite, .selectiveExtract],
                                       compressionMethods: [.lzfse, .lzma, .lz4, .zlib, .lzbitmap, .store],
                                       memory: "Bounded; the framework streams blocks.", threading: "Framework-managed worker threads.",
                                       limitations: ["Readable on macOS 11+ and iOS 14+ only."])
        case .appleEncryptedArchive:
            return EngineFormatSupport(format: format, operations: [.inspect, .extract, .test, .create, .encrypt, .decrypt, .encryptFilenames, .preserveMetadata, .multithreaded],
                                       compressionMethods: [.lzfse, .lzma, .lz4, .zlib, .lzbitmap, .store],
                                       encryptionMethods: [.appleEncryptedArchive], decryptionMethods: [.appleEncryptedArchive],
                                       limitations: ["Readable on macOS 13+ only.", "Password profile: HKDF-SHA256, AES-CTR, HMAC, scrypt key derivation."])
        default: return nil
        }
    }

    static func compression(_ m: CompressionMethod?) -> ArchiveCompression {
        switch m {
        case .lzma?: return .lzma
        case .lz4?: return .lz4
        case .zlib?, .deflate?: return .zlib
        case .lzbitmap?: return .lzbitmap
        case .store?: return .none
        default: return .lzfse
        }
    }

    // MARK: Streams

    /// Opens the payload stream: plain, or decrypted with the provider's password.
    private func openInput(_ source: ArchiveSource, options: ReadOptions) throws -> (ArchiveByteStream, [ArchiveByteStream]) {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(source.url.path), mode: .readOnly, options: [],
                                                      permissions: FilePermissions(rawValue: 0o644)) else {
            throw ArchiveError.fileNotFound(path: source.url.path)
        }
        var chain = [file]
        var current = file
        if source.format == .appleEncryptedArchive {
            guard let context = ArchiveEncryptionContext(from: file) else {
                throw ArchiveError.damaged(details: "The Apple Encrypted Archive header could not be read.")
            }
            var reason = PasswordRequestReason.required
            var opened: ArchiveByteStream?
            for _ in 0..<5 {
                guard let pw = options.passwordProvider?.password(for: source.url, reason: reason) else {
                    throw reason == .required ? ArchiveError.passwordRequired(archive: source.url.path) : ArchiveError.incorrectPassword(archive: source.url.path)
                }
                do {
                    try context.setPassword(pw.unsafeStringValue)
                    if let d = ArchiveByteStream.decryptionStream(readingFrom: file, encryptionContext: context) {
                        opened = d
                        break
                    }
                } catch {}
                reason = .previousAttemptIncorrect
            }
            guard let dec = opened else { throw ArchiveError.incorrectPassword(archive: source.url.path) }
            chain.append(dec)
            current = dec
        }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: current) else {
            throw ArchiveError.damaged(details: "The archive's compression stream could not be opened.")
        }
        chain.append(decompressed)
        return (decompressed, chain)
    }

    private func close(_ chain: [ArchiveByteStream]) {
        for s in chain.reversed() { try? s.close() }
    }

    // MARK: Listing

    public func list(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> ArchiveListing {
        let (input, chain) = try openInput(source, options: options)
        defer { close(chain) }
        guard let decode = ArchiveStream.decodeStream(readingFrom: input) else {
            throw ArchiveError.damaged(details: "Not a valid Apple Archive stream.")
        }
        defer { try? decode.close() }
        var entries: [ArchiveEntry] = []
        let patKey = ArchiveHeader.FieldKey("PAT"), typKey = ArchiveHeader.FieldKey("TYP"), datKey = ArchiveHeader.FieldKey("DAT")
        let mtmKey = ArchiveHeader.FieldKey("MTM"), modKey = ArchiveHeader.FieldKey("MOD"), lnkKey = ArchiveHeader.FieldKey("LNK")
        var index = 0
        while let header = try decode.readHeader() {
            try progress.checkCancelled()
            var path = "", type = EntryType.file, size: UInt64?, mtime: Date?, perms: UInt16?, link: String?
            if case .string(_, let v)? = header.field(forKey: patKey) { path = v }
            if case .uint(_, let v)? = header.field(forKey: typKey) {
                switch UInt8(truncatingIfNeeded: v) {
                case UInt8(ascii: "D"): type = .directory
                case UInt8(ascii: "L"): type = .symlink
                case UInt8(ascii: "F"): type = .file
                default: type = .special
                }
            }
            if case .blob(_, let s, _)? = header.field(forKey: datKey) { size = s }
            if case .timespec(_, let ts)? = header.field(forKey: mtmKey) { mtime = Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9) }
            if case .uint(_, let v)? = header.field(forKey: modKey) { perms = UInt16(truncatingIfNeeded: v & 0o7777) }
            if case .string(_, let v)? = header.field(forKey: lnkKey) { link = v }
            if path.isEmpty, type == .directory { continue } // archive root
            entries.append(ArchiveEntry(index: index, path: path, type: type, uncompressedSize: type == .file ? (size ?? 0) : nil,
                                        modificationDate: mtime, permissions: perms,
                                        isEncrypted: source.format == .appleEncryptedArchive, linkTarget: link))
            index += 1
        }
        let props = ArchiveProperties(format: source.format, formatDescription: source.format == .appleEncryptedArchive ? "Apple Encrypted Archive" : "Apple Archive",
                                      archiveSize: source.totalSize, hasEncryptedEntries: source.format == .appleEncryptedArchive,
                                      hasEncryptedHeaders: source.format == .appleEncryptedArchive,
                                      encryptionMethod: source.format == .appleEncryptedArchive ? "AEA (HKDF-SHA256, AES-CTR, HMAC, scrypt)" : nil,
                                      engine: id)
        return ArchiveListing(properties: props, entries: entries)
    }

    // MARK: Extraction

    public func extract(_ source: ArchiveSource, selection: EntrySelection, into sink: ExtractionSink,
                        options: ReadOptions, progress: OperationProgress) throws {
        let destination = (sink as? SafeExtractionSink)?.destination ?? FileManager.default.temporaryDirectory
        let staging = try StagingDirectory(near: destination)
        defer { staging.remove() }
        let (input, chain) = try openInput(source, options: options)
        defer { close(chain) }
        guard let decode = ArchiveStream.decodeStream(readingFrom: input),
              let extract = ArchiveStream.extractStream(extractingTo: FilePath(staging.url.path), flags: [.ignoreOperationNotPermitted]) else {
            throw ArchiveError.damaged(details: "The archive could not be opened for extraction.")
        }
        defer { try? extract.close(); try? decode.close() }
        progress.setPhase("Extracting")
        do {
            _ = try ArchiveStream.process(readingFrom: decode, writingTo: extract)
        } catch {
            throw ArchiveError.damaged(details: "Apple Archive reported: \(error.localizedDescription)")
        }
        let target: ExtractionSink = selection == .all ? sink : FilteringSink(base: sink, selection: selection)
        try StagingImporter.importTree(staging.url, into: target, progress: progress)
    }

    // MARK: Creation

    public func create(_ request: CreateRequest, progress: OperationProgress) throws -> CreateResult {
        let settings = request.settings
        // Mirror the selection as a tree of hard links so filters and archive paths are honoured
        // exactly, without copying file data.
        let mirrorParent = request.output.deletingLastPathComponent()
        let mirror = mirrorParent.appendingPathComponent(".ua-aa-\(TempToken.make())")
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: mirror) }
        for item in request.items {
            let dest = mirror.appendingPathComponent(item.archivePath)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch item.type {
            case .directory:
                try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            case .symlink:
                try FileManager.default.createSymbolicLink(atPath: dest.path, withDestinationPath: item.linkTarget ?? "")
            default:
                do { try FileManager.default.linkItem(at: item.url, to: dest) } catch { try FileManager.default.copyItem(at: item.url, to: dest) }
            }
        }
        for item in request.items where item.type == .directory {
            if let d = item.modificationDate {
                try? FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: mirror.appendingPathComponent(item.archivePath).path)
            }
        }

        let temp = mirrorParent.appendingPathComponent(".\(request.output.lastPathComponent).ua-\(TempToken.make())")
        guard let file = ArchiveByteStream.fileStream(path: FilePath(temp.path), mode: .writeOnly, options: [.create, .truncate],
                                                      permissions: FilePermissions(rawValue: 0o644)) else {
            throw ArchiveError.permissionDenied(path: mirrorParent.path)
        }
        var chain: [ArchiveByteStream] = [file]
        var success = false
        defer {
            if !success { close(chain); try? FileManager.default.removeItem(at: temp) }
        }
        var top: ArchiveByteStream
        if request.format == .appleEncryptedArchive {
            guard let pw = request.password else { throw ArchiveError.invalidArgument("A password is required for Apple Encrypted Archive.") }
            let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none,
                                                   compressionAlgorithm: Self.compression(settings.method))
            try context.setPassword(pw.unsafeStringValue)
            guard let enc = ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context) else {
                throw ArchiveError.internalError("Could not create the encryption stream.")
            }
            chain.append(enc)
            top = enc
        } else {
            guard let comp = ArchiveByteStream.compressionStream(using: Self.compression(settings.method), writingTo: file) else {
                throw ArchiveError.internalError("Could not create the compression stream.")
            }
            chain.append(comp)
            top = comp
        }
        guard let encode = ArchiveStream.encodeStream(writingTo: top) else { throw ArchiveError.internalError("Could not create the encoder.") }
        let keys = settings.metadata == .macPreservation
            ? "TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM,XAT,ACL"
            : "TYP,PAT,LNK,DAT,MOD,MTM"
        guard let keySet = ArchiveHeader.FieldKeySet(keys) else { throw ArchiveError.internalError("Invalid key set") }
        progress.setPhase("Compressing")
        do {
            try encode.writeDirectoryContents(archiveFrom: FilePath(mirror.path), keySet: keySet)
            try encode.close()
        } catch {
            throw ArchiveError.io(path: request.output.path, code: 0, message: error.localizedDescription)
        }
        close(chain)
        chain = []
        guard !FileManager.default.fileExists(atPath: request.output.path) else {
            try? FileManager.default.removeItem(at: temp)
            throw ArchiveError.destinationExists(path: request.output.path)
        }
        try FileManager.default.moveItem(at: temp, to: request.output)
        success = true
        let size = (try? FileManager.default.attributesOfItem(atPath: request.output.path)[.size] as? UInt64) ?? 0
        progress.setOutput(size)
        return CreateResult(outputs: [request.output], inputBytes: request.items.reduce(0) { $0 + $1.size }, outputBytes: size,
                            entryCount: request.items.count, warnings: [], engine: id)
    }
}
#endif
