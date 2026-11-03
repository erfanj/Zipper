import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// FileHandle's original API (readData(ofLength:), write(_:), seekToEndOfFile(), seek(toFileOffset:))
// can't report errors: on macOS it raises an Objective-C exception and on Linux it traps, so any
// read error — a folder passed where a file was expected (EISDIR), a disk that fills up, a file on
// a network volume that goes away — would crash the app. Everything goes through these instead.

extension FileHandle {
    /// Reads up to `count` bytes; returns empty data at the end of the file.
    public func readChunk(upTo count: Int, path: String) throws -> Data {
        do { return try read(upToCount: count) ?? Data() } catch { throw ArchiveError.fileIO(error, path: path) }
    }

    public func writeChunk(_ data: Data, path: String) throws {
        do { try write(contentsOf: data) } catch { throw ArchiveError.fileIO(error, path: path) }
    }

    /// Moves to the end of the file and returns its size.
    @discardableResult
    public func seekToEndChecked(path: String) throws -> UInt64 {
        do { return try seekToEnd() } catch { throw ArchiveError.fileIO(error, path: path) }
    }

    public func seekChecked(to offset: UInt64, path: String) throws {
        do { try seek(toOffset: offset) } catch { throw ArchiveError.fileIO(error, path: path) }
    }
}

public enum SafeFileIO {
    /// Opens a regular file for reading. A folder is reported as `notAFile` (never opened: reading
    /// a directory handle fails with EISDIR), a missing file as not found, anything else as denied.
    public static func openForReading(_ url: URL, folderError: (String) -> ArchiveError = { .notAnArchive(path: $0) }) throws -> FileHandle {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw ArchiveError.fileNotFound(path: url.path) }
        if isDir.boolValue { throw folderError(url.path) }
        guard let fh = FileHandle(forReadingAtPath: url.path) else { throw ArchiveError.permissionDenied(path: url.path) }
        return fh
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

extension ArchiveError {
    /// Converts a Foundation file error into an I/O error with the POSIX reason, where there is one.
    public static func fileIO(_ error: Error, path: String) -> ArchiveError {
        if let e = error as? ArchiveError { return e }
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let posix: Int32 = {
            if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
            if let u = underlying, u.domain == NSPOSIXErrorDomain { return Int32(u.code) }
            return 0
        }()
        switch posix {
        case EISDIR: return .io(path: path, code: posix, message: "It's a folder, not a file.")
        case ENOSPC: return .io(path: path, code: posix, message: "The disk is full.")
        case 0: return .io(path: path, code: 0, message: ns.localizedDescription)
        default: return .io(path: path, code: posix, message: String(cString: strerror(posix)))
        }
    }
}
