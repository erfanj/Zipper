import Foundation
import Observation
import ArchiveCore
import ArchiveEngines
import ArchiverKit

/// State of the Tools window. One object per tool keeps each tool's inputs and results while the
/// user switches between them; results arrive on the main actor when the background work finishes.
@MainActor
@Observable
final class ToolsState {
    let test = IntegrityTool()
    let repair = RepairTool()
    let convert = ConvertTool()
    let batch = BatchTool()
    let checksums = ChecksumTool()
    let splitJoin = SplitJoinTool()
    let compare = CompareTool()
    let duplicates = DuplicatesTool()

    /// Hands archives dropped elsewhere (e.g. several archives at once) to the selected tool.
    func receive(_ urls: [URL], for tool: Tool) {
        guard !urls.isEmpty else { return }
        switch tool {
        case .test: test.archives = urls
        case .repair: repair.setArchive(urls.first)
        case .convert: convert.archives = urls
        case .batchExtract: batch.archives = urls
        case .checksums: checksums.files = urls
        case .splitJoin: break
        case .compare: compare.left = urls.first; compare.right = urls.dropFirst().first
        case .duplicates: duplicates.archives = urls
        }
    }
}

// MARK: Test

@MainActor
@Observable
final class IntegrityTool {
    var archives: [URL] = []
    private(set) var reports: [IntegrityReport] = []
    private(set) var isRunning = false

    func run(_ model: AppModel) {
        let list = archives
        let service = model.service
        let options = model.readOptions()
        reports = []
        isRunning = true
        model.run("Test \(list.count == 1 ? list[0].lastPathComponent : "\(list.count) archives")", kind: .test, inputs: list,
                  onFinish: { self.isRunning = false }) { progress in
            var out: [IntegrityReport] = []
            for url in list {
                do {
                    out.append(try service.test(url, options: options, progress: progress))
                } catch {
                    let e = ArchiveError.wrap(error)
                    if case .cancelled = e { throw e }
                    var r = IntegrityReport(archive: url.lastPathComponent, format: "unknown", engine: "none")
                    r.issues.append(.init(entry: nil, message: e.explanation, code: e.code))
                    out.append(r)
                }
            }
            let results = out
            Task { @MainActor in self.reports = results }
            let passed = out.filter { $0.result == .passed }.count
            return "\(passed) passed, \(out.count - passed) with problems"
        }
    }

    var reportText: String { reports.map(\.textSummary).joined(separator: "\n\n") }
}

// MARK: Repair

@MainActor
@Observable
final class RepairTool {
    /// The damaged archive. Change it with `setArchive(_:)`, which clears stale results.
    private(set) var archive: URL?
    private(set) var analysis: DamageAnalysis?
    private(set) var report: RecoveryReport?
    private(set) var isRunning = false

    func setArchive(_ url: URL?) {
        archive = url
        analysis = nil
        report = nil
    }

    func analyze(_ model: AppModel) {
        guard let url = archive else { return }
        let service = model.service
        let options = model.readOptions()
        isRunning = true
        analysis = nil
        report = nil
        model.run("Analyze \(url.lastPathComponent)", kind: .repair, inputs: [url], onFinish: { self.isRunning = false }) { progress in
            let a = try service.analyzeDamage(url, options: options, progress: progress)
            // Shown only if the user hasn't chosen another archive in the meantime.
            Task { @MainActor in if self.archive == url { self.analysis = a } }
            return a.estimate
        }
    }

    func recover(_ model: AppModel, to destination: URL) {
        guard let url = archive else { return }
        let service = model.service
        let options = model.readOptions()
        isRunning = true
        model.run("Recover from \(url.lastPathComponent)", kind: .repair, inputs: [url], onFinish: { self.isRunning = false }) { progress in
            let r = try service.recover(url, to: destination, options: options, progress: progress)
            Task { @MainActor in if self.archive == url { self.report = r } }
            return "\(r.recovered.count) files recovered, \(r.failed.count) not recoverable"
        }
    }
}

// MARK: Convert

