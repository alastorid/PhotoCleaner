import Foundation

/// Reads the one thing the updater needs out of `hdiutil`'s machine-readable
/// output.
///
/// `hdiutil attach -plist` writes a property list, not a line of text, and the
/// mount point is buried several levels down under `system-entities`. Parsing that
/// by hand — or, worse, scraping the human-readable `-verbose` output — is how an
/// updater ends up staging files from somewhere it did not mount.
enum DiskImagePlist {
    /// The single mount point in `hdiutil attach -plist` output.
    ///
    /// Requires exactly one: a multi-partition image reports several, and taking
    /// the first would be a guess about which volume holds the app. A missing or
    /// ambiguous mount point is an error rather than an empty path, so the caller
    /// fails before it stages anything.
    static func mountPoint(in data: Data) throws -> String {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any] else {
            throw UpdateError.installFailed("hdiutil did not return a property list")
        }
        guard let entities = root["system-entities"] as? [[String: Any]] else {
            throw UpdateError.installFailed("hdiutil reported no mounted volumes")
        }
        let mountPoints = entities
            .compactMap { $0["mount-point"] as? String }
            .filter { !$0.isEmpty }
        // `dev-entry` entities (the whole-disk device and the synthesized entries
        // for it) carry no mount point and are already filtered by the cast
        // above; what is left is the mounted volumes.
        switch mountPoints.count {
        case 1:
            return mountPoints[0]
        case 0:
            throw UpdateError.installFailed("the disk image mounted no volume")
        default:
            throw UpdateError.installFailed(
                "the disk image mounted \(mountPoints.count) volumes and it is not known which one to use")
        }
    }
}

/// Runs the four system tools an install needs, and owns the swap.
///
/// `hdiutil`, `ditto`, `xattr` and `open` all ship with macOS, which is the whole
/// reason this file has no dependencies: the project has no package manager and
/// no third-party runtime, and an updater that could not be shipped with the app
/// would not be an updater.
struct UpdateInstaller: Sendable {
    private enum Tool: String {
        case hdiutil = "/usr/bin/hdiutil"
        case ditto = "/usr/bin/ditto"
        case xattr = "/usr/bin/xattr"
        case open = "/usr/bin/open"
        case codesign = "/usr/bin/codesign"
        case shell = "/bin/sh"

        /// Every tool named by absolute path, never by `PATH` lookup. A build
        /// launched from a shell with a modified `PATH` must not resolve `ditto`
        /// out of somebody's `~/bin`.
        var url: URL { URL(fileURLWithPath: rawValue) }
    }

    /// What `run` hands back.
    struct Output: Sendable {
        let status: Int32
        let standardOutput: String
        let standardError: String

        var succeeded: Bool { status == 0 }
    }

    // MARK: - Tools

    /// Run one tool to completion and capture both streams.
    ///
    /// `async`, and not `waitUntilExit()`, for one reason: `ditto` of a bundle
    /// takes seconds, and blocking a cooperative thread for seconds is how an app
    /// beachballs during its own update. Foundation has no `async` `Process`
    /// entry point on this SDK, so the waiting is done with `terminationHandler`
    /// and a continuation.
    ///
    /// stdout and stderr are separate pipes on purpose. `hdiutil attach -plist`
    /// writes the plist to stdout and its human-readable progress to stderr, so
    /// merging the streams would put log text inside the document being parsed.
    /// Both are drained concurrently and on libdispatch threads, not the
    /// cooperative pool: a tool that fills one pipe while the parent waits on the
    /// other deadlocks, and a large `ditto` is exactly that case.
    private func run(_ tool: Tool, _ arguments: [String]) async throws -> Output {
        let process = Process()
        process.executableURL = tool.url
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let collector = OutputCollector()
        return try await withCheckedThrowingContinuation { continuation in
            collector.attach(continuation)
            process.terminationHandler = { finished in collector.exited(finished.terminationStatus) }
            // Draining starts before the process does, on purpose: a pipe holds a
            // fixed amount and the child does not care that anyone is reading.
            DispatchQueue.global(qos: .userInitiated).async {
                collector.drain(out.fileHandleForReading, as: .out)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                collector.drain(err.fileHandleForReading, as: .err)
            }
            do {
                try process.run()
            } catch {
                // Close the write ends, or the two drain threads block forever
                // on a pipe whose writer will now never exist.
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                collector.fail(error)
            }
        }
    }

