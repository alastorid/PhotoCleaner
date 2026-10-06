import Foundation

/// Lifecycle of one asset in the score cache. Persisted verbatim as `TEXT`.
enum AnalysisState: String, Sendable, Codable {
    case pending
    case analyzing
    case done
    case failed
    /// The pixels are not on this Mac and the user has not allowed iCloud
    /// downloads. Not an error: it is the conservative default behaviour.
    case unavailable
}

/// One asset as produced by a library walk. Contains everything the cache needs
/// to reconcile itself with Photos; no score, no image data.
struct ScanRecord: Sendable {
    let identifier: String
    let mediaType: Int
    let creationDate: Double?
    let modificationDate: Double?
    let width: Int
    let height: Int
    let favorite: Bool
    let mediaSubtype: Int
    let isScreenshot: Bool
}

/// One cached asset as served to the UI.
struct PhotoRow: Sendable, Codable, Equatable {
    let id: String
    let score: Float
    let date: Double?
    let width: Int
    let height: Int
    let favorite: Bool
}

enum FavoriteFilter: String, Sendable, Codable {
    case include
    case exclude
    case only
}

/// Which album, if any, the grid is scoped to.
///
/// Album membership in Photos is **many-to-many and possibly empty**: one asset
/// can be in several user albums at once and can be in none. The three cases
/// below are the only ones that can be expressed honestly:
///
/// - `.all` — no album constraint at all (the default).
/// - `.unassigned` — *only* assets that are in no indexed user album. This is a
///   first-class bucket, not a leftover: without it those photos would be
///   unreachable from any album view.
/// - `.album(String)` — one album, named by its PhotoKit
///   `PHAssetCollection.localIdentifier`, which is what the cache stores.
///
/// **Smart albums are not representable here and deliberately so.** "Recents",
/// "Favorites", "Panoramas", "Screenshots", "Hidden", "Recently Deleted" and the
/// rest are *computed* by Photos from asset metadata and a rolling window — they
/// are not membership anyone adds a photo to. Materialising them would mean
/// storing tens of thousands of rows that are wrong the instant they are
/// written, and offering them as a filter would let a computed collection behave
/// like a user one. "Favorites" in particular would be a second, staler source
/// of truth for the one flag that protects photos from deletion
/// (`PhotoLibrary.delete` re-reads `isFavorite` live). Only
/// `PHCollectionType.album` collections are indexed; see `CacheStore.albums()`.
enum AlbumSelection: Sendable, Equatable, Codable {
    case all
    case unassigned
    case album(String)

    // MARK: Codable

    /// Encoded as the *single string* the wire already uses, not as a nested
    /// object, so `PhotoFilter`'s synthesised `Codable` conformance keeps
    /// producing the flat `{"lo":…,"hi":…,"album":"…"}` shape. Decoding goes
    /// through the same parser as the query parameter, so there is exactly one
    /// definition of which strings mean what.
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try AlbumSelection.parse(try container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }

    /// The album identifier, when one is selected.
    var albumIdentifier: String? {
        if case .album(let identifier) = self { return identifier }
        return nil
    }

    /// True when the selection asks for assets that are in *no* indexed album.
    var isUnassigned: Bool {
        if case .unassigned = self { return true }
        return false
    }

    /// What the UI sends and receives: `"all"`, `"none"`, or an album
    /// identifier. Two reserved words rather than optionals, because a client
    /// cannot forget to send one and cannot confuse "absent" with a bucket.
    enum WireValue: String, Sendable, Codable {
        case all
        case none
    }

    /// The album value as it travels on the wire.
    var wireValue: String {
        switch self {
        case .all: return WireValue.all.rawValue
        case .unassigned: return WireValue.none.rawValue
        case .album(let identifier): return identifier
        }
    }

