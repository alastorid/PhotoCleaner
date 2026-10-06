import Foundation
import os

/// User-visible preferences, persisted as JSON in Application Support.
///
/// Deliberately *not* `UserDefaults`: the tool can be launched either from the
/// `.app` bundle or straight from a terminal, and those two launch modes would
/// otherwise resolve to different defaults domains. One explicit file keeps the
/// behaviour identical in both cases, and makes "delete my settings" trivial.
struct SettingsSnapshot: Sendable, Equatable, Codable {
    /// Allow PhotoKit to reach iCloud for assets whose original is not on disk.
    /// Off by default so that a first run never silently downloads a library.
    var downloadFromICloud: Bool = false

    /// How Similar Groups are built and ranked.
    ///
    /// Stored inline rather than as a nested object so an existing `settings.json`
    /// written before these fields existed still decodes — every new field has a
    /// default in its declaration. See `SimilarGroupSettings` for what each knob
    /// means and how the defaults were measured.
    var groupWindowSeconds: Double = SimilarGroupSettings.default.windowSeconds
    var groupMaxDistance: Float = SimilarGroupSettings.default.maxDistance
    var groupFaceWeight: Float = SimilarGroupSettings.default.faceWeight
    var groupMinimumFaceArea: Float = SimilarGroupSettings.default.minimumFaceAreaFraction
    var groupMaximumSize: Int = SimilarGroupSettings.default.maximumGroupSize

    /// The group settings, assembled and clamped.
    ///
    /// One place, so the value used by the builder, the router and the status
    /// document cannot drift from each other or from what is on disk.
    var similarGroups: SimilarGroupSettings {
        SimilarGroupSettings(
            windowSeconds: groupWindowSeconds,
            maxDistance: groupMaxDistance,
            faceWeight: groupFaceWeight,
            minimumFaceAreaFraction: groupMinimumFaceArea,
            maximumGroupSize: groupMaximumSize
        ).validated()
    }

    /// Exclude favourites from bulk selection and deletion unless explicitly
    /// overridden per request. On by default, and never changed implicitly.
    var protectFavorites: Bool = true

    /// Bounded Vision concurrency. Measured on an M3: 4 concurrent analyses
    /// reach the same throughput as 1 (Vision serialises internally), so the
    /// extra parallelism only overlaps image decode with inference.
    var analysisConcurrency: Int = 4

    /// Longest edge, in pixels, of the image handed to Vision.
    ///
    /// Measured: scores are stable from 512 px up (1024 vs 2048 differ by
    /// < 0.02), while 256 px drifts by up to 0.135 for the same asset. 1024 is
    /// the cheapest point on the plateau: ~4 MB RGBA per in-flight image, and
    /// no full-resolution HEIC/RAW decode.
    var analysisPixelSize: Int = 1024

    /// Look for a new release on launch.
    ///
    /// On by default, because a released build is a released artifact: the whole
    /// point of a tag is that something changed, and a user left on 1.0.0 with a
    /// security fix in 1.0.1 has no other way to find out. What it costs is one
    /// HTTPS request that reads a public JSON document, at most once a day.
    ///
    /// It never blocks anything. The check is deferred a couple of seconds past
    /// launch, its result is a state the window draws, and a failure is one line
    /// in the log — the app does not wait for GitHub to start working.
    var checkForUpdates: Bool = true

    /// When the last update check ran, at all — automatic or manual.
    ///
    /// Stored so "check on launch" is really "check on launch, but not more than
    /// once a day", and so a manual check resets the interval: someone who just
    /// checked by hand has done what the launch check would have done.
    ///
    /// Not clamped or validated: a clock that jumps backwards produces a
    /// timestamp in the future, which `Updater.checkOnLaunch` reads as "checked
    /// very recently" and simply skips once. That is the harmless direction.
    var lastUpdateCheck: Date?

    /// Every preference at its declared default.
    ///
    /// Explicit because writing `init(from:)` below suppresses the synthesized
    /// memberwise initialiser, and this is exactly what `Settings.load` needs for a
    /// missing or unreadable file: the defaults, without throwing.
    init() {}

