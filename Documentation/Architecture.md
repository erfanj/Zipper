# Architecture

Universal Archiver is a Swift package with a strict layering: a platform-neutral core, a set of
interchangeable engines, a service layer, and two front ends (the macOS app and the `archiver`
CLI). Everything below the app builds and is tested on macOS and Linux.

```
                     UNIVERSAL ARCHIVER
                            │
          ┌─────────────────┴──────────────────┐
     macOS app (SwiftUI + AppKit)        archiver CLI / Shortcuts / Finder Services
          └─────────────────┬──────────────────┘
                            │
                  ArchiverKit (service façade)
   extract · compress · convert · modify · test · repair · split/join · compare
   duplicates · checksums · batch · history · operation queue · passwords · performance
                            │
                  ArchiveCore (no engine code)
   format catalogue & detection · multipart · engine protocol & registry · SafeExtractionSink
   safety limits · filters · source collection · hashing · presets · advisor · errors
                            │
                       Engine registry
     ┌──────────┬───────────┼────────────┬───────────┬──────────────┬─────────────┐
 libarchive   7-Zip      unar/lsar     RAR (user-    Apple Archive  hdiutil      zpaq/lrzip/
 (in-process) (helper)   (helper)      installed)    (framework)    (system)     lzop/nomarch
 + Brotli                                                                         (helpers)
                            │
                  File system (POSIX *at() calls)
```

## Modules

| Target | Responsibility |
|---|---|
| `CArchive`, `CZlib`, `CBrotli` | System-library shims (module maps) for libarchive, zlib and Brotli. |
| `ArchiveCore` | The engine-agnostic model: `FormatID`/`FormatDescriptor`/`FormatCatalog` (97 formats), `FormatDetector`, `MultipartDetector`, the `ArchiveEngine` protocol and `EngineRegistry`, `SafeExtractionSink`, `SafetyLimits`, `SafePath`, `FileFilter`/`Glob`, `SourceCollector`, `StreamingHasher`, presets, the compression advisor, `ArchiveError`, `OperationProgress`, `Secret`. |
| `ArchiveEngines` | Concrete engines: `LibArchiveEngine`, `SevenZipEngine`, `UnarEngine`, `RarEngine`, `ExternalToolsEngine`, and on macOS `AppleArchiveEngine` and `DiskImageEngine`. Also helper-process plumbing (`HelperProcess`, `HelperLocator`, `StagingDirectory`, `StagingImporter`). |
| `ArchiverKit` | High-level operations with engine fallback, smart extraction, conversion, transactional editing, repair, tools, history, operation queue, password storage (Keychain), performance profile. |
| `archiver` | Command-line companion. |
| `UniversalArchiver` | The macOS SwiftUI app (a stub on other platforms). |
| `Integrations/QuickLook` | Quick Look preview extension (built through the Xcode project). |

## Key design decisions

### One write path: `SafeExtractionSink`

Engines never write extracted files themselves. In-process engines stream entry data into an
`ExtractionSink`; helper-process engines extract into a private staging folder on the destination
volume and `StagingImporter` feeds the result through the same sink. The sink is therefore the only
code that creates files during extraction, and it enforces every rule in one place: path
validation, `O_NOFOLLOW` component-by-component directory traversal, conflict policy, temporary
names with atomic placement, permission sanitising, quarantine propagation, and all resource
limits. See [Security.md](Security.md).

### Staging, then placement

`ArchiveService.extract` always extracts into `.ua-extract-<uuid>` inside the destination folder.
Only after the engine finishes successfully is the result moved into place (Smart Extract / New
Folder) or merged (Extract Here, through a second sink that applies the user's conflict policy).
A failed attempt, a cancellation, or a fallback to another engine therefore never leaves partial
output in the user's folder.

### Engine selection and fallback

Each engine declares an `EngineFormatSupport` per format: operations (inspect, extract, create,
modify, test, repair, createSplit, readSplit, encrypt, decrypt, encryptFilenames,
preserveMetadata, streaming, multithreaded, selectiveExtract), methods, encryption methods,
memory/threading notes and limitations. Support is discovered at run time where it depends on the
build (libarchive's writers are probed; 7-Zip's format list is parsed from `7z i`).

`EngineRegistry.candidates(for:requirements:)` returns capable engines in priority order
(libarchive first — in-process, streaming, no process start-up — then 7-Zip, unar, external tools).
`ArchiveService.withEngines` runs an operation with the first candidate and retries with the next
one only for capability errors (unsupported method/encryption, not recognised) and for "damaged"
verdicts that may be engine-specific. Wrong passwords, checksum mismatches, safety-limit stops and
cancellations are never retried. Every fallback is recorded in `engineNotes` and shown to the user;
the policy can be set to ask first or never fall back.

Real cases this resolves (all covered by interop tests): encrypted RAR 5 and RAR3 solid archives
(libarchive → 7-Zip/unar), encrypted 7z (libarchive → 7-Zip), Deflate64 ZIP (libarchive → 7-Zip),
ARC variants unar cannot decode (unar → nomarch).

### Format detection

Content signatures first, extension second (`FormatDetector`). Strong signatures override a
misleading extension; packages that share a container's signature (JAR/EPUB/APK → ZIP, CBR → RAR,
PKG → XAR) are identified by extension; compression streams are probed for an inner tarball so
`data.gz` containing a tar is extracted in one step. Multipart sets are recognised from names alone
(`.partN.rar`, `.rar/.r00`, `.z01…/.zip`, `.001`), with gaps reported before any work starts.

### Transactions

Archive edits (`ArchiveService.modify`) extract to a private folder, apply the edits, rebuild the
archive with the same format (and encryption, re-using the password), test it, check it contains
exactly the expected files, and only then `rename(2)` it over the original. Conversion keeps the
original and verifies the result by SHA-256 of every entry. Compression writes to a temporary file
that is linked into place only after the engine succeeds.

### Concurrency and progress

Long operations take an `OperationProgress`: a thread-safe tracker that also carries cancellation
and pause. In-process engines check it between blocks (pause blocks the worker at a checkpoint);
helper processes are suspended with `SIGSTOP`/`SIGCONT` and terminated on cancel. The
`OperationCenter` queue runs operations on GCD with a quality-of-service and concurrency limit
derived from the performance mode and the machine (`SystemProfile`: P/E core counts via
`hw.perflevel*`, Low Power Mode, thermal state).

### Passwords

Passwords are `Secret` byte buffers zeroed on release. Engines ask a `PasswordProvider` only when an
archive needs one; the app's provider checks the Keychain, then shows a sheet (the worker thread
waits on a semaphore; the main thread is never blocked). Helper tools receive passwords on stdin in
answer to their prompt, never as arguments. `CachingPasswordProvider` reuses a password across a
multipart set or batch.

## Extending: adding a format provider

See [PluginInterface.md](PluginInterface.md). In short: implement `ArchiveEngine`, declare
`EngineFormatSupport` honestly, route all extraction through the sink you are given, add the engine
to `DefaultEngines.make()`, and add fixtures and interop tests. Engines are compiled into the
signed app; there is deliberately no mechanism to load executable plug-ins at run time.
