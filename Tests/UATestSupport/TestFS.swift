import Foundation
import XCTest
import ArchiveCore

/// Shared helpers for engine tests.
public enum TestFS {
    public static func tempDir(_ label: String = "t") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ua-tests-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    public static func write(_ root: URL, _ rel: String, _ content: String) -> URL {
        let url = root.appendingPathComponent(rel)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(content.utf8).write(to: url)
        return url
    }

    @discardableResult
    public static func writeBytes(_ root: URL, _ rel: String, _ data: Data) -> URL {
        let url = root.appendingPathComponent(rel)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
        return url
    }

    /// A small tree with Unicode names in several scripts, nested folders, an empty folder and binary data.
    public static func sampleTree(in parent: URL, name: String = "Sample") -> URL {
        let root = parent.appendingPathComponent(name)
        write(root, "readme.txt", String(repeating: "Zipper test line.\n", count: 200))
        write(root, "docs/فارسی.txt", "سلام دنیا")
        write(root, "docs/العربية.txt", "مرحبا بالعالم")
        write(root, "docs/中文/文件.txt", "你好，世界")
        write(root, "docs/日本語.txt", "こんにちは世界")
        write(root, "docs/한국어.txt", "안녕하세요")
        write(root, "docs/हिन्दी.txt", "नमस्ते दुनिया")
        write(root, "docs/Кириллица.txt", "Привет, мир")
        write(root, "docs/Crème brûlée.txt", "accents")
        write(root, "docs/emoji 🎉.txt", "party")
        var bytes = [UInt8](repeating: 0, count: 300_000)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: (i * 7919) ^ (i >> 3)) }
        writeBytes(root, "bin/data.bin", Data(bytes))
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        return root
    }

    /// Relative path → SHA-256 for every regular file under `root`.
    public static func digestTree(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root.path) else { return out }
        while let rel = en.nextObject() as? String {
            let url = root.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if let attrs = try? fm.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { continue }
            out[rel.precomposedStringWithCanonicalMapping] = try! StreamingHasher.hashFile(at: url, algorithm: .sha256)
        }
        return out
    }

    public static func directories(_ root: URL) -> Set<String> {
        var out = Set<String>()
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root.path) else { return out }
        while let rel = en.nextObject() as? String {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root.appendingPathComponent(rel).path, isDirectory: &isDir), isDir.boolValue {
                out.insert(rel.precomposedStringWithCanonicalMapping)
            }
        }
        return out
    }

    public static func which(_ tool: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let p = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// The reference 7-Zip: the official program, version 21 or later (what Zipper bundles and
    /// requires). `UA_HELPERS_DIR` is searched first, so `UA_HELPERS_DIR=Vendor/macos/helpers` tests
    /// against the bundled 7zz. Old p7zip builds (macOS runners ship 17.05) are not a reference: they
    /// mishandle non-ASCII ZIP AES passwords.
    public static let sevenZip: String? = {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        if let custom = ProcessInfo.processInfo.environment["UA_HELPERS_DIR"], !custom.isEmpty { dirs.insert(custom, at: 0) }
        for dir in dirs {
            for name in ["7zz", "7z"] {
                let path = dir + "/" + name
                guard FileManager.default.isExecutableFile(atPath: path), let text = try? run(path, ["i"]).1,
                      let m = text.range(of: #"7-Zip (\(z\) )?[0-9]+\.[0-9]+"#, options: .regularExpression),
                      let version = Double(text[m].split(separator: " ").last ?? ""), version >= 21 else { continue }
                return path
            }
        }
        return nil
    }()

    /// Runs a reference tool. Input is passed on stdin (used for passwords so they never appear in argv).
    @discardableResult
    public static func run(_ tool: String, _ args: [String], cwd: URL? = nil, stdin: String? = nil) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "C.UTF-8"
        env["LC_ALL"] = "C.UTF-8"
        p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inPipe = Pipe()
        p.standardInput = inPipe
        try p.run()
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inPipe.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Builds small tar archives in memory, so hostile layouts don't need committed fixtures.
public struct TarBuilder {
    public enum Kind: UInt8 { case file = 0x30, symlink = 0x32, directory = 0x35 }
    public private(set) var data = Data()

    public init() {}

    public mutating func add(_ name: String, kind: Kind = .file, content: String = "", link: String = "", mode: Int = 0o644) {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, at offset: Int, length: Int) {
            let bytes = Array(s.utf8.prefix(length))
            header.replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
        let body = Array(content.utf8)
        put(name, at: 0, length: 100)
        put(String(format: "%07o", kind == .directory ? 0o755 : mode), at: 100, length: 7)
        put("0000000", at: 108, length: 7)
        put("0000000", at: 116, length: 7)
        put(String(format: "%011o", kind == .file ? body.count : 0), at: 124, length: 11)
        put(String(format: "%011o", 1_700_000_000), at: 136, length: 11)
        header.replaceSubrange(148..<156, with: [UInt8](repeating: 0x20, count: 8))
        header[156] = kind.rawValue
        put(link, at: 157, length: 100)
        put("ustar", at: 257, length: 5)
        put("00", at: 263, length: 2)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), at: 148, length: 6)
        header[154] = 0
        header[155] = 0x20
        data.append(contentsOf: header)
        if kind == .file {
            data.append(contentsOf: body)
            data.append(contentsOf: [UInt8](repeating: 0, count: (512 - body.count % 512) % 512))
        }
    }

    public func write(to url: URL) throws {
        var out = data
        out.append(contentsOf: [UInt8](repeating: 0, count: 1024))
        try out.write(to: url)
    }
}

extension TestFS {
    /// A folder on a case-insensitive volume, as on a Mac's default APFS: the temporary folder when it
    /// is one, else the folder named by UA_CASE_INSENSITIVE_DIR (on Linux, e.g. a `ciopfs` mount).
    /// nil when neither is available.
    public static func caseInsensitiveDir(_ label: String) -> URL? {
        let fm = FileManager.default
        var bases = [fm.temporaryDirectory]
        if let custom = ProcessInfo.processInfo.environment["UA_CASE_INSENSITIVE_DIR"], !custom.isEmpty {
            bases.insert(URL(fileURLWithPath: custom, isDirectory: true), at: 0)
        }
        for base in bases {
            let dir = base.appendingPathComponent("ua-ci-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { continue }
            _ = fm.createFile(atPath: dir.appendingPathComponent("Probe.txt").path, contents: Data())
            let insensitive = fm.fileExists(atPath: dir.appendingPathComponent("pROBE.TXT").path)
            try? fm.removeItem(at: dir.appendingPathComponent("Probe.txt"))
            if insensitive { return dir }
            try? fm.removeItem(at: dir)
        }
        return nil
    }
}