    /// Parses a wire value. Anything else is an error, never a fallback to
    /// `.all`: quietly widening a filter that was meant to be narrow is the same
    /// class of mistake as defaulting an unknown `favorites` value to `include`.
    static func parse(_ raw: String) throws -> AlbumSelection {
        switch raw {
        case WireValue.all.rawValue: return .all
        case WireValue.none.rawValue: return .unassigned
        default:
            guard !raw.isEmpty else { return .all }
            return .album(raw)
        }
    }

    /// A stable, order-independent fingerprint of the album dimension alone.
    /// Folded into the pagination token so a cursor issued under one album
    /// cannot be replayed under another — see `PhotoCursor.filterFingerprint`.
    var fingerprint: String {
        switch self {
        case .all: return "albums:all"
        case .unassigned: return "albums:none"
        case .album(let identifier): return "albums:one:\(identifier)"
        }
    }
}

/// The score-range query that drives the whole UI.
struct PhotoFilter: Sendable, Codable, Equatable {
    var lower: Float
    var upper: Float
    var favorites: FavoriteFilter = .include
    /// Added in schema version 2. Defaults to `.all`, so every pre-existing
    /// construction site keeps its exact old meaning.
    var album: AlbumSelection = .all
    /// Set by the read-only timeline routes, which deliberately build the widest
    /// filter the cache can express out of the *observed* score extremes. Those
    /// extremes move as analysis progresses, so folding the live bounds into a
    /// pagination fingerprint would make the server refuse a continuation of its
    /// own token the next time a new score arrived. The flag pins the fingerprint
    /// to a constant instead: these queries are, by construction, unfiltered
    /// apart from "has a score".
    var unboundedByScore = false

    // Favourites are deliberately *not* excluded by rewriting the filter:
    // protection is enforced against the stored `favorite` flags at the moment
    // of the action (see `CacheStore.partitionFavorites`), so the number the
    // user is shown and the set that is protected cannot drift apart, and
    // `favorites: .only` still resolves — to nothing deletable.

    /// Exact, order-independent identity of this filter, for binding a
    /// pagination token to the query that issued it.
    ///
    /// Score bounds go in as their raw IEEE-754 bit patterns rather than their
    /// decimal text: the numbers arrive as `Float`s over JSON, so the bit pattern
    /// is both exactly what `bindFilter` will bind and immune to any formatting
    /// decision that could make two different bounds look alike.
    var paginationFingerprint: String {
        if unboundedByScore {
            // The timeline's bound is "every asset that has a score", which is the
            // same query no matter where the observed extremes currently sit.
            return "timeline:scored"
        }
        let low = lower.bitPattern
        let high = upper.bitPattern
        return "lo:\(low)|hi:\(high)|fav:\(favorites.rawValue)|\(album.fingerprint)"
    }
}

/// How the members of one Similar Group are ordered against each other.
///
/// Two conceptually different rankings, kept as a closed set so an unrecognised
/// value is refused rather than silently defaulted to one of them — the same
/// reasoning as `FavoriteFilter` and `TimelineDirection`.
enum GroupRankOrder: String, Sendable, Codable, CaseIterable {
    /// Apple's aesthetics score, unchanged: higher first.
    case aesthetics
    /// PhotoCleaner's own within-group ranking, built from aesthetics plus
    /// applicable Vision capture signals. See `BestShotRanker`.
    case bestShot = "best_shot"

    var wireValue: String { rawValue }
}

/// One photo as served inside a Similar Group.
///
/// `aesthetics` is Apple's `overallScore` exactly as returned. `bestShot` and
/// `faceCaptureQuality` are `nil` where the signal does not apply — a photo with
/// no faces has no face capture quality, and a group with no faces has no Best
/// Shot value to report. Absence is therefore always meaningful and never
/// presented as a zero.
struct GroupMemberRow: Sendable, Codable, Equatable {
    let id: String
    /// Apple's `overallScore`, stored and served verbatim.
    let aesthetics: Float
    /// Relative within-group rank. Higher is better; `nil` when the group has
    /// not been ranked by this order yet.
    let bestShot: Float?
    /// Vision's face capture quality, aggregated across the photo's significant
    /// faces. `nil` when the photo has no faces, or when the group contains none.
    let faceCaptureQuality: Float?
    let faceCount: Int?
    let date: Double?
    let width: Int
    let height: Int
    let favorite: Bool
}

