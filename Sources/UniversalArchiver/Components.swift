#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore
import ArchiveEngines
import ArchiverKit

// MARK: Panels

@MainActor
enum FilePicker {
    static func chooseItems(prompt: String) -> [URL]? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = prompt
        return p.runModal() == .OK ? p.urls : nil
    }

    static func chooseArchive(multiple: Bool = false) -> URL? {
        chooseArchives(multiple: false)?.first
    }

    static func chooseArchives(multiple: Bool = true) -> [URL]? {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = multiple
        p.prompt = "Open"
        p.message = "Choose an archive"
        return p.runModal() == .OK ? p.urls : nil
    }
}

@MainActor
enum FolderPicker {
    static func choose(prompt: String, message: String? = nil, directory: URL? = nil) -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = prompt
        if let message { p.message = message }
        if let directory { p.directoryURL = directory }
        return p.runModal() == .OK ? p.url : nil
    }
}

@MainActor
enum ExportPanel {
    static func save(text: String, name: String) {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        if p.runModal() == .OK, let url = p.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    static func save(data: Data, name: String) {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        if p.runModal() == .OK, let url = p.url { try? data.write(to: url) }
    }
}

// MARK: Passwords

/// Password entry with confirmation, show/hide, strength meter, generator and copy.
struct NewPasswordFields: View {
    @Binding var password: String
    @Binding var confirmation: String
    @State private var reveal = false
    @State private var length = 20.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Group {
                    if reveal { TextField("Password", text: $password) } else { SecureField("Password", text: $password) }
                }
                .textContentType(.newPassword)
                Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless).help(reveal ? "Hide password" : "Show password")
                    .accessibilityLabel(reveal ? "Hide password" : "Show password")
            }
            if !reveal {
                SecureField("Confirm password", text: $confirmation)
                if !confirmation.isEmpty, confirmation != password {
                    Label("The passwords don't match.", systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.caption)
                }
            }
            StrengthMeter(password: password)
                .onChange(of: password) { _, new in if reveal { confirmation = new } }
            HStack {
                Button("Generate Strong Password") {
                    password = PasswordGenerator.generate(length: Int(length))
                    confirmation = password
                    reveal = true
                }
                Stepper("\(Int(length)) characters", value: $length, in: 12...64, step: 2).fixedSize()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(password, forType: .string)
                }
                .disabled(password.isEmpty)
                .help("Copy the password so you can send it separately from the archive")
            }
            .controlSize(.small)
        }
    }
}

struct StrengthMeter: View {
    let password: String
    var body: some View {
        let s = PasswordStrength.evaluate(password)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                ForEach(0..<5) { i in
                    Capsule().fill(i <= s.rating.rawValue && !password.isEmpty ? color(s.rating) : Color.secondary.opacity(0.2)).frame(height: 4)
                }
            }
            if !password.isEmpty {
                Text("\(s.rating.label)\(s.feedback.first.map { " — \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Password strength: \(password.isEmpty ? "empty" : s.rating.label)")
    }
    func color(_ r: PasswordStrength.Rating) -> Color {
        switch r { case .veryWeak: return .red; case .weak: return .orange; case .fair: return .yellow; case .strong: return .green; case .veryStrong: return .mint }
    }
}

struct PasswordSheet: View {
    let request: PasswordRequest
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var remember = false
    @State private var reveal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(request.reason == .previousAttemptIncorrect ? "Incorrect password. Try again." : "“\(request.archive.lastPathComponent)” is encrypted.",
                  systemImage: request.reason == .previousAttemptIncorrect ? "exclamationmark.lock" : "lock")
                .font(.headline)
            HStack {
                if reveal { TextField("Password", text: $password) } else { SecureField("Password", text: $password) }
                Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.borderless)
            }
            .onSubmit { submit() }
            if model.settings.savePasswordsInKeychain {
                Toggle("Remember in Keychain", isOn: $remember)
            }
            Text("For multi-part archives the same password is used for every part.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.answerPassword(nil, remember: false) }.keyboardShortcut(.cancelAction)
                Button("OK") { submit() }.keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    func submit() {
        guard !password.isEmpty else { return }
        model.answerPassword(Secret(password), remember: remember)
        password = ""
    }
}

struct ConflictSheet: View {
    let request: ConflictRequest
    @Environment(AppModel.self) private var model
    @State private var applyToAll = false

    var body: some View {
        let i = request.info
        VStack(alignment: .leading, spacing: 12) {
            Text("“\((i.existingPath as NSString).lastPathComponent)” already exists").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text(""); Text("Existing").bold(); Text("From archive").bold() }
                GridRow { Text("Size").foregroundStyle(.secondary); Text(i.existingSize.map(ByteFormatting.string) ?? "—"); Text(i.entrySize.map(ByteFormatting.string) ?? "—") }
                GridRow { Text("Modified").foregroundStyle(.secondary)
                    Text(i.existingModified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    Text(i.entryModified?.formatted(date: .abbreviated, time: .shortened) ?? "—") }
            }
            Toggle("Apply to all conflicts", isOn: $applyToAll)
            HStack {
                Button("Skip") { model.answerConflict(.skip, applyToAll: applyToAll) }
                Spacer()
                Button("Keep Both") { model.answerConflict(.keepBoth, applyToAll: applyToAll) }.keyboardShortcut(.defaultAction)
                Button("Replace", role: .destructive) { model.answerConflict(.replace, applyToAll: applyToAll) }
            }
            Text(i.existingIsDirectory ? "Folders are merged, never replaced." : "Keep Both saves the new file with a number added to its name.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }
}

// MARK: Misc

struct SectionHeader: View {
    let title: String
    let subtitle: String?
    init(_ title: String, _ subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2.weight(.semibold))
            if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DestinationPicker: View {
    let label: String
    @Binding var url: URL?
    var placeholder: String
    var body: some View {
        LabeledContent(label) {
            HStack {
                Image(systemName: "folder")
                Text(url?.path(percentEncoded: false) ?? placeholder).lineLimit(1).truncationMode(.middle)
                Button("Choose…") { if let u = FolderPicker.choose(prompt: "Choose", directory: url) { url = u } }
                if url != nil { Button("Reset") { url = nil }.buttonStyle(.borderless) }
            }
        }
    }
}

struct ErrorBanner: View {
    let error: ArchiveError
    @State private var details = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.title, systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            Text(error.explanation)
            ForEach(error.suggestions, id: \.self) { Text("• " + $0).font(.callout).foregroundStyle(.secondary) }
            DisclosureGroup("Technical details", isExpanded: $details) {
                Text("Code: \(error.code)\n\(String(describing: error))").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            .font(.caption)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

func formatBytes(_ v: UInt64?) -> String { v.map(ByteFormatting.string) ?? "Unknown" }

/// Runs throwing work on a background thread.
func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, ArchiveError> {
    await Task.detached(priority: .userInitiated) {
        do { return .success(try work()) } catch { return .failure(ArchiveError.wrap(error)) }
    }.value
}
#endif
