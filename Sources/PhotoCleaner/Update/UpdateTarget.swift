import Foundation

/// Where a downloaded release gets installed, decided *before* anything is
/// downloaded.
///
/// A plan rather than a path, because the swap needs three of them and the rule
/// that decides whether there can be a plan at all has to be readable on its own.
struct UpdatePlan: Sendable, Equatable {
    /// The bundle to replace: the one currently running.
    let bundleURL: URL
    /// A copy of the new bundle, inside Application Support.
    let stagedAppURL: URL
    /// Where the outgoing bundle is moved first, so a swap that fails halfway can
    /// be undone rather than leaving the user with no app at all.
    let backupAppURL: URL
    /// The updater's own directory. Everything it writes is under here, which is
    /// what keeps "PhotoCleaner writes nothing outside Application Support and
    /// Logs" true for the updater too — `smoke-test.sh` checks it.
    let scratchDirectory: URL
}

/// Why a location cannot be replaced, or that it can.
enum InstalledLocation: Sendable, Equatable {
    case writable
    /// A mounted disk image, or any volume marked read-only.
    case readOnlyVolume
    /// Writable in principle, but not by this process — the usual case is
    /// `/Applications` on a Mac where it needs authentication.
    case notWritable
    case notAnApplicationBundle
}

/// Resolves the install target.
///
/// The rules are split from the filesystem probe so they can be tested without
/// root and without touching `/Applications`: `plan(bundleURL:location:)` is a
/// pure function of its arguments, and only `locate(_:)` talks to the disk.
enum UpdateTarget {
    /// Whether this path is shaped like an application bundle.
    ///
    /// Checked by `plan` as well as by `locate`, and deliberately. `locate` is one
    /// caller that happens to answer this while classifying a location, but the
    /// rule belongs to the function that decides whether a plan exists: a caller
    /// that passed `.writable` for `/tmp/photocleaner-tests` must still be refused,
    /// not trusted to have classified it correctly.
    static func isApplicationBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app"
    }

    /// Classify a bundle by asking the filesystem the one question only it can
    /// answer.
    static func locate(_ bundleURL: URL) -> InstalledLocation {
        guard isApplicationBundle(bundleURL) else {
            return .notAnApplicationBundle
        }
        let parent = bundleURL.deletingLastPathComponent()
        // A bundle inside a mounted disk image is the state right after the user
        // dragged PhotoCleaner out of the DMG and before they let go. Replacing
        // it there writes into the image, and the write vanishes on eject — so
        // this is checked by path as well as by the volume's own flag, because
        // `hdiutil attach -rw` exists and a developer may well have used it.
        if parent.path == "/Volumes" || parent.path.hasPrefix("/Volumes/") {
            return .readOnlyVolume
        }
        // A read-only volume reports every file on it as unwritable, so this one call
        // covers the mounted-image case as well as a folder the user cannot write
        // to. The path check above is the extra part: `hdiutil attach -rw` makes a
        // writable-looking volume out of one that still must not be written to.
        //
        // Existence is checked first because `isWritableFile` answers `true` for a
        // path that is not there — it asks about the containing directory's
        // permission bits, and for a missing leaf that is a question about the
        // nearest directory that does exist. A parent that does not exist cannot
        // be swapped into, so it is not writable in any sense that matters here,
        // and reporting otherwise would let the plan be made and the swap fail
        // eleven seconds later, after a download.
        guard FileManager.default.fileExists(atPath: parent.path) else { return .notWritable }
        return FileManager.default.isWritableFile(atPath: parent.path) ? .writable : .notWritable
    }

    /// The plan, or the reason there isn't one.
    ///
    /// The version being replaced is not a parameter because nothing in the
    /// install reads it: the bundle's own `CFBundleShortVersionString` is the only
    /// statement of what is installed, and it is re-read from disk after the swap
    /// rather than carried here.
    static func plan(bundleURL: URL, location: InstalledLocation, scratch: URL) throws -> UpdatePlan {
        // First, and independent of `location`: see `isApplicationBundle`.
        guard isApplicationBundle(bundleURL) else {
            throw UpdateError.notSelfInstallable(
                "\(bundleURL.path) is not an application bundle, so there is nothing to replace")
        }
        // `.notAnApplicationBundle` cannot reach here — the guard above has
        // already refused it — but it is a case of the enum this function takes,
        // and leaving it out would be a `default` that silently accepted
        // whatever was added next.
        switch location {
        case .notAnApplicationBundle, .writable:
            break
        case .readOnlyVolume:
            throw UpdateError.notSelfInstallable(
                "it is running from a disk image (\(bundleURL.deletingLastPathComponent().path)). "
                + "Move PhotoCleaner to Applications first")
        case .notWritable:
            throw UpdateError.notSelfInstallable(
                "\(bundleURL.deletingLastPathComponent().path) is not writable. "
                + "Replacing PhotoCleaner in place needs write access to that folder")
        }

        let staged = scratch
            .appendingPathComponent("staged", isDirectory: true)
            .appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
        return UpdatePlan(
            bundleURL: bundleURL,
            stagedAppURL: staged,
            backupAppURL: scratch.appendingPathComponent("previous", isDirectory: true)
                .appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true),
            scratchDirectory: scratch
        )
    }

    /// Locate, then plan. The form production uses.
    static func plan(bundleURL: URL, scratch: URL) throws -> UpdatePlan {
        try plan(bundleURL: bundleURL, location: locate(bundleURL), scratch: scratch)
    }
}
