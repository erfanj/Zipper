import Foundation
import ArchiveCore
import ArchiveEngines

// MARK: - Generic split / join

/// Byte-level splitting of any file into numbered parts (name.001, name.002…). This is distinct
/// from native multipart archives: the parts must be joined before the file can be used (7-Zip and
/// Zipper can also open split .7z/.zip sets directly).
public enum FileSplitter {
    public struct SplitResult: Sendable {
        public var parts: [URL]
        public var manifest: URL?
        public var sha256: String
    }

    public static let presets: [(String, UInt64)] = [
        ("100 MB", 100_000_000), ("650 MB (CD)", 650_000_000), ("700 MB (CD)", 700_000_000), ("1 GB", 1_000_000_000),
        ("2 GB", 2_000_000_000), ("4 GB (FAT32)", 4_294_967_295), ("4.7 GB (DVD)", 4_700_000_000), ("8.5 GB (DVD DL)", 8_500_000_000),
        ("25 GB (Blu-ray)", 25_000_000_000),
    ]

    /// Parses sizes like "100M", "1.5 GB", "650MB", "4096K", "1T" (decimal units; "MiB"/"GiB" binary).
    public static func parseSize(_ s: String) -> UInt64? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: " ", with: "")
        let units: [(String, Double)] = [("TIB", 1_099_511_627_776), ("GIB", 1_073_741_824), ("MIB", 1_048_576), ("KIB", 1024),
                                         ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("T", 1e12), ("G", 1e9), ("M", 1e6), ("K", 1e3), ("B", 1)]
        for (u, m) in units where t.hasSuffix(u) {
            guard let v = Double(t.dropLast(u.count)), v > 0 else { return nil }
            return UInt64(v * m)
        }
        return UInt64(t)
    }

    public static func split(_ file: URL, partSize: UInt64, into dir: URL? = nil, writeManifest: Bool = true,
                             progress: OperationProgress = OperationProgress()) throws -> SplitResult {
        guard partSize >= 1_000 else { throw ArchiveError.invalidArgument("Parts must be at least 1 KB.") }
        let input = try SafeFileIO.openForReading(file) {
            ArchiveError.invalidArgument("“\(($0 as NSString).lastPathComponent)” is a folder. Compress it first, then split the archive.")
        }
        defer { try? input.close() }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0
        let outDir = dir ?? file.deletingLastPathComponent()
        let count = max(1, Int((size + partSize - 1) / partSize))
        let digits = max(3, String(count).count)
        progress.setTotal(bytes: size, items: count)
        progress.setPhase("Splitting")
        let whole = StreamingHasher(.sha256)
        var parts: [URL] = []
        var partHashes: [String] = []
        do {
            for i in 1...count {
                let name = file.lastPathComponent + "." + String(format: "%0\(digits)d", i)
                let url = outDir.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: url.path) else { throw ArchiveError.destinationExists(path: url.path) }
                FileManager.default.createFile(atPath: url.path, contents: nil)
                guard let out = FileHandle(forWritingAtPath: url.path) else { throw ArchiveError.permissionDenied(path: url.path) }
                parts.append(url)
                let ph = StreamingHasher(.sha256)
                var remaining = partSize
                while remaining > 0 {
                    try progress.checkCancelled()
                    let chunk = try input.readChunk(upTo: Int(min(remaining, 4 << 20)), path: file.path)
                    if chunk.isEmpty { break }
                    try out.writeChunk(chunk, path: url.path)
                    whole.update(chunk)
                    ph.update(chunk)
                    remaining -= UInt64(chunk.count)
                    progress.add(processed: UInt64(chunk.count))
                }
                try out.close()
                partHashes.append(ph.finalizeHex())
                progress.itemCompleted()
            }
        } catch {
            parts.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        let digest = whole.finalizeHex()
        var manifest: URL?
        if writeManifest {
            let m = outDir.appendingPathComponent(file.lastPathComponent + ".sha256")
            var lines = ["\(digest)  \(file.lastPathComponent)"]
            for (u, h) in zip(parts, partHashes) { lines.append("\(h)  \(u.lastPathComponent)") }
            try (lines.joined(separator: "\n") + "\n").write(to: m, atomically: true, encoding: .utf8)
            manifest = m
        }
        return SplitResult(parts: parts, manifest: manifest, sha256: digest)
    }

    public struct JoinResult: Sendable {
        public var output: URL
        public var sha256: String
        /// nil when no manifest was found.
        public var matchedManifest: Bool?
    }

    /// Joins name.001… into name, verifying against name.sha256 when present. Refuses gaps.
    public static func join(firstPart: URL, to output: URL? = nil, progress: OperationProgress = OperationProgress()) throws -> JoinResult {
        guard let set = MultipartDetector.detect(firstPart), set.style == .numbered else {
            throw ArchiveError.invalidArgument("Select the first part of a numbered set (name.001).")
        }
        guard set.isComplete else { throw ArchiveError.missingVolume(expected: set.missing) }
        let out = output ?? ArchiveService.uniqueURL(in: set.directory, name: set.baseName)
        let temp = out.deletingLastPathComponent().appendingPathComponent(".\(out.lastPathComponent).ua-partial")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: temp.path) else { throw ArchiveError.permissionDenied(path: temp.path) }
        let hasher = StreamingHasher(.sha256)
        let total = set.volumes.reduce(UInt64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? UInt64) ?? 0) }
        progress.setTotal(bytes: total, items: set.volumes.count)
        progress.setPhase("Joining")
        do {
            for v in set.volumes {
                guard let input = FileHandle(forReadingAtPath: v.path) else { throw ArchiveError.fileNotFound(path: v.path) }
                defer { try? input.close() }
                while true {
                    try progress.checkCancelled()
                    let chunk = try input.readChunk(upTo: 4 << 20, path: v.path)
                    if chunk.isEmpty { break }
                    try fh.writeChunk(chunk, path: temp.path)
                    hasher.update(chunk)
                    progress.add(processed: UInt64(chunk.count))
                }
            }
            try fh.close()
        } catch {
            try? fh.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        let digest = hasher.finalizeHex()
        var matched: Bool?
        let manifest = set.directory.appendingPathComponent(set.baseName + ".sha256")
        if let text = try? String(contentsOf: manifest, encoding: .utf8),
           let entry = ChecksumManifest.parse(text).first(where: { $0.path == set.baseName }) {
            matched = entry.digest.lowercased() == digest
            if matched == false {
                try? FileManager.default.removeItem(at: temp)
                throw ArchiveError.verificationFailed(details: "The joined file's SHA-256 doesn't match \(manifest.lastPathComponent). A part is damaged.")
            }
        }
        guard !FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: temp)
            throw ArchiveError.destinationExists(path: out.path)
        }
        try FileManager.default.moveItem(at: temp, to: out)
        return JoinResult(output: out, sha256: digest, matchedManifest: matched)
    }
}