    private enum Stream {
        case out, err
    }

    /// Gathers a finished child's two streams and resumes its continuation once.
    ///
    /// The condition for resuming is *both* streams drained **and** the process
    /// reaped. Anything weaker returns a truncated document, and a truncated
    /// `hdiutil` plist is one that parses as far as it goes and then reports a
    /// missing mount point — a failure that looks like a bad disk image rather
    /// than a race.
    private final class OutputCollector: @unchecked Sendable {
        private enum Pending {
            case none
            case ready(CheckedContinuation<Output, Error>, Output)
            case failed(CheckedContinuation<Output, Error>, Error)
        }

        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var draining = 0
        private var status: Int32?
        private var failure: Error?
        private var continuation: CheckedContinuation<Output, Error>?

        func attach(_ continuation: CheckedContinuation<Output, Error>) {
            lock.withLock { self.continuation = continuation }
        }

        /// Read one pipe to EOF on a libdispatch thread.
        /// Take the lock, run `body`, release it. Spelled out because `NSLock`
        /// carries no `withLock` — that is `OSAllocatedUnfairLock`'s shape, and this
        /// type needs `withLock`'s non-reentrant behaviour but has to be usable
        /// from a `defer` around a `return`.
        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        func drain(_ handle: FileHandle, as stream: Stream) {
            locked { draining += 1 }
            let data = handle.readDataToEndOfFile()
            append(data, as: stream)
        }

        private func append(_ data: Data, as stream: Stream) {
            locked {
                // A launch failure already resolved this continuation; a late EOF
                // must not decrement the counter of a run nobody is waiting on, or
                // it would settle a *second*, uncounted claim.
                guard continuation != nil else { return }
                switch stream {
                case .out: out.append(data)
                case .err: err.append(data)
                }
                draining -= 1
            }
            settle()
        }

        func exited(_ status: Int32) {
            locked { self.status = status }
            settle()
        }

        func fail(_ error: Error) {
            locked {
                guard continuation != nil else { return }
                failure = error
                draining = 0
            }
            settle()
        }

