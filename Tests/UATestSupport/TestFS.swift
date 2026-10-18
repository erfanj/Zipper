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
