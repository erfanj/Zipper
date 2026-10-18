import Foundation
import ArchiveCore
import ArchiveEngines
import ArchiverKit

/// Archive operations shared by the toolbar, context menus, menu-bar commands, Finder services
/// and the extract sheet.
extension AppModel {
    // MARK: Extract

    /// Extracts with the user's defaults (Finder's double-click, "Extract" in the toolbar).
    func quickExtract(_ archive: URL) {
        noteRecent(archive)
        extract(archive: archive, destination: defaultExtractionDestination, mode: settings.extractionMode)
    }

    func extract(archive: URL, destination: URL?, mode: ExtractionMode, selection: EntrySelection = .all,
                 conflict: ConflictPolicy? = nil, verify: Bool? = nil, nested: Bool? = nil, trashAfter: Bool = false,
                 reveal: Bool? = nil, allowMount: Bool = false) {
        let request = ExtractRequest(archive: archive, destination: destination, mode: mode, selection: selection,
                                     options: extractionOptions(conflictPolicy: conflict), readOptions: readOptions(allowMountingDiskImages: allowMount),
                                     extractNestedArchives: nested ?? settings.extractNestedArchives,
                                     verifyAfterExtraction: verify ?? settings.verifyAfterExtraction,
                                     trashArchiveAfterVerification: trashAfter)
        let service = self.service
        let platform = self.platform
        let shouldReveal = reveal ?? settings.revealAfterExtraction
        run("Extract \(archive.lastPathComponent)", kind: .extract, inputs: [archive]) { progress in
            let o = try service.extract(request, progress: progress)
            if shouldReveal, !o.createdItems.isEmpty {
                let items = o.createdItems
                Task { @MainActor in platform.reveal(items) }
            }
            var summary = "\(o.report.filesWritten) file\(o.report.filesWritten == 1 ? "" : "s") extracted"
            if !o.report.blocked.isEmpty { summary += " · \(o.report.blocked.count) unsafe item(s) blocked" }
            if let v = o.verification { summary += v.passed ? " · verified" : " · verification found problems" }
            if !o.trashed.isEmpty { summary += " · archive moved to the Trash" }
            return summary
        }
    }

    /// Extracts the browser's selection (everything when nothing is selected).
    func extract(from state: BrowserState, to destination: URL?) {
        let paths = state.selectedPaths
        extract(archive: state.url, destination: destination ?? defaultExtractionDestination,
                mode: paths.isEmpty ? settings.extractionMode : .here,
                selection: paths.isEmpty ? .all : .paths(Set(paths)))
    }

    // MARK: Test

    func test(_ state: BrowserState) {
        let service = self.service
        let url = state.url
        let options = readOptions()
        state.isTesting = true
        run("Test \(url.lastPathComponent)", kind: .test, inputs: [url], onFinish: { state.isTesting = false }) { progress in
            let r = try service.test(url, options: options, progress: progress)
            Task { @MainActor in state.integrity = r }
            return "\(r.result.rawValue.capitalized): \(r.filesVerified) of \(r.filesInspected) files verified"
        }
    }

    // MARK: Edit (transactional: rebuilt, verified, then swapped in)

    func edit(_ state: BrowserState, _ edits: [ArchiveEdit], title: String) {
        let service = self.service
        let request = ModifyRequest(archive: state.url, edits: edits, readOptions: readOptions())
        run("\(title) in \(state.displayName)", kind: .modify, inputs: [state.url], onSuccess: { [weak self] _ in
            guard let self else { return }
            state.load(using: self)
        }) { progress in
            let o = try service.modify(request, progress: progress)
            return "Archive updated and verified (\(o.entryCount) items)"
        }
    }

    func add(_ urls: [URL], to state: BrowserState) {
        guard !urls.isEmpty else { return }
        edit(state, [.add(files: urls, toFolder: state.currentFolder)], title: urls.count == 1 ? "Add “\(urls[0].lastPathComponent)”" : "Add \(urls.count) items")
    }