        private func settle() {
            let pending: Pending = locked {
                switch (continuation, failure, draining, status) {
                case (let continuation?, let error?, _, _):
                    self.continuation = nil
                    return .failed(continuation, error)
                case (let continuation?, nil, 0, let status?):
                    self.continuation = nil
                    return .ready(continuation, Output(
                        status: status,
                        standardOutput: String(decoding: out, as: UTF8.self),
                        standardError: String(decoding: err, as: UTF8.self)))
                default:
                    return .none
                }
            }
            switch pending {
            case .none:
                return
            case .ready(let continuation, let output):
                continuation.resume(returning: output)
            case .failed(let continuation, let error):
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Disk image

    /// Mount a downloaded DMG and return its volume.
    ///
    /// `-nobrowse` keeps the volume out of the Finder sidebar and `-noautoopen`
    /// keeps it from stealing focus; a user who clicks a progress arc should not
    /// watch a window open and close over their own app. Verification is left on:
    /// the image is small, and it is the check that a truncated download cannot
    /// become an installed app.
    func mount(_ image: URL) async throws -> URL {
        let output = try await run(.hdiutil, ["attach", "-plist", "-nobrowse", "-noautoopen",
                                              "-readonly", image.path])
        guard output.succeeded else {
            throw UpdateError.installFailed(detail(from: output, fallback: "the disk image would not mount"))
        }
        return URL(fileURLWithPath: try DiskImagePlist.mountPoint(in: Data(output.standardOutput.utf8)))
    }

    func unmount(_ volume: URL) async {
        // Best effort: a failure here leaks a read-only mount until logout, but
        // it must not turn a *successful* install into a reported failure, so the
        // status is logged rather than thrown.
        if let output = try? await run(.hdiutil, ["detach", volume.path]), !output.succeeded {
            Log.warn("could not detach \(volume.path): \(output.standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: - Staging

    /// Copy the mounted app to the staging path, and take the quarantine flag off.
    ///
    /// `ditto` rather than `cp` because it is the copy that preserves a bundle's
    /// extended attributes and therefore its code signature — a plain copy of a
    /// signed app is what makes `codesign --verify` start failing.
    ///
    /// The quarantine attribute *is* removed, deliberately, and this is the one
    /// place the updater is asking macOS to trust a download. The reasoning:
    /// releases are ad-hoc signed and un-notarized, so a quarantined copy would
    /// be refused by Gatekeeper at every launch — including the one this updater
    /// exists to perform — while the binary being installed is byte-identical to
    /// the one already installed and already running. The download URL is fixed
    /// to `api.github.com` over https, the asset name must match the release tag
    /// exactly, and the version inside the mounted image is re-read and compared
    /// to the tag before any of this happens (`verify(_:expects:)`).
    func stage(from mountedApp: URL, to stagedApp: URL) async throws {
        try FileManager.default.createDirectory(
            at: stagedApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = try await run(.ditto, [mountedApp.path, stagedApp.path])
        guard output.succeeded else {
            throw UpdateError.installFailed(detail(from: output, fallback: "the new app could not be copied"))
        }
        // A non-zero status here is not fatal: an image with no quarantine
        // attribute at all reports an error for `-d`. Only a real failure to
        // clear the attribute would be worth reporting, and that shows up as the
        // app failing to open afterwards — so the status is logged, not thrown.
        let cleared = try? await run(.xattr, ["-dr", "com.apple.quarantine", stagedApp.path])
        if let cleared, !cleared.succeeded {
            Log.warn("could not clear the quarantine attribute on the staged app: "
                     + cleared.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Read `CFBundleShortVersionString` out of a bundle on disk.
    ///
    /// Read from the `Info.plist` rather than through `Bundle`, because the
    /// staged and mounted bundles are not loadable by this process — loading a
    /// second bundle with the same identifier is how an app ends up reading its
    /// own `Info.plist` twice and comparing a version to itself.
    static func version(of appBundle: URL) throws -> String {
        let plist = appBundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = value["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            throw UpdateError.unreadableBundle(name: appBundle.lastPathComponent)
        }
        return version
    }

    /// Refuse an image whose contents do not match the tag that named it.
    ///
    /// The tag, the asset filename and the version inside the bundle are three
    /// separate claims about the same thing. All three agreeing is cheap to check
    /// and is what makes "it downloaded *this* release" a statement rather than
    /// an assumption.
    func verify(_ mountedApp: URL, expects expected: UpdateVersion) throws {
        let found = try Self.version(of: mountedApp)
        guard UpdateVersion(found) == expected else {
            throw UpdateError.wrongPayload(expected: expected.description, found: found)
        }
    }

    // MARK: - The swap

    /// Replace the running bundle with the staged one.
    ///
    /// Two moves, and the order is the whole design: the outgoing bundle goes to
    /// `previous/` *first*, so that from that instant there is always a complete,
    /// launchable app on disk. If the second move fails, the first is undone and
    /// the user is left with the version they were running, which is the only
    /// acceptable outcome for a failed update.
    ///
    /// Note what this does *not* check: `moveItem` succeeds for any directory, so a
    /// staged bundle that is not a usable app moves into place perfectly happily
    /// and this reports success. That is why `Updater` re-verifies the installed
    /// bundle afterwards and calls `rollBack(_:)` if it is not the release.
    func swap(stagedApp: URL, to bundle: URL, backup: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: backup)
        try manager.moveItem(at: bundle, to: backup)

        do {
            try manager.moveItem(at: stagedApp, to: bundle)
        } catch {
            Log.error("the swap failed (\(error.localizedDescription)); restoring the previous app")
            do {
                try manager.moveItem(at: backup, to: bundle)
                Log.info("restored the previous PhotoCleaner at \(bundle.path)")
            } catch let rollback {
                // Nothing left to launch where the app used to be. Say so loudly
                // and leave the backup in place: it is still a working app.
                Log.error("could not restore the previous app (\(rollback.localizedDescription)); "
                          + "a working copy is at \(backup.path)")
                throw UpdateError.installFailed(
                    "\(error.localizedDescription). A working copy is at \(backup.path) — move it back to \(bundle.path)")
            }
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }

    /// Undo a completed swap, because what landed is not the release.
    ///
    /// Moves the bad bundle aside rather than deleting it — it is the evidence, and
    /// it is also the only thing that explains why the user's app suddenly
    /// reverted. `previous/` is put back where it came from, so the user is left
    /// running what they were running.
    func rollBack(_ plan: UpdatePlan) {
        let manager = FileManager.default
        let aside = plan.scratchDirectory
            .appendingPathComponent("failed", isDirectory: true)
            .appendingPathComponent(plan.bundleURL.lastPathComponent)
        try? manager.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: aside)
        _ = try? manager.moveItem(at: plan.bundleURL, to: aside)
        do {
            try manager.moveItem(at: plan.backupAppURL, to: plan.bundleURL)
            Log.info("rolled back to the previous PhotoCleaner at \(plan.bundleURL.path); "
                     + "the rejected update is at \(aside.path)")
        } catch {
            Log.error("could not roll back to the previous app (\(error.localizedDescription)); "
                      + "a working copy is at \(plan.backupAppURL.path)")
        }
    }

    /// Whether a bundle still carries a signature macOS will accept.
    ///
    /// Checked on the staged copy rather than trusted, because `ditto` is the
    /// reason the signature usually survives and nothing about the copy *says* it
    /// did. A bundle that lost its signature is exactly the kind of thing that
    /// installs successfully and then refuses to launch — and it would do so after
    /// the running app had already been moved away.
    func signatureIsIntact(_ appBundle: URL) async -> Bool {
        guard let output = try? await run(.codesign, ["--verify", "--deep", "--strict", appBundle.path]) else {
            return false
        }
        return output.succeeded
    }

    /// Remove the staged and previous copies once an update has succeeded.
    ///
    /// Called after the new app has launched and reported for itself, not before:
    /// `previous/` is the rollback for a bad release, and deleting it in the
    /// seconds before the first launch of new code is throwing away the only way
    /// back.
    func tidy(_ plan: UpdatePlan) {
        let manager = FileManager.default
        try? manager.removeItem(at: plan.stagedAppURL)
        try? manager.removeItem(at: plan.backupAppURL)
        try? manager.removeItem(at: plan.scratchDirectory)
    }

    // MARK: - Restart

    /// Hand the relaunch to a shell that waits for this process to be gone.
    ///
    /// The new bundle cannot be launched until the old executable has exited, and
    /// the new executable *is* the file that was just replaced — so the wait has
    /// to happen in something outside this process. `/bin/sh` is that something:
    /// a detached shell that polls `kill -0` on our pid and then `open`s the
    /// bundle.
    ///
    /// `kill -0` is the check rather than `ps`: it is a permission probe that
    /// succeeds while the pid is alive and fails with `ESRCH` once it is reaped,
    /// and it needs no other process's arguments.
    func scheduleRelaunch(of bundle: URL, afterProcess pid: Int32) async throws {
        // The pid and the path are passed as positional parameters and never
        // interpolated into the script. A path containing a quote, a space or a
        // `$(...)` must not be able to become shell syntax.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        exec /usr/bin/open -a "$2"
        """
        let process = Process()
        process.executableURL = Tool.shell.url
        process.arguments = ["-c", script, "photocleaner-relaunch", String(pid), bundle.path]
        // Not inherited: the shell outlives this process, and a pipe to a
        // terminal that closes would turn its `open` into a failure.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.restartFailed(error.localizedDescription)
        }
        Log.info("scheduled a relaunch of \(bundle.path) once pid \(pid) exits")
    }

    // MARK: - Errors

    /// Turn a failed tool into a sentence.
    ///
    /// `hdiutil` and `ditto` both put the useful part on stderr, and both have
    /// been known to lead with a bare "Error", so the fallback only applies when
    /// there is genuinely nothing to report.
    private func detail(from output: Output, fallback: String) -> String {
        let text = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "\(fallback) (exit \(output.status))" }
        // Tool output can be many lines; the first two carry the cause and the
        // rest is usually the same sentence repeated per volume.
        let lines = text.split(separator: "\n").prefix(2).joined(separator: " ")
        return lines.isEmpty ? "\(fallback) (exit \(output.status))" : lines
    }
}
