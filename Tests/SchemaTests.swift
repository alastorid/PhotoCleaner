import Foundation

// Schema versioning.
//
// The cache is the one piece of state that outlives the process, and every build a
// user ever runs opens it. So "an older cache upgrades in place" is a promise about
// real data, not a claim about a fresh file. These cases rewind a database to an
// older version — dropping the tables that version never had, exactly as an older
// build left them — and then point the *current* code at it.
//
// Two details do the work. The connection that created the cache is replaced, so
// the upgrade really is a fresh `migrate()` over an existing file rather than a
// second run on a connection that already migrated. And the version stamp is
// asserted, not assumed: `migrate()` is idempotent by construction, so it can create
// every table correctly and still leave `user_version` behind, which would make the
// *next* launch believe the cache predates the album tables.
//
// Seeding goes through the production write path, so a fixture cannot create a row
// the application itself could not produce.

func registerSchemaTests() {
    let suite = "cache schema"

    Registry.shared.add(suite: suite, TestCase(name: "a fresh cache is stamped with the current version",
        knownBug: nil) {
        let fixture = try await Fixture.make("schema-fresh")
        checkEqual(try await fixture.cache.schemaUserVersion(), CacheStore.schemaVersion,
                   "user_version on a brand-new cache")
    })

    Registry.shared.add(suite: suite, TestCase(name: "migrating twice changes nothing",
        knownBug: nil) {
        // Every step in `migrate()` is `IF NOT EXISTS`, which is what lets the app
        // call it unconditionally on launch. If a step ever grows a `CREATE` without
        // the guard, or starts rewriting rows, this case fails.
        let fixture = try await Fixture.make("schema-idempotent")
        try await fixture.seed([.init(id: "a", score: 0.5, date: 100)])
        let before = try await fixture.cache.stats(maxAge: 0)
        try await fixture.cache.migrate()
        try await fixture.cache.migrate()
        let after = try await fixture.cache.stats(maxAge: 0)
        checkEqual(after.total, before.total, "row count survives repeated migration")
        checkEqual(after.analyzed, before.analyzed, "and so does the analysis state")
        checkEqual(try await fixture.cache.schemaUserVersion(), CacheStore.schemaVersion,
                   "and the version is still current")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a version 1 cache is upgraded without losing a single row",
        knownBug: nil) {
        // The case the others lean on. An older build wrote `assets` and
        // `asset_signals`; the current build adds albums and groups. The upgrade must
        // be a pure insert — no dropped table, no rewritten score, no reset analysis
        // state — or a user who upgrades loses the work already done on their behalf,
        // which is the one failure mode a cache cannot recover from.
        let fixture = try await Fixture.make("schema-upgrade")
        try await fixture.seed([
            .init(id: "keep-scored", score: 0.75, date: 100),
            .init(id: "keep-negative", score: -0.9476, date: 200),
            .init(id: "keep-perfect", score: 1.0, date: 300),
            .init(id: "keep-favourite", score: 0.1, date: 400, favorite: true),
            .init(id: "keep-cloud-only", score: nil, date: 500, state: .unavailable),
        ])
        try fixture.rewindSchema(to: 1, dropping: Fixture.postV1Tables)
        checkEqual(try await fixture.cache.schemaUserVersion(), 1, "the fixture is rewound to version 1")

        let upgraded = try await Fixture.reopen(fixture)
        checkEqual(try await upgraded.cache.schemaUserVersion(), CacheStore.schemaVersion,
                   "the upgrade advances the stamp — a stale version is a bug in its own right")

        checkEqual(try await upgraded.cache.photo(identifier: "keep-scored")?.score, 0.75,
                   "an existing score survives the upgrade")
        checkEqual(try await upgraded.cache.photo(identifier: "keep-scored")?.date.map { Int($0) },
                   100, "and so does its date")

        // The score range is data-derived and is not 0…1, so an upgrade that
        // "normalises" scores into [0,1] would quietly rewrite real observations.
        // That is exactly the corruption worth pinning, because it is invisible: the
        // grid still renders, it is just no longer showing what Vision said.
        checkEqual(try await upgraded.cache.photo(identifier: "keep-negative")?.score, -0.9476,
                   "a negative score is not clamped or rescaled")
        checkEqual(try await upgraded.cache.photo(identifier: "keep-perfect")?.score, 1.0,
                   "nor is the pile-up at the top")
        checkEqual(try await upgraded.cache.photo(identifier: "keep-favourite")?.favorite, true,
                   "favourite flags survive, so protection still applies after an upgrade")

        // `unavailable` must stay `unavailable`: it is neither a failure nor
        // `pending`, and downgrading it would re-queue cloud-only photos forever.
        let stats = try await upgraded.cache.stats(maxAge: 0)
        checkEqual(stats.total, 5, "every row survives")
        checkEqual(stats.unavailable, 1, "a cloud-only asset is still unavailable, not pending")
        checkEqual(stats.analyzed, 4, "and the four scored assets are still analysed")
        checkEqual(stats.minScore, -0.9476, "the observed minimum is still the observed minimum")
        checkEqual(stats.maxScore, 1.0, "and so is the maximum")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the tables added after version 1 work once migrated",
        knownBug: nil) {
        // Same upgrade, but the new tables are *exercised* rather than merely
        // counted. Nothing reads albums or groups on a small fixture, so a migration
        // that creates a table with the wrong shape fails here and nowhere else.
        let fixture = try await Fixture.make("schema-new-tables")
        try await fixture.seed([.init(id: "a", score: 0.5, date: 100)])
        try fixture.rewindSchema(to: 1, dropping: Fixture.postV1Tables)

        let upgraded = try await Fixture.reopen(fixture)

        try await upgraded.cache.upsertAlbum(identifier: "album-1", title: "Trips", collectionType: 1)
        try await upgraded.cache.replaceAlbumMembership(albumIdentifier: "album-1", identifiers: ["a"])

        let albums = try await upgraded.cache.albums()
        checkEqual(albums.map(\.identifier), ["album-1"], "an album written after the upgrade reads back")
        checkEqual(albums.first?.title, "Trips", "with its title")
        checkEqual(albums.first?.assetCount, 1, "and its membership count")
        checkEqual(albums.first?.indexedAt == nil, false, "and is marked as indexed")

        // A featureprint_queue row is the backfill's claim on an asset that already
        // holds a score. It is filled by `beginScan()` — the scan is what discovers
        // the asset, so that is where the claim belongs — which means the table
        // arriving from the migration is not enough on its own: the query that
        // refills it has to run against the migrated shape too.
        try await upgraded.cache.beginScan()
        let claims = try await upgraded.cache.claimFeaturePrints(limit: 10)
        checkEqual(claims, ["a"], "a scored asset with no vector is queued for backfill by the migration")
        checkEqual(try await upgraded.cache.claimFeaturePrints(limit: 10).count, 0,
                   "and claiming consumes the row, so a claim is never stale")

        // Once the vector lands the asset must leave the queue for good, or every
        // launch would re-claim it forever. A real FeaturePrint rather than an
        // arbitrary blob, because what is stored is the compressed encoding of one.
        let vector = try await makeFeaturePrint(.verticalBands)
        guard let payload = SignalCompression.featurePrintData(vector) else {
            Harness.record("could not encode a FeaturePrint")
            return
        }
        try await upgraded.cache.recordFeaturePrint(payload, for: "a")
        checkEqual(try await upgraded.cache.claimFeaturePrints(limit: 10).count, 0,
                   "an asset that has a vector is not re-claimed")
        checkEqual(try await upgraded.cache.signalCounts().featurePrints, 1,
                   "and the stored vector is counted as one")
    })
}