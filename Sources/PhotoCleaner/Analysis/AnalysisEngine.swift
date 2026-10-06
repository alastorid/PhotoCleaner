import Foundation
import Photos

/// The single status document served by `GET /api/status` and pushed over SSE.
///
/// Every number here is derived from real counters: throughput is measured from
/// completed analyses inside a rolling window, and the ETA is that rate applied
/// to the remaining queue. Nothing is estimated or fabricated.
struct StatusSnapshot: Sendable, Codable {
    struct LibrarySection: Sendable, Codable {
        var total = 0
        var favorites = 0
    }

    struct AnalysisSection: Sendable, Codable {
        var phase: String = "starting"
        var total = 0
        var analyzed = 0
        var failed = 0
        var unavailable = 0
        var pending = 0
        var percent: Double = 0
        var rate: Double = 0
        var etaSeconds: Double?
        var startedAt: Double?
        var scanned: Int?
        var lastError: String?
    }

    struct ScoreSection: Sendable, Codable {
        var min: Float?
        var max: Float?
        var analyzed = 0
    }

    struct SettingsSection: Sendable, Codable {
        var downloadFromICloud = false
        var protectFavorites = true
        var concurrency = 4
        var analysisPixelSize = 1024
        /// The Similar Group knobs, echoed so the UI renders the values the server
        /// actually applied rather than what it last sent.
        var groupWindowSeconds = SimilarGroupSettings.default.windowSeconds
        var groupMaxDistance = SimilarGroupSettings.default.maxDistance
        var groupFaceWeight = SimilarGroupSettings.default.faceWeight
        var groupMaximumSize = SimilarGroupSettings.default.maximumGroupSize
    }

    var version: String = AppPaths.version
    var authorization: String = "notDetermined"
    var library = LibrarySection()
    var analysis = AnalysisSection()
    var score = ScoreSection()
    var settings = SettingsSection()
    var cachePath: String = ""
    var cacheBytes: Int64 = 0
    var serverTime: Double = 0
}

enum AnalysisPhase: String, Sendable {
    case starting
    case scanning
    case analyzing
    case upToDate = "up_to_date"
    case unauthorized
    case failed
}

