import Foundation
import os

/// What PhotoCleaner puts on screen once the server is listening.
///
/// Kept as three cases rather than a single `openBrowser` flag because "use the
/// browser" and "show something native" are now different things: the default is
/// an `NSWindow` hosting a `WKWebView`, and the browser is an escape hatch for
/// anyone who prefers their own.
enum Presentation: String, Sendable {
    /// A native window. The default, and the only mode that touches AppKit.
    case window
    /// Hand the URL to the default browser and let it own the UI.
    case browser
    /// Nothing on screen at all: a plain background server.
    case headless

    var opensBrowser: Bool { self == .browser }

    /// True for the mode that cannot survive a machine with no window server.
    ///
    /// `--no-browser` and `--browser` never initialise `NSApplication`, so they
    /// still start over SSH and in a `launchd` job, exactly as they did before
    /// there was a window. `--foreground` from a terminal is fine too: the
    /// bundle is what talks to the window server, not the parent shell.
    static func needsAppKit(_ presentation: Presentation) -> Bool {
        presentation == .window
    }
}

/// A process-wide "please stop" request.
///
/// A `SIGINT`, a `SIGTERM`, the window's close button and ⌘Q all have to end up
/// in the same place — the shutdown loop in `PhotoCleanerApp.run()` — and none of
/// them may know about the others' thread. The signal side arrives on a dispatch
/// queue and the AppKit side is `@MainActor`, so this is a relay rather than a
/// direct call: each side registers what it wants, and whoever asks first pulls.
final class ShutdownRelay: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var handlers: [@Sendable () -> Void] = []
        var fired = false
    }

    /// Register interest. Registrations after the relay has fired are ignored:
    /// a shutdown in progress is never restarted.
    func add(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { state in
            guard !state.fired else { return }
            state.handlers.append(handler)
        }
    }

    /// Fire every registered handler, at most once for the process lifetime.
    ///
    /// Idempotent on purpose: ⌘Q and a close click can both arrive, and the
    /// second one must not queue a second graceful shutdown.
    func trigger() {
        let due: [@Sendable () -> Void] = state.withLock { state in
            guard !state.fired else { return [] }
            state.fired = true
            return state.handlers
        }
        for handler in due { handler() }
    }
}

/// The seam between the server and whatever is hosting it.
///
/// `main.swift` builds these before it knows whether there will be a window,
/// which is the whole point: starting the server, analysing, serving the UI and
/// shutting down are byte-for-byte the same code whether the interface ends up
/// in a `WKWebView`, in Safari, or nowhere at all.
struct AppHooks: Sendable {
    /// Show the interface at `url`. Called exactly once, after the listener is
    /// up and Photos authorization has been asked for.
    var present: @MainActor @Sendable (URL) -> Void

    /// How the host asks the run loop to stop.
    var shutdown: ShutdownRelay

    /// The graceful shutdown has finished. Only AppKit needs to hear this, and
    /// only because a windowed app must not call `exit` from under itself.
    var didStop: @MainActor @Sendable () -> Void

    /// The updater, once it exists.
    ///
    /// A callback rather than a stored property, and that is forced by the
    /// construction order rather than chosen for tidiness: the hooks are built
    /// before the object graph, and the updater needs the `Settings` instance
    /// built with it. Handing it over here is what lets the windowed host draw it
    /// while `--browser` and `--no-browser` — which pass `serverOnly` and get the
    /// no-op default — still run the check and record the result in the log.
    var didBuild: @MainActor @Sendable (Updater) -> Void = { _ in }

    /// A host that shows nothing and cannot be asked to stop: the server alone.
    static let serverOnly = AppHooks(
        present: { _ in },
        shutdown: ShutdownRelay(),
        didStop: {}
    )
}