// MARK: - Checksums

public enum ChecksumManifest {
    public struct Line: Sendable, Hashable {
        public var algorithm: HashAlgorithm?
        public var digest: String
        public var path: String
    }

    /// Parses GNU (`hex  path`, `hex *path`) and BSD (`SHA256 (path) = hex`) styles, and SFV (`path crc`).
    public static func parse(_ text: String) -> [Line] {
        var out: [Line] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if let open = line.range(of: " ("), let close = line.range(of: ") = ", options: .backwards) {
                let alg = String(line[..<open.lowerBound]).lowercased().replacingOccurrences(of: "-", with: "")
                out.append(Line(algorithm: HashAlgorithm(rawValue: alg), digest: String(line[close.upperBound...]), path: String(line[open.upperBound..<close.lowerBound])))
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let first = String(parts[0])
            var rest = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if first.allSatisfy(\.isHexDigit), [8, 32, 40, 64, 96, 128].contains(first.count) {
                if rest.hasPrefix("*") { rest.removeFirst() }
                let alg = HashAlgorithm.allCases.first { $0.hexLength == first.count && $0 != .crc32 } ?? (first.count == 8 ? .crc32 : nil)
                out.append(Line(algorithm: alg, digest: first.lowercased(), path: rest))
            } else if let last = line.split(separator: " ").last, last.count == 8, last.allSatisfy(\.isHexDigit) {
                out.append(Line(algorithm: .crc32, digest: last.lowercased(), path: String(line.dropLast(9)).trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }

    /// Generates a manifest (GNU coreutils format, or SFV for CRC-32) for files relative to `base`.
    public static func generate(for files: [URL], base: URL, algorithm: HashAlgorithm, progress: OperationProgress = OperationProgress()) throws -> String {
        var lines: [String] = []
        if algorithm == .crc32 { lines.append("; Generated by \(ProductInfo.name)") }
        let b = base.standardizedFileURL.path.hasSuffix("/") ? base.standardizedFileURL.path : base.standardizedFileURL.path + "/"
        for f in files {
            let digest = try StreamingHasher.hashFile(at: f, algorithm: algorithm, progress: progress)
            let p = f.standardizedFileURL.path
            let rel = p.hasPrefix(b) ? String(p.dropFirst(b.count)) : f.lastPathComponent
            lines.append(algorithm == .crc32 ? "\(rel) \(digest)" : "\(digest)  \(rel)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public struct VerifyResult: Sendable {
        public var ok: [String]
        public var mismatched: [String]
        public var missing: [String]
        public var passed: Bool { mismatched.isEmpty && missing.isEmpty }
    }

    public static func verify(manifest: URL, defaultAlgorithm: HashAlgorithm? = nil, progress: OperationProgress = OperationProgress()) throws -> VerifyResult {
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let base = manifest.deletingLastPathComponent()
        let extAlg = HashAlgorithm.allCases.first { $0.manifestExtension == manifest.pathExtension.lowercased() }
        var r = VerifyResult(ok: [], mismatched: [], missing: [])
        for line in parse(text) {
            try progress.checkCancelled()
            guard let alg = line.algorithm ?? extAlg ?? defaultAlgorithm else { continue }
            // Manifest paths are untrusted: refuse anything that escapes the manifest's folder.
            guard let comps = try? SafePath.components(of: line.path) else { r.missing.append(line.path); continue }
            let url = comps.reduce(base) { $0.appendingPathComponent($1) }
            guard FileManager.default.fileExists(atPath: url.path) else { r.missing.append(line.path); continue }
            let d = try StreamingHasher.hashFile(at: url, algorithm: alg, progress: progress)
            if d == line.digest.lowercased() { r.ok.append(line.path) } else { r.mismatched.append(line.path) }
        }
        return r
    }
}

// MARK: - Batch extraction

public struct BatchExtractRequest: Sendable {
    public var archives: [URL]
    /// nil: each archive extracts next to itself. Otherwise all go into this folder.
    public var sharedDestination: URL?
    /// Each archive gets its own folder (true) or uses smart extraction (false).
    public var folderPerArchive: Bool
    /// Skip archives whose output folder already exists.
    public var skipAlreadyExtracted: Bool
    public var continueOnError: Bool
    public var options: ExtractionOptions
    public var readOptions: ReadOptions

    public init(archives: [URL], sharedDestination: URL? = nil, folderPerArchive: Bool = true, skipAlreadyExtracted: Bool = true,
                continueOnError: Bool = true, options: ExtractionOptions = ExtractionOptions(), readOptions: ReadOptions = ReadOptions()) {
        self.archives = archives
        self.sharedDestination = sharedDestination
        self.folderPerArchive = folderPerArchive
        self.skipAlreadyExtracted = skipAlreadyExtracted
        self.continueOnError = continueOnError
        self.options = options
        self.readOptions = readOptions
    }
}

public struct BatchReport: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var archive: String
        public var status: String   // "extracted", "skipped", "failed"
        public var detail: String
        public var files: Int
        public var bytes: UInt64
    }
    public var items: [Item] = []
    public var succeeded: Int { items.filter { $0.status == "extracted" }.count }
    public var failed: Int { items.filter { $0.status == "failed" }.count }
    public var skipped: Int { items.filter { $0.status == "skipped" }.count }

    public var textReport: String {
        (["Batch Extraction Report", "", "Extracted: \(succeeded)", "Skipped: \(skipped)", "Failed: \(failed)", ""] +
         items.map { "[\($0.status)] \($0.archive)\($0.detail.isEmpty ? "" : " — " + $0.detail)" }).joined(separator: "\n")
    }
}

extension ArchiveService {
    /// Collapses multipart volumes so each set is extracted once (from its first volume).
    public static func distinctArchives(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for u in urls {
            let key = MultipartDetector.setKey(for: u)
            if seen.insert(key).inserted { out.append(MultipartDetector.detect(u)?.firstVolume ?? u) }
        }
        return out
    }

    public func extractBatch(_ request: BatchExtractRequest, progress: OperationProgress = OperationProgress()) throws -> BatchReport {
        var report = BatchReport()
        let archives = Self.distinctArchives(request.archives)
        progress.setTotal(bytes: nil, items: archives.count)
        // A password that worked is offered for the next archives, so the user isn't asked repeatedly.
        let caching = request.readOptions.passwordProvider.map { CachingPasswordProvider(upstream: $0) }
        // "Already extracted" means the folder existed before this run. Folders this run creates
        // don't count: "Photos.zip" and "Photos.tar.gz" are different archives, and the second
        // must not be skipped because the first just made "Photos".
        let existedBefore = Set(archives.map { a -> String in
            (request.sharedDestination ?? a.deletingLastPathComponent()).appendingPathComponent(Self.baseName(for: a)).path
        }.filter { FileManager.default.fileExists(atPath: $0) })
        for a in archives {
            try progress.checkCancelled()
            progress.setCurrentItem(a.lastPathComponent)
            let parent = request.sharedDestination ?? a.deletingLastPathComponent()
            let base = Self.baseName(for: a)
            if request.skipAlreadyExtracted, request.folderPerArchive, existedBefore.contains(parent.appendingPathComponent(base).path) {
                report.items.append(.init(archive: a.lastPathComponent, status: "skipped", detail: "“\(base)” already exists", files: 0, bytes: 0))
                progress.itemCompleted()
                continue
            }
            var ro = request.readOptions
            ro.passwordProvider = caching ?? ro.passwordProvider
            do {
                let o = try extract(ExtractRequest(archive: a, destination: parent, mode: request.folderPerArchive ? .newFolder : .smart,
                                                   options: request.options, readOptions: ro))
                report.items.append(.init(archive: a.lastPathComponent, status: "extracted",
                                          detail: o.createdItems.map(\.lastPathComponent).joined(separator: ", "),
                                          files: o.report.filesWritten, bytes: o.report.bytesWritten))
            } catch {
                let e = ArchiveError.wrap(error)
                if case .cancelled = e { throw e }
                report.items.append(.init(archive: a.lastPathComponent, status: "failed", detail: e.explanation, files: 0, bytes: 0))
                if !request.continueOnError { break }
            }
            progress.itemCompleted()
        }
        return report
    }
}
