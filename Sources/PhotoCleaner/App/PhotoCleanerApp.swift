import AppKit
import Foundation
import Network
import Photos

/// Command line surface. Small on purpose: this is an appliance, not a shell.
struct LaunchOptions {
    var port: UInt16 = 8765
    /// What to show once the server is listening. The default is a native
    /// window; the browser is kept as an escape hatch, not as the way in.
    var presentation: Presentation = .window
    var showHelp = false
    var showVersion = false

    static let help = """
    PhotoCleaner — browse an Apple Photos library by Apple's Vision aesthetics score.

    Usage: photo-cleaner [options]

      --port <n>        Port to listen on (loopback only). Default 8765.
      --browser         Show the interface in the default browser instead of a
                        PhotoCleaner window.
      --no-browser      Show no interface at all; run as a plain server.
      --version         Print the version and exit.
      --help            Print this help and exit.

    The interface is served from http://127.0.0.1:<port> and is reachable only
    from this Mac. Photos access is requested through PhotoKit on first launch.

    Closing the window, or ⌘Q, shuts PhotoCleaner down. --no-browser and --browser
    never open a window, so they also start on a Mac with no window server.
    """

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--port":
                if index + 1 < arguments.count, let value = UInt16(arguments[index + 1]) {
                    options.port = value
                    index += 1
                }
            case "--browser":
                options.presentation = .browser
            case "--no-browser":
                options.presentation = .headless
            case "--version", "-v":
                options.showVersion = true
            case "--help", "-h":
                options.showHelp = true
            default:
                break
            }
            index += 1
        }
        return options
    }
}

/// Wires the application together and owns the process lifetime.
///
/// Deliberately knows nothing about AppKit's run loop: how the interface is shown
/// and how the process is asked to stop both arrive through `hooks`, so the same
/// code serves a `WKWebView` window, the default browser, or no UI at all.
final class PhotoCleanerApp: Sendable {
    private let options: LaunchOptions
    private let hooks: AppHooks

    init(options: LaunchOptions, hooks: AppHooks = .serverOnly) {
        self.options = options
        self.hooks = hooks
    }

    func run() async {
        let cacheStore: CacheStore
        do {
            try AppPaths.createDirectoryIfNeeded(AppPaths.supportDirectory)
            cacheStore = try CacheStore(path: AppPaths.cacheDatabase.path)
            try await cacheStore.migrate()
        } catch {
            Log.error("\(error)")
            FileHandle.standardError.write(Data("PhotoCleaner: \(error)\n".utf8))
            exit(1)
        }

        let settings = Settings()
        // The updater is built here rather than by the host because it needs the
        // same `Settings` the rest of the graph uses, and it is handed over
        // straight away. Every presentation mode gets one: `--no-browser` has no
        // window to draw it in, but it can still find out there is a fix.
        //
        // Handed over *before* the server starts, not after. `requestAuthorization`
        // below can put a system dialog in front of the user for as long as they
        // take to answer it, and the menu's "Check for Updates Automatically"
        // checkmark is a setting read from `settings.json` — the one thing about
        // the updater a user can see before the window even exists.
        let updater = Updater(settings: settings)
        await hooks.didBuild(updater)
        let bus = EventBus()
        let library = PhotoLibrary.shared
        let engine = AnalysisEngine(cache: cacheStore, library: library, settings: settings, bus: bus)
        // Album membership is populated lazily by the first `GET /api/albums`,
        // never on this path — see `AlbumIndexer` for why.
        let albumIndex = AlbumIndexer(cache: cacheStore, library: library)
        // Similar Groups are built lazily by the first `GET /api/groups`, for the
        // same reason as albums: grouping reads every cached FeaturePrint and walks
        // the capture-time neighbourhood, which is minutes of work on a large
        // library and must not sit on the launch path.
        let groupEngine = SimilarGroupEngine(cache: cacheStore, library: library,
                                             settings: settings, bus: bus)
        let router = Router(cache: cacheStore, engine: engine, library: library,
                            settings: settings, bus: bus, images: ImageCache(),
                            albumIndex: albumIndex, groupEngine: groupEngine)
        let server = HTTPServer(port: options.port, router: router)

        do {
            try await server.start()
        } catch {
            await handleStartFailure(error, port: options.port)
            return
        }

        let authorization = await PhotoLibrary.requestAuthorization()
        let description = PhotoLibrary.authorizationDescription(authorization)
        Log.info("Photos authorization: \(description)")
        await engine.setAuthorization(description, hasAccess: PhotoLibrary.hasReadAccess(authorization))
        await engine.start()

        let url = "http://127.0.0.1:\(options.port)"
        announce(url: url, authorization: description)

        guard let interfaceURL = URL(string: url) else {
            // Cannot happen: the port is a `UInt16` and the host is a literal.
            Log.error("could not form the interface URL from \(url)")
            exit(1)
        }
        if options.presentation.opensBrowser {
            openBrowser(url: interfaceURL)
        } else {
            await hooks.present(interfaceURL)
        }

        let heartbeat = startHeartbeat(bus: bus)
        let signals = installSignalHandlers()
        hooks.shutdown.add { signals.trigger() }

        // The updater was built above, with `settings`; what is left is the check
        // itself. Detached, deliberately. This is the one thing in the launch
        // sequence that must not be able to delay the window: the check is
        // deferred a couple of seconds, needs no UI thread, and ends by `exit`ing
        // on success. Nothing else here may wait on it.
        Task.detached(priority: .background) { [updater] in
            await updater.checkOnLaunch()
        }

        // Run until the user interrupts the process or the window closes.
        // Analysis state is persisted continuously, so an abrupt exit loses at
        // most the asset in flight.
        for await _ in signals.stream {
            Log.info("shutting down")
            // Cancel first: a detached task is not a child of anything here and
            // would otherwise keep publishing into a bus that is about to close.
            heartbeat.cancel()
            await engine.shutdown()
            server.stop()
            bus.close()
            break
        }
        await hooks.didStop()
        exit(0)
    }

