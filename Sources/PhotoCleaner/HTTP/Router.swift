import AppKit
import Foundation
import Photos

/// Bounded in-memory cache for encoded thumbnails and previews.
///
/// Deliberately *not* a mirror of the library on disk: the only bytes that ever
/// leave PhotoKit are the ones the browser is currently looking at. `NSCache`
/// is documented as thread-safe and evicts under memory pressure, which is
/// exactly the desired behaviour for a browse-through-thousands-of-photos tool.
final class ImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSData>()

    init(totalCostLimit: Int = 192 * 1024 * 1024, countLimit: Int = 4_096) {
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = countLimit
    }

    func data(for key: String) -> Data? {
        cache.object(forKey: key as NSString) as Data?
    }

    func store(_ data: Data, for key: String) {
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }
}

/// All application endpoints.
///
/// Two invariants hold on every route:
/// 1. Identifiers arriving from the browser are validated against the cache
///    before they are used for anything, so a request can only ever touch assets
///    this instance has actually seen.
/// 2. Nothing destructive is reachable with `GET`. Deletion and preference
///    changes are `POST`-only, and favourite protection is re-checked here,
///    server-side, rather than trusted from the UI.
struct Router: Sendable {
    let cache: CacheStore
    let engine: AnalysisEngine
    let library: PhotoLibrary
    let settings: Settings
    let bus: EventBus
    let images: ImageCache
    /// Populates album membership in the background. Injectable so the object
    /// graph stays constructed in `PhotoCleanerApp`, and defaulted so every other
    /// construction site — the test fixture among them — keeps working without
    /// naming it.
    let albumIndex: AlbumIndexer
    /// Builds and ranks Similar Groups. Same injection terms as `albumIndex`:
    /// optional so every existing construction site keeps working.
    let groupEngine: SimilarGroupEngine

    /// The Photos authorization this router gates on.
    ///
    /// Defaults to the real `PHPhotoLibrary` status, and that default is what
    /// production runs on. It is a stored closure rather than a direct call to
    /// `photosAccessRefusal()` because otherwise *every* route that touches a photo
    /// is untestable on a machine that has not been granted Photos access — which is
    /// every CI runner. The gate itself is load-bearing and fail-closed: the point is
    /// that it is exercised, so it is exercised against an injected answer instead of
    /// being deleted. See `FavouriteProtectionTests` for the case that asserts the
    /// refusal really does happen when access is absent.
    private let authorizationStatus: @Sendable () -> PHAuthorizationStatus

    /// Written out rather than left to the memberwise initialiser, because the
    /// memberwise form would require `albumIndex:` at every call site for a
    /// dependency that can be derived from two that are already there.
    init(cache: CacheStore, engine: AnalysisEngine, library: PhotoLibrary,
         settings: Settings, bus: EventBus, images: ImageCache,
         albumIndex: AlbumIndexer? = nil,
         groupEngine: SimilarGroupEngine? = nil,
         authorizationStatus: @escaping @Sendable () -> PHAuthorizationStatus = {
             PhotoLibrary.currentAuthorization()
         }) {
        self.cache = cache
        self.engine = engine
        self.library = library
        self.settings = settings
        self.bus = bus
        self.images = images
        self.albumIndex = albumIndex ?? AlbumIndexer(cache: cache, library: library)
        self.groupEngine = groupEngine ?? SimilarGroupEngine(cache: cache, library: library,
                                                             settings: settings, bus: bus)
        self.authorizationStatus = authorizationStatus
    }

    private static let thumbnailSizes = [128, 256, 384, 512]
    private static let previewPixels = 2048
    private static let defaultPageSize = 60
    private static let maxPageSize = 200
    /// Members served per group.
    ///
    /// Groups are small by construction — a burst of alternate captures — so this
    /// is a bound on pathological input rather than a paging mechanism: a library
    /// whose FeaturePrint threshold is set so wide that a whole event collapses
    /// into one "group" must not be able to ask for 53k rows in one response.
    private static let maxGroupMembers = 500

    /// Snaps a requested thumbnail width onto the ladder in `thumbnailSizes`.
    ///
    /// Ties go to the **smaller** rung, deliberately: a grid tile that renders at
    /// 128 when 128 was asked for costs half the bytes of the 256 rendition and
    /// looks the same at tile density, so breaking a tie the other way is an
    /// upscale bought for nothing. `192` → 128 and `320` → 256.
    ///
    /// The tie-break is written out rather than left to `min(by:)`, whose choice
    /// among equal elements is a documented-but-incidental property of the
    /// standard library's reduction order — not something a routing decision
    /// should depend on.
    static func thumbnailPixelSize(for requested: Int) -> Int {
        thumbnailSizes.min { candidate, incumbent in
            let toCandidate = abs(candidate - requested)
            let toIncumbent = abs(incumbent - requested)
            if toCandidate == toIncumbent { return candidate < incumbent }
            return toCandidate < toIncumbent
        } ?? 256
    }

    func handle(_ request: HTTPRequest) async -> RouteResult {
        let segments = request.segments
        let method = request.method
        let path = "/" + segments.joined(separator: "/")

        switch (method, path) {
        case ("GET", "/"):
            return staticAsset("index.html", contentType: "text/html; charset=utf-8")
        case ("GET", "/app.css"):
            return staticAsset("app.css", contentType: "text/css; charset=utf-8")
        case ("GET", "/app.js"):
            return staticAsset("app.js", contentType: "application/javascript; charset=utf-8")
        case ("GET", "/favicon.ico"):
            return .response(HTTPResponse(status: 204))

        case ("GET", "/api/status"):
            return .response(.json(await engine.status()))

        case ("GET", "/api/photos"):
            return await photos(request)

        case ("GET", "/api/albums"):
            return await albums(request)

        case ("POST", "/api/albums/index"):
            return await reindexAlbums(request)

        case ("GET", "/api/timeline/around"):
            return await timelineAround(request)

        case ("GET", "/api/timeline/page"):
            return await timelinePage(request)

        case ("GET", "/api/events"):
            return await events()

        case ("POST", "/api/selection/preview"):
            return await selectionPreview(request)

        case ("POST", "/api/photos/reveal"):
            return await reveal(request)

        case ("POST", "/api/delete"):
            return await delete(request)

        case ("POST", "/api/favorites"):
            return await favorites(request)

        case ("POST", "/api/settings"):
            return await updateSettings(request)

        case ("POST", "/api/analysis/retry"):
            // Same-origin gated like every other mutating route, and for a sharper
            // reason than most: this requeues every failed asset in the library and
            // restarts the run, which is a whole-library pass of Vision requests.
            // `crossOriginRefusal` is what stops a page the user happened to be
            // visiting from starting one.
            if let refusal = Self.crossOriginRefusal(for: request) { return .response(refusal) }
            let engine = self.engine
            Task { await engine.requestRetry() }
            // Name only what will actually be requeued: with iCloud downloads
            // off, `unavailable` assets would fail the same way again.
            let message = settings.snapshot().downloadFromICloud
                ? "retrying failed and unavailable assets"
                : "retrying failed assets"
            return .response(.json(SimpleMessage(ok: true, message: message)))

        case ("POST", "/api/library/rescan"):
            // Gated for a sharper reason than most: `finishScan` deletes every cache
            // row the new scan does not stamp, so a cross-site page reaching this
            // would make the app throw away its own record of the library.
            if let refusal = Self.crossOriginRefusal(for: request) { return .response(refusal) }
            let engine = self.engine
            Task { await engine.requestRescan() }
            return .response(.json(SimpleMessage(ok: true, message: "rescanning the library")))

        case ("GET", "/api/groups"):
            return await groups(request)

        case ("GET", "/api/group"):
            return await group(request)

        case ("POST", "/api/groups/rebuild"):
            return await rebuildGroups(request)

        default:
            return await parameterisedRoute(request, segments: segments, method: method)
        }
    }

