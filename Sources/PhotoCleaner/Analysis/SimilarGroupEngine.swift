import Foundation
import Photos
import Vision

/// Builds Similar Groups and ranks their members.
///
/// ## Staged, not library-wide
///
/// The three tiers are kept apart because they cost wildly different amounts and
/// answer different questions:
///
/// 1. **FeaturePrint** — one per asset, computed during the ordinary analysis run
///    because the image is already decoded and the request costs 4.4 ms (measured,
///    1024 px input). Cached in `asset_signals`.
/// 2. **Grouping** — `creationDate` restricted to a capture-time neighbourhood,
///    then FeaturePrint distance. Read from the cache; no image is decoded.
/// 3. **Face capture quality** — 7.1 ms per image, so it runs *only* for members
///    of a group of two or more. Never library-wide.
///
/// ## Why a rebuild is a background pass
///
/// Grouping reads every FeaturePrint and walks the neighbourhood — ~3.9 million
/// distance comparisons on a 53k library. Doing that in a request handler would
/// block the server for minutes, so a rebuild runs detached, publishes progress,
/// and browsing serves whatever the last completed pass stored. A rebuild is
/// therefore always a *consistent snapshot*: groups are replaced in one
/// transaction, never row by row while a reader walks them.
actor SimilarGroupEngine {
    private let cache: CacheStore
    private let library: PhotoLibrary
    private let settings: Settings
    private let analyzer: VisionAnalyzer
    private let bus: EventBus

    private var running = false
    private var lastBuiltAt: Date?
    private var lastError: String?
    /// The settings the stored groups were built under, so a settings change can
    /// mark them stale instead of silently serving groups built by other rules.
    private var lastBuiltSettings: SimilarGroupSettings?
    /// Set once per pass: the members still awaiting face analysis, read in one
    /// query so a page of groups does not each re-ask the database.
    private var faceBacklog: Set<String> = []
    /// Hands out queue positions to the face-analysis workers. Actor state, so two
    /// tasks pulling from it cannot receive the same position.
    private var faceCursor = 0

    init(cache: CacheStore, library: PhotoLibrary, settings: Settings, bus: EventBus) {
        self.cache = cache
        self.library = library
        self.settings = settings
        self.analyzer = VisionAnalyzer()
        self.bus = bus
    }

    /// Progress and staleness, as served to the UI.
    struct Status: Sendable, Codable {
        var building = false
        /// Groups from the last completed pass.
        var groupCount = 0
        /// Photos currently in some group.
        var groupedAssets = 0
        /// Assets holding a FeaturePrint, i.e. how much of the library grouping
        /// can see at all.
        var featurePrints = 0
        /// Group members still waiting for face capture quality.
        var facesPending = 0
        var facesAnalyzed = 0
        var lastBuiltAt: Double?
        /// True when the stored groups were built under different settings than the
        /// current ones and should be rebuilt before they are trusted.
        var stale = false
        var lastError: String?
    }

    func status() async -> Status {
        var result = Status()
        result.building = running
        result.lastBuiltAt = lastBuiltAt?.timeIntervalSince1970
        result.lastError = lastError
        if let counts = try? await cache.signalCounts() {
            result.featurePrints = counts.featurePrints
            result.facesAnalyzed = counts.faceCaptureQualities
        }
        if let page = try? await cache.groupSummaries(limit: 1, offset: 0) {
            result.groupCount = page.total
            result.groupedAssets = page.groups.first?.memberCount ?? 0
        }
        result.facesPending = faceBacklog.count
        let current = settings.snapshot().similarGroups
        result.stale = lastBuiltSettings.map { $0 != current } ?? false
        return result
    }

    /// Whether this identifier is still waiting for face capture quality.
    ///
    /// Populated when a pass finishes. A membership row whose asset has since been
    /// deleted keeps its entry in the cache's `group_members` only until the next
    /// pass, so a `false` here means "analysed or unknown", never "analysed and
    /// had no faces" — the distinction the caller needs is between *not yet
    /// analysed* and *analysed*, and this reports the former.
    func isAwaitingFaceAnalysis(_ identifier: String) -> Bool {
        faceBacklog.contains(identifier)
    }

    /// Refreshes the backlog, so `status()` reports real progress during a pass.
    private func refreshFaceBacklog() async {
        let pending = (try? await cache.groupMembersNeedingFaces(limit: 50_000)) ?? []
        faceBacklog = Set(pending)
    }

    /// Rebuilds the groups, then tops up face capture quality for their members.
    ///
    /// Returns immediately; the pass runs detached. `reason` is only for the log.
    /// Starts a pass if the stored groups are stale.
    ///
    /// Called from the group routes. Returns immediately — the pass is detached,
    /// and the request is answered from whatever the last completed pass stored —
    /// so a first visit to the group browser never blocks on a whole-library walk.
    func rebuildIfNeeded() async {
        guard await shouldRebuild() else { return }
        rebuild(reason: "stale")
    }

    /// Starts a pass now. No-op if one is already running.
    func rebuild(reason: String) {
        guard !running else { return }
        running = true
        lastError = nil
        // The cursor is per-pass: a cancelled pass that left it part-way through
        // would otherwise make the next pass start mid-queue and skip the photos
        // before that point.
        faceCursor = 0
        Log.info("similar group rebuild started (\(reason))")
        Task { [weak self] in
            await self?.run()
        }
    }

    /// Whether a rebuild is worth starting on its own.
    ///
    /// Conservative in the same way `AlbumIndexer.shouldRefresh` is: a fresh,
    /// current index is left alone, and a pass cannot be started twice.
    ///
    /// The one case that returns false outright is having no FeaturePrints at all.
    /// A pass over an empty candidate list can only produce zero groups, so running
    /// it would be pure cost — and worse than cost: `replaceGroups` replaces
    /// wholesale, so an empty pass *erases* whatever groups were stored. That makes
    /// "nothing to group yet" and "these groups are wrong" the same action, which is
    /// exactly the confusion to avoid. Once analysis has stored its first
    /// FeaturePrint this check starts returning true again, which is when a rebuild
    /// first has something to do.
    func shouldRebuild() async -> Bool {
        if running { return false }
        let counts = try? await cache.signalCounts()
        guard (counts?.featurePrints ?? 0) > 0 else { return false }
        let current = settings.snapshot().similarGroups
        if let built = lastBuiltSettings, built != current { return true }
        guard let lastBuiltAt else { return true }
        return Date().timeIntervalSince(lastBuiltAt) > Self.maxAge
    }

    static let maxAge: TimeInterval = 6 * 60 * 60

    private func run() async {
        let config = settings.snapshot().similarGroups
        do {
            let candidates = try await cache.featurePrints()
            Log.info("grouping \(candidates.count) cached FeaturePrints "
                     + "(window \(Int(config.windowSeconds))s, distance ≤ \(config.maxDistance))")

            var built = SimilarGroupBuilder.build(candidates: candidates, settings: config)

            // Split any component past the size bound, in chronological chunks.
            // The alternative — silently serving one 1,499-member "group" for a
            // whole event — is the failure this exists to prevent.
            var dates: [String: Double] = [:]
            for candidate in candidates {
                if let date = candidate.date { dates[candidate.identifier] = date }
            }
            let before = built.reduce(0) { $0 + $1.members.count }
            built = built.flatMap {
                SimilarGroupBuilder.split($0, maximumSize: config.maximumGroupSize, dates: dates)
            }
            let after = built.reduce(0) { $0 + $1.members.count }
            if after != before {
                Log.info("split \(before) grouped photos across \(built.count) groups "
                         + "to respect the size bound of \(config.maximumGroupSize)")
            }

            // Face capture quality for the members, so the stored face counts and
            // the Best Shot ranking are real rather than "not analysed yet".
            let members = built.flatMap { $0.members }
            let faces = try await analyzeFaces(for: members, config: config)

            var faceCounts: [String: Int] = [:]
            for group in built {
                var count = 0
                for member in group.members where !(faces[member] ?? []).isEmpty { count += 1 }
                faceCounts[group.id] = count
            }
            var earliest: [String: Double?] = [:]
            for group in built {
                earliest[group.id] = group.members.compactMap { dates[$0] }.min()
            }
            try await cache.replaceGroups(built, settings: config,
                                          faceMemberCounts: faceCounts, earliestDates: earliest)
            for group in built where (faceCounts[group.id] ?? 0) > 0 {
                try? await cache.markGroupRanked(id: group.id)
            }

            lastBuiltAt = Date()
            lastBuiltSettings = config
            let groupedPhotos = after
            Log.info("similar group rebuild finished: \(built.count) groups covering "
                     + "\(groupedPhotos) photos, \(faces.values.filter { !$0.isEmpty }.count) with faces")
        } catch is CancellationError {
            Log.info("similar group rebuild cancelled")
        } catch {
            lastError = "\(error)"
            Log.error("similar group rebuild failed: \(error)")
        }
        running = false
        // Read the backlog *after* the pass wrote its results, so what is left is
        // genuinely outstanding rather than what was outstanding when it began.
        await refreshFaceBacklog()
        publishStatus()
    }

    /// Runs Tier 3 over the members of the groups just built.
    ///
    /// Bounded concurrency, and every failure is local: one undecodable photo must
    /// not abandon the ranking of the other 40 in its group. A photo whose pixels
    /// are not on this Mac is recorded as having no faces *for this run's purposes*
    /// by simply not being written, so it is retried on the next rebuild rather
    /// than being recorded as a face-free result it might not be.
    private func analyzeFaces(for identifiers: [String],
                              config: SimilarGroupSettings) async throws -> [String: [FaceCapture]] {
        var unique: [String] = []
        var seen = Set<String>()
        for identifier in identifiers where seen.insert(identifier).inserted { unique.append(identifier) }
        guard !unique.isEmpty else { return [:] }

        let existing = try await cache.faceCaptureQualities(for: unique)
        let outstanding = unique.filter { existing[$0] == nil }
        guard !outstanding.isEmpty else { return existing }

        let snapshot = settings.snapshot()
        let concurrency = max(1, min(snapshot.analysisConcurrency, 8))
        let count = outstanding.count
        var results = existing

        // Results are collected by the group, not written through `inout` from
        // several tasks: an `inout` capture across a task group is exclusive, so
        // workers would have to be serialised and the whole pass would run at
        // concurrency 1. Each worker returns what it analysed and the merge below
        // is the only mutation.
        // Each worker drains the queue until `nextFaceIndex` reports it exhausted,
        // collecting what it analysed and returning it once. An earlier version
        // `return`ed inside the loop, so a worker stopped after a single photo while
        // the queue still had entries: five members with four workers analysed four
        // and silently left the fifth unanalysed. The exhaustion check is the only
        // exit — there is no per-item return to get wrong.
        await withTaskGroup(of: [(String, [FaceCapture])].self) { group in
            for _ in 0..<concurrency {
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    var collected: [(String, [FaceCapture])] = []
                    while !Task.isCancelled {
                        let position = await self.nextFaceIndex(upTo: count)
                        guard position >= 0 else { break }
                        if let analysed = await self.analyzeOneFace(
                            identifier: outstanding[position],
                            pixelSize: snapshot.analysisPixelSize,
                            allowNetwork: snapshot.downloadFromICloud) {
                            collected.append(analysed)
                        }
                    }
                    return collected
                }
            }
            for await batch in group {
                for entry in batch { results[entry.0] = entry.1 }
            }
        }
        return results
    }

    /// Hands out one index at a time, so the workers split the queue between them.
    ///
    /// Actor state for the same reason `AnalysisEngine.worker` owns its own batch:
    /// several tasks pulling from a shared cursor must not race and hand the same
    /// index to two of them. Returns -1 once the queue is exhausted, which is the
    /// only way a worker learns to stop.
    private func nextFaceIndex(upTo count: Int) -> Int {
        guard faceCursor < count else { return -1 }
        defer { faceCursor += 1 }
        return faceCursor
    }

    private func analyzeOneFace(identifier: String, pixelSize: Int,
                                allowNetwork: Bool) async -> (String, [FaceCapture])? {
        do {
            let image = try await library.image(identifier: identifier, maxPixelSize: pixelSize,
                                                allowNetwork: allowNetwork)
            let result = try await analyzer.faceCaptureQuality(image)
            guard let payload = SignalCompression.faceCaptureResultData(result) else { return nil }
            try await cache.recordFaceCaptureQuality(payload, for: identifier)
            return (identifier, result.faces)
        } catch {
            // Not written, so the next rebuild retries it. An iCloud-only photo with
            // downloads off is the expected case and is not worth a warning.
            if let libraryError = error as? PhotoLibraryError {
                switch libraryError {
                case .imageNotLocal, .imageUnavailable: return nil
                default: Log.warn("face analysis failed for \(identifier): \(libraryError)")
                }
            } else {
                Log.warn("face analysis failed for \(identifier): \(error)")
            }
            return nil
        }
    }

    // MARK: - Status publishing

    private func publishStatus() {
        let bus = self.bus
        Task { [weak self] in
            guard let self else { return }
            let status = await self.status()
            guard let data = try? JSONEncoder().encode(status) else { return }
            bus.publish(SSE.frame(event: "groups", json: data))
        }
    }
}
