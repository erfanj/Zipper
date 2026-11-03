import Foundation
import ArchiveCore
import ArchiveEngines

public enum ComparisonMode: String, Codable, Sendable {
    /// Names, sizes, dates and stored CRCs only (fast; no decompression).
    case metadata
    /// Decompresses both archives and compares SHA-256 of every file.
    case content
}

public struct ComparisonResult: Codable, Sendable {
    public struct Change: Codable, Sendable, Hashable {
        public var path: String
        public var reason: String
    }
    public var left: String
    public var right: String
    public var mode: ComparisonMode
    public var added: [String] = []
    public var removed: [String] = []
    public var modified: [Change] = []
    public var identical: [String] = []

    public var isIdentical: Bool { added.isEmpty && removed.isEmpty && modified.isEmpty }

    public var textReport: String {
        var lines = ["Archive Comparison", "", "Left:  \(left)", "Right: \(right)", "Mode:  \(mode == .content ? "content (SHA-256)" : "metadata")", "",
                     "Identical: \(identical.count)", "Added: \(added.count)", "Removed: \(removed.count)", "Modified: \(modified.count)", ""]
        for a in added { lines.append("+ \(a)") }
        for r in removed { lines.append("- \(r)") }
        for m in modified { lines.append("~ \(m.path) (\(m.reason))") }
        return lines.joined(separator: "\n")
    }

    public var csvReport: String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = ["status,path,detail"]
        rows += added.map { "added,\(q($0))," }
        rows += removed.map { "removed,\(q($0))," }
        rows += modified.map { "modified,\(q($0.path)),\(q($0.reason))" }
        rows += identical.map { "identical,\(q($0))," }
        return rows.joined(separator: "\n")
    }
}

extension ArchiveService {
    /// Hashes every file entry of an archive while streaming it (nothing is written to disk).
    public func hashEntries(_ url: URL, algorithm: HashAlgorithm = .sha256, options: ReadOptions = ReadOptions(),
                            progress: OperationProgress = OperationProgress()) throws -> (listing: ArchiveListing, digests: [String: String], sizes: [String: UInt64]) {
        let opened = try open(url, options: options, progress: progress)
        let sink = VerifyingSink(hashing: algorithm)
        var notes: [String] = []
        _ = try withEngines(for: opened.detection.format, EngineRequirements(operations: .extract), notes: &notes) {
            try $0.extract(opened.source, selection: .all, into: sink, options: options, progress: progress)
        }
        return (opened.listing, sink.digests, sink.sizes)
    }

    public func compare(_ a: URL, _ b: URL, mode: ComparisonMode = .metadata, leftOptions: ReadOptions = ReadOptions(),
                        rightOptions: ReadOptions = ReadOptions(), progress: OperationProgress = OperationProgress()) throws -> ComparisonResult {
        var result = ComparisonResult(left: a.lastPathComponent, right: b.lastPathComponent, mode: mode)
        func files(_ l: ArchiveListing) -> [String: ArchiveEntry] {
            var d: [String: ArchiveEntry] = [:]
            for e in l.entries where e.type == .file { d[e.normalizedPath.precomposedStringWithCanonicalMapping] = e }
            return d
        }
        switch mode {
        case .metadata:
            let la = try open(a, options: leftOptions, progress: progress).listing
            let lb = try open(b, options: rightOptions, progress: progress).listing
            let fa = files(la), fb = files(lb)
            for (p, ea) in fa.sorted(by: { $0.key < $1.key }) {
                guard let eb = fb[p] else { result.removed.append(p); continue }
                var reasons: [String] = []
                if let s1 = ea.uncompressedSize, let s2 = eb.uncompressedSize, s1 != s2 { reasons.append("size \(s1) → \(s2)") }
                if let c1 = ea.crc32, let c2 = eb.crc32, c1 != c2 { reasons.append("CRC differs") }
                if let d1 = ea.modificationDate, let d2 = eb.modificationDate, abs(d1.timeIntervalSince(d2)) > 2 { reasons.append("modification date differs") }
                if reasons.isEmpty { result.identical.append(p) } else { result.modified.append(.init(path: p, reason: reasons.joined(separator: ", "))) }
            }
            result.added = fb.keys.filter { fa[$0] == nil }.sorted()
        case .content:
            let ha = try hashEntries(a, options: leftOptions, progress: progress)
            let hb = try hashEntries(b, options: rightOptions, progress: progress)
            let da = Dictionary(ha.digests.map { ($0.key.precomposedStringWithCanonicalMapping, $0.value) }, uniquingKeysWith: { x, _ in x })
            let db = Dictionary(hb.digests.map { ($0.key.precomposedStringWithCanonicalMapping, $0.value) }, uniquingKeysWith: { x, _ in x })
            for (p, h) in da.sorted(by: { $0.key < $1.key }) {
                guard let h2 = db[p] else { result.removed.append(p); continue }
                if h == h2 { result.identical.append(p) } else { result.modified.append(.init(path: p, reason: "content differs")) }
            }
            result.added = db.keys.filter { da[$0] == nil }.sorted()
        }
        return result
    }

    /// Groups of identical files (by SHA-256) inside one or more archives. Nothing is deleted.
    public func findDuplicates(in archives: [URL], options: ReadOptions = ReadOptions(), progress: OperationProgress = OperationProgress()) throws -> [DuplicateGroup] {
        var byHash: [String: [DuplicateGroup.Member]] = [:]
        var sizes: [String: UInt64] = [:]
        for url in archives {
            let h = try hashEntries(url, options: options, progress: progress)
            for (path, digest) in h.digests {
                byHash[digest, default: []].append(.init(archive: url.lastPathComponent, path: path))
                sizes[digest] = h.sizes[path]
            }
        }
        return byHash.filter { $0.value.count > 1 && (sizes[$0.key] ?? 0) > 0 }
            .map { DuplicateGroup(sha256: $0.key, size: sizes[$0.key] ?? 0, members: $0.value.sorted { ($0.archive, $0.path) < ($1.archive, $1.path) }) }
            .sorted { $0.wastedBytes > $1.wastedBytes }
    }
}

public struct DuplicateGroup: Codable, Sendable {
    public struct Member: Codable, Sendable, Hashable {
        public var archive: String
        public var path: String
    }
    public var sha256: String
    public var size: UInt64
    public var members: [Member]
    public var wastedBytes: UInt64 { size * UInt64(max(0, members.count - 1)) }
}
