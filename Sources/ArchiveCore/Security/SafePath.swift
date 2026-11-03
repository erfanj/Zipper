import Foundation

/// Converts untrusted archive entry paths into safe relative path components.
///
/// The rules are deliberately strict. An entry is rejected (never "repaired" into a different
/// location) if any component is `..`, if it contains a NUL byte, or if a component is too long.
/// Absolute paths and Windows drive prefixes are made relative, matching the behaviour of
/// mainstream archivers (`/etc/passwd` → `etc/passwd` inside the destination).
public enum SafePath {
    public enum Rejection: Error, Equatable, CustomStringConvertible {
        case parentTraversal
        case nulByte
        case componentTooLong(String)
        case pathTooLong
        case empty
        case reservedName(String)

        public var description: String {
            switch self {
            case .parentTraversal: return "contains “..”"
            case .nulByte: return "contains a NUL character"
            case .componentTooLong(let c): return "name longer than 255 bytes (\(c.prefix(32))…)"
            case .pathTooLong: return "path longer than the system limit"
            case .empty: return "empty path"
            case .reservedName(let n): return "reserved name “\(n)”"
            }
        }
    }

    public static let maxComponentBytes = 255
    public static let maxPathBytes = 1024 * 4 - 1

    /// Returns the safe components of `raw`, relative to the destination root.
    /// - Parameter treatBackslashAsSeparator: Windows-created archives often use `\`; treating it as a
    ///   separator also stops `..\..\` traversal attempts.
    public static func components(of raw: String, treatBackslashAsSeparator: Bool = true,
                                  normalization: UnicodeNormalization = .none) throws -> [String] {
        if raw.utf8.contains(0) { throw Rejection.nulByte }
        var s = raw
        if treatBackslashAsSeparator { s = s.replacingOccurrences(of: "\\", with: "/") }
        // Strip Windows drive prefixes like "C:" / "C:/".
        if s.count >= 2 {
            let chars = Array(s.prefix(2))
            if chars[1] == ":", chars[0].isASCII, chars[0].isLetter { s.removeFirst(2) }
        }
        var out: [String] = []
        for part in s.split(separator: "/", omittingEmptySubsequences: true) {
            var comp = String(part)
            if comp == "." { continue }
            if comp == ".." { throw Rejection.parentTraversal }
            comp = normalization.apply(comp)
            if comp.utf8.count > maxComponentBytes { throw Rejection.componentTooLong(comp) }
            out.append(comp)
        }
        if out.isEmpty { throw Rejection.empty }
        if out.reduce(0, { $0 + $1.utf8.count + 1 }) > maxPathBytes { throw Rejection.pathTooLong }
        return out
    }

    /// Lexically resolves a symlink `target` relative to the directory containing the link.
    /// Returns the resolved components relative to the destination root, or nil if the target is
    /// absolute or escapes the destination.
    public static func resolveLinkTarget(_ target: String, linkParent: [String]) -> [String]? {
        guard !target.isEmpty, !target.utf8.contains(0) else { return nil }
        if target.hasPrefix("/") { return nil }
        var stack = linkParent
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if stack.isEmpty { return nil }
                stack.removeLast()
            } else {
                stack.append(String(part))
            }
        }
        return stack
    }
}

public enum UnicodeNormalization: String, Codable, Sendable, CaseIterable {
    case none
    /// Composed form; best for sharing with Windows and Linux.
    case nfc
    /// Decomposed form; what HFS+ historically stored.
    case nfd

    public func apply(_ s: String) -> String {
        switch self {
        case .none: return s
        case .nfc: return s.precomposedStringWithCanonicalMapping
        case .nfd: return s.decomposedStringWithCanonicalMapping
        }
    }
}
