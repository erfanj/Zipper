import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Thin, platform-neutral wrappers over the POSIX *at() family used for race-resistant extraction.
enum POSIX {
    static var lastErrno: Int32 { errno }

    static func errorMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    struct StatInfo {
        var mode: mode_t
        var size: UInt64
        var mtime: Date
        var isDirectory: Bool { (mode & S_IFMT) == S_IFDIR }
        var isSymlink: Bool { (mode & S_IFMT) == S_IFLNK }
        var isRegular: Bool { (mode & S_IFMT) == S_IFREG }
    }

    static func lstatAt(_ dirfd: Int32, _ name: String) -> StatInfo? {
        var st = stat()
        guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        #if canImport(Darwin)
        let ts = st.st_mtimespec
        #else
        let ts = st.st_mtim
        #endif
        return StatInfo(mode: st.st_mode, size: UInt64(st.st_size),
                        mtime: Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9))
    }

    static func openDirectory(at dirfd: Int32, _ name: String) -> Int32 {
        openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    static func openRoot(_ path: String) -> Int32 {
        open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }

    static func createExclusive(at dirfd: Int32, _ name: String, mode: mode_t = 0o600) -> Int32 {
        openat(dirfd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    }

    static func timespec(from date: Date) -> timespec {
        let t = date.timeIntervalSince1970
        var sec = floor(t)
        var nsec = (t - sec) * 1e9
        if nsec >= 1e9 { sec += 1; nsec -= 1e9 }
        #if canImport(Darwin)
        return Darwin.timespec(tv_sec: Int(sec), tv_nsec: Int(nsec))
        #else
        return Glibc.timespec(tv_sec: Int(sec), tv_nsec: Int(nsec))
        #endif
    }

    #if canImport(Darwin)
    static let utimeOmit = -2
    #else
    static let utimeOmit = (1 << 30) - 2
    #endif

    /// Sets access and modification times on an open descriptor. A nil date leaves it unchanged.
    static func setTimes(fd: Int32, modification: Date?, access: Date?) {
        guard modification != nil || access != nil else { return }
        var omit = timespec(from: Date())
        omit.tv_nsec = utimeOmit
        var times = [access.map { timespec(from: $0) } ?? omit, modification.map { timespec(from: $0) } ?? omit]
        _ = futimens(fd, &times)
    }

    static func availableBytes(fd: Int32) -> UInt64? {
        var s = statvfs()
        guard fstatvfs(fd, &s) == 0 else { return nil }
        return UInt64(s.f_bavail) * UInt64(s.f_frsize)
    }

    static func availableBytes(path: String) -> UInt64? {
        var s = statvfs()
        guard statvfs(path, &s) == 0 else { return nil }
        return UInt64(s.f_bavail) * UInt64(s.f_frsize)
    }

    @discardableResult
    static func setXattr(fd: Int32, name: String, value: [UInt8]) -> Bool {
        #if os(macOS)
        return value.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, value.count, 0, 0) == 0 }
        #else
        return false
        #endif
    }

    static func getXattr(path: String, name: String) -> [UInt8]? {
        #if os(macOS)
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        let n = buf.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return n > 0 ? Array(buf.prefix(n)) : nil
        #else
        return nil
        #endif
    }

    static func randomToken() -> String {
        String(UInt64.random(in: 0...UInt64.max), radix: 36)
    }
}
