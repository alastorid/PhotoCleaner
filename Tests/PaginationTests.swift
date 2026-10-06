import Foundation

// Keyset pagination.
//
// `CacheStore.keysetClause` and `SortOrder.orderByClause` have to agree in three
// ways — direction, the `asset_identifier` tie-break, and `COALESCE` null handling
// — or a walk silently skips or repeats rows. Nothing verified that before. These
// cases walk a purpose-built dataset with **deliberately tied scores and dates**
// (ties are where keyset bugs live), for every sort order and several page sizes,
// and compare the concatenation against an ordering computed independently in Swift
// from the same data.

func registerPaginationTests() {
    let suite = "keyset pagination"

    // MARK: the SQL contract the keyset depends on

    Registry.shared.add(suite: suite, TestCase(name: "every ORDER BY is a total order", knownBug: nil) {
        let clauses: [SortOrder: String] = [
            .scoreAscending: "aesthetics_score ASC, asset_identifier ASC",
            .scoreDescending: "aesthetics_score DESC, asset_identifier ASC",
            .newestFirst: "COALESCE(creation_date, 0) DESC, asset_identifier ASC",
            .oldestFirst: "COALESCE(creation_date, 0) ASC, asset_identifier ASC",
            .timelineNewer: "COALESCE(creation_date, 0) ASC, asset_identifier DESC",
        ]
        for (order, expected) in clauses {
            checkEqual(order.orderByClause, expected, "\(order.rawValue) ORDER BY")
            check(order.orderByClause.hasSuffix("asset_identifier ASC")
                    || order.orderByClause.hasSuffix("asset_identifier DESC"),
                  "\(order.rawValue) must tie-break on the primary key, got \(order.orderByClause)")
        }
        // The one ordering that breaks ties downwards is `newestFirst` reversed,
        // and the All Photos window's two sides are exactly it and `newestFirst`.
        // That pairing is the whole reason a same-timestamp burst partitions
        // instead of overlapping, so it is pinned rather than left implicit.
        checkEqual(TimelineDirection.older.sort.orderByClause,
                   "COALESCE(creation_date, 0) DESC, asset_identifier ASC",
                   "older walks the timeline's own order")
        checkEqual(TimelineDirection.newer.sort.orderByClause,
                   "COALESCE(creation_date, 0) ASC, asset_identifier DESC",
                   "newer walks that order with every key reversed")
    })

    Registry.shared.add(suite: suite, TestCase(name: "filter bounds are always ?1/?2, with literals after them",
        knownBug: nil) {
        // The keyset clause hard-codes parameter indices 3, 4 and 5 and puts LIMIT
        // at 6, which is only correct if the filter never binds anything above ?2.
        checkEqual(PhotoFilter(lower: -1, upper: 1).whereSQLClause(),
                   "aesthetics_score >= ?1 AND aesthetics_score <= ?2", "default filter")
        checkEqual(PhotoFilter(lower: -1, upper: 1, favorites: .exclude).whereSQLClause(),
                   "aesthetics_score >= ?1 AND aesthetics_score <= ?2 AND favorite = 0",
                   "exclude")
        checkEqual(PhotoFilter(lower: -1, upper: 1, favorites: .only).whereSQLClause(),
                   "aesthetics_score >= ?1 AND aesthetics_score <= ?2 AND favorite = 1",
                   "only")
        for filter in [PhotoFilter(lower: -1, upper: 1), PhotoFilter(lower: -1, upper: 1, favorites: .exclude),
                       PhotoFilter(lower: -1, upper: 1, favorites: .only)] {
            let clause = filter.whereSQLClause()
            checkEqual(clause.filter { $0 == "?" }.count, 2,
                       "only the two score bounds may bind a parameter, got \"\(clause)\"")
            check(clause.hasPrefix("aesthetics_score >= ?1"), "and they are ?1 and ?2, got \"\(clause)\"")
        }
    })

    // MARK: the walk

    Registry.shared.add(suite: suite, TestCase(name: "every sort order: a full walk has no gaps and no duplicates",
        knownBug: nil) {
        let fixture = try await Fixture.make("pagination-walk")
        let seeds = PagingDataset.seeds()
        try await fixture.seed(seeds)
        let filter = try await fixture.allRowsFilter()

        for sort in PagingDataset.allSorts {
            let expected = PagingDataset.expectedOrder(seeds, sort)
            for limit in [1, 2, 3, 7, 8, 60, 62, 63, 64, 200] {
                let walk = try await PagingDataset.walk(cache: fixture.cache, filter: filter, sort: sort, limit: limit)
                checkEqual(walk.ids, expected, "\(sort.rawValue) limit \(limit): the walk must reproduce the documented ordering")
                checkNoDuplicates(walk.ids, "\(sort.rawValue) limit \(limit)")
                checkEqual(walk.total, expected.count, "\(sort.rawValue) limit \(limit): total")
                checkEqual(Set(walk.ids).count, seeds.count, "\(sort.rawValue) limit \(limit): every row exactly once")
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "the last page never advertises a nextCursor", knownBug: nil) {
        let fixture = try await Fixture.make("pagination-lastpage")
        let seeds = PagingDataset.seeds()
        try await fixture.seed(seeds)
        let filter = try await fixture.allRowsFilter()

        for sort in PagingDataset.allSorts {
            // Page size exactly equal to the row count: a *full* final page, which
            // is indistinguishable from "there is more" without the lookahead row.
            let exact = try await PagingDataset.walk(cache: fixture.cache, filter: filter, sort: sort,
                                                     limit: seeds.count)
            checkEqual(exact.pages, 1, "\(sort.rawValue): one page holds the whole result set")
            check(exact.cursors.last.flatMap { $0 } == nil,
                  "\(sort.rawValue): a full final page must not advertise a cursor")

            // A short final page, after several full ones.
            let multi = try await PagingDataset.walk(cache: fixture.cache, filter: filter, sort: sort, limit: 20)
            checkEqual(multi.ids.count, seeds.count, "\(sort.rawValue): the multi-page walk is complete")
            check(multi.cursors.last.flatMap { $0 } == nil, "\(sort.rawValue): the last page is cursorless")
            checkEqual(multi.cursors.count, Int(ceil(Double(seeds.count) / 20.0)),
                       "\(sort.rawValue): one cursor per page except the last")
            check(multi.cursors.dropLast().allSatisfy { $0 != nil },
                  "\(sort.rawValue): every non-final page advertises a cursor, got \(multi.cursors.map { $0 == nil })")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a cursor names exactly the last row of the page it came from",
        knownBug: nil) {
        let fixture = try await Fixture.make("pagination-cursor")
        let seeds = PagingDataset.seeds()
        try await fixture.seed(seeds)
        let filter = try await fixture.allRowsFilter()

        for sort in PagingDataset.allSorts {
            var cursor: PhotoCursor?
            for pageNumber in 1...8 {
                let page = try await fixture.cache.page(filter: filter, sort: sort, cursor: cursor, limit: 9, offset: 0)
                guard let last = page.rows.last else { break }
                if let encoded = page.nextCursor {
                    guard let decoded = checkNotNil(PhotoCursor.decode(encoded),
                                                    "\(sort.rawValue) page \(pageNumber): cursor decodes") else { break }
                    checkEqual(decoded.id, last.id, "\(sort.rawValue): cursor id")
                    checkEqual(decoded.score, last.score, "\(sort.rawValue): cursor score (REAL written from Float)")
                    checkEqual(decoded.date, last.date ?? 0, "\(sort.rawValue): cursor date (null becomes 0)")
                }
                cursor = page.nextCursor.flatMap { PhotoCursor.decode($0) }
                if cursor == nil { break }
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "resuming from a hand-made cursor skips exactly that row",
        knownBug: nil) {
        // The tie-break term is what makes this exact: with `c-020` held back, no
        // other row sharing its score may be skipped either.
        let fixture = try await Fixture.make("pagination-resume")
        let seeds = PagingDataset.seeds()
        try await fixture.seed(seeds)
        let filter = try await fixture.allRowsFilter()
        let expected = PagingDataset.expectedOrder(seeds, .scoreAscending)
        let startIndex = (expected.firstIndex(of: "c-020") ?? 0) + 1
        guard let target = seeds.first(where: { $0.id == "c-020" }), let targetScore = target.score else {
            Harness.record("the fixture lost c-020")
            return
        }

        let page = try await fixture.cache.page(filter: filter, sort: .scoreAscending,
                                                cursor: PhotoCursor(score: targetScore, date: target.date ?? 0,
                                                                    id: target.id),
                                                limit: 5, offset: 0)
        checkEqual(page.rows.map(\.id), Array(expected[startIndex..<(startIndex + 5)]),
                   "score_asc resumed at (0.5, c-020)")
        check(!page.rows.contains { $0.id == "c-020" }, "the cursor row itself is not repeated")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a cursor past the last row returns nothing and no cursor",
        knownBug: nil) {
        let fixture = try await Fixture.make("pagination-endcursor")
        let seeds = PagingDataset.seeds()
        try await fixture.seed(seeds)
        let filter = try await fixture.allRowsFilter()
        for sort in PagingDataset.allSorts {
            let all = try await PagingDataset.walk(cache: fixture.cache, filter: filter, sort: sort, limit: 200)
            guard let last = all.rows.last else { continue }
            let page = try await fixture.cache.page(filter: filter, sort: sort,
                                                    cursor: PhotoCursor(row: last), limit: 10, offset: 0)
            checkEqual(page.rows.count, 0, "\(sort.rawValue): past the last row there is nothing")
            checkEqual(page.nextCursor, nil, "\(sort.rawValue): and no cursor")
            checkEqual(page.total, all.ids.count, "\(sort.rawValue): total is the whole match, not the remainder")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "ties break on the identifier, upwards except in the reversed order",
        knownBug: nil) {
        let fixture = try await Fixture.make("pagination-ties")
        // Six rows: tied scores, tied dates, and rows tied on both at once.
        let seeds: [Fixture.Seed] = [
            .init(id: "t-1", score: 0.5, date: 100),
            .init(id: "t-2", score: 0.5, date: 100),
            .init(id: "t-3", score: 0.5, date: 100),
            .init(id: "t-4", score: 0.5, date: 50),
            .init(id: "t-5", score: 0.25, date: 100),
            .init(id: "t-6", score: 0.25, date: 100),
        ]
        try await fixture.seed(seeds)
        let filter = try await fixture.allRowsFilter()

        checkEqual(try await PagingDataset.ids(cache: fixture.cache, filter: filter, sort: .scoreAscending, limit: 1),
                   ["t-5", "t-6", "t-1", "t-2", "t-3", "t-4"],
                   "score_asc: tied scores ascend by id, whatever the dates")
        checkEqual(try await PagingDataset.ids(cache: fixture.cache, filter: filter, sort: .scoreDescending, limit: 1),
                   ["t-1", "t-2", "t-3", "t-4", "t-5", "t-6"],
                   "score_desc: the primary key still ascends inside a tie")
        checkEqual(try await PagingDataset.ids(cache: fixture.cache, filter: filter, sort: .newestFirst, limit: 1),
                   ["t-1", "t-2", "t-3", "t-5", "t-6", "t-4"],
                   "date_desc: tied dates ascend by id")
        checkEqual(try await PagingDataset.ids(cache: fixture.cache, filter: filter, sort: .oldestFirst, limit: 1),
                   ["t-4", "t-1", "t-2", "t-3", "t-5", "t-6"],
                   "date_asc: tied dates ascend by id")
        checkEqual(try await PagingDataset.ids(cache: fixture.cache, filter: filter, sort: .timelineNewer, limit: 1),
                   ["t-4", "t-6", "t-5", "t-3", "t-2", "t-1"],
                   "the All Photos newer side is date_desc reversed: tied dates descend by id")
    })

    Registry.shared.add(suite: suite, TestCase(name: "null dates sort as epoch 0 in both date orders", knownBug: nil) {
        let fixture = try await Fixture.make("pagination-nulls")
        let seeds: [Fixture.Seed] = [
            .init(id: "n-a", score: 0.5, date: nil),
            .init(id: "n-b", score: 0.5, date: 0),
            .init(id: "n-c", score: 0.5, date: 1),
            .init(id: "n-d", score: 0.5, date: 1),
        ]
        try await fixture.seed(seeds)
        let filter = try await fixture.allRowsFilter()

        let oldest = try await PagingDataset.walk(cache: fixture.cache, filter: filter, sort: .oldestFirst, limit: 1)
        checkEqual(oldest.ids, ["n-a", "n-b", "n-c", "n-d"],
                   "a null date is COALESCEd to 0, ties with a real epoch-0 date and sorts by id")
        checkNil(oldest.rows.first?.date, "the null date survives the round trip as nil")
        checkEqual(oldest.rows[1].date, 0, "and the real epoch 0 stays 0")

        let newest = try await PagingDataset.ids(cache: fixture.cache, filter: filter, sort: .newestFirst, limit: 1)
        checkEqual(newest, ["n-c", "n-d", "n-a", "n-b"], "a null date is the *oldest* end of date_desc")
    })

    Registry.shared.add(suite: suite, TestCase(name: "offset is only honoured on a cursorless first page",
        knownBug: nil) {
        let fixture = try await Fixture.make("pagination-offset")
        let seeds = PagingDataset.seeds()
        try await fixture.seed(seeds)
        let filter = try await fixture.allRowsFilter()
        let expected = PagingDataset.expectedOrder(seeds, .scoreAscending)

        let jumped = try await fixture.cache.page(filter: filter, sort: .scoreAscending,
                                                   cursor: nil, limit: 4, offset: 10)
        checkEqual(jumped.rows.map(\.id), Array(expected[10..<14]), "offset skips the first ten rows")
        check(jumped.nextCursor != nil, "a mid-list page still advertises a cursor")

        let afterJump = try await fixture.cache.page(filter: filter, sort: .scoreAscending,
                                                     cursor: PhotoCursor(row: jumped.rows.last!),
                                                     limit: 4, offset: 10)
        checkEqual(afterJump.rows.map(\.id), Array(expected[14..<18]),
                   "offset is ignored once a cursor is present (CacheStore.page:511)")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a nonsense limit cannot abort the process",
        knownBug: nil) {
        // `page` trims a lookahead row with `removeLast()`, which is a hard process
        // abort on an empty array — not a thrown error, an exit. The arithmetic
        // reaches it at `limit < 0`: the query returns nothing, and `0 > -1` is
        // true. Every current caller clamps (`queryInt(…, range: 1…200)`), so this
        // is about the next one: `page` is a public actor method, and its contract
        // should not be "pass a sensible number or the app dies".
        let fixture = try await Fixture.make("pagination-negative-limit")
        let seeds = PagingDataset.seeds()
        try await fixture.seed(seeds)
        let filter = try await fixture.allRowsFilter()

        // Asserted on the return value, not on surviving: a crash takes the suite
        // down with it, so there would be nothing left to read this assertion from.
        for limit in [-1, Int.min] {
            let page = try await fixture.cache.page(filter: filter, sort: .scoreAscending,
                                                    cursor: nil, limit: limit, offset: 0)
            checkEqual(page.rows.count, 0, "limit \(limit) returns no rows rather than aborting")
            checkNil(page.nextCursor, "and advertises no next page for limit \(limit)")
        }

        // The ordinary case is untouched, which is what makes the guard safe rather
        // than a behaviour change: a lookahead row is still trimmed, and a full page
        // still hands back a cursor.
        let normal = try await fixture.cache.page(filter: filter, sort: .scoreAscending,
                                                   cursor: nil, limit: 4, offset: 0)
        checkEqual(normal.rows.count, 4, "a normal limit still returns exactly what it asked for")
        checkNotNil(normal.nextCursor, "and still advertises the next page")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a filtered walk is gap-free within the filter",
        knownBug: nil) {
        let fixture = try await Fixture.make("pagination-filtered")
        let seeds = PagingDataset.seeds()
        try await fixture.seed(seeds)
        let included = seeds.filter { let score = $0.score ?? 0; return score >= 0 && score <= 0.4 }
        check(included.count > 10, "the filtered set is big enough to need several pages, got \(included.count)")

        for sort in PagingDataset.allSorts {
            let filter = PhotoFilter(lower: 0, upper: 0.4)
            let walk = try await PagingDataset.walk(cache: fixture.cache, filter: filter, sort: sort, limit: 4)
            checkEqual(walk.ids, PagingDataset.expectedOrder(included, sort),
                       "\(sort.rawValue): a filtered walk still has no gaps")
            checkEqual(walk.total, included.count, "\(sort.rawValue): total matches the filter")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "an empty result set is a clean, cursorless page", knownBug: nil) {
        let fixture = try await Fixture.make("pagination-empty")
        let filter = PhotoFilter(lower: 0.9, upper: 1.0)
        for sort in PagingDataset.allSorts {
            let page = try await fixture.cache.page(filter: filter, sort: sort, cursor: nil, limit: 60, offset: 0)
            checkEqual(page.rows.count, 0, "\(sort.rawValue): no rows")
            checkEqual(page.nextCursor, nil, "\(sort.rawValue): and no cursor")
            checkEqual(page.total, 0, "\(sort.rawValue): and a total of zero")
        }
    })

    // MARK: through the router

    Registry.shared.add(suite: suite, TestCase(name: "GET /api/photos paginates with the server's own cursor",
        knownBug: nil) {
        let fixture = try await Fixture.make("pagination-router")
        let seeds = PagingDataset.seeds()
        try await fixture.seed(seeds)
        let expected = PagingDataset.expectedOrder(seeds, .scoreAscending)

        var collected: [String] = []
        var cursor: String?
        var pages = 0
        var totals: Set<Int> = []
        repeat {
            var query = ["sort": "score_asc", "limit": "25"]
            if let cursor { query["cursor"] = cursor }
            let reply = await fixture.router.reply(Req.get("/api/photos", query: query))
            checkEqual(reply.status, 200, "status")
            collected.append(contentsOf: reply.rows().map(\.id))
            totals.insert(reply.int("total") ?? -1)
            pages += 1
            checkEqual((reply.json["filter"] as? [String: Any])?["sort"] as? String, "score_asc",
                       "the filter echo is self-describing")
            cursor = reply.string("nextCursor")
        } while cursor != nil && pages < 20

        checkEqual(collected, expected, "the walk through /api/photos is complete and ordered")
        checkNoDuplicates(collected, "/api/photos walk")
        checkEqual(totals, [seeds.count], "total is constant across pages")
        checkEqual(cursor, nil, "the walk ends with no cursor, after \(pages) pages")
    })

    Registry.shared.add(suite: suite, TestCase(name: "limit is clamped to 1…200 and junk falls back to 60",
        knownBug: nil) {
        let fixture = try await Fixture.make("pagination-clamp")
        // 260 rows, so a 200-row page is genuinely shorter than the result set.
        try await fixture.seed((0..<260).map {
            .init(id: "z-\(String(format: "%04d", $0))", score: Float($0 % 7) / 8, date: Double(1000 + $0))
        })
        checkEqual((await fixture.router.reply(Req.get("/api/photos", query: ["limit": "100000"]))).rows().count, 200,
                   "limit is clamped to the maximum page size")
        checkEqual((await fixture.router.reply(Req.get("/api/photos", query: ["limit": "0"]))).rows().count, 1,
                   "limit=0 clamps up to 1, never to 0 or negative")
        checkEqual((await fixture.router.reply(Req.get("/api/photos", query: ["limit": "-20"]))).rows().count, 1,
                   "a negative limit clamps to 1")
        checkEqual((await fixture.router.reply(Req.get("/api/photos", query: ["limit": "sixty"]))).rows().count, 60,
                   "an unparseable limit falls back to the default page size")
        checkEqual((await fixture.router.reply(Req.get("/api/photos", query: ["offset": "99999999"]))).rows().count, 0,
                   "an out-of-range offset yields nothing rather than everything")
    })

    Registry.shared.add(suite: suite, TestCase(name: "an unreadable cursor restarts from the top on /api/photos",
        knownBug: nil) {
        // `photos()` ignores a cursor it cannot decode; the timeline routes refuse
        // it instead. Pinning the difference so it cannot change unnoticed.
        let fixture = try await Fixture.make("pagination-badcursor")
        let seeds = PagingDataset.seeds()
        try await fixture.seed(seeds)
        let first = PagingDataset.expectedOrder(seeds, .scoreAscending).first
        for bad in ["not-base64!!", "", "eyJzY29yZSI6MH0", "@@@@"] {
            let reply = await fixture.router.reply(Req.get("/api/photos", query: ["cursor": bad, "limit": "3"]))
            checkEqual(reply.status, 200, "status for cursor \"\(bad)\"")
            checkEqual(reply.rows().count, 3, "an undecodable cursor yields a page")
            checkEqual(reply.rows().first?.id, first, "i.e. from the very beginning")
        }
    })

    // MARK: cursors are only meaningful for the ordering that issued them

    Registry.shared.add(suite: suite, TestCase(name: "a cursor issued for one ordering is refused by another",
        knownBug: nil) {
        // `PhotoCursor` carries both a score and a date, so which key the keyset
        // predicate reads is decided entirely by `sort`. Replaying a `score_asc`
        // token against `date_desc` used to return a well-formed page of photos from
        // an unrelated part of the grid — silently, which is worse than an error.
        let fixture = try await Fixture.make("pagination-cursor-sort")
        try await fixture.seed(PagingDataset.seeds())
        let filter = try await fixture.allRowsFilter()

        let first = try await fixture.cache.page(filter: filter, sort: .scoreAscending, cursor: nil,
                                                 limit: 5, offset: 0)
        guard let encoded = checkNotNil(first.nextCursor, "a score_asc cursor") else { return }
        guard let decoded = checkNotNil(PhotoCursor.decode(encoded), "the cursor decodes") else { return }
        checkEqual(decoded.sort, .scoreAscending, "the token records the ordering that issued it")

        do {
            let wrong = try await fixture.cache.page(filter: filter, sort: .newestFirst,
                                                     cursor: decoded, limit: 5, offset: 0)
            check(false, "a score_asc cursor must not be accepted by date_desc, got \(wrong.rows.count) rows")
        } catch {
            check(String(describing: error).contains("date_desc"),
                  "the error names the requested ordering, got: \(error)")
        }
        for other in [SortOrder.scoreDescending, .oldestFirst] {
            var refused = false
            do {
                _ = try await fixture.cache.page(filter: filter, sort: other, cursor: decoded, limit: 5, offset: 0)
            } catch {
                refused = true
            }
            check(refused, "\(other.rawValue) must refuse a score_asc cursor")
        }

        // An unbound cursor — the All Photos anchor, which the server builds for
        // itself and never hands out — is still accepted.
        let unbound = PhotoCursor(score: 0.5, date: 0, id: "c-020")
        checkNil(unbound.sort, "an unbound cursor carries no ordering")
        let resumed = try await fixture.cache.page(filter: filter, sort: .scoreAscending, cursor: unbound,
                                                   limit: 5, offset: 0)
        check(!resumed.rows.isEmpty, "and works with the ordering its caller chose")

        // Over HTTP the refusal is still a refusal, whatever status it carries.
        let reply = await fixture.router.reply(Req.get("/api/photos", query: ["sort": "date_desc", "cursor": encoded]))
        check(reply.status >= 400, "the route refuses it too, got \(reply.status)")
        checkEqual(reply.rows(), [], "returning nothing rather than the wrong photos")
    })

    Registry.shared.add(suite: suite, TestCase(name: "stamping the ordering leaves every walk unchanged", knownBug: nil) {
        let fixture = try await Fixture.make("pagination-stampsort")
        let seeds = PagingDataset.seeds()
        try await fixture.seed(seeds)
        let filter = try await fixture.allRowsFilter()
        for sort in PagingDataset.allSorts {
            let walk = try await PagingDataset.walk(cache: fixture.cache, filter: filter, sort: sort, limit: 11)
            checkEqual(walk.ids, PagingDataset.expectedOrder(seeds, sort),
                       "\(sort.rawValue): each page's cursor carries its own ordering, so the walk is unaffected")
        }
    })

    // MARK: the resolver that deletion uses

    Registry.shared.add(suite: suite, TestCase(name: "identifiers(matching:) is deterministic and score-ordered",
        knownBug: nil) {
        let fixture = try await Fixture.make("pagination-identifiers")
        let seeds = PagingDataset.seeds()
        try await fixture.seed(seeds)
        let filter = try await fixture.allRowsFilter()
        let first = try await fixture.cache.identifiers(matching: filter, limit: 10_000)
        checkEqual(first, try await fixture.cache.identifiers(matching: filter, limit: 10_000),
                   "two resolutions of the same filter agree exactly")
        checkEqual(first, PagingDataset.expectedOrder(seeds, .scoreAscending),
                   "and match the score-ascending order the confirm token is minted over")
    })

    Registry.shared.add(suite: suite, TestCase(name: "identifiers(matching:) honours its limit", knownBug: nil) {
        let fixture = try await Fixture.make("pagination-identifiers-limit")
        try await fixture.seed((0..<50).map {
            .init(id: "l-\(String(format: "%03d", $0))", score: 0.5, date: Double($0))
        })
        let filter = try await fixture.allRowsFilter()
        let limited = try await fixture.cache.identifiers(matching: filter, limit: 7)
        checkEqual(limited.count, 7, "the limit is applied")
        checkNoDuplicates(limited, "and does not repeat rows")
    })
}

// MARK: - The dataset

enum PagingDataset {
    /// Every ordering `CacheStore.page` supports, including `timelineNewer` — the
    /// one that exists only for the All Photos window's newer side and is the only
    /// ordering that breaks a tie downwards. A keyset bug in it would be invisible
    /// to a walk that only covered the four grid sorts.
    static let allSorts: [SortOrder] = [.scoreAscending, .scoreDescending,
                                        .newestFirst, .oldestFirst, .timelineNewer]

    /// 63 rows, built so that keyset bugs cannot hide:
    ///  * heavy score ties — 0.5 × 12, 0.0 × 7, −0.9959 × 5, and 1.0 × 8 — the
    ///    negative and the pile-up at exactly 1.0 are real observed values, and a
    ///    suite that assumed 0…1 would not notice either;
    ///  * heavy date ties — 1000 × 10, 2000 × 15, 3000 × 6;
    ///  * rows tied on score *and* date at once;
    ///  * rows with a null creation date.
    static func seeds() -> [Fixture.Seed] {
        var seeds: [Fixture.Seed] = []
        var index = 0
        func add(_ score: Float, _ date: Double?) {
            index += 1
            seeds.append(.init(id: "c-\(String(format: "%03d", index))", score: score, date: date))
        }
        for _ in 0..<12 { add(0.5, 1000) }
        for _ in 0..<7 { add(0.0, 2000) }
        for _ in 0..<5 { add(-0.9959, 3000) }
        for _ in 0..<9 { add(0.25, 2000) }
        for _ in 0..<6 { add(-0.5, nil) }
        for _ in 0..<8 { add(1.0, 1000) }
        for _ in 0..<10 { add(0.75, 1500) }
        for _ in 0..<6 { add(0.1, 2500) }
        // Unique keys too, so the walk is not purely tied.
        for step in 0..<6 { add(0.02 + Float(step) / 50, Double(900 + step)) }
        return seeds
    }

    /// The ordering the `ORDER BY` clauses promise, computed independently of SQL.
    ///
    /// Written out per sort rather than derived, because deriving it from the same
    /// rule the code uses would make this a tautology: the point is that a walk
    /// reproduces the *documented* order, tie-break direction included.
    static func expectedOrder(_ seeds: [Fixture.Seed], _ sort: SortOrder) -> [String] {
        let scores: [(primary: Double, id: String)] = seeds.compactMap { seed in
            guard let score = seed.score else { return nil }
            return (Double(score), seed.id)
        }
        let dates: [(primary: Double, id: String)] = seeds.map { (Double($0.date ?? 0), $0.id) }
        switch sort {
        case .scoreAscending:
            return scores.sorted { $0.primary == $1.primary ? $0.id < $1.id : $0.primary < $1.primary }.map(\.id)
        case .scoreDescending:
            return scores.sorted { $0.primary == $1.primary ? $0.id < $1.id : $0.primary > $1.primary }.map(\.id)
        case .newestFirst:
            return dates.sorted { $0.primary == $1.primary ? $0.id < $1.id : $0.primary > $1.primary }.map(\.id)
        case .oldestFirst:
            return dates.sorted { $0.primary == $1.primary ? $0.id < $1.id : $0.primary < $1.primary }.map(\.id)
        case .timelineNewer:
            // Ascending by date, *descending* by identifier inside a tie: the exact
            // reverse of `newestFirst`, which is what lets the All Photos window's
            // two sides partition a burst of same-second shots.
            return dates.sorted { $0.primary == $1.primary ? $0.id > $1.id : $0.primary < $1.primary }.map(\.id)
        }
    }

    struct Walk {
        var ids: [String] = []
        var rows: [PhotoRow] = []
        var cursors: [String?] = []
        var total: Int?
        var pages = 0
    }

    static func ids(cache: CacheStore, filter: PhotoFilter, sort: SortOrder, limit: Int) async throws -> [String] {
        try await walk(cache: cache, filter: filter, sort: sort, limit: limit).ids
    }

    static func walk(cache: CacheStore, filter: PhotoFilter, sort: SortOrder, limit: Int) async throws -> Walk {
        var walk = Walk()
        var cursor: PhotoCursor?
        var pageNumber = 0
        while true {
            pageNumber += 1
            check(pageNumber <= 2_000, "pagination did not terminate for \(sort.rawValue) limit \(limit)")
            if pageNumber > 2_000 { break }
            let page = try await cache.page(filter: filter, sort: sort, cursor: cursor, limit: limit, offset: 0)
            walk.pages += 1
            if walk.total == nil { walk.total = page.total }
            checkEqual(page.total, walk.total, "\(sort.rawValue): total is stable across pages")
            walk.rows.append(contentsOf: page.rows)
            walk.ids.append(contentsOf: page.rows.map(\.id))
            walk.cursors.append(page.nextCursor)
            guard let encoded = page.nextCursor, let next = PhotoCursor.decode(encoded) else { break }
            cursor = next
        }
        return walk
    }
}