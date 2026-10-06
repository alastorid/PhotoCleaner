import Foundation
import os

/// Checks for a new release, downloads it, installs it over the running app and
/// restarts it.
///
/// One actor for the whole flow because the flow is a state machine with exactly
/// one writer: a second check arriving while a download is running must not be
/// able to start a second download, and the UI must never be able to ask for the
/// same phase twice. Every transition goes through `publish(_:)`, so what the
/// title bar draws and what is written to the log cannot disagree.
///
/// Nothing here asks permission. The window's progress arc is the whole
/// affordance: clicking it means "do this now", and the app replaces itself. The
/// one thing it does not do is fail quietly — every outcome is reported, because
/// an app that silently stops being the version it was is worse than one that
/// explains why it is still the old one.
actor Updater {
    /// Where the flow has got to.
    ///
    /// `offered` carries *which* update, so the phase cases stay about progress
    /// and two states can never disagree about the version in play.
    enum Phase: Sendable, Equatable {
        /// Nothing has been established yet this launch.
        case idle
        case checking
        /// Checked, and this build is already the newest published.
        case upToDate
        /// Checked, and a newer release exists and has not been installed.
        case available
        case downloading(received: Int64, expected: Int64?)
        /// Image downloaded, app being staged and swapped into place.
        case installing
        /// Installed; the relaunch is waiting for this process to exit.
        case restarting
        /// The last attempt failed. The message is the user-facing one.
        case failed(String)

        /// 0…1 while there is progress to report, nil otherwise.
        ///
        /// Nil rather than 0 or 1 for "not downloading" so a caller cannot paint
        /// a full ring for a state that has no ring: an empty ring and a complete
        /// one are different claims.
        var fraction: Double? {
            guard case .downloading(let received, let expected) = self else { return nil }
            guard let expected, expected > 0 else { return nil }
            return min(max(Double(received) / Double(expected), 0), 1)
        }

        /// True while the flow owns the app: a click must be ignored rather than
        /// starting a second download over the first.
        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing, .restarting: return true
            case .idle, .upToDate, .available, .failed: return false
            }
        }

        /// What happens when the arc is clicked in this phase.
        var isActionable: Bool {
            switch self {
            case .available, .upToDate, .idle, .failed: return true
            case .checking, .downloading, .installing, .restarting: return false
            }
        }
    }

    /// The state the title bar draws, in one value.
    struct Status: Sendable, Equatable {
        var phase: Phase = .idle
        /// The release waiting to be installed, when there is one.
        var offered: AvailableUpdate?
        /// The running version, so the title bar can say "up to date" honestly
        /// rather than only showing a spinner.
        var installedVersion: UpdateVersion?
        /// Whether the automatic launch check is on. Carried here rather than read
        /// from `Settings` by the menu, so the checkmark and the check cannot
        /// disagree: this is the value the updater will actually act on.
        var automaticChecks: Bool = true
    }

    /// How an explicit request ended. Only the caller needs this; the title bar
    /// reads `Status` instead.
    enum Outcome: Sendable, Equatable {
        case installed(version: UpdateVersion)
        /// Checked, and there was nothing newer. Reached by a deliberate click,
        /// which is the only moment it is interesting.
        case alreadyCurrent(version: UpdateVersion)
        case failed(String)
    }

    /// How often the automatic check may run.
    ///
    /// One a day is the whole of it: a check is one HTTPS request that asks
    /// whether a tag exists, and an app that checks on every launch is an app
    /// that makes a network request every time it starts.
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    private let settings: Settings
    private let installer: UpdateInstaller
    private let feedURL: URL?
    private let currentVersion: UpdateVersion?
    private let bundleURL: URL
    private let architecture: String
    private let processIdentifier: Int32

    private var status = Status()
    private var observers: [UUID: @MainActor (Status) -> Void] = [:]

    init(settings: Settings, installer: UpdateInstaller = UpdateInstaller(),
         feedURL: URL? = AppPaths.updateFeedURL,
         currentVersion: String = AppPaths.version,
         bundleURL: URL = Bundle.main.bundleURL,
         architecture: String = AppPaths.architecture,
         processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.settings = settings
        self.installer = installer
        self.feedURL = feedURL
        // A build with no stamped version (`dev`) parses to nothing, and a build
        // with an unreadable one likewise. Both mean the same thing to the
        // updater: there is no honest answer to "is this newer", so it declines
        // rather than guessing.
        self.currentVersion = UpdateVersion(currentVersion)
        self.bundleURL = bundleURL
        self.architecture = architecture
        self.processIdentifier = processIdentifier
        status.installedVersion = self.currentVersion
        status.automaticChecks = settings.snapshot().checkForUpdates
        if self.currentVersion == nil {
            Log.warn("no readable version stamp (\"\(currentVersion)\"); self-update is disabled")
        }
    }

    /// The state, for a caller that only wants to read it once.
    var current: Status { status }

    /// Turn the launch check on or off, checking immediately when turning it on.
    ///
    /// Enabling has to act now. A setting that records "yes, check on launch" and
    /// then waits for the next launch is a setting that looks broken for as long
    /// as the app stays open, which is the whole of the session in which someone
    /// usually changes it.
    func setAutomaticChecks(_ enabled: Bool) async {
        settings.update { $0.checkForUpdates = enabled }
        status.automaticChecks = enabled
        publish(status.phase)
        guard enabled else { return }
        await check()
    }

    // MARK: - Observation

    /// Register for state changes, immediately receiving the current state.
    ///
    /// Delivered on the main actor because every observer is AppKit: the title
    /// bar arc and the menu item. The handler is stored as a `@MainActor`
    /// function rather than a plain `@Sendable` one so an observer does not have
    /// to hop itself on every progress tick.
    @discardableResult
    func observe(_ handler: @escaping @MainActor (Status) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        let snapshot = status
        Task { @MainActor in handler(snapshot) }
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func publish(_ phase: Phase) {
        status.phase = phase
        let snapshot = status
        for handler in observers.values {
            Task { @MainActor in handler(snapshot) }
        }
    }

    // MARK: - The automatic check

    /// Check on launch, if the user has not turned that off.
    ///
    /// `actor`-isolated and therefore already serialized against a click: a click
    /// arriving during this is refused by `Phase.isBusy`, and one arriving before
    /// it has started is only superseded if the user genuinely checked a moment
    /// ago.
    func checkOnLaunch(after delay: Duration = .seconds(2)) async {
        guard settings.snapshot().checkForUpdates else { return }
        guard currentVersion != nil else { return }

        let last = settings.snapshot().lastUpdateCheck
        if let last, Date().timeIntervalSince(last) < Self.automaticCheckInterval {
            Log.info("update check skipped; last ran \(Int(Date().timeIntervalSince(last)) / 60) minute(s) ago")
            return
        }

        // Not on the launch path: the window is up and the library scan is
        // starting, and a network round trip has no business competing with that.
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        await check(record: true)
    }

    /// Ask the feed what the newest release is.
    ///
    /// `record` writes the timestamp, so a manual check resets the daily
    /// interval: checking because you clicked should mean the launch check has
    /// just been done.
    @discardableResult
    func check(record: Bool = true) async -> AvailableUpdate? {
        guard !status.phase.isBusy else { return status.offered }

        guard let installed = currentVersion else {
            publish(.failed(UpdateError.notSelfInstallable(
                "this build carries no version to compare against").description))
            return nil
        }
        guard let feedURL else {
            publish(.failed(UpdateError.malformedRelease("no update feed is configured").description))
            return nil
        }

        publish(.checking)
        defer { if record { settings.update { $0.lastUpdateCheck = Date() } } }

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        do {
            var request = URLRequest(url: feedURL)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("PhotoCleaner/\(installed)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body: Data
            switch try UpdateCheck.outcome(statusCode: code, body: data) {
            case .noReleases:
                // Not a failure — `FeedOutcome` says why, and says so in one place.
                // Reporting it as one would leave a red icon in the title bar
                // permanently on any repository that has not shipped a release, and
                // would tell someone who clicked the arc that something was wrong
                // when there is nothing to install.
                status.offered = nil
                publish(.upToDate)
                Log.info("\(AppPaths.releaseRepository) has published no release; nothing to update to")
                return nil
            case .release(let payload):
                body = payload
            }

            switch try UpdateCheck.offer(from: body, installed: installed, architecture: architecture) {
            case .none:
                status.offered = nil
                publish(.upToDate)
                Log.info("PhotoCleaner \(installed) is the newest published release")
            case .some(let offer):
                status.offered = offer
                publish(.available)
                Log.info("PhotoCleaner \(offer.version) is available (this build is \(installed))")
            }
        } catch {
            // A failed check must never *replace* a known offer: a flaky network
            // on the second poll would otherwise take away the update the user
            // already has a button for.
            publish(.failed(Self.message(for: error)))
            Log.warn("update check failed: \(error)")
            return status.offered
        }
        return status.offered
    }

    // MARK: - The full flow

    /// Check if needed, then download, install and restart.
    ///
    /// This is what a click on the progress arc means. There is no confirmation
    /// step, by design: the affordance is a control labelled with what it does,
    /// and asking again would make the app's own title bar a dialog it had already
    /// answered.
    @discardableResult
    func start() async -> Outcome {
        if status.phase.isBusy { return .failed("an update is already in progress") }

        let offer: AvailableUpdate
        if let known = status.offered, status.phase.isActionable {
            offer = known
        } else {
            await check()
            guard let found = status.offered else {
                // Either current, or the check failed — in both cases the phase
                // already says which.
                if case .upToDate = status.phase, let version = currentVersion {
                    return .alreadyCurrent(version: version)
                }
                return .failed(Self.message(for: status.phase))
            }
            offer = found
        }

        do {
            let plan = try installPlan(for: offer)
            try await download(offer, into: plan)
            try await install(offer, plan: plan)
            try await relaunch(plan: plan, version: offer.version)
            return .installed(version: offer.version)
        } catch {
            let message = Self.message(for: error)
            publish(.failed(message))
            Log.error("update failed: \(error)")
            return .failed(message)
        }
    }

    /// Forget a known update and go back to "nothing known".
    ///
    /// Used after an install and when a manual check finds nothing, so a stale
    /// offer cannot outlive the version it referred to.
    func reset() {
        status.offered = nil
        publish(.idle)
    }

    // MARK: - Steps

    /// Where this update will be installed, before anything is downloaded.
    ///
    /// Refusing early is the point: finding out after a 15 MB download that the
    /// app is running from a mounted disk image wastes the user's bandwidth to
    /// deliver a message that was knowable at launch.
    private func installPlan(for offer: AvailableUpdate) throws -> UpdatePlan {
        guard let installed = currentVersion else {
            throw UpdateError.notSelfInstallable("this build carries no version")
        }
        let plan = try UpdateTarget.plan(bundleURL: bundleURL, installed: installed,
                                         scratch: AppPaths.updateDirectory)
        Log.info("update plan: \(plan.bundleURL.path) <- \(offer.asset.name)")
        return plan
    }

    private func download(_ offer: AvailableUpdate, into plan: UpdatePlan) async throws {
        try FileManager.default.createDirectory(at: plan.scratchDirectory, withIntermediateDirectories: true)
        let destination = plan.scratchDirectory.appendingPathComponent(offer.asset.name)
        // A previous run may have left a partial file; `ditto` would then stage
        // the *old* truncated image.
        try? FileManager.default.removeItem(at: destination)

        let session = makeSession()
        let transfer = Download()
        defer { session.finishTasksAndInvalidate() }

        transfer.onProgress { [weak self] received, expected in
            // Arrives on the session's delegate queue, not the actor.
            Task { await self?.noteProgress(received: received, expected: expected) }
        }
        transfer.destination = destination

        // The feed's `size`, when it gave one. An estimate for the arc until the first
        // progress callback reports a real content length, at which point that wins
        // — the header is authoritative and the feed's number is only a guess.
        let declared: Int64? = offer.asset.size.map(Int64.init)
        publish(.downloading(received: 0, expected: declared))
        var request = URLRequest(url: try assetURL(for: offer))
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("PhotoCleaner/\(status.installedVersion?.description ?? "dev")",
                         forHTTPHeaderField: "User-Agent")
        let image = try await transfer.run(request, in: session)
        guard image == destination else {
            throw UpdateError.downloadFailed("the download landed in the wrong place")
        }
        // The arc is about to become a ring with no progress left to describe;
        // saying "installing" is the honest state for the seconds the swap takes.
        publish(.installing)
    }

    private func assetURL(for offer: AvailableUpdate) throws -> URL {
        // Re-checked at the point of use, not only in `UpdateCheck`: this is the
        // URL that will actually be fetched, and it is the last place before a
        // write to disk.
        guard let url = URL(string: offer.asset.browserDownloadURL), url.scheme == "https" else {
            throw UpdateError.downloadFailed("the asset URL is not https")
        }
        return url
    }

    private func noteProgress(received: Int64, expected: Int64?) {
        guard case .downloading = status.phase else { return }
        publish(.downloading(received: received, expected: expected))
    }

    private func install(_ offer: AvailableUpdate, plan: UpdatePlan) async throws {
        let image = plan.scratchDirectory.appendingPathComponent(offer.asset.name)
        guard FileManager.default.fileExists(atPath: image.path) else {
            throw UpdateError.installFailed("the downloaded image is missing")
        }
        publish(.installing)

        let volume = try await installer.mount(image)
        do {
            // The app inside the image is named by the bundle on disk, not
            // guessed: a volume containing something *other* than
            // `PhotoCleaner.app` is not a layout this updater should install
            // from, whatever the file inside it claims to be.
            let mountedApp = volume.appendingPathComponent("PhotoCleaner.app", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: mountedApp.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw UpdateError.installFailed("the disk image does not contain PhotoCleaner.app")
            }
            try installer.verify(mountedApp, expects: offer.version)
            try await installer.stage(from: mountedApp, to: plan.stagedAppURL)
            // Two checks on the *copy*, taken before anything irreversible. The
            // version is re-read because `ditto` is the only reason it survived,
            // and the signature is checked because a bundle that lost it installs
            // cleanly and then refuses to launch — after the running app has been
            // moved out of the way.
            try installer.verify(plan.stagedAppURL, expects: offer.version)
            guard await installer.signatureIsIntact(plan.stagedAppURL) else {
                throw UpdateError.installFailed("the copied app did not keep its signature")
            }
        } catch {
            // Detach even on failure: a leaked read-only volume sits in the
            // Finder sidebar until logout, and the user has no way to know this
            // updater put it there.
            await installer.unmount(volume)
            throw error
        }
        await installer.unmount(volume)

        try await installer.swap(stagedApp: plan.stagedAppURL, to: plan.bundleURL, backup: plan.backupAppURL)
        Log.info("installed PhotoCleaner \(offer.version) at \(plan.bundleURL.path)")

        // The last check, on the thing that is actually installed now. `swap` only
        // moves directories, so it reports success for a bundle that is not a
        // usable app; this catches that, and the rollback is what stops it being
        // the state the user is left in.
        do {
            try installer.verify(plan.bundleURL, expects: offer.version)
        } catch {
            installer.rollBack(plan)
            throw error
        }
    }

    /// Hand the new app a shell to launch itself once this process is gone.
    private func relaunch(plan: UpdatePlan, version: UpdateVersion) async throws {
        publish(.restarting)
        do {
            try await installer.scheduleRelaunch(of: plan.bundleURL, afterProcess: processIdentifier)
        } catch {
            // The swap already happened, so the app on disk is the new one and the
            // user has to open it. Say exactly that — "the update failed" would be
            // false, and telling them to try again would install it twice.
            installer.tidy(plan)
            throw error
        }
        Log.info("PhotoCleaner \(version) is installed; restarting")
        await shutdown()
    }

    // MARK: - Leaving

    /// Ask the app to stop, so the new bundle can be launched.
    ///
    /// `processIdentifier` is the *old* app's pid, and the shell is polling it, so
    /// exiting is what releases the new one. There is no way to launch the new
    /// bundle from inside this process: the executable it would run is the file
    /// that was just replaced, and the only copy of it still mapped is this one.
    private func shutdown() async {
        Log.info("exiting for the update restart")
        exit(0)
    }

    // MARK: - Helpers

    /// A session that leaves no trace.
    ///
    /// `ephemeral` with the cache and cookie storage removed is not tidiness: it
    /// is what keeps `smoke-test.sh`'s check that the URL cache holds no response
    /// true now that the app makes a request off the machine. A cached release
    /// feed would also mean a user on a plane could be told they were up to date
    /// for as long as the cache entry lived.
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The user agent is set per request; this stops Foundation appending its
        // own so the feed sees one stable identity.
        configuration.httpAdditionalHeaders = nil
        return URLSession(configuration: configuration)
    }

    private static func message(for error: any Error) -> String {
        (error as? UpdateError)?.description ?? error.localizedDescription
    }

    private static func message(for phase: Phase) -> String {
        if case .failed(let message) = phase { return message }
        return "the update did not finish"
    }
}