    /// Routes whose middle component is an asset identifier.
    ///
    /// Photos `localIdentifier`s contain slashes (`…/L0/001`). Browser clients
    /// percent-encode them, but the identifier is reconstructed by joining the
    /// remaining segments so that a raw, unencoded identifier works too — both
    /// forms resolve to exactly the same string.
    private func parameterisedRoute(_ request: HTTPRequest, segments: [String], method: String) async -> RouteResult {
        guard method == "GET", segments.count >= 3,
              segments[0] == "api", segments[1] == "photo" else {
            return .response(.error("no route for \(method) \(request.rawPath)", status: 404))
        }
        var remaining = Array(segments.dropFirst(2))
        var action = "detail"
        if let last = remaining.last, remaining.count > 1,
           last == "thumbnail" || last == "preview" || last == "similar" {
            action = last
            remaining.removeLast()
        }
        let identifier = remaining.joined(separator: "/")
        guard !identifier.isEmpty else {
            return .response(.error("missing asset identifier", status: 400))
        }

        switch action {
        case "thumbnail":
            let size = request.queryInt("size", default: 256, range: 64...1024) ?? 256
            let nearest = Self.thumbnailPixelSize(for: size)
            // Grid tiles never reach for iCloud: scrolling past thousands of
            // photos must not trigger thousands of downloads.
            return await image(identifier: identifier, pixels: nearest, allowNetwork: false,
                               kind: "thumb", usePreviewLadder: false)
        case "preview":
            let pixels = request.queryInt("size", default: Self.previewPixels, range: 512...4096) ?? Self.previewPixels
            let allowNetwork = settings.snapshot().downloadFromICloud
            return await image(identifier: identifier, pixels: pixels, allowNetwork: allowNetwork,
                               kind: "preview", usePreviewLadder: true)
        case "similar":
            return await similarPhotos(identifier: identifier)
        default:
            return await photo(identifier: identifier)
        }
    }

    // MARK: - Static UI

    private func staticAsset(_ name: String, contentType: String) -> RouteResult {
        guard let data = WebAssets.bytes(named: name) else {
            return .response(.error("embedded asset \(name) is missing", status: 500))
        }
        return .response(.bytes(data, contentType: contentType))
    }

    // MARK: - Status / events

    private func events() async -> RouteResult {
        // Give the new subscriber a current snapshot immediately, then stream.
        await engine.publishStatus(force: true)
        let subscription = bus.subscribe()
        let bus = self.bus
        return .stream(HTTPStream(
            headers: ["Content-Type": "text/event-stream; charset=utf-8"],
            events: subscription.stream,
            onClose: { bus.unsubscribe(subscription.id) }
        ))
    }

    // MARK: - Browsing

    private struct PhotosResponse: Encodable {
        let total: Int
        let items: [PhotoRow]
        let nextCursor: String?
        let bounds: Bounds
        let filter: FilterEcho

        struct Bounds: Encodable {
            let min: Float?
            let max: Float?
        }

        struct FilterEcho: Encodable {
            let lower: Float
            let upper: Float
            let sort: String
            let favorites: String
            /// Which album the grid was filtered to. `all` and `none` are the two
            /// sentinels `AlbumSelection` uses; anything else is an album
            /// identifier. Echoed so a client can tell "the album I asked for" from
            /// "the album the server actually applied", which matters because an
            /// unknown album is refused rather than silently ignored.
            let album: String
            /// The albums each row in this page belongs to, keyed by asset
            /// identifier. `[{id, title}]`, so a tag can be rendered *and* filtered
            /// without matching titles back to identifiers. Omitted entirely when
            /// the page is empty or nothing is indexed, so an album-less cache pays
            /// nothing.
            let albums: [String: [AlbumTag]]?
        }

        struct AlbumTag: Encodable {
            let id: String
            let title: String
        }
    }

    private func photos(_ request: HTTPRequest) async -> RouteResult {
        let stats = (try? await cache.stats(maxAge: 0.25)) ?? CacheStats()
        // The slider's limits are `MIN`/`MAX(aesthetics_score)` over the cache, not
        // 0 and 1. `overallScore` is not a 0…1 quantity — a real library measures
        // about −0.95…+1.0, with a pile-up at exactly 1.0 — so normalising, clamping
        // or hard-coding the range here would quietly change what the filter means.
        // The zero fallback is the *empty* case only: nothing is scored yet.
        let bounds = (min: stats.minScore ?? 0, max: stats.maxScore ?? 0)
        let base = Self.filter(from: request, bounds: bounds)
        let sort = SortOrder(rawValue: request.queryValue("sort") ?? "") ?? .scoreAscending
        let limit = request.queryInt("limit", default: Self.defaultPageSize, range: 1...Self.maxPageSize) ?? Self.defaultPageSize
        let offset = request.queryInt("offset", default: 0, range: 0...1_000_000) ?? 0
        let cursor = request.queryValue("cursor").flatMap { PhotoCursor.decode($0) }

        // The album dimension is validated against the `albums` table *before* it
        // becomes part of a filter, exactly as identifiers are validated against
        // `known()`. An album identifier this instance has not indexed is refused
        // rather than quietly treated as "no album" — which would be a lie that
        // silently empties the grid.
        let album: AlbumSelection
        switch await resolveAlbumSelection(request) {
        case .refused(let response): return .response(response)
        case .resolved(let selection): album = selection
        }
        var filter = base
        filter.album = album

        do {
            let page = try await cache.page(filter: filter, sort: sort, cursor: cursor, limit: limit, offset: offset)
            // Album membership for the tags on this page only — bounded by the
            // page size, never by the library.
            let membership = page.rows.isEmpty
                ? [:]
                : ((try? await cache.albumMembership(for: page.rows.map(\.id))) ?? [:])
            let tags = membership.mapValues { entries in
                entries.map { PhotosResponse.AlbumTag(id: $0.identifier, title: $0.title) }
            }
            return .response(.json(PhotosResponse(
                total: page.total,
                items: page.rows,
                nextCursor: page.nextCursor,
                bounds: .init(min: stats.minScore, max: stats.maxScore),
                filter: .init(lower: filter.lower, upper: filter.upper, sort: sort.rawValue,
                              favorites: filter.favorites.rawValue,
                              album: album.wireValue,
                              albums: tags.isEmpty ? nil : tags)
            )))
        } catch let error as CacheError {
            // A cursor/filter mismatch is the caller's mistake, not a cache
            // failure, and saying 500 would hide that from the client.
            if case .cursorSortMismatch = error { return .response(.error("\(error)", status: 400)) }
            if case .cursorFilterMismatch = error { return .response(.error("\(error)", status: 400)) }
            return .response(.error("could not read the score cache: \(error)", status: 500))
        } catch {
            return .response(.error("could not read the score cache: \(error)", status: 500))
        }
    }

    private func photo(identifier: String) async -> RouteResult {
        guard let row = try? await cache.photo(identifier: identifier) else {
            return .response(.error("unknown asset", status: 404))
        }
        struct Response: Encodable { let photo: PhotoRow }
        return .response(.json(Response(photo: row)))
    }

    // MARK: - All Photos

    /// Read-only chronological browsing, for "Show in All Photos".
    ///
    /// Both routes are `GET`, change nothing and take no body, so — like
    /// `/api/photos` — they need no same-origin gate and no Photos-authorization
    /// gate; there is no state for a cross-site page to disturb. Nothing here
    /// can delete, and no request can reach an asset this instance has not
    /// already scanned: `/api/timeline/around` resolves its anchor through the
    /// cache, and `/api/timeline/page` returns the same score-bounded rows the
    /// grid already serves.
    ///
    /// The ordering is by date alone. The aesthetics score is used *only* as the
    /// widest bound the cache can express — the observed extremes, so that every
    /// scored asset is included — and never as an ordering key. That is the
    /// whole point of the view: chronology, not ranking. Assets PhotoCleaner has
    /// never scored have no row in a score-bounded query, so they cannot appear
    /// here; the client states that count rather than implying the window is the
    /// whole library.
    private struct TimelineSide: Encodable {
        let items: [PhotoRow]
        /// Opaque keyset token for the next page in this direction. Nil once this
        /// side is exhausted — that is how the client knows it has reached the
        /// newest or oldest photo.
        let nextCursor: String?
    }

    private struct TimelineAroundResponse: Encodable {
        let anchor: PhotoRow
        /// Photos in the whole-library chronological ordering, not a page size.
        let total: Int
        let older: TimelineSide
        /// `date ASC, id DESC` from the anchor — the rows *nearest* the anchor come
        /// first, so the client reverses this to display newest-first. Reversing it
        /// yields exactly the order `older` already returns, which is what lets the
        /// two sides meet at the anchor with no discontinuity.
        let newer: TimelineSide
    }

    private struct TimelinePageResponse: Encodable {
        let direction: String
        let total: Int
        let items: [PhotoRow]
        let nextCursor: String?
    }

    /// The widest filter the cache can express: every asset that has a score.
    ///
    /// Built here rather than through `filter(from:bounds:)` because this view is
    /// by definition *not* filtered — the client must not be able to narrow the
    /// timeline with `lo`, `hi` or `favorites` query parameters, and
    /// those are exactly what that helper would read.
    private func timelineFilter() async -> PhotoFilter {
        let stats = (try? await cache.stats(maxAge: 0.25)) ?? CacheStats()
        // `unboundedByScore` pins the pagination fingerprint: these bounds are the
        // *observed* extremes, which move as analysis progresses, so folding them
        // into the token would make `/api/timeline/page` refuse its own server's
        // nextCursor the next time a new score arrived.
        return PhotoFilter(lower: stats.minScore ?? 0, upper: stats.maxScore ?? 0,
                           unboundedByScore: true)
    }

