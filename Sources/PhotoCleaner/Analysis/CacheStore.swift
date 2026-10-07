import Foundation
import SQLite3

enum CacheError: Error, CustomStringConvertible {
    case open(String)
    case sql(String, String)
    case cursorSortMismatch(requested: String, cursor: String)
    /// Schema version 2: a token is bound to the filter that issued it as well as
    /// to its ordering, because "the rows after this row" only names a place
    /// inside one result set.
    case cursorFilterMismatch

    var description: String {
        switch self {
        case .open(let detail): return "could not open the score cache: \(detail)"
        case .sql(let statement, let detail): return "cache query failed (\(detail)): \(statement)"
        case .cursorSortMismatch(let requested, let cursor):
            // A caller's mistake, not a cache problem — `Router` maps every error
            // out of `page` to 500 today; this one deserves 400.
            return "this pagination cursor was issued for the \"\(cursor)\" ordering and cannot be "
                + "used with \"\(requested)\"; restart from the first page"
        case .cursorFilterMismatch:
            return "this pagination cursor was issued for a different filter and cannot be used "
                + "here; restart from the first page"
        }
    }
}

struct CacheStats: Sendable {
    var total = 0
    var analyzed = 0
    var failed = 0
    var unavailable = 0
    var pending = 0
    var favorites = 0
    /// Scanned assets whose media type is video. `total` and `favorites` are
    /// unchanged and now mean "all scanned assets", videos included — this is the
    /// extra number that lets a caller say *which* of them are videos rather than
    /// inferring it by subtraction.
    var videos = 0
    var minScore: Float?
    var maxScore: Float?
}

struct PhotoPage: Sendable {
    var total = 0
    var rows: [PhotoRow] = []
    var nextCursor: String?
}

struct AssetJob: Sendable {
    let identifier: String
    /// True when this job only needs a FeaturePrint, because the asset was scored
    /// by an earlier build and already holds a correct aesthetics score.
    ///
    /// Such a job must not touch `analysis_state` or `aesthetics_score`: the score
    /// is good, and requeueing it would null it and drop the photo out of the grid
    /// until a full re-run finished.
    let isBackfill: Bool

    /// A job that needs the full analysis pass: aesthetics and FeaturePrint.
    init(identifier: String) {
        self.identifier = identifier
        self.isBackfill = false
    }

    /// A backfill job: the asset already holds its score and needs only the vector.
    init(backfill identifier: String) {
        self.identifier = identifier
        self.isBackfill = true
    }
}