/// One download, with progress, that leaves the file where the installer wants it.
///
/// Delegate-driven rather than `URLSession.download(for:delegate:)` because of
/// where the bytes end up: that method hands back a temporary URL, and the file
/// under it is deleted when the delegate call that produced it returns. Moving it
/// here, inside `didFinishDownloadingTo`, is the only point at which the file is
/// guaranteed to still exist.
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<URL, Error>?
        var destination: URL?
        var onProgress: (@Sendable (Int64, Int64?) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var destination: URL? {
        get { state.withLock { $0.destination } }
        set { state.withLock { $0.destination = newValue } }
    }

    func onProgress(_ handler: @escaping @Sendable (Int64, Int64?) -> Void) {
        state.withLock { $0.onProgress = handler }
    }

    func run(_ request: URLRequest, in session: URLSession) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.continuation = continuation }
            session.downloadTask(with: request).resume()
        }
    }

    /// Claim the continuation exactly once.
    ///
    /// `didCompleteWithError` fires *after* `didFinishDownloadingTo`, so without
    /// the claim a successful download would be followed by a nil-error completion
    /// resuming an already-resumed continuation — a crash, not a bug report.
    private func settle(_ result: Result<URL, Error>) {
        let continuation = state.withLock { current -> CheckedContinuation<URL, Error>? in
            defer { current.continuation = nil; current.onProgress = nil }
            return current.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let handler = state.withLock { $0.onProgress }
        // A zero total means the length was not in the headers; reported as
        // unknown rather than as 100%, so the arc does not claim to be finished
        // on an unknown amount of data.
        handler?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let target = state.withLock { $0.destination }
        guard let target else {
            settle(.failure(UpdateError.downloadFailed("no destination for the download")))
            return
        }
        guard let http = downloadTask.response as? HTTPURLResponse else {
            settle(.failure(UpdateError.downloadFailed("the download had no HTTP response")))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            settle(.failure(UpdateError.downloadFailed("the server answered HTTP \(http.statusCode)")))
            return
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: target)
            settle(.success(target))
        } catch {
            settle(.failure(UpdateError.downloadFailed(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return } // success; `didFinishDownloadingTo` settled it
        settle(.failure(UpdateError.downloadFailed(error.localizedDescription)))
    }
}
