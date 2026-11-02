#if os(macOS)
import SwiftUI
import AppKit
import ArchiveCore
import ArchiverKit

/// Running and finished operations (this session), plus the saved history.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .current

    enum Tab: Hashable { case current, history }

    var body: some View {
        let _ = model.operationsVersion
        VStack(spacing: 0) {
            switch tab {
            case .current: CurrentOperationsList()
            case .history: HistoryList()
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $tab) {
                    Text("Current").tag(Tab.current)
                    Text("History").tag(Tab.history)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}

struct CurrentOperationsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.operationsVersion
        let active = model.center.active
        let finished = Array(model.center.finished.reversed())
        if active.isEmpty && finished.isEmpty {
            EmptyStateView(title: "Nothing Running", message: "Archives you compress, extract or test appear here while they're being processed.", symbol: "clock.arrow.circlepath")
        } else {
            List {
                if !active.isEmpty {
                    Section("In Progress") {
                        ForEach(active) { op in OperationRow(op: op).padding(.vertical, 4) }
                    }
                }
                if !finished.isEmpty {
                    Section {
                        ForEach(finished) { op in OperationRow(op: op).padding(.vertical, 2) }
                    } header: {
                        HStack {
                            Text("Finished")
                            Spacer()
                            Button("Clear") { model.center.clearFinished() }
                                .buttonStyle(.link)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

/// One operation with live, measured progress (refreshed twice a second while it runs).
struct OperationRow: View {
    let op: QueuedOperation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let state = op.state
            let s = op.progress.snapshot
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: icon(state)).foregroundStyle(color(state)).frame(width: 18)
                    Text(op.title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    controls(state)
                }
                if state == .running || state == .paused {
                    if let f = s.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                    HStack(spacing: 10) {
                        Text(state == .paused ? "Paused" : (s.phase.isEmpty ? "Working" : s.phase))
                        Text(ByteFormatting.string(s.processedBytes) + (s.totalBytes.map { " of " + ByteFormatting.string($0) } ?? ""))
                        if s.bytesPerSecond > 0, state == .running { Text(ByteFormatting.rate(s.bytesPerSecond)) }
                        if let r = s.estimatedRemaining, state == .running { Text("About \(ByteFormatting.duration(r)) left") }
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    if let item = s.currentItem {
                        Text(item).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                } else if state == .queued {
                    Text("Waiting to start…").font(.caption).foregroundStyle(.secondary)
                } else if state == .succeeded, let summary = op.summary, !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if state == .failed, let e = op.error {
                    Text("\(e.title). \(e.explanation)").font(.caption).foregroundStyle(.red).lineLimit(3)
                } else if state == .cancelled {
                    Text("Cancelled. Nothing was left behind.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func controls(_ state: QueuedOperation.State) -> some View {
        switch state {
        case .running:
            Button { op.pause() } label: { Image(systemName: "pause.circle") }
                .buttonStyle(.borderless).help("Pause").accessibilityLabel("Pause")
            Button { op.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).help("Stop").accessibilityLabel("Stop")
        case .paused:
            Button { op.resume() } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless).help("Resume").accessibilityLabel("Resume")
            Button { op.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).help("Stop").accessibilityLabel("Stop")
        case .queued:
            Button { op.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).help("Cancel").accessibilityLabel("Cancel")
        default:
            EmptyView()
        }
    }

    private func icon(_ state: QueuedOperation.State) -> String {
        switch state {
        case .queued: return "clock"
        case .running: return "gearshape.2"
        case .paused: return "pause.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func color(_ state: QueuedOperation.State) -> Color {
        switch state {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }
}

struct HistoryList: View {
    @Environment(AppModel.self) private var model
    @State private var records: [HistoryRecord] = []
    @State private var selection = Set<HistoryRecord.ID>()
    @State private var confirmClear = false

    var body: some View {
        Group {
            if !model.settings.historyEnabled {
                EmptyStateView(title: "History Is Off", message: "Turn it on in Settings › Privacy to keep a list of past operations.", symbol: "clock")
            } else if records.isEmpty {
                EmptyStateView(title: "No History", message: "Finished operations are listed here. History stays on this Mac and never includes file contents or passwords.", symbol: "clock.arrow.circlepath")
            } else {
                Table(records, selection: $selection) {
                    TableColumn("Date") { r in Text(r.date.formatted(date: .abbreviated, time: .shortened)) }
                        .width(min: 120, ideal: 150)
                    TableColumn("Action") { r in Text(r.kind.rawValue.capitalized) }
                        .width(min: 60, ideal: 80)
                    TableColumn("Items") { r in
                        Text(r.inputs.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("Result") { r in
                        Label(r.summary, systemImage: r.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(r.succeeded ? Color.primary : Color.orange)
                            .lineLimit(1)
                    }
                }
                .contextMenu(forSelectionType: HistoryRecord.ID.self) { ids in
                    if let id = ids.first, let r = records.first(where: { $0.id == id }), let first = r.inputs.first, first.hasPrefix("/") {
                        Button("Show in Finder") { model.platform.reveal([URL(fileURLWithPath: first)]) }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear History…") { confirmClear = true }
                    .disabled(records.isEmpty)
            }
        }
        .confirmationDialog("Clear the operation history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        }
        // Reloaded when an operation finishes and when history is cleared (also from Settings).
        .task(id: model.operationsVersion &+ model.historyVersion) { records = model.history.all() }
    }
}
#endif
