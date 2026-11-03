#if os(macOS)
import AppKit
import ArchiveCore
import ArchiverKit

/// Finder Quick Actions and Services (declared under NSServices in Info.plist). Each method receives
/// the selected files on a pasteboard. Nothing destructive happens without the app's own UI.
@MainActor
final class ServicesProvider: NSObject {
    private func urls(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private var model: AppModel? { AppDelegate.model }

    private func compress(_ pb: NSPasteboard, format: FormatID) {
        let items = urls(pb)
        guard let model, !items.isEmpty else { return }
        let form = CompressForm(items: items, model: model)
        form.format = format
        // Quick Actions use the everyday settings; only the format differs.
        if form.canCreate {
            form.start()
        } else {
            NSApp.activate()
            model.openWindow?("main")
            model.sheet = .compress(form)
        }
    }

    @objc func compressToZip(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        compress(pb, format: .zip)
    }

    @objc func compressTo7z(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        compress(pb, format: .sevenZip)
    }

    @objc func compressWithOptions(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let items = urls(pb)
        guard let model, !items.isEmpty else { return }
        NSApp.activate()
        model.openWindow?("main")
        model.beginCompress(items)
    }

    private func extract(_ pb: NSPasteboard, mode: ExtractionMode, askForDestination: Bool) {
        let archives = ArchiveService.distinctArchives(urls(pb))
        guard let model, !archives.isEmpty else { return }
        var destination = model.defaultExtractionDestination
        if askForDestination {
            NSApp.activate()
            guard let d = Panels.chooseFolder(prompt: "Extract", directory: archives[0].deletingLastPathComponent()) else { return }
            destination = d
        }
        for archive in archives {
            model.noteRecent(archive)
            model.extract(archive: archive, destination: destination, mode: mode)
        }
    }

    @objc func extractHere(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        extract(pb, mode: .smart, askForDestination: false)
    }

    @objc func extractToFolder(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        extract(pb, mode: .newFolder, askForDestination: false)
    }

    @objc func extractTo(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        extract(pb, mode: .smart, askForDestination: true)
    }

    @objc func previewArchive(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let items = urls(pb)
        guard let model else { return }
        NSApp.activate()
        model.openWindow?("main")
        for item in items { model.openArchive(item) }
    }

    @objc func testArchive(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let items = urls(pb)
        guard let model, !items.isEmpty else { return }
        NSApp.activate()
        model.showTool(.test, input: items)
    }

    @objc func convertArchive(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let items = urls(pb)
        guard let model else { return }
        NSApp.activate()
        model.showTool(.convert, input: items)
    }

    @objc func calculateSHA256(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let files = urls(pb).filter { !$0.hasDirectoryPath }
        guard let model, !files.isEmpty else { return }
        NSApp.activate()
        model.showTool(.checksums, input: files)
    }
}
#endif