    func deleteSelection(in state: BrowserState) {
        let paths = state.selectedPaths
        guard !paths.isEmpty else { return }
        state.selection = []
        edit(state, [.delete(paths: paths)], title: paths.count == 1 ? "Delete “\((paths[0] as NSString).lastPathComponent)”" : "Delete \(paths.count) items")
    }

    func rename(_ row: BrowserRow, to newName: String, in state: BrowserState) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != row.name, !name.contains("/") else { return }
        edit(state, [.rename(path: row.path, newName: name)], title: "Rename “\(row.name)”")
    }

    func createFolder(named name: String, in state: BrowserState) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !n.contains("/") else { return }
        edit(state, [.createFolder(path: ArchivePath.join(state.currentFolder, n))], title: "New folder “\(n)”")
    }

    // MARK: Opening entries

    /// Extracts one entry to the private preview folder (for Quick Look, opening or dragging out).
    func previewFile(for row: BrowserRow, in state: BrowserState) async -> Result<URL, ArchiveError> {
        let service = self.service
        let options = readOptions()
        let url = state.url
        let path = row.path
        return await offMain { try service.extractForPreview(url, entryPath: path, options: options) }
    }

    /// Double-click: folders open in place, nested archives open in Zipper, documents open in their
    /// default app. Apps and scripts are never run: they are revealed in Finder instead.
    func open(_ row: BrowserRow, in state: BrowserState) {
        if row.isFolder {
            state.open(folder: row.path)
            return
        }
        Task {
            switch await previewFile(for: row, in: state) {
            case .success(let file):
                if isArchive(file) {
                    openArchive(file)
                } else if ExecutableContent.isPotentiallyExecutable(path: file.path, permissions: nil, header: []) {
                    platform.reveal([file])
                } else {
                    platform.open(file)
                }
            case .failure(let e):
                present(e, context: "Open “\(row.name)”")
            }
        }
    }

    /// Opens an entry in its default app and offers to update the archive when it is saved.
    func editExternally(_ row: BrowserRow, in state: BrowserState, onChange: @escaping @MainActor (ExternalEditSession) -> Void) {
        guard !row.isFolder else { return }
        let service = self.service
        let archive = state.url
        let options = readOptions()
        let path = row.path
        Task {
            let r = await offMain { try ExternalEditSession(service: service, archive: archive, entryPath: path, readOptions: options) }
            switch r {
            case .success(let session):
                state.editSessions[path]?.discard()
                state.editSessions[path] = session
                platform.open(session.fileURL)
                watch(session, in: state, onChange: onChange)
            case .failure(let e):
                present(e, context: "Edit “\(row.name)”")
            }
        }
    }

    /// Watches the temporary copy and calls `onChange` once per save (not repeatedly while it stays
    /// changed, so "Not Now" really means not now). Stops when the session ends or the archive closes.
    private func watch(_ session: ExternalEditSession, in state: BrowserState, onChange: @escaping @MainActor (ExternalEditSession) -> Void) {
        let file = session.fileURL
        func modified() -> Date? { (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date }
        Task {
            var lastSeen = modified()
            while state.editSessions[session.entryPath] === session {
                try? await Task.sleep(for: .seconds(1.5))
                guard state.editSessions[session.entryPath] === session else { return }
                let now = modified()
                guard now != lastSeen else { continue }
                lastSeen = now
                if case .success(true) = await offMain({ session.hasChanges() }) { onChange(session) }
            }
        }
    }

    func commit(_ session: ExternalEditSession, in state: BrowserState) {
        let service = self.service
        let options = readOptions()
        run("Update \(state.displayName)", kind: .modify, inputs: [state.url], onSuccess: { [weak self] _ in
            guard let self else { return }
            state.load(using: self)
        }) { _ in
            let o = try session.commit(using: service, readOptions: options)
            return "Updated “\((session.entryPath as NSString).lastPathComponent)” (\(o.verification.result.rawValue))"
        }
    }

    func stopEditing(_ session: ExternalEditSession, in state: BrowserState) {
        session.discard()
        state.editSessions[session.entryPath] = nil
    }
}