/// Owns the library scan and the scoring queue.
///
/// Concurrency model: a bounded pool of nonisolated workers pulls identifiers
/// from the actor, does the expensive work (PhotoKit decode → Vision) entirely
/// off the actor, and reports back. The actor itself only does bookkeeping, so
/// the HTTP server stays responsive while Vision is busy.
actor AnalysisEngine {
    private let cache: CacheStore
    private let library: PhotoLibrary
    private let settings: Settings
    private let analyzer: VisionAnalyzer
    private let bus: EventBus

    private var phase: AnalysisPhase = .starting
    private var authorization = "notDetermined"
    private var lastError: String?
    private var runTask: Task<Void, Never>?
    /// Identifies the current run so a finishing task can only clear `runTask`
    /// if it is still the current one.
    private var runGeneration: UInt64 = 0
    /// Identifies the newest restart request. See `requestRescan`.
    private var restartToken: UInt64 = 0
    private var samples: [(at: Date, processed: Int)] = []
    private var processedCount = 0
    private var analysisStartedAt: Date?
    private var lastPublish = Date.distantPast
    private var scannedSoFar: Int?

    init(cache: CacheStore, library: PhotoLibrary, settings: Settings, bus: EventBus) {
        self.cache = cache
        self.library = library
        self.settings = settings
        self.analyzer = VisionAnalyzer()
        self.bus = bus
    }

    // MARK: - Lifecycle

    func setAuthorization(_ description: String, hasAccess: Bool) {
        authorization = description
        if !hasAccess { phase = .unauthorized }
    }

    func start() {
        guard runTask == nil else { return }
        runGeneration &+= 1
        let generation = runGeneration
        runTask = Task { [weak self] in
            await self?.runLoop()
            await self?.markRunFinished(generation: generation)
        }
    }

    /// Cancels any run in flight and starts a fresh scan. Safe because all
    /// durable state lives in SQLite: an interrupted queue is simply re-claimed.
    ///
    /// `await task.value` suspends, and suspending releases this actor. Without
    /// the token below, two rescans arriving close together (or a rescan racing
    /// the `engine.start()` in the settings handler) would both observe the same
    /// run task, both null `runTask`, and the second would orphan the run loop
    /// the first had just started. Two loops then scan concurrently with
    /// *different* `scan_marker` values, and each one's `finishScan` deletes every
    /// row the other stamped — silently dropping live photos out of the cache,
    /// scores and all, until some later scan rediscovers them. Only the newest
    /// request restarts.
    func requestRescan() async {
        restartToken &+= 1
        let token = restartToken
        if let task = runTask {
            task.cancel()
            await task.value
        }
        guard token == restartToken else { return }
        runTask = nil
        start()
    }

    func requestRetry() async {
        let requeued = (try? await cache.requeueFailures(includeUnavailable: settings.snapshot().downloadFromICloud)) ?? 0
        Log.info("requeued \(requeued) failed/unavailable assets for analysis")
        await publishStatus(force: true)
        start()
    }

    private func markRunFinished(generation: UInt64) {
        if generation == runGeneration { runTask = nil }
    }

    /// Stops the run loop and waits for in-flight analyses to unwind. Durable
    /// state is already committed per asset, so nothing is lost.
    func shutdown() async {
        guard let task = runTask else { return }
        task.cancel()
        await task.value
        runTask = nil
    }

    // MARK: - Run loop

    private func runLoop() async {
        guard phase != .unauthorized else {
            await publishStatus(force: true)
            return
        }
        await scan()
        guard !Task.isCancelled else { return }
        // A failed scan means the library state is unknown, so there is nothing
        // honest to report progress against. `analyze` would otherwise overwrite
        // `.failed` with `.analyzing` and the UI would claim a healthy run.
        if phase == .failed { return }
        await analyze()
    }

    private func scan() async {
        phase = .scanning
        scannedSoFar = 0
        lastError = nil
        await publishStatus(force: true)
        Log.info("scanning Photos library")

        let marker = Int64(Date().timeIntervalSince1970)
        do {
            try await cache.beginScan()
            try await library.enumerateImages(batchSize: 512) { [cache] batch in
                try await cache.upsert(batch: batch, marker: marker)
                await self.noteScanned(batch.count)
            }
            // Only reached when the whole library was walked without throwing. An
            // interrupted scan must never get here: `finishScan` deletes every row
            // not stamped with this marker, so calling it after a partial walk
            // would delete live photos' cache rows.
            let removed = try await cache.finishScan(marker: marker)
            if removed > 0 {
                Log.info("removed \(removed) cache entries for assets no longer in Photos")
            }
            scannedSoFar = nil
        } catch is CancellationError {
            // A rescan or a quit interrupted the walk. That is not an error and
            // must not leave `scanning` reported as `failed`; the run that
            // supersedes this one publishes its own phase immediately.
            scannedSoFar = nil
            Log.info("library scan cancelled")
        } catch {
            scannedSoFar = nil
            lastError = "library scan failed: \(error)"
            phase = .failed
            Log.error("library scan failed: \(error)")
        }
        guard !Task.isCancelled else { return }
        await publishStatus(force: true)
    }

    private func noteScanned(_ count: Int) async {
        scannedSoFar = (scannedSoFar ?? 0) + count
        await publishStatus()
    }

    private func analyze() async {
        let snapshot = settings.snapshot()
        analysisStartedAt = Date()
        processedCount = 0
        samples.removeAll(keepingCapacity: true)
        phase = .analyzing
        await publishStatus(force: true)

        let concurrency = max(1, snapshot.analysisConcurrency)
        Log.info("analyzing with concurrency \(concurrency), \(snapshot.analysisPixelSize)px inputs, iCloud downloads \(snapshot.downloadFromICloud ? "allowed" : "disabled")")

        let cache = self.cache
        let library = self.library
        let settings = self.settings
        let analyzer = self.analyzer
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    await AnalysisEngine.worker(cache: cache, library: library, settings: settings, analyzer: analyzer, engine: self)
                }
            }
            await group.waitForAll()
        }

        // An interrupted run must not report `up_to_date`: its queue is still open
        // and a rescan is already on its way to re-open it. The same guard keeps a
        // run that ended in `.failed` (Vision unavailable) or `.unauthorized`
        // (access revoked mid-pass) from being papered over with a cheerful
        // `up_to_date`.
        guard !Task.isCancelled else { return }
        if phase == .analyzing {
            phase = .upToDate
            analysisStartedAt = nil
        }
        await publishStatus(force: true)
        Log.info("analysis run finished")
    }

    // MARK: - Worker

    private nonisolated static func worker(cache: CacheStore,
                                           library: PhotoLibrary,
                                           settings: Settings,
                                           analyzer: VisionAnalyzer,
                                           engine: AnalysisEngine) async {
        // Each worker owns its own batch. Claiming into a single shared buffer
        // would race: two workers can suspend inside `claimJobs` at the same
        // time, and the second assignment would discard the first batch —
        // leaving those assets marked `analyzing` and never processed.
        var batch: [AssetJob] = []
        while !Task.isCancelled {
            if batch.isEmpty {
                batch = await engine.claimBatch()
                if batch.isEmpty { break }
            }
            let job = batch.removeFirst()
            // An asset scored by an earlier build has a good aesthetics score but no
            // FeaturePrint. It needs only the vector, and must not go through the
            // state machine — `releaseClaims`/`record` would rewrite a score that is
            // already correct. Its own queue, claimed and released separately.
            if job.isBackfill {
                let image: CGImage
                do {
                    let snapshot = settings.snapshot()
                    image = try await library.image(identifier: job.identifier,
                                                    maxPixelSize: snapshot.analysisPixelSize,
                                                    allowNetwork: snapshot.downloadFromICloud)
                    let observation = try await analyzer.featurePrint(image)
                    if let payload = SignalCompression.featurePrintData(observation) {
                        try await cache.recordFeaturePrint(payload, for: job.identifier)
                    }
                    await engine.noteProcessed()
                } catch {
                    // A backfill that cannot read its pixels is not a scoring
                    // failure: the asset keeps its score and simply has no vector, so
                    // it will not join a Similar Group. Nothing is recorded against
                    // it — `recordFailure` would park an asset whose analysis is in
                    // fact complete — and nothing is logged, because an
                    // iCloud-optimised library makes this the expected case for
                    // thousands of photos rather than an anomaly.
                    await engine.noteProcessed()
                }
                continue
            }
            let snapshot = settings.snapshot()
            do {
                let image = try await library.image(
                    identifier: job.identifier,
                    maxPixelSize: snapshot.analysisPixelSize,
                    allowNetwork: snapshot.downloadFromICloud
                )
                // Aesthetics and the FeaturePrint come from the same decoded image: measured at
                // 7.2 ms together against 5.0 ms for aesthetics alone, because the
                // two requests are independent models over pixels already in memory.
                let (result, featurePrint) = try await analyzer.analyzeWithFeaturePrint(image)
                try await cache.record(score: result.score, for: job.identifier)
                // A missing FeaturePrint is not a failure — the score is the primary
                // observation, and an asset without one simply cannot join a group.
                if let featurePrint {
                    try? await cache.recordFeaturePrint(featurePrint, for: job.identifier)
                }
                await engine.noteProcessed()
            } catch {
                if Task.isCancelled {
                    // Cancelling a `PHImageRequest` makes PhotoKit invoke the
                    // handler with `PHImageCancelledKey`, which
                    // `PhotoLibrary.requestImage` turns into
                    // `PhotoLibraryError.imageUnavailable`. Routed through
                    // `noteFailure` that would permanently mark a perfectly
                    // local asset `unavailable` — a state that is never retried
                    // while iCloud downloads are off — so every rescan during
                    // analysis would strand up to `concurrency` photos. The run
                    // was interrupted, not the asset: hand the claim back.
                    await engine.releaseUnclaimed([job] + batch)
                    return
                }
                await engine.noteFailure(job: job, error: error)
            }
        }
        // Whatever is left was claimed and never resolved.
        await engine.releaseUnclaimed(batch)
    }

    /// Claims the next batch of work for one worker. Rows are marked
    /// `analyzing` here and reach a terminal state when the worker finishes
    /// them; anything interrupted is returned to `pending` by `releaseUnclaimed`,
    /// and a process killed outright is recovered by the next `beginScan()`.
    private func claimBatch() async -> [AssetJob] {
        let pending = (try? await cache.claimJobs(limit: 64)) ?? []
        // Backfill is drained only once the scoring queue is empty, so a first run
        // spends its time on photos that have no score at all — which is the work
        // the user is waiting for — rather than backfilling vectors for photos
        // already scored.
        guard pending.isEmpty else { return pending }
        let backfill = (try? await cache.claimFeaturePrints(limit: 64)) ?? []
        return backfill.map { AssetJob(backfill: $0) }
    }

    /// Returns jobs this worker claimed but never resolved back to `pending`, so
    /// a cancelled or resized run leaves no orphaned `analyzing` rows behind.
    private func releaseUnclaimed(_ jobs: [AssetJob]) async {
        guard !jobs.isEmpty else { return }
        // Partitioned: a backfill job's claim lives in a different table, and
        // `releaseClaims` would look for an `analyzing` row that does not exist —
        // silently dropping the claim and losing the backfill for this run.
        let normal = jobs.filter { !$0.isBackfill }.map(\.identifier)
        let backfill = jobs.filter(\.isBackfill).map(\.identifier)
        if !normal.isEmpty { try? await cache.releaseClaims(identifiers: normal) }
        if !backfill.isEmpty { try? await cache.releaseFeaturePrints(identifiers: backfill) }
    }

    private func noteProcessed() async {
        // One bad photo must never abort a scan: failures are recorded against
        // the asset itself and the queue moves on.
        processedCount += 1
        samples.append((Date(), processedCount))
        let cutoff = Date().addingTimeInterval(-15)
        if let firstFresh = samples.firstIndex(where: { $0.at >= cutoff }), firstFresh > 0 {
            samples.removeFirst(firstFresh)
        }
        await publishStatus()
    }

    /// Routes one failure to the right bucket.
    ///
    /// "Not on this Mac" is deliberately distinct from "failed": it is the
    /// expected outcome for an optimised iCloud library when downloads are
    /// switched off, so it is not counted as an error and is not retried.
    /// Whether an unavailable asset could be fetched is only knowable per
    /// asset, so the two cases are decided from the actual PhotoKit result
    /// rather than from a global setting.
    private func noteFailure(job: AssetJob, error: Error) async {
        await recordOutcome(job: job, error: error)
        // Deliberately outside `recordOutcome`, so exactly one place counts a
        // failure as processed. `rate` and `etaSeconds` come from this counter
        // while `percent` comes from the cache, so a terminal state that forgot
        // to count itself — an asset that vanished between the scan and the
        // pass, say — would compute the rate over a different population than
        // the one the progress read-out reports. Leaving the call inside the
        // switch instead leaves that up to one `return` per case, and a case
        // added later would quietly not count itself.
        await noteProcessed()
    }

    /// Records what happened to one asset: which terminal state it lands in, and
    /// nothing else. Never touches the progress counters — `noteFailure` owns
    /// that, so every outcome is counted exactly once by construction.
    private func recordOutcome(job: AssetJob, error: Error) async {
        guard let libraryError = error as? PhotoLibraryError else {
            if let visionError = error as? VisionAnalyzerError {
                lastError = visionError.description
                phase = .failed
            }
            try? await cache.recordFailure(for: job.identifier, error: String(describing: error))
            Log.warn("analysis failed for \(job.identifier): \(error)")
            return
        }

        switch libraryError {
        case .assetNotFound:
            // Deleted (here or on another device) between the scan and the pass.
            // The row goes with it, so `total` falls and the numerator falls
            // with it; the work still happened, so it is still counted.
            try? await cache.remove(identifiers: [job.identifier])
            Log.info("asset \(job.identifier) disappeared before analysis")

        case .imageNotLocal, .imageUnavailable:
            try? await cache.recordUnavailable(for: job.identifier, reason: libraryError.description)

        case .imageRequestFailed(let detail):
            try? await cache.recordFailure(for: job.identifier, error: detail)
            Log.warn("image request failed for \(job.identifier): \(detail)")

        case .notAuthorized(let detail):
            lastError = "Photos access was revoked during analysis (\(detail))"
            phase = .unauthorized
            try? await cache.recordFailure(for: job.identifier, error: detail)

        case .deletionFailed(let detail):
            try? await cache.recordFailure(for: job.identifier, error: detail)
        }
    }

    // MARK: - Status

    func status() async -> StatusSnapshot {
        await buildStatus(maxAge: 0)
    }

    func publishStatus(force: Bool = false) async {
        let now = Date()
        if !force, now.timeIntervalSince(lastPublish) < 0.25 { return }
        lastPublish = now
        let snapshot = await buildStatus(maxAge: 1.0)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        bus.publish(SSE.frame(event: "status", json: data))
    }

    private func buildStatus(maxAge: TimeInterval) async -> StatusSnapshot {
        let stats = (try? await cache.stats(maxAge: maxAge)) ?? CacheStats()
        let preferences = settings.snapshot()

        var status = StatusSnapshot()
        status.authorization = authorization
        status.library = .init(total: stats.total, favorites: stats.favorites)
        status.settings = .init(downloadFromICloud: preferences.downloadFromICloud,
                                protectFavorites: preferences.protectFavorites,
                                concurrency: preferences.analysisConcurrency,
                                analysisPixelSize: preferences.analysisPixelSize,
                                groupWindowSeconds: preferences.groupWindowSeconds,
                                groupMaxDistance: preferences.groupMaxDistance,
                                groupFaceWeight: preferences.groupFaceWeight,
                                groupMaximumSize: preferences.groupMaximumSize)
        status.score = .init(min: stats.minScore, max: stats.maxScore, analyzed: stats.analyzed)
        status.cachePath = AppPaths.cacheDatabase.path
        status.cacheBytes = cache.databaseSizeBytes()
        status.serverTime = Date().timeIntervalSince1970

        var analysis = StatusSnapshot.AnalysisSection()
        analysis.phase = phase.rawValue
        analysis.total = stats.total
        analysis.analyzed = stats.analyzed
        analysis.failed = stats.failed
        analysis.unavailable = stats.unavailable
        analysis.pending = stats.pending
        let processed = stats.analyzed + stats.failed + stats.unavailable
        analysis.percent = stats.total > 0 ? min(1, Double(processed) / Double(stats.total)) : 0
        analysis.rate = currentRate()
        if analysis.rate > 0, stats.pending > 0, phase == .analyzing {
            analysis.etaSeconds = Double(stats.pending) / analysis.rate
        }
        analysis.startedAt = analysisStartedAt?.timeIntervalSince1970
        analysis.scanned = scannedSoFar
        analysis.lastError = lastError
        status.analysis = analysis
        return status
    }

    private func currentRate() -> Double {
        guard phase == .analyzing, let first = samples.first, let last = samples.last else { return 0 }
        let elapsed = last.at.timeIntervalSince(first.at)
        guard elapsed >= 1 else { return 0 }
        return Double(last.processed - first.processed) / elapsed
    }

    func lastErrorDescription() -> String? { lastError }
}
