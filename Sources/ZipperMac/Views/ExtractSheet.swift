#if os(macOS)
import SwiftUI
import AppKit
import ArchiveCore
import ArchiverKit

/// The "Extract" sheet: where to, how folders are arranged, what to do with existing items.
struct ExtractSheet: View {
    @Bindable var form: ExtractForm
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section { summary }
                Section {
                    DestinationRow(label: "Extract to", url: form.destination, placeholder: "Same folder as the archive") { form.setDestination($0) }
                    Picker("Folders", selection: $form.mode) {
                        Text("Automatic").tag(ExtractionMode.smart)
                        Text("Always in a new folder").tag(ExtractionMode.newFolder)
                        Text("Directly in the destination").tag(ExtractionMode.here)
                    }
                    Picker("If an item exists", selection: $form.conflict) {
                        ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } footer: {
                    Text(modeExplanation).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Show in Finder when done", isOn: $form.revealWhenDone)
                    Toggle("Check the extracted files", isOn: $form.verify)
                    Toggle("Also extract archives inside this archive", isOn: $form.extractNested)
                    Toggle("Move the archive to the Trash afterwards", isOn: $form.trashAfter)
                        .disabled(!form.verify)
                        .help("Only after every file was extracted and checked.")
                    if form.isDiskImage {
                        Toggle("Allow mounting this disk image (read-only) if needed", isOn: $form.allowMount)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Show Contents") {
                    model.openArchive(form.archive)
                    dismiss()
                }
                .disabled(form.isLoading || !form.canExtract)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Extract") {
                    form.start()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!form.canExtract)
            }
            .padding(16)
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 440, idealHeight: 500)
        .task { await form.load() }
    }

    @ViewBuilder private var summary: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(forFile: form.archive)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(form.archive.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Group {
                    if form.isLoading {
                        Text("Reading…")
                    } else if let o = form.opened {
                        let l = o.listing
                        Text("\(l.fileCount) file\(l.fileCount == 1 ? "" : "s"), \(l.directoryCount) folder\(l.directoryCount == 1 ? "" : "s") · \(formatBytes(l.totalUncompressedSize))"
                             + (o.detection.multipart.map { " · \($0.volumes.count) parts" } ?? ""))
                    } else {
                        Text(" ")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if form.isLoading { ProgressView().controlSize(.small) }
        }
        if form.needsPassword {
            Label("Protected with a password. You'll be asked for it when extraction starts.", systemImage: "lock.fill")
                .font(.callout)
        }
        if let warning = form.spaceWarning {
            Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        }
        if form.executableCount > 0 {
            Label("Contains \(form.executableCount) app\(form.executableCount == 1 ? "" : "s"), script\(form.executableCount == 1 ? "" : "s") or program\(form.executableCount == 1 ? "" : "s"). Zipper never opens them automatically.",
                  systemImage: "app.badge")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if let e = form.loadError, !form.needsPassword {
            ErrorBanner(error: e)
        }
    }

    private var modeExplanation: String {
        switch form.mode {
        case .smart: return "Puts the contents in a new folder, unless the archive already contains a single folder or file."
        case .newFolder: return "Always creates a folder named after the archive."
        case .here: return "Puts the contents directly in the destination, merging folders."
        }
    }
}
#endif
