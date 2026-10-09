import Foundation

/// A set of volumes forming one archive.
public struct MultipartSet: Sendable, Hashable, Codable {
    public enum Style: String, Sendable, Codable {
        /// archive.part1.rar, archive.part2.rar …
        case rarParts
        /// archive.rar, archive.r00, archive.r01 …
        case rarLegacy
        /// archive.z01, archive.z02 … archive.zip (the .zip is the last volume)
        case zipSplit
        /// archive.7z.001, archive.zip.001, archive.001 … (byte-split, concatenated)
        case numbered
    }

    public var style: Style
    /// Base name shared by every volume (e.g. "backup" for backup.part1.rar).
    public var baseName: String
    public var directory: URL
    /// Volumes found on disk, in reading order.
    public var volumes: [URL]
    /// File names of volumes that are expected but missing (gaps, or the final .zip of a split ZIP).
    public var missing: [String]
    /// The volume an engine must be given to start reading.
    public var firstVolume: URL
    /// Number of digits used in volume numbers (to propose correct missing names).
    public var digits: Int

    public var isComplete: Bool { missing.isEmpty }

    /// The format of the joined data, as implied by the naming scheme.
    public var impliedFormat: FormatID? {
        switch style {
        case .rarParts, .rarLegacy: return .rar
        case .zipSplit: return .zip
        case .numbered:
            return FormatCatalog.matchExtension(of: baseName)?.formats.first?.id
        }
    }

    /// The name the volume after the last one present would have.
    public var nextVolumeName: String {
        MultipartDetector.volumeName(style: style, base: baseName, index: volumes.count + 1, digits: digits)
    }
}

/// Recognises multipart naming schemes and finds sibling volumes.
public enum MultipartDetector {
    private static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    /// File name of volume number `index` (1-based) for a style.
    public static func volumeName(style: MultipartSet.Style, base: String, index: Int, digits: Int) -> String {
        func pad(_ n: Int, _ d: Int) -> String {
            let s = String(n)
            return s.count >= d ? s : String(repeating: "0", count: d - s.count) + s
        }
        switch style {
        case .rarParts: return "\(base).part\(pad(index, digits)).rar"
        case .rarLegacy: return index == 1 ? "\(base).rar" : "\(base).r\(pad(index - 2, 2))"
        case .zipSplit: return "\(base).z\(pad(index, 2))"
        case .numbered: return "\(base).\(pad(index, max(3, digits)))"
        }
    }

    /// Key identifying the multipart set a file belongs to (used to share passwords between volumes).
    public static func setKey(for url: URL) -> String {
        if let set = detect(url) { return set.directory.appendingPathComponent(set.baseName).path + "#" + set.style.rawValue }
        return url.standardizedFileURL.path
    }

