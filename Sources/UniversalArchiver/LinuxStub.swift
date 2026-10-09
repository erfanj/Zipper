#if !os(macOS)
// The Universal Archiver app is macOS-only. On other platforms this target builds a stub so the
// package (core, engines, CLI and tests) builds and tests everywhere.
@main
struct UniversalArchiverStub {
    static func main() {
        print("Universal Archiver's graphical app requires macOS 14 or later. Use the `archiver` command-line tool on this platform.")
    }
}
#endif
