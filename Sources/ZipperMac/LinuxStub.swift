#if !os(macOS)
// The Zipper app is macOS-only. Elsewhere this target builds a stub, so the package (core, engines,
// CLI, tests — and the app's platform-neutral model code, which is type-checked here) builds everywhere.
@main
struct ZipperStub {
    static func main() {
        print("Zipper's app requires macOS 14 or later. Use the `zipper` command-line tool on this platform.")
    }
}
#endif
