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
    /// Video-specific PhotoKit work: export, frame decoding, the export cache.
    ///
    /// Injected rather than reached through `library` because `PhotoLibrary` is the
    /// *image* path and every AVFoundation call is meant to live in `VideoLibrary`
    /// (see that file's doc comment). Optional so the existing construction sites —
    /// the test fixture included — keep compiling without naming it; the default is
    /// `VideoLibrary.shared`, the same instance the scan reaches for, because two
    /// instances would mean two views of one on-disk export cache and its eviction
    /// bound enforced twice against the same directory.
    let videos: VideoLibrary

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
         videos: VideoLibrary? = nil,
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
        self.videos = videos ?? VideoLibrary.shared
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
           last == "thumbnail" || last == "preview" || last == "similar" || last == "video" {
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
        case "video":
            // `video`, not `play`/`stream`: the route serves bytes, and a name that
            // said what it did would invite a future caller to expect a transcoded
            // or re-muxed stream from it. On first play of an uncached clip it
            // re-muxes to fMP4 on the fly; thereafter it is a byte range of the
            // passthrough export.
            return await video(identifier: identifier, request: request)
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
            /// Which media types the page contains: `all`, `images` or `videos`.
            /// Echoed for the same reason as `album`, and it matters more here: the
            /// dimension was added later than the client that reads this echo, and a
            /// client that assumes the field is there when it is not would render a
            /// videos-only grid without one badge. Absent means nothing is filtered,
            /// which is exactly what an older server meant.
            let media: String
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
        // The media dimension is resolved through the same refuse-or-apply shape as
        // the album, and for the same reason: `?media=vidoes` must not quietly mean
        // "all" on a grid the user believes holds only clips.
        let media: MediaSelection
        switch resolveMediaSelection(request) {
        case .refused(let response): return .response(response)
        case .resolved(let selection): media = selection
        }
        var filter = base
        filter.album = album
        filter.media = media

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
                              media: media.wireValue,
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

    /// `GET /api/photo/{id}` — one cached row, and the albums it is in.
    ///
    /// The albums are here because of a lie the preview used to tell. `/api/photos`
    /// sends album names for the rows of *one page* (`filter.albums`), which is enough
    /// for a tile's tooltip and not enough for the preview's Albums row: that row is a
    /// claim about one photograph, and a client-side map of page-scoped answers says
    /// "in no album" for every photograph it never happened to load — including ones
    /// whose page was rendered before the album index had read their membership.
    ///
    /// So this is the indexed read the preview asks for when it opens one: `asset_albums`
    /// probed by asset, joined to `albums` for the titles. An empty list means the table
    /// has no membership row for it, which the client must *not* read on its own as "in no
    /// album" — it does that only once the index is complete, and the album list route
    /// says when that is.
    private func photo(identifier: String) async -> RouteResult {
        guard let row = try? await cache.photo(identifier: identifier) else {
            return .response(.error("unknown asset", status: 404))
        }
        // The same `{id, title}` tags the page response carries, from the same cache
        // read, so the preview and the grid cannot disagree about an album's name.
        let membership = (try? await cache.albumMembership(for: [identifier]))?[identifier] ?? []
        let tags = membership.map { PhotosResponse.AlbumTag(id: $0.identifier, title: $0.title) }
        struct Response: Encodable {
            let photo: PhotoRow
            let albums: [PhotosResponse.AlbumTag]
        }
        return .response(.json(Response(photo: row, albums: tags)))
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
    ///
    /// **`?media=` is deliberately not read here either, and the two timeline routes
    /// are the only browsing routes that do not take it.** The invariant these routes
    /// exist to keep is that the chronology cannot be narrowed: "All Photos" is the
    /// user's *whole* library in date order, and a photo shown there must not depend
    /// on which filter chip happened to be selected in the grid. Adding a media
    /// dimension to one of the two keyset walks — and the two walks are exact
    /// complements of each other, so a filter applied to one but not the other would
    /// put the anchor in a gap — would break that. It would also make the same token
    /// mean different things on the two routes, which is the failure
    /// `PhotoFilter.paginationFingerprint` exists to prevent, and it would have to be
    /// solved by pinning the media dimension in the fingerprint too, i.e. by making
    /// the fingerprint carry a filter that is never applied.
    ///
    /// Nothing is lost by this. Videos are scored assets, so they are in `assets`,
    /// and they appear in All Photos automatically with their dates in the right
    /// places. The media filter is a *narrowing* control; the timeline is not
    /// narrowable.
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
        /// `all`, `images` or `videos`. Absent means `.all`.
        ///
        /// **Load-bearing, not politeness.** This is the same argument as `album`,
        /// one dimension newer and with a sharper edge. "Select all matching"
        /// snapshots the filter the user is looking at; a snapshot missing the media
        /// dimension resolves to *every* photo and video on a grid that is showing
        /// only photos — so the confirmation dialog would count a library's worth of
        /// clips the user never saw, and the deletion would then be authorised
        /// against that count. The selection is only safe if the dimension the user
        /// filtered by is part of what it pins.
        var media: String?

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
            // Same rule as `favorites`, one step sharper: substituting `.all` for an
            // unrecognised media value would *add* every video on the machine to a
            // selection the user took believing the grid held only photos, and the
            // alternative that looks safer — substituting `.images` — is no better,
            // because it silently drops rows. A typo must be an error.
            if let media, MediaSelection(rawValue: media) == nil {
                throw SelectionError.invalidFilter(
                    "unknown media filter \"\(media)\"; expected \"all\", \"images\" or \"videos\"")
            }
            var filter = PhotoFilter(
                lower: lo,
                upper: hi,
                favorites: FavoriteFilter(rawValue: favorites ?? "") ?? .include
            )
            if let album {
                filter.album = try AlbumSelection.parse(album)
            }
            if let media, let selection = MediaSelection(rawValue: media) {
                filter.media = selection
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
                // Drop each deleted asset's exported video from the disk cache. The
                // cache is bounded (see `VideoLibrary`), so a deleted clip's export
                // would eventually be reclaimed by eviction pressure — but only
                // pressure. Without this, a user who deletes their worst clips
                // frees no space at all until the directory happens to fill, and
                // the directory is on the same volume as the library being
                // tidied. `evict` is a no-op for an asset that has no export, which
                // is every still and every clip never played.
                //
                // Best-effort, like the cache write above it: a failed eviction
                // leaves a file the bounded cache will still collect, so it is not
                // worth failing a completed deletion over — that deletion has
                // already happened in Photos and cannot be taken back.
                for identifier in outcome.deletedIdentifiers {
                    videos.evict(identifier: identifier)
                }
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
        // Same filter, same validation, as the grid: a group list built from the whole
        // library while the user is looking at photos-only is the same silent
        // widening the album dimension refuses. In practice this yields the unfiltered
        // list under `images` and an empty one under `videos`, because videos are
        // never group members — a deliberate exclusion, not a gap.
        let media: MediaSelection
        switch resolveMediaSelection(request) {
        case .refused(let response): return .response(response)
        case .resolved(let selection): media = selection
        }
        await groupEngine.rebuildIfNeeded()
        let order = Self.groupRankOrder(from: request)
        let limit = request.queryInt("limit", default: 24, range: 1...100) ?? 24
        let offset = request.queryInt("offset", default: 0, range: 0...1_000_000) ?? 0
        do {
            let page = try await cache.groupSummaries(limit: limit, offset: offset,
                                                     album: album, media: media)
            let config = settings.snapshot().similarGroups
            var rows: [SimilarGroupRow] = []
            for summary in page.groups {
                rows.append(await groupRow(summary: summary, order: order, config: config,
                                        memberLimit: Self.maxGroupMembers,
                                        album: album, media: media))
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
        let media: MediaSelection
        switch resolveMediaSelection(request) {
        case .refused(let response): return .response(response)
        case .resolved(let selection): media = selection
        }
        do {
            guard let summary = try await cache.groupSummary(id: id) else {
                return .response(.error("unknown group", status: 404))
            }
            let row = await groupRow(summary: summary,
                                   order: Self.groupRankOrder(from: request),
                                   config: settings.snapshot().similarGroups,
                                   memberLimit: Self.maxGroupMembers,
                                   album: album, media: media)
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
    /// An unrecognised value *defaults* rather than being refused, which is the
    /// opposite of `TimelineDirection` and `FilterPayload.resolved`, and
    /// deliberately so: this is the one closed enum on a route where guessing
    /// cannot mislead. A wrong `direction` or `favorites` would resolve a
    /// different set of photos than the one asked for, but a wrong `order` only
    /// re-ranks the group that was already selected, and the response reports
    /// what it did in `ranked` — so the browser labels the strip from the
    /// server's answer rather than from the one it sent.
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
                          album: AlbumSelection = .all,
                          media: MediaSelection = .all) async -> SimilarGroupRow {
        let inputs = (try? await cache.rankingInputs(groupID: summary.id, limit: memberLimit,
                                                     album: album, media: media)) ?? []

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
        // Recounted under *either* filter, not just the album. `album != .all` alone
        // would leave the stored counts in place under `media`, which is fine today
        // (no video is ever a member, so nothing is hidden) and wrong the day one is —
        // a count that says "6 photos" above a strip of 4 with no explanation.
        if album != .all || media != .all,
           let kept = try? await cache.groupMembers(groupID: summary.id, album: album, media: media) {
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

    // MARK: - Video

    /// `GET /api/photo/{id}/video` — a playable file for a video, with byte ranges.
    ///
    /// The only route whose body is not produced by this process, and the only one
    /// that can be tens of thousands of times larger than any other response. Three
    /// things about it are load-bearing:
    ///
    /// 1. **The identifier is validated before any PhotoKit call.** Not only against
    ///    the cache — the cached row must also say this asset is a *video*. The two
    ///    checks are separate because they answer different questions: "is this an
    ///    asset this instance has scanned" is the invariant every route here upholds,
    ///    and "is it the right *kind* of thing" is specific to this route. A crafted
    ///    identifier naming a photo, or naming nothing at all, must not reach
    ///    `VideoLibrary`: that call is the most expensive one in the app (it can
    ///    export a multi-gigabyte clip), so an unauthenticated-in-spirit probe should
    ///    not be able to trigger one, and the error the client gets for a still must
    ///    be the same 404 a photo gets from `photo(identifier:)` rather than
    ///    something that says "that exists, but not here".
    /// 2. **`allowNetwork` comes from the user's iCloud preference**, never from the
    ///    request. A query parameter that could turn a download on would let any page
    ///    that reached the loopback port pull an iCloud library down to disk; the
    ///    preference is the only input, and it defaults off.
    /// 3. **The response is a byte range of a file**, handed to `HTTPConnection` as
    ///    `.file`, which streams it. Nothing here reads the clip: `HTTPResponse.body`
    ///    is `Data`, and a 2 GB `Data` is the failure this design exists to avoid.

    /// `Range` needs the file's length before it can be resolved, so this is read
    /// from the exported file rather than from a cache column. It is a `stat` on a
    /// file that was just written, so it is the same number the bytes are.
    ///
    /// Zero on a failed `stat` rather than a thrown error: a clip whose length cannot
    /// be read is not worth a `500` from a route the client has no alternative to, and
    /// zero degrades to "this file is empty" — a `200` with no body, or a `416` for
    /// every range. Both are answers a media element can act on, and both are honest
    /// about what is actually known.
    private static func byteLength(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Content type from the exported file's extension.
    ///
    /// **Not sniffed.** Reading the first bytes to decide would mean a file read on
    /// every response for an answer the extension already gives, and — worse — a
    /// server that reports a type derived from content is one whose answer can
    /// disagree with what the file is, which is the situation `nosniff` exists to
    /// contain. Photos reports the original's extension, and passthrough export keeps
    /// it, so the extension is authoritative.
    ///
    /// `.m4v`, `.m4a`-style variants are deliberately not special-cased: they are
    /// QuickTime containers too, and an unlisted extension falls through to
    /// `application/octet-stream`, which a `<video>` element will decline rather than
    /// mis-play.
    private static func videoContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    private func video(identifier: String, request: HTTPRequest) async -> RouteResult {
        // Gated on Photos authorization, unlike `thumbnail`/`preview`. Those read a
        // frame and fail closed on their own — no frame, no bytes — while this route
        // exports a clip through PhotoKit and would happily produce one from whatever
        // access remains. The group routes gate for the same reason: what they answer
        // is a claim about the user's library, and a claim PhotoCleaner can no longer
        // verify is not one it should make.
        if let refusal = photosAccessRefusal() { return .response(refusal) }
        // The gate, in full, before any PhotoKit call. Two reads rather than one
        // because they answer two questions: `known()` is this instance's own
        // membership test — the same one the delete and favourite paths run, and the
        // invariant every route on this router upholds — and the cached row says what
        // kind of asset it is. Neither is asked of PhotoKit: a `PHAsset` fetch to
        // learn "is this a video" would be the expensive call the gate exists to
        // avoid, and it would answer a question the cache already holds the answer
        // to. The second read is an exact primary-key lookup, and the whole thing
        // costs less than the export that follows it by three orders of magnitude.
        //
        // One 404 for all three refusals — unknown identifier, not a video, and not a
        // row at all — because a caller learns nothing useful from being told which
        // of those it hit, and "that exists, but not here" would be an oracle.
        let known = (try? await cache.known(identifiers: [identifier])) ?? []
        guard known.contains(identifier),
              let row = try? await cache.photo(identifier: identifier),
              row.mediaType == PHAssetMediaType.video.rawValue else {
            return .response(.error("unknown asset", status: 404))
        }

        let allowNetwork = settings.snapshot().downloadFromICloud

        // Check for Range header. For initial playback (no Range or bytes=0-),
        // check if there's a cached export first. If cached, serve from file
        // (supports precise byte ranges). If not cached, use fMP4 streaming for
        // instant start without waiting for full export. For seeking (other ranges),
        // always use cached export file.
        let rangeHeader = request.header("range")
        let isInitialPlayback = rangeHeader == nil || rangeHeader == "bytes=0-"

        // Check if there's already a cached export (fast path for cached videos)
        let cachedSize = videos.cachedByteCount(identifier: identifier)
        let hasCachedFile = cachedSize != nil && cachedSize! > 0

        if isInitialPlayback && !hasCachedFile {
            // No cached export — stream via fMP4 for instant start.
            // Do NOT advertise Accept-Ranges: the stream is generated on-the-fly
            // and cannot be seeked. Once cached, the file path handles ranges.
            let videoStream = HTTPVideoStream(
                status: 200,
                headers: ["Content-Type": "video/mp4"],
                identifier: identifier,
                allowNetwork: allowNetwork,
                rangeStart: nil,
                rangeLength: nil
            )
            return .videoStream(videoStream)
        }

        // Either cached file exists, or this is a seeking request (Range other than bytes=0-)
        // Use cached export file which supports precise byte-range serving
        let url: URL
        do {
            url = try await videos.exportedFile(identifier: identifier, allowNetwork: allowNetwork)
        } catch PhotoLibraryError.imageNotLocal {
            return .response(.error(
                "this clip is stored in iCloud only; turn on \"Download from iCloud\" in Settings "
                + "and try again", status: 409))
        } catch let error as PhotoLibraryError {
            return .response(.error("\(error)", status: 404))
        } catch {
            return .response(.error("could not export that clip: \(error)", status: 500))
        }

        let size = Self.byteLength(of: url)
        let range = HTTPRange.resolve(header: rangeHeader, fileSize: size)
        switch range {
        case .unsatisfiable:
            var response = HTTPResponse.error(
                "that byte range is past the end of this clip (\(size) bytes)", status: 416)
            if let value = range.contentRangeHeader(fileSize: size) {
                response.headers["Content-Range"] = value
            }
            return .response(response)
        case .whole(let length):
            var headers = Self.videoHeaders(for: url)
            headers["Accept-Ranges"] = "bytes"
            return .file(HTTPFile(status: 200, headers: headers, url: url,
                                   start: 0, length: length))
        case .partial(let start, let length):
            var headers = Self.videoHeaders(for: url)
            headers["Accept-Ranges"] = "bytes"
            if let value = range.contentRangeHeader(fileSize: size) {
                headers["Content-Range"] = value
            }
            return .file(HTTPFile(status: 206, headers: headers, url: url,
                                  start: start, length: length))
        }
    }

    private static func videoHeaders(for url: URL) -> [String: String] {
        // `private, max-age=3600` rather than the `no-store` every JSON route carries:
        // the bytes are immutable once exported and the export is itself cached on
        // disk, so a re-fetch costs a `stat` and nothing else — while `no-store` would
        // forbid the client from keeping the ranges it has already pulled, which is
        // how a scrub bar works. `private` because this is a user's own library being
        // served off loopback and nothing else may hold it.
        ["Content-Type": videoContentType(for: url),
         "Cache-Control": "private, max-age=3600"]
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
        // Present only so a client that still sends the old switch gets a refusal
        // rather than silence. There is no `false` to apply: see `updateSettings`.
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
        // Preference changes are mutating, so the same-origin gate applies here.
        // Deliberately *not* gated on Photos authorization — refusing to change
        // preferences would strand a user whose access was revoked.
        if let refusal = Self.crossOriginRefusal(for: request) { return .response(refusal) }
        guard let payload = try? JSONDecoder().decode(SettingsPayload.self, from: request.body) else {
            return .response(.error("malformed settings", status: 400))
        }
        // Favourite protection is not a preference, so a request to turn it off is
        // refused outright rather than quietly ignored. Silently ignoring it would
        // leave a stale client reporting success and a stale checkbox drawn as
        // unchecked, which is a false account of what will happen to favourites.
        if payload.protectFavorites == false {
            Log.warn("refused a request to disable favourite protection")
            return .response(.error("favorites are always protected and cannot be turned off", status: 400))
        }
        let previous = settings.snapshot()
        let updated = settings.update { current in
            if let value = payload.downloadFromICloud { current.downloadFromICloud = value }
            if let value = payload.concurrency { current.analysisConcurrency = value }
            if let value = payload.groupWindowSeconds { current.groupWindowSeconds = value }
            if let value = payload.groupMaxDistance { current.groupMaxDistance = value }
            if let value = payload.groupFaceWeight { current.groupFaceWeight = value }
            if let value = payload.groupMinimumFaceArea { current.groupMinimumFaceArea = value }
            if let value = payload.groupMaximumSize { current.groupMaximumSize = value }
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

    /// `?media=`, resolved the same way and with the same reasoning as `?album=`.
    ///
    /// Absent or empty means `.all`. Anything else must name one of the three values
    /// `MediaSelection` defines; an unrecognised string is a 400 that names them,
    /// never a silent fall back to `all`.
    ///
    /// The failure that motivates that is the same one `resolveAlbumSelection`
    /// documents, and it is worth being concrete about why the media case is *worse*
    /// rather than merely equal: a client that sent `?media=videos` and was quietly
    /// answered with the unfiltered grid would render a page containing every photo in
    /// the library under a "Videos" heading. A user deleting from that page would be
    /// deleting photos while looking at what they believe is a list of clips, and
    /// every confirmation count in between would be true — of the wrong set.
    ///
    /// There is no `knownAlbums`-style validation step after the parse: the three
    /// values are a closed set rather than identifiers, so there is nothing a caller
    /// could name that this instance has not heard of. That is also why this is
    /// **synchronous** where `resolveAlbumSelection` is not — the album's second step
    /// is an awaited cache read, and there is no such step here to await. The shape
    /// is otherwise deliberately the same, including the return type, so a reader who
    /// knows one knows the other.
    private func resolveMediaSelection(_ request: HTTPRequest) -> MediaResolution {
        guard let raw = request.queryValue("media"), !raw.isEmpty else {
            return .resolved(.all)
        }
        guard let selection = MediaSelection(rawValue: raw) else {
            return .refused(.error("unknown media filter \"\(raw)\"; "
                                   + "expected \"all\", \"images\" or \"videos\"", status: 400))
        }
        return .resolved(selection)
    }

    /// Either a media selection the server will apply, or the refusal to apply one.
    private enum MediaResolution {
        case resolved(MediaSelection)
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