    /// One page either side of an anchor, plus the anchor itself.
    ///
    /// Two keyset queries, both starting from the anchor's own `(date, id)` sort
    /// key — see `TimelineDirection.sort`. Nothing walks from the top of the
    /// library, so the neighbours of a photo from 2019 cost the same as the
    /// neighbours of one from this morning.
    ///
    /// The anchor must be an asset this instance has scored: unscored assets are
    /// not in a score-bounded ordering, so there is no position for one to hold.
    /// Every photo the interface can offer as an anchor comes from `/api/photos`
    /// and therefore has a score.
    ///
    /// That contract is *enforced*, not merely documented: an unscored asset is a
    /// 404 rather than a window it is not part of. It was previously resolved
    /// with `cache.photo(identifier:)`, which matches any cached row, and answered
    /// with `200`, an `anchor` carrying `score: 0` (`PhotoRow.score` is
    /// non-optional) and a chronological window that cannot contain it — so the
    /// client would scroll a gap where the anchor should be. `scoredPhoto` asks
    /// the database whether a score exists rather than inferring it from a row
    /// that cannot say.
    private func timelineAround(_ request: HTTPRequest) async -> RouteResult {
        guard let identifier = request.queryValue("id"), !identifier.isEmpty else {
            return .response(.error("the timeline needs an anchor asset identifier in ?id=", status: 400))
        }
        let limit = request.queryInt("limit", default: Self.defaultPageSize,
                                     range: 1...Self.maxPageSize) ?? Self.defaultPageSize
        let anchor: PhotoRow
        do {
            guard let row = try await cache.scoredPhoto(identifier: identifier) else {
                return .response(.error("unknown or unscored asset", status: 404))
            }
            anchor = row
        } catch {
            return .response(.error("could not read the score cache: \(error)", status: 500))
        }

        let filter = await timelineFilter()
        // One anchor key, walked forwards in two orderings that are exact reverses
        // of each other — see `TimelineDirection.sort`. That is what makes the two
        // sides *partition* the timeline: together they are every scored row in the
        // library except the anchor, with nothing twice and nothing unreachable,
        // even in the middle of a burst of same-timestamp shots.
        let cursor = PhotoCursor(row: anchor)
        do {
            let older = try await cache.page(filter: filter, sort: TimelineDirection.older.sort,
                                             cursor: cursor, limit: limit, offset: 0)
            let newer = try await cache.page(filter: filter, sort: TimelineDirection.newer.sort,
                                             cursor: cursor, limit: limit, offset: 0)
            return .response(.json(TimelineAroundResponse(
                anchor: anchor,
                total: older.total,
                older: .init(items: older.rows, nextCursor: older.nextCursor),
                newer: .init(items: newer.rows, nextCursor: newer.nextCursor)
            )))
        } catch {
            return .response(.error("could not read the score cache: \(error)", status: 500))
        }
    }

    /// One more page in one direction.
    ///
    /// Separate from `timelineAround` so that paging one way does not re-query the
    /// other side. The cursor is the server's own opaque token from the previous
    /// page; a malformed one is refused instead of being ignored, because
    /// silently restarting from the anchor would duplicate photos the client
    /// already has.
    private func timelinePage(_ request: HTTPRequest) async -> RouteResult {
        guard let raw = request.queryValue("direction") else {
            return .response(.error("the timeline page needs ?direction=older|newer", status: 400))
        }
        guard let direction = TimelineDirection(rawValue: raw) else {
            return .response(.error("unknown timeline direction \"\(raw)\"; expected \"older\" or \"newer\"",
                                    status: 400))
        }
        guard let encoded = request.queryValue("cursor"), !encoded.isEmpty else {
            return .response(.error("the timeline page needs the cursor from the previous page", status: 400))
        }
        guard let cursor = PhotoCursor.decode(encoded) else {
            return .response(.error("malformed timeline cursor", status: 400))
        }
        let limit = request.queryInt("limit", default: Self.defaultPageSize,
                                     range: 1...Self.maxPageSize) ?? Self.defaultPageSize
        let filter = await timelineFilter()
        do {
            let page = try await cache.page(filter: filter, sort: direction.sort,
                                            cursor: cursor, limit: limit, offset: 0)
            return .response(.json(TimelinePageResponse(
                direction: direction.rawValue,
                total: page.total,
                items: page.rows,
                nextCursor: page.nextCursor
            )))
        } catch {
            return .response(.error("could not read the score cache: \(error)", status: 500))
        }
    }

    private func image(identifier: String, pixels: Int, allowNetwork: Bool,
                       kind: String, usePreviewLadder: Bool) async -> RouteResult {
        // Validation gate: only assets this instance knows about are reachable.
        guard (try? await cache.photo(identifier: identifier)) != nil else {
            return .response(.error("unknown asset", status: 404))
        }
        let key = "\(kind)@\(pixels):\(identifier)"
        if let cached = images.data(for: key) {
            return .response(.bytes(cached, contentType: "image/jpeg", maxAge: 3_600))
        }
        do {
            let image = usePreviewLadder
                ? try await library.previewImage(identifier: identifier, preferredPixelSize: pixels, allowNetwork: allowNetwork)
                : try await library.image(identifier: identifier, maxPixelSize: pixels, allowNetwork: allowNetwork)
            guard let data = Self.encodeJPEG(image) else {
                return .response(.error("could not encode the image", status: 500))
            }
            images.store(data, for: key)
            return .response(.bytes(data, contentType: "image/jpeg", maxAge: 3_600))
        } catch {
            return .response(.error("\(error)", status: 404))
        }
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }

    // MARK: - Selection and deletion

    /// Wire format shared by `/api/selection/preview` and `/api/delete`.
    private struct SelectionSpec: Decodable {
        var mode: String
        var ids: [String]?
        var filter: FilterPayload?
        var exclude: [String]?
        var allowFavorites: Bool?
        /// Fingerprint of the candidate set from the `/api/selection/preview`
        /// the user actually confirmed. Optional, so a client that does not send
        /// it keeps working — but when it *is* sent, the deletion is refused
        /// unless the selection still resolves to exactly that set.
        var confirmToken: String?
    }

    private struct FilterPayload: Decodable {
        var lo: Float?
        var hi: Float?
        var favorites: String?
        /// `"all"`, `"none"`, or an album identifier. Absent means `.all`.
        ///
        /// It is part of the *selection snapshot*, not a separate concern: an
        /// "all matching" selection taken while the grid was filtered to one album
        /// must keep resolving against that album after the user changes the
        /// filter, exactly as it keeps the score bounds it was taken at. Omitting
        /// it from the payload would silently widen a snapshotted selection to
        /// the whole library — the exact failure §4.9 exists to prevent.
        var album: String?

        /// An unrecognised value is an error, never a fallback.
        ///
        /// `favorites` defaults to `include`, so quietly
        /// substituting the default for a typo would turn an intended
        /// *exclusion* into an *inclusion* — the exact opposite of what a
        /// cautious caller meant. The bounds are mandatory for the same reason:
        /// an unbounded filter means "everything I have ever scored", which is
        /// not a decision a human made about a score range.
        ///
        /// The album is validated against the `albums` table by
        /// `resolveSelection` rather than here, because that needs the cache and
        /// this is a synchronous helper: an album identifier that survives the
        /// parse is still only *well-formed*, not known.
        func resolved() throws -> PhotoFilter {
            guard let lo, let hi else { throw SelectionError.missingBounds }
            if let favorites, FavoriteFilter(rawValue: favorites) == nil {
                throw SelectionError.invalidFilter("unknown favorites filter \"\(favorites)\"")
            }
            var filter = PhotoFilter(
                lower: lo,
                upper: hi,
                favorites: FavoriteFilter(rawValue: favorites ?? "") ?? .include
            )
            if let album {
                filter.album = try AlbumSelection.parse(album)
            }
            return filter
        }
    }

    /// Why a selection could not be resolved. Never a silent empty result: every
    /// case here maps to a status the client can act on.
    private enum SelectionError: Error, CustomStringConvertible {
        case unknownMode(String)
        case missingFilter
        case missingIdentifiers
        case missingBounds
        case invalidFilter(String)
        /// An album identifier that is syntactically fine but that this instance
        /// has not indexed. An error rather than "matches nothing": silently
        /// returning an empty selection would read as "this album is empty".
        case unknownAlbum
        /// Favourite protection could not be evaluated, so the selection is
        /// treated as "nothing is eligible" rather than "nothing is protected".
        case favoriteCheckFailed
        /// The library changed between the preview the user confirmed and this
        /// deletion. Nothing was deleted.
        case selectionChanged

