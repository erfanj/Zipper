import Foundation

/// A snapshot of operation progress. All byte counts are measured, never invented.
public struct ProgressSnapshot: Sendable, Equatable {
    public var phase: String
    public var currentItem: String?
    public var totalBytes: UInt64?
    public var processedBytes: UInt64
    /// Bytes written to the output so far (compressed bytes when compressing).
    public var outputBytes: UInt64
    public var totalItems: Int?
    public var processedItems: Int
    public var elapsed: TimeInterval
    public var bytesPerSecond: Double
    public var warnings: Int
    public var isPaused: Bool = false

    public var fraction: Double? {
        guard let t = totalBytes, t > 0 else {
            if let ti = totalItems, ti > 0 { return min(1, Double(processedItems) / Double(ti)) }
            return nil
        }
        return min(1, Double(processedBytes) / Double(t))
    }

    /// Estimated seconds remaining, based on the measured throughput. Nil when unknown.
    public var estimatedRemaining: TimeInterval? {
        guard let t = totalBytes, bytesPerSecond > 0, processedBytes > 0, elapsed > 1 else { return nil }
        return Double(t > processedBytes ? t - processedBytes : 0) / bytesPerSecond
    }
}

/// Thread-safe progress tracker and cancellation token shared by an operation and its observers.
///
/// Engines call `add(processed:)` from worker threads; observers receive throttled snapshots.
public final class OperationProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _phase: String = ""
    private var _currentItem: String?
    private var _totalBytes: UInt64?
    private var _processed: UInt64 = 0
    private var _output: UInt64 = 0
    private var _totalItems: Int?
    private var _items: Int = 0
    private var _warnings: Int = 0
    private var _cancelled = false
    private let start = Date()
    private var lastEmit = Date.distantPast
    private var observers: [(ProgressSnapshot) -> Void] = []
    /// Minimum interval between observer callbacks.
    public var throttle: TimeInterval = 0.1
    /// Child processes to terminate when cancelled, keyed by registration token.
    private var cancelHandlers: [Int: () -> Void] = [:]
    private var pauseHandlers: [Int: (Bool) -> Void] = [:]
    private var nextHandlerID = 0
    /// Guarded by `pauseCondition` (it is what paused workers wait on).
    private var _paused = false
    private let pauseCondition = NSCondition()
    /// Copy of the paused state guarded by `lock`, so snapshots never take both locks.
    private var _pausedMirror = false
    private var pausedSince: Date?
    private var pausedTotal: TimeInterval = 0

    /// Identifies a registered cancel or pause handler so its owner can remove just that handler.
    public struct HandlerToken: Hashable, Sendable {
        fileprivate let id: Int
    }

    public init() {}

    public func observe(_ block: @escaping (ProgressSnapshot) -> Void) {
        lock.lock(); observers.append(block); lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    public func cancel() {
        pauseCondition.lock(); _paused = false; pauseCondition.broadcast(); pauseCondition.unlock()
        lock.lock()
        _cancelled = true
        updatePauseClockLocked(paused: false)
        let handlers = Array(cancelHandlers.values)
        lock.unlock()
        handlers.forEach { $0() }
    }

    /// Runs `handler` when the operation is cancelled (immediately if it already was).
    @discardableResult
    public func onCancel(_ handler: @escaping () -> Void) -> HandlerToken {
        lock.lock()
        let already = _cancelled
        let token = makeTokenLocked()
        if !already { cancelHandlers[token.id] = handler }
        lock.unlock()
        if already { handler() }
        return token
    }

    /// Removes handlers registered with `onCancel` or `onPauseChange`. Other owners' handlers stay.
    public func removeHandlers(_ tokens: [HandlerToken]) {
        lock.lock()
        for t in tokens {
            cancelHandlers[t.id] = nil
            pauseHandlers[t.id] = nil
        }
        lock.unlock()
    }

    /// Removes every handler. Prefer `removeHandlers(_:)`, which leaves other owners' handlers alone.
    public func clearCancelHandlers() {
        lock.lock(); cancelHandlers.removeAll(); pauseHandlers.removeAll(); lock.unlock()
    }

    private func makeTokenLocked() -> HandlerToken {
        nextHandlerID += 1
        return HandlerToken(id: nextHandlerID)
    }

    private func updatePauseClockLocked(paused: Bool) {
        _pausedMirror = paused
        if paused {
            if pausedSince == nil { pausedSince = Date() }
        } else if let since = pausedSince {
            pausedTotal += Date().timeIntervalSince(since)
            pausedSince = nil
        }
    }

    /// Throws `ArchiveError.cancelled` if cancellation was requested. While paused, blocks here, so
    /// in-process engines pause between blocks without leaving data in an inconsistent state.
    public func checkCancelled() throws {
        pauseCondition.lock()
        while _paused && !isCancelled { pauseCondition.wait(until: Date().addingTimeInterval(0.25)) }
        pauseCondition.unlock()
        if isCancelled { throw ArchiveError.cancelled }
    }

    public var isPaused: Bool {
        pauseCondition.lock(); defer { pauseCondition.unlock() }
        return _paused
    }

    /// Pauses the operation. In-process engines stop at their next checkpoint; helper processes are
    /// suspended with SIGSTOP and resumed with SIGCONT.
    public func pause() { setPaused(true) }
    public func resume() { setPaused(false) }

    private func setPaused(_ p: Bool) {
        pauseCondition.lock()
        _paused = p
        pauseCondition.broadcast()
        pauseCondition.unlock()
        lock.lock(); let handlers = Array(pauseHandlers.values); lock.unlock()
        handlers.forEach { $0(p) }
        mutate { $0.updatePauseClockLocked(paused: p) }
    }

    /// Registers a handler that is told when the operation is paused (true) or resumed (false).
    @discardableResult
    public func onPauseChange(_ handler: @escaping (Bool) -> Void) -> HandlerToken {
        lock.lock()
        let token = makeTokenLocked()
        pauseHandlers[token.id] = handler
        lock.unlock()
        return token
    }

    public func setPhase(_ phase: String) { mutate { $0._phase = phase } }
    public func setCurrentItem(_ item: String?) { mutate(force: false) { $0._currentItem = item } }
    public func setTotal(bytes: UInt64?, items: Int?) { mutate { $0._totalBytes = bytes; $0._totalItems = items } }
    public func add(processed: UInt64) { mutate(force: false) { $0._processed &+= processed } }
    public func add(output: UInt64) { mutate(force: false) { $0._output &+= output } }
    public func setOutput(_ bytes: UInt64) { mutate(force: false) { $0._output = bytes } }
    public func setProcessed(_ bytes: UInt64) { mutate(force: false) { $0._processed = bytes } }
    public func itemCompleted() { mutate(force: false) { $0._items += 1 } }
    public func warning() { mutate(force: false) { $0._warnings += 1 } }

    public var snapshot: ProgressSnapshot {
        lock.lock(); defer { lock.unlock() }
        return makeSnapshot()
    }

    /// Emit a final snapshot regardless of throttling.
    public func flush() { mutate { _ in } }

    private func makeSnapshot() -> ProgressSnapshot {
        // Time spent paused is excluded, so throughput and the remaining-time estimate stay honest.
        let now = Date()
        let paused = pausedTotal + (pausedSince.map { now.timeIntervalSince($0) } ?? 0)
        let elapsed = max(0, now.timeIntervalSince(start) - paused)
        return ProgressSnapshot(
            phase: _phase, currentItem: _currentItem, totalBytes: _totalBytes, processedBytes: _processed,
            outputBytes: _output, totalItems: _totalItems, processedItems: _items, elapsed: elapsed,
            bytesPerSecond: elapsed > 0 ? Double(_processed) / elapsed : 0, warnings: _warnings, isPaused: _pausedMirror)
    }

    private func mutate(force: Bool = true, _ body: (OperationProgress) -> Void) {
        lock.lock()
        body(self)
        let now = Date()
        var snap: ProgressSnapshot?
        var obs: [(ProgressSnapshot) -> Void] = []
        if !observers.isEmpty, force || now.timeIntervalSince(lastEmit) >= throttle {
            lastEmit = now
            snap = makeSnapshot()
            obs = observers
        }
        lock.unlock()
        if let s = snap { obs.forEach { $0(s) } }
    }
}
