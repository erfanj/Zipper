import Foundation
import Observation
import ArchiveCore
import ArchiverKit

/// State and rules of the "Extract" sheet.
@MainActor
@Observable
final class ExtractForm {
    // Strong on purpose: a form never outlives its sheet, and the model clears `sheet` when it closes.
    @ObservationIgnored private let model: AppModel

    let archive: URL
    private(set) var opened: OpenedArchive?
    private(set) var loadError: ArchiveError?
    private(set) var isLoading = false
    private(set) var isDiskImage = false
    private(set) var freeSpace: UInt64?
    /// Apps, scripts and programs in the archive (they are never opened automatically).
    private(set) var executableCount = 0
    /// Where to extract; nil means next to the archive. Change it with `setDestination(_:)`.
    private(set) var destination: URL?
    var mode: ExtractionMode
    var conflict: ConflictPolicy
    var revealWhenDone: Bool
    var verify: Bool
    var extractNested: Bool
    var trashAfter = false
    var allowMount = false

    init(archive: URL, model: AppModel) {
        self.model = model
        self.archive = archive
        let s = model.settings
        mode = s.extractionMode
        conflict = s.conflictPolicy == .ask ? .ask : s.conflictPolicy
        revealWhenDone = s.revealAfterExtraction
        verify = s.verifyAfterExtraction
        extractNested = s.extractNestedArchives
        destination = model.defaultExtractionDestination
    }

    func setDestination(_ url: URL?) {
        destination = url
        refreshFreeSpace()
    }

    var effectiveDestination: URL { destination ?? archive.deletingLastPathComponent() }

    /// Reads the listing (without asking for a password: encrypted names are reported, and the
    /// password is requested once, when extraction starts).
    func load() async {
        isLoading = true
        let url = archive
        let service = model.service
        let r = await offMain { () -> (OpenedArchive?, ArchiveError?, Bool, Int) in
            let isDMG = (try? FormatDetector.detect(url))?.format == .dmg
            do {
                let o = try service.open(url, options: ReadOptions())
                let executables = o.listing.entries.filter {
                    ExecutableContent.isPotentiallyExecutable(path: $0.normalizedPath, permissions: $0.permissions, header: [])
                }.count
                return (o, nil, isDMG, executables)
            } catch {
                return (nil, ArchiveError.wrap(error), isDMG, 0)
            }
        }
        isLoading = false
        if case .success(let (o, e, dmg, executables)) = r {
            opened = o
            loadError = e
            isDiskImage = dmg
            executableCount = executables
        }
        refreshFreeSpace()
    }

    private func refreshFreeSpace() {
        let dir = effectiveDestination
        #if os(macOS)
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        freeSpace = v.map { UInt64(max(0, $0)) }
        #else
        freeSpace = nil
        #endif
    }

    var needsPassword: Bool {
        if opened?.listing.properties.hasEncryptedEntries == true { return true }
        switch loadError {
        case .passwordRequired?, .incorrectPassword?: return true
        default: return false
        }
    }

    /// Not enough space for the uncompressed contents (when the size is known).
    var spaceWarning: String? {
        guard let free = freeSpace, let need = opened?.listing.totalUncompressedSize, need > free else { return nil }
        return "Not enough free space: needs \(ByteFormatting.string(need)), \(ByteFormatting.string(free)) available."
    }

    /// Extraction is still attempted when listing failed for a reason extraction may not share
    /// (a missing password, or an engine that can extract but not list); hopeless cases are blocked.
    var canExtract: Bool {
        guard !isLoading else { return false }
        switch loadError {
        case .notAnArchive?, .fileNotFound?, .missingVolume?, .unsupportedFormat?, .noEngineAvailable?: return false
        default: return true
        }
    }

    func start() {
        model.extract(archive: archive, destination: destination, mode: mode, conflict: conflict,
                      verify: verify, nested: extractNested, trashAfter: trashAfter && verify,
                      reveal: revealWhenDone, allowMount: allowMount)
    }
}
