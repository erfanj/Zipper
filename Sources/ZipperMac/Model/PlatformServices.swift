import Foundation
import ArchiveCore
import ArchiverKit

/// Everything the app model needs from the operating system's user interface. The macOS app
/// implements it with AppKit (`MacPlatform`); keeping it behind a protocol keeps `AppModel`
/// free of AppKit, so it builds — and is type-checked — on every platform.
@MainActor
protocol PlatformServices: AnyObject {
    /// Shows a modal password prompt. Returns nil when the user cancels.
    func askPassword(for archive: URL, reason: PasswordRequestReason, offerToRemember: Bool) -> PasswordAnswer?
    /// Shows a modal "item already exists" prompt.
    func askConflict(_ info: ConflictInfo) -> ConflictAnswer
    /// Shows a modal alert for a failed operation.
    func showError(_ error: ArchiveError, context: String)
    /// Posts a user notification (only used while the app is in the background).
    func notify(title: String, body: String)
    var isAppActive: Bool { get }
    func updateDockProgress(fraction: Double?, activeCount: Int)
    func reveal(_ urls: [URL])
    func open(_ url: URL)
    func noteRecentDocument(_ url: URL)
}

struct PasswordAnswer {
    var secret: Secret
    var remember: Bool
}

struct ConflictAnswer {
    var decision: ConflictDecision
    var applyToAll: Bool
}

/// Used where there is no user interface (tests, the non-macOS stub): never prompts.
@MainActor
final class HeadlessPlatform: PlatformServices {
    func askPassword(for archive: URL, reason: PasswordRequestReason, offerToRemember: Bool) -> PasswordAnswer? { nil }
    func askConflict(_ info: ConflictInfo) -> ConflictAnswer { ConflictAnswer(decision: .keepBoth, applyToAll: true) }
    func showError(_ error: ArchiveError, context: String) {}
    func notify(title: String, body: String) {}
    var isAppActive: Bool { true }
    func updateDockProgress(fraction: Double?, activeCount: Int) {}
    func reveal(_ urls: [URL]) {}
    func open(_ url: URL) {}
    func noteRecentDocument(_ url: URL) {}
}

/// Hands one answer from the main thread to a worker thread that is waiting for it.
/// One box per request, so concurrent operations can never receive each other's answers.
final class AnswerBox<T>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: T?

    func wait() -> T? {
        semaphore.wait()
        return value
    }

    func answer(_ v: T?) {
        value = v
        semaphore.signal()
    }
}
