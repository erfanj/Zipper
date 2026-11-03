#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore
import ArchiverKit

// MARK: Icons

/// Finder icons for archive rows, cached per file type (looking them up per row is slow).
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for row: BrowserRow) -> NSImage {
        if row.isFolder { return folder }
        let ext = (row.name as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache[ext] = image
        return image
    }

    static let folder = NSWorkspace.shared.icon(for: .folder)

    static func icon(forFile url: URL) -> NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

// MARK: Passwords

/// New-password entry: confirmation, show/hide, strength meter and a generator.
struct NewPasswordFields: View {
    @Binding var password: String
    @Binding var confirmation: String
    @State private var reveal = false

    var body: some View {
        Group {
            HStack {
                if reveal {
                    TextField("Password", text: $password)
                } else {
                    SecureField("Password", text: $password)
                }
                Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                    .help(reveal ? "Hide password" : "Show password")
                    .accessibilityLabel(reveal ? "Hide password" : "Show password")
            }
            if !reveal {
                SecureField("Confirm", text: $confirmation)
            }
            LabeledContent("Strength") {
                StrengthMeter(password: password).frame(maxWidth: 220)
            }
            HStack {
                Button("Suggest Strong Password") {
                    password = PasswordGenerator.generate(length: 20)
                    confirmation = password
                    reveal = true
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(password, forType: .string)
                }
                .disabled(password.isEmpty)
                .help("Copy the password so you can share it separately from the archive")
            }
            .controlSize(.small)
        }
        .onChange(of: password) { _, new in if reveal { confirmation = new } }
        // While the password is shown there's no Confirm field: what you see is what you get. Without
        // this, a mismatch typed before showing it left "The passwords don't match" with no field to fix.
        .onChange(of: reveal) { _, shown in if shown { confirmation = password } }
    }
}

struct StrengthMeter: View {
    let password: String

    var body: some View {
        let s = PasswordStrength.evaluate(password)
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(i <= s.rating.rawValue && !password.isEmpty ? color(s.rating) : Color.secondary.opacity(0.2))
                        .frame(height: 4)
                }
            }
            Text(password.isEmpty ? "—" : s.rating.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
        }
        .help(s.feedback.joined(separator: " "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(password.isEmpty ? "empty" : s.rating.label)")
    }

    private func color(_ r: PasswordStrength.Rating) -> Color {
        switch r {
        case .veryWeak: return .red
        case .weak: return .orange
        case .fair: return .yellow
        case .strong: return .green
        case .veryStrong: return .mint
        }
    }
}

// MARK: Feedback

struct ErrorBanner: View {
    let error: ArchiveError
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(error.explanation)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(error.suggestions, id: \.self) { s in
                Text("• " + s).font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("Details", isExpanded: $showDetails) {
                Text("Code: \(error.code)\n\(String(describing: error))")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A large empty-state message with an icon, like Finder's and Mail's.
struct EmptyStateView: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}

// MARK: Choosers

/// "Destination: [folder] Choose…" row used by the sheets and tools.
struct DestinationRow: View {
    let label: String
    let url: URL?
    let placeholder: String
    let onChange: (URL?) -> Void

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Image(nsImage: url.map(FileIcons.icon(forFile:)) ?? FileIcons.folder)
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(url?.lastPathComponent ?? placeholder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url?.path(percentEncoded: false) ?? placeholder)
                Spacer(minLength: 4)
                Button("Choose…") {
                    if let u = Panels.chooseFolder(prompt: "Choose", directory: url) { onChange(u) }
                }
                if url != nil {
                    Button { onChange(nil) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help("Use the default location")
                        .accessibilityLabel("Use the default location")
                }
            }
        }
    }
}

/// A list of chosen files with Add and Remove, accepting drops. Used by the tools.
struct FileListBox: View {
    @Binding var urls: [URL]
    var prompt = "Drop archives here or click Add."
    var multiple = true
    var chooseFolders = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if urls.isEmpty {
                Text(prompt)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ForEach(urls, id: \.self) { u in
                    HStack(spacing: 8) {
                        Image(nsImage: FileIcons.icon(forFile: u)).resizable().frame(width: 16, height: 16)
                        Text(u.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { urls.removeAll { $0 == u } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove from the list")
                            .accessibilityLabel("Remove \(u.lastPathComponent)")
                    }
                    .padding(.vertical, 3)
                }
            }
            Divider().padding(.vertical, 6)
            HStack {
                Button(multiple ? "Add…" : "Choose…") { choose() }
                if !urls.isEmpty, multiple { Button("Remove All") { urls = [] } }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(targeted ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.3)))
        .dropDestination(for: URL.self) { dropped, _ in
            urls = multiple ? urls + dropped.filter { !urls.contains($0) } : Array(dropped.prefix(1))
            return !dropped.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private func choose() {
        let picked = chooseFolders ? Panels.chooseItemsToCompress() : (multiple ? Panels.chooseFiles() : Panels.chooseFiles(multiple: false))
        guard let picked else { return }
        urls = multiple ? urls + picked.filter { !urls.contains($0) } : Array(picked.prefix(1))
    }
}

/// Monospaced, selectable report text (integrity, recovery, batch reports).
struct ReportText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif
