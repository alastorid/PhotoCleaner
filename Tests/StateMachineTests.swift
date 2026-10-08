import Foundation
import SQLite3

// The analysis state machine: `pending → analyzing → done | failed | unavailable`.
//
// The production state machine is split between two places: `CacheStore` owns the
// durable transitions and `AnalysisEngine.worker` owns the routing decision. Only
// the durable half is reachable from a test — the worker needs a real PhotoKit
// image request to fail — but the durable half is where the states live, and it is
// where every one of the recorded bugs showed up: claims orphaned in `analyzing`, a
// cancellation recorded as `unavailable` (a state that is never retried while iCloud
// downloads are off, so the photo is stranded for good), and a failure retried
// forever. `releaseClaims` and `requeueFailures` are asserted here to be incapable
// of producing any of those states.

func registerStateMachineTests() {
    let suite = "analysis state machine"

    Registry.shared.add(suite: suite, TestCase(name: "a scanned asset starts pending and claiming moves it to analyzing",
        knownBug: nil) {
        let fixture = try await Fixture.make("sm-claim")
        try await fixture.seed([.init(id: "a", score: nil, date: 1, state: .pending)])
        checkEqual(try await fixture.analysisState(of: "a"), .pending, "a fresh scan leaves the row pending")

        let jobs = try await fixture.cache.claimJobs(limit: 10)
        checkEqual(jobs.map(\.identifier), ["a"], "claimJobs returns the pending row")
        checkEqual(try await fixture.analysisState(of: "a"), .analyzing, "and marks it analyzing in the same transaction")
        checkEqual(try await fixture.cache.claimJobs(limit: 10).count, 0, "a claimed row is never handed out twice")
    })

    Registry.shared.add(suite: suite, TestCase(name: "concurrent claims never overlap and lose nothing",
        knownBug: nil) {
        // The orphaned-work bug: two workers shared one refill buffer and the second
        // overwrote the first's batch, stranding those assets in `analyzing` forever.
        let fixture = try await Fixture.make("sm-concurrent")
        let total = 40
        try await fixture.seed((0..<total).map {
            .init(id: "j-\(String(format: "%03d", $0))", score: nil, date: Double($0), state: .pending)
        })

        async let first = fixture.cache.claimJobs(limit: 9)
        async let second = fixture.cache.claimJobs(limit: 9)
        async let third = fixture.cache.claimJobs(limit: 9)
        async let fourth = fixture.cache.claimJobs(limit: 9)
        let batches = try await [first, second, third, fourth]

        let claimed = batches.flatMap { $0.map(\.identifier) }
        checkNoDuplicates(claimed, "concurrent claims must not hand the same asset to two workers")
        checkEqual(claimed.count, 36, "each claim gets exactly the batch it asked for")
        // The queue drains newest first (`claimJobs` orders by creation_date DESC), so
        // the four batches are the four newest groups of nine, and the four oldest
        // rows are the ones left waiting.
        checkSetEqual(claimed, Set((4..<40).map { "j-\(String(format: "%03d", $0))" }),
                      "the batches are the newest 36 rows")

        let states = try await fixture.stateCounts()
        checkEqual(states[.analyzing], 36, "every claimed row is analyzing")
        checkEqual(states[.pending], total - 36, "and the rest are still pending")
        checkEqual(states[.done] ?? 0, 0, "nothing is done yet")
    })

    Registry.shared.add(suite: suite, TestCase(name: "recording a score completes the asset and keeps it out of the queue",
        knownBug: nil) {
        let fixture = try await Fixture.make("sm-record")
        try await fixture.seed([.init(id: "a", score: nil, date: 1, state: .pending)])
        _ = try await fixture.cache.claimJobs(limit: 1)
        try await fixture.cache.record(score: -0.9959, for: "a")

        checkEqual(try await fixture.analysisState(of: "a"), .done, "state")
        let row = checkNotNil(try await fixture.cache.photo(identifier: "a"), "the completed row")
        checkEqual(row?.score, -0.9959, "the score is stored raw, outside 0…1")
        check((try await fixture.scoredAt(of: "a")) ?? 0 > 0, "scored_at is stamped")
        checkEqual(try await fixture.lastError(of: "a"), nil, "last_error is cleared on success")
        checkEqual(try await fixture.cache.claimJobs(limit: 10).count, 0, "a completed asset is never re-claimed")

        let stats = try await fixture.cache.stats(maxAge: 0)
        checkEqual(stats.analyzed, 1, "analyzed counts it")
        checkEqual(stats.minScore, -0.9959, "min")
        checkEqual(stats.maxScore, -0.9959, "max")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a failure gets exactly one retry, then stops", knownBug: nil) {
        let fixture = try await Fixture.make("sm-retry")
        try await fixture.seed([.init(id: "a", score: nil, date: 1, state: .pending)])
        _ = try await fixture.cache.claimJobs(limit: 1)

        try await fixture.cache.recordFailure(for: "a", error: "boom")
        checkEqual(try await fixture.analysisState(of: "a"), .pending, "the first failure returns the row to pending")
        checkEqual(try await fixture.attempts(of: "a"), 1, "one attempt is recorded")
        checkEqual(try await fixture.cache.claimJobs(limit: 10).map(\.identifier), ["a"],
                   "the single automatic retry is offered exactly once")

        try await fixture.cache.recordFailure(for: "a", error: "boom again")
        checkEqual(try await fixture.analysisState(of: "a"), .failed, "the second failure parks the row")
        checkEqual(try await fixture.attempts(of: "a"), 2, "two attempts")
        checkEqual(try await fixture.cache.claimJobs(limit: 10).count, 0,
                   "a failed row is never claimed again without an explicit retry")

        try await fixture.cache.recordFailure(for: "a", error: "boom a third time")
        checkEqual(try await fixture.analysisState(of: "a"), .failed, "and it stays failed")
        checkEqual(try await fixture.cache.claimJobs(limit: 10).count, 0, "still never claimed")
        check((try await fixture.lastError(of: "a"))?.contains("boom") == true, "the error is kept for diagnosis")
    })

    Registry.shared.add(suite: suite, TestCase(name: "an unanswered request is parked without a retry, and stays retryable",
        knownBug: nil) {
        // The retry exists so a transient failure does not park an asset forever.
        // It is what a *deadline* must not have: the retried row returns to
        // `pending` with its original `creation_date`, and `claimJobs` drains
        // `pending` newest-first, so the next worker to claim a batch finds it at
        // the front and waits out the whole deadline again. Measured on a real
        // library: eleven such assets held four workers for eighteen minutes and
        // moved the pass by two assets.
        let fixture = try await Fixture.make("sm-timeout")
        try await fixture.seed([.init(id: "stuck", score: nil, date: 1, state: .pending)])
        _ = try await fixture.cache.claimJobs(limit: 1)

        try await fixture.cache.recordFailure(for: "stuck", error: "no answer after 120 s", retry: false)
        checkEqual(try await fixture.analysisState(of: "stuck"), .failed,
                   "a timed-out request is terminal on its first record")
        checkEqual(try await fixture.attempts(of: "stuck"), 1, "the attempt is still counted")
        checkEqual(try await fixture.cache.claimJobs(limit: 10).count, 0,
                   "and it is never re-claimed, which is what keeps the queue moving")

        // Retry is the escape hatch, and it must reach these rows: `requeueFailures`
        // re-queues `failed` unconditionally, so a timeout is retryable whether or
        // not iCloud downloads are on — the difference from `unavailable`, which is
        // only re-queued when they are.
        let requeued = try await fixture.cache.requeueFailures(includeUnavailable: false)
        checkEqual(requeued, 1, "Retry re-queues a timed-out asset with downloads off")
        checkEqual(try await fixture.analysisState(of: "stuck"), .pending, "back in the queue")
        checkEqual(try await fixture.attempts(of: "stuck"), 0, "with its attempt counter reset")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a very long error message is truncated, not stored whole",
        knownBug: nil) {
        let fixture = try await Fixture.make("sm-longerror")
        try await fixture.seed([.init(id: "a", score: nil, date: 1, state: .pending)])
        try await fixture.cache.recordFailure(for: "a", error: String(repeating: "x", count: 5_000))
        let stored = checkNotNil(try await fixture.lastError(of: "a"), "last_error")
        checkEqual(stored?.count, 500, "last_error is capped at 500 characters")
        try await fixture.cache.recordUnavailable(for: "a", reason: String(repeating: "y", count: 5_000))
        checkEqual((try await fixture.lastError(of: "a"))?.count, 500, "and so is an unavailable reason")
    })

    Registry.shared.add(suite: suite, TestCase(name: "unavailable is terminal while iCloud downloads are off",
        knownBug: nil) {
        let fixture = try await Fixture.make("sm-unavailable")
        try await fixture.seed([
            .init(id: "cloud", score: nil, date: 1, state: .pending),
            .init(id: "failed", score: nil, date: 2, state: .failed),
            .init(id: "ok", score: 0.5, date: 3),
        ])
        try await fixture.cache.recordUnavailable(for: "cloud", reason: "stored in iCloud only")
        checkEqual(try await fixture.analysisState(of: "cloud"), .unavailable, "state")
        checkEqual(try await fixture.cache.claimJobs(limit: 100).count, 0,
                   "an unavailable asset is never claimed, so it can never be retried by accident")

        checkEqual(try await fixture.cache.requeueFailures(includeUnavailable: false), 1,
                   "the explicit retry requeues only the failure")
        checkEqual(try await fixture.analysisState(of: "cloud"), .unavailable,
                   "unavailable is untouched while iCloud downloads are off")
        checkEqual(try await fixture.analysisState(of: "failed"), .pending, "the failed row is queued again")
        checkEqual(try await fixture.attempts(of: "failed"), 0, "and its attempt counter is reset")

        // `failed` was requeued by the previous call and is now `pending`, so only the
        // iCloud-only row is left for this one to pick up.
        checkEqual(try await fixture.cache.requeueFailures(includeUnavailable: true), 1,
                   "with iCloud downloads on, the unavailable row is requeued too")
        checkEqual(try await fixture.analysisState(of: "cloud"), .pending, "so it becomes eligible again")

        // The setting-change path is separate, and just as one-directional.
        try await fixture.cache.recordUnavailable(for: "cloud", reason: "cloud again")
        checkEqual(try await fixture.cache.requeueUnavailable(), 1, "requeueUnavailable picks up the newly-skipped row")
        checkEqual(try await fixture.analysisState(of: "cloud"), .pending, "which is pending again")
        checkEqual(try await fixture.cache.requeueUnavailable(), 0, "and idempotent")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a cancellation returns the claim to pending and never to unavailable",
        knownBug: nil) {
        // `AnalysisEngine.worker` checks `Task.isCancelled` *before* routing a
        // failure, and hands the claim back with `releaseClaims`; PhotoKit answers a
        // cancelled `PHImageRequest` with `imageUnavailable`, which is the one error
        // that would otherwise be recorded as `unavailable` — permanently stranding a
        // local photo. The durable half of that contract is assertable here: what
        // `releaseClaims` is capable of writing.
        let fixture = try await Fixture.make("sm-release")
        try await fixture.seed([
            .init(id: "in-flight", score: nil, date: 1, state: .pending),
            .init(id: "done", score: 0.4, date: 2),
            .init(id: "failed", score: nil, date: 3, state: .failed),
            .init(id: "cloud", score: nil, date: 4, state: .unavailable),
        ])
        _ = try await fixture.cache.claimJobs(limit: 1)
        checkEqual(try await fixture.analysisState(of: "in-flight"), .analyzing, "claimed")

        // A cancelling worker hands back everything it was holding, including rows
        // that already reached a terminal state.
        try await fixture.cache.releaseClaims(identifiers: ["in-flight", "done", "failed", "cloud", "never-seen"])

        checkEqual(try await fixture.analysisState(of: "in-flight"), .pending,
                   "the claim goes back to pending so the next run picks it up")
        checkEqual(try await fixture.lastError(of: "in-flight"), nil,
                   "and no error is recorded: a cancellation is not an asset failure")
        let counts = try await fixture.stateCounts()
        checkEqual(counts[.unavailable] ?? 0, 1, "releaseClaims cannot create an unavailable row")
        checkEqual(counts[.pending] ?? 0, 1, "exactly the cancelled claim is pending")
        checkEqual(try await fixture.analysisState(of: "done"), .done, "a completed row is not resurrected")
        checkEqual(try await fixture.analysisState(of: "failed"), .failed, "a failed row is not resurrected")
        checkEqual(try await fixture.analysisState(of: "cloud"), .unavailable, "an unavailable row is not resurrected")

        let jobs = try await fixture.cache.claimJobs(limit: 10)
        checkEqual(jobs.map(\.identifier), ["in-flight"], "and the released row is claimable again")
        try await fixture.cache.releaseClaims(identifiers: [])
        checkEqual(try await fixture.analysisState(of: "in-flight"), .analyzing,
                   "releasing nothing is a no-op, not a reset")
    })

    Registry.shared.add(suite: suite, TestCase(name: "beginScan recovers interrupted work and preserves terminal states",
        knownBug: nil) {
        let fixture = try await Fixture.make("sm-beginscan")
        try await fixture.seed([
            .init(id: "orphan", score: nil, date: 1, state: .pending),
            .init(id: "done", score: 0.4, date: 2),
            .init(id: "failed", score: nil, date: 3, state: .failed),
            .init(id: "cloud", score: nil, date: 4, state: .unavailable),
        ])
        _ = try await fixture.cache.claimJobs(limit: 1)
        checkEqual(try await fixture.analysisState(of: "orphan"), .analyzing, "a claim is in flight")

        try await fixture.cache.beginScan()
        checkEqual(try await fixture.analysisState(of: "orphan"), .pending,
                   "a process killed mid-analysis leaves analyzing rows, and the next launch recovers them")
        checkEqual(try await fixture.analysisState(of: "done"), .done, "done is preserved")
        checkEqual(try await fixture.analysisState(of: "failed"), .failed, "failed is preserved")
        checkEqual(try await fixture.analysisState(of: "cloud"), .unavailable, "unavailable is preserved")
        checkEqual((try await fixture.cache.stats(maxAge: 0)).pending, 1, "the recovered orphan is the only pending row")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a rescan never re-queues an unchanged, already-scored asset",
        knownBug: nil) {
        let fixture = try await Fixture.make("sm-rescan")
        let record = ScanRecord(identifier: "a", mediaType: 1, creationDate: 100, modificationDate: 500,
                                width: 10, height: 10, favorite: false, mediaSubtype: 0, isScreenshot: false)
        try await fixture.cache.upsert(batch: [record], marker: 1)
        try await fixture.cache.record(score: 0.25, for: "a")
        let scoredAt = checkNotNil(try await fixture.scoredAt(of: "a"), "scored_at before")

        try await fixture.cache.beginScan()
        try await fixture.cache.upsert(batch: [record], marker: 2)
        checkEqual(try await fixture.analysisState(of: "a"), .done, "an unchanged asset is not re-queued")
        checkEqual(try await fixture.scoredAt(of: "a"), scoredAt, "scored_at is byte-identical, so no re-scoring")
        checkEqual(checkNotNil(try await fixture.cache.photo(identifier: "a"), "row")?.score, 0.25, "the score survives")
        checkEqual(try await fixture.cache.claimJobs(limit: 10).count, 0, "and the queue stays empty")
    })

    Registry.shared.add(suite: suite, TestCase(name: "an edited asset is re-queued and its score cleared", knownBug: nil) {
        let fixture = try await Fixture.make("sm-edited")
        try await fixture.cache.upsert(batch: [ScanRecord(identifier: "a", mediaType: 1, creationDate: 100,
                                                          modificationDate: 500, width: 10, height: 10,
                                                          favorite: false, mediaSubtype: 0, isScreenshot: false)],
                                       marker: 1)
        try await fixture.cache.record(score: 0.25, for: "a")

        try await fixture.cache.upsert(batch: [ScanRecord(identifier: "a", mediaType: 1, creationDate: 100,
                                                          modificationDate: 900, width: 12, height: 12,
                                                          favorite: false, mediaSubtype: 0, isScreenshot: false)],
                                       marker: 2)
        checkEqual(try await fixture.analysisState(of: "a"), .pending, "an edited asset goes back in the queue")
        checkEqual(try await fixture.scoredAt(of: "a"), nil, "its stale score timestamp is cleared")
        // The score column is cleared to NULL. `PhotoRow.score` is non-optional, so a
        // row awaiting re-analysis reads back as `score: 0` — indistinguishable from a
        // genuine 0.0. It leaves the score-bounded grid either way, because the filter
        // is `aesthetics_score >= ?1` and NULL fails it.
        let row = try await fixture.cache.photo(identifier: "a")
        checkEqual(row?.score, 0, "the stale score is gone, and reads as 0 rather than absent")
        checkEqual(try await fixture.cache.claimJobs(limit: 10).map(\.identifier), ["a"], "so it is re-scanned")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a rescan preserves in-flight and iCloud-only states", knownBug: nil) {
        let fixture = try await Fixture.make("sm-rescan-states")
        try await fixture.seed([
            .init(id: "in-flight", score: nil, date: 1, state: .pending),
            .init(id: "cloud", score: nil, date: 2, state: .unavailable),
        ])
        _ = try await fixture.cache.claimJobs(limit: 1)

        try await fixture.cache.beginScan()
        try await fixture.cache.upsert(batch: [
            ScanRecord(identifier: "in-flight", mediaType: 1, creationDate: 1, modificationDate: 1, width: 1,
                       height: 1, favorite: false, mediaSubtype: 0, isScreenshot: false),
            ScanRecord(identifier: "cloud", mediaType: 1, creationDate: 2, modificationDate: 2, width: 1,
                       height: 1, favorite: false, mediaSubtype: 0, isScreenshot: false),
        ], marker: 2)

        checkEqual(try await fixture.analysisState(of: "in-flight"), .pending, "upsert leaves a released claim alone")
        checkEqual(try await fixture.analysisState(of: "cloud"), .unavailable,
                   "a rescan must not re-queue an iCloud-only asset; only the explicit setting change does that")
    })

    Registry.shared.add(suite: suite, TestCase(name: "finishScan deletes only rows another scan stamped", knownBug: nil) {
        // Two rescans that overlap each other's `finishScan` is how photos silently
        // disappear from the cache with their scores intact. The marker is what makes
        // that impossible.
        let fixture = try await Fixture.make("sm-finishscan")
        func scan(_ marker: Int64, _ ids: [String]) async throws {
            try await fixture.cache.upsert(batch: ids.map {
                ScanRecord(identifier: $0, mediaType: 1, creationDate: 1, modificationDate: 1, width: 1,
                           height: 1, favorite: false, mediaSubtype: 0, isScreenshot: false)
            }, marker: marker)
        }
        // Two overlapping rescans. The second reached everything the first did plus one
        // more, so finishing it removes exactly the row it never saw.
        try await scan(100, ["shared-1", "shared-2", "only-in-100"])
        try await scan(200, ["shared-1", "shared-2", "only-in-200"])
        checkEqual(try await fixture.cache.finishScan(marker: 200), 1,
                   "the row this scan never reached is the only one removed")
        checkNil(try await fixture.cache.photo(identifier: "only-in-100"), "and it is gone")
        checkEqual((try await fixture.cache.stats(maxAge: 0)).total, 3, "the three rows it did reach survive")

        // The same three rows, but the second scan only reached two of them.
        try await scan(300, ["shared-1", "shared-2"])
        checkEqual(try await fixture.cache.finishScan(marker: 300), 1,
                   "exactly the row this scan never reached is removed")
        checkNil(try await fixture.cache.photo(identifier: "only-in-200"), "the unvisited row is gone")
        checkNotNil(try await fixture.cache.photo(identifier: "shared-1"), "the visited rows are not")
        checkNotNil(try await fixture.cache.photo(identifier: "shared-2"), "including the one stamped by an older scan")

        // And two scans that each stamped only part of the library delete each other's
        // rows. This is precisely why `AnalysisEngine.requestRescan` must serialise:
        // the marker is the *only* thing standing between a rescan and the loss of
        // every score another scan had written.
        let other = try await Fixture.make("sm-finishscan-2")
        try await other.cache.upsert(batch: ["x-1", "x-2"].map {
            ScanRecord(identifier: $0, mediaType: 1, creationDate: 1, modificationDate: 1, width: 1,
                       height: 1, favorite: false, mediaSubtype: 0, isScreenshot: false)
        }, marker: 10)
        try await other.cache.upsert(batch: ["x-2", "x-3"].map {
            ScanRecord(identifier: $0, mediaType: 1, creationDate: 1, modificationDate: 1, width: 1,
                       height: 1, favorite: false, mediaSubtype: 0, isScreenshot: false)
        }, marker: 20)
        checkEqual(try await other.cache.finishScan(marker: 10), 2,
                   "scan 10 removes the two rows only scan 20 reached")
        checkEqual(try await other.cache.finishScan(marker: 20), 1, "and scan 20 then removes the one scan 10 reached")
        checkEqual((try await other.cache.stats(maxAge: 0)).total, 0, "two interleaved scans erase each other")
    })

    Registry.shared.add(suite: suite, TestCase(name: "finishScan is destructive for rows a scan never reached",
        knownBug: nil) {
        // `finishScan` deletes every row not stamped with this marker, which is why
        // `AnalysisEngine.scan` may only call it after a complete walk. This case pins
        // those destructive semantics rather than the caller's ordering, which needs
        // a real library walk.
        let fixture = try await Fixture.make("sm-partial")
        try await fixture.seed((0..<10).map { .init(id: "p-\($0)", score: 0.5, date: Double($0)) })
        // A scan that only got half way: only half the rows carry the new marker.
        try await fixture.cache.upsert(batch: (0..<5).map {
            ScanRecord(identifier: "p-\($0)", mediaType: 1, creationDate: 0, modificationDate: 0, width: 1,
                       height: 1, favorite: false, mediaSubtype: 0, isScreenshot: false)
        }, marker: 999)
        let removed = try await fixture.cache.finishScan(marker: 999)
        checkEqual(removed, 5, "finishScan deletes anything the scan did not reach")
        checkEqual((try await fixture.cache.stats(maxAge: 0)).total, 5,
                   "which is exactly why it must only run after a full walk")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the state machine never writes a state outside the enum",
        knownBug: nil) {
        let fixture = try await Fixture.make("sm-enum")
        try await fixture.seed([
            .init(id: "a", score: 0.5, date: 1),
            .init(id: "b", score: nil, date: 2, state: .pending),
            .init(id: "c", score: nil, date: 3, state: .failed),
            .init(id: "d", score: nil, date: 4, state: .unavailable),
        ])
        _ = try await fixture.cache.claimJobs(limit: 1)
        try await fixture.cache.record(score: 0.1, for: "b")
        let distinct = try fixture.query("SELECT DISTINCT analysis_state FROM assets;") { statement -> [String] in
            var values: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let raw = RawSQL.string(statement, 0) { values.append(raw) }
            }
            return values
        }
        check(distinct.count >= 3, "the fixture reached most of the machine, saw \(distinct)")
        for value in distinct {
            checkNotNil(AnalysisState(rawValue: value), "stored state \"\(value)\" must be a declared state")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "the accounting identity holds after every transition",
        knownBug: nil) {
        let fixture = try await Fixture.make("sm-accounting")
        try await fixture.seed([
            .init(id: "d-1", score: 0.5, date: 1),
            .init(id: "d-2", score: -0.9, date: 2),
            .init(id: "p-1", score: nil, date: 3, state: .pending),
            .init(id: "f-1", score: nil, date: 4, state: .failed),
            .init(id: "u-1", score: nil, date: 5, state: .unavailable),
            .init(id: "a-1", score: nil, date: 6, state: .pending),
        ])
        _ = try await fixture.cache.claimJobs(limit: 1)

        func identity(_ label: String) async throws {
            let stats = try await fixture.cache.stats(maxAge: 0)
            checkEqual(stats.analyzed + stats.failed + stats.unavailable + stats.pending, stats.total,
                       "\(label): analyzed + failed + unavailable + pending == total")
            let counts = try await fixture.stateCounts()
            checkEqual(counts.values.reduce(0, +), stats.total, "\(label): the per-state counts add up to the total")
        }
        try await identity("after seeding")
        try await fixture.cache.record(score: 0.2, for: "a-1")
        try await identity("after a completion")
        try await fixture.cache.recordFailure(for: "p-1", error: "boom")
        try await identity("after a failure")
        try await fixture.cache.releaseClaims(identifiers: ["p-1"])
        try await identity("after a release")
        try await fixture.cache.beginScan()
        try await identity("after a rescan")

        let stats = try await fixture.cache.stats(maxAge: 0)
        checkEqual(stats.total, 6, "total")
        checkEqual(stats.analyzed, 3, "analyzed")
        checkEqual(stats.failed, 1, "failed")
        checkEqual(stats.unavailable, 1, "unavailable")
        checkEqual(stats.pending, 1, "pending")
        checkEqual(stats.favorites, 0, "favorites")
    })

    Registry.shared.add(suite: suite, TestCase(name: "stats over an empty cache report nothing rather than zero",
        knownBug: nil) {
        let fixture = try await Fixture.make("sm-emptystats")
        let stats = try await fixture.cache.stats(maxAge: 0)
        checkEqual(stats.total, 0, "total")
        checkNil(stats.minScore, "there is no minimum score over an empty cache")
        checkNil(stats.maxScore, "nor a maximum — the UI must not be handed a 0…0 range as if it were real")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the stats cache is invalidated by every write", knownBug: nil) {
        let fixture = try await Fixture.make("sm-statcache")
        try await fixture.seed([.init(id: "a", score: 0.5, date: 1)])
        checkEqual((try await fixture.cache.stats(maxAge: 0.25)).total, 1, "one row")
        try await fixture.seed([.init(id: "b", score: 0.6, date: 2)])
        checkEqual((try await fixture.cache.stats(maxAge: 0.25)).total, 2,
                   "a write must invalidate the cached stats, or the UI would report a stale library size")
        try await fixture.cache.remove(identifiers: ["a"])
        checkEqual((try await fixture.cache.stats(maxAge: 0.25)).total, 1, "and so must a deletion")
    })

    Registry.shared.add(suite: suite, TestCase(name: "remove is all-or-nothing across chunks", knownBug: nil) {
        let fixture = try await Fixture.make("sm-remove")
        let ids = (0..<900).map { "r-\(String(format: "%04d", $0))" }
        try await fixture.seed(ids.map { .init(id: $0, score: 0.5, date: 1) })
        checkEqual((try await fixture.cache.stats(maxAge: 0)).total, 900, "seeded")

        // Deliberately include an identifier that is not in the cache: a real
        // deletion cohort can arrive with a row the cache no longer has.
        try await fixture.cache.remove(identifiers: ids + ["not-in-the-cache"])
        checkEqual((try await fixture.cache.stats(maxAge: 0)).total, 0,
                   "removal spans three 400-identifier chunks in one transaction")
        try await fixture.cache.remove(identifiers: [])
        checkEqual((try await fixture.cache.stats(maxAge: 0)).total, 0, "removing nothing is a no-op")
    })

    Registry.shared.add(suite: suite, TestCase(name: "claimJobs claims only the media types analysis understands",
        knownBug: nil) {
        // The queue is bounded by media type, not open to everything the walk can
        // produce: `PHAssetMediaType` has values this pipeline has no work for, and a
        // row in one of them must sit in `pending` rather than be handed to a worker
        // that cannot do anything with it — and must not be parked `failed` either,
        // which would be a claim about the asset that nothing observed.
        let fixture = try await Fixture.make("sm-mediatype")
        let records = ["still", "clip", "audio"].enumerated().map { offset, id in
            ScanRecord(identifier: id, mediaType: offset + 1, creationDate: Double(offset + 1),
                       modificationDate: Double(offset + 1), width: 1, height: 1,
                       favorite: false, mediaSubtype: 0, isScreenshot: false)
        }
        try await fixture.cache.upsert(batch: records, marker: 1)

        // Newest first, which is the order the walk found them in.
        checkEqual(try await fixture.cache.claimJobs(limit: 10).map(\.identifier), ["clip", "still"],
                   "a still and a clip are both claimed")
        checkEqual(try await fixture.analysisState(of: "audio"), .pending,
                   "and a media type this pipeline does not handle is left pending, not failed")
        checkEqual(try await fixture.cache.claimJobs(limit: 10).map(\.identifier), [],
                   "nothing else is offered, so the unhandled row is not a poison pill")
    })
}