    private func announce(url: String, authorization: String) {
        var lines = ["", "  PhotoCleaner \(AppPaths.version)", ""]
        if authorization == "authorized" || authorization == "limited" {
            lines.append("  PhotoCleaner running at \(url)")
        } else {
            lines.append("  PhotoCleaner is running at \(url), but Photos access is \(authorization).")
            lines.append("  Grant access in System Settings › Privacy & Security › Photos and relaunch.")
        }
        lines.append("  Cache: \(AppPaths.cacheDatabase.path)")
        lines.append("  Log:   \(AppPaths.logFile.path)")
        lines.append("")
        let text = lines.joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(text.utf8))
        Log.info("listening on \(url) (loopback only)")
    }

    private func openBrowser(url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error {
                Log.warn("could not open the browser: \(error.localizedDescription)")
            }
        }
    }

    /// Raises the window of an already-running PhotoCleaner.
    ///
    /// This is what a second launch should do: opening the browser used to be the
    /// only option, and now that there is a window it is the wrong one. Returns
    /// false when there is no other instance to raise, so the caller can fall
    /// back rather than exit silently.
    private func focusRunningInstance() async -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        // `activate` is a window-server operation, and AppKit types it as one, so
        // it goes on the main actor even when this path runs in a presentation
        // that never started AppKit.
        return await MainActor.run {
            let siblings = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == identifier && $0.processIdentifier != mine
            }
            guard !siblings.isEmpty else { return false }
            // All of them, not just the first: one instance per port is a
            // supported way to run this.
            //
            // No `.activateIgnoringOtherApps`: it has been deprecated since
            // macOS 14 and does nothing. `activate` already brings the app
            // forward, which is the whole point of the gesture.
            return siblings.contains { $0.activate(options: [.activateAllWindows]) }
        }
    }

    /// A second launch should be harmless: if the port is taken but answers as
    /// PhotoCleaner, focus the instance that already owns it and exit.
    private func handleStartFailure(_ error: Error, port: UInt16) async {
        let address = "http://127.0.0.1:\(port)"
        if await PhotoCleanerApp.isRunningAt(port: port) {
            Log.info("PhotoCleaner is already running at \(address)")
            FileHandle.standardError.write(Data("\n  PhotoCleaner is already running at \(address)\n\n".utf8))

            let url = URL(string: address)
            switch options.presentation {
            case .window:
                // If there is no window to raise — the running instance has not
                // opened one yet — the browser still works, and is a better
                // answer than exiting having shown nothing at all.
                if await focusRunningInstance() == false, let url {
                    Log.info("no running instance to focus; falling back to the browser")
                    openBrowser(url: url)
                }
            case .browser:
                if let url { openBrowser(url: url) }
            case .headless:
                break
            }
            exit(0)
        }
        Log.error("could not start the HTTP server on port \(port): \(error)")
        FileHandle.standardError.write(Data("""

          PhotoCleaner could not listen on port \(port): \(error)
          Something else is using that port. Try: photo-cleaner --port 8766

        """.utf8))
        exit(1)
    }

    /// Probes loopback only — the sole network request this tool ever makes, and
    /// it never leaves the machine. Used purely to make a second launch behave
    /// like focusing the already-running instance.
    ///
    /// On its own session rather than `URLSession.shared`, because the shared one
    /// has a disk cache behind it and this response was being written into
    /// `~/Library/Caches`: `smoke-test.sh` holds the app to storing no HTTP
    /// response outside Application Support, and a stale one here would be worse
    /// than the disk write anyway — a cached 200 for a port whose server has since
    /// quit would report "already running" and focus nothing. Same reasoning, and
    /// the same session shape, as the updater's.
    private static func isRunningAt(port: UInt16) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            return String(decoding: data, as: UTF8.self).contains("\"version\"")
        } catch {
            return false
        }
    }

    /// Transport keep-alive for SSE connections that are otherwise idle.
    ///
    /// Runs detached because it must survive every `Task` the app creates, which
    /// is also why the caller keeps the handle: nothing else can cancel it, and
    /// a heartbeat that outlives `bus.close()` is a task publishing into a dead
    /// bus for the rest of the process lifetime.
    private func startHeartbeat(bus: EventBus) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    break // cancelled while sleeping
                }
                // Not `publish`: a comment frame is not state and must not
                // become the snapshot a newly subscribing browser receives.
                bus.broadcast(SSE.heartbeat)
            }
        }
    }

    /// SIGINT and SIGTERM, plus whatever the host pulls through the relay.
    ///
    /// Returns the trigger rather than closing over it so the same code serves
    /// both: a signal arrives on a dispatch queue, and the window's close button
    /// arrives on the main actor, and neither may reach into the other's world.
    private func installSignalHandlers() -> (stream: AsyncStream<Void>, trigger: @Sendable () -> Void) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        for signalNumber in [SIGINT, SIGTERM] {
            // Ignore the default disposition so the dispatch source below is
            // what actually handles it.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { continuation.yield() }
            source.resume()
            PhotoCleanerApp.signalSources.append(source)
        }
        // `continuation` is Sendable, so handing it to another isolation domain
        // is safe; the stream and the trigger must end the run loop together, and
        // only the run loop's owner may finish it.
        return (stream, { continuation.yield() })
    }

    private nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []
}
