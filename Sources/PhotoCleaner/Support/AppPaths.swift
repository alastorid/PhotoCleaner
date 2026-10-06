import Foundation

/// Filesystem locations used by PhotoCleaner.
///
/// Everything the tool persists lives outside the Photos library, in the user's
/// own Application Support directory. Nothing is ever written next to, or
/// inside, `Photos Library.photoslibrary`.
enum AppPaths {
    static let bundleIdentifier = "com.alastorid.photocleaner"

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

    /// The GitHub repository releases are published to.
    ///
    /// One constant rather than something assembled from a build-time variable:
    /// `release.yml` publishes to the repository this URL names, and a build
    /// pointed at a feed that is not the one it was released from would install
    /// an unrelated app over the running one. A fork that publishes elsewhere
    /// should change it here, in the same commit that changes `make-dmg.sh`'s
    /// `gh release` target.
    static let releaseRepository = "alastorid/PhotoCleaner"

    /// `GET /repos/{owner}/{repo}/releases/latest` — the newest non-draft,
    /// non-prerelease release, which is exactly the one the update flow is
    /// allowed to install.
    static var updateFeedURL: URL? {
        URL(string: "https://api.github.com/repos/\(releaseRepository)/releases/latest")
    }

    /// The architecture this binary was built for, which is what decides which
    /// published asset can be installed.
    ///
    /// Decided at compile time rather than by asking `uname`, because a
    /// Rosetta-translated process reports `x86_64` while the app bundle on disk
    /// contains both slices — and asking for the `x86_64` DMG would then be
    /// answering a question about the translation rather than about the app.
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// `~/Library/Application Support/PhotoCleaner/update`
    ///
    /// Everything the updater writes lives under here, including the downloaded
    /// image and the outgoing bundle it moves aside. Application Support rather
    /// than `/tmp` because this is a resumable, user-visible amount of data; and
    /// under PhotoCleaner's own directory rather than anywhere else so that
    /// "PhotoCleaner writes nothing outside Application Support and Logs" —
    /// which `smoke-test.sh` checks — stays true with the updater in the app.
    static var updateDirectory: URL {
        supportDirectory.appendingPathComponent("update", isDirectory: true)
    }

    /// Where a release's DMG is downloaded to.
    static func downloadedUpdate(version: String, architecture: String) -> URL {
        updateDirectory.appendingPathComponent("PhotoCleaner-\(version)-\(architecture).dmg")
    }

    /// `~/Library/Application Support/PhotoCleaner/cache.sqlite`
    static var cacheDatabase: URL {
        supportDirectory.appendingPathComponent("cache.sqlite")
    }

    /// `~/Library/Logs/PhotoCleaner/PhotoCleaner.log`
    static var logFile: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/PhotoCleaner/PhotoCleaner.log")
    }

    /// The running executable, resolving the bundle layout when launched from a `.app`.
    static var executableDirectory: URL {
        let arg0 = CommandLine.arguments.first ?? ""
        if arg0.contains("/") {
            return URL(fileURLWithPath: arg0).resolvingSymlinksInPath().deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static func createDirectoryIfNeeded(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