/// One Similar Group as served to the UI.
///
/// `memberCount` is how many members this response is *about*; `items` is one page
/// of exactly those, in the requested order. `ranked` says which order they are in,
/// so a client can tell "sorted by Best Shot" from "sorted by Aesthetics" rather
/// than inferring it.
///
/// Under an album filter the two counts describe the group **as it appears in that
/// album**: a group qualifies if at least one member is in the album, and
/// `memberCount` then counts only the members that are. The group's own size stays
/// available as `hiddenMemberCount`, so the browser can say what it left out rather
/// than quietly showing a smaller group than the one that exists.
struct SimilarGroupRow: Sendable, Codable, Equatable {
    /// Stable identifier: the lexicographically smallest member's asset
    /// identifier. Derived from the members rather than generated, so the same
    /// group has the same key across rebuilds and can be cited in a URL.
    let id: String
    /// Members this response is about: the whole group, or the subset an album
    /// filter keeps.
    let memberCount: Int
    /// Members the album filter left out — of `memberCount`, of `faceMemberCount`
    /// and of `items`. **Omitted** when nothing was filtered, so an unfiltered
    /// response is exactly what it always was and a client cannot mistake "no
    /// filter" for "a filter that hid nothing".
    let hiddenMemberCount: Int?
    /// Earliest capture in the group, for the date line in the browser.
    let date: Double?
    /// How many of this response's members contain at least one face. Drives
    /// whether Best Shot has anything to add beyond aesthetics.
    let faceMemberCount: Int
    let items: [GroupMemberRow]
    let ranked: GroupRankOrder
    /// True while the group's members have not all been through face capture
    /// analysis, so a portrait group's Best Shot ordering may still be settling.
    let incomplete: Bool
}

enum SortOrder: String, Sendable, Codable {
    case scoreAscending = "score_asc"
    case scoreDescending = "score_desc"
    case newestFirst = "date_desc"
    case oldestFirst = "date_asc"
    /// The exact reverse of `newestFirst`, tie-break included. Used by exactly one
    /// caller — the All Photos window's "newer" side — and it exists for a
    /// specific reason; see `TimelineDirection`.
    case timelineNewer = "date_asc_id_desc"

    /// Column and direction used for both `ORDER BY` and keyset pagination.
    /// Never interpolated from user input — this enum is the only source.
    var orderByClause: String {
        switch self {
        case .scoreAscending: return "aesthetics_score ASC, asset_identifier ASC"
        case .scoreDescending: return "aesthetics_score DESC, asset_identifier ASC"
        case .newestFirst: return "COALESCE(creation_date, 0) DESC, asset_identifier ASC"
        case .oldestFirst: return "COALESCE(creation_date, 0) ASC, asset_identifier ASC"
        case .timelineNewer: return "COALESCE(creation_date, 0) ASC, asset_identifier DESC"
        }
    }
}

/// Which side of an anchor a chronological page was asked for.
///
/// A closed enum for the same reason `FavoriteFilter` is:
/// the value selects a SQL sort, so an unrecognised string must be refused
/// rather than defaulted to one of the two directions.
enum TimelineDirection: String, Sendable, Codable {
    /// Photos older than the anchor — the page that follows it in `date_desc`.
    case older
    /// Photos newer than the anchor.
    case newer

