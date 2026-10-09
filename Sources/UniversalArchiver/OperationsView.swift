#if os(macOS)
import SwiftUI
import Combine
import AppKit
import ArchiveCore
import ArchiveEngines
import ArchiverKit

struct OperationsView: View {
    let showFinished: Bool
    @Environment(AppModel.self) private var model
    @State private var showPerformance = false

    var body: some View {
        let _ = model.operationsVersion
        let ops: [QueuedOperation] = showFinished ? Array(model.center.finished.reversed()) : model.center.active
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(showFinished ? "Completed Operations" : "Active Operations")
                if showFinished, !ops.isEmpty { Button("Clear") { model.center.clearFinished() } }
                if !showFinished, model.settings.uiLevel != .simple { Toggle("Performance details", isOn: $showPerformance).toggleStyle(.switch) }
            }
            if ops.isEmpty {
                Text(showFinished ? "Nothing here yet." : "No operations are running.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(ops) { op in
                    VStack(alignment: .leading) {
                        OperationRow(op: op, compact: false)
                        if showPerformance, op.state == .running || op.state == .paused { PerformancePanel(op: op) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(24)
    }
}

/// One operation with live progress. Values shown are measured, not simulated.
struct OperationRow: View {
    let op: QueuedOperation
    let compact: Bool
    @State private var snap: ProgressSnapshot?
    @State private var timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(op.title).lineLimit(1)
                Spacer()
                switch op.state {
                case .running:
                    Button { op.pause() } label: { Image(systemName: "pause.fill") }.buttonStyle(.borderless).help("Pause")
                    Button { op.cancel() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("Cancel")
                case .paused:
                    Button { op.resume() } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).help("Resume")
                    Button { op.cancel() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("Cancel")
                case .queued:
                    Button { op.cancel() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                default: EmptyView()
                }
            }
            if let s = snap, op.state == .running || op.state == .paused {
                if let f = s.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                if !compact {
                    HStack(spacing: 10) {
                        Text(s.phase + (s.isPaused ? " (paused)" : ""))
                        Text(ByteFormatting.string(s.processedBytes) + (s.totalBytes.map { " of " + ByteFormatting.string($0) } ?? ""))
                        if s.bytesPerSecond > 0 { Text(ByteFormatting.rate(s.bytesPerSecond)) }
                        if let r = s.estimatedRemaining { Text("about \(ByteFormatting.duration(r)) left") }
                        if s.outputBytes > 0, s.processedBytes > 0 { Text(String(format: "ratio %.0f%%", Double(s.outputBytes) / Double(s.processedBytes) * 100)) }
                    }
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if let item = s.currentItem { Text(item).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
            }
            if let summary = op.summary, op.state == .succeeded { Text(summary).font(.caption).foregroundStyle(.secondary) }
            if let e = op.error, op.state == .failed {
                Text(e.title + ": " + e.explanation).font(.caption).foregroundStyle(.red)
            }
        }
        .onReceive(timer) { _ in snap = op.progress.snapshot }
        .accessibilityElement(children: .combine)
    }

    var icon: String {
        switch op.state {
        case .queued: return "clock"
        case .running: return "gearshape.2"
        case .paused: return "pause.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }
    var color: Color {
        switch op.state { case .succeeded: return .green; case .failed: return .red; case .cancelled: return .secondary; default: return .accentColor }
    }
}

/// Optional expert panel with live resource measurements of this process.
struct PerformancePanel: View {
    let op: QueuedOperation
    @State private var stats = ProcessStats.sample()
    @State private var lastCPU: (Date, Double)?
    @State private var cpuPercent: Double = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let s = op.progress.snapshot
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
            GridRow { Text("Operation"); Text(s.phase) }
            GridRow { Text("Mode"); Text(SystemProfile.current().effectiveMode(.balanced).displayName) }
            GridRow { Text("Processed"); Text(ByteFormatting.string(s.processedBytes) + (s.totalBytes.map { " of " + ByteFormatting.string($0) } ?? "")) }
            GridRow { Text("Output so far"); Text(ByteFormatting.string(s.outputBytes)) }
            GridRow { Text("Throughput"); Text(ByteFormatting.rate(s.bytesPerSecond)) }
            GridRow { Text("Elapsed"); Text(ByteFormatting.duration(s.elapsed)) }
            GridRow { Text("Remaining (estimate)"); Text(s.estimatedRemaining.map(ByteFormatting.duration) ?? "—") }
            GridRow { Text("Memory (app)"); Text(ByteFormatting.string(stats.residentBytes)) }
            GridRow { Text("CPU (app)"); Text(String(format: "%.0f%%", cpuPercent)) }
        }
        .font(.caption.monospacedDigit())
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onReceive(timer) { now in
            stats = ProcessStats.sample()
            if let last = lastCPU { cpuPercent = (stats.cpuSeconds - last.1) / now.timeIntervalSince(last.0) * 100 }
            lastCPU = (now, stats.cpuSeconds)
        }
    }
}

/// Resident memory and CPU time of this process (including helper children is not possible without privileges).
struct ProcessStats {
    var residentBytes: UInt64
    var cpuSeconds: Double

    static func sample() -> ProcessStats {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        return ProcessStats(residentBytes: kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0, cpuSeconds: cpu)
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [HistoryRecord] = []
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                SectionHeader("History", model.settings.historyEnabled ? "Stored only on this Mac. Contains no file contents or passwords." : "History is turned off in Settings.")
                Button("Clear History", role: .destructive) { model.history.clear(); records = [] }
            }
            Table(records) {
                TableColumn("Date") { r in Text(r.date.formatted(date: .abbreviated, time: .shortened)) }.width(140)
                TableColumn("Action") { r in Text(r.kind.rawValue.capitalized) }.width(80)
                TableColumn("Items") { r in Text(r.inputs.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) }
                TableColumn("Result") { r in Label(r.summary, systemImage: r.succeeded ? "checkmark.circle" : "exclamationmark.triangle") }
                TableColumn("") { r in
                    if let first = r.inputs.first, first.hasPrefix("/") {
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)]) }.buttonStyle(.link)
                    }
                }.width(50)
            }
        }
        .padding(24)
        .onAppear { records = model.history.all() }
    }
}
#endif
