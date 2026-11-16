import Foundation
import ArchiveCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Locates trusted helper executables. Only the app bundle's Helpers folder and fixed system
/// locations are searched; PATH and the current directory are never consulted.
public enum HelperLocator {
    /// Directories searched in order. The bundle's `Contents/Helpers` comes first.
    public static var searchDirectories: [String] = {
        var dirs: [String] = []
        // Resolve symlinks so /usr/local/bin/archiver -> App.app/Contents/Helpers/archiver finds its siblings.
        if let exec = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            // Contents/MacOS/<exe> → Contents/Helpers
            let helpers = exec.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers")
            dirs.append(helpers.path)
            dirs.append(exec.deletingLastPathComponent().path)
        }
        if let custom = ProcessInfo.processInfo.environment["UA_HELPERS_DIR"], !custom.isEmpty { dirs.append(custom) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return dirs
    }()

    public static func find(_ names: [String]) -> URL? {
        for dir in searchDirectories {
            for name in names {
                let path = (dir as NSString).appendingPathComponent(name)
                if isTrustedExecutable(path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    /// Refuses helpers that are writable by other users (which would let another account replace them).
    static func isTrustedExecutable(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, access(path, X_OK) == 0 else { return false }
        if st.st_mode & S_IWOTH != 0 { return false }
        if st.st_uid != 0 && st.st_uid != getuid() { return false }
        return true
    }
}

/// Runs a helper tool with arguments passed as an array (no shell), a controlled environment,
/// stdin answers for password prompts, streaming output and cancellation.
final class HelperProcess {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var combined: String { stdout + "\n" + stderr }
        var wasCancelled: Bool
        var passwordSupplied = false
    }

    let executable: URL
    let arguments: [String]
    var workingDirectory: URL?
    /// Called when output contains a password prompt. Return the password, or nil to abort.
    var onPasswordPrompt: (() -> Secret?)?
    /// Substrings that identify a password prompt.
    var promptMarkers: [String] = ["Enter password", "Verify password", "Reenter password"]
    var onStdoutChunk: ((String) -> Void)?
    /// Written to stdin (followed by a NUL byte) as soon as the process starts, then stdin is closed.
    /// Used for tools such as `hdiutil -stdinpass`.
    var initialInput: Secret?
    var progress: OperationProgress?
    /// The most memory the helper may hold, or nil for no limit. A damaged archive can make a
    /// helper's parser ask for many gigabytes (lsar did, on a fuzzed file); the helper is stopped
    /// rather than the computer. Helpers that *create* archives set this to nil: what they need
    /// follows from settings the user chose.
    var memoryLimit: UInt64? = HelperProcess.defaultMemoryLimit
    /// The longest the helper may run, not counting time spent paused; nil (the default) for no
    /// limit. For tools whose parsers can loop forever on damaged input.
    var timeLimit: TimeInterval?

    /// Half the computer's memory, and never less than 2 GB: more than any archive needs to be read
    /// (the largest 7z and RAR 5 dictionaries are 1.5 GB and 1 GB), less than what hurts.
    static var defaultMemoryLimit: UInt64 { max(2 << 30, ProcessInfo.processInfo.physicalMemory / 2) }

    /// Memory the process `pid` holds right now, or nil if that can't be read.
    static func residentMemory(of pid: Int32) -> UInt64? {
        #if os(Linux)
        if let statm = try? String(contentsOfFile: "/proc/\(pid)/statm", encoding: .utf8) {
            let fields = statm.split(separator: " ")
            if fields.count > 1, let pages = UInt64(fields[1]) { return pages * UInt64(max(1, sysconf(Int32(_SC_PAGESIZE)))) }
        }
        #endif
        return residentMemoryFromPS(pid)
    }

    /// The same, asked of `ps` (the way that works on macOS without private interfaces).
    static func residentMemoryFromPS(_ pid: Int32) -> UInt64? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "rss=", "-p", String(pid)]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        ps.standardInput = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        // This runs once a second for as long as a helper does: the descriptor is closed now, not
        // whenever the handle happens to be deallocated.
        try? out.fileHandleForReading.close()
        ps.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ps.terminationStatus == 0, let kilobytes = UInt64(text) else { return nil }
        return kilobytes * 1024
    }

    init(_ executable: URL, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Writing a password to a helper that has already exited must fail with EPIPE, not kill the
    /// whole process with SIGPIPE (the default action). Done once, before the first helper starts.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Writes `bytes` to the helper's stdin, ignoring a closed pipe (the helper reports its own error).
    private static func send(_ bytes: [UInt8], to handle: FileHandle) {
        try? handle.write(contentsOf: Data(bytes))
    }

    func run() throws -> Result {
        _ = Self.ignoreSIGPIPE
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if let wd = workingDirectory { p.currentDirectoryURL = wd }
        var env: [String: String] = [
            "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PATH": "/usr/bin:/bin",
            "HOME": NSTemporaryDirectory(), "TMPDIR": NSTemporaryDirectory(),
        ]
        #if os(macOS)
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        #endif
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe

        // Everything the pipe handlers, the cancel handler and this thread share, behind one lock.
        final class Shared: @unchecked Sendable {
            let lock = NSLock()
            var out = Data(), err = Data()
            var promptWindow = ""
            var prompts = 0
            var abortedForPassword = false
            var cancelled = false
            var finished = false
            var overMemory: UInt64?
            var active: TimeInterval = 0
            var overTime: TimeInterval?
        }
        let shared = Shared()
        let stdinHandle = inPipe.fileHandleForWriting
        let markers = promptMarkers
        let passwordPrompt = onPasswordPrompt

        /// Called with `shared.lock` held.
        @Sendable func handlePrompts(_ chunk: String) {
            shared.promptWindow += chunk
            if shared.promptWindow.count > 4096 { shared.promptWindow = String(shared.promptWindow.suffix(256)) }
            for marker in markers where shared.promptWindow.contains(marker) {
                shared.promptWindow = ""
                shared.prompts += 1
                if shared.prompts > 4 { shared.abortedForPassword = true; p.terminate(); return }
                if let secret = passwordPrompt?() {
                    secret.withBytes { bytes in
                        var line = bytes
                        line.append(0x0A)
                        Self.send(line, to: stdinHandle)
                        // Wipe the temporary copy.
                        for i in line.indices { line[i] = 0 }
                    }
                } else {
                    shared.abortedForPassword = true
                    try? stdinHandle.close()
                    p.terminate()
                }
                return
            }
        }

        let stdoutChunk = onStdoutChunk
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self)
            shared.lock.lock()
            shared.out.append(d)
            handlePrompts(s)
            shared.lock.unlock()
            stdoutChunk?(s)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            shared.lock.lock()
            shared.err.append(d)
            handlePrompts(String(decoding: d, as: UTF8.self))
            shared.lock.unlock()
        }

        var tokens: [OperationProgress.HandlerToken] = []
        if let progress {
            tokens.append(progress.onCancel { [weak p] in
                shared.lock.lock()
                shared.cancelled = true
                shared.lock.unlock()
                p?.terminate()
            })
            tokens.append(progress.onPauseChange { [weak p] paused in
                guard let p, p.isRunning else { return }
                // Suspending a helper is safe: it simply stops being scheduled until resumed.
                kill(p.processIdentifier, paused ? SIGSTOP : SIGCONT)
            })
        }
        // Only this run's handlers are removed: the progress object may be shared with other work.
        defer { progress?.removeHandlers(tokens) }
        do { try p.run() } catch {
            throw ArchiveError.engineUnavailable(EngineID(rawValue: executable.lastPathComponent), reason: error.localizedDescription)
        }
        if let input = initialInput {
            input.withBytes { bytes in
                var buf = bytes
                buf.append(0)
                Self.send(buf, to: stdinHandle)
                for i in buf.indices { buf[i] = 0 }
            }
            try? stdinHandle.close()
        }
        // Memory and time guard. SIGKILL, because a helper that is paused (SIGSTOP), busy
        // allocating or stuck in a loop doesn't act on a polite request.
        var limitGuard: DispatchSourceTimer?
        let (memoryLimit, timeLimit, watched) = (self.memoryLimit, self.timeLimit, self.progress)
        if memoryLimit != nil || timeLimit != nil {
            let pid = p.processIdentifier
            #if os(Linux)
            let interval: TimeInterval = 0.25
            #else
            let interval: TimeInterval = 1.0   // each look at the memory starts `ps` here
            #endif
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler {
                var tooMuch: UInt64?
                if let limit = memoryLimit, let used = Self.residentMemory(of: pid), used > limit { tooMuch = used }
                let paused = watched?.isPaused ?? false
                shared.lock.lock()
                if !paused { shared.active += interval }
                if !shared.finished, shared.overMemory == nil, shared.overTime == nil {
                    if let used = tooMuch {
                        shared.overMemory = used
                        kill(pid, SIGKILL)
                    } else if let limit = timeLimit, shared.active > limit {
                        shared.overTime = shared.active
                        kill(pid, SIGKILL)
                    }
                }
                shared.lock.unlock()
            }
            timer.resume()
            limitGuard = timer
        }
        p.waitUntilExit()
        shared.lock.lock()
        shared.finished = true
        shared.lock.unlock()
        limitGuard?.cancel()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Drain anything left.
        let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
        let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
        try? stdinHandle.close()
        // Closed here, not left to deallocation: on macOS a handle that has had a readability
        // handler keeps its descriptor open after the last reference is gone, two per helper run.
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
        shared.lock.lock()
        shared.out.append(restOut)
        shared.err.append(restErr)
        let (out, err, cancelled, aborted) = (shared.out, shared.err, shared.cancelled, shared.abortedForPassword)
        let (overMemory, overTime) = (shared.overMemory, shared.overTime)
        shared.lock.unlock()
        if cancelled || progress?.isCancelled == true { throw ArchiveError.cancelled }
        if let used = overMemory, let limit = memoryLimit {
            throw ArchiveError.safetyLimitExceeded(.helperMemory, limit: limit, observed: used)
        }
        if let ran = overTime, let limit = timeLimit {
            throw ArchiveError.safetyLimitExceeded(.helperTime, limit: UInt64(limit.rounded()), observed: UInt64(ran.rounded()))
        }
        var result = Result(status: p.terminationStatus, stdout: String(decoding: out, as: UTF8.self),
                            stderr: String(decoding: err, as: UTF8.self), wasCancelled: false)
        if aborted { result.status = -100 }
        return result
    }
}

