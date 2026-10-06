import Foundation

/// Populates album membership in the cache, lazily and incrementally.
///
/// ## Why this is not part of the launch path
///
/// Album membership is the largest table in the cache: this library has 32 user
/// albums whose sizes sum to about 53,800 assets, so one pass is roughly one
/// membership row per photo. Doing that synchronously before the server accepts
/// a connection would add tens of seconds to every launch and would make the
/// cache's initialisation cost proportional to how organised the user's library
/// is. So:
///
/// - Nothing runs at launch. `Router` asks for the album list on the first
///   `GET /api/albums`, and gets whatever is already indexed, immediately.
/// - Indexing then proceeds **one album per step** in a detached task, smallest
///   album first, so the cheapest albums are filterable almost immediately and a
///   12,000-photo album is not on the critical path of anything.
/// - Progress is observable (`AlbumIndexStatus`), so the UI can say "still
///   reading albums" instead of pretending an incomplete index is complete.
///
/// ## Ordering: smallest first
///
/// Albums arrive from `PhotoLibrary.userAlbums()` sorted by
/// `estimatedAssetCount` ascending, which is a deliberate approximation of cost.
/// It is not exact — Photos' estimate is the whole library, while the write is
/// only over assets this instance has scanned — but it is the right ordering for
/// the same reason it is an approximation: the albums that cost least to read
/// are the ones most likely to be small and useful.
///
/// ## Reconciling
///
/// A full pass runs again when it is stale (older than `maxAge`) or when the
/// user asks. Membership is replaced wholesale per album, never merged, so a
/// photo removed from an album in Photos stops matching that album's filter
/// here. Albums Photos no longer reports are pruned at the end of a pass.
actor AlbumIndexer {
    /// How stale a complete index may be before a new pass starts by itself.
    static let maxAge: TimeInterval = 6 * 60 * 60

    /// Minimum gap between the end of one pass and the start of the next, so a
    /// client polling `/api/albums` cannot turn into a loop over the whole
    /// library.
    static let minPassInterval: TimeInterval = 60

    private let cache: CacheStore
    private let library: PhotoLibrary
    private var running = false
    private var lastPassFinished: Date?
    private var indexed = 0
    private var total = 0
    private var currentAlbum: String?
    private var lastError: String?

    init(cache: CacheStore, library: PhotoLibrary) {
        self.cache = cache
        self.library = library
    }

    struct AlbumIndexStatus: Sendable {
        /// True while a pass is running.
        var indexing = false
        /// Albums whose membership has been read at least once, this instance's
        /// whole life.
        var indexed = 0
        /// Albums Photos currently reports.
        var total = 0
        /// Album currently being read, for the progress line. Never a photo
        /// count: that would imply the pass is a fraction of the library.
        var current: String?
        /// True once every album Photos reports has been read at least once.
        var complete = false
        var lastError: String?
        var lastFinishedAt: Double?
    }

    func status() -> AlbumIndexStatus {
        AlbumIndexStatus(indexing: running, indexed: indexed, total: total,
                          current: currentAlbum, complete: indexed > 0 && indexed >= total,
                          lastError: lastError, lastFinishedAt: lastPassFinished?.timeIntervalSince1970)
    }

    /// Whether a new pass is worth starting. Deliberately conservative: a
    /// complete, fresh index is left alone entirely.
    func shouldRefresh() -> Bool {
        if running { return false }
        if indexed == 0 { return true }
        if indexed < total { return true }
        if let lastPassFinished, Date().timeIntervalSince(lastPassFinished) < Self.minPassInterval { return false }
        return (lastPassFinished ?? .distantPast).timeIntervalSinceNow < -Self.maxAge
    }

    /// Starts a pass if one is warranted. Returns immediately either way — this
    /// is called from a request handler.
    func refreshIfNeeded() {
        guard shouldRefresh() else { return }
        startPass(reason: "automatic")
    }

    /// Starts a pass regardless of freshness. Used by `POST /api/albums/index`.
    func refreshNow() {
        startPass(reason: "requested")
    }

    private func startPass(reason: String) {
        guard !running else { return }
        running = true
        indexed = 0
        total = 0
        currentAlbum = nil
        lastError = nil
        Log.info("album index pass started (\(reason))")
        Task { [weak self] in
            await self?.runPass()
        }
    }

    private func runPass() async {
        defer {
            running = false
            currentAlbum = nil
            lastPassFinished = Date()
        }
        do {
            let albums = library.userAlbums()
            total = albums.count
            var keep: [String] = []
            keep.reserveCapacity(albums.count)

            for album in albums {
                // A pass is cancelled by a quit, a rescan, or the user walking
                // away; stopping between albums keeps whatever has been written
                // so far and reports the pass as incomplete, which is honest.
                if Task.isCancelled {
                    Log.info("album index pass cancelled after \(indexed) of \(total) albums")
                    return
                }
                currentAlbum = album.title.isEmpty ? album.identifier : album.title
                try await cache.upsertAlbum(identifier: album.identifier, title: album.title,
                                            collectionType: album.collectionType)
                // Membership is collected into a bounded set and handed over in
                // one call: `replaceAlbumMembership` needs the whole list because
                // it deletes-then-inserts, and holding one album's identifiers is
                // bounded by the largest album a user chose to create.
                // A reference box, because the consumer closure is `@Sendable` and
                // therefore cannot capture a mutable local. Safe because
                // `enumerateAlbumAssets` runs its consumer strictly one batch at a
                // time, in order — the same back-pressure contract as the library
                // walk's.
                let members = IdentifierAccumulator()
                try await library.enumerateAlbumAssets(albumIdentifier: album.identifier) { batch in
                    members.append(batch)
                }
                try await cache.replaceAlbumMembership(albumIdentifier: album.identifier,
                                                        identifiers: members.taken())
                keep.append(album.identifier)
                indexed += 1
            }

            let removed = try await cache.removeAlbums(notIn: keep)
            if removed > 0 { Log.info("pruned \(removed) albums Photos no longer reports") }
            Log.info("album index pass finished: \(indexed) of \(total) albums, "
                     + "\(cache.databaseSizeBytes()) cache bytes")
        } catch is CancellationError {
            Log.info("album index pass cancelled")
        } catch {
            lastError = "\(error)"
            Log.error("album index pass failed: \(error)")
        }
    }
}

/// Collects one album's identifiers across `consume` callbacks.
///
/// Only ever touched from the consumer side, which `enumerateAlbumAssets`
/// invokes strictly one batch at a time, in order.
private final class IdentifierAccumulator: @unchecked Sendable {
    private var identifiers: [String] = []

    func append(_ batch: [String]) { identifiers.append(contentsOf: batch) }

    func taken() -> [String] {
        let all = identifiers
        identifiers = []
        return all
    }
}