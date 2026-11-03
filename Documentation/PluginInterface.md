# Engine provider interface

New formats are added by implementing an engine. Engines are ordinary Swift types compiled into the
app and signed with it. Loading engines from disk at run time is intentionally unsupported: archive
parsers process hostile input, so only trusted, signed code may do it. Engines that drive an
external tool must locate it through `HelperLocator` (the app bundle's `Contents/Helpers` and fixed
system directories only — never `PATH` or the working directory).

## The protocol

```swift
public protocol ArchiveEngine: AnyObject, Sendable {
    var descriptor: EngineDescriptor { get }          // id, name, implementation, version, license, availability, isolation
    func support(for format: FormatID) -> EngineFormatSupport?
    var supportedFormats: [FormatID] { get }

    func list(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> ArchiveListing
    func extract(_ source: ArchiveSource, selection: EntrySelection, into sink: ExtractionSink,
                 options: ReadOptions, progress: OperationProgress) throws
    func test(_ source: ArchiveSource, options: ReadOptions, progress: OperationProgress) throws -> IntegrityReport  // default: decode into a VerifyingSink
    func create(_ request: CreateRequest, progress: OperationProgress) throws -> CreateResult                       // default: unsupported
}
```

## Rules for implementations

1. **Declare capabilities truthfully.** `EngineFormatSupport.operations` must only contain what the
   engine really does in this build. Probe at run time when it depends on build options. List known
   limitations in `limitations`; the UI and the generated capability matrix show them.
2. **Never write to the destination yourself.** Stream entry data into the provided
   `ExtractionSink` (`begin` → `write` → `commit`/`abort`). If you must use a tool that writes files,
   extract into a `StagingDirectory` and import with `StagingImporter.importTree(_:into:progress:)`.
3. **Respect `EntrySelection`** (skip unselected entries) and **`ReadOptions.salvage`** (record entry
   failures in the `SalvageLog` and continue, for the repair workflow).
4. **Ask for passwords lazily** through `options.passwordProvider`, with reason `.required` first and
   `.previousAttemptIncorrect` after a failure. Never put passwords in arguments, logs or errors.
5. **Map failures to `ArchiveError`**: distinguish `passwordRequired`, `incorrectPassword`,
   `unsupportedEncryption`, `unsupportedMethod`, `damaged`, `checksumMismatch`, `truncated`,
   `missingVolume`. The service's fallback logic depends on these distinctions.
6. **Support cancellation** by calling `progress.checkCancelled()` regularly (this is also where
   pause takes effect), and report progress with `setProcessed`/`setOutput`.
7. **Creation writes to a temporary file** and moves it into place only on success, never
   overwriting an existing file.
8. **Register** the engine in `DefaultEngines.make()` at the right priority and add the format to
   `FormatCatalog` if it is new.
9. **Add fixtures and tests**: reference-tool fixtures in `Scripts/make-interop-fixtures.sh`, a
   malicious sample if the format has new structure, and round-trip tests for creation.