        var description: String {
            switch self {
            case .unknownMode(let mode):
                return "unknown selection mode \"\(mode)\"; expected \"ids\" or \"matching\""
            case .missingFilter:
                return "matching mode requires a filter"
            case .missingIdentifiers:
                return "ids mode requires an \"ids\" array of asset identifiers"
            case .missingBounds:
                return "a matching filter must state both score bounds (lo and hi)"
            case .invalidFilter(let detail):
                return "invalid filter: \(detail)"
            case .unknownAlbum:
                return "this album is not one PhotoCleaner has read; refresh the album list, "
                    + "or use \"none\" for photos that are in no album"
            case .favoriteCheckFailed:
                return "could not verify which of these photos are favorites, so nothing was selected"
            case .selectionChanged:
                return "the selection changed since you reviewed it; nothing was deleted — review it again"
            }
        }

        var status: Int {
            switch self {
            case .unknownMode, .missingFilter, .missingIdentifiers, .missingBounds, .invalidFilter,
                 .unknownAlbum:
                return 400
            case .selectionChanged: return 409
            case .favoriteCheckFailed: return 500
            }
        }
    }

    private struct ResolvedSelection {
        /// What the request asked for, *before* favourite protection — so
        /// "127 requested, 0 eligible" is expressible rather than collapsing to
        /// a meaningless zero.
        var requestedCount = 0
        /// What would actually be deleted: identifiers this instance has verified
        /// as its own, with protected favourites already removed.
        var candidates: [String] = []
        var protectedFavorites = 0
        var unknownIdentifiers = 0
        /// The filter matches more assets than one resolution will return.
        var truncated = false
        var mode = "ids"
    }

    /// Upper bound on what a single "all matching" resolution returns. Beyond it
    /// the resolver says so instead of quietly returning a subset. Both routes
    /// use the same cap, so the preview count and the deletion count still
    /// agree.
    private static let maxMatchingCandidates = 200_000

    /// The single place that turns a browser-side selection into a concrete,
    /// server-verified list of assets. Both the review step and the deletion
    /// itself call it, so what the user confirms is exactly what is deleted.
    ///
    /// Nothing here trusts the browser: identifiers must already be in the cache,
    /// the filter is a closed set of enum values with mandatory bounds, and
    /// favourites are excluded from stored state. Every failure is an error, never
    /// an empty result a caller could mistake for "nothing matched".
    private func resolveSelection(_ spec: SelectionSpec, protectFavorites: Bool) async throws -> ResolvedSelection {
        var resolved = ResolvedSelection()

        switch spec.mode {
        case "matching":
            guard let payload = spec.filter else { throw SelectionError.missingFilter }
            let filter = try payload.resolved()
            // An album identifier reaches SQL, so it is checked against the albums
            // this instance has indexed first — the same discipline asset
            // identifiers get against `known()`. A stale one (an album deleted in
            // Photos, or an album the index has not reached) is an error rather
            // than an empty selection, because "0 photos match" and "that album
            // does not exist" are very different things to hear before deleting.
            if let identifier = filter.album.albumIdentifier,
               !(try await cache.knownAlbums([identifier])).contains(identifier) {
                throw SelectionError.unknownAlbum
            }
            // Ask for one row beyond the cap so that a filter matching more than
            // the cap is *detected* rather than silently truncated.
            var matches = (try? await cache.identifiers(matching: filter,
                                                        limit: Self.maxMatchingCandidates + 1)) ?? []
            if matches.count > Self.maxMatchingCandidates {
                matches.removeLast(matches.count - Self.maxMatchingCandidates)
                resolved.truncated = true
                Log.warn("matching selection truncated to \(Self.maxMatchingCandidates) assets; the filter matches more")
            }
            let excluded = Set(spec.exclude ?? [])
            resolved.candidates = excluded.isEmpty ? matches : matches.filter { !excluded.contains($0) }
        case "ids":
            // A *missing* `ids` key is not an empty selection. `{"mode":"ids"}`
            // names no photos at all, which is a malformed specification, and
            // treating it as `[]` answered 200 with `resolved: 0` — a caller that
            // meant "delete these four" and mistyped the key would be told it
            // deleted nothing, having asked for the deletion of nothing. An
            // explicit `[]` is still legitimate (it is how the UI clears a
            // selection); matching mode already refuses its own missing
            // argument for the same reason.
            guard let requested = spec.ids else { throw SelectionError.missingIdentifiers }
            // The only identifiers that survive are the ones this instance has
            // actually scanned: `known()` is an exact-match lookup in the cache,
            // so a crafted identifier — unknown, a video, a differently-cased or
            // partially-decoded near-miss — is dropped and counted, never used.
            resolved.candidates = (try? await cache.known(identifiers: requested)) ?? []
            // Counted over distinct identifiers: `known()` collapses a repeated
            // identifier to a single row, so without this a client that named the
            // same photo twice would be told it named two unknown photos.
            var distinct = Set<String>()
            let distinctCount = requested.filter { distinct.insert($0).inserted }.count
            resolved.unknownIdentifiers = max(0, distinctCount - resolved.candidates.count)
        default:
            // An unrecognised mode must not fall through to `ids`: a client that
            // meant something else is told so, instead of quietly deleting
            // whatever `ids` happened to contain.
            throw SelectionError.unknownMode(spec.mode)
        }

        resolved.mode = spec.mode
        resolved.requestedCount = resolved.candidates.count

        if protectFavorites, !(spec.allowFavorites ?? false) {
            // Favourite protection is decided from stored flags, never from what
            // the browser claims — and it fails *closed*: if the flags cannot be
            // read the selection resolves to nothing, not to "no favourites".
            guard let partition = try? await cache.partitionFavorites(identifiers: resolved.candidates) else {
                throw SelectionError.favoriteCheckFailed
            }
            resolved.protectedFavorites = partition.favorites.count
            resolved.candidates = partition.others
        }
        return resolved
    }

    /// Order-independent 64-bit FNV-1a digest of a resolved candidate set.
    ///
    /// Used only to notice that "the set the user confirmed" is no longer "the
    /// set that would be deleted"; not a security primitive. `hashValue` is
    /// deliberately avoided: it is seeded per process, so the preview request and
    /// the delete request would never agree.
    private static func fingerprint(mode: String, identifiers: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func feed(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x0a
            hash = hash &* 0x0000_0100_0000_01b3
        }
        feed(mode)
        for identifier in identifiers.sorted() { feed(identifier) }
        return String(hash, radix: 16)
    }

    private func selectionPreview(_ request: HTTPRequest) async -> RouteResult {
        if let refusal = Self.crossOriginRefusal(for: request) { return .response(refusal) }
        if let refusal = photosAccessRefusal() { return .response(refusal) }
        guard let spec = try? JSONDecoder().decode(SelectionSpec.self, from: request.body) else {
            return .response(.error("malformed selection", status: 400))
        }
        let resolved: ResolvedSelection
        do {
            resolved = try await resolveSelection(spec, protectFavorites: settings.snapshot().protectFavorites)
        } catch let error as SelectionError {
            return .response(.error(error.description, status: error.status))
        } catch {
            return .response(.error("could not resolve the selection", status: 500))
        }
        struct Response: Encodable {
            let mode: String
            let requested: Int
            let resolved: Int
            let protectedFavorites: Int
            let unknownIdentifiers: Int
            let appliesToAllMatching: Bool
            let truncated: Bool
            /// Hand this back verbatim as `confirmToken` on the deletion.
            let confirmToken: String
        }
        return .response(.json(Response(
            mode: resolved.mode,
            requested: resolved.requestedCount,
            resolved: resolved.candidates.count,
            protectedFavorites: resolved.protectedFavorites,
            unknownIdentifiers: resolved.unknownIdentifiers,
            appliesToAllMatching: resolved.mode == "matching",
            truncated: resolved.truncated,
            confirmToken: Self.fingerprint(mode: resolved.mode, identifiers: resolved.candidates))))
    }

    /// One report shape for every outcome, so `/api/delete` always says what was
    /// asked for, what was eligible, and what actually happened.
    private struct DeleteReport: Encodable {
        var requested = 0
        var resolved = 0
        var deleted = 0
        var missing = 0
        var protectedFavorites = 0
        var skippedNonImages = 0
        var unknownIdentifiers = 0
        var truncated = false
        var errors: [String] = []
    }

