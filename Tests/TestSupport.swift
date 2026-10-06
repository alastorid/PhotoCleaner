import Foundation
import os
import Photos
import SQLite3

// Test fixtures and helpers.
//
// Everything here runs against a throwaway SQLite file in a temporary directory.
// Nothing in this file reads or writes `Photos Library.photoslibrary`, the real
// cache at `~/Library/Application Support/PhotoCleaner/cache.sqlite`, a real
// `settings.json`, or the application log, and no test ever sends a selection to
// `PhotoLibrary.delete` that resolves to a non-empty set.

/// Direct SQLite access to a test database file, used only to *damage* a schema on
/// purpose so that one specific production query can be made to fail. Never used
/// against any real database.
enum RawSQL {
    static func exec(_ path: String, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw CacheError.open("could not open \(path) for the raw fixture")
        }
        defer { sqlite3_close_v2(handle) }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw CacheError.sql(sql, message)
        }
    }

    static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, Fixture.rawTransient)
    }

    static func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }
}

// MARK: - Fixture

/// A complete, isolated object graph: a temporary cache database, a temporary
/// `settings.json`, and a real `Router` wired to them — the same wiring
/// `PhotoCleanerApp` performs, so `Router.handle` is exercised as shipped.
final class Fixture: @unchecked Sendable {
    let root: URL
    let cachePath: String
    let cache: CacheStore
    let settings: Settings
    let bus: EventBus
    let images: ImageCache
    let engine: AnalysisEngine
    let router: Router

    /// The authorization the router gates on, or nil for the default.
    ///
    /// Set after construction for the cases that need the refusal; the closure the
    /// router holds reads it, so the change takes effect without rebuilding the
    /// graph. Production has no such seam — see `Router.authorizationStatus`.
    ///
    /// Held in a box rather than read through `self` because the router is being
    /// constructed from `self`'s own initialiser: capturing self there would be a
    /// use-before-initialisation, and the box sidesteps it without needing the
    /// whole graph to exist first.
    private let authorization: LockedBox<PHAuthorizationStatus?> = LockedBox(nil)

    /// Set or cleared after construction; nil means `.authorized`.
    var statusOverride: PHAuthorizationStatus? {
        get { authorization.value }
        set { authorization.value = newValue }
    }

    private init(label: String) throws {
        root = try Self.makeRoot(label: label)
        Self.createdRoots.append(root)
        cachePath = root.appendingPathComponent("cache.sqlite").path
        cache = try CacheStore(path: cachePath)
        settings = Settings(url: root.appendingPathComponent("settings.json"))
        bus = EventBus()
        images = ImageCache(totalCostLimit: 1 << 20, countLimit: 8)
        engine = AnalysisEngine(cache: cache, library: PhotoLibrary.shared, settings: settings, bus: bus)
        router = Router(cache: cache, engine: engine, library: PhotoLibrary.shared,
                        settings: settings, bus: bus, images: images,
                        // Authorized unless a case says otherwise. Every route that
                        // touches a photo refuses with 403 when access is absent, so
                        // a fixture that inherited the machine's real status would skip
                        // the whole suite on an un-granted machine, and 403 on CI. The
                        // refusal is still covered, by `registerAuthorizationTests`.
                        authorizationStatus: { [authorization] in authorization.value ?? .authorized })
    }

    /// The same object graph, pointed at an existing cache file.
    ///
    /// Needed by the migration cases: the point of an upgrade test is that the
    /// *current* code opens a database an *older* build left behind, which means the
    /// connection that ran `migrate()` the first time has to be gone. Reconstructing
    /// the graph against the same path is how that is arranged without a second
    /// process.
    static func reopen(_ existing: Fixture, label: String? = nil) async throws -> Fixture {
        let fixture = try Fixture(label: label ?? "reopened", reusingRoot: existing.root)
        try await fixture.cache.migrate()
        return fixture
    }

    private init(label: String, reusingRoot root: URL) throws {
        self.root = root
        cachePath = root.appendingPathComponent("cache.sqlite").path
        cache = try CacheStore(path: cachePath)
        settings = Settings(url: root.appendingPathComponent("settings.json"))
        bus = EventBus()
        images = ImageCache(totalCostLimit: 1 << 20, countLimit: 8)
        engine = AnalysisEngine(cache: cache, library: PhotoLibrary.shared, settings: settings, bus: bus)
        router = Router(cache: cache, engine: engine, library: PhotoLibrary.shared,
                        settings: settings, bus: bus, images: images,
                        authorizationStatus: { [authorization] in authorization.value ?? .authorized })
    }

    /// Rewinds the database to an older schema version, dropping the tables that
    /// version never had.
    ///
    /// Test-only, and deliberately crude: it reproduces what an older build left on
    /// disk — `assets` and `asset_signals` populated, the later tables absent, the
    /// version stamp behind — so `migrate()` can be pointed at real data rather than
    /// at a file it just created. The stamp matters as much as the tables: a
    /// migration that creates the tables but forgets to advance `user_version` looks
    /// successful on every other assertion.
    func rewindSchema(to version: Int, dropping tables: [String]) throws {
        for table in tables {
            try RawSQL.exec(cachePath, "DROP TABLE IF EXISTS \(table);")
        }
        try RawSQL.exec(cachePath, "PRAGMA user_version = \(version);")
    }

