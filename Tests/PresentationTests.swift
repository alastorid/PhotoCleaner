import Foundation

// Presentation, the shutdown relay, and the window's navigation policy.
//
// All three are small, all three are pure, and all three are places where being
// wrong is quiet rather than loud: a mis-parsed flag means the wrong UI comes up,
// a relay that fires twice means two shutdown sequences race, and a navigation
// policy that is too generous lets a foreign page run in a window that is trusted
// locally.

func registerPresentationTests() {
    let suite = "presentation, shutdown relay and window navigation"

    // MARK: flags

    Registry.shared.add(suite: suite, TestCase(name: "the default is a window, and only --browser changes it",
        knownBug: nil) {
        let bare = LaunchOptions.parse(["photo-cleaner"])
        checkEqual(bare.presentation, .window, "no flags means a native window")
        checkEqual(bare.port, 8765, "default port")

        checkEqual(LaunchOptions.parse(["photo-cleaner", "--browser"]).presentation, .browser,
                   "--browser opens the default browser")
        checkEqual(LaunchOptions.parse(["photo-cleaner", "--no-browser"]).presentation, .headless,
                   "--no-browser shows nothing at all")
    })

    Registry.shared.add(suite: suite, TestCase(name: "only the windowed presentation touches AppKit",
        knownBug: nil) {
        // The property that keeps --no-browser usable from launchd and over SSH:
        // a machine with no window server must still be able to run the server.
        check(Presentation.needsAppKit(.window), "the window needs AppKit")
        check(!Presentation.needsAppKit(.browser), "the browser path must not initialise NSApplication")
        check(!Presentation.needsAppKit(.headless), "the headless path must not initialise NSApplication")
    })

    Registry.shared.add(suite: suite, TestCase(name: "flags combine, and an unknown flag is still ignored",
        knownBug: nil) {
        let options = LaunchOptions.parse(["photo-cleaner", "--port", "8799", "--no-browser", "--wat"])
        checkEqual(options.port, 8799, "--port is read")
        checkEqual(options.presentation, .headless, "--no-browser is read")
        checkEqual(options.presentation.opensBrowser, false, "headless does not open a browser")
        checkEqual(options.presentation.showsWindow, false, "headless shows no window")

        // Last one wins, which is the least surprising reading of a repeated flag.
        checkEqual(LaunchOptions.parse(["photo-cleaner", "--no-browser", "--browser"]).presentation, .browser,
                   "a later --browser overrides an earlier --no-browser")

        // A --port with no value is ignored rather than consuming the next flag,
        // exactly as it was before the window existed.
        let dangling = LaunchOptions.parse(["photo-cleaner", "--port", "--browser"])
        checkEqual(dangling.port, 8765, "a --port with no value keeps the default")
        checkEqual(dangling.presentation, .browser, "and does not eat the next flag")
    })

    // MARK: the relay

    Registry.shared.add(suite: suite, TestCase(name: "the shutdown relay fires every handler, exactly once",
        knownBug: nil) {
        let relay = ShutdownRelay()
        let counter = Counter()
        relay.add { counter.increment() }
        relay.add { counter.increment() }

        checkEqual(counter.value, 0, "registering does not fire")
        relay.trigger()
        checkEqual(counter.value, 2, "both handlers run")
        // ⌘Q and the red button can both arrive, and a second graceful shutdown
        // would run while the first is still flushing.
        relay.trigger()
        relay.trigger()
        checkEqual(counter.value, 2, "a second and third trigger are no-ops")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a handler registered after the relay fired is not called",
        knownBug: nil) {
        let relay = ShutdownRelay()
        let early = Counter()
        relay.add { early.increment() }
        relay.trigger()

        let late = Counter()
        relay.add { late.increment() }
        checkEqual(early.value, 1, "the handler registered before the trigger ran once")
        checkEqual(late.value, 0, "a shutdown in progress is never restarted")
    })

    // MARK: navigation policy

    Registry.shared.add(suite: suite, TestCase(name: "the window accepts its own server and nothing else",
        knownBug: nil) {
        let port = 8765
        let allowed = [
            "http://127.0.0.1:8765/",
            "http://127.0.0.1:8765/api/status",
            "http://localhost:8765/",
            "http://LOCALHOST:8765/app.js",
        ]
        for address in allowed {
            let url = checkNotNil(URL(string: address), "url for \(address)")
            check(AppWindow.isOwnServer(url!, port: port), "\(address) must be allowed")
        }

        // Every one of these would put a document in a window that is trusted with
        // loopback access to the whole photo API.
        let refused = [
            "http://127.0.0.1:8766/",          // another port on loopback
            "http://localhost:9999/",          // another server entirely
            "https://127.0.0.1:8765/",         // right host, wrong scheme
            "file:///etc/passwd",              // a local file
            "http://127.0.0.2:8765/",          // loopback range, not this host
            "http://evil.example.com:8765/",   // right port, wrong host
            "http://127.0.0.1.evil.example/",  // a host that merely starts with ours
        ]
        for address in refused {
            let url = checkNotNil(URL(string: address), "url for \(address)")
            check(!AppWindow.isOwnServer(url!, port: port), "\(address) must be refused")
        }

        // A URL with no port cannot match a ported server, so it must not match
        // even when the host is right.
        check(!AppWindow.isOwnServer(URL(string: "http://127.0.0.1")!, port: port),
              "a portless URL is not this server")
    })
}

/// A thread-safe counter, so a relay test does not race with the assertion.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