/// Persistent, dependency-free score cache.
///
/// SQLite ships with macOS, needs no server, and handles a 100k-row library with
/// a few megabytes of disk. The schema is intentionally wider than version 1
/// needs: `asset_signals` exists so that FeaturePrint vectors, duplicate scores,
/// blur metrics or preference scores can be added later without touching the
/// asset table or invalidating existing caches.
///
/// An `actor` owns the connection: `sqlite3` handles are not thread-safe, and
/// serialising through the actor removes the need for a lock around every call.
actor CacheStore {
    /// Bump when the meaning of a stored score changes. Assets scored by an
    /// older version are re-queued on the next scan.
    static let analyzerVersion = 1

    /// Owns the `sqlite3` handle.
    ///
    /// A reference box is used so the connection is closed when it is released,
    /// without the actor needing a `deinit` (an actor's `deinit` is nonisolated
    /// and cannot touch non-`Sendable` isolated state). The pointer is only ever
    /// dereferenced from actor-isolated code.
    private final class Connection: @unchecked Sendable {
        let pointer: OpaquePointer?

        init(pointer: OpaquePointer?) {
            self.pointer = pointer
        }

        deinit {
            if let pointer { sqlite3_close_v2(pointer) }
        }
    }

    private let connection: Connection
    private let path: String
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Actor-isolated accessor for the handle.
    private var db: OpaquePointer? { connection.pointer }

    private var cachedStats: CacheStats?
    private var cachedStatsAt: Date = .distantPast

    init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close_v2(handle) }
            throw CacheError.open(message)
        }
        self.connection = Connection(pointer: handle)
        sqlite3_busy_timeout(handle, 5_000)
    }

    // MARK: - Schema

    /// Current on-disk schema version. Bump together with a migration step below.
    ///
    /// Version 1: `assets`, `asset_signals` and the indexes the queue needs.
    /// Version 2: the album tables. Deliberately additive — see `migrate`.
    /// Version 3: `similar_groups`, `similar_group_members` and
    /// `featureprint_queue`.
    /// Version 4: the three group settings version 3 did not record, so a stored
    /// group can say which *rules* produced it and not only which threshold.
    /// Version 5: `assets.duration_seconds`, so a scored video can say how long it
    /// is without PhotoKit being asked again.
    ///
    /// Covered by `SchemaTests`, which rewinds a database to an older version and
    /// upgrades it — the one guarantee here that cannot be checked on a fresh file,
    /// because a fresh file is already at the current version.
    static let schemaVersion = 5

    /// Creates or upgrades the schema. Idempotent, and safe to run against a
    /// database an older build wrote: every step is `IF NOT EXISTS` or is guarded
    /// by a column check, nothing is dropped or rewritten, and no existing column
    /// changes meaning — the two steps that touch an existing table (version 4's
    /// group settings and version 5's `duration_seconds`) only *add* columns, which
    /// is why the rows an older build wrote survive both.
    ///
    /// **Version 2 (albums).** The existing `assets` table has exactly one row per
    /// asset and albums are many-to-many, so they cannot be columns on it: a
    /// photo in four albums needs four rows. Two new tables instead —
    ///
    /// - `albums` — one row per **user** album (`PHCollectionType.album`), keyed
    ///   by PhotoKit's `PHAssetCollection.localIdentifier`. Smart albums are
    ///   deliberately not stored; see `AlbumSelection`.
    /// - `asset_albums` — the many-to-many join, one row per (asset, album) pair.
    ///   The primary key is `(asset_identifier, album_identifier)`, so it *is* the
    ///   index for the correlated `EXISTS` the album filter runs once per
    ///   candidate row, and it makes a duplicate membership impossible. The
    ///   foreign key cascades, so deleting a photo — through the API or through
    ///   `finishScan` — takes its album rows with it instead of leaving orphans
    ///   that would make an album look larger than it is.
    ///
    /// Row cost, honestly: a 53,273-photo library with album membership is on the
    /// order of one row per membership — tens of thousands for a user with a few
    /// large albums, and `Recents`-sized if someone put a whole library into one
    /// album. That is why membership is populated one album at a time, in
    /// ascending order of size, and never on the launch path.
    func migrate() throws {
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("""
        CREATE TABLE IF NOT EXISTS assets (
            asset_identifier  TEXT PRIMARY KEY,
            media_type        INTEGER NOT NULL DEFAULT 1,
            creation_date     REAL,
            modification_date REAL,
            width             INTEGER NOT NULL DEFAULT 0,
            height            INTEGER NOT NULL DEFAULT 0,
            favorite          INTEGER NOT NULL DEFAULT 0,
            media_subtype     INTEGER NOT NULL DEFAULT 0,
            is_screenshot     INTEGER NOT NULL DEFAULT 0,
            aesthetics_score  REAL,
            analysis_state    TEXT NOT NULL DEFAULT 'pending',
            attempts          INTEGER NOT NULL DEFAULT 0,
            last_error        TEXT,
            scored_at         REAL,
            scan_marker       INTEGER NOT NULL DEFAULT 0,
            analyzer_version  INTEGER NOT NULL DEFAULT 0
        );
        """)
        try execute("""
        CREATE INDEX IF NOT EXISTS idx_assets_score
            ON assets(aesthetics_score) WHERE aesthetics_score IS NOT NULL;
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_assets_state ON assets(analysis_state);")
        try execute("CREATE INDEX IF NOT EXISTS idx_assets_queue ON assets(analysis_state, creation_date DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_assets_date ON assets(creation_date);")

        // Reserved for version 2+: one row per (asset, signal kind). Kept empty
        // in version 1, documented here so the future addition is a pure insert
        // rather than a migration of the asset table.
        try execute("""
        CREATE TABLE IF NOT EXISTS asset_signals (
            asset_identifier TEXT NOT NULL,
            signal           TEXT NOT NULL,
            value            REAL,
            payload          BLOB,
            analyzer_version INTEGER NOT NULL DEFAULT 0,
            computed_at      REAL,
            PRIMARY KEY (asset_identifier, signal),
            FOREIGN KEY (asset_identifier) REFERENCES assets(asset_identifier) ON DELETE CASCADE
        );
        """)

        // ---- version 2: albums -------------------------------------------------
        // Additive only. `assets` is not touched, so every score, timestamp and
        // analysis state an older cache holds survives this untouched.
        try execute("""
        CREATE TABLE IF NOT EXISTS albums (
            album_identifier TEXT PRIMARY KEY,
            title            TEXT NOT NULL DEFAULT '',
            -- Recorded, never filtered on. `PhotoLibrary.userAlbums` is the only
            -- writer and it enumerates `PHAssetCollectionType.album` and nothing
            -- else, so the type is a record of what was asked for rather than a
            -- filter; see `AlbumRecord.collectionType`.
            collection_type  INTEGER NOT NULL DEFAULT 1,
            -- Populated (membership rows written) at least once, and when.
            indexed_at       REAL,
            -- Version 2 wrote this as the album's membership size. Nothing has read
            -- it since, because the count that is served is deliberately *not* this
            -- one: `albums()` recounts over scored assets, so the number on the chip
            -- is the number of tiles the filter will actually yield. The column stays
            -- because a cache on disk is not ours to reshape, and it is no longer
            -- written — one `COUNT(*)` per album per pass for nobody.
            estimated_count  INTEGER NOT NULL DEFAULT 0
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS asset_albums (
            asset_identifier TEXT NOT NULL,
            album_identifier TEXT NOT NULL,
            PRIMARY KEY (asset_identifier, album_identifier),
            FOREIGN KEY (asset_identifier) REFERENCES assets(asset_identifier) ON DELETE CASCADE
        );
        """)
        // The primary key already indexes `asset_identifier` first, which is what
        // the filter's correlated lookup uses; this one serves the album's own
        // asset list and the "how many photos" count.
        try execute("CREATE INDEX IF NOT EXISTS idx_asset_albums_album ON asset_albums(album_identifier);")

        // ---- version 3: similar groups ----------------------------------------
        // Additive, like version 2. `assets` and `asset_signals` are untouched, so
        // every aesthetics score, FeaturePrint and analysis state an older cache
        // holds survives: this is a pure insert.
        //
        // Groups are **materialised**, not computed per request. Rebuilding them
        // means decoding FeaturePrints for the library and walking the capture-time
        // neighbourhood — measured at ~3.9M distance comparisons for a 53k library —
        // which is far too much to do inside a request handler. A rebuild writes
        // here and browsing reads.
        //
        // The FeaturePrint itself stays in `asset_signals` and is *not* copied here:
        // one payload per asset, joined on demand. Storing it twice would double
        // ~144 MB of compressed vectors for no benefit.
        try execute("""
        CREATE TABLE IF NOT EXISTS similar_groups (
            group_id            TEXT PRIMARY KEY,
            member_count        INTEGER NOT NULL DEFAULT 0,
            face_member_count   INTEGER NOT NULL DEFAULT 0,
            earliest_date       REAL,
            -- The settings this group was built under. Kept so a rebuild triggered
            -- by a settings change can tell "these groups are stale" from "these
            -- groups were built with different rules" and report the latter rather
            -- than silently serving groups built under rules the user has moved on
            -- from.
            window_seconds      REAL,
            max_distance        REAL,
            -- True once every member has a face-capture result. Until then a
            -- portrait group's Best Shot ordering is incomplete, and the UI says so
            -- instead of presenting a half-ranked group as finished.
            ranked_at           REAL,
            built_at            REAL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS similar_group_members (
            group_id        TEXT NOT NULL,
            asset_identifier TEXT NOT NULL,
            PRIMARY KEY (group_id, asset_identifier),
            FOREIGN KEY (group_id) REFERENCES similar_groups(group_id) ON DELETE CASCADE,
            FOREIGN KEY (asset_identifier) REFERENCES assets(asset_identifier) ON DELETE CASCADE
        );
        """)
        // The group list is ordered by size then id, and the members of one group
        // are read in either ranking order — both need the group id first.
        try execute("CREATE INDEX IF NOT EXISTS idx_similar_groups_order ON similar_groups(member_count DESC, group_id);")
        // Serves "every group this asset belongs to" during a rebuild's cascade
        // cleanup and the deletion path.
        try execute("CREATE INDEX IF NOT EXISTS idx_similar_group_members_asset ON similar_group_members(asset_identifier);")

        // ---- version 3: the FeaturePrint backfill queue -------------------------
        // Assets that already hold an aesthetics score but no FeaturePrint, because
        // they were scored by a build that predates the signal. Claiming a row means
        // deleting it, so a crash loses the claim rather than leaving a placeholder
        // that would never be filled. See `refreshFeaturePrintQueue`.
        try execute("""
        CREATE TABLE IF NOT EXISTS featureprint_queue (
            asset_identifier TEXT PRIMARY KEY,
            FOREIGN KEY (asset_identifier) REFERENCES assets(asset_identifier) ON DELETE CASCADE
        );
        """)

        // ---- version 4: the rest of the settings a pass was built under --------
        // Additive like everything above, and the only step that has to *alter* an
        // existing table, because a version 3 cache already has `similar_groups` and
        // the columns belong to it rather than to a new table.
        //
        // Version 3 stored the capture window and the FeaturePrint threshold — the
        // two knobs that decide *which photos are grouped* — and read them back into
        // `GroupSummary`, where nothing consumed them. The knobs a pass also used
        // had nowhere to go, so "were these groups built with different rules?"
        // could not be answered for them: after a restart the answer was always
        // "no", because the comparison lived in the engine's memory. Recording the
        // remaining three makes the stored row a complete statement of the rules it
        // was built under. See `newestGroupPass`.
        try addColumnIfMissing("similar_groups", name: "face_weight", type: "REAL")
        try addColumnIfMissing("similar_groups", name: "minimum_face_area", type: "REAL")
        try addColumnIfMissing("similar_groups", name: "maximum_group_size", type: "INTEGER")

        // ---- version 5: clip duration ------------------------------------------
        // The only column video support adds, and it is additive like every step
        // above: an existing cache upgrades in place with every score intact.
        //
        // `NULL`, not `0`, for every row written before this version, and that is
        // the honest value rather than a placeholder: those rows are either stills
        // — which have no duration — or videos this build has not re-scanned yet,
        // and both of those are "unknown", not "zero seconds long". A client that
        // renders a duration badge must therefore omit it, exactly as it omits any
        // other absent field, rather than printing `0:00` for a nine-minute clip.
        // `0` would be a claim about the asset, and this codebase never writes a
        // claim it cannot source.
        try addColumnIfMissing("assets", name: "duration_seconds", type: "REAL")

        try execute("PRAGMA user_version = \(Self.schemaVersion);")
    }

    /// Adds one column to an existing table, if it is not already there.
    ///
    /// SQLite has no `ALTER TABLE … ADD COLUMN IF NOT EXISTS`, so a step that has
    /// to alter a table has to *read* its shape first. That is what keeps this
    /// idempotent, which in turn is what lets `migrate()` keep running
    /// unconditionally on every launch: a column added on the first upgrade is found
    /// on the second and skipped.
    ///
    /// `table` and `name` are literals at both call sites, never anything a caller
    /// supplies — there is no parameter for a value that has to reach SQL as text.
    private func addColumnIfMissing(_ table: String, name: String, type: String) throws {
        let existing = try withStatement("PRAGMA table_info(\(table));") { statement -> Set<String> in
            var columns: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                columns.insert(text(statement, 1))
            }
            return columns
        }
        guard !existing.contains(name) else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(name) \(type);")
    }

    /// Reads `PRAGMA user_version`. Used by the migration tests and by
    /// `albumIndexComplete`, which treats a cache written before version 2 as
    /// "no albums indexed" rather than "the user has no albums".
    func schemaUserVersion() throws -> Int {
        var value = 0
        try withStatement("PRAGMA user_version;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return }
            value = Int(sqlite3_column_int(statement, 0))
        }
        return value
    }

    // MARK: - SQLite plumbing

    private func execute(_ sql: String) throws {
        guard let db else { throw CacheError.open("connection closed") }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw CacheError.sql(sql, message)
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let db else { throw CacheError.open("connection closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CacheError.sql(sql, String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func run(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw CacheError.sql("step", message)
        }
    }

    private func invalidateStats() {
        cachedStats = nil
    }

    // MARK: - Library scan

    func beginScan() throws {
        // Anything left in `analyzing` from a previous run was interrupted by a
        // crash or a quit mid-analysis; it goes back in the queue.
        try execute("UPDATE assets SET analysis_state = 'pending' WHERE analysis_state = 'analyzing';")
        try refreshFeaturePrintQueue()
    }

    /// Queues a FeaturePrint for every asset that has a score but no vector.
    ///
    /// ## Why this is a queue and not a re-analysis
    ///
    /// A FeaturePrint arrived after a library had already been scored, and
    /// `upsert` deliberately keeps a `done` asset `done` when its modification date
    /// and analyzer version are unchanged. So without this, every photo scored by an
    /// earlier build would keep its score and never gain a vector — Similar Groups
    /// would silently be empty for exactly the users who already have a cache, and
    /// only photos analysed *after* upgrading would ever appear in one.
    ///
    /// Re-scoring instead of backfilling would work but throws away a good score to
    /// recompute it, and `upsert` nulls `aesthetics_score` on requeue — so the
    /// photos would vanish from the grid for the duration of a multi-minute pass.
    /// This queue carries only the new signal and touches nothing else.
    ///
    /// A row is claimed by being *deleted*, and completed by writing the vector. A
    /// crash therefore loses the claim and the asset is retried, rather than
    /// leaving a placeholder that would silently never be filled.
    ///
    /// The version guard is what makes `asset_signals.analyzer_version` mean
    /// something. A vector written by an earlier build is re-queued for the same
    /// reason a score is: `analyzerVersion` is the promise that "the meaning of a
    /// stored observation changes when this number changes", and a cache that
    /// checked only for the row's *existence* would keep comparing FeaturePrints
    /// computed under rules the current build no longer applies — with no symptom
    /// other than subtly wrong groups. Rows written by the current build carry its
    /// version, so this costs nothing until the version is actually bumped.
    ///
    /// **Videos are excluded, and that is a decision rather than a gap.** A
    /// FeaturePrint is Apple's answer to "are these the same shot?". For a video
    /// it would be one arbitrary frame of a clip that may pan off the very thing a
    /// still shows, so the distance would be answering a question nobody asked, and
    /// the `maxDistance` threshold and the capture window were both calibrated on
    /// stills against bursts and retakes. Admitting clip frames would silently
    /// change what a distance *means* for every group already stored. Excluding
    /// them here is the belt; `VisionAnalyzer.analyzeFrames` returning no vector for
    /// a multi-frame subject is the braces, and a video therefore has no path into
    /// `similar_group_members` at all.
    private func refreshFeaturePrintQueue() throws {
        try withStatement("""
        INSERT OR IGNORE INTO featureprint_queue (asset_identifier)
        SELECT a.asset_identifier
        FROM assets a
        WHERE a.aesthetics_score IS NOT NULL
          AND a.media_type = 1
          AND NOT EXISTS (
            SELECT 1 FROM asset_signals s
            WHERE s.asset_identifier = a.asset_identifier AND s.signal = ?
              AND s.analyzer_version = ?
          );
        """) { statement in
            bind(statement, 1, Signal.featurePrint.rawValue)
            sqlite3_bind_int(statement, 2, Int32(Self.analyzerVersion))
            try run(statement)
        }
    }

    func upsert(batch: [ScanRecord], marker: Int64) throws {
        // `duration_seconds` is written on conflict unconditionally, exactly like
        // `media_type` and `favorite`: they are facts Photos reported about the
        // asset right now, so the newest scan always wins. It is *not* given one of
        // the guarded `CASE` arms below, which exist for a different reason —
        // those preserve a score that is still valid, and duration is not a score.
        // A video scanned for the first time lands on the existing `ELSE 'pending'`
        // arm and is queued; a video already `done` keeps its score untouched,
        // exactly as a photo does, and a still keeps a NULL duration.
        let sql = """
        INSERT INTO assets (
            asset_identifier, media_type, creation_date, modification_date, width, height,
            favorite, media_subtype, is_screenshot, duration_seconds,
            analysis_state, scan_marker, analyzer_version
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
        ON CONFLICT(asset_identifier) DO UPDATE SET
            media_type        = excluded.media_type,
            creation_date     = excluded.creation_date,
            modification_date = excluded.modification_date,
            width             = excluded.width,
            height            = excluded.height,
            favorite          = excluded.favorite,
            media_subtype     = excluded.media_subtype,
            is_screenshot     = excluded.is_screenshot,
            duration_seconds  = excluded.duration_seconds,
            scan_marker       = excluded.scan_marker,
            analysis_state    = CASE
                WHEN assets.analysis_state = 'done'
                     AND (assets.modification_date IS NOT excluded.modification_date
                          OR assets.analyzer_version < excluded.analyzer_version)
                     THEN 'pending'
                WHEN assets.analysis_state = 'done' THEN 'done'
                WHEN assets.analysis_state = 'analyzing' THEN 'analyzing'
                WHEN assets.analysis_state = 'unavailable' THEN 'unavailable'
                ELSE 'pending'
            END,
            aesthetics_score  = CASE
                WHEN assets.analysis_state = 'done'
                     AND (assets.modification_date IS NOT excluded.modification_date
                          OR assets.analyzer_version < excluded.analyzer_version)
                     THEN NULL
                ELSE assets.aesthetics_score
            END,
            scored_at         = CASE
                WHEN assets.analysis_state = 'done'
                     AND (assets.modification_date IS NOT excluded.modification_date
                          OR assets.analyzer_version < excluded.analyzer_version)
                     THEN NULL
                ELSE assets.scored_at
            END;
        """
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement(sql) { statement in
                for record in batch {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(statement, 1, record.identifier)
                    sqlite3_bind_int(statement, 2, Int32(record.mediaType))
                    bind(statement, 3, record.creationDate)
                    bind(statement, 4, record.modificationDate)
                    sqlite3_bind_int(statement, 5, Int32(record.width))
                    sqlite3_bind_int(statement, 6, Int32(record.height))
                    sqlite3_bind_int(statement, 7, record.favorite ? 1 : 0)
                    sqlite3_bind_int(statement, 8, Int32(truncatingIfNeeded: record.mediaSubtype))
                    sqlite3_bind_int(statement, 9, record.isScreenshot ? 1 : 0)
                    // NULL for a still, never `0`: `PHAsset.duration` is 0 for an
                    // image, and storing that would be a stored lie about a clip
                    // that does not exist. `bind(_:_: Double?)` binds NULL itself.
                    bind(statement, 10, record.duration)
                    sqlite3_bind_int64(statement, 11, marker)
                    sqlite3_bind_int(statement, 12, Int32(Self.analyzerVersion))
                    try run(statement)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        invalidateStats()
    }

    /// Drops assets that no longer exist in Photos (deleted elsewhere, or on
    /// another device and synced away).
    @discardableResult
    func finishScan(marker: Int64) throws -> Int {
        try execute("DELETE FROM assets WHERE scan_marker <> \(marker);")
        let removed = sqlite3_changes(db)
        invalidateStats()
        return Int(removed)
    }

    // MARK: - Analysis queue

    /// Takes up to `limit` unscored assets, newest first.
    ///
    /// `media_type IN (1, 2)` — images *and* videos. The predicate is spelled as a
    /// two-value `IN` rather than `!= 1` on purpose: the closed set is what the
    /// scoring pass wants, and `!= 1` would quietly start scoring an asset whose
    /// media type is `audio` or `unknown` if Photos ever reported one, which is not
    /// something this pass knows how to produce frames for.
    func claimJobs(limit: Int) throws -> [AssetJob] {
        var jobs: [AssetJob] = []
        // The selection and the state change are one transaction. They were
        // already serialised by the actor, so this is about crash atomicity: a
        // process killed between the SELECT and the UPDATE must leave the rows
        // untouched (`pending`), never half-claimed.
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement("""
            SELECT asset_identifier FROM assets
            WHERE analysis_state = 'pending' AND media_type IN (1, 2)
            ORDER BY creation_date DESC, asset_identifier ASC
            LIMIT ?;
            """) { statement in
                sqlite3_bind_int(statement, 1, Int32(limit))
                while sqlite3_step(statement) == SQLITE_ROW {
                    jobs.append(AssetJob(identifier: text(statement, 0)))
                }
            }
            if !jobs.isEmpty {
                try withStatement("UPDATE assets SET analysis_state = 'analyzing' WHERE asset_identifier = ?;") { statement in
                    for job in jobs {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        bind(statement, 1, job.identifier)
                        try run(statement)
                    }
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        guard !jobs.isEmpty else { return [] }
        invalidateStats()
        return jobs
    }

    /// Puts claimed-but-unresolved jobs back in the queue.
    ///
    /// A worker owns its batch exclusively, so on cancellation the leftovers are
    /// still `analyzing` with nobody working on them; `beginScan` would recover
    /// them, but only on the next launch, and a graceful quit has no next
    /// launch. The `analysis_state` guard makes the statement a no-op for any
    /// row that already reached a terminal state, so a caller can never
    /// resurrect work that has been recorded.
    func releaseClaims(identifiers: [String]) throws {
        guard !identifiers.isEmpty else { return }
        try execute("BEGIN IMMEDIATE;")
        do {
            for chunk in identifiers.chunked(into: 400) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try withStatement("""
                UPDATE assets SET analysis_state = 'pending'
                WHERE analysis_state = 'analyzing' AND asset_identifier IN (\(placeholders));
                """) { statement in
                    for (offset, identifier) in chunk.enumerated() {
                        bind(statement, Int32(offset + 1), identifier)
                    }
                    try run(statement)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        invalidateStats()
    }

    func record(score: Float, for identifier: String) throws {
        try withStatement("""
        UPDATE assets SET aesthetics_score = ?, analysis_state = 'done',
                          scored_at = ?, analyzer_version = ?, last_error = NULL
        WHERE asset_identifier = ?;
        """) { statement in
            sqlite3_bind_double(statement, 1, Double(score))
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            sqlite3_bind_int(statement, 3, Int32(Self.analyzerVersion))
            bind(statement, 4, identifier)
            try run(statement)
        }
        invalidateStats()
    }

    /// Records a failure. One retry is attempted automatically; after that the
    /// asset waits for an explicit retry so a poison image cannot spin forever.
    func recordFailure(for identifier: String, error: String) throws {
        try withStatement("""
        UPDATE assets SET attempts = attempts + 1,
                          last_error = ?,
                          analysis_state = CASE WHEN attempts + 1 < 2 THEN 'pending' ELSE 'failed' END
        WHERE asset_identifier = ?;
        """) { statement in
            bind(statement, 1, String(error.prefix(500)))
            bind(statement, 2, identifier)
            try run(statement)
        }
        invalidateStats()
    }

    /// The pixels are not on this Mac and iCloud downloads are switched off.
    func recordUnavailable(for identifier: String, reason: String) throws {
        try withStatement("""
        UPDATE assets SET analysis_state = 'unavailable', last_error = ?
        WHERE asset_identifier = ?;
        """) { statement in
            bind(statement, 1, String(reason.prefix(500)))
            bind(statement, 2, identifier)
            try run(statement)
        }
        invalidateStats()
    }

    @discardableResult
    func requeueFailures(includeUnavailable: Bool) throws -> Int {
        let clause = includeUnavailable
            ? "analysis_state IN ('failed', 'unavailable')"
            : "analysis_state = 'failed'"
        try execute("UPDATE assets SET analysis_state = 'pending', attempts = 0 WHERE \(clause);")
        let count = Int(sqlite3_changes(db))
        invalidateStats()
        return count
    }

    /// Called when the user turns iCloud downloads on: assets that were skipped
    /// because their pixels were remote become eligible again.
    @discardableResult
    func requeueUnavailable() throws -> Int {
        try execute("UPDATE assets SET analysis_state = 'pending', attempts = 0 WHERE analysis_state = 'unavailable';")
        let count = Int(sqlite3_changes(db))
        invalidateStats()
        return count
    }

    func remove(identifiers: [String]) throws {
        guard !identifiers.isEmpty else { return }
        // One transaction: a crash must not delete half a deletion cohort and
        // leave the other half to be re-discovered by the next scan.
        try execute("BEGIN IMMEDIATE;")
        do {
            for chunk in identifiers.chunked(into: 400) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try withStatement("DELETE FROM assets WHERE asset_identifier IN (\(placeholders));") { statement in
                    for (offset, identifier) in chunk.enumerated() {
                        bind(statement, Int32(offset + 1), identifier)
                    }
                    try run(statement)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        invalidateStats()
    }

    // MARK: - Vision signals

    /// Signal names in `asset_signals`.
    ///
    /// A closed set rather than free text, so a typo cannot write a signal nothing
    /// ever reads back — and so `featurePrints()` can be sure of what it is
    /// selecting.
    enum Signal: String, Sendable {
        /// Apple's FeaturePrint, zlib-compressed JSON. See `recordFeaturePrint`.
        case featurePrint = "featureprint"
        /// Per-face capture quality, zlib-compressed JSON.
        case faceCaptureQuality = "face_capture_quality"
    }

    /// Stores one FeaturePrint for an asset.
    ///
    /// ## Why the payload is compressed JSON
    ///
    /// A FeaturePrint is 768 floats: 3,072 B raw, 4,351 B as JSON. Measured on
    /// this library, JSON at 4.3 KB × 53k assets is 231 MB of cache — against a
    /// cache that is otherwise 15 MB — so it is zlib'd, which brings it to
    /// ~2.5 KB each, about 149 MB.
    ///
    /// JSON is used rather than the raw bytes because **there is no public way to
    /// rebuild a `FeaturePrintObservation` from its raw payload**: the only
    /// initialiser takes another observation, and the `Codable` conformance is the
    /// only route in. That round trip was verified bit-exact — worst distance
    /// error `0.0` across 400 pairs — so nothing is lost by taking it. The same
    /// applies to a face result; both encodings live in `SignalCompression`.
    func recordFeaturePrint(_ payload: Data, for identifier: String) throws {
        try recordSignal(.featurePrint, payload: payload, for: identifier)
    }

    /// Takes up to `limit` assets awaiting a FeaturePrint backfill.
    ///
    /// A separate queue from `claimJobs` because these assets are already `done`:
    /// their aesthetics score is good and must not be disturbed, so they cannot go
    /// through the state machine that clears scores on requeue.
    ///
    /// Claims come out in the order the queue was filled — insertion order, which is
    /// the order `refreshFeaturePrintQueue` scanned the asset table in, and so the
    /// order of the walk that discovered them. Deliberately not "newest first":
    /// arranging that would need a join against `assets`, and the queue is a set of
    /// outstanding work rather than a ranking. The one property it does need is that
    /// a claim is *removed* when it is taken, so two runs can never both spend
    /// effort on one asset.
    func claimFeaturePrints(limit: Int) throws -> [String] {
        var identifiers: [String] = []
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement("""
            SELECT asset_identifier FROM featureprint_queue
            ORDER BY rowid ASC LIMIT ?;
            """) { statement in
                sqlite3_bind_int(statement, 1, Int32(limit))
                while sqlite3_step(statement) == SQLITE_ROW {
                    identifiers.append(text(statement, 0))
                }
            }
            if !identifiers.isEmpty {
                try withStatement("DELETE FROM featureprint_queue WHERE asset_identifier = ?;") { statement in
                    for identifier in identifiers {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        bind(statement, 1, identifier)
                        try run(statement)
                    }
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return identifiers
    }

    /// Puts claimed FeaturePrint jobs back, for a run that was cancelled.
    func releaseFeaturePrints(identifiers: [String]) throws {
        guard !identifiers.isEmpty else { return }
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement("""
            INSERT OR IGNORE INTO featureprint_queue (asset_identifier) VALUES (?);
            """) { statement in
                for identifier in identifiers {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(statement, 1, identifier)
                    try run(statement)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// How many assets are still awaiting a FeaturePrint.
    func featurePrintBacklog() throws -> Int {
        try withStatement("SELECT COUNT(*) FROM featureprint_queue;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// Stores one face-capture result for an asset.
    func recordFaceCaptureQuality(_ payload: Data, for identifier: String) throws {
        try recordSignal(.faceCaptureQuality, payload: payload, for: identifier)
    }

    private func recordSignal(_ signal: Signal, payload: Data, for identifier: String) throws {
        guard let compressed = SignalCompression.compress(payload) else { return }
        try withStatement("""
        INSERT INTO asset_signals (asset_identifier, signal, value, payload, analyzer_version, computed_at)
        VALUES (?, ?, NULL, ?, ?, ?)
        ON CONFLICT(asset_identifier, signal) DO UPDATE SET
            payload          = excluded.payload,
            analyzer_version = excluded.analyzer_version,
            computed_at      = excluded.computed_at;
        """) { statement in
            bind(statement, 1, identifier)
            bind(statement, 2, signal.rawValue)
            SignalCompression.bind(statement, 3, compressed)
            sqlite3_bind_int(statement, 4, Int32(Self.analyzerVersion))
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            try run(statement)
        }
    }

    /// Cached FeaturePrints for every asset that has one, with its capture date.
    ///
    /// Returns *decoded* observations: the builder compares distances, and
    /// `distance(to:)` needs real observations, not bytes. Only assets with a
    /// FeaturePrint are returned, so the caller filters nothing.
    func featurePrints() throws -> [GroupingCandidate] {
        var candidates: [GroupingCandidate] = []
        try withStatement("""
        SELECT a.asset_identifier, a.creation_date, s.payload
        FROM assets a
        JOIN asset_signals s
          ON s.asset_identifier = a.asset_identifier AND s.signal = ?
        WHERE a.creation_date IS NOT NULL;
        """) { statement in
            bind(statement, 1, Signal.featurePrint.rawValue)
            while sqlite3_step(statement) == SQLITE_ROW {
                let identifier = text(statement, 0)
                let date = sqlite3_column_type(statement, 1) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 1)
                guard let bytes = SignalCompression.read(statement, 2),
                      let observation = SignalCompression.featurePrint(from: bytes) else { continue }
                candidates.append(GroupingCandidate(identifier: identifier, date: date,
                                                    featurePrint: observation))
            }
        }
        return candidates
    }

    /// Cached per-face capture quality, keyed by asset identifier.
    ///
    /// Assets with no stored result are **absent** rather than present-with-no-faces,
    /// which is what lets `SimilarGroupBuilder` tell "analysed, no faces here" from
    /// "not analysed yet".
    func faceCaptureQualities(for identifiers: [String]) throws -> [String: [FaceCapture]] {
        var qualities: [String: [FaceCapture]] = [:]
        for chunk in identifiers.chunked(into: 400) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try withStatement("""
            SELECT asset_identifier, payload FROM asset_signals
            WHERE signal = ? AND asset_identifier IN (\(placeholders));
            """) { statement in
                bind(statement, 1, Signal.faceCaptureQuality.rawValue)
                for (offset, identifier) in chunk.enumerated() {
                    bind(statement, Int32(offset + 2), identifier)
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let bytes = SignalCompression.read(statement, 1),
                          let result = SignalCompression.faceCaptureResult(from: bytes) else { continue }
                    qualities[text(statement, 0)] = result.faces
                }
            }
        }
        return qualities
    }

    /// How many assets hold a FeaturePrint, and how many a face result.
    ///
    /// Two counts rather than a fraction: the first says how much of the library
    /// grouping can see, the second how far the Best Shot ranking has got.
    func signalCounts() throws -> (featurePrints: Int, faceCaptureQualities: Int) {
        var result = (featurePrints: 0, faceCaptureQualities: 0)
        try withStatement("""
        SELECT signal, COUNT(*) FROM asset_signals WHERE signal IN (?, ?) GROUP BY signal;
        """) { statement in
            bind(statement, 1, Signal.featurePrint.rawValue)
            bind(statement, 2, Signal.faceCaptureQuality.rawValue)
            while sqlite3_step(statement) == SQLITE_ROW {
                let count = Int(sqlite3_column_int(statement, 1))
                if text(statement, 0) == Signal.featurePrint.rawValue {
                    result.featurePrints = count
                } else {
                    result.faceCaptureQualities = count
                }
            }
        }
        return result
    }

    // MARK: - Similar groups

    /// Replaces every stored group in one transaction.
    ///
    /// Wholesale replacement, not a merge, for the same reason album membership is:
    /// a rebuild under different settings must *replace* the previous answer, or a
    /// group that no longer qualifies keeps matching as if it did. One transaction,
    /// so a rebuild interrupted by a crash cannot leave the table holding half of
    /// one pass and half of another — a state in which a photo could appear in two
    /// groups or none.
    func replaceGroups(_ groups: [SimilarGroup],
                       settings: SimilarGroupSettings,
                       faceMemberCounts: [String: Int],
                       earliestDates: [String: Double?]) throws {
        let config = settings.validated()
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement("DELETE FROM similar_group_members;") { statement in try run(statement) }
            try withStatement("DELETE FROM similar_groups;") { statement in try run(statement) }

            try withStatement("""
            INSERT INTO similar_groups (
                group_id, member_count, face_member_count, earliest_date,
                window_seconds, max_distance, face_weight, minimum_face_area,
                maximum_group_size, ranked_at, built_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?);
            """) { statement in
                let now = Date().timeIntervalSince1970
                for group in groups {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(statement, 1, group.id)
                    sqlite3_bind_int(statement, 2, Int32(group.members.count))
                    sqlite3_bind_int(statement, 3, Int32(faceMemberCounts[group.id] ?? 0))
                    if let date = earliestDates[group.id] ?? nil {
                        sqlite3_bind_double(statement, 4, date)
                    } else {
                        sqlite3_bind_null(statement, 4)
                    }
                    sqlite3_bind_double(statement, 5, config.windowSeconds)
                    sqlite3_bind_double(statement, 6, Double(config.maxDistance))
                    // The rest of the settings, so a stored row is a complete
                    // statement of the rules it was built under — see
                    // `newestGroupPass`, which is what reads them back.
                    sqlite3_bind_double(statement, 7, Double(config.faceWeight))
                    sqlite3_bind_double(statement, 8, Double(config.minimumFaceAreaFraction))
                    sqlite3_bind_int(statement, 9, Int32(config.maximumGroupSize))
                    sqlite3_bind_double(statement, 10, now)
                    try run(statement)
                }
            }

            try withStatement("""
            INSERT OR IGNORE INTO similar_group_members (group_id, asset_identifier) VALUES (?, ?);
            """) { statement in
                for group in groups {
                    for member in group.members {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        bind(statement, 1, group.id)
                        bind(statement, 2, member)
                        try run(statement)
                    }
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        invalidateStats()
    }

    /// Marks a group's ranking as complete once every member has a face result.
    func markGroupRanked(id: String) throws {
        try withStatement("UPDATE similar_groups SET ranked_at = ? WHERE group_id = ?;") { statement in
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            bind(statement, 2, id)
            try run(statement)
        }
    }

    /// One group as stored, for the group browser.
    struct GroupSummary: Sendable {
        let id: String
        let memberCount: Int
        let faceMemberCount: Int
        let earliestDate: Double?
        /// `nil` until every member has been through face capture analysis. The
        /// browser reports that as `incomplete`, so a portrait group whose ranking
        /// may still move is not presented as settled.
        let rankedAt: Double?
    }

    /// The pass the stored groups came from: when it ran, and the settings it ran
    /// under. `nil` when no group is stored, or when the stored rows predate the
    /// columns that record the settings (schema version 4) — "not recorded" is not
    /// "recorded as current", and the caller must be able to tell the difference.
    ///
    /// One row is enough: `replaceGroups` writes every group in a single
    /// transaction from one `SimilarGroupSettings`, so they all carry the same
    /// values. The newest row is read, so a pass that found nothing does not
    /// masquerade as a library that has never been grouped.
    ///
    /// This is what makes "built with different rules" survive a restart. The
    /// engine's own record of what it built is process state; a settings change
    /// followed by a quit would otherwise leave groups built under rules the user
    /// has moved on from being reported — and served — as current.
    func newestGroupPass() throws -> (builtAt: Date, settings: SimilarGroupSettings)? {
        try withStatement("""
        SELECT built_at, window_seconds, max_distance, face_weight,
               minimum_face_area, maximum_group_size
        FROM similar_groups
        ORDER BY built_at DESC LIMIT 1;
        """) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let window = sqlite3_column_double(statement, 1)
            let distance = Float(sqlite3_column_double(statement, 2))
            guard sqlite3_column_type(statement, 3) != SQLITE_NULL,
                  sqlite3_column_type(statement, 4) != SQLITE_NULL,
                  sqlite3_column_type(statement, 5) != SQLITE_NULL else { return nil }
            return (
                Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                SimilarGroupSettings(
                    windowSeconds: window,
                    maxDistance: distance,
                    faceWeight: Float(sqlite3_column_double(statement, 3)),
                    minimumFaceAreaFraction: Float(sqlite3_column_double(statement, 4)),
                    maximumGroupSize: Int(sqlite3_column_int(statement, 5))
                ).validated()
            )
        }
    }

    /// A page of groups, largest first, optionally restricted to one album and one
    /// media type.
    ///
    /// The album dimension filters on a group's **members**, and a group qualifies
    /// as soon as *one* member is in the album rather than only when all of them
    /// are. A burst is one cleanup decision; a group that straddles two albums is
    /// still the same burst, and requiring every member to be in the album would
    /// hide exactly the groups that straddle the albums a user is most likely to be
    /// comparing. The predicate is an `EXISTS` over the members primary key, so
    /// the cost is one index probe per group, not per photo.
    ///
    /// The media dimension filters the same way, on the same "one member is enough"
    /// rule, and for the same reason — but note what it actually means in practice:
    /// **videos are never group members** (§ the FeaturePrint exclusion in
    /// `refreshFeaturePrintQueue`), so `media = .videos` yields an empty list and
    /// `media = .images` yields the unfiltered list. That is the truthful answer, and
    /// it is produced by the filter rather than short-circuited in the router, so the
    /// day a video *can* join a group this route needs no change.
    ///
    /// The order is the group's own size, unchanged by either filter:
    /// `member_count` is a property of the group, and re-ranking the list by "how
    /// many photos of this group happen to be in this album" would make one album's
    /// list a different sort from another's for no reason the user asked for.
    func groupSummaries(limit: Int, offset: Int, album: AlbumSelection = .all,
                        media: MediaSelection = .all) throws -> (total: Int, groups: [GroupSummary]) {
        let clause = Self.groupMemberClause(album: album, media: media,
                                            asset: "m.asset_identifier", albumParameter: "?1")
        let filtered = !clause.isEmpty
        // Named `qualifier` rather than `where`: the latter is a keyword, and the
        // multiline literal it would be interpolated into reads as a clause
        // declaration rather than a value.
        //
        // `assets` is joined into the `EXISTS` rather than left out. `MediaSelection`'s
        // predicate is the bare literal `media_type = 1` (it has to be unqualified
        // and unparameterised — see `PhotoFilter.whereSQLClause`), and
        // `similar_group_members` has no such column, so without this join SQLite
        // would fail to prepare the statement and the *album* filter would break
        // along with the media one. The join is on the members primary key, so it
        // costs the same one index probe the correlated subquery already paid.
        let qualifier = filtered
            ? """
            WHERE EXISTS (SELECT 1 FROM similar_group_members m \
            JOIN assets ma ON ma.asset_identifier = m.asset_identifier \
            WHERE m.group_id = g.group_id AND \(clause))
            """
            : ""
        // One placeholder is skipped when there is no filter rather than bound to
        // nothing, so the unfiltered statement is byte-for-byte the one it always
        // was and `EXPLAIN QUERY PLAN` keeps using the size index on its own.
        let limitParameter = filtered ? "?2" : "?1"
        let offsetParameter = filtered ? "?3" : "?2"
        let identifier = album.albumIdentifier
        func bindAlbum(_ statement: OpaquePointer) {
            guard filtered, let identifier else { return }
            bind(statement, 1, identifier)
        }

        var summaries: [GroupSummary] = []
        var total = 0
        try withStatement("SELECT COUNT(*) FROM similar_groups g \(qualifier);") { statement in
            bindAlbum(statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return }
            total = Int(sqlite3_column_int64(statement, 0))
        }
        try withStatement("""
        SELECT g.group_id, g.member_count, g.face_member_count, g.earliest_date, g.ranked_at
        FROM similar_groups g
        \(qualifier)
        ORDER BY g.member_count DESC, g.group_id ASC
        LIMIT \(limitParameter) OFFSET \(offsetParameter);
        """) { statement in
            bindAlbum(statement)
            sqlite3_bind_int(statement, filtered ? 2 : 1, Int32(limit))
            sqlite3_bind_int(statement, filtered ? 3 : 2, Int32(offset))
            while sqlite3_step(statement) == SQLITE_ROW {
                summaries.append(GroupSummary(
                    id: text(statement, 0),
                    memberCount: Int(sqlite3_column_int(statement, 1)),
                    faceMemberCount: Int(sqlite3_column_int(statement, 2)),
                    earliestDate: sqlite3_column_type(statement, 3) == SQLITE_NULL
                        ? nil : sqlite3_column_double(statement, 3),
                    rankedAt: sqlite3_column_type(statement, 4) == SQLITE_NULL
                        ? nil : sqlite3_column_double(statement, 4)))
            }
        }
        return (total, summaries)
    }

    /// A group's members the album selection keeps, as identifiers — every one of
    /// them, not a page.
    ///
    /// Used only under a filter, and specifically so the reported counts are counts
    /// of the *group* rather than of whatever page was fetched: a `LIMIT` applied
    /// before the count would turn "12 photos" into "the first 12 photos". The read
    /// is an index probe per member on the members primary key.
    func groupMembers(groupID: String, album: AlbumSelection = .all,
                      media: MediaSelection = .all) throws -> [String] {
        let clause = Self.groupMemberClause(album: album, media: media,
                                            asset: "m.asset_identifier", albumParameter: "?2")
        let extra = clause.isEmpty ? "" : "AND \(clause)"
        var identifiers: [String] = []
        // `assets` joined for the same reason as in `groupSummaries`: the media
        // predicate is an unqualified literal and the members table has no
        // `media_type`. Primary-key join, so one probe per member.
        try withStatement("""
        SELECT m.asset_identifier FROM similar_group_members m
        JOIN assets ma ON ma.asset_identifier = m.asset_identifier
        WHERE m.group_id = ?1\(extra)
        ORDER BY m.asset_identifier ASC;
        """) { statement in
            bind(statement, 1, groupID)
            if let identifier = album.albumIdentifier { bind(statement, 2, identifier) }
            while sqlite3_step(statement) == SQLITE_ROW {
                identifiers.append(text(statement, 0))
            }
        }
        return identifiers
    }

    /// One group's stored row, or nil for an identifier this instance never built.
    func groupSummary(id: String) throws -> GroupSummary? {
        try withStatement("""
        SELECT group_id, member_count, face_member_count, earliest_date, ranked_at
        FROM similar_groups WHERE group_id = ?;
        """) { statement in
            bind(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return GroupSummary(
                id: text(statement, 0),
                memberCount: Int(sqlite3_column_int(statement, 1)),
                faceMemberCount: Int(sqlite3_column_int(statement, 2)),
                earliestDate: sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 3),
                rankedAt: sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil : sqlite3_column_double(statement, 4))
        }
    }

    /// A group's members as ranking inputs, with whatever signals are cached.
    ///
    /// The single place a group's members are read, so the ranking, the face
    /// summary and the browser's tiles cannot disagree about who is in a group.
    ///
    /// The album selection is applied **before** the `LIMIT`, not after it: filtering
    /// a full page down to the album would starve a large group of members the
    /// filter keeps and report a page the group never contained.
    func rankingInputs(groupID: String, limit: Int, album: AlbumSelection = .all,
                       media: MediaSelection = .all) throws -> [RankingInput] {
        let clause = Self.groupMemberClause(album: album, media: media,
                                            asset: "a.asset_identifier", albumParameter: "?2")
        let extra = clause.isEmpty ? "" : "AND \(clause)"
        let limitParameter = clause.isEmpty ? "?2" : "?3"
        var inputs: [RankingInput] = []
        try withStatement("""
        SELECT a.asset_identifier, a.aesthetics_score, a.creation_date, a.favorite
        FROM similar_group_members m
        JOIN assets a ON a.asset_identifier = m.asset_identifier
        WHERE m.group_id = ?1 \(extra)
          AND a.aesthetics_score IS NOT NULL
        ORDER BY a.asset_identifier ASC
        LIMIT \(limitParameter);
        """) { statement in
            bind(statement, 1, groupID)
            if let identifier = album.albumIdentifier { bind(statement, 2, identifier) }
            sqlite3_bind_int(statement, clause.isEmpty ? 2 : 3, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                inputs.append(RankingInput(
                    identifier: text(statement, 0),
                    aesthetics: Float(sqlite3_column_double(statement, 1)),
                    faces: [],
                    date: sqlite3_column_type(statement, 2) == SQLITE_NULL
                        ? nil : sqlite3_column_double(statement, 2),
                    favorite: sqlite3_column_int(statement, 3) != 0))
            }
        }
        let faces = try faceCaptureQualities(for: inputs.map(\.identifier))
        return inputs.map { input in
            RankingInput(identifier: input.identifier, aesthetics: input.aesthetics,
                         faces: faces[input.identifier] ?? [], date: input.date,
                         favorite: input.favorite)
        }
    }

    /// The stored group this asset belongs to, or nil when it is in none.
    ///
    /// Group **membership**, not similarity: this reads `similar_group_members`,
    /// which the last completed pass wrote, so the whole lookup is one indexed
    /// read of one table. No FeaturePrint is decoded, no pair is compared and no
    /// image is touched — the expensive part of grouping already happened, and
    /// this is where a request asks for the answer rather than computing it.
    ///
    /// Reads membership rather than scanning the group *list* on purpose. A list
    /// is a presentation with rules of its own — it may omit groups that hold
    /// nothing worth cleaning up — while "which group is this photo in" is a
    /// property of the photo. Answering it from the list would make a group
    /// unreachable from its own members the moment the list's rules changed, so
    /// the two concerns stay apart here.
    ///
    /// `ORDER BY … LIMIT 1` because an asset is only ever in one group, but a
    /// membership row can briefly outlive its group (see `pruneOrphanGroupMembers`).
    /// Ordering makes the answer deterministic when that happens instead of
    /// letting SQLite pick.
    func groupID(containingAsset identifier: String) throws -> String? {
        try withStatement("""
        SELECT group_id FROM similar_group_members
        WHERE asset_identifier = ?
        ORDER BY group_id ASC LIMIT 1;
        """) { statement in
            bind(statement, 1, identifier)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return text(statement, 0)
        }
    }

    /// Whether FeaturePrint analysis has reached this asset.
    ///
    /// This is what separates "this photo has no similar photos" from "similarity
    /// analysis is not available for this photo yet". Both are answered by an
    /// absent group, and without this the UI would claim a photo is unique when
    /// the truth is that nothing has compared it to anything yet.
    ///
    /// A photo with no FeaturePrint cannot be a group member — grouping skips
    /// candidates without one — so this is also the cheapest honest answer to
    /// "could this photo ever be in a group".
    func hasFeaturePrint(for identifier: String) throws -> Bool {
        try withStatement("""
        SELECT 1 FROM asset_signals WHERE asset_identifier = ? AND signal = ? LIMIT 1;
        """) { statement in
            bind(statement, 1, identifier)
            bind(statement, 2, Signal.featurePrint.rawValue)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    /// Members of the stored groups that have no face result yet, oldest capture
    /// first.
    ///
    /// This is the Tier 3 queue. It is deliberately **not** the whole library: only
    /// photos that grouping has already placed in a group of two or more are
    /// eligible, so face capture quality is computed for the small fraction of a
    /// library that can actually use it.
    ///
    /// Capture time is the order, with the identifier as the tie-break, so two runs
    /// cannot hand out the same work in a different order. What matters is that the
    /// order is a property of the photos rather than of which group happened to sort
    /// first: a bounded queue whose order shifts between passes lets a long tail of
    /// members be looked at last over and over, while the groups containing them
    /// report themselves as still settling.
    func groupMembersNeedingFaces(limit: Int) throws -> [String] {
        var identifiers: [String] = []
        try withStatement("""
        SELECT m.asset_identifier
        FROM similar_group_members m
        LEFT JOIN asset_signals s
          ON s.asset_identifier = m.asset_identifier AND s.signal = ?
        LEFT JOIN assets a
          ON a.asset_identifier = m.asset_identifier
        WHERE s.asset_identifier IS NULL
        GROUP BY m.asset_identifier
        ORDER BY MIN(COALESCE(a.creation_date, 0)) ASC, m.asset_identifier ASC
        LIMIT ?;
        """) { statement in
            bind(statement, 1, Signal.faceCaptureQuality.rawValue)
            sqlite3_bind_int(statement, 2, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                identifiers.append(text(statement, 0))
            }
        }
        return identifiers
    }

    /// Drops membership rows whose asset has left the library.
    ///
    /// Normally handled by the foreign key on `assets` — which `finishScan`'s delete
    /// cascades through — so on a correct database this is a no-op. It exists for
    /// the case where a rebuild reads members while the scan is deleting underneath
    /// it: a member that no longer exists must not keep a group alive with a phantom
    /// slot. Called once per scan, after the reconciliation that could have left
    /// such a row, and its count is logged when it is not zero.
    @discardableResult
    func pruneOrphanGroupMembers() throws -> Int {
        try execute("""
        DELETE FROM similar_group_members
        WHERE asset_identifier NOT IN (SELECT asset_identifier FROM assets);
        """)
        let removed = sqlite3_changes(db)
        if removed > 0 { invalidateStats() }
        return Int(removed)
    }

    // MARK: - Favourite flags

    /// Updates the cached `favorite` flag for a set of assets.
    ///
    /// Called only after PhotoKit has actually applied the change, and only with
    /// the value PhotoKit then reports, never with the value that was requested.
    /// That is what keeps the cache from claiming protection the library does not
    /// grant — the direction that matters, because `Router.resolveSelection`
    /// partitions the candidate set from this column.
    ///
    /// The reverse disagreement — the cache says favourite and Photos no longer
    /// does — is the safe direction for deletion (an over-protected photo is
    /// merely annoying) but is still corrected by the next scan, which upserts
    /// `favorite` from live `asset.isFavorite`. And the delete path re-reads
    /// `isFavorite` at the point of destruction, so neither direction can ever
    /// let a favourite through.
    func setFavorite(_ favorite: Bool, identifiers: [String]) throws -> Int {
        guard !identifiers.isEmpty else { return 0 }
        try execute("BEGIN IMMEDIATE;")
        var changed = 0
        do {
            for chunk in identifiers.chunked(into: 400) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try withStatement("""
                UPDATE assets SET favorite = ? WHERE asset_identifier IN (\(placeholders));
                """) { statement in
                    sqlite3_bind_int(statement, 1, favorite ? 1 : 0)
                    for (offset, identifier) in chunk.enumerated() {
                        bind(statement, Int32(offset + 2), identifier)
                    }
                    try run(statement)
                }
                changed += Int(sqlite3_changes(db))
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        invalidateStats()
        return changed
    }

    // MARK: - Albums

    /// One indexed user album, as served to the UI.
    struct AlbumSummary: Sendable {
        let identifier: String
        let title: String
        /// How many of *this instance's* assets are in it. Not Photos'
        /// `estimatedAssetCount`: that counts the whole library including assets
        /// this instance has never scanned, so it would disagree with the number
        /// of tiles an album filter actually yields.
        let assetCount: Int
        let indexedAt: Double?
    }

    /// Creates or refreshes an album row. Membership is written separately by
    /// `replaceAlbumMembership`, so an album row can exist with `indexed_at` set
    /// to nil to mean "known to exist, membership not yet read".
    func upsertAlbum(identifier: String, title: String, collectionType: Int) throws {
        try withStatement("""
        INSERT INTO albums (album_identifier, title, collection_type)
        VALUES (?, ?, ?)
        ON CONFLICT(album_identifier) DO UPDATE SET
            title           = excluded.title,
            collection_type = excluded.collection_type;
        """) { statement in
            bind(statement, 1, identifier)
            bind(statement, 2, String(title.prefix(200)))
            sqlite3_bind_int(statement, 3, Int32(collectionType))
            try run(statement)
        }
    }

    /// Replaces one album's membership wholesale.
    ///
    /// Delete-then-insert inside a single transaction, because Photos album
    /// membership is authoritative and re-reading it must *replace* what the
    /// cache believes rather than merge into it — otherwise a photo removed from
    /// an album in Photos would keep matching that album's filter here forever.
    /// The insert is filtered to identifiers this instance actually knows, so the
    /// table cannot grow rows for assets outside the cache.
    func replaceAlbumMembership(albumIdentifier: String, identifiers: [String]) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try withStatement("DELETE FROM asset_albums WHERE album_identifier = ?;") { statement in
                bind(statement, 1, albumIdentifier)
                try run(statement)
            }
            // Membership is intersected with what this instance has actually
            // scanned. The foreign key would refuse an unknown asset anyway, but
            // failing the whole chunk on one identifier is worse than skipping it:
            // a photo added in Photos between this instance's scan and the album
            // walk must not lose the rest of the album's membership.
            var scanned = Set<String>()
            for chunk in identifiers.chunked(into: 400) {
                scanned.formUnion(try known(identifiers: chunk))
            }
            let usable = identifiers.filter { scanned.contains($0) }
            for chunk in usable.chunked(into: 400) {
                let values = Array(repeating: "(?, ?)", count: chunk.count).joined(separator: ",")
                try withStatement("""
                INSERT OR IGNORE INTO asset_albums (asset_identifier, album_identifier)
                VALUES \(values);
                """) { statement in
                    var index: Int32 = 1
                    for identifier in chunk {
                        bind(statement, index, identifier)
                        index += 1
                        bind(statement, index, albumIdentifier)
                        index += 1
                    }
                    try run(statement)
                }
            }
            try withStatement("""
            UPDATE albums SET indexed_at = ? WHERE album_identifier = ?;
            """) { statement in
                sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
                bind(statement, 2, albumIdentifier)
                try run(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    /// Drops album rows and their membership that Photos no longer reports.
    ///
    /// The empty case is the one that looks like a special case and is not: Photos
    /// reporting *no* user albums is a fact about the library, and every stored row
    /// is then one Photos no longer reports. Refusing to prune it would leave a
    /// deleted album filterable for ever. It is also self-healing if the enumeration
    /// ever answers empty by accident — `AlbumIndexer.shouldRefresh` restarts a pass
    /// as soon as it has indexed nothing, and membership is only ever written from a
    /// fresh read of the album.
    @discardableResult
    func removeAlbums(notIn identifiers: [String]) throws -> Int {
        guard !identifiers.isEmpty else {
            try execute("DELETE FROM albums;")
            let removed = sqlite3_changes(db)
            return Int(removed)
        }
        try execute("BEGIN IMMEDIATE;")
        var removed = 0
        do {
            for chunk in identifiers.chunked(into: 400) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try withStatement("DELETE FROM albums WHERE album_identifier NOT IN (\(placeholders));") { statement in
                    for (offset, identifier) in chunk.enumerated() {
                        bind(statement, Int32(offset + 1), identifier)
                    }
                    try run(statement)
                }
                removed += Int(sqlite3_changes(db))
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        return removed
    }

    /// The albums worth offering as a filter, and how many of this instance's
    /// **scored** assets each one holds.
    ///
    /// Albums with no `indexed_at` are omitted: they are known to exist but not
    /// yet read, and showing them as "0 photos" would claim a fact the cache does
    /// not have.
    ///
    /// The count is score-bounded for the same reason the grid is: it is the
    /// number of tiles the filter will actually yield. A count taken over every
    /// scanned asset would disagree with the grid by whatever share is iCloud-only
    /// and therefore unscored, and a chip promising 11,747 that opens onto 11,638
    /// is worse than no count.
    func albums() throws -> [AlbumSummary] {
        var summaries: [AlbumSummary] = []
        try withStatement("""
        SELECT album_identifier, title, indexed_at,
               (SELECT COUNT(*) FROM asset_albums aa
                JOIN assets s ON s.asset_identifier = aa.asset_identifier
                WHERE aa.album_identifier = albums.album_identifier
                  AND s.aesthetics_score IS NOT NULL)
        FROM albums
        WHERE indexed_at IS NOT NULL
        ORDER BY title COLLATE NOCASE ASC, album_identifier ASC;
        """) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                summaries.append(AlbumSummary(
                    identifier: text(statement, 0),
                    title: text(statement, 1),
                    assetCount: Int(sqlite3_column_int(statement, 3)),
                    indexedAt: sqlite3_column_type(statement, 2) == SQLITE_NULL
                        ? nil : sqlite3_column_double(statement, 2)))
            }
        }
        return summaries
    }

    /// Album identifiers this instance has actually indexed. The album filter is
    /// validated against this before it reaches SQL, so a crafted identifier
    /// cannot reach the join table — the same discipline identifiers get against
    /// `known()`.
    func knownAlbums(_ identifiers: [String]) throws -> Set<String> {
        guard !identifiers.isEmpty else { return [] }
        var known: Set<String> = []
        for chunk in identifiers.chunked(into: 400) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try withStatement("SELECT album_identifier FROM albums WHERE album_identifier IN (\(placeholders));") { statement in
                for (offset, identifier) in chunk.enumerated() {
                    bind(statement, Int32(offset + 1), identifier)
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    known.insert(text(statement, 0))
                }
            }
        }
        return known
    }

    /// How many of this instance's **scored** assets are in no indexed album at all.
    ///
    /// This is the "no album" bucket's population, and it is score-bounded for the
    /// same reason `albums()` is: the bucket filter itself is score-bounded, so an
    /// unscored count would promise photos the grid cannot show.
    ///
    /// Computed as a complement rather than counted from the join table, because
    /// an asset with no membership row is exactly what the bucket means — and
    /// because assets whose albums have not been indexed yet would otherwise be
    /// counted here and then be wrong the moment indexing finished. The caller
    /// reports `albumIndexComplete` alongside it so the number is not read as a
    /// fact while it is still a lower bound.
    func unassignedCount() throws -> Int {
        try withStatement("""
        SELECT COUNT(*) FROM assets
        WHERE aesthetics_score IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM asset_albums aa WHERE aa.asset_identifier = assets.asset_identifier);
        """) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// True once every album Photos reports has been read at least once, so the
    /// "no album" count can be stated as a fact rather than a lower bound.
    ///
    /// A cache written before schema version 2 has no album rows at all, which
    /// would otherwise read as "complete, and the user has no albums" — so the
    /// schema version is checked first.
    func albumIndexComplete(photosAlbumCount: Int) throws -> Bool {
        guard try schemaUserVersion() >= 2 else { return false }
        var indexed = 0
        try withStatement("SELECT COALESCE(SUM(indexed_at IS NOT NULL), 0) FROM albums;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return }
            indexed = Int(sqlite3_column_int(statement, 0))
        }
        // Compared against what Photos currently reports rather than against this
        // table's own row count: Photos can add or remove an album between the
        // walk and the count, and comparing the table to itself would let a
        // deleted-but-not-yet-pruned album read as complete.
        return photosAlbumCount > 0 && indexed == photosAlbumCount
    }

    /// The albums each of these identifiers belongs to.
    ///
    /// Both the album's *identifier* and its title come back, because the UI needs
    /// the title to render a tag and the identifier to filter by — and matching one
    /// to the other by title would be ambiguous the moment a library has two albums
    /// with the same name.
    func albumMembership(for identifiers: [String]) throws -> [String: [AlbumSummary]] {
        var membership: [String: [AlbumSummary]] = [:]
        guard !identifiers.isEmpty else { return membership }
        for chunk in identifiers.chunked(into: 400) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try withStatement("""
            SELECT aa.asset_identifier, a.album_identifier, a.title, a.indexed_at
            FROM asset_albums aa JOIN albums a ON a.album_identifier = aa.album_identifier
            WHERE aa.asset_identifier IN (\(placeholders))
            ORDER BY a.title COLLATE NOCASE ASC, a.album_identifier ASC;
            """) { statement in
                for (offset, identifier) in chunk.enumerated() {
                    bind(statement, Int32(offset + 1), identifier)
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    membership[text(statement, 0), default: []].append(AlbumSummary(
                        identifier: text(statement, 1),
                        title: text(statement, 2),
                        // A per-asset count would be 1 for every one of them, so it
                        // is left out rather than misleading.
                        assetCount: 0,
                        indexedAt: sqlite3_column_type(statement, 3) == SQLITE_NULL
                            ? nil : sqlite3_column_double(statement, 3)))
                }
            }
        }
        return membership
    }

    // MARK: - Queries

    func stats(maxAge: TimeInterval = 0) throws -> CacheStats {
        if maxAge > 0, let cached = cachedStats, Date().timeIntervalSince(cachedStatsAt) < maxAge {
            return cached
        }
        var stats = CacheStats()
        // The video count is one more column in this statement rather than a second
        // query. `/api/status` polls this, it is cached for a second at a time and
        // read straight after a page in `Router.photos`, so a separate round trip
        // would be paid on every poll to learn a number that costs one `CASE` here —
        // and the table is already being scanned once, so the marginal cost is
        // nil.
        //
        // `media_type = 2` is a literal, matching `claimJobs`: no placeholder, so
        // the existing numbering (and therefore the callers' bind indices) is
        // untouched.
        try withStatement("""
        SELECT COUNT(*),
               COALESCE(SUM(CASE WHEN aesthetics_score IS NOT NULL THEN 1 ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN analysis_state = 'failed' THEN 1 ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN analysis_state = 'unavailable' THEN 1 ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN analysis_state IN ('pending', 'analyzing') THEN 1 ELSE 0 END), 0),
               COALESCE(SUM(favorite), 0),
               COALESCE(SUM(CASE WHEN media_type = 2 THEN 1 ELSE 0 END), 0),
               MIN(aesthetics_score), MAX(aesthetics_score)
        FROM assets;
        """) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return }
            stats.total = Int(sqlite3_column_int64(statement, 0))
            stats.analyzed = Int(sqlite3_column_int64(statement, 1))
            stats.failed = Int(sqlite3_column_int64(statement, 2))
            stats.unavailable = Int(sqlite3_column_int64(statement, 3))
            stats.pending = Int(sqlite3_column_int64(statement, 4))
            stats.favorites = Int(sqlite3_column_int64(statement, 5))
            stats.videos = Int(sqlite3_column_int64(statement, 6))
            if sqlite3_column_type(statement, 7) != SQLITE_NULL {
                stats.minScore = Float(sqlite3_column_double(statement, 7))
            }
            if sqlite3_column_type(statement, 8) != SQLITE_NULL {
                stats.maxScore = Float(sqlite3_column_double(statement, 8))
            }
        }
        cachedStats = stats
        cachedStatsAt = Date()
        return stats
    }

    func photo(identifier: String) throws -> PhotoRow? {
        try withStatement("\(Self.rowSelect) WHERE asset_identifier = ?;") { statement in
            bind(statement, 1, identifier)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Self.decodeRow(statement)
        }
    }

    /// `photo(identifier:)`, but nil unless the asset has actually been scored.
    ///
    /// Needed because `PhotoRow.score` is a non-optional `Float`: an unscored row
    /// decodes with `score: 0`, which is indistinguishable from a genuine score of
    /// zero (and `0.0` is a real observation — the score range is data-derived and
    /// is not 0…1). A caller that needs to know whether the asset is *in the
    /// score-bounded ordering* must ask the database, not read the row.
    func scoredPhoto(identifier: String) throws -> PhotoRow? {
        try withStatement("""
        \(Self.rowSelect) WHERE asset_identifier = ? AND aesthetics_score IS NOT NULL;
        """) { statement in
            bind(statement, 1, identifier)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Self.decodeRow(statement)
        }
    }

    func page(filter: PhotoFilter, sort: SortOrder, cursor: PhotoCursor?, limit: Int, offset: Int) throws -> PhotoPage {
        // Refuse a cursor issued for another ordering instead of reading the wrong
        // half of it. `PhotoCursor` carries both a score and a date, so which one
        // the keyset predicate below is about to use is decided entirely by
        // `sort`: replaying a `score_asc` token against `date_desc` silently
        // yields a *correct* page of photos from an unrelated part of the grid,
        // which is the one failure mode worse than an error. Only a server-built
        // token (the All Photos anchor, which is never given to a client) may
        // arrive unbound.
        if let cursor, let issued = cursor.sort, issued != sort {
            throw CacheError.cursorSortMismatch(requested: sort.rawValue, cursor: issued.rawValue)
        }
        // The same binding discipline for the *filter*: a token names a position
        // inside one result set, and "the rows after this row within album A" is
        // a different set from the same question about album B. A token minted
        // before version 2 carries no fingerprint and is bound only to its sort,
        // which is exactly the guarantee version 1 gave.
        if let cursor, let issued = cursor.filterFingerprint,
           issued != filter.paginationFingerprint {
            throw CacheError.cursorFilterMismatch
        }
        var page = PhotoPage()
        let whereSQL = filter.whereSQLClause()

        // Clamped before anything arithmetic happens on it, because three separate
        // traps sit downstream of `limit` and each aborts the *process* rather than
        // throwing:
        //
        // 1. `limit + 1` overflows at `Int.max`.
        // 2. `Int32(fetchLimit)` traps for anything outside Int32 — and SQLite's
        //    `LIMIT` takes an int32, so an unbounded `Int` is unrepresentable here
        //    regardless.
        // 3. The lookahead trim below runs `removeLast()` whenever
        //    `rows.count > limit`, which is true for *any* negative limit because
        //    the query returns zero rows and `0 > -1`. `removeLast()` on an empty
        //    array is a trap.
        //
        // Every current caller already clamps to 1…200 via `queryInt`, so this never
        // changes an answer. It is here so the *next* caller cannot take the process
        // down with it, and so the ceiling is stated in one place rather than
        // assumed to hold at each of three call sites.
        let boundedLimit = min(max(limit, 0), Self.maxPageLimit)

        try withStatement("SELECT COUNT(*) FROM assets WHERE \(whereSQL);") { statement in
            bindFilter(statement, filter)
            if sqlite3_step(statement) == SQLITE_ROW {
                page.total = Int(sqlite3_column_int64(statement, 0))
            }
        }

        // Keyset pagination: every page is O(log n) regardless of how deep the
        // user has scrolled. `OFFSET` is retained only for an explicit jump back
        // to the start of the result set, where it is bounded by the page size.
        //
        // The keyset starts at `?4` rather than `?3` because the album predicate
        // may bind the album identifier as `?3`. The album identifier is bound
        // rather than interpolated so a crafted one can never reach the SQL text;
        // it has already been validated against the `albums` table, and binding it
        // makes that belt-and-braces.
        let keysetSQL = cursor.map { _ in Self.keysetClause(sort: sort, parameterIndex: 4) } ?? ""
        let limitIndex: Int32 = cursor == nil ? 4 : 7
        let offsetSQL = cursor == nil && offset > 0 ? " OFFSET \(max(0, offset))" : ""
        // Ask for one row more than the caller asked for. Without the extra row a
        // full page is indistinguishable from "the last page", so `nextCursor`
        // has to be emitted on every full page and the client is forced into one
        // final request that provably returns zero rows.
        let fetchLimit = boundedLimit >= Self.maxPageLimit ? boundedLimit : boundedLimit + 1
        let sql = """
        \(Self.rowSelect) WHERE \(whereSQL) \(keysetSQL)
        ORDER BY \(sort.orderByClause) LIMIT ?\(limitIndex)\(offsetSQL);
        """

        try withStatement(sql) { statement in
            bindFilter(statement, filter)
            if let cursor {
                switch sort {
                case .scoreAscending, .scoreDescending:
                    sqlite3_bind_double(statement, 4, Double(cursor.score))
                    sqlite3_bind_double(statement, 5, Double(cursor.score))
                case .newestFirst, .oldestFirst, .timelineNewer:
                    sqlite3_bind_double(statement, 4, cursor.date)
                    sqlite3_bind_double(statement, 5, cursor.date)
                }
                bind(statement, 6, cursor.id)
            }
            sqlite3_bind_int(statement, limitIndex, Int32(fetchLimit))
            while sqlite3_step(statement) == SQLITE_ROW {
                page.rows.append(Self.decodeRow(statement))
            }
        }
        if page.rows.count > boundedLimit {
            // The lookahead row proves another page exists. The cursor is the last
            // row actually returned, so the next page resumes exactly after it,
            // and it is stamped with the ordering *and* the filter that produced it.
            page.rows.removeLast()
            page.nextCursor = page.rows.last.map {
                PhotoCursor(row: $0, sort: sort, filterFingerprint: filter.paginationFingerprint).encoded()
            }
        }
        return page
    }

    /// Resolves a filter to concrete identifiers. Used for "all matching"
    /// selection and for deletion, where the authoritative set must be computed
    /// server-side at the moment of the action rather than trusted from the
    /// browser.
    func identifiers(matching filter: PhotoFilter, limit: Int = 200_000) throws -> [String] {
        var identifiers: [String] = []
        let whereSQL = filter.whereSQLClause()
        try withStatement("""
        SELECT asset_identifier FROM assets WHERE \(whereSQL)
        ORDER BY \(SortOrder.scoreAscending.orderByClause) LIMIT ?4;
        """) { statement in
            bindFilter(statement, filter)
            sqlite3_bind_int(statement, 4, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                identifiers.append(text(statement, 0))
            }
        }
        return identifiers
    }

    /// Binds every parameter `PhotoFilter.whereSQLClause()` can reference.
    ///
    /// Score bounds are always `?1`/`?2`; the album predicate takes `?3` only
    /// when an album is selected. Both the count query and the page query go
    /// through here, so the numbering cannot drift between them.
    ///
    /// There is deliberately nothing to bind for the favourite or media
    /// predicates: both are literals, which is what keeps `?4` free for keyset
    /// pagination. A caller adding a fourth bound filter would have to extend this
    /// and `keysetClause(parameterIndex:)` together.
    private func bindFilter(_ statement: OpaquePointer, _ filter: PhotoFilter) {
        sqlite3_bind_double(statement, 1, Double(filter.lower))
        sqlite3_bind_double(statement, 2, Double(filter.upper))
        if let identifier = filter.album.albumIdentifier {
            bind(statement, 3, identifier)
        }
    }

    /// Keeps only identifiers this instance actually knows about. Every path
    /// that accepts identifiers from the browser runs through here.
    func known(identifiers: [String]) throws -> [String] {
        guard !identifiers.isEmpty else { return [] }
        var known: [String] = []
        for chunk in identifiers.chunked(into: 400) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try withStatement("SELECT asset_identifier FROM assets WHERE asset_identifier IN (\(placeholders));") { statement in
                for (offset, identifier) in chunk.enumerated() {
                    bind(statement, Int32(offset + 1), identifier)
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    known.append(text(statement, 0))
                }
            }
        }
        return known
    }

    /// Splits a candidate set into favourites and everything else, so that
    /// favourite protection is enforced from stored state rather than from
    /// anything the browser claims.
    func partitionFavorites(identifiers: [String]) throws -> (favorites: [String], others: [String]) {
        guard !identifiers.isEmpty else { return ([], []) }
        var favorites: [String] = []
        var others: [String] = []
        for chunk in identifiers.chunked(into: 400) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try withStatement("SELECT asset_identifier, favorite FROM assets WHERE asset_identifier IN (\(placeholders));") { statement in
                for (offset, identifier) in chunk.enumerated() {
                    bind(statement, Int32(offset + 1), identifier)
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    if sqlite3_column_int(statement, 1) != 0 {
                        favorites.append(text(statement, 0))
                    } else {
                        others.append(text(statement, 0))
                    }
                }
            }
        }
        return (favorites, others)
    }

    nonisolated func databaseSizeBytes() -> Int64 {
        let fm = FileManager.default
        return ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let attributes = try? fm.attributesOfItem(atPath: path + suffix)
            return total + ((attributes?[.size] as? Int64) ?? 0)
        }
    }

    // MARK: - SQL fragments

    /// Columns every row-shaped read shares, in the order `decodeRow` reads them.
    ///
    /// `media_type` and `duration_seconds` are selected here so *every* row the
    /// grid serves — a page, `photo(identifier:)`, `scoredPhoto` — carries the
    /// media dimensions, rather than only some of them. The alternative was a
    /// separate lookup for the two new fields, which would make a video's tile and
    /// its lightbox disagree if they were read by different statements.
    ///
    /// There is deliberately no index on `media_type`. The filter that uses it is
    /// always combined with a score range, and `idx_assets_score` is a *partial*
    /// index over exactly the rows that range can return, so the media predicate is
    /// a per-row integer comparison on a set already narrowed to what the user is
    /// looking at. A second index on `media_type` would add write cost on every
    /// upsert of a 53k-row scan to accelerate a filter the client issues once.
    private static let rowSelect = """
    SELECT asset_identifier, aesthetics_score, creation_date, width, height, favorite,
           media_type, duration_seconds
    FROM assets
    """

    /// Ceiling on the rows one `page` call will return.
    ///
    /// SQLite's `LIMIT` is an int32, so the value bound into it must fit in one —
    /// `page` clamps to this rather than trusting the caller, because an `Int`
    /// outside that range is a trap at the bind, not an error. Set above the largest
    /// page the UI ever asks for (`Router.maxPageSize` is 200) so no real request is
    /// ever affected.
    private static let maxPageLimit = 1_000_000

    private static func decodeRow(_ statement: OpaquePointer) -> PhotoRow {
        let favorite = sqlite3_column_int(statement, 5) != 0
        // `media_type` is stored raw — `PHAssetMediaType` values, not a
        // translation — so this row and the column it came from cannot disagree
        // about what kind of asset this is. It is always emitted: a client that
        // read its absence as "image" would then render a clip as a still, which is
        // the one mistake the field exists to prevent.
        let mediaType = Int(sqlite3_column_int(statement, 6))
        // NULL stays nil all the way to the wire, where it is *omitted*. A
        // pre-version-5 row has no duration and a still has none either; neither is
        // a zero-length clip, so neither may be reported as `0`.
        let duration = sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, 7)
        return PhotoRow(
            id: String(cString: sqlite3_column_text(statement, 0)),
            score: Float(sqlite3_column_double(statement, 1)),
            date: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2),
            width: Int(sqlite3_column_int(statement, 3)),
            height: Int(sqlite3_column_int(statement, 4)),
            favorite: favorite,
            mediaType: mediaType,
            duration: duration
        )
    }

    /// Keyset predicate mirroring `SortOrder.orderByClause` — this *must* stay in
    /// lockstep with it.
    ///
    /// The two halves have to agree in three ways for pagination to be
    /// gap-free and duplicate-free:
    ///
    /// 1. **Direction.** The comparison operator flips with the sort direction
    ///    (`score ASC` → `>`, `score DESC` → `<`).
    /// 2. **Tie-break.** Every `ORDER BY` ends in `asset_identifier`, so the
    ///    ordering is a *total* order over a `TEXT PRIMARY KEY`. Keyset
    ///    pagination over a non-total order silently skips rows: without the
    ///    `asset_identifier` term, page N+1 restarts the whole tied group that
    ///    page N cut through. The tie-break's *direction* is part of the ordering
    ///    and must be read off `SortOrder.orderByClause`, not assumed: the four
    ///    grid orderings all break ties upwards, but `timelineNewer` is
    ///    `newestFirst` reversed and breaks them downwards, because it exists to
    ///    walk the timeline the other way. Copying a neighbouring case's `>` into
    ///    a `DESC` tie-break is exactly the bug that made the All Photos window
    ///    show one burst twice and lose half of it.
    /// 3. **Null handling.** `ORDER BY` uses `COALESCE(creation_date, 0)`, and so
    ///    must the predicate, or a dateless asset sorts one way and is filtered
    ///    another.
    ///
    /// The score key is a `REAL` written from a `Float` and round-tripped
    /// through `Float` in the cursor, so the `=` comparison is exact rather than
    /// approximate — which is what makes the tie-break term fire at all.
    /// The album and media predicates for a query over group **members**, joined.
    ///
    /// Both group filters answer the same question — "is at least one member of
    /// this group in the requested slice?" — and they are composed here rather than
    /// at each of the three call sites so a group list, a group's members and a
    /// group's ranking cannot disagree about what "in the album" means.
    ///
    /// The album predicate names the parameter (`?1` for the list, `?2` where the
    /// group id already occupies `?1`); the media predicate is the literal
    /// `MediaSelection` supplies, so composing it costs no placeholder and moves no
    /// numbering. `asset` is the SQL expression for the member's identifier in the
    /// calling statement — `m.asset_identifier` or `a.asset_identifier` — because
    /// the two statements alias it differently and a wrong guess here would be a
    /// predicate on a nonexistent column, which SQLite reports only at prepare time.
    private static func groupMemberClause(album: AlbumSelection, media: MediaSelection,
                                          asset: String, albumParameter: String) -> String {
        var conditions: [String] = []
        let albumClause = album.membershipClause(asset: asset, albumParameter: albumParameter)
        if !albumClause.isEmpty { conditions.append(albumClause) }
        let mediaClause = media.whereSQLClause()
        if !mediaClause.isEmpty { conditions.append(mediaClause) }
        return conditions.joined(separator: " AND ")
    }

    private static func keysetClause(sort: SortOrder, parameterIndex: Int) -> String {
        let n = parameterIndex
        switch sort {
        case .scoreAscending:
            return "AND (aesthetics_score > ?\(n) OR (aesthetics_score = ?\(n + 1) AND asset_identifier > ?\(n + 2)))"
        case .scoreDescending:
            return "AND (aesthetics_score < ?\(n) OR (aesthetics_score = ?\(n + 1) AND asset_identifier > ?\(n + 2)))"
        case .newestFirst:
            return "AND (COALESCE(creation_date, 0) < ?\(n) OR (COALESCE(creation_date, 0) = ?\(n + 1) AND asset_identifier > ?\(n + 2)))"
        case .oldestFirst:
            return "AND (COALESCE(creation_date, 0) > ?\(n) OR (COALESCE(creation_date, 0) = ?\(n + 1) AND asset_identifier > ?\(n + 2)))"
        case .timelineNewer:
            // `date ASC, id DESC`: strictly *after* the cursor in that total order.
            return "AND (COALESCE(creation_date, 0) > ?\(n) OR (COALESCE(creation_date, 0) = ?\(n + 1) AND asset_identifier < ?\(n + 2)))"
        }
    }
}

/// A `WHERE` fragment plus the values it needs bound, in order.
extension PhotoFilter {
    /// Builds the filter predicate. Score bounds are always parameter `?1` and
    /// `?2`; the favourite predicate uses a literal (0/1) so it cannot shift the
    /// numbering; the album predicate binds `?3` and keyset pagination therefore
    /// starts at `?4`. `CacheStore.bindFilter` is the only place that binds, so
    /// the two cannot drift apart.
    ///
    /// The album predicate comes from `AlbumSelection.membershipClause`, which is
    /// also what the group queries use — one definition of what each album value
    /// means, so the grid and the group browser cannot disagree about it.
    ///
    /// The media predicate is a **literal**, for the same reason the favourite one
    /// is and not for the same reason: `MediaSelection.whereSQLClause()` is a
    /// closed set of three values, so a bound parameter here would be a fourth
    /// placeholder — and `?1`/`?2` are the score bounds, `?3` is the album and
    /// keyset pagination starts at `?4`. A fourth placeholder would shift every one
    /// of them, and `page` binds its keyset positions by number. The alternative —
    /// appending the media value as `?4` — would mean renumbering the keyset clause
    /// and the limit index on every statement that builds a page, for a value with
    /// exactly three possible answers.
    func whereSQLClause() -> String {
        var conditions = ["aesthetics_score >= ?1", "aesthetics_score <= ?2"]
        switch favorites {
        case .include: break
        case .exclude: conditions.append("favorite = 0")
        case .only: conditions.append("favorite = 1")
        }
        let albumClause = album.membershipClause(asset: "assets.asset_identifier", albumParameter: "?3")
        if !albumClause.isEmpty { conditions.append(albumClause) }
        let mediaClause = media.whereSQLClause()
        if !mediaClause.isEmpty { conditions.append(mediaClause) }
        return conditions.joined(separator: " AND ")
    }
}

extension AlbumSelection {
    /// The `WHERE` fragment for this album selection, over the SQL expression
    /// `asset`, or `""` when the selection constrains nothing.
    ///
    /// `albumParameter` is the placeholder an album identifier is bound to, and is
    /// only read for `.album` — `.unassigned` needs no value, and `.all` needs
    /// neither. The fragment is a correlated subquery against the primary key of
    /// `asset_albums`, so it costs one index probe per candidate row and needs no
    /// join in the outer query:
    ///
    /// - `.album(id)` → the asset must have a membership row for that album.
    /// - `.unassigned` → the asset must have *no* membership row at all. Written as
    ///   `NOT EXISTS` rather than `LEFT JOIN … IS NULL` for exactly that reason.
    ///
    /// Both the score grid and the group queries build their album predicate here.
    /// The parameter is a placeholder the caller chooses, never user input: it
    /// appears in the statement as text and is bound by `withStatement`.
    func membershipClause(asset: String, albumParameter: String) -> String {
        switch self {
        case .all:
            return ""
        case .unassigned:
            return """
            NOT EXISTS (SELECT 1 FROM asset_albums aa \
            WHERE aa.asset_identifier = \(asset))
            """
        case .album:
            return """
            EXISTS (SELECT 1 FROM asset_albums aa \
            WHERE aa.asset_identifier = \(asset) AND aa.album_identifier = \(albumParameter))
            """
        }
    }
}
