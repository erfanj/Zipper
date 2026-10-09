import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import ArchiveCore
import ArchiveEngines

/// Quick Look preview for archives (Space bar in Finder): format, file count, sizes, encryption and
/// the folder hierarchy — without launching the app and without extracting anything.
///
/// Archives whose file names are encrypted are shown as such; the names are never revealed.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let html = Self.render(url)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 640, height: 720)) { _ in Data(html.utf8) }
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func render(_ url: URL) -> String {
        var body = "<h2>\(esc(url.lastPathComponent))</h2>"
        do {
            guard let d = try FormatDetector.detect(url) else { return page(body + "<p>Not a recognised archive.</p>") }
            // In-process engine only: the extension is sandboxed and never starts helper processes.
            let engine = LibArchiveEngine()
            let listing = try engine.list(d.source(for: url), options: ReadOptions(), progress: OperationProgress())
            let size = d.source(for: url).totalSize
            body += "<p class=meta>\(esc(FormatCatalog.descriptor(for: d.format)?.name ?? d.format.rawValue)) · \(listing.fileCount) files · \(listing.directoryCount) folders · "
            body += "\(listing.totalUncompressedSize.map(ByteFormatting.string) ?? "unknown size") uncompressed · \(ByteFormatting.string(size)) on disk"
            if listing.properties.hasEncryptedEntries == true { body += " · 🔒 encrypted" }
            body += "</p><table>"
            for e in listing.entries.prefix(2000) {
                let depth = e.normalizedPath.split(separator: "/").count - 1
                let icon = e.type == .directory ? "📁" : (e.isEncrypted ? "🔒" : "📄")
                body += "<tr><td style='padding-left:\(depth * 16)px'>\(icon) \(esc(e.name))</td><td class=num>\(e.type == .directory ? "" : (e.uncompressedSize.map(ByteFormatting.string) ?? ""))</td></tr>"
            }
            if listing.entries.count > 2000 { body += "<tr><td>… \(listing.entries.count - 2000) more</td></tr>" }
            body += "</table>"
        } catch let e as ArchiveError {
            switch e {
            case .passwordRequired, .incorrectPassword, .unsupportedEncryption:
                body += "<p>🔒 This archive is encrypted, including its file names. Open it in Universal Archiver to enter the password.</p>"
            default:
                body += "<p>\(esc(e.explanation))</p>"
            }
        } catch {
            body += "<p>\(esc(error.localizedDescription))</p>"
        }
        return page(body)
    }

    static func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; } body { font: 13px -apple-system, sans-serif; margin: 16px; }
        .meta { color: #888; } table { border-collapse: collapse; width: 100%; } td { padding: 2px 4px; }
        .num { text-align: right; color: #888; font-variant-numeric: tabular-nums; white-space: nowrap; }
        </style></head><body>\(body)</body></html>
        """
    }
}