    /// The tables schema 2 and 3 added, i.e. everything a version 1 database lacks.
    static let postV1Tables = [
        "similar_group_members", "similar_groups", "featureprint_queue",
        "asset_albums", "albums",
    ]

    static func make(_ label: String = "fixture", protectFavorites: Bool = true) async throws -> Fixture {
        let fixture = try Fixture(label: label)
        try await fixture.cache.migrate()
        // `protectFavorites` defaults to true in production, so make it explicit
        // rather than relying on the absence of a settings file.
        fixture.settings.update { $0.protectFavorites = protectFavorites }
        return fixture
    }

    nonisolated(unsafe) private static var createdRoots: [URL] = []

    static func removeAll() {
        createdRoots.forEach { try? FileManager.default.removeItem(at: $0) }
        createdRoots = []
    }

    static func makeRoot(label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photocleaner-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let rawTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: Seeding

    struct Seed {
        var id: String
        var score: Float?
        var date: Double?
        var favorite = false
        var state: AnalysisState = .done
        var width = 4032
        var height = 3024
    }

    /// Inserts rows through the production write path (`upsert`, then `record` /
    /// `recordFailure` / `recordUnavailable`), so the fixture cannot create a
    /// state the application itself could not produce.
    func seed(_ assets: [Seed]) async throws {
        let records = assets.map {
            ScanRecord(identifier: $0.id, mediaType: 1, creationDate: $0.date,
                       modificationDate: $0.date, width: $0.width, height: $0.height,
                       favorite: $0.favorite, mediaSubtype: 0, isScreenshot: false)
        }
        try await cache.upsert(batch: records, marker: 1)
        for asset in assets {
            switch asset.state {
            case .done:
                guard let score = asset.score else { continue }
                try await cache.record(score: score, for: asset.id)
            case .failed:
                // Two attempts: the first returns the row to `pending` (the single
                // automatic retry), the second parks it in `failed`.
                try await cache.recordFailure(for: asset.id, error: "seeded failure")
                try await cache.recordFailure(for: asset.id, error: "seeded failure")
            case .unavailable:
                try await cache.recordUnavailable(for: asset.id, reason: "seeded iCloud-only")
            case .pending, .analyzing:
                continue
            }
        }
    }

    /// The "widest filter the cache can express" — the same one the timeline routes
    /// build for themselves out of the observed score extremes.
    func allRowsFilter() async throws -> PhotoFilter {
        let stats = try await cache.stats(maxAge: 0)
        return PhotoFilter(lower: stats.minScore ?? 0, upper: stats.maxScore ?? 0)
    }

    // MARK: Inspection

    func analysisState(of identifier: String) async throws -> AnalysisState? {
        try query("SELECT analysis_state FROM assets WHERE asset_identifier = ?;") { statement in
            RawSQL.bind(statement, 1, identifier)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return RawSQL.string(statement, 0).flatMap { AnalysisState(rawValue: $0) }
        }
    }

    func attempts(of identifier: String) async throws -> Int? {
        try query("SELECT attempts FROM assets WHERE asset_identifier = ?;") { statement in
            RawSQL.bind(statement, 1, identifier)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    func lastError(of identifier: String) async throws -> String? {
        try query("SELECT last_error FROM assets WHERE asset_identifier = ?;") { statement in
            RawSQL.bind(statement, 1, identifier)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return RawSQL.string(statement, 0)
        }
    }

    func scoredAt(of identifier: String) async throws -> Double? {
        try query("SELECT scored_at FROM assets WHERE asset_identifier = ?;") { statement in
            RawSQL.bind(statement, 1, identifier)
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else {
                return nil
            }
            return sqlite3_column_double(statement, 0)
        }
    }

    func stateCounts() async throws -> [AnalysisState: Int] {
        try query("SELECT analysis_state, COUNT(*) FROM assets GROUP BY analysis_state;") { statement in
            var counts: [AnalysisState: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                if let raw = RawSQL.string(statement, 0), let state = AnalysisState(rawValue: raw) {
                    counts[state, default: 0] += Int(sqlite3_column_int(statement, 1))
                }
            }
            return counts
        }
    }

    /// Runs a read-only query against the *temporary* test database.
    ///
    /// Opened read/write on purpose: the cache runs in WAL mode, and a read-only
    /// handle cannot recover the write-ahead log, so it would see an empty database
    /// and every inspection below would silently answer "no such row". Only
    /// `SELECT`s ever run over this handle.
    func query<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(cachePath, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw CacheError.open("could not open the test cache for inspection")
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CacheError.sql(sql, "could not prepare the fixture query")
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }
}

/// A single value behind a lock, for the fixture's mutable authorization.
///
/// `OSAllocatedUnfairLock` rather than an `actor` because the router's closure is
/// synchronous and `@Sendable`, and it is called from request-handling tasks. Note
/// the trap this type exists to avoid: `withLock` hands the closure an `inout`, so
/// the body must assign to *that*, not to a captured copy.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }

    var value: Value {
        get { lock.withLock { $0 } }
        // Assign to the `inout` the closure is handed, not to a copy of it.
        set { lock.withLock { $0 = newValue } }
    }
}

// MARK: - Requests

enum Req {
    /// Mirrors what `HTTPConnection.makeRequest` produces for a `GET`. The parser
    /// itself is covered end to end by `HTTPServerTests`; this is the short way to
    /// reach the router without a socket.
    static func get(_ path: String, query: [String: String] = [:],
                    headers: [String: String] = [:]) -> HTTPRequest {
        // Split a query string off `path` the way `HTTPConnection.makeRequest` does,
        // so a caller can write the URL it would actually type. Passing
        // `"/api/group?id=g"` with the query left in `rawPath` used to reach the
        // router as one segment and 404 — which reads like a missing route rather
        // than a malformed request, so it is worth handling here rather than in
        // every case that needs a query.
        var pathOnly = path
        var parsed = query
        if let mark = path.firstIndex(of: "?") {
            pathOnly = String(path[path.startIndex..<mark])
            for pair in path[path.index(after: mark)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1,
                                       omittingEmptySubsequences: false)
                let name = String(parts.first ?? "")
                let value = parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : ""
                if !name.isEmpty { parsed[name] = value }
            }
        }
        return HTTPRequest(method: "GET", rawPath: pathOnly,
                           segments: pathOnly.split(separator: "/", omittingEmptySubsequences: true)
                               .map { String($0).percentDecodedPathSegment },
                           query: parsed, headers: headers, body: Data())
    }

    static func post(_ path: String, json: String,
                     headers: [String: String] = ["sec-fetch-site": "same-origin"]) -> HTTPRequest {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return HTTPRequest(method: "POST", rawPath: path, segments: segments,
                           query: [:], headers: headers, body: Data(json.utf8))
    }

    /// A request by method, for the cases that enumerate the API surface rather than
    /// testing one route's behaviour — `AuthorizationTests` walks the gated list, and
    /// writing each entry out twice would be a way for the two copies to disagree.
    ///
    /// Segments are percent-decoded like a real `GET`, because that is what
    /// `HTTPConnection.makeRequest` produces and the router matches on segments.
    static func post(_ path: String, json: String?,
                     headers: [String: String] = ["sec-fetch-site": "same-origin"]) -> HTTPRequest {
        HTTPRequest(method: "POST", rawPath: path,
                    segments: path.split(separator: "/", omittingEmptySubsequences: true)
                        .map { String($0).percentDecodedPathSegment },
                    query: [:], headers: headers, body: Data((json ?? "").utf8))
    }

    static func request(_ method: String, _ path: String, json: String? = nil) -> HTTPRequest {
        switch method {
        case "GET": return get(path)
        case "POST": return post(path, json: json)
        default:
            preconditionFailure("Req.request handles GET and POST; got \(method)")
        }
    }
}

/// A `RouteResult` reduced to what an HTTP client would see.
struct Reply {
    var status: Int
    var headers: [String: String]
    var body: Data