@MainActor
@Observable
final class ConvertTool {
    var archives: [URL] = []
    var presetIndex = 0
    var password = ""
    var confirmation = ""
    var trashOriginals = false
    private(set) var warnings: [ConversionWarning] = []

    var target: (name: String, settings: CompressionSettings) { ConversionPresets.all[presetIndex] }
    var needsPassword: Bool { target.settings.encryption != nil }

    var problem: String? {
        if archives.isEmpty { return "Add archives to convert." }
        if needsPassword {
            if password.isEmpty { return "Enter a password for the new archives." }
            if password != confirmation { return "The passwords don't match." }
        }
        return nil
    }

    /// Lists what the target format can't keep (encryption, Unix permissions, comments…).
    func refreshWarnings(_ model: AppModel) async {
        let service = model.service
        let list = archives
        let settings = target.settings
        let r = await offMain { () -> [ConversionWarning] in
            var all = Set<ConversionWarning>()
            for u in list {
                if let listing = try? service.open(u).listing { all.formUnion(service.conversionWarnings(from: listing, to: settings)) }
            }
            return all.sorted { $0.feature < $1.feature }
        }
        if case .success(let w) = r { warnings = w }
    }

    func run(_ model: AppModel) {
        let service = model.service
        let options = model.readOptions()
        let settings = target.settings
        let newPassword = needsPassword ? Secret(password) : nil
        let trash = trashOriginals
        for url in archives {
            model.run("Convert \(url.lastPathComponent)", kind: .convert, inputs: [url]) { progress in
                let request = ConvertRequest(archive: url, settings: settings, readOptions: options, newPassword: newPassword,
                                             trashOriginalAfterVerification: trash)
                let o = try service.convert(request, progress: progress)
                return "\(o.created.outputs.first?.lastPathComponent ?? "") — \(o.comparison.identical.count) files verified"
            }
        }
        archives = []
        password = ""
        confirmation = ""
    }
}

// MARK: Batch extract

@MainActor
@Observable
final class BatchTool {
    var archives: [URL] = []
    var destination: URL?
    var folderPerArchive = true
    var skipAlreadyExtracted = true
    private(set) var report: BatchReport?
    private(set) var isRunning = false

    func run(_ model: AppModel) {
        let request = BatchExtractRequest(archives: archives, sharedDestination: destination, folderPerArchive: folderPerArchive,
                                          skipAlreadyExtracted: skipAlreadyExtracted, continueOnError: true,
                                          options: model.extractionOptions(), readOptions: model.readOptions())
        let service = model.service
        report = nil
        isRunning = true
        model.run("Extract \(request.archives.count) archives", kind: .extract, inputs: request.archives,
                  onFinish: { self.isRunning = false }) { progress in
            let r = try service.extractBatch(request, progress: progress)
            Task { @MainActor in self.report = r }
            return "\(r.succeeded) extracted, \(r.skipped) skipped, \(r.failed) failed"
        }
    }
}

// MARK: Checksums

struct ChecksumResult: Identifiable, Sendable {
    let id = UUID()
    let file: URL
    let digest: String
}

@MainActor
@Observable
final class ChecksumTool {
    /// Removing a file from the list removes its result too.
    var files: [URL] = [] { didSet { if files != oldValue { results.removeAll { r in !files.contains(r.file) } } } }
    var algorithm: HashAlgorithm = .sha256
    var expected = ""
    private(set) var results: [ChecksumResult] = []
    private(set) var verification: ChecksumManifest.VerifyResult?
    private(set) var isRunning = false

    func matches(_ r: ChecksumResult) -> Bool? {
        let e = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return e.isEmpty ? nil : e == r.digest.lowercased()
    }

    func calculate(_ model: AppModel) {
        // Folders can be dropped on the list; checksums are for files. (A folder URL doesn't always
        // end in "/", so ask the file system.)
        let list = files.filter { !SafeFileIO.isDirectory($0) }
        let alg = algorithm
        results = []
        isRunning = true
        model.run("Checksums (\(alg.displayName))", kind: .checksum, inputs: list, onFinish: { self.isRunning = false }) { progress in
            var out: [ChecksumResult] = []
            for f in list { out.append(ChecksumResult(file: f, digest: try StreamingHasher.hashFile(at: f, algorithm: alg, progress: progress))) }
            let results = out
            Task { @MainActor in self.results = results.filter { self.files.contains($0.file) } }
            return "\(out.count) file\(out.count == 1 ? "" : "s")"
        }
    }

