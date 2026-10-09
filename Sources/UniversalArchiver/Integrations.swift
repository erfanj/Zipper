#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ArchiveCore
import ArchiveEngines
import ArchiverKit

/// Finder Quick Actions / Services (declared under NSServices in Info.plist). Each method receives
/// the selected files on the pasteboard. Destructive actions are never performed without the UI.
final class ServicesProvider: NSObject {
    private func urls(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @MainActor private var model: AppModel? { AppDelegate.model }

    private func compress(_ pb: NSPasteboard, format: FormatID) {
        let items = urls(pb)
        Task { @MainActor in
            guard let model, !items.isEmpty else { return }
            var s = model.allPresets.first { $0.id == model.settings.defaultPresetID }?.settings ?? CompressionSettings()
            s.format = format
            if format == .sevenZip { s.method = .lzma2 } else if format == .zip { s.method = .deflate }
            let request = CompressRequest(items: items, settings: s, verifyAfterCreation: model.settings.verifyAfterCompression)
            let service = model.service
            model.run("Compress \(items.count == 1 ? items[0].lastPathComponent : "\(items.count) items")", kind: .compress, inputs: items) { p in
                let o = try service.compress(request, progress: p)
                return o.archives.flatMap(\.outputs).map(\.lastPathComponent).joined(separator: ", ")
            }
        }
    }

    @objc func compressToZip(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { compress(pb, format: .zip) }
    @objc func compressTo7z(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { compress(pb, format: .sevenZip) }

    @objc func compressWithOptions(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let items = urls(pb)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            model?.pendingCompression = items
            model?.selection = .compress
        }
    }

    private func extract(_ pb: NSPasteboard, mode: ExtractionMode, ask: Bool) {
        let archives = ArchiveService.distinctArchives(urls(pb))
        Task { @MainActor in
            guard let model else { return }
            var dest: URL?
            if ask {
                NSApp.activate(ignoringOtherApps: true)
                guard let d = FolderPicker.choose(prompt: "Extract", directory: archives.first?.deletingLastPathComponent()) else { return }
                dest = d
            }
            for a in archives {
                let req = ExtractRequest(archive: a, destination: dest, mode: mode, options: model.extractionOptions(), readOptions: model.readOptions(),
                                         verifyAfterExtraction: model.settings.verifyAfterExtraction)
                let service = model.service
                let reveal = model.settings.openDestinationAfterExtraction
                model.run("Extract \(a.lastPathComponent)", kind: .extract, inputs: [a]) { p in
                    let o = try service.extract(req, progress: p)
                    if reveal { DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(o.createdItems) } }
                    return "\(o.report.filesWritten) files"
                }
            }
        }
    }

    @objc func extractHere(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { extract(pb, mode: .smart, ask: false) }
    @objc func extractToFolder(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { extract(pb, mode: .newFolder, ask: false) }
    @objc func extractTo(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) { extract(pb, mode: .smart, ask: true) }

    @objc func previewArchive(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let items = urls(pb)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            for u in items { model?.openArchive(u) }
        }
    }

    @objc func testArchive(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let items = urls(pb)
        Task { @MainActor in
            guard let model else { return }
            let service = model.service
            let options = model.readOptions()
            for u in items {
                model.run("Test \(u.lastPathComponent)", kind: .test, inputs: [u]) { p in
                    let r = try service.test(u, options: options, progress: p)
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "\(u.lastPathComponent): \(r.result.rawValue)"
                        alert.informativeText = r.textSummary
                        alert.runModal()
                    }
                    return r.result.rawValue
                }
            }
        }
    }

    @objc func convertArchive(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            model?.selection = .convert
        }
    }

    @objc func calculateSHA256(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = urls(pb).filter { !$0.hasDirectoryPath }
        Task.detached {
            let lines = files.map { f in "\((try? StreamingHasher.hashFile(at: f, algorithm: .sha256)) ?? "error")  \(f.lastPathComponent)" }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                let alert = NSAlert()
                alert.messageText = "SHA-256 (copied to the clipboard)"
                alert.informativeText = lines.joined(separator: "\n")
                alert.runModal()
            }
        }
    }
}

/// Lets the user make Universal Archiver the default app for common archive types — only when asked.
@MainActor
enum DefaultAppRegistration {
    static let types: [UTType] = [
        .zip, UTType("org.7-zip.7-zip-archive"), UTType("com.rarlab.rar-archive"), UTType("public.tar-archive"), .gzip,
        UTType("org.tukaani.xz-archive"), UTType("public.bzip2-archive"), UTType("org.facebook.zstandard-archive"),
    ].compactMap { $0 }

    static func makeDefault(report: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Open ZIP, 7z, RAR, TAR, gzip, XZ, bzip2 and Zstandard files with \(ProductInfo.name)?"
        alert.informativeText = "You can change this later in Finder › Get Info › Open with."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let app = Bundle.main.bundleURL
        var done = 0
        let group = DispatchGroup()
        for t in types {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: t) { error in
                if error == nil { done += 1 }
                group.leave()
            }
        }
        group.notify(queue: .main) { report("\(ProductInfo.name) now opens \(done) archive type(s) by default.") }
    }
}
#endif