    var json: [String: Any] {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
    }

    var errorMessage: String {
        (json["error"] as? String) ?? String(decoding: body, as: UTF8.self)
    }

    func int(_ key: String) -> Int? { json[key] as? Int }
    func bool(_ key: String) -> Bool? { json[key] as? Bool }
    func string(_ key: String) -> String? { json[key] as? String }
    func has(_ key: String) -> Bool { json.keys.contains(key) }

    /// Rows of an array-valued key, in wire order.
    func rows(_ key: String = "items") -> [Row] {
        (json[key] as? [[String: Any]] ?? []).map(Row.init)
    }

    func side(_ key: String) -> Reply {
        let object = json[key] as? [String: Any] ?? [:]
        return Reply(status: status, headers: headers,
                     body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}

struct Row: Hashable {
    let id: String
    let score: Float
    let date: Double?
    let favorite: Bool
    /// Whether the key was present at all, so "omitted" and "null" stay distinguishable.
    let hadDateKey: Bool

    init(_ json: [String: Any]) {
        id = json["id"] as? String ?? ""
        score = (json["score"] as? NSNumber)?.floatValue ?? 0
        date = (json["date"] as? NSNumber)?.doubleValue
        favorite = (json["favorite"] as? NSNumber)?.boolValue ?? false
        hadDateKey = json.keys.contains("date")
    }
}

extension Router {
    /// Runs a request and unwraps the non-streaming cases. A `.stream` result is a
    /// test error, not a silent empty reply.
    func reply(_ request: HTTPRequest) async -> Reply {
        switch await handle(request) {
        case .response(let response):
            return Reply(status: response.status, headers: response.headers, body: response.body)
        case .stream:
            return Reply(status: -1, headers: [:], body: Data("unexpected SSE stream".utf8))
        }
    }
}