    /// The ordering whose keyset walk *forwards* from the anchor yields this side.
    ///
    /// The All Photos window is one total order — `newestFirst`, `date DESC` then
    /// `asset_identifier ASC` — and the anchor splits it in two. `older` is what
    /// comes strictly *after* the anchor in that order, so its walk is a plain
    /// forward keyset walk of `newestFirst` and it comes back in display order.
    ///
    /// `newer` is what comes strictly *before* the anchor, which is not the same
    /// thing as a forward walk of `oldestFirst`: two orderings that both tie-break
    /// `asset_identifier` upwards cannot partition a group of photos that share one
    /// timestamp. A burst of shots in the same second would land in *both* sides
    /// when its identifier sorted above the anchor's, and in *neither* when it
    /// sorted below — duplicates on screen, and photos the window can never reach.
    /// So the newer side walks `timelineNewer`, which is `newestFirst` with every
    /// key reversed. Reversing a total order reverses it exactly, so the newer
    /// side is the exact complement of the older side: disjoint, jointly complete,
    /// and still one contiguous forward walk that pages without a gap. It comes
    /// back in `date ASC, id DESC` order, which is why the client reverses it —
    /// see `Router.timelineAround`.
    var sort: SortOrder {
        switch self {
        case .older: return .newestFirst
        case .newer: return .timelineNewer
        }
    }
}

/// Keyset pagination token: the sort key of the last row of the previous page.
///
/// Keyset (rather than `OFFSET`) pagination keeps every page fetch O(log n) even
/// at the far end of a 100k-photo result set.
///
/// The token carries *both* sort keys — the score and the date — because one
/// number cannot describe a position in either of the two families of ordering
/// (`CacheStore.keysetClause` reads `score` for a score sort and `date` for a
/// date sort). That is also why it carries `sort`.
///
/// A keyset token is only meaningful *relative to the ordering that issued it*.
/// Handed to a different one it is not merely imprecise, it is a description of
/// a different place in the library: a cursor taken from the last row of a
/// `score_asc` page and replayed against `date_desc` asks for "the rows after
/// this row in date order", which is a well-formed query returning well-formed
/// photos from an unrelated part of the grid — silently. So `sort` is part of the
/// token and `CacheStore.page` refuses a cursor that was issued for another
/// ordering rather than guessing. See `CacheError.cursorSortMismatch`.
///
/// The same argument applies to the *filter*, one level up: a token names a
/// position in one result set, and "the rows after this row **within album A**"
/// is a different set of rows from "the rows after this row within album B" —
/// or from the unfiltered grid. `filterFingerprint` therefore binds the token to
/// the filter that produced it for the same reason, and `page` refuses a
/// mismatch. `nil` keeps the old meaning: a token the server built for itself,
/// never handed to a client and used only with the filter its caller chose.
struct PhotoCursor: Sendable, Codable {
    let score: Float
    let date: Double
    let id: String
    /// The ordering this token was issued for, or `nil` for a token the server
    /// built for itself (`/api/timeline/around`'s anchor), which is never handed
    /// to a client and is only ever used with the ordering its caller chose.
    let sort: SortOrder?
    /// The filter this token was issued for. See the discussion above; a token
    /// minted before schema version 2 decodes with `nil` here and is then only
    /// bound to its sort, which is exactly the guarantee version 1 gave.
    let filterFingerprint: String?

    init(score: Float, date: Double, id: String, sort: SortOrder? = nil, filterFingerprint: String? = nil) {
        self.score = score
        self.date = date
        self.id = id
        self.sort = sort
        self.filterFingerprint = filterFingerprint
    }

    init(row: PhotoRow, sort: SortOrder? = nil, filterFingerprint: String? = nil) {
        self.score = row.score
        self.date = row.date ?? 0
        self.id = row.id
        self.sort = sort
        self.filterFingerprint = filterFingerprint
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return data.base64URLEncodedString()
    }

    static func decode(_ string: String) -> PhotoCursor? {
        guard let data = Data(base64URLEncoded: string) else { return nil }
        return try? JSONDecoder().decode(PhotoCursor.self, from: data)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var value = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value.append("=") }
        self.init(base64Encoded: value)
    }
}
