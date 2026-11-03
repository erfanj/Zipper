import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Temporary items written next to the user's files (partial archives, extraction staging folders,
/// rebuilt archives) are removed when an operation finishes, fails or is cancelled. A process that
/// is killed (crash, force quit, power loss) can't do that, and its hidden leftovers — as large as
/// the archive — used to stay forever. Every such item now carries a token naming the process that
/// made it, and `Leftovers.sweep` removes the ones whose process is gone before writing to a folder.
public enum TempToken {
    /// "z<pid>-<8 hex digits>", unique per call.
    public static func make() -> String {
        String(format: "z%d-%08x", getpid(), UInt32.random(in: 0...UInt32.max))
    }
}

public enum Leftovers {
    /// Names Zipper gives temporary items: ".name.ua-TOKEN[.partial|.dmg|.rar]", ".name.ua-partial",
    /// ".ua-KIND-TOKEN" and ".ua-TOKEN.partial". TOKEN is a TempToken, or (before tokens) a number or UUID.
    private static let pattern = try! NSRegularExpression(pattern:
        #"^\.(?:.+\.ua-(?:partial|(?<a>[0-9A-Za-z-]+)(?:\.partial|\.dmg|\.rar)?)|ua-(?:(?:extract|staging|convert|modify|dmg|aa|rar-repair)-)?(?<b>[0-9A-Za-z-]+)(?:\.partial)?)$"#)
    private static let tokenPattern = try! NSRegularExpression(pattern: #"^z(\d+)-[0-9a-f]{8}$"#)

    /// Removes leftovers of dead processes in `dir` (not recursive). Untagged leftovers from older
    /// versions are removed once they are a day old. Never throws; never touches anything else.
    public static func sweep(_ dir: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix(".") && name.contains("ua-") {
            guard isStale(name, at: dir.appendingPathComponent(name), now: now) else { continue }
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    static func isStale(_ name: String, at url: URL, now: Date) -> Bool {
        let ns = name as NSString
        guard let m = pattern.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return false }
        let tokenRange = m.range(withName: "a").location != NSNotFound ? m.range(withName: "a") : m.range(withName: "b")
        if tokenRange.location != NSNotFound {
            let token = ns.substring(with: tokenRange)
            if let t = tokenPattern.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)),
               let pid = Int32((token as NSString).substring(with: t.range(at: 1))) {
                return !isAlive(pid)
            }
        }
        // Made before tokens existed: only when clearly abandoned.
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? now
        return now.timeIntervalSince(modified) > 24 * 3600
    }

    static func isAlive(_ pid: Int32) -> Bool {
        if pid == getpid() { return true }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