/// Temporary extraction area inside the destination volume. Helper tools extract here; the result
/// is then imported through the safe sink, so their output gets the same validation as in-process
/// engines.
final class StagingDirectory {
    let url: URL

    init(near destination: URL) throws {
        let parent = FileManager.default.isWritableFile(atPath: destination.path) ? destination : FileManager.default.temporaryDirectory
        url = parent.appendingPathComponent(".ua-staging-\(TempToken.make())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    deinit { remove() }

    /// Size of everything written so far (bounded walk used by the watchdog).
    func usedBytes(limit: Int = 200_000) -> UInt64 {
        var total: UInt64 = 0
        var count = 0
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        for case let u as URL in en {
            count += 1
            if count > limit { break }
            if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                total += UInt64(v.fileSize ?? 0)
            }
        }
        return total
    }
}

/// Feeds a directory tree produced by a helper tool into an `ExtractionSink`.
public enum StagingImporter {
    public static func importTree(_ staging: URL, into sink: ExtractionSink, listing: [String: ArchiveEntry] = [:],
                           progress: OperationProgress) throws {
        let fm = FileManager.default
        var index = 0
        func walk(_ dir: URL, _ rel: String) throws {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
            for name in names {
                try progress.checkCancelled()
                let url = dir.appendingPathComponent(name)
                let path = rel.isEmpty ? name : rel + "/" + name
                guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
                let type = attrs[.type] as? FileAttributeType
                let mdate = attrs[.modificationDate] as? Date
                let perms = (attrs[.posixPermissions] as? NSNumber).map { UInt16(truncatingIfNeeded: $0.intValue) }
                let base = listing[path]
                index += 1
                switch type {
                case .typeDirectory?:
                    var e = ArchiveEntry(index: index, path: path, type: .directory, uncompressedSize: 0, modificationDate: base?.modificationDate ?? mdate, permissions: base?.permissions ?? perms)
                    e.isEncrypted = base?.isEncrypted ?? false
                    _ = try sink.begin(e, extras: .none)
                    try walk(url, path)
                case .typeSymbolicLink?:
                    let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                    _ = try sink.begin(ArchiveEntry(index: index, path: path, type: .symlink, linkTarget: target), extras: .none)
                case .typeRegular?:
                    let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                    var e = ArchiveEntry(index: index, path: path, type: .file, uncompressedSize: size,
                                         modificationDate: base?.modificationDate ?? mdate, permissions: base?.permissions ?? perms)
                    e.isEncrypted = base?.isEncrypted ?? false
                    try sink.importFile(e, extras: .none, from: url)
                default:
                    _ = try sink.begin(ArchiveEntry(index: index, path: path, type: .special), extras: .none)
                }
            }
        }
        try walk(staging, "")
    }
}

/// Caches the output of capability probes (`7z i`, `lsar -v`, `rar -iver`) keyed by the helper's
/// path, size and modification time, so launching the app or CLI doesn't start helper processes.
/// A changed or updated helper is probed again automatically.
enum ProbeCache {
    struct Entry: Codable {
        var key: String
        var status: Int32
        var stdout: String
    }

    static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("\(ProductInfo.cacheFolderName)/probes", isDirectory: true)
    }()

    static func run(_ exe: URL, _ args: [String]) -> (status: Int32, stdout: String)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: exe.resolvingSymlinksInPath().path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(exe.path)|\(size)|\(mtime)|\(args.joined(separator: " "))"
        let h = StreamingHasher(.sha256)
        h.update(Data(key.utf8))
        let file = directory.appendingPathComponent(String(h.finalizeHex().prefix(24)) + ".json")
        if let d = try? Data(contentsOf: file), let e = try? JSONDecoder().decode(Entry.self, from: d), e.key == key {
            return (e.status, e.stdout)
        }
        guard let r = try? HelperProcess(exe, args).run() else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Entry(key: key, status: r.status, stdout: r.stdout + (r.stdout.isEmpty ? r.stderr : ""))) {
            try? d.write(to: file, options: .atomic)
        }
        return (r.status, r.stdout + (r.stdout.isEmpty ? r.stderr : ""))
    }
}
