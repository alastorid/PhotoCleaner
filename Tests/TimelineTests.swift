import Foundation

// Timeline ordering — the "All Photos" window.
//
// `TimelineDirection` is the mechanism under test: one total order (`date DESC,
// asset_identifier ASC`) split at the anchor, walked forwards in either of two
// orderings that are *exact reverses* of each other. The older side is what comes
// strictly after the anchor in that order; the newer side is what comes strictly
// before it. That symmetry only holds if the tie-break direction is reversed along
// with the date direction — the case this file now pins hardest, because the
// All Photos window exists to show bursts of same-second shots and a burst is
// exactly where a one-directional tie-break duplicates half of itself and loses
// the other half. Also pinned here: the anchor's own key is excluded from both
// sides, the window cannot be narrowed with a filter (a safety property, not a
// nicety), and an unscored asset cannot anchor it at all.

func registerTimelineTests() {
    let suite = "timeline ordering (All Photos)"

    Registry.shared.add(suite: suite, TestCase(name: "the direction-to-sort mapping is the documented one",
        knownBug: nil) {
        checkEqual(TimelineDirection.older.sort, .newestFirst, "older walks date_desc")
        checkEqual(TimelineDirection.newer.sort, .timelineNewer, "newer walks newestFirst reversed")
        // The two sides must be exact reverses of one another, tie-break included,
        // or they cannot partition a group of photos sharing one timestamp.
        checkEqual(TimelineDirection.older.sort.orderByClause, "COALESCE(creation_date, 0) DESC, asset_identifier ASC",
                   "the older side's total order")
        checkEqual(TimelineDirection.newer.sort.orderByClause, "COALESCE(creation_date, 0) ASC, asset_identifier DESC",
                   "the newer side's total order is that one with every key flipped")
        checkEqual(TimelineDirection(rawValue: "older"), .older, "rawValue round trip")
        checkEqual(TimelineDirection(rawValue: "newer"), .newer, "rawValue round trip")
        checkNil(TimelineDirection(rawValue: "Older"), "case matters")
        checkNil(TimelineDirection(rawValue: "newer "), "whitespace matters")
        checkNil(TimelineDirection(rawValue: "desc"), "there are only two directions")
        checkNil(TimelineDirection(rawValue: ""), "and an empty string is not one of them")
    })

    Registry.shared.add(suite: suite, TestCase(name: "older is strictly descending, newer ascends from the anchor",
        knownBug: nil) {
        let fixture = try await Fixture.make("timeline-sides")
        try await fixture.seed(TimelineDataset.seeds())
        let around = await fixture.router.reply(Req.get("/api/timeline/around",
            query: ["id": "d-020", "limit": "50"]))
        checkEqual(around.status, 200, "status")
        guard let anchorRow = try await fixture.cache.photo(identifier: "d-020") else {
            Harness.record("the anchor is missing from the cache")
            return
        }
        let anchorDate = anchorRow.date ?? 0

        let older = around.side("older").rows()
        let newer = around.side("newer").rows()
        check(older.count > 1 && newer.count > 1, "both sides are populated: \(older.count)/\(newer.count)")
        check(!older.contains { $0.id == "d-020" }, "the anchor is not in its own older side")
        check(!newer.contains { $0.id == "d-020" }, "the anchor is not in its own newer side")
        checkDescending(older, "older")
        checkNewerAscending(newer, "newer")

        for row in older {
            let date = row.date ?? 0
            check(date < anchorDate || (date == anchorDate && row.id > "d-020"),
                  "older row \(row.id)@\(date) is not strictly older than the anchor")
        }
        // The other half of the partition. It used to assert `row.id > anchor` here,
        // which is precisely the defect: both sides walked the same `id ASC`
        // tie-break from the same strict key, so a tied row above the anchor was
        // claimed by both and one below it by neither.
        for row in newer {
            let date = row.date ?? 0
            check(date > anchorDate || (date == anchorDate && row.id < "d-020"),
                  "newer row \(row.id)@\(date) is not strictly newer than the anchor")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a walk in both directions covers every row exactly once",
        knownBug: nil) {
        let fixture = try await Fixture.make("timeline-walk")
        let seeds = TimelineDataset.seeds()
        try await fixture.seed(seeds)
        let all = Set(seeds.map(\.id))

        for anchorID in ["d-020", "d-001", "d-043"] {
            let around = await fixture.router.reply(Req.get("/api/timeline/around",
                query: ["id": anchorID, "limit": "4"]))
            checkEqual(around.status, 200, "status for anchor \(anchorID)")
            checkEqual(around.int("total"), seeds.count, "total is the whole chronological window")

            for direction in ["older", "newer"] {
                let side = around.side(direction)
                var seen: [String] = side.rows().map(\.id)
                var cursor = side.string("nextCursor")
                var pages = 0
                while let token = cursor {
                    pages += 1
                    check(pages <= 30, "paging \(direction) from \(anchorID) did not terminate")
                    if pages > 30 { break }
                    let page = await fixture.router.reply(Req.get("/api/timeline/page",
                        query: ["direction": direction, "cursor": token, "limit": "4"]))
                    checkEqual(page.status, 200, "page status")
                    checkEqual(page.string("direction"), direction, "direction echo")
                    checkEqual(page.int("total"), seeds.count, "total is stable while paging")
                    let ids = page.rows().map(\.id)
                    for id in ids { check(!seen.contains(id), "\(id) appeared twice in the \(direction) walk from \(anchorID)") }
                    seen.append(contentsOf: ids)
                    check(!seen.contains(anchorID), "the anchor never appears in its own \(direction) side")
                    cursor = page.string("nextCursor")
                }
                checkEqual(cursor, nil, "the \(direction) walk from \(anchorID) ends with no cursor")
                check(seen.count >= 4, "the \(direction) walk from \(anchorID) is non-empty (\(seen.count) rows)")
                check(seen.count <= seeds.count - 1, "and cannot contain the anchor or more rows than exist")
                checkNoDuplicates(seen, "\(direction) walk from \(anchorID)")
                if direction == "older" {
                    checkDescending(around.side(direction).rows(), "older first page")
                } else {
                    checkNewerAscending(around.side(direction).rows(), "newer first page")
                }
            }
            check(!all.isEmpty, "the fixture is not empty")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "the two windows are disjoint and jointly cover the timeline",
        knownBug: nil) {
        // `Router.timelineAround` used to walk both sides from the anchor's own
        // `(date, id)` key through orderings that *both* tie-broke
        // `asset_identifier ASC`. The keyset start is strict, so a photo sharing
        // the anchor's timestamp landed in both windows when its id sorted above
        // the anchor's and in neither when it sorted below: a burst of same-second
        // shots showed duplicates on screen and photos the window could never
        // reach. The newer side now walks `newestFirst` reversed
        // (`SortOrder.timelineNewer`), so the two sides partition the timeline.
        let fixture = try await Fixture.make("timeline-coverage")
        let seeds = TimelineDataset.seeds()
        try await fixture.seed(seeds)
        let all = Set(seeds.map(\.id))

        for anchorID in ["d-020", "d-003", "d-040"] {
            let around = await fixture.router.reply(Req.get("/api/timeline/around",
                query: ["id": anchorID, "limit": "200"]))
            let older = around.side("older").rows().map(\.id)
            let newer = around.side("newer").rows().map(\.id)

            let overlap = Set(older).intersection(newer)
            check(overlap.isEmpty,
                  "\(anchorID): \(overlap.count) photos appear in both windows, e.g. \(Array(overlap.sorted().prefix(3)))")
            let missing = all.subtracting(Set(older).union(newer)).subtracting([anchorID])
            check(missing.isEmpty,
                  "\(anchorID): \(missing.count) photos are unreachable from this anchor, e.g. \(Array(missing.sorted().prefix(3)))")
            checkNoDuplicates(older + newer, "\(anchorID): the combined window")
            checkEqual(older.count + newer.count, all.count - 1, "\(anchorID): every other row, exactly once")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a burst of same-timestamp photos partitions around the anchor",
        knownBug: nil) {
        // The invariant, stated on its own: for *every* anchor in a group of
        // photos that all share one timestamp, the two sides together are every
        // photo in the group except the anchor — none twice, none missing — and
        // the anchor itself is in neither. Sizes 2, 3, 6 and 12 are checked
        // because the failure scales with the size of the tied group: a
        // duplicated-and-lost pair is invisible at two rows only if you look at
        // every anchor, so every anchor is checked, not just the middle one.
        for burst in [2, 3, 6, 12] {
            let fixture = try await Fixture.make("timeline-burst-\(burst)")
            // A burst, one photo an hour earlier, and one an hour later, so the
            // tied group is in the middle of the timeline rather than at an end.
            let group = (0..<burst).map { String(format: "b-%02d", $0) }
            var seeds: [Fixture.Seed] = group.map { .init(id: $0, score: 0.5, date: 2000) }
            seeds.append(.init(id: "before", score: 0.5, date: 1000))
            seeds.append(.init(id: "after", score: 0.5, date: 3000))
            try await fixture.seed(seeds)
            let all = Set(seeds.map(\.id))

            for anchorID in group {
                let around = await fixture.router.reply(Req.get("/api/timeline/around",
                    query: ["id": anchorID, "limit": "200"]))
                checkEqual(around.status, 200, "burst \(burst), anchor \(anchorID)")
                let older = around.side("older").rows()
                let newer = around.side("newer").rows()
                let olderIDs = older.map(\.id), newerIDs = newer.map(\.id)

                check(!olderIDs.contains(anchorID) && !newerIDs.contains(anchorID),
                      "burst \(burst), anchor \(anchorID): the anchor is in neither side")
                let overlap = Set(olderIDs).intersection(newerIDs)
                check(overlap.isEmpty,
                      "burst \(burst), anchor \(anchorID): \(overlap.count) duplicated, e.g. \(Array(overlap.sorted().prefix(3)))")
                let missing = all.subtracting(Set(olderIDs).union(newerIDs)).subtracting([anchorID])
                check(missing.isEmpty,
                      "burst \(burst), anchor \(anchorID): \(missing.count) unreachable, e.g. \(Array(missing.sorted().prefix(3)))")
                checkEqual(olderIDs.count + newerIDs.count, burst + 1,
                           "burst \(burst), anchor \(anchorID): the whole window is the burst plus one photo each side")

                // Which side a tied photo lands on is not arbitrary: the burst is
                // one run of the timeline order, the anchor splits it, and the two
                // halves are exactly the identifiers below and above the anchor's.
                // This is what makes the partition *stable* rather than merely
                // gap-free — the same burst pages the same way every time.
                let belowAnchor = group.filter { $0 < anchorID }
                let aboveAnchor = group.filter { $0 > anchorID }
                check(Set(olderIDs).intersection(group) == Set(aboveAnchor),
                      "burst \(burst), anchor \(anchorID): the older side is the half of the burst above \(anchorID)")
                check(Set(newerIDs).intersection(group) == Set(belowAnchor),
                      "burst \(burst), anchor \(anchorID): the newer side is the half of the burst below \(anchorID)")
                check(olderIDs.contains("before") && newerIDs.contains("after"),
                      "burst \(burst), anchor \(anchorID): the untied neighbours are on their own sides")
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "paging out of a burst is gap-free and duplicate-free",
        knownBug: nil) {
        // The partition has to survive *paging*, not just the first page. A cursor
        // is the last row of the previous page, so if the tie-break direction were
        // wrong on the way in it would be wrong on the way out too — the second
        // page would restart the rest of the burst.
        for burst in [3, 12] {
            let fixture = try await Fixture.make("timeline-burstpage-\(burst)")
            let group = (0..<burst).map { String(format: "p-%02d", $0) }
            try await fixture.seed(group.map { .init(id: $0, score: 0.5, date: 2000) }
                + [.init(id: "older-tail", score: 0.5, date: 500)])
            let all = Set(group + ["older-tail"])
            let anchor = group[burst / 2]

            var walks: [String: [String]] = [:]
            for direction in ["older", "newer"] {
                let around = await fixture.router.reply(Req.get("/api/timeline/around",
                    query: ["id": anchor, "limit": "2"]))
                var seen: [String] = []
                var cursor: String? = around.side(direction).string("nextCursor")
                var page = around.side(direction)
                var pages = 0
                while true {
                    pages += 1
                    check(pages <= burst + 2, "burst \(burst) \(direction): paging did not terminate")
                    if pages > burst + 2 { break }
                    checkEqual(page.status, 200, "burst \(burst) \(direction) page \(pages)")
                    for id in page.rows().map(\.id) {
                        check(!seen.contains(id), "burst \(burst) \(direction): \(id) appeared twice")
                        check(id != anchor, "burst \(burst) \(direction): the anchor appeared in its own walk")
                        seen.append(id)
                    }
                    guard let token = cursor else { break }
                    page = await fixture.router.reply(Req.get("/api/timeline/page",
                        query: ["direction": direction, "cursor": token, "limit": "2"]))
                    cursor = page.string("nextCursor")
                }
                checkNoDuplicates(seen, "burst \(burst) \(direction) walk")
                walks[direction] = seen
            }
            let older = Set(walks["older"] ?? []), newer = Set(walks["newer"] ?? [])
            check(older.isDisjoint(with: newer),
                  "burst \(burst): the two walks overlap on \(older.intersection(newer).sorted())")
            checkEqual(older.union(newer), all.subtracting([anchor]),
                       "burst \(burst): paging both ways covers every other photo exactly once")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "lo, hi, favorites and unknown parameters cannot narrow the window",
        knownBug: nil) {
        let fixture = try await Fixture.make("timeline-unfilterable")
        let base = TimelineDataset.seeds()
        // A favourite, the top-scoring row and the bottom-scoring row: each of them
        // would visibly disappear if the matching parameter were honoured instead of
        // ignored. `utility` and `sort` are in the hostile set because a client may
        // still send parameters this view has never honoured — the window must be as
        // unfilterable to those as to any parameter it does read.
        let extras: [Fixture.Seed] = [
            .init(id: "x-fav", score: 0.5, date: 1000, favorite: true),
            .init(id: "x-high", score: 1.0, date: 1002),
            .init(id: "x-low", score: -0.9959, date: 1003),
        ]
        let seeds = base + extras
        try await fixture.seed(seeds)

        let hostile: [String: String] = ["lo": "0.99", "hi": "1.0", "favorites": "only",
                                     "utility": "only", "sort": "date_asc", "album": "none"]
        let baseline = await fixture.router.reply(Req.get("/api/timeline/around", query: ["id": "d-020", "limit": "200"]))
        let filtered = await fixture.router.reply(Req.get("/api/timeline/around",
            query: ["id": "d-020", "limit": "200"].merging(hostile) { $1 }))
        checkEqual(filtered.status, 200, "status")
        checkEqual(filtered.rows(), baseline.rows(), "the host params are ignored")
        checkEqual(filtered.int("total"), baseline.int("total"), "total is unchanged")
        checkEqual(filtered.side("older").rows(), baseline.side("older").rows(), "older side unchanged")
        checkEqual(filtered.side("newer").rows(), baseline.side("newer").rows(), "newer side unchanged")
        checkEqual(baseline.int("total"), seeds.count, "every scored row is in the window")
        let window = baseline.side("older").rows().map(\.id) + baseline.side("newer").rows().map(\.id)
        check(window.contains("x-fav"), "the favourite is inside the window: it is a scored row, not a filtered one")
        check(window.contains("x-high") && window.contains("x-low"),
              "including the top and bottom scorers, whatever lo/hi said")

        for extra in [["lo": "2.0", "hi": "3.0"], ["lo": "-99", "hi": "99"],
                      ["favorites": "exclude", "utility": "hide"], ["favorites": "only"],
                      ["lo": "0.4", "hi": "0.6", "favorites": "exclude", "utility": "exclude"]] {
            let reply = await fixture.router.reply(Req.get("/api/timeline/around",
                query: ["id": "d-020", "limit": "200"].merging(extra) { $1 }))
            checkEqual(reply.rows(), baseline.rows(), "\(extra) must not narrow the window")
            checkEqual(reply.int("total"), seeds.count, "\(extra) must not change the total")
        }

        // The paging route keeps being called long after the first page, so it gets
        // the same check.
        let first = await fixture.router.reply(Req.get("/api/timeline/around", query: ["id": "d-020", "limit": "3"]))
        guard let token = checkNotNil(first.side("older").string("nextCursor"), "older cursor") else { return }
        let plain = await fixture.router.reply(Req.get("/api/timeline/page",
            query: ["direction": "older", "cursor": token, "limit": "3"]))
        let narrowed = await fixture.router.reply(Req.get("/api/timeline/page",
            query: ["direction": "older", "cursor": token, "limit": "3"].merging(hostile) { $1 }))
        checkEqual(narrowed.rows(), plain.rows(), "/api/timeline/page ignores the filter too")
        checkEqual(narrowed.int("total"), seeds.count, "and reports the same total")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the timeline is date-ordered only, never score-ordered",
        knownBug: nil) {
        // Scores here run opposite to dates, so any score influence on the ordering
        // would show up immediately.
        let fixture = try await Fixture.make("timeline-datesonly")
        try await fixture.seed([
            .init(id: "y-1", score: -0.9, date: 3000),
            .init(id: "y-2", score: 0.0, date: 2000),
            .init(id: "y-3", score: 0.9, date: 1000),
            .init(id: "y-4", score: 0.5, date: 4000),
            .init(id: "y-5", score: -0.5, date: 3500),
        ])
        let around = await fixture.router.reply(Req.get("/api/timeline/around", query: ["id": "y-2", "limit": "50"]))
        checkDescending(around.side("older").rows(), "older")
        checkNewerAscending(around.side("newer").rows(), "newer")
        checkSetEqual(around.side("older").rows().map(\.id) + around.side("newer").rows().map(\.id),
                      ["y-1", "y-3", "y-4", "y-5"], "all four other photos are present")
        checkEqual(around.side("older").rows().map(\.id), ["y-3"],
                   "older walks back from the anchor towards the earlier-dated photos")
        checkEqual(around.side("newer").rows().map(\.id), ["y-1", "y-5", "y-4"],
                   "newer walks forward from the anchor, nearest first")
    })

    Registry.shared.add(suite: suite, TestCase(name: "only scored rows are in the window, and the anchor needs a score",
        knownBug: nil) {
        let fixture = try await Fixture.make("timeline-unscored")
        try await fixture.seed([
            .init(id: "s-1", score: 0.5, date: 1000),
            .init(id: "s-2", score: nil, date: 1001, state: .pending),
            .init(id: "s-3", score: nil, date: 1002, state: .unavailable),
            .init(id: "s-4", score: 0.6, date: 1003),
        ])
        let around = await fixture.router.reply(Req.get("/api/timeline/around", query: ["id": "s-1", "limit": "50"]))
        checkEqual(around.int("total"), 2, "only the two scored rows are in the chronological window")
        check(!around.side("older").rows().map(\.id).contains("s-2"),
              "a pending row has no place in a score-bounded ordering")
        check(!around.side("newer").rows().map(\.id).contains("s-3"),
              "nor does an iCloud-only row")

        checkEqual((await fixture.router.reply(Req.get("/api/timeline/around", query: ["id": "no-such-asset"]))).status, 404,
                   "an unknown identifier is a 404")
        checkEqual((await fixture.router.reply(Req.get("/api/timeline/around"))).status, 400, "a missing anchor is a 400")
        checkEqual((await fixture.router.reply(Req.get("/api/timeline/around", query: ["id": ""]))).status, 400,
                   "an empty anchor is a 400")

        // The scored anchor still comes back with its real score — the assertion
        // that used to sit here (`anchor.score == 0`, the unscored anchor accepted
        // with a 200) documented the defect, and is covered by the next case.
        let scored = await fixture.router.reply(Req.get("/api/timeline/around", query: ["id": "s-1", "limit": "50"]))
        checkEqual((scored.json["anchor"] as? [String: Any])?["id"] as? String, "s-1", "the scored anchor comes back")
        checkEqual(((scored.json["anchor"] as? [String: Any])?["score"] as? NSNumber)?.floatValue, 0.5,
                   "with its own score, not a substituted zero")
        check(!scored.rows().contains { $0.id == "s-1" }, "and is in neither side of its own window")
    })

    Registry.shared.add(suite: suite, TestCase(name: "an unscored asset cannot anchor the window",
        knownBug: nil) {
        // The contract above `Router.timelineAround` says the anchor "must be an
        // asset this instance has scored". It was documented and not enforced: the
        // anchor was resolved with `cache.photo(identifier:)`, which matches any
        // cached row, so a pending or iCloud-only asset was answered 200 with an
        // `anchor` carrying `score: 0` (`PhotoRow.score` is non-optional, so an
        // absent score is indistinguishable from a real 0.0) and a window that
        // cannot contain it — a hole where the anchor should be.
        let fixture = try await Fixture.make("timeline-unscored-anchor")
        try await fixture.seed([
            .init(id: "u-1", score: 0.5, date: 1000),
            .init(id: "u-2", score: nil, date: 1001, state: .pending),
            .init(id: "u-3", score: nil, date: 1002, state: .unavailable),
            .init(id: "u-4", score: nil, date: 1003, state: .failed),
            .init(id: "u-5", score: 0.6, date: 1004),
        ])
        for unscored in ["u-2", "u-3", "u-4"] {
            let reply = await fixture.router.reply(Req.get("/api/timeline/around",
                query: ["id": unscored, "limit": "50"]))
            checkEqual(reply.status, 404, "\(unscored) has no position in a score-bounded ordering")
            check(reply.has("anchor") == false, "\(unscored): no anchor is invented for it")
            checkEqual(reply.rows(), [], "\(unscored): and no window is returned")
        }
        // The scored rows around them are untouched: a 404 for an unscored anchor
        // must not have narrowed the window for the rest.
        let around = await fixture.router.reply(Req.get("/api/timeline/around", query: ["id": "u-1", "limit": "50"]))
        checkEqual(around.int("total"), 2, "the window is still every scored row")
        checkEqual(around.side("older").rows().map(\.id), [], "nothing scored is older than u-1")
        checkEqual(around.side("newer").rows().map(\.id), ["u-5"], "and u-5 is newer")
    })

    Registry.shared.add(suite: suite, TestCase(name: "timeline/page refuses a missing, unknown or malformed cursor",
        knownBug: nil) {
        let fixture = try await Fixture.make("timeline-badcursor")
        try await fixture.seed(TimelineDataset.seeds())
        let around = await fixture.router.reply(Req.get("/api/timeline/around", query: ["id": "d-020", "limit": "3"]))
        let cursor = checkNotNil(around.side("older").string("nextCursor"), "a cursor to replay") ?? "x"

        checkEqual((await fixture.router.reply(Req.get("/api/timeline/page", query: ["cursor": cursor]))).status, 400,
                   "a missing direction is refused")
        for direction in ["sideways", "", "OLDER", "date_desc", "oldest"] {
            let reply = await fixture.router.reply(Req.get("/api/timeline/page",
                query: ["direction": direction, "cursor": cursor]))
            checkEqual(reply.status, 400, "direction \"\(direction)\" must be refused rather than defaulted")
        }
        checkEqual((await fixture.router.reply(Req.get("/api/timeline/page", query: ["direction": "older"]))).status, 400,
                   "a missing cursor is refused")
        checkEqual((await fixture.router.reply(Req.get("/api/timeline/page",
            query: ["direction": "older", "cursor": ""]))).status, 400, "an empty cursor is refused")
        for bad in ["not-base64!!", "eyJ4IjoxfQ", "@@@@", "eyJzY29yZSI6MC4wMDAwMDAwMDAwMDAwMDAwMDAwMDB9"] {
            let reply = await fixture.router.reply(Req.get("/api/timeline/page",
                query: ["direction": "older", "cursor": bad]))
            checkEqual(reply.status, 400, "malformed cursor \"\(bad)\" is refused rather than silently restarting")
            check(reply.errorMessage.lowercased().contains("cursor"),
                  "the message names the cursor, got: \(reply.errorMessage)")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a cursor is refused for the other direction", knownBug: nil) {
        // The token records the ordering it was issued for. Replaying an `older`
        // token against `direction=newer` used to be answered with a *correct page of
        // photos from an unrelated part of the window* — the one failure mode worse
        // than an error — so it must be refused instead.
        let fixture = try await Fixture.make("timeline-mixedcursor")
        try await fixture.seed(TimelineDataset.seeds())
        let around = await fixture.router.reply(Req.get("/api/timeline/around", query: ["id": "d-020", "limit": "3"]))
        guard let cursor = checkNotNil(around.side("older").string("nextCursor"), "older cursor") else { return }

        let refused = await fixture.router.reply(Req.get("/api/timeline/page",
            query: ["direction": "newer", "cursor": cursor, "limit": "3"]))
        check(refused.status >= 400, "an older cursor cannot drive a newer page, got \(refused.status)")
        checkEqual(refused.rows(), [], "and no rows at all are returned")
        check(refused.errorMessage.contains(TimelineDirection.older.sort.rawValue)
                && refused.errorMessage.contains(TimelineDirection.newer.sort.rawValue),
              "the message names both orderings, got: \(refused.errorMessage)")

        let accepted = await fixture.router.reply(Req.get("/api/timeline/page",
            query: ["direction": "older", "cursor": cursor, "limit": "3"]))
        checkEqual(accepted.status, 200, "the matching direction is accepted")
        check(!accepted.rows().isEmpty, "and returns a page")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a null-dated photo sits at the oldest end of the window",
        knownBug: nil) {
        let fixture = try await Fixture.make("timeline-nulls")
        try await fixture.seed([
            .init(id: "w-1", score: 0.5, date: 1000),
            .init(id: "w-2", score: 0.5, date: 2000),
            .init(id: "w-null", score: 0.5, date: nil),
        ])
        let around = await fixture.router.reply(Req.get("/api/timeline/around", query: ["id": "w-1", "limit": "50"]))
        let older = around.side("older").rows()
        checkEqual(older.map(\.id), ["w-null"], "a null date is older than 1000")
        checkNil(older.first?.date, "and it arrives with no date")
        checkEqual(older.first?.hadDateKey, false, "the encoder drops nil optionals rather than sending null")
    })

    Registry.shared.add(suite: suite, TestCase(name: "timeline limit is clamped exactly like the grid's",
        knownBug: nil) {
        let fixture = try await Fixture.make("timeline-clamp")
        // 500 rows with unique dates, anchored in the middle, so both sides are long
        // enough to be clamped rather than exhausted.
        try await fixture.seed((0..<500).map {
            .init(id: "c-\(String(format: "%04d", $0))", score: Float($0 % 7) / 8, date: Double(1000 + $0))
        })
        checkEqual((await fixture.router.reply(Req.get("/api/timeline/around",
            query: ["id": "c-0250", "limit": "100000"]))).side("older").rows().count, 200,
                   "clamped to the maximum page size")
        checkEqual((await fixture.router.reply(Req.get("/api/timeline/around",
            query: ["id": "c-0250", "limit": "100000"]))).side("newer").rows().count, 200,
                   "on both sides")
        checkEqual((await fixture.router.reply(Req.get("/api/timeline/around",
            query: ["id": "c-0250", "limit": "0"]))).side("older").rows().count, 1, "clamped up to 1")
        checkEqual((await fixture.router.reply(Req.get("/api/timeline/around",
            query: ["id": "c-0250", "limit": "-1"]))).side("older").rows().count, 1, "a negative limit clamps to 1")
        checkEqual((await fixture.router.reply(Req.get("/api/timeline/around",
            query: ["id": "c-0250", "limit": "lots"]))).side("older").rows().count, 60,
                   "an unparseable limit falls back to the default page size")
    })
}

// MARK: - Ordering helpers

/// Strictly ordered by `(date DESC, id ASC)` — the `newestFirst` total order.
func checkDescending(_ rows: [Row], _ what: String) {
    guard rows.count > 1 else { return }
    for index in 1..<rows.count {
        let previous = rows[index - 1], current = rows[index]
        let previousDate = previous.date ?? 0, currentDate = current.date ?? 0
        check(previousDate > currentDate || (previousDate == currentDate && previous.id < current.id),
              "\(what): \(previous.id)@\(previousDate) must come strictly before \(current.id)@\(currentDate)")
    }
}

/// Strictly ordered by `(date ASC, id DESC)` — the `timelineNewer` total order,
/// which is `newestFirst` with every key reversed.
///
/// Reversing it for display is what makes the newer side meet the older side at
/// the anchor in one continuous order; the tie-break has to flip with the date or
/// the two sides cannot partition a burst.
func checkNewerAscending(_ rows: [Row], _ what: String) {
    guard rows.count > 1 else { return }
    for index in 1..<rows.count {
        let previous = rows[index - 1], current = rows[index]
        let previousDate = previous.date ?? 0, currentDate = current.date ?? 0
        check(previousDate < currentDate || (previousDate == currentDate && previous.id > current.id),
              "\(what): \(previous.id)@\(previousDate) must come strictly before \(current.id)@\(currentDate)")
    }
}

enum TimelineDataset {
    /// 45 rows: a six-way date tie, three large tied groups, a group of dateless
    /// rows, and rows tied on score and date simultaneously.
    static func seeds() -> [Fixture.Seed] {
        var seeds: [Fixture.Seed] = []
        var index = 0
        func add(_ date: Double?, _ score: Float) {
            index += 1
            seeds.append(.init(id: "d-\(String(format: "%03d", index))", score: score, date: date))
        }
        for _ in 0..<6 { add(2000, 0.5) }
        for _ in 0..<10 { add(1000, 0.5) }
        for _ in 0..<15 { add(3000, 0.25) }
        for _ in 0..<4 { add(4000, -0.5) }
        for _ in 0..<4 { add(nil, 0.75) }
        for step in 0..<6 { add(Double(500 + step), 0.9) }
        return seeds
    }
}