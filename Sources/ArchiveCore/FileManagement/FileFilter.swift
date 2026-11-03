import Foundation

/// One include/exclude rule.
public struct FilterRule: Codable, Hashable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable { case include, exclude }

    public enum Criterion: Codable, Hashable, Sendable {
        /// Shell-style glob matched against the relative path and the file name.
        /// `*` matches within a component, `**` across components, `?` one character,
        /// `[abc]` a set. A trailing `/` matches directories only.
        case glob(String)
        case regex(String)
        case fileExtension([String])
        case nameEquals(String)
        case largerThan(UInt64)
        case smallerThan(UInt64)
        case modifiedAfter(Date)
        case modifiedBefore(Date)
        case kind(FileKind)
    }

    public var id: UUID
    public var action: Action
    public var criterion: Criterion
    public var enabled: Bool

    public init(id: UUID = UUID(), _ action: Action, _ criterion: Criterion, enabled: Bool = true) {
        self.id = id
        self.action = action
        self.criterion = criterion
        self.enabled = enabled
    }

    public var displayText: String {
        let verb = action == .include ? "Include" : "Exclude"
        switch criterion {
        case .glob(let g): return "\(verb) \(g)"
        case .regex(let r): return "\(verb) matching /\(r)/"
        case .fileExtension(let e): return "\(verb) " + e.map { "*.\($0)" }.joined(separator: ", ")
        case .nameEquals(let n): return "\(verb) named \(n)"
        case .largerThan(let b): return "\(verb) larger than \(ByteFormatting.string(b))"
        case .smallerThan(let b): return "\(verb) smaller than \(ByteFormatting.string(b))"
        case .modifiedAfter(let d): return "\(verb) modified after \(d)"
        case .modifiedBefore(let d): return "\(verb) modified before \(d)"
        case .kind(let k): return "\(verb) \(k.rawValue) files"
        }
    }
}

/// Coarse file classification used by filters and the compression advisor.
public enum FileKind: String, Codable, Sendable, CaseIterable {
    case text, sourceCode, document, image, video, audio, archive, executable, database, other
}

/// Candidate file for filtering.
public struct FilterSubject {
    public var relativePath: String
    public var isDirectory: Bool
    public var size: UInt64
    public var modificationDate: Date?

    public init(relativePath: String, isDirectory: Bool, size: UInt64 = 0, modificationDate: Date? = nil) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
    }

    public var name: String { (relativePath as NSString).lastPathComponent }
}

/// Evaluates rules in order. Excludes win for directories (pruning whole subtrees). If any include
/// rule exists, files must match at least one include rule.
public struct FileFilter: Sendable {
    public var rules: [FilterRule]
    private let compiledRegex: [UUID: NSRegularExpression]

    public init(rules: [FilterRule]) {
        self.rules = rules.filter(\.enabled)
        var re: [UUID: NSRegularExpression] = [:]
        for r in self.rules {
            if case .regex(let p) = r.criterion, let c = try? NSRegularExpression(pattern: p) { re[r.id] = c }
        }
        compiledRegex = re
    }

    public static let none = FileFilter(rules: [])

    /// Common clutter that users may choose to exclude. Never applied unless selected.
    public static let commonExclusions: [FilterRule] = [
        FilterRule(.exclude, .nameEquals(".DS_Store")),
        FilterRule(.exclude, .glob("__MACOSX/")),
        FilterRule(.exclude, .nameEquals("Thumbs.db")),
        FilterRule(.exclude, .nameEquals("desktop.ini")),
        FilterRule(.exclude, .glob("._*")),
    ]

    public static let developerExclusions: [FilterRule] = [
        FilterRule(.exclude, .glob(".git/")),
        FilterRule(.exclude, .glob(".svn/")),
        FilterRule(.exclude, .glob(".hg/")),
        FilterRule(.exclude, .glob("node_modules/")),
        FilterRule(.exclude, .glob(".build/")),
        FilterRule(.exclude, .glob("DerivedData/")),
        FilterRule(.exclude, .glob("build/")),
        FilterRule(.exclude, .glob("__pycache__/")),
        FilterRule(.exclude, .glob("*.tmp")),
        FilterRule(.exclude, .glob("*.log")),
        FilterRule(.exclude, .nameEquals(".DS_Store")),
    ]

