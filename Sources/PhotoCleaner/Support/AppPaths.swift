import Foundation

/// Filesystem locations used by PhotoCleaner.
///
/// Everything the tool persists lives outside the Photos library, in the user's
/// own Application Support directory. Nothing is ever written next to, or
/// inside, `Photos Library.photoslibrary`.
enum AppPaths {
    /// The running app's version, read from the `CFBundleShortVersionString` that
    /// build.sh stamped into Info.plist.
    ///
    /// Deliberately not a constant here: a second copy of the version is a
    /// second thing to forget to bump, and the failure mode is a `--version`
    /// that lies. build.sh is the only place a version is written, and the
    /// release workflow takes it from the pushed tag, so what this prints is
    /// always the artifact the user actually downloaded.
    ///
    /// Falls back to "dev" only when there is no bundle to ask — the regression
    /// suite compiles these sources into a throwaway executable, which has no
    /// Info.plist of its own. A released app always runs inside its bundle.
    static let version: String = {
        let stamped = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let stamped, !stamped.isEmpty else { return "dev" }
        return stamped
    }()

    /// `~/Library/Application Support/PhotoCleaner`
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PhotoCleaner", isDirectory: true)
    }

    /// `~/Library/Application Support/PhotoCleaner/cache.sqlite`
    static var cacheDatabase: URL {
        supportDirectory.appendingPathComponent("cache.sqlite")
    }

    /// `~/Library/Application Support/PhotoCleaner/video-cache`
    ///
    /// Where `VideoLibrary` parks passthrough exports of clips the user has
    /// opened, so a clip is fetched from iCloud at most once per eviction cycle
    /// instead of once per play.
    ///
    /// Application Support rather than `~/Library/Caches`, and that is the whole
    /// argument: macOS offers to empty `Caches` when a disk runs low, and a user
    /// who accepts would silently lose every cached export — harmless — but the
    /// *same* directory being where the tool keeps the things it is supposed to
    /// keep is a worse habit than a stale file. It is also what keeps
    /// "PhotoCleaner writes nothing outside Application Support and Logs" true,
    /// which `smoke-test.sh` audits and the README promises. Nothing here is a
    /// derived value the user would miss: every file in it is reproducible from
    /// Photos by re-exporting, which is why `VideoLibrary` bounds it rather than
    /// treating it as storage.
    static var videoCacheDirectory: URL {
        supportDirectory.appendingPathComponent("video-cache", isDirectory: true)
    }

    /// `~/Library/Logs/PhotoCleaner/PhotoCleaner.log`
    static var logFile: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/PhotoCleaner/PhotoCleaner.log")
    }

    static func createDirectoryIfNeeded(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
