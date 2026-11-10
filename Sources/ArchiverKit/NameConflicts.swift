import Foundation
import ArchiveCore

/// An archive can hold "Readme.txt" and "README.TXT", or the same name twice. A Mac's disk (and any
/// other case-insensitive volume) can't hold both, so operations that rebuild an archive from files
/// on disk (edit, convert) would silently rename or merge entries. They refuse instead, and say why.
/// Extraction is unaffected: it keeps both items, one under a numbered name, and reports the rename.
enum NameConflicts {
    /// Whether `dir`'s volume treats names that differ only by case as the same name.
    static func isCaseInsensitive(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let token = TempToken.make()
        let probe = dir.appendingPathComponent(".ua-\(token).partial")
        guard fm.createFile(atPath: probe.path, contents: nil) else { return false }
        defer { try? fm.removeItem(at: probe) }
        return fm.fileExists(atPath: dir.appendingPathComponent(".UA-\(token.uppercased()).PARTIAL").path)
    }

    static func fold(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

    /// Two different spellings among `paths` or their folders that fold to the same name.
    static func caseConflict(in paths: [String]) -> (first: String, second: String)? {
        var seen: [String: String] = [:]   // folded path → the spelling met first
        for path in paths {
            var prefix = ""
            for component in path.split(separator: "/") {
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                let key = fold(prefix)
                if let known = seen[key] {
                    // Compared byte by byte: Swift's == treats composed and decomposed accents as equal.
                    if !known.utf8.elementsEqual(prefix.utf8) { return (known, prefix) }
                } else {
                    seen[key] = prefix
                }
            }
        }
        return nil
    }

    /// Why a tree extracted into `dir` doesn't mirror `listing`, if it doesn't.
    static func conflict(listing: ArchiveListing, report: ExtractionReport, stagedIn dir: URL) -> ArchiveError? {
        let paths = listing.entries.map(\.normalizedPath)
        if isCaseInsensitive(dir), let c = caseConflict(in: paths) {
            return .conflictingNames(first: c.first, second: c.second)
        }
        // The sink renamed something anyway: the same name twice, or a file and a folder sharing one.
        if let renamed = report.renamed.first {
            return .conflictingNames(first: renamed.archivePath, second: renamed.archivePath)
        }
        return nil
    }

    /// Whether `newName` is just another spelling of `item` on this disk (as "Report.TXT" is of
    /// "report.txt" on a Mac): the names fold to the same thing and the folder holds only one of them.
    /// File IDs aren't compared: some drivers report a different one for each spelling.
    static func isRespelling(of item: URL, as newName: String) -> Bool {
        let key = fold(newName)
        guard fold(item.lastPathComponent) == key,
              let siblings = try? FileManager.default.contentsOfDirectory(atPath: item.deletingLastPathComponent().path) else { return false }
        return siblings.filter { fold($0) == key }.count == 1
    }
}
