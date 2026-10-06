import Foundation

// Favourite protection must fail *closed*.
//
// This is the single most safety-critical behaviour in the tool: it decides which
// photos are allowed to be destroyed. `Router.resolveSelection` (Router.swift:552)
// partitions the candidate set from the cache's stored `favorite` flags, and if
// that partition cannot be computed it throws `SelectionError.favoriteCheckFailed`
// — an *error*, never "there are no favourites". The case
// `favourite partition fails closed` below breaks the `favorite` column on purpose
// so that the real `CacheStore.partitionFavorites` really does fail, and asserts
// the resolution does not degrade into a full, deletable selection.

func registerFavouriteProtectionTests() {
    let suite = "favourite protection fails closed"

    Registry.shared.add(suite: suite, TestCase(name: "protection on: favourites are excluded and counted",
        knownBug: nil) {
        let fixture = try await Fixture.make("fav-on")
        try await fixture.seed([
            .init(id: "plain-1", score: 0.1, date: 1),
            .init(id: "plain-2", score: 0.2, date: 2),
            .init(id: "fav-1", score: 0.3, date: 3, favorite: true),
            .init(id: "fav-2", score: 0.4, date: 4, favorite: true),
        ])
        let reply = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["plain-1","plain-2","fav-1","fav-2"]}"#))
        checkEqual(reply.status, 200, "status")
        checkEqual(reply.int("resolved"), 2, "only the non-favourites survive")
        checkEqual(reply.int("protectedFavorites"), 2, "both favourites are reported")
        checkEqual(reply.int("requested"), 4, "requested is what was asked for")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a selection of nothing but favourites resolves to nothing",
        knownBug: nil) {
        let fixture = try await Fixture.make("fav-only")
        try await fixture.seed([
            .init(id: "fav-1", score: 0.3, date: 1, favorite: true),
            .init(id: "fav-2", score: 0.4, date: 2, favorite: true),
        ])
        let reply = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["fav-1","fav-2"]}"#))
        checkEqual(reply.int("resolved"), 0, "nothing is deletable")
        checkEqual(reply.int("protectedFavorites"), 2, "but the reason is reported, not hidden")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the favourite partition fails closed", knownBug: nil) {
        let fixture = try await Fixture.make("fav-failclosed")
        try await fixture.seed([
            .init(id: "plain-1", score: 0.1, date: 1),
            .init(id: "plain-2", score: 0.2, date: 2),
            .init(id: "fav-1", score: 0.3, date: 3, favorite: true),
        ])
        // Sanity: before the damage, the favourites are correctly separated.
        let before = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["plain-1","plain-2","fav-1"]}"#))
        checkEqual(before.int("resolved"), 2, "baseline: two deletable")
        checkEqual(before.int("protectedFavorites"), 1, "baseline: one protected")

        // Rename the column the partition reads. `known()` still works, so the
        // failure lands exactly on `CacheStore.partitionFavorites` — which is the
        // one query whose failure has to be unrecoverable.
        try RawSQL.exec(fixture.cachePath, "ALTER TABLE assets RENAME COLUMN favorite TO favorite_hidden;")

        let ids = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["plain-1","plain-2","fav-1"]}"#))
        check(ids.status == 500,
              "a failed favourite check must be an error, not a resolution. Got \(ids.status): \(ids.errorMessage)")
        check(ids.errorMessage.contains("favorites"),
              "the message must say why nothing was selected, got: \(ids.errorMessage)")
        checkEqual(ids.int("resolved"), nil, "no resolution may be reported at all")
        checkEqual(ids.has("confirmToken"), false, "no confirmToken may be issued for an unresolved selection")

        let matching = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"matching","filter":{"lo":-1,"hi":1}}"#))
        check(matching.status == 500, "the same must hold in matching mode, got \(matching.status)")

        let deletion = await fixture.router.reply(Req.post("/api/delete",
            json: #"{"mode":"ids","ids":["plain-1","plain-2","fav-1"]}"#))
        checkEqual(deletion.status, 500, "and on the destructive route, which must refuse")
        checkEqual(deletion.int("deleted"), nil, "a deletion report must not be produced")
    })

    Registry.shared.add(suite: suite, TestCase(name: "allowFavorites overrides protection for one request",
        knownBug: nil) {
        let fixture = try await Fixture.make("fav-override")
        try await fixture.seed([
            .init(id: "plain", score: 0.1, date: 1),
            .init(id: "fav", score: 0.2, date: 2, favorite: true),
        ])
        let overridden = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["plain","fav"],"allowFavorites":true}"#))
        checkEqual(overridden.int("resolved"), 2, "an explicit per-request override includes favourites")
        checkEqual(overridden.int("protectedFavorites"), 0, "and reports none as protected")

        let explicitFalse = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["plain","fav"],"allowFavorites":false}"#))
        checkEqual(explicitFalse.int("resolved"), 1, "an explicit false is the same as omitting it")
        checkEqual(explicitFalse.int("protectedFavorites"), 1, "and protection still applies")
    })

    Registry.shared.add(suite: suite, TestCase(name: "protection is not switchable from the request body",
        knownBug: nil) {
        let fixture = try await Fixture.make("fav-body-switch")
        try await fixture.seed([
            .init(id: "plain", score: 0.1, date: 1),
            .init(id: "fav", score: 0.2, date: 2, favorite: true),
        ])
        // Unknown keys are ignored by the decoder, so a client cannot weaken the
        // rail by inventing a field for it.
        let reply = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["plain","fav"],"protectFavorites":false,"favorite":true}"#))
        checkEqual(reply.int("resolved"), 1, "an invented field cannot turn protection off")
        checkEqual(reply.int("protectedFavorites"), 1, "the favourite is still protected")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a non-boolean allowFavorites is refused, not coerced",
        knownBug: nil) {
        let fixture = try await Fixture.make("fav-badbool")
        try await fixture.seed([.init(id: "fav", score: 0.2, date: 1, favorite: true)])
        // `null` is deliberately absent from this list: `Bool?` decodes JSON null to
        // `nil`, which is the *same* as omitting the field, and both leave protection
        // on. That is the safe direction, so it is the intended reading.
        for value in [#""true""#, #"1"#, #"{}"#, #"[]"#] {
            let reply = await fixture.router.reply(Req.post("/api/selection/preview",
                json: #"{"mode":"ids","ids":["fav"],"allowFavorites":\#(value)}"#))
            checkEqual(reply.status, 400, "allowFavorites=\(value) must not be coerced")
        }
        let nulled = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["fav"],"allowFavorites":null}"#))
        checkEqual(nulled.int("resolved"), 0, "an explicit null is not an override")
        checkEqual(nulled.int("protectedFavorites"), 1, "the favourite stays protected")
    })

    Registry.shared.add(suite: suite, TestCase(name: "protection off in settings includes favourites and reports zero",
        knownBug: nil) {
        let fixture = try await Fixture.make("fav-setting-off", protectFavorites: false)
        try await fixture.seed([
            .init(id: "plain", score: 0.1, date: 1),
            .init(id: "fav", score: 0.2, date: 2, favorite: true),
        ])
        let reply = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["plain","fav"]}"#))
        checkEqual(reply.int("resolved"), 2, "protection off is an explicit, remembered choice")
        checkEqual(reply.int("protectedFavorites"), 0, "and nothing is claimed to be protected")
        checkEqual(fixture.settings.snapshot().protectFavorites, false, "the setting really is off")
    })

    Registry.shared.add(suite: suite, TestCase(name: "protection survives more than one chunk of identifiers",
        knownBug: nil) {
        // `partitionFavorites` and `known` both chunk at 400, so the boundary
        // between chunks is exactly where a favourite could be lost.
        let fixture = try await Fixture.make("fav-chunks")
        let count = 1_100
        var assets: [Fixture.Seed] = (0..<count).map {
            .init(id: "c-\($0)", score: Float($0) / 10_000, date: Double($0))
        }
        for index in stride(from: 0, to: count, by: 7) {
            assets[index].favorite = true
        }
        try await fixture.seed(assets)
        let favourites = assets.filter(\.favorite).count
        let ids = assets.map(\.id)
        let reply = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["\#(ids.joined(separator: "\",\""))"]}"#))
        checkEqual(reply.status, 200, "status")
        checkEqual(reply.int("requested"), count, "requested")
        checkEqual(reply.int("protectedFavorites"), favourites, "every favourite is found across all chunks")
        checkEqual(reply.int("resolved"), count - favourites, "and every non-favourite is still deletable")
    })
}