#if os(macOS)
import AppKit
import UserNotifications
import ArchiveCore
import ArchiverKit

/// AppKit implementation of the model's platform needs: native alerts for prompts and errors,
/// user notifications, the Dock tile and Finder.
@MainActor
final class MacPlatform: PlatformServices {
    private var dockProgress: NSProgressIndicator?

    // MARK: Prompts

    func askPassword(for archive: URL, reason: PasswordRequestReason, offerToRemember: Bool) -> PasswordAnswer? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let name = archive.lastPathComponent
        if reason == .previousAttemptIncorrect {
            alert.messageText = "The password for “\(name)” is incorrect."
            alert.informativeText = "Check the password and try again."
        } else {
            alert.messageText = "“\(name)” is protected with a password."
            alert.informativeText = "Enter the password to continue. For multi-part archives, the same password is used for every part."
        }
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Password"
        field.contentType = .password
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if offerToRemember {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember this password in my keychain"
            alert.suppressionButton?.state = .off
        }
        alert.layout()
        alert.window.initialFirstResponder = field
        NSApp.activate()
        let response = alert.runModal()
        let text = field.stringValue
        field.stringValue = ""
        guard response == .alertFirstButtonReturn, !text.isEmpty else { return nil }
        return PasswordAnswer(secret: Secret(text), remember: alert.suppressionButton?.state == .on)
    }

    func askConflict(_ info: ConflictInfo) -> ConflictAnswer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let name = (info.existingPath as NSString).lastPathComponent
        alert.messageText = info.existingIsDirectory
            ? "A folder named “\(name)” already exists in this location."
            : "An item named “\(name)” already exists in this location."
        func describe(_ size: UInt64?, _ date: Date?) -> String {
            [size.map(ByteFormatting.string), date.map { $0.formatted(date: .abbreviated, time: .shortened) }].compactMap { $0 }.joined(separator: ", ")
        }
        var details = [String]()
        let existing = describe(info.existingSize, info.existingModified)
        let incoming = describe(info.entrySize, info.entryModified)
        if !existing.isEmpty { details.append("Existing: \(existing)") }
        if !incoming.isEmpty { details.append("From the archive: \(incoming)") }
        details.append(info.existingIsDirectory ? "Folders are merged; nothing in the existing folder is deleted." : "“Keep Both” saves the new item with a number added to its name.")
        alert.informativeText = details.joined(separator: "\n")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: info.existingIsDirectory ? "Merge" : "Replace")
        alert.addButton(withTitle: "Skip")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all"
        NSApp.activate()
        let decision: ConflictDecision
        switch alert.runModal() {
        case .alertSecondButtonReturn: decision = .replace
        case .alertThirdButtonReturn: decision = .skip
        default: decision = .keepBoth
        }
        return ConflictAnswer(decision: decision, applyToAll: alert.suppressionButton?.state == .on)
    }

    func showError(_ error: ArchiveError, context: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error.title
        var text = error.explanation
        if !error.suggestions.isEmpty { text += "\n\n" + error.suggestions.map { "• " + $0 }.joined(separator: "\n") }
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Details")
        if alert.runModal() == .alertSecondButtonReturn {
            let details = "\(context)\n\(error.title)\n\(error.explanation)\nCode: \(error.code)\n\(String(describing: error))"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(details, forType: .string)
        }
    }

    // MARK: Notifications

    /// Permission is requested the first time an operation finishes in the background, not at
    /// launch, so the request makes sense to the user when it appears.
    func notify(title: String, body: String) {
        // UNUserNotificationCenter requires a real app bundle (it traps when run from `swift run`).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        // The request is built inside the callback: the notification classes aren't Sendable, so
        // only the two strings cross into it.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    var isAppActive: Bool { NSApp.isActive }

    // MARK: Dock

    func updateDockProgress(fraction: Double?, activeCount: Int) {
        let tile = NSApp.dockTile
        guard activeCount > 0 else {
            if dockProgress != nil || tile.badgeLabel != nil {
                tile.contentView = nil
                tile.badgeLabel = nil
                dockProgress = nil
                tile.display()
            }
            return
        }
        if dockProgress == nil {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
            let icon = NSImageView(frame: container.bounds)
            icon.image = NSApp.applicationIconImage
            let bar = NSProgressIndicator(frame: NSRect(x: 14, y: 10, width: 100, height: 14))
            bar.style = .bar
            bar.minValue = 0
            bar.maxValue = 1
            container.addSubview(icon)
            container.addSubview(bar)
            tile.contentView = container
            dockProgress = bar
        }
        if let fraction {
            dockProgress?.isIndeterminate = false
            dockProgress?.doubleValue = fraction
        } else {
            dockProgress?.isIndeterminate = true
        }
        tile.badgeLabel = activeCount > 1 ? "\(activeCount)" : nil
        tile.display()
    }

    // MARK: Finder

    func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func noteRecentDocument(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
}

/// Standard open and save panels.
@MainActor
enum Panels {
    static func chooseItemsToCompress(prompt: String = "Choose") -> [URL]? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = prompt
        p.message = "Choose the files and folders to put in the archive."
        return p.runModal() == .OK ? p.urls : nil
    }

    static func chooseArchive(prompt: String = "Open", message: String = "Choose an archive.") -> URL? {
        chooseArchives(prompt: prompt, message: message, multiple: false)?.first
    }

    static func chooseArchives(prompt: String = "Choose", message: String = "Choose archives.", multiple: Bool = true) -> [URL]? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = multiple
        p.prompt = prompt
        p.message = message
        return p.runModal() == .OK ? p.urls : nil
    }

    static func chooseFiles(prompt: String = "Choose", message: String? = nil, multiple: Bool = true) -> [URL]? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = multiple
        p.prompt = prompt
        if let message { p.message = message }
        return p.runModal() == .OK ? p.urls : nil
    }

    static func chooseFolder(prompt: String = "Choose", message: String? = nil, directory: URL? = nil) -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = prompt
        if let message { p.message = message }
        if let directory { p.directoryURL = directory }
        return p.runModal() == .OK ? p.url : nil
    }

    /// Saves text chosen by the user; returns false when cancelled or the write failed.
    @discardableResult
    static func save(text: String, suggestedName: String) -> Bool {
        save(data: Data(text.utf8), suggestedName: suggestedName)
    }

    @discardableResult
    static func save(data: Data, suggestedName: String) -> Bool {
        let p = NSSavePanel()
        p.nameFieldStringValue = suggestedName
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }
}
#endif