    private func delete(_ request: HTTPRequest) async -> RouteResult {
        if let refusal = Self.crossOriginRefusal(for: request) { return .response(refusal) }
        if let refusal = photosAccessRefusal() { return .response(refusal) }
        guard let spec = try? JSONDecoder().decode(SelectionSpec.self, from: request.body) else {
            return .response(.error("malformed deletion request", status: 400))
        }
        let protect = settings.snapshot().protectFavorites
        let resolved: ResolvedSelection
        do {
            resolved = try await resolveSelection(spec, protectFavorites: protect)
        } catch let error as SelectionError {
            return .response(.error(error.description, status: error.status))
        } catch {
            return .response(.error("could not resolve the selection", status: 500))
        }

        // Time-of-check to time-of-use: the review step and the deletion are two
        // requests, so the library can change in between (a rescan scoring more
        // assets, photos added or removed elsewhere). If the client presents the
        // fingerprint of the set the user confirmed, refuse rather than delete a
        // different set than the one that was agreed.
        if let confirmed = spec.confirmToken,
           confirmed != Self.fingerprint(mode: resolved.mode, identifiers: resolved.candidates) {
            Log.warn("refusing a deletion whose confirmed selection no longer matches")
            return .response(.error(SelectionError.selectionChanged.description,
                                     status: SelectionError.selectionChanged.status))
        }

        var report = DeleteReport()
        report.requested = resolved.requestedCount
        report.resolved = resolved.candidates.count
        report.protectedFavorites = resolved.protectedFavorites
        report.unknownIdentifiers = resolved.unknownIdentifiers
        report.truncated = resolved.truncated

        if !resolved.candidates.isEmpty {
            let override = spec.allowFavorites ?? false
            Log.info("deleting \(resolved.candidates.count) assets through PhotoKit "
                     + "(favourite protection \(protect ? "on" : "off"), per-request favourite override "
                     + "\(override ? "used" : "not used"), \(resolved.protectedFavorites) protected favourites excluded)")
            let outcome = await library.delete(identifiers: resolved.candidates,
                                               protectFavorites: protect && !override)
            report.deleted = outcome.deleted
            report.missing = outcome.missing
            // Favouriteness re-read live from PhotoKit adds to the favourites
            // already excluded by the cached flags, so the totals still add up:
            // requested = resolved = deleted + missing + (fresh favourites) + skippedNonImages
            report.protectedFavorites += outcome.skippedFavorites
            report.skippedNonImages = outcome.skippedNonImages
            report.errors = outcome.failedMessages
            if !outcome.deletedIdentifiers.isEmpty {
                try? await cache.remove(identifiers: outcome.deletedIdentifiers)
            }
            await engine.publishStatus(force: true)
        }

        // A partial deletion is reported as exactly what it is: every chunk that
        // did not go is named in `errors[]`, and if nothing at all went, the
        // status says the server could not do it rather than reporting success.
        if report.deleted == 0, !report.errors.isEmpty {
            return .response(.json(report, status: 500))
        }
        return .response(.json(report))
    }

    // MARK: - Similar Groups

    /// `GET /api/groups` — the list of groups, largest first.
    ///
    /// `?album=` is the grid's own album dimension, with the same wire values and
    /// the same validation: a group qualifies if **at least one** of its members is
    /// in the album, because a burst split across two albums is still the same
    /// burst. The members served for each qualifying group are the album's own, and
    /// the number left out is reported rather than absorbed.
    ///
    /// Read-only: no body, no state, so no same-origin gate, for the same reason
    /// as the timeline and album-list routes. Groups are only ever built from
    /// signals already in the cache, so this cannot reach anything this instance
    /// has not scanned.
    ///
    /// Every count is reported with what it is a count *of*. `featurePrints` in
    /// particular is the honest ceiling on grouping: a library where 30% of photos
    /// are iCloud-only can never group them, and a group list that did not say so
    /// would read as "these are all the similar photos you have".
    private struct GroupsResponse: Encodable {
        let groups: [SimilarGroupRow]
        let total: Int
        let status: SimilarGroupEngine.Status
    }

    private func groups(_ request: HTTPRequest) async -> RouteResult {
        if let refusal = photosAccessRefusal() { return .response(refusal) }
        // The album filter the grid is already showing applies here too: the two
        // views are the same library, and a list of groups from every album while
        // the grid is narrowed to one is the sort of silent widening the grid
        // refuses for its own selection. Validated the same way, so an album this
        // instance has not read is a 400 rather than an empty list.
        let album: AlbumSelection
        switch await resolveAlbumSelection(request) {
        case .refused(let response): return .response(response)
        case .resolved(let selection): album = selection
        }
        await groupEngine.rebuildIfNeeded()
        let order = Self.groupRankOrder(from: request)
        let limit = request.queryInt("limit", default: 24, range: 1...100) ?? 24
        let offset = request.queryInt("offset", default: 0, range: 0...1_000_000) ?? 0
        do {
            let page = try await cache.groupSummaries(limit: limit, offset: offset, album: album)
            let config = settings.snapshot().similarGroups
            var rows: [SimilarGroupRow] = []
            for summary in page.groups {
                rows.append(await groupRow(summary: summary, order: order, config: config,
                                        memberLimit: Self.maxGroupMembers, album: album))
            }
            return .response(.json(GroupsResponse(
                groups: rows,
                total: page.total,
                status: await groupEngine.status())))
        } catch {
            return .response(.error("could not read similar groups: \(error)", status: 500))
        }
    }

    /// `GET /api/group?id=` — one group, its members in the requested order.
    ///
    /// The identifier is validated against the stored groups, exactly as asset
    /// identifiers are validated against `known()`: a caller can only ever name a
    /// group this instance actually built. A group's id is one of its members'
    /// asset identifiers, so it is not attacker-controlled text reaching SQL — but
    /// it is still bound rather than interpolated.
    private func group(_ request: HTTPRequest) async -> RouteResult {
        if let refusal = photosAccessRefusal() { return .response(refusal) }
        guard let id = request.queryValue("id"), !id.isEmpty else {
            return .response(.error("a group needs an id", status: 400))
        }
        // The same album filter as the list, so "Show Similar Photos" from a tile in
        // an album-scoped grid shows the group's members from that album rather than
        // silently widening back to the whole library.
        let album: AlbumSelection
        switch await resolveAlbumSelection(request) {
        case .refused(let response): return .response(response)
        case .resolved(let selection): album = selection
        }
        do {
            guard let summary = try await cache.groupSummary(id: id) else {
                return .response(.error("unknown group", status: 404))
            }
            let row = await groupRow(summary: summary,
                                   order: Self.groupRankOrder(from: request),
                                   config: settings.snapshot().similarGroups,
                                   memberLimit: Self.maxGroupMembers,
                                   album: album)
            return .response(.json(row))
        } catch {
            return .response(.error("could not read that group: \(error)", status: 500))
        }
    }

    /// `GET /api/photo/{id}/similar` — the Similar Group this photo is in.
    ///
    /// The entry point behind "Show Similar Photos", and deliberately a *lookup*
    /// rather than a search. Grouping already happened when the FeaturePrints were
    /// analysed, so this only names the group a photo was placed in: two indexed
    /// reads, no image decoded, no FeaturePrint generated, no pair compared and no
    /// Vision request. The client then reads that group through `GET /api/group`,
    /// so the members, their ranking and their favourite flags come from exactly
    /// the one implementation the Similar Groups page uses.
    ///
    /// It is `GET`, takes no body and changes nothing, so — like `/api/groups` —
    /// it needs no same-origin gate. It *is* gated on Photos authorization, like
    /// every other group route: what it answers is a claim about the user's
    /// library, and a claim PhotoCleaner can no longer verify is not one it should
    /// make.
    ///
    /// `analyzed` is the honest half of an absent `groupId`. "No similar photos"
    /// and "similarity analysis has not reached this photo" are both a nil group,
    /// and the UI says different things about them, so the difference is reported
    /// rather than left for the client to guess.
    private struct SimilarPhotosResponse: Encodable {
        /// The stored group this asset is a member of. **Omitted** when there is
        /// none, following this API's convention for an absent optional rather
        /// than sending an explicit `null`.
        let groupId: String?
        /// How many photos are in that group, protected favourites included.
        /// Zero when there is no group.
        let totalCount: Int
        /// Whether FeaturePrint analysis has reached this asset, so grouping has
        /// been able to see it at all. `false` means "not analysed yet", which is
        /// a different answer from `true` with no group.
        let analyzed: Bool
    }