    func manifestText() throws -> String {
        let list = files.filter { !SafeFileIO.isDirectory($0) }
        guard let base = list.first?.deletingLastPathComponent() else { throw ArchiveError.invalidArgument("Choose files first. Checksum files list files, not folders.") }
        return try ChecksumManifest.generate(for: list, base: base, algorithm: algorithm)
    }

    var manifestFileName: String { "checksums.\(algorithm.manifestExtension)" }

    func verify(manifest: URL, model: AppModel) async {
        verification = nil
        switch await offMain({ try ChecksumManifest.verify(manifest: manifest) }) {
        case .success(let v): verification = v
        case .failure(let e): model.present(e, context: "Verify checksums")
        }
    }
}

// MARK: Split & join

@MainActor
@Observable
final class SplitJoinTool {
    var partSize = "100 MB"

    var isValidSize: Bool { FileSplitter.parseSize(partSize) != nil }

    func split(_ file: URL, model: AppModel) {
        guard let size = FileSplitter.parseSize(partSize) else { return }
        let platform = model.platform
        model.run("Split \(file.lastPathComponent)", kind: .split, inputs: [file]) { progress in
            let r = try FileSplitter.split(file, partSize: size, progress: progress)
            let parts = r.parts
            Task { @MainActor in platform.reveal(parts) }
            return "\(r.parts.count) parts"
        }
    }

    func join(_ firstPart: URL, model: AppModel) {
        let platform = model.platform
        model.run("Join \(firstPart.lastPathComponent)", kind: .join, inputs: [firstPart]) { progress in
            let r = try FileSplitter.join(firstPart: firstPart, progress: progress)
            let output = r.output
            Task { @MainActor in platform.reveal([output]) }
            return r.matchedManifest == true ? "Joined and verified" : "Joined (no checksum file to verify against)"
        }
    }
}

// MARK: Compare

@MainActor
@Observable
final class CompareTool {
    /// Changing either side clears a result that no longer describes them.
    var left: URL? { didSet { if left != oldValue { result = nil } } }
    var right: URL? { didSet { if right != oldValue { result = nil } } }
    var compareContents = false
    private(set) var result: ArchiverKit.ComparisonResult?
    private(set) var isRunning = false

    func run(_ model: AppModel) {
        guard let a = left, let b = right else { return }
        let service = model.service
        let options = model.readOptions()
        let mode: ComparisonMode = compareContents ? .content : .metadata
        result = nil
        isRunning = true
        model.run("Compare archives", kind: .compare, inputs: [a, b], onFinish: { self.isRunning = false }) { progress in
            let r = try service.compare(a, b, mode: mode, leftOptions: options, rightOptions: options, progress: progress)
            Task { @MainActor in if self.left == a, self.right == b { self.result = r } }
            return r.isIdentical ? "Identical" : "\(r.added.count + r.removed.count + r.modified.count) differences"
        }
    }
}

// MARK: Duplicates

@MainActor
@Observable
final class DuplicatesTool {
    var archives: [URL] = []
    private(set) var groups: [DuplicateGroup] = []
    private(set) var isRunning = false

    func run(_ model: AppModel) {
        let list = archives
        let service = model.service
        let options = model.readOptions()
        groups = []
        isRunning = true
        model.run("Find duplicates", kind: .compare, inputs: list, onFinish: { self.isRunning = false }) { progress in
            let g = try service.findDuplicates(in: list, options: options, progress: progress)
            Task { @MainActor in self.groups = g.sorted { $0.wastedBytes > $1.wastedBytes } }
            return "\(g.count) group\(g.count == 1 ? "" : "s") of duplicates"
        }
    }

    var reportText: String {
        groups.map { g in
            "\(g.sha256)  \(g.size) bytes\n" + g.members.map { "  \($0.archive): \($0.path)" }.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
