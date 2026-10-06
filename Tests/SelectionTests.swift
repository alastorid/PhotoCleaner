import Foundation

// Selection resolution and the count contract.
//
// `Router.resolveSelection` is `private`, so it is reached the way a browser
// reaches it: `POST /api/selection/preview` through the real `Router.handle`.
// That also means the HTTP status codes, the JSON field names and the gate order
// are all covered, not just the resolution itself.
//
// The identity under test, read out of `ResolvedSelection`:
//
//   requestedCount  = identifiers this instance recognised, *before* protection
//   candidates      = those identifiers, *after* protection
//   protectedFavorites = favourites removed from that set
//   unknownIdentifiers = distinct identifiers that were not in the cache
//
// so for `ids` mode the exact decomposition is
//
//   distinct identifiers named  ==  resolved + protectedFavorites + unknownIdentifiers
//
// and `requested` is the pre-protection subtotal, i.e.
// `requested == resolved + protectedFavorites`. It is deliberately *not* the count
// of identifiers in the JSON body: unknown ones are reported in their own field so
// "127 requested, 0 eligible" stays expressible.

func registerSelectionTests() {
    let suite = "selection resolution and the count contract"

    // MARK: ids mode

    Registry.shared.add(suite: suite, TestCase(name: "ids mode: the four counts decompose exactly",
        knownBug: nil) {
        let fixture = try await Fixture.make("selection-ids")
        try await fixture.seed([
            .init(id: "known-1", score: 0.4, date: 100),
            .init(id: "known-2", score: 0.3, date: 200),
            .init(id: "fav-1", score: 0.2, date: 300, favorite: true),
        ])
        // Two identifiers this instance has never seen, plus a repeat of a known one.
        let reply = await fixture.router.reply(Req.post("/api/selection/preview", json: """
        {"mode":"ids","ids":["known-1","known-2","fav-1","ghost-1","ghost-2","known-1"]}
        """))

        checkEqual(reply.status, 200, "status")
        checkEqual(reply.int("requested"), 3, "requested counts the identifiers the cache knows")
        checkEqual(reply.int("resolved"), 2, "resolved excludes the protected favourite")
        checkEqual(reply.int("protectedFavorites"), 1, "the favourite is reported, not silently dropped")
        checkEqual(reply.int("unknownIdentifiers"), 2, "unknown identifiers are counted distinctly")
        checkEqual(reply.int("resolved"), 0 + 2, "resolved + protectedFavorites must equal requested")
        checkEqual(reply.string("mode"), "ids", "mode echo")
        checkEqual(reply.bool("appliesToAllMatching"), false, "ids mode is not 'all matching'")
        check(reply.string("confirmToken")?.isEmpty == false, "a confirmToken is always issued")
    })

    Registry.shared.add(suite: suite, TestCase(name: "ids mode: a repeated identifier is not 'unknown'",
        knownBug: nil) {
        let fixture = try await Fixture.make("selection-dupes")
        try await fixture.seed([.init(id: "a", score: 0.1, date: 1)])
        let knownTwice = await fixture.router.reply(Req.post("/api/selection/preview", json: """
        {"mode":"ids","ids":["a","a","a"]}
        """))
        checkEqual(knownTwice.status, 200, "status")
        checkEqual(knownTwice.int("resolved"), 1, "one row cannot be resolved three times")
        checkEqual(knownTwice.int("unknownIdentifiers"), 0, "a repeat of a known id is not unknown")
        checkEqual(knownTwice.int("resolved")! + knownTwice.int("unknownIdentifiers")!, 1,
                   "the decomposition still holds for a repeated identifier")

        let unknownTwice = await fixture.router.reply(Req.post("/api/selection/preview", json: """
        {"mode":"ids","ids":["ghost","ghost"]}
        """))
        checkEqual(unknownTwice.int("unknownIdentifiers"), 1, "distinct counting for unknown ids too")
        checkEqual(unknownTwice.int("requested"), 0, "an unknown identifier is never 'requested'")
    })

    Registry.shared.add(suite: suite, TestCase(name: "ids mode: near-miss identifiers are unknown, not resolved",
        knownBug: nil) {
        let fixture = try await Fixture.make("selection-nearmiss")
        try await fixture.seed([.init(id: "ABC-123/L0/001", score: 0.5, date: 10)])
        let reply = await fixture.router.reply(Req.post("/api/selection/preview", json: """
        {"mode":"ids","ids":["abc-123/L0/001","ABC-123/L0/001 ","ABC-123/L0/001%00","ABC-123/L0/002"]}
        """))
        checkEqual(reply.int("resolved"), 0, "only the exactly-matching identifier resolves")
        checkEqual(reply.int("unknownIdentifiers"), 4, "each near-miss is reported as unknown")
    })

    Registry.shared.add(suite: suite, TestCase(name: "ids mode: an empty ids array resolves to nothing",
        knownBug: nil) {
        let fixture = try await Fixture.make("selection-empty")
        try await fixture.seed([.init(id: "a", score: 0.1, date: 1)])
        let reply = await fixture.router.reply(Req.post("/api/selection/preview", json: #"{"mode":"ids","ids":[]}"#))
        checkEqual(reply.status, 200, "status")
        checkEqual(reply.int("requested"), 0, "requested")
        checkEqual(reply.int("resolved"), 0, "resolved")
        checkEqual(reply.int("protectedFavorites"), 0, "protectedFavorites")
        checkEqual(reply.int("unknownIdentifiers"), 0, "unknownIdentifiers")
        // Deliberately legitimate: an explicit empty array is a cleared selection,
        // which is a real "nothing to do" — unlike a *missing* `ids` key, below.
    })

    Registry.shared.add(suite: suite, TestCase(name: "ids mode: a missing ids key is refused rather than treated as empty",
        knownBug: nil) {
        // `Router.resolveSelection` had no `missingFilter`-style error for `ids`
        // mode, so `{"mode":"ids"}` with no `ids` key resolved to a silent empty
        // selection and answered 200 — the exact asymmetry `SelectionError`'s own
        // doc comment ("Never a silent empty result") forbids, and the opposite of
        // how matching mode treats its missing argument.
        let fixture = try await Fixture.make("selection-no-ids")
        try await fixture.seed([.init(id: "a", score: 0.1, date: 1)])
        let preview = await fixture.router.reply(Req.post("/api/selection/preview", json: #"{"mode":"ids"}"#))
        checkEqual(preview.status, 400, "a mode of ids with no ids is a malformed specification")
        check(preview.errorMessage.contains("ids"), "the message names the missing key, got: \(preview.errorMessage)")
        check(preview.has("confirmToken") == false, "and no confirm token is minted for it")
        // The destructive route shares the resolver, so it refuses identically.
        // The fixture's single row is therefore never selected and nothing can
        // reach `PhotoLibrary.delete` from this case.
        let deletion = await fixture.router.reply(Req.post("/api/delete", json: #"{"mode":"ids"}"#))
        checkEqual(deletion.status, 400, "and the deletion route refuses it too")
        checkEqual(deletion.has("deleted") == false, true, "rather than reporting a deletion report at all")
        checkEqual((try? await fixture.cache.stats(maxAge: 0))?.total, 1, "the cache is untouched")
        // `null` is as absent as omitted, and `exclude` is not a substitute for the
        // argument the mode actually names.
        for body in [#"{"mode":"ids","ids":null}"#, #"{"mode":"ids","exclude":["a"]}"#] {
            checkEqual((await fixture.router.reply(Req.post("/api/selection/preview", json: body))).status, 400,
                       "\(body) must not read as a cleared selection")
        }
    })

    // MARK: mode / filter rejection

    for badMode in ["match", "all", "", "IDS", "IdS", "matching "] {
        Registry.shared.add(suite: suite, TestCase(name: "mode \"\(badMode)\" is refused", knownBug: nil) {
            let fixture = try await Fixture.make("selection-mode-\(abs(badMode.hashValue))")
            try await fixture.seed([.init(id: "known", score: 0.9, date: 1), .init(id: "fav", score: 0.9, date: 2, favorite: true)])
            let reply = await fixture.router.reply(Req.post("/api/selection/preview",
                json: #"{"mode":"\#(badMode)","ids":["known","fav"]}"#))
            checkEqual(reply.status, 400, "mode \"\(badMode)\" must not fall through to ids")
            check(reply.errorMessage.contains("expected"), "the message names the two legal modes, got: \(reply.errorMessage)")
        })
    }

    Registry.shared.add(suite: suite, TestCase(name: "matching mode without a filter is refused", knownBug: nil) {
        let fixture = try await Fixture.make("selection-nofilter")
        let reply = await fixture.router.reply(Req.post("/api/selection/preview", json: #"{"mode":"matching"}"#))
        checkEqual(reply.status, 400, "status")
        check(reply.errorMessage.contains("requires a filter"), "message, got: \(reply.errorMessage)")
    })

    Registry.shared.add(suite: suite, TestCase(name: "matching filter without lo is refused", knownBug: nil) {
        let fixture = try await Fixture.make("selection-nolo")
        let reply = await fixture.router.reply(Req.post("/api/selection/preview", json: #"{"mode":"matching","filter":{"hi":1}}"#))
        checkEqual(reply.status, 400, "status")
        check(reply.errorMessage.contains("lo and hi"), "message, got: \(reply.errorMessage)")
    })

    Registry.shared.add(suite: suite, TestCase(name: "matching filter without hi is refused", knownBug: nil) {
        let fixture = try await Fixture.make("selection-nohi")
        let reply = await fixture.router.reply(Req.post("/api/selection/preview", json: #"{"mode":"matching","filter":{"lo":-1}}"#))
        checkEqual(reply.status, 400, "status")
        check(reply.errorMessage.contains("lo and hi"), "message, got: \(reply.errorMessage)")
    })

    Registry.shared.add(suite: suite, TestCase(name: "matching filter with an out-of-enum favorites value is refused",
        knownBug: nil) {
        let fixture = try await Fixture.make("selection-badfav")
        for value in ["sometimes", "Include", "EXCLUDE", "true", ""] {
            let reply = await fixture.router.reply(Req.post("/api/selection/preview",
                json: #"{"mode":"matching","filter":{"lo":-1,"hi":1,"favorites":"\#(value)"}}"#))
            checkEqual(reply.status, 400, "favorites=\"\(value)\" must not fall back to the default")
        }
    })

    // The utility filter is gone. A client predating that removal still sends the
    // parameter, so what matters now is that it is *ignored* — neither an error,
    // nor a filter, and above all not a silently narrowed selection.
    Registry.shared.add(suite: suite, TestCase(name: "a stale utility filter is ignored, not refused and not applied",
        knownBug: nil) {
        let fixture = try await Fixture.make("selection-staleutil")
        try await fixture.seed([
            .init(id: "a", score: 0.1, date: 1),
            .init(id: "b", score: 0.2, date: 2),
            .init(id: "c", score: 0.3, date: 3),
        ])
        let plain = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"matching","filter":{"lo":-1,"hi":1}}"#))
        for value in ["only", "hide", "include", "nonsense", ""] {
            let stale = await fixture.router.reply(Req.post("/api/selection/preview",
                json: #"{"mode":"matching","filter":{"lo":-1,"hi":1,"utility":"\#(value)"}}"#))
            checkEqual(stale.status, 200, "utility=\"\(value)\" must not fail a request")
            checkEqual(stale.int("requested"), plain.int("requested"),
                       "utility=\"\(value)\" must not narrow the selection")
            checkEqual(stale.int("resolved"), plain.int("resolved"),
                       "utility=\"\(value)\" must not change what is deletable")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "every in-enum favorites value is accepted",
        knownBug: nil) {
        let fixture = try await Fixture.make("selection-enum-ok")
        try await fixture.seed([.init(id: "a", score: 0.1, date: 1), .init(id: "b", score: 0.2, date: 2)])
        for favorites in ["include", "exclude", "only"] {
            let reply = await fixture.router.reply(Req.post("/api/selection/preview",
                json: #"{"mode":"matching","filter":{"lo":-2,"hi":2,"favorites":"\#(favorites)"}}"#))
            checkEqual(reply.status, 200, "favorites=\(favorites)")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "malformed JSON is refused", knownBug: nil) {
        let fixture = try await Fixture.make("selection-json")
        for body in ["", "{", "[]", "null", #"{"mode":1}"#, #"{"mode":"ids","ids":"not-an-array"}"#] {
            let reply = await fixture.router.reply(Req.post("/api/selection/preview", json: body))
            checkEqual(reply.status, 400, "body \(body.prefix(24).description) must be refused")
        }
    })

    // MARK: matching mode

    Registry.shared.add(suite: suite, TestCase(name: "matching mode resolves the whole filter, not one page",
        knownBug: nil) {
        let fixture = try await Fixture.make("selection-matching")
        var assets: [Fixture.Seed] = (0..<40).map {
            .init(id: "m-\($0)", score: Float($0) / 100, date: Double(1_000 + $0))
        }
        assets.append(.init(id: "m-fav", score: 0.9, date: 2000, favorite: true))
        try await fixture.seed(assets)

        let reply = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"matching","filter":{"lo":-1,"hi":1}}"#))
        checkEqual(reply.status, 200, "status")
        checkEqual(reply.int("resolved"), 40, "every matching row, not a 60-row page")
        checkEqual(reply.int("protectedFavorites"), 1, "the favourite is separated out")
        checkEqual(reply.int("unknownIdentifiers"), 0, "matching mode cannot name unknown identifiers")
        checkEqual(reply.int("requested"), 41, "requested is the pre-protection count")
        checkEqual(reply.bool("appliesToAllMatching"), true, "appliesToAllMatching")
        checkEqual(reply.bool("truncated"), false, "41 matches is nowhere near the cap")
        check(reply.has("nextCursor") == false, "a preview is not a page and carries no cursor")
    })

    Registry.shared.add(suite: suite, TestCase(name: "matching bounds are inclusive at both ends", knownBug: nil) {
        let fixture = try await Fixture.make("selection-bounds")
        try await fixture.seed([
            .init(id: "below", score: -0.9959, date: 1),
            .init(id: "at-lo", score: -0.5, date: 2),
            .init(id: "middle", score: 0.6, date: 3),
            .init(id: "at-hi", score: 0.5, date: 4),
            .init(id: "above", score: 1.0, date: 5),
        ])
        let reply = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"matching","filter":{"lo":-0.5,"hi":0.5}}"#))
        checkEqual(reply.int("resolved"), 2, "lo and hi are inclusive; the two scores outside are excluded")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a reversed range resolves to nothing", knownBug: nil) {
        let fixture = try await Fixture.make("selection-reversed")
        try await fixture.seed((0..<10).map { .init(id: "r-\($0)", score: 0.5, date: Double($0)) })
        let reply = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"matching","filter":{"lo":0.9,"hi":0.1}}"#))
        checkEqual(reply.status, 200, "status")
        checkEqual(reply.int("resolved"), 0, "an inverted range must never mean 'everything'")
    })

    Registry.shared.add(suite: suite, TestCase(name: "matching honours favorites:only", knownBug: nil) {
        let fixture = try await Fixture.make("selection-only")
        try await fixture.seed([
            .init(id: "plain", score: 0.1, date: 1),
            .init(id: "fav", score: 0.2, date: 2, favorite: true),
            .init(id: "fav-2", score: 0.4, date: 4, favorite: true),
        ])
        let favoritesOnly = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"matching","filter":{"lo":-1,"hi":1,"favorites":"only"}}"#))
        checkEqual(favoritesOnly.int("protectedFavorites"), 2, "both favourites are found")
        checkEqual(favoritesOnly.int("resolved"), 0, "favorites:only resolves to nothing deletable")
        checkEqual(favoritesOnly.int("requested"), 2, "and the plain photo is not in the set")

        let excluded = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"matching","filter":{"lo":-1,"hi":1,"favorites":"exclude"}}"#))
        checkEqual(excluded.int("protectedFavorites"), 0, "exclude protects nothing, because it excludes them")
        checkEqual(excluded.int("resolved"), 1, "so the one plain photo is deletable")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the exclude list removes identifiers and never double-counts",
        knownBug: nil) {
        let fixture = try await Fixture.make("selection-exclude")
        try await fixture.seed([
            .init(id: "keep-1", score: 0.1, date: 1),
            .init(id: "keep-2", score: 0.2, date: 2),
            .init(id: "drop", score: 0.3, date: 3),
            .init(id: "drop-fav", score: 0.4, date: 4, favorite: true),
        ])
        let reply = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"matching","filter":{"lo":-1,"hi":1},"exclude":["drop","drop-fav","never-existed"]}"#))
        checkEqual(reply.status, 200, "status")
        checkEqual(reply.int("resolved"), 2, "the two kept rows")
        checkEqual(reply.int("protectedFavorites"), 0, "an excluded favourite is not 'protected'")
        checkEqual(reply.int("requested"), 2, "requested is measured after the exclusion")
        checkEqual(reply.int("resolved")! + reply.int("protectedFavorites")!, reply.int("requested")!,
                   "the decomposition survives exclusion")
    })

    // MARK: cross-origin gate

    Registry.shared.add(suite: suite, TestCase(name: "cross-site Sec-Fetch-Site is refused with 403", knownBug: nil) {
        let fixture = try await Fixture.make("selection-secfetch")
        try await fixture.seed([.init(id: "a", score: 0.1, date: 1)])
        for site in ["cross-site", "same-site", "none-site"] {
            let reply = await fixture.router.reply(Req.post("/api/selection/preview",
                json: #"{"mode":"ids","ids":["a"]}"#, headers: ["sec-fetch-site": site]))
            checkEqual(reply.status, 403, "Sec-Fetch-Site: \(site)")
        }
        for site in ["same-origin", "none", "SAME-ORIGIN", "None"] {
            let reply = await fixture.router.reply(Req.post("/api/selection/preview",
                json: #"{"mode":"ids","ids":["a"]}"#, headers: ["sec-fetch-site": site]))
            checkEqual(reply.status, 200, "Sec-Fetch-Site: \(site) must be allowed")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a mismatched Origin is refused, a matching one is allowed",
        knownBug: nil) {
        let fixture = try await Fixture.make("selection-origin")
        try await fixture.seed([.init(id: "a", score: 0.1, date: 1)])
        let host = ["host": "127.0.0.1:8765"]
        let hostile = [
            ["host": "127.0.0.1:8765", "origin": "http://evil.example"],
            ["host": "127.0.0.1:8765", "origin": "null"],
            ["host": "127.0.0.1:8765", "origin": "https://127.0.0.1:8765"],
            ["host": "127.0.0.1:8765", "origin": "http://127.0.0.1:8766"],
            ["origin": "http://evil.example"],
        ]
        for headers in hostile {
            let reply = await fixture.router.reply(Req.post("/api/selection/preview",
                json: #"{"mode":"ids","ids":["a"]}"#, headers: headers))
            checkEqual(reply.status, 403, "origin \(headers["origin"] ?? "<none>") host \(headers["host"] ?? "<none>")")
        }
        let allowed = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["a"]}"#, headers: host.merging(["origin": "http://127.0.0.1:8765"]) { $1 }))
        checkEqual(allowed.status, 200, "a same-origin Origin with a matching Host is allowed")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a headerless POST is allowed so the JSON API stays scriptable",
        knownBug: nil) {
        let fixture = try await Fixture.make("selection-noheaders")
        try await fixture.seed([.init(id: "a", score: 0.1, date: 1)])
        let reply = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["a"]}"#, headers: [:]))
        checkEqual(reply.status, 200, "curl-style requests carry neither header and must work")
    })

    // MARK: destructive routes

    Registry.shared.add(suite: suite, TestCase(name: "nothing destructive is reachable with GET", knownBug: nil) {
        let fixture = try await Fixture.make("selection-get")
        try await fixture.seed([.init(id: "a", score: 0.1, date: 1)])
        for path in ["/api/delete", "/api/settings", "/api/selection/preview", "/api/analysis/retry", "/api/library/rescan"] {
            let reply = await fixture.router.reply(Req.get(path))
            checkEqual(reply.status, 404, "GET \(path) must not exist")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a deletion whose identifiers are all unknown changes nothing",
        knownBug: nil) {
        // Safe to send: `resolveSelection` returns no candidates, so
        // `Router.delete` never calls `PhotoLibrary.delete` (Router.swift:671).
        let fixture = try await Fixture.make("selection-delete-unknown")
        try await fixture.seed([.init(id: "real", score: 0.1, date: 1)])
        let reply = await fixture.router.reply(Req.post("/api/delete",
            json: #"{"mode":"ids","ids":["ghost-a","ghost-b"]}"#))
        checkEqual(reply.status, 200, "status")
        checkEqual(reply.int("requested"), 0, "requested")
        checkEqual(reply.int("resolved"), 0, "resolved")
        checkEqual(reply.int("deleted"), 0, "deleted")
        checkEqual(reply.int("missing"), 0, "missing")
        checkEqual(reply.int("unknownIdentifiers"), 2, "unknownIdentifiers")
        checkEqual(reply.int("protectedFavorites"), 0, "protectedFavorites")
        checkEqual((try? await fixture.cache.stats(maxAge: 0))?.total, 1, "the cache is untouched")
    })
}