    private func similarPhotos(identifier: String) async -> RouteResult {
        if let refusal = photosAccessRefusal() { return .response(refusal) }
        // Identifiers are validated against the cache exactly as everywhere else,
        // so a request can only ever name an asset this instance has actually seen.
        guard (try? await cache.photo(identifier: identifier)) != nil else {
            return .response(.error("unknown asset", status: 404))
        }
        do {
            let analyzed = try await cache.hasFeaturePrint(for: identifier)
            // The membership row names the group; the group's own row is what the
            // browser reads next. A membership whose group row has gone — the case
            // `pruneOrphanGroupMembers` exists for — is therefore reported as "no
            // group" rather than as an id `/api/group` would answer 404 to.
            var groupId: String?
            var totalCount = 0
            if let candidate = try await cache.groupID(containingAsset: identifier),
               let summary = try await cache.groupSummary(id: candidate) {
                groupId = summary.id
                totalCount = summary.memberCount
            }
            return .response(.json(SimilarPhotosResponse(groupId: groupId,
                                                         totalCount: totalCount,
                                                         analyzed: analyzed)))
        } catch {
            return .response(.error("could not read that photo's similar group: \(error)", status: 500))
        }
    }

    /// `POST /api/groups/rebuild` — start a grouping pass now.
    ///
    /// Gated like every other mutating route: a rebuild is thousands of Vision
    /// requests and a whole-library walk, which is far too much work for a
    /// cross-site page to be able to trigger repeatedly.
    private func rebuildGroups(_ request: HTTPRequest) async -> RouteResult {
        if let refusal = Self.crossOriginRefusal(for: request) { return .response(refusal) }
        if let refusal = photosAccessRefusal() { return .response(refusal) }
        await groupEngine.rebuild(reason: "requested")
        return .response(.json(SimpleMessage(ok: true, message: "rebuilding similar groups")))
    }

    /// Identifiers of `inputs` in the Aesthetics order: highest score first, with
    /// the identifier as a deterministic tie-break so two equal scores can never
    /// swap places between two requests and make a tile appear to move on its own.
    private static func orderedIndices(of inputs: [RankingInput]) -> [String] {
        inputs.sorted {
            $0.aesthetics == $1.aesthetics ? $0.identifier < $1.identifier : $0.aesthetics > $1.aesthetics
        }.map(\.identifier)
    }

    /// The within-group order, defaulting to aesthetics.
    ///
    /// An unrecognised value is refused rather than defaulted, for the same reason
    /// `SortOrder` is a closed enum: `best_shot` and `aesthetics` are different
    /// rankings and silently serving one when the other was asked for would be a
    /// claim the user never made.
    private static func groupRankOrder(from request: HTTPRequest) -> GroupRankOrder {
        guard let raw = request.queryValue("order"), !raw.isEmpty else { return .aesthetics }
        return GroupRankOrder(rawValue: raw) ?? .aesthetics
    }

    /// Assembles one group: its members, ranked, with each member's signals.
    ///
    /// The `incomplete` flag is the honest part. A group is only fully ranked once
    /// every member has been through face capture analysis, and a portrait group
    /// that is still being analysed has a Best Shot order that may still change. The
    /// caller gets that as a flag rather than a finished-looking ordering.
    ///
    /// Under an album filter every count here is a count *of what this response is
    /// about* — the members the filter keeps — and what the filter dropped is
    /// reported as `hiddenMemberCount` rather than absorbed. A card reading "3
    /// photos" above a strip of three, next to a badge saying four of them have
    /// faces, would be two true sentences and one obviously wrong one.
    private func groupRow(summary: CacheStore.GroupSummary, order: GroupRankOrder,
                          config: SimilarGroupSettings, memberLimit: Int,
                          album: AlbumSelection = .all) async -> SimilarGroupRow {
        let inputs = (try? await cache.rankingInputs(groupID: summary.id, limit: memberLimit,
                                                     album: album)) ?? []

        let ranking = order == .bestShot ? BestShotRanker.rank(inputs, settings: config) : []
        let bestShot = Dictionary(uniqueKeysWithValues: ranking.map { ($0.identifier, Float($0.bestShot)) })
        /// Position in the requested order, best first. `bestShot` holds a value
        /// only for the Best Shot order; the aesthetics order is derived from the
        /// score itself, so a group sorted by aesthetics reports no Best Shot
        /// number rather than a fabricated one.
        let position: [String: Int]
        if order == .bestShot {
            position = Dictionary(uniqueKeysWithValues: ranking.enumerated().map { ($0.element.identifier, $0.offset) })
        } else {
            position = Dictionary(uniqueKeysWithValues: Self.orderedIndices(of: inputs).enumerated().map { ($0.element, $0.offset) })
        }

        let ordered = inputs.sorted {
            let lhs = position[$0.identifier] ?? Int.max
            let rhs = position[$1.identifier] ?? Int.max
            return lhs == rhs ? $0.identifier < $1.identifier : lhs < rhs
        }

        let items: [GroupMemberRow] = ordered.map { input in
            let aggregate = FaceCaptureAggregator.aggregate(
                input.faces, minimumAreaFraction: config.minimumFaceAreaFraction)
            return GroupMemberRow(
                id: input.identifier,
                aesthetics: input.aesthetics,
                bestShot: bestShot[input.identifier],
                faceCaptureQuality: aggregate,
                // Only meaningful where a face was found, so it stays nil otherwise
                // rather than claiming a face count of zero for an un-analysed photo.
                faceCount: input.faces.isEmpty ? nil : input.faces.count,
                date: input.date,
                width: 0,
                height: 0,
                favorite: input.favorite)
        }

        // `incomplete` is the honest part of this response. A group's Best Shot ordering is
        // only finished once every member has been through face capture analysis, so
        // the client is told whether it is looking at a settled order or one that may
        // still change — rather than being handed a half-ranked group that looks
        // authoritative.
        var outstanding: [RankingInput] = []
        for input in inputs where await groupEngine.isAwaitingFaceAnalysis(input.identifier) {
            outstanding.append(input)
        }

        // Under a filter the stored counts describe the whole group, so they are
        // recounted over the members it keeps — read in full, not as a page, so the
        // count is of the group and not of the strip's ceiling. Only the filtered
        // path pays for it; an unfiltered response is the stored numbers untouched.
        var memberCount = summary.memberCount
        var faceMemberCount = summary.faceMemberCount
        var hiddenMemberCount: Int?
        if album != .all, let kept = try? await cache.groupMembers(groupID: summary.id, album: album) {
            memberCount = kept.count
            hiddenMemberCount = summary.memberCount > kept.count
                ? summary.memberCount - kept.count : nil
            let faces = (try? await cache.faceCaptureQualities(for: kept)) ?? [:]
            faceMemberCount = kept.filter { faces[$0]?.isEmpty == false }.count
        }

        return SimilarGroupRow(
            id: summary.id,
            memberCount: memberCount,
            hiddenMemberCount: hiddenMemberCount,
            date: summary.earliestDate,
            faceMemberCount: faceMemberCount,
            items: items,
            ranked: order,
            incomplete: summary.rankedAt == nil || !outstanding.isEmpty)
    }

// MARK: - Reveal in Photos

    /// Wire format for `POST /api/photos/reveal`.
    ///
    /// Exactly one identifier, because the operation is per-photo: the photo
    /// the user pointed at. A list is refused rather than quietly truncated, so
    /// a caller cannot believe it revealed a selection.
    private struct RevealSpec: Decodable {
        var id: String?
    }

    /// `mechanism` says what actually happened, so the UI never claims more than
    /// was achieved: the per-asset link is undocumented and cannot be verified,
    /// and `launched_only` means Photos is open but was not pointed anywhere.
    private struct RevealResponse: Encodable {
        let ok: Bool
        let mechanism: String
        let requested: Int
        let opened: Int
        let id: String
        let message: String
    }

    /// Hands one photo to Photos.app.
    ///
    /// Not destructive — nothing in the library changes — but it *is* outward:
    /// it leaves this process and puts another application in front of the user,
    /// so it is same-origin gated like every other POST, and gated on Photos
    /// access because PhotoKit is what resolves the asset and its library uuid.
    ///
    /// The identifier is validated against the cache exactly as everywhere else,
    /// so a caller can only ever name an asset this instance has actually seen.
    private func reveal(_ request: HTTPRequest) async -> RouteResult {
        if let refusal = Self.crossOriginRefusal(for: request) { return .response(refusal) }
        if let refusal = photosAccessRefusal() { return .response(refusal) }
        guard let spec = try? JSONDecoder().decode(RevealSpec.self, from: request.body) else {
            return .response(.error("malformed reveal request", status: 400))
        }
        guard let identifier = spec.id, !identifier.isEmpty else {
            return .response(.error("the reveal needs exactly one asset identifier in \"id\"", status: 400))
        }
        guard (try? await cache.photo(identifier: identifier)) != nil else {
            return .response(.error("unknown asset", status: 404))
        }
        do {
            let outcome = try await library.revealInPhotos(identifier: identifier)
            return .response(.json(RevealResponse(
                ok: true,
                mechanism: outcome.mechanism.rawValue,
                requested: 1,
                opened: outcome.opened,
                id: identifier,
                message: outcome.message)))
        } catch let error as RevealError {
            // Logged because an undocumented URL that stops working is the single
            // thing most likely to break this route, and the log is the only place
            // that will show it.
            Log.warn("reveal failed (\(error.description))")
            return .response(.error(error.description, status: error.status))
        } catch {
            Log.error("reveal failed: \(error.localizedDescription)")
            return .response(.error("could not hand the photo to Photos: \(error)", status: 500))
        }
    }

