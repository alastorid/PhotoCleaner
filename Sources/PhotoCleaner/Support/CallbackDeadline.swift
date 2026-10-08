import Foundation

/// A deadline for a system callback that may never arrive.
///
/// PhotoKit and AVFoundation both hand results back through completion handlers,
/// and neither one promises to call them. Measured on this machine, against a real
/// 54,614-asset library: with network access allowed, `PHImageManager.requestImage`
/// for one iCloud-backed asset left its handler uncalled for minutes, while the
/// *same* asset answered in 3 ms when the request was not allowed to reach the
/// network. No error, no exception, no callback.
///
/// An `await` on a handler that never runs suspends its task with **no thread
/// behind it**: nothing times out, nothing logs, nothing recovers. That is fatal
/// to more than the one asset. `AnalysisEngine` runs a bounded pool of workers and
/// `analyze()` waits for all of them, so one unanswered callback parks a worker for
/// the life of the process; the phase never leaves `analyzing`, the percentage
/// (terminal rows over total) never moves, and a relaunch reproduces both — the
/// queue is drained in the same order, so the same assets are claimed and the pass
/// stops in the same place. A stall that a restart reproduces is not a slow pass.
///
/// This is deliberately **not** a `Task`-based timeout wrapping the call. Cancelling
/// a Swift task cannot resume a continuation the framework owns, and the caller —
/// not this type — is what knows how to cancel the underlying request. So this owns
/// exactly one thing: a timer that fires once, `seconds` from now, unless
/// `disarm()` gets there first.
///
/// The shape is `HTTPServer`'s idle and request timers, for the same reason: those
/// bound a connection whose handler may never answer.
final class CallbackDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchWorkItem?

    /// Fires `fire` once, `seconds` from now, unless `disarm()` is called first.
    ///
    /// `fire` runs on a global queue and it races the callback it exists to outlive,
    /// so it must be safe to run after — or before — that callback resolves. Every
    /// caller here pairs it with a single-shot resume guard, which is what makes the
    /// race harmless: whichever side arrives second finds the answer already given.
    func arm(after seconds: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
        let work = DispatchWorkItem(block: fire)
        lock.lock()
        let superseded = timer
        timer = work
        lock.unlock()
        superseded?.cancel()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The callback answered. There is nothing left to fire.
    func disarm() {
        lock.lock()
        let work = timer
        timer = nil
        lock.unlock()
        work?.cancel()
    }
}