    /// Whether a directory's subtree should be skipped entirely.
    public func prunes(_ s: FilterSubject) -> Bool {
        guard s.isDirectory else { return false }
        return rules.contains { $0.action == .exclude && matches($0, s) }
    }

    /// Whether `s` is included.
    public func includes(_ s: FilterSubject) -> Bool {
        if rules.contains(where: { $0.action == .exclude && matches($0, s) }) { return false }
        if s.isDirectory { return true }
        let includes = rules.filter { $0.action == .include }
        if includes.isEmpty { return true }
        return includes.contains { matches($0, s) }
    }

    func matches(_ rule: FilterRule, _ s: FilterSubject) -> Bool {
        switch rule.criterion {
        case .glob(let pattern):
            var p = pattern
            let dirOnly = p.hasSuffix("/")
            if dirOnly { p.removeLast(); if !s.isDirectory { return false } }
            if p.contains("/") {
                return Glob.match(p.hasPrefix("/") ? String(p.dropFirst()) : p, s.relativePath)
                    || Glob.match("**/" + p, s.relativePath)
            }
            return Glob.match(p, s.name)
        case .regex:
            guard let re = compiledRegex[rule.id] else { return false }
            let ns = s.relativePath as NSString
            return re.firstMatch(in: s.relativePath, range: NSRange(location: 0, length: ns.length)) != nil
        case .fileExtension(let exts):
            guard !s.isDirectory else { return false }
            let e = (s.name as NSString).pathExtension.lowercased()
            return exts.contains { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == e }
        case .nameEquals(let n):
            return s.name == n
        case .largerThan(let b): return !s.isDirectory && s.size > b
        case .smallerThan(let b): return !s.isDirectory && s.size < b
        case .modifiedAfter(let d): return !s.isDirectory && (s.modificationDate.map { $0 > d } ?? false)
        case .modifiedBefore(let d): return !s.isDirectory && (s.modificationDate.map { $0 < d } ?? false)
        case .kind(let k): return !s.isDirectory && FileClassifier.kind(forExtension: (s.name as NSString).pathExtension) == k
        }
    }
}

/// Glob matcher supporting `*`, `**`, `?` and `[...]` character classes.
public enum Glob {
    public static func match(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.unicodeScalars)
        let t = Array(text.unicodeScalars)
        var memo = [Int: Bool]()
        func m(_ pi: Int, _ ti: Int) -> Bool {
            let key = pi * (t.count + 1) + ti
            if let v = memo[key] { return v }
            var result: Bool
            if pi == p.count {
                result = ti == t.count
            } else if p[pi] == "*" {
                let double = pi + 1 < p.count && p[pi + 1] == "*"
                if double {
                    var next = pi + 2
                    let slash = next < p.count && p[next] == "/"
                    if slash { next += 1 }
                    if next == p.count {
                        result = true // trailing ** matches everything below
                    } else {
                        // ** matches zero or more whole path components.
                        result = m(next, ti)
                        var k = ti
                        while !result, k < t.count {
                            k += 1
                            if t[k - 1] == "/" || !slash { result = m(next, k) }
                        }
                    }
                } else {
                    result = m(pi + 1, ti)
                    var k = ti
                    while !result, k < t.count, t[k] != "/" {
                        k += 1
                        result = m(pi + 1, k)
                    }
                }
            } else if ti < t.count {
                if p[pi] == "?" {
                    result = t[ti] != "/" && m(pi + 1, ti + 1)
                } else if p[pi] == "[", let close = p[(pi + 1)...].firstIndex(of: "]") {
                    var set = Array(p[(pi + 1)..<close])
                    var negate = false
                    if set.first == "!" || set.first == "^" { negate = true; set.removeFirst() }
                    var hit = false
                    var i = 0
                    while i < set.count {
                        if i + 2 < set.count, set[i + 1] == "-" {
                            if set[i].value <= t[ti].value && t[ti].value <= set[i + 2].value { hit = true }
                            i += 3
                        } else {
                            if set[i] == t[ti] { hit = true }
                            i += 1
                        }
                    }
                    result = (hit != negate) && m(close + 1, ti + 1)
                } else {
                    result = p[pi] == t[ti] && m(pi + 1, ti + 1)
                }
            } else {
                result = false
            }
            memo[key] = result
            return result
        }
        return m(0, 0)
    }
}