    // MARK: - Request gates

    /// Same-origin check for the routes that mutate state.
    ///
    /// A loopback listener is not access control: any page the user visits can
    /// send a *simple* cross-origin `POST` (`text/plain` needs no preflight, so
    /// the request really is delivered) at `http://127.0.0.1:<port>`, and
    /// `mode: "matching"` needs no identifiers at all. Browsers always attach
    /// `Sec-Fetch-Site` — a forbidden header name, so script cannot forge it —
    /// and the Fetch specification requires `Origin` on every non-GET/HEAD
    /// request, so requiring one of them to be same-origin closes that hole.
    ///
    /// A request carrying *neither* header cannot have come from a browser — it
    /// is curl, a script or a native client — and is allowed through, because
    /// refusing it would break the documented JSON API for no security gain.
    private static func crossOriginRefusal(for request: HTTPRequest) -> HTTPResponse? {
        let refusal = HTTPResponse.error("cross-site requests are refused on \(request.rawPath)", status: 403)
        if let site = request.header("sec-fetch-site")?.lowercased() {
            return (site == "same-origin" || site == "none") ? nil : refusal
        }
        if let origin = request.header("origin")?.lowercased() {
            // `Origin: null` (a sandboxed iframe, a `file://` document) matches
            // nothing and is refused, which is the correct answer for both.
            guard let host = request.header("host")?.lowercased(), origin == "http://" + host else {
                return refusal
            }
        }
        return nil
    }

    /// Refuses a Photos-dependent mutation when access is not granted.
    ///
    /// `limited` is allowed: PhotoKit only ever enumerates the granted subset, so
    /// neither the cache nor `known()` can name an asset outside it — limited
    /// access cannot widen a selection, only narrow it. `denied`, `restricted` and
    /// `notDetermined` mean anything the tool still remembers about the library
    /// is unverifiable, so nothing is selected and nothing is destroyed.
    /// 403 when Photos access is absent, so no route can act on a library the app
    /// is not allowed to read. An instance method because the status is injectable;
    /// see `authorizationStatus`.
    private func photosAccessRefusal() -> HTTPResponse? {
        let status = authorizationStatus()
        guard PhotoLibrary.hasReadAccess(status) else {
            return .error("Photos access is not authorized (\(PhotoLibrary.authorizationDescription(status))); "
                          + "nothing was changed", status: 403)
        }
        return nil
    }

    // MARK: - Settings

    private struct SettingsPayload: Decodable {
        var downloadFromICloud: Bool?
        var protectFavorites: Bool?
        var concurrency: Int?
        // The Similar Group knobs. Optional individually, so a client can move one
        // without resending the rest — and all clamped by `validated()` below.
        var groupWindowSeconds: Double?
        var groupMaxDistance: Float?
        var groupFaceWeight: Float?
        var groupMinimumFaceArea: Float?
        var groupMaximumSize: Int?
    }

    private func updateSettings(_ request: HTTPRequest) async -> RouteResult {
        // Preference changes are mutating too: `protectFavorites: false` is the
        // one setting that weakens a safety rail, so the same-origin gate applies
        // here. Deliberately *not* gated on Photos authorization — refusing to
        // change preferences would strand a user whose access was revoked, and
        // `protectFavorites` in particular must stay settable at any time.
        if let refusal = Self.crossOriginRefusal(for: request) { return .response(refusal) }
        guard let payload = try? JSONDecoder().decode(SettingsPayload.self, from: request.body) else {
            return .response(.error("malformed settings", status: 400))
        }
        let previous = settings.snapshot()
        let updated = settings.update { current in
            if let value = payload.downloadFromICloud { current.downloadFromICloud = value }
            if let value = payload.protectFavorites { current.protectFavorites = value }
            if let value = payload.concurrency { current.analysisConcurrency = value }
            if let value = payload.groupWindowSeconds { current.groupWindowSeconds = value }
            if let value = payload.groupMaxDistance { current.groupMaxDistance = value }
            if let value = payload.groupFaceWeight { current.groupFaceWeight = value }
            if let value = payload.groupMinimumFaceArea { current.groupMinimumFaceArea = value }
            if let value = payload.groupMaximumSize { current.groupMaximumSize = value }
        }

        // Leave a trail for the one setting that weakens a safety rail, so
        // "why did that favourite go?" can be answered from the log.
        if previous.protectFavorites != updated.protectFavorites {
            Log.info("favourite protection turned \(updated.protectFavorites ? "ON" : "OFF")")
        }

        // Changing a grouping parameter invalidates the stored groups: they were
        // built under other rules, so serving them unchanged would show the user
        // groups produced by settings they no longer hold. Rebuild now rather than
        // marking them stale and leaving the old answer on screen.
        if previous.similarGroups != updated.similarGroups {
            Log.info("similar group settings changed; rebuilding")
            await groupEngine.rebuild(reason: "settings changed")
        }

        if !previous.downloadFromICloud, updated.downloadFromICloud {
            // Assets skipped as "not on this Mac" become eligible again.
            let requeued = (try? await cache.requeueUnavailable()) ?? 0
            Log.info("iCloud downloads enabled; \(requeued) assets re-queued")
            await engine.start()
        }
        await engine.publishStatus(force: true)
        return .response(.json(await engine.status()))
    }

    // MARK: - Helpers

    private static func filter(from request: HTTPRequest, bounds: (min: Float, max: Float)) -> PhotoFilter {
        PhotoFilter(
            lower: request.queryFloat("lo") ?? bounds.min,
            upper: request.queryFloat("hi") ?? bounds.max,
            favorites: FavoriteFilter(rawValue: request.queryValue("favorites") ?? "") ?? .include
        )
    }

    /// Reads and validates `?album=` from a browsing request.
    ///
    /// Absent or empty means `.all`. An album identifier is only accepted if this
    /// instance has indexed it; anything else is a 400 naming the problem, because
    /// treating an unknown album as "no filter" would silently show the whole
    /// library under a title the user believes is an album.
    private func resolveAlbumSelection(_ request: HTTPRequest) async -> AlbumResolution {
        guard let raw = request.queryValue("album"), !raw.isEmpty else {
            return .resolved(.all)
        }
        let selection: AlbumSelection
        do {
            selection = try AlbumSelection.parse(raw)
        } catch {
            return .refused(.error("unknown album \"\(raw)\"; expected \"all\", \"none\", or an album identifier",
                                   status: 400))
        }
        if let identifier = selection.albumIdentifier {
            let indexed = (try? await cache.knownAlbums([identifier]))?.contains(identifier) ?? false
            guard indexed else {
                return .refused(.error("this album is not one PhotoCleaner has read; refresh the album list, "
                                       + "or use \"none\" for photos that are in no album", status: 400))
            }
        }
        return .resolved(selection)
    }

    /// Either an album selection the server will apply, or the refusal to apply
    /// one. A separate type from `Result` because `HTTPResponse` is not an `Error`
    /// and is not going to become one.
    private enum AlbumResolution {
        case resolved(AlbumSelection)
        case refused(HTTPResponse)
    }

    // MARK: - Albums

    private struct AlbumEntry: Encodable {
        let id: String
        let title: String
        /// How many of *this instance's* assets are in the album. Not Photos'
        /// estimate: that counts the whole library, so it would disagree with the
        /// number of tiles the filter actually yields.
        let count: Int
        let indexedAt: Double?
    }

    private struct AlbumsResponse: Encodable {
        let albums: [AlbumEntry]
        /// Photos in no indexed album. Always present — a library can legitimately
        /// have none, and `0` is a real answer.
        let unassigned: Int
        /// True once every album Photos reports has been read. While it is false,
        /// `albums` is a partial list and `unassigned` is a lower bound; the client
        /// is told rather than left to infer completeness from a count.
        let indexComplete: Bool
        /// True while a pass is running.
        let indexing: Bool
        let indexedAlbums: Int
        let totalAlbums: Int
        let currentAlbum: String?
        let lastError: String?
        /// Photos' own smart albums, named but **not** filterable.
        ///
        /// Present so the UI can explain the gap — "Recents", "Favorites",
        /// "Panoramas" and "Screenshots" are computed collections, not membership
        /// anyone created, so PhotoCleaner does not index them (see
        /// `PhotoLibrary.userAlbums`). Omitting them entirely would leave a user
        /// looking for an album they can see in Photos and unable to find why.
        let smartAlbums: [String]
        /// The message the UI shows when smart albums exist but are not offered.
        let smartAlbumsNote: String?
    }