    /// Decodes a `settings.json` written by *any* version of PhotoCleaner.
    ///
    /// Written out rather than synthesized, because a synthesized `init(from:)`
    /// requires every key to be present and a Swift property's default is **not** a
    /// decode fallback. The synthesized decoder therefore failed on any file
    /// written before a field existed, and `Settings.load` — which has no way to
    /// tell that apart from a corrupt file — silently fell back to all defaults.
    /// The result was that adding any preference reset every preference: a user
    /// who had turned off iCloud downloads lost that, and their favourite
    /// protection and tuned concurrency with it, silently, on upgrade.
    ///
    /// `decodeIfPresent` against the declared default is what makes the promise in
    /// this type's own documentation true: an old file loads, keeps what it had,
    /// and takes the default only for what it never had.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One source of truth for the defaults: the values this type's property
        // declarations already carry, read off a fully-defaulted instance rather
        // than written out a second time here where the two copies could drift.
        let fallback = SettingsSnapshot()
        downloadFromICloud = try container.decodeIfPresent(Bool.self, forKey: .downloadFromICloud)
            ?? fallback.downloadFromICloud
        groupWindowSeconds = try container.decodeIfPresent(Double.self, forKey: .groupWindowSeconds)
            ?? fallback.groupWindowSeconds
        groupMaxDistance = try container.decodeIfPresent(Float.self, forKey: .groupMaxDistance)
            ?? fallback.groupMaxDistance
        groupFaceWeight = try container.decodeIfPresent(Float.self, forKey: .groupFaceWeight)
            ?? fallback.groupFaceWeight
        groupMinimumFaceArea = try container.decodeIfPresent(Float.self, forKey: .groupMinimumFaceArea)
            ?? fallback.groupMinimumFaceArea
        groupMaximumSize = try container.decodeIfPresent(Int.self, forKey: .groupMaximumSize)
            ?? fallback.groupMaximumSize
        protectFavorites = try container.decodeIfPresent(Bool.self, forKey: .protectFavorites)
            ?? fallback.protectFavorites
        analysisConcurrency = try container.decodeIfPresent(Int.self, forKey: .analysisConcurrency)
            ?? fallback.analysisConcurrency
        analysisPixelSize = try container.decodeIfPresent(Int.self, forKey: .analysisPixelSize)
            ?? fallback.analysisPixelSize
        checkForUpdates = try container.decodeIfPresent(Bool.self, forKey: .checkForUpdates)
            ?? fallback.checkForUpdates
        lastUpdateCheck = try container.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
    }
}

final class Settings: Sendable {
    private let state: OSAllocatedUnfairLock<SettingsSnapshot>
    private let url: URL

    init(url: URL = AppPaths.supportDirectory.appendingPathComponent("settings.json")) {
        self.url = url
        let loaded = Settings.load(from: url)
        self.state = OSAllocatedUnfairLock(initialState: loaded)
    }

    private static func load(from url: URL) -> SettingsSnapshot {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SettingsSnapshot.self, from: data) else {
            return SettingsSnapshot()
        }
        return decoded
    }

    func snapshot() -> SettingsSnapshot {
        state.withLock { $0 }
    }

    @discardableResult
    func update(_ mutate: @Sendable (inout SettingsSnapshot) -> Void) -> SettingsSnapshot {
        // `withLock` hands the closure an `inout` view of the stored state, so
        // the mutation must be applied in place. Mutating a copy and returning
        // it would leave the in-memory value stale while still persisting the
        // new one to disk.
        let updated = state.withLock { current -> SettingsSnapshot in
            mutate(&current)
            current.analysisConcurrency = min(max(current.analysisConcurrency, 1), 16)
            current.analysisPixelSize = min(max(current.analysisPixelSize, 256), 4096)
            // The group knobs go through the same `validated()` the readers use, so
            // a hand-edited `settings.json` is clamped identically no matter which
            // path reads it next.
            let groups = current.similarGroups
            current.groupWindowSeconds = groups.windowSeconds
            current.groupMaxDistance = groups.maxDistance
            current.groupFaceWeight = groups.faceWeight
            current.groupMinimumFaceArea = groups.minimumFaceAreaFraction
            current.groupMaximumSize = groups.maximumGroupSize
            return current
        }
        persist(updated)
        return updated
    }

    private func persist(_ snapshot: SettingsSnapshot) {
        do {
            try AppPaths.createDirectoryIfNeeded(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            Log.warn("could not persist settings: \(error.localizedDescription)")
        }
    }
}
