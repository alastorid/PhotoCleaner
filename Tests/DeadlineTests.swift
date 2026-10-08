import Foundation

// `CallbackDeadline` — the bound that keeps an unanswered PhotoKit or AVFoundation
// callback from parking an analysis worker, and with it the whole pass, forever.
//
// The failure it exists for cannot be reproduced here: it needs a real library and
// an asset whose handler never fires (see `CallbackDeadline`'s own documentation
// for the measurement, and `docs/ARCHITECTURE.md` §5.4). The suite has no Photos
// library and no network. What *is* testable is the whole of the primitive: a
// timer with one contract — fire once, after the interval, unless disarmed first —
// and that contract is exactly what every call site relies on, because each one
// disarms the deadline on the only path that reports the framework's answer.

func registerDeadlineTests() {
    let suite = "callback deadlines"

    Registry.shared.add(suite: suite, TestCase(name: "a deadline fires once, after its interval", knownBug: nil) {
        let fired = DeadlineFireCounter()
        let deadline = CallbackDeadline()
        deadline.arm(after: 0.05) { fired.increment() }
        checkEqual(fired.value, 0, "arming a deadline must not run it inline")

        let limit = Date().addingTimeInterval(2)
        while fired.value == 0, Date() < limit {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        checkEqual(fired.value, 1, "it runs when the interval elapses")

        // The other half of "once": a timer that re-armed itself after firing would
        // show up here, and no call site would survive it — the answer has already
        // been given, and the second firing resumes a continuation that is gone.
        try await Task.sleep(nanoseconds: 150_000_000)
        checkEqual(fired.value, 1, "and never again, however long the process keeps running")
    })

    Registry.shared.add(suite: suite, TestCase(name: "disarming beats the interval", knownBug: nil) {
        let fired = DeadlineFireCounter()
        let deadline = CallbackDeadline()
        deadline.arm(after: 0.05) { fired.increment() }
        // The production ordering: the framework's handler resolves the request and
        // disarms, all before the interval could elapse.
        deadline.disarm()
        try await Task.sleep(nanoseconds: 250_000_000)
        checkEqual(fired.value, 0, "a disarmed deadline does not fire")
        deadline.disarm()
        checkEqual(fired.value, 0, "and disarming twice is harmless")
    })
}

/// Counts firings across threads. A deadline is a timer, so the read below happens
/// on the test's task while the increment happens on a global queue.
private final class DeadlineFireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