    private func albums(_ request: HTTPRequest) async -> RouteResult {
        if let refusal = photosAccessRefusal() { return .response(refusal) }
        // Read-only: no body, no state, nothing a cross-site page can disturb, so
        // no same-origin gate (same reasoning as the timeline routes).
        await albumIndex.refreshIfNeeded()
        let summaries = (try? await cache.albums()) ?? []
        let status = await albumIndex.status()
        let photosAlbumCount = library.userAlbumCount()
        let complete = (try? await cache.albumIndexComplete(photosAlbumCount: photosAlbumCount)) ?? false
        let smart = Self.smartAlbumTitles()
        return .response(.json(AlbumsResponse(
            albums: summaries.map {
                AlbumEntry(id: $0.identifier, title: $0.title, count: $0.assetCount, indexedAt: $0.indexedAt)
            },
            unassigned: (try? await cache.unassignedCount()) ?? 0,
            indexComplete: complete,
            indexing: status.indexing,
            indexedAlbums: status.indexed,
            totalAlbums: max(photosAlbumCount, status.total),
            currentAlbum: status.current,
            lastError: status.lastError,
            smartAlbums: smart,
            smartAlbumsNote: smart.isEmpty ? nil
                : "Photos computes these from the photos themselves; they are not albums you can add to, "
                + "so PhotoCleaner filters by your own albums only.")))
    }

    /// Names Photos' automatic albums, read-only through PhotoKit.
    ///
    /// Called on demand rather than stored: they are not filterable, so there is
    /// nothing to cache, and the fetch is one counted enumeration.
    private static func smartAlbumTitles() -> [String] {
        let result = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                             subtype: .any, options: nil)
        var titles: [String] = []
        result.enumerateObjects { collection, _, _ in
            if let title = collection.localizedTitle, !title.isEmpty { titles.append(title) }
        }
        return titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func reindexAlbums(_ request: HTTPRequest) async -> RouteResult {
        // Same-origin gated for the same reason as the other mutating routes: this
        // writes to the cache in the background, so a cross-site page could make
        // it do tens of thousands of writes.
        if let refusal = Self.crossOriginRefusal(for: request) { return .response(refusal) }
        if let refusal = photosAccessRefusal() { return .response(refusal) }
        await albumIndex.refreshNow()
        return .response(.json(SimpleMessage(ok: true, message: "reading album membership")))
    }

    // MARK: - Favourites

    /// Wire format for `POST /api/favorites`.
    ///
    /// `ids` is required and must be an array; `favorite` is required and must be
    /// a boolean. Both are mandatory rather than defaulted because the whole point
    /// of the route is that it *writes*: defaulting `favorite` to `true` would
    /// silently protect something the user asked to unprotect, and defaulting it to
    /// `false` would silently remove protection. Either default is a real
    /// surprise, so a missing key is a 400.
    private struct FavoriteSpec: Decodable {
        var ids: [String]?
        var favorite: Bool?
    }

    /// One report shape for every outcome, so `/api/favorites` always says what was
    /// asked for, what PhotoKit actually reports now, and what went wrong.
    private struct FavoriteReport: Encodable {
        /// Distinct identifiers in the request.
        var requested = 0
        /// How many of them this instance has actually scanned and will act on.
        var resolved = 0
        /// The state the request asked for.
        var favorite = false
        /// Assets PhotoKit now reports as favourites matching `favorite`. The
        /// number that matters: it is read back from the library, never assumed
        /// from the request.
        var confirmed = 0
        /// Of those, how many actually changed state as a result of this request
        /// (an asset that was already a favourite is confirmed but unchanged).
        var changed = 0
        /// Rows written to the cache. Can be lower than `confirmed` if the cache
        /// write failed, and that is reported rather than hidden.
        var cacheUpdated = 0
        /// Identifiers in the request that this instance has never scanned.
        var unknownIdentifiers = 0
        /// Identifiers that are no longer in Photos at all.
        var missing = 0
        /// Assets that exist but are not still images.
        var skippedNonImages = 0
        /// One message per chunk PhotoKit refused, naming the batch size.
        var errors: [String] = []
    }

    /// Sets or clears the favourite flag. A real write to the library, so it is
    /// gated exactly like deletion.
    ///
    /// Why it is a write and not a "local preference": `favorite` is a Photos
    /// attribute, it syncs to the user's other devices, and it is the flag
    /// `PhotoLibrary.delete` re-reads live. Recording it only in PhotoCleaner's
    /// cache would make the tool's idea of protection disagree with the library's,
    /// which is the one disagreement that must not exist.
    private func favorites(_ request: HTTPRequest) async -> RouteResult {
        if let refusal = Self.crossOriginRefusal(for: request) { return .response(refusal) }
        if let refusal = photosAccessRefusal() { return .response(refusal) }
        guard let spec = try? JSONDecoder().decode(FavoriteSpec.self, from: request.body) else {
            return .response(.error("malformed favourite request", status: 400))
        }
        guard let favorite = spec.favorite else {
            return .response(.error("a favourite change must state \"favorite\": true or false", status: 400))
        }
        guard let requested = spec.ids else {
            return .response(.error("a favourite change must name the assets: {\"ids\":[...],\"favorite\":bool}",
                                    status: 400))
        }

        var report = FavoriteReport(favorite: favorite)
        var distinct = Set<String>()
        let unique = requested.filter { distinct.insert($0).inserted }
        report.requested = unique.count
        guard !unique.isEmpty else {
            return .response(.json(report))
        }

        // Identifiers are validated against the cache exactly as on the delete
        // path, so a request can only ever touch assets this instance has seen.
        let known = (try? await cache.known(identifiers: unique)) ?? []
        report.resolved = known.count
        report.unknownIdentifiers = max(0, unique.count - known.count)
        guard !known.isEmpty else {
            Log.warn("favourite request named \(report.unknownIdentifiers) unknown identifiers; nothing was changed")
            return .response(.json(report))
        }

        Log.info("setting favorite=\(favorite) on \(known.count) assets through PhotoKit")
        let outcome = await library.setFavorite(identifiers: known, favorite: favorite)
        report.missing = outcome.missing
        report.skippedNonImages = outcome.skippedNonImages
        report.errors = outcome.failedMessages

        // Partition by what PhotoKit *reports*, not by what was requested. An asset
        // whose flag PhotoKit did not move is recorded with the value it actually
        // has, so the cache can never claim protection the library is not granting.
        var nowFavorite: [String] = []
        var nowNotFavorite: [String] = []
        for (identifier, isFavorite) in outcome.confirmed {
            if isFavorite { nowFavorite.append(identifier) } else { nowNotFavorite.append(identifier) }
            if isFavorite == favorite { report.confirmed += 1 }
        }
        // "Changed" is relative to the state this instance last recorded, which is
        // the only "before" available — and the honest one, since that is the state
        // the user has been looking at.
        let cachedFavorites = (try? await cache.partitionFavorites(identifiers: known))?.favorites ?? []
        let wasFavorite = Set(cachedFavorites)
        for identifier in nowFavorite where favorite && !wasFavorite.contains(identifier) {
            report.changed += 1
        }
        for identifier in nowNotFavorite where !favorite && wasFavorite.contains(identifier) {
            report.changed += 1
        }

        // Write the confirmed state through. Two updates, in one go per direction,
        // so a photo Photos did not move keeps the value it has.
        if !nowFavorite.isEmpty {
            report.cacheUpdated += (try? await cache.setFavorite(true, identifiers: nowFavorite)) ?? 0
        }
        if !nowNotFavorite.isEmpty {
            report.cacheUpdated += (try? await cache.setFavorite(false, identifiers: nowNotFavorite)) ?? 0
        }
        if report.cacheUpdated < nowFavorite.count + nowNotFavorite.count {
            report.errors.append("the library has the change, but PhotoCleaner's cache could not record "
                                 + "every one of it; it will be reconciled on the next scan")
        }
        await engine.publishStatus(force: true)

        // A partial success is reported as exactly what it is. `confirmed` says how
        // many hold the requested state, `changed` how many moved, and `errors`
        // names each refused chunk with its size — so "3 of 5" can never read as
        // "5 of 5". If nothing at all happened and something was asked for, the
        // status says the server could not do it.
        if report.confirmed == 0, !report.errors.isEmpty {
            return .response(.json(report, status: 500))
        }
        return .response(.json(report))
    }
}

private struct SimpleMessage: Encodable {
    let ok: Bool
    let message: String
}