    /// Whether the file name looks like a member of a multipart set, without touching the disk.
    public static func looksLikeVolume(_ name: String) -> Bool {
        match(#"^(.+)\.part(\d+)\.rar$"#, name) != nil ||
            match(#"^(.+)\.r(\d{2})$"#, name) != nil ||
            match(#"^(.+)\.z(\d{2})$"#, name) != nil ||
            match(#"^(.+)\.(\d{3})$"#, name) != nil
    }

    /// Detects the multipart set `url` belongs to. Returns nil for single-volume archives.
    public static func detect(_ url: URL, fileManager: FileManager = .default) -> MultipartSet? {
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let siblings = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        let lowerSiblings = Dictionary(siblings.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })

        func existing(_ candidate: String) -> URL? {
            lowerSiblings[candidate.lowercased()].map { dir.appendingPathComponent($0) }
        }

        // archive.partN.rar
        if let m = match(#"^(.+)\.part(\d+)\.rar$"#, name) {
            let base = m[0]
            var numbers: [Int: String] = [:]
            var digits = m[1].count
            for s in siblings {
                if let mm = match(#"^(.+)\.part(\d+)\.rar$"#, s), mm[0].lowercased() == base.lowercased(), let n = Int(mm[1]) {
                    numbers[n] = s
                    digits = max(digits, mm[1].count)
                }
            }
            return build(style: .rarParts, base: base, dir: dir, numbers: numbers, digits: digits, firstIndex: 1)
        }

        // archive.rar + archive.r00 …  /  archive.r00
        if let m = match(#"^(.+)\.(rar|r\d{2})$"#, name) {
            let base = m[0]
            var numbers: [Int: String] = [:]
            if let rar = existing("\(base).rar") { numbers[1] = rar.lastPathComponent }
            for s in siblings {
                if let mm = match(#"^(.+)\.r(\d{2})$"#, s), mm[0].lowercased() == base.lowercased(), let n = Int(mm[1]) {
                    numbers[n + 2] = s
                }
            }
            // A lone .rar with no .rNN siblings is a single-volume archive.
            if numbers.count <= 1, m[1].lowercased() == "rar" { return nil }
            return build(style: .rarLegacy, base: base, dir: dir, numbers: numbers, digits: 2, firstIndex: 1)
        }

        // archive.z01 … archive.zip
        if let m = match(#"^(.+)\.(zip|z\d{2})$"#, name) {
            let base = m[0]
            var numbers: [Int: String] = [:]
            for s in siblings {
                if let mm = match(#"^(.+)\.z(\d{2})$"#, s), mm[0].lowercased() == base.lowercased(), let n = Int(mm[1]), n > 0 {
                    numbers[n] = s
                }
            }
            if numbers.isEmpty { return nil }
            let maxN = numbers.keys.max() ?? 0
            var volumes: [URL] = []
            var missing: [String] = []
            for i in 1...maxN {
                if let s = numbers[i] { volumes.append(dir.appendingPathComponent(s)) } else { missing.append(volumeName(style: .zipSplit, base: base, index: i, digits: 2)) }
            }
            if let zip = existing("\(base).zip") { volumes.append(zip) } else { missing.append("\(base).zip") }
            let first = existing("\(base).zip") ?? volumes.first ?? url
            return MultipartSet(style: .zipSplit, baseName: base, directory: dir, volumes: volumes, missing: missing,
                                firstVolume: first, digits: 2)
        }

        // archive.7z.001 / archive.001
        if let m = match(#"^(.+)\.(\d{3,})$"#, name) {
            let base = m[0]
            var numbers: [Int: String] = [:]
            for s in siblings {
                if let mm = match(#"^(.+)\.(\d{3,})$"#, s), mm[0].lowercased() == base.lowercased(), let n = Int(mm[1]) {
                    numbers[n] = s
                }
            }
            // .000-based sets exist (some split tools); normalise to 1-based ordering.
            if numbers[0] != nil {
                var shifted: [Int: String] = [:]
                for (k, v) in numbers { shifted[k + 1] = v }
                numbers = shifted
            }
            return build(style: .numbered, base: base, dir: dir, numbers: numbers, digits: m[1].count, firstIndex: 1)
        }
        return nil
    }

    private static func build(style: MultipartSet.Style, base: String, dir: URL, numbers: [Int: String], digits: Int, firstIndex: Int) -> MultipartSet? {
        guard let maxN = numbers.keys.max() else { return nil }
        var volumes: [URL] = []
        var missing: [String] = []
        for i in firstIndex...max(firstIndex, maxN) {
            if let s = numbers[i] {
                volumes.append(dir.appendingPathComponent(s))
            } else {
                missing.append(volumeName(style: style, base: base, index: i, digits: digits))
            }
        }
        let first = numbers[firstIndex].map { dir.appendingPathComponent($0) } ?? volumes.first!
        return MultipartSet(style: style, baseName: base, directory: dir, volumes: volumes, missing: missing,
                            firstVolume: first, digits: digits)
    }
}
