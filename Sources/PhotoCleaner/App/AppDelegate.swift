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
    /// The updater, once `PhotoCleanerApp` has built it, and the token that
    /// unsubscribes from it. Retained because the updater's flow ends by
    /// replacing and restarting the very bundle this window is running from: a
    /// half-released observer graph at that moment is a crash on the way out.
    private var updater: Updater?
    private var updateObservation: UUID?

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
            didStop: { [weak self] in self?.finishedShutdown() },
            didBuild: { [weak self] updater in self?.adopt(updater) }
        )
        runner = Task { [options] in
            await PhotoCleanerApp(options: options, hooks: hooks).run()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateIndicatorClicked),
            name: UpdateIndicatorController.clicked,
            object: nil)
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

    // MARK: - Updates

    /// Take the updater the app built and start observing it.
    ///
    /// Called from `PhotoCleanerApp` rather than constructed here, because the
    /// updater needs the same `Settings` instance the rest of the graph uses — two
    /// `Settings` over one file would each write back a snapshot the other had not
    /// seen, which is a lost update, not a race.
    private func adopt(_ updater: Updater) {
        self.updater = updater
        self.updateObservation = nil
        Task { [weak self] in
            guard let self else { return }
            updateObservation = await updater.observe { [weak self] status in
                self?.render(status)
            }
        }
    }

    /// Draw one updater state, on the main actor, wherever the window is.
    private func render(_ status: Updater.Status) {
        window?.showUpdateStatus(status)
        MainMenu.updateItem(for: status)
    }

    /// The title bar arc, clicked.
    ///
    /// The whole flow from here: check if needed, then download, install and
    /// restart. No confirmation — the control said what it does, and asking again
    /// would make the app's own title bar a dialog it had already answered.
    @objc private func updateIndicatorClicked() {
        runUpdateFlow()
    }

    /// **Check for Updates…** from the menu.
    ///
    /// The same flow, for the times the arc is not the fastest way in: someone who
    /// wants to be told there is nothing new, or who turned the automatic check
    /// off and still wants the app to know.
    @objc func checkForUpdates(_ sender: Any?) {
        runUpdateFlow()
    }

    /// Toggle whether the app checks for updates on its own.
    ///
    /// Flipping it *on* runs a check immediately rather than waiting for the next
    /// launch. Turning it on and then waiting is how an opt-in setting feels broken.
    @objc func toggleAutomaticUpdateChecks(_ sender: Any?) {
        guard let updater else { return }
        let enabled: Bool
        if let item = sender as? NSMenuItem {
            enabled = item.state != .on
            item.state = enabled ? .on : .off
        } else {
            enabled = false
        }
        Task { await updater.setAutomaticChecks(enabled) }
    }

    /// One entry point for both the menu item and the arc.
    ///
    /// The result is reported only when it is something the user cannot see: the
    /// window is about to be replaced on success, so an alert then would be a
    /// dialog racing the restart. A failure, by contrast, has to be shown — an app
    /// that silently stays on the old version after being asked to update is the
    /// one failure mode worth being loud about.
    private func runUpdateFlow() {
        guard let updater else { return }
        Task { [weak self] in
            guard let self else { return }
            switch await updater.start() {
            case .installed:
                break // replacing this process; there is nothing to say afterwards
            case .alreadyCurrent(let version):
                report("PhotoCleaner \(version) is the newest published release.")
            case .failed(let message):
                report(message)
            }
        }
    }

    /// The only thing this app ever says to the user unprompted.
    ///
    /// A plain informational alert, because the alternatives are worse: a silent
    /// failure leaves someone believing they are on the new version when they are
    /// not, and a window-level sheet cannot be shown by a presentation that has no
    /// window. `AppWindow.present` decides between the two.
    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window {
            window.present(alert)
        } else {
            alert.runModal()
        }
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
        if let updater, let updateObservation {
            // Unsubscribe before the process goes, so a state published during
            // teardown does not reach a window that is already on its way out.
            Task { await updater.removeObserver(updateObservation) }
            self.updateObservation = nil
        }
        if isTerminating {
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            // Not a terminate request — a SIGINT or SIGTERM pulled the relay, so
            // there is nobody to reply to and the process must end itself.
            exit(0)
        }
    }
}
