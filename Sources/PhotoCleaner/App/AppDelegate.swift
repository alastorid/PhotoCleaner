import AppKit
import Foundation

/// Starts the app as a real application: a Dock icon, a menu bar, a window.
///
/// `NSApplication` owns the process from here — `run()` does not return until the
/// app terminates, which is why the server is started from
/// `applicationDidFinishLaunching` and the shutdown is a conversation rather than
/// a `return`.
///
/// Only `main.swift` calls this, and only for `--presentation window`. The other
/// two presentations never touch AppKit at all, so `--no-browser` still starts on
/// a machine with no window server.
@MainActor
enum WindowedApp {
    static func run(options: LaunchOptions) -> Never {
        // Opt-in Web Inspector, off unless asked for.
        //
        // `PHOTOCLEANER_WEB_INSPECTOR=1 ./photo-cleaner` adds "Inspect Element" to
        // the page's right-click menu. It is registered rather than set, because
        // the registration domain is never written to disk — `set` would create a
        // preferences plist, and "the app writes nothing outside Application
        // Support and Logs" is a property worth keeping exactly true.
        //
        // Registered instead of reached for through KVC on the web view because
        // this project has no private API in it.
        if ProcessInfo.processInfo.environment["PHOTOCLEANER_WEB_INSPECTOR"] == "1" {
            UserDefaults.standard.register(defaults: ["WebKitDeveloperExtras": true])
            Log.info("Web Inspector enabled (PHOTOCLEANER_WEB_INSPECTOR=1)")
        }

        let application = NSApplication.shared
        // A bundle launched with `open` would get this anyway; being explicit
        // matters because `--foreground` runs the binary from a terminal, where
        // it does not.
        application.setActivationPolicy(.regular)

        // The delegate must be retained for the process lifetime:
        // `NSApplication.delegate` is a weak reference.
        let delegate = AppDelegate(options: options)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
        // `run()` is documented never to return; if it somehow does, do not leave
        // a half-torn-down server behind.
        exit(0)
    }
}

/// The application delegate: it owns the window and the process's exit.
///
/// `@unchecked Sendable` is asserted for one reason — every stored property is
/// `@MainActor`-isolated and the only thing that leaves this object is a
/// `@MainActor @Sendable` closure. AppKit is single-threaded; there is no other
/// invariant to check.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let options: LaunchOptions
    private let shutdown = ShutdownRelay()

    private var window: AppWindow?
    /// Set while a terminate request is in flight, so `didStop` knows whether to
    /// reply to AppKit or to exit directly.
    private var isTerminating = false
    /// Retained for its side effect of keeping the run loop alive; cancelled by
    /// the shutdown sequence in `PhotoCleanerApp.run()`.
    private var runner: Task<Void, Never>?

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(target: self)
        let hooks = AppHooks(
            present: { [weak self] url in self?.presentWindow(at: url) },
            shutdown: shutdown,
            didStop: { [weak self] in self?.finishedShutdown() }
        )
        runner = Task { [options] in
            await PhotoCleanerApp(options: options, hooks: hooks).run()
        }
    }

    /// ⌘Q, the Dock's Quit, and closing the window all arrive here.
    ///
    /// `.terminateLater` because the answer depends on work already in progress —
    /// analysis state is flushed and the server socket closed before the process
    /// goes away, and AppKit has to be told when that has finished.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginShutdown()
        return .terminateLater
    }

    /// Closing the window quits the app.
    ///
    /// Routed through `NSApp.terminate` rather than exited from directly, so the
    /// red button and ⌘Q share one shutdown path. This is the documented hook
    /// for it, which avoids asking AppKit to terminate itself from inside
    /// `windowShouldClose`.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu actions

    @objc func reloadInterface(_ sender: Any?) {
        window?.reload()
    }

    // MARK: - The window

    private func presentWindow(at url: URL) {
        if let window {
            // A second launch already raised this one. Nothing is reloaded: that
            // would discard the user's filter, scroll position and selection.
            window.show()
            return
        }
        let created = AppWindow(url: url)
        window = created
        created.show()
    }

    /// Pull the shutdown relay exactly once, whichever AppKit route asked.
    private func beginShutdown() {
        guard !isTerminating else { return }
        isTerminating = true
        shutdown.trigger()
    }

    /// The run loop has finished shutting down.
    private func finishedShutdown() {
        runner = nil
        if isTerminating {
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            // Not a terminate request — a SIGINT or SIGTERM pulled the relay, so
            // there is nobody to reply to and the process must end itself.
            exit(0)
        }
    }
}
