import Foundation

// `confirmToken`: the fingerprint that stands between "what the user reviewed" and
// "what gets deleted".
//
// The two requests are separated in time, so the library can change in between. The
// preview hands back a token over the *resolved, post-protection* candidate set;
// `/api/delete` recomputes it and refuses with 409 if it no longer matches. That
// makes the digest's properties load-bearing: stable across identical requests
// (including across processes — `hashValue` is seeded per process and would never
// agree), independent of the order the identifiers arrived in, and different
// whenever the resolved set or the mode differs.

func registerConfirmTokenTests() {
    let suite = "confirmToken"

    // MARK: stability

    Registry.shared.add(suite: suite, TestCase(name: "an identical request gets an identical token", knownBug: nil) {
        let fixture = try await Fixture.make("token-stable")
        try await fixture.seed((0..<12).map { .init(id: "k-\($0)", score: 0.1 * Float($0), date: Double($0)) })
        let body = #"{"mode":"ids","ids":["k-1","k-2","k-3"]}"#
        let tokens = try await collectTokens(fixture, body, times: 4)
        checkEqual(Set(tokens).count, 1, "four identical previews must agree: \(tokens)")
        check(tokens.allSatisfy { !$0.isEmpty }, "and never be empty")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the token does not depend on the order of the identifiers",
        knownBug: nil) {
        let fixture = try await Fixture.make("token-order")
        try await fixture.seed((0..<12).map { .init(id: "k-\($0)", score: 0.1 * Float($0), date: Double($0)) })
        let forward = await token(fixture, #"{"mode":"ids","ids":["k-1","k-2","k-3","k-4"]}"#)
        let reversed = await token(fixture, #"{"mode":"ids","ids":["k-4","k-3","k-2","k-1"]}"#)
        let shuffled = await token(fixture, #"{"mode":"ids","ids":["k-3","k-1","k-4","k-2"]}"#)
        checkEqual(Set([forward, reversed, shuffled]).count, 1,
                   "the digest is order-independent, so a UI that reorders its list does not invalidate a review")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the token differs when the resolved set differs", knownBug: nil) {
        let fixture = try await Fixture.make("token-set")
        try await fixture.seed((0..<12).map { .init(id: "k-\($0)", score: 0.1 * Float($0), date: Double($0)) })
        let three = await token(fixture, #"{"mode":"ids","ids":["k-1","k-2","k-3"]}"#)
        let four = await token(fixture, #"{"mode":"ids","ids":["k-1","k-2","k-3","k-4"]}"#)
        let fewer = await token(fixture, #"{"mode":"ids","ids":["k-1","k-2"]}"#)
        checkEqual(Set([three, four, fewer]).count, 3, "each different set has its own token")

        // Unknown identifiers change what was asked for but not what would be
        // deleted, so they must not invalidate a review.
        let withGhosts = await token(fixture, #"{"mode":"ids","ids":["k-1","k-2","k-3","ghost-1","ghost-2"]}"#)
        checkEqual(withGhosts, three, "identifiers that resolve to nothing are not part of the confirmed set")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the token differs when the mode differs", knownBug: nil) {
        let fixture = try await Fixture.make("token-mode")
        try await fixture.seed((0..<6).map { .init(id: "k-\($0)", score: 0.2, date: Double($0)) })
        // A filter that resolves to exactly the same three assets as the ids list.
        let byIDs = await token(fixture, #"{"mode":"ids","ids":["k-0","k-1","k-2"]}"#)
        let byFilter = await token(fixture, #"{"mode":"matching","filter":{"lo":0.2,"hi":0.2}}"#)
        check(byIDs != byFilter, "the same set reached a different way is still a different decision")
    })

    Registry.shared.add(suite: suite, TestCase(name: "favourite protection is part of the confirmed set", knownBug: nil) {
        let fixture = try await Fixture.make("token-favourites")
        try await fixture.seed([
            .init(id: "keep", score: 0.3, date: 1),
            .init(id: "fav", score: 0.3, date: 2, favorite: true),
        ])
        let protected = await token(fixture, #"{"mode":"ids","ids":["keep","fav"]}"#)
        let overridden = await token(fixture, #"{"mode":"ids","ids":["keep","fav"],"allowFavorites":true}"#)
        let justKeep = await token(fixture, #"{"mode":"ids","ids":["keep"]}"#)
        check(protected == justKeep,
              "a protected favourite is not in the confirmed set, so it cannot be used to smuggle one in")
        check(overridden != protected, "and turning protection off genuinely changes what would be deleted")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the token is a digest of the set, not of the request bytes",
        knownBug: nil) {
        let fixture = try await Fixture.make("token-request")
        try await fixture.seed([
            .init(id: "a", score: 0.3, date: 1),
            .init(id: "b", score: 0.3, date: 2),
        ])
        let plain = await token(fixture, #"{"mode":"ids","ids":["a","b"]}"#)
        let spaced = await token(fixture, #"{ "mode" : "ids" , "ids" : [ "a" , "b" ] }"#)
        let reordered = await token(fixture, #"{"ids":["a","b"],"mode":"ids"}"#)
        let withExclude = await token(fixture, #"{"mode":"ids","ids":["a","b"],"exclude":[]}"#)
        checkEqual(Set([plain, spaced, reordered, withExclude]).count, 1,
                   "only the resolved set and the mode matter; the request's spelling does not")
    })

    Registry.shared.add(suite: suite, TestCase(name: "an empty resolution still produces a usable token",
        knownBug: nil) {
        let fixture = try await Fixture.make("token-empty")
        try await fixture.seed([
            .init(id: "fav", score: 0.3, date: 1, favorite: true),
            .init(id: "keep", score: 0.3, date: 2),
        ])
        let preview = await fixture.router.reply(Req.post("/api/selection/preview",
            json: #"{"mode":"ids","ids":["fav"]}"#))
        checkEqual(preview.int("resolved"), 0, "protection leaves nothing")
        check(preview.string("confirmToken")?.isEmpty == false,
              "a token over the empty set is still issued, so the client can pair preview and delete")

        // The accepting path, exercised on a resolution that is empty — so the
        // request can never reach `PhotoLibrary.delete`.
        let accepted = await fixture.router.reply(Req.post("/api/delete",
            json: #"{"mode":"ids","ids":["fav"],"confirmToken":"\#(preview.string("confirmToken") ?? "")"}"#))
        checkEqual(accepted.status, 200, "a current token is accepted")
        checkEqual(accepted.int("requested"), 1, "one identifier was recognised")
        checkEqual(accepted.int("resolved"), 0, "but nothing survived protection")
        checkEqual(accepted.int("deleted"), 0, "nothing was deleted")
        checkEqual(accepted.int("protectedFavorites"), 1, "and the reason is still reported")
    })

    // MARK: the 409 path

    Registry.shared.add(suite: suite, TestCase(name: "a stale confirmToken is refused with 409 and deletes nothing",
        knownBug: nil) {
        // Safe to send: the token check runs *before* `PhotoLibrary.delete` is
        // reached (Router.swift:657), so a refused deletion cannot touch the library.
        let fixture = try await Fixture.make("token-stale")
        try await fixture.seed((0..<6).map { .init(id: "k-\($0)", score: 0.1 * Float($0), date: Double($0)) })

        for stale in ["", "deadbeef", "0", "ffffffffffffffff",
                      await token(fixture, #"{"mode":"ids","ids":["k-1"]}"#),
                      await token(fixture, #"{"mode":"ids","ids":["k-2","k-3"]}"#),
                      await token(fixture, #"{"mode":"matching","filter":{"lo":-1,"hi":1}}"#)] {
            let reply = await fixture.router.reply(Req.post("/api/delete",
                json: #"{"mode":"ids","ids":["k-1","k-2"],"confirmToken":"\#(stale)"}"#))
            checkEqual(reply.status, 409, "stale token \"\(stale)\" must be refused")
            check(reply.errorMessage.lowercased().contains("selection changed"),
                  "the message says the selection changed, got: \(reply.errorMessage)")
            checkEqual(reply.has("deleted"), false, "no deletion report is produced at all")
        }
        checkEqual((try await fixture.cache.stats(maxAge: 0)).total, 6, "the cache is untouched by every refusal")
    })

    Registry.shared.add(suite: suite, TestCase(name: "near-miss tokens are refused, not normalised",
        knownBug: nil) {
        // Every candidate here is *known* to differ from the confirmed token, so
        // none of them can be accepted — and the fixture's only candidate is a
        // favourite, so even an accidental match would resolve to nothing.
        let fixture = try await Fixture.make("token-stale-shapes")
        try await fixture.seed([
            .init(id: "k-1", score: 0.5, date: 1, favorite: true),
            .init(id: "k-2", score: 0.5, date: 2, favorite: true),
        ])
        let current = await token(fixture, #"{"mode":"ids","ids":["k-1"]}"#)
        let mutations: [String] = [" " + current, current + " ", "0" + current, current + "x",
                                   String(current.dropLast()), "deadbeef"]
        for mutated in mutations {
            check(mutated != current, "the fixture's mutations must all differ from the token")
            let reply = await fixture.router.reply(Req.post("/api/delete",
                json: #"{"mode":"ids","ids":["k-1"],"confirmToken":"\#(mutated)"}"#))
            checkEqual(reply.status, 409, "\"\(mutated)\" is not the confirmed token")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a matching selection that stopped matching is refused",
        knownBug: nil) {
        // The exact scenario the token exists for: the user reviewed "everything
        // below 0.5", then moved the slider — or a rescan scored more rows.
        let fixture = try await Fixture.make("token-drift")
        try await fixture.seed((0..<5).map { .init(id: "k-\($0)", score: 0.1 * Float($0), date: Double($0)) })
        let before = await token(fixture, #"{"mode":"matching","filter":{"lo":-1,"hi":0.3}}"#)
        checkEqual(before, await token(fixture, #"{"mode":"matching","filter":{"lo":-1,"hi":0.3}}"#),
                   "with a stable filter the token is stable")

        try await fixture.seed([.init(id: "k-9", score: 0.25, date: 99)])
        let after = await token(fixture, #"{"mode":"matching","filter":{"lo":-1,"hi":0.3}}"#)
        check(after != before, "a new matching row changes the confirmed set")

        let refused = await fixture.router.reply(Req.post("/api/delete",
            json: #"{"mode":"matching","filter":{"lo":-1,"hi":0.3},"confirmToken":"\#(before)"}"#))
        checkEqual(refused.status, 409, "so the deletion that was confirmed against the old set is refused")
        checkEqual((try await fixture.cache.stats(maxAge: 0)).total, 6, "and nothing is removed from the cache")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a non-string confirmToken is refused as malformed",
        knownBug: nil) {
        // Favourites only, so a request that somehow got past the type check still
        // resolves to an empty selection and cannot reach PhotoKit.
        let fixture = try await Fixture.make("token-nonstring")
        try await fixture.seed([.init(id: "k-0", score: 0.5, date: 1, favorite: true)])
        for value in ["1", "true", "[]", "{}"] {
            let reply = await fixture.router.reply(Req.post("/api/delete",
                json: #"{"mode":"ids","ids":["k-0"],"confirmToken":\#(value)}"#))
            checkEqual(reply.status, 400, "confirmToken=\(value) is not a token")
        }
        // `null` decodes to `nil`, which the specification calls optional on purpose:
        // "a client that does not send it keeps working". Documented, not an oversight.
        let nulled = await fixture.router.reply(Req.post("/api/delete",
            json: #"{"mode":"ids","ids":["k-0"],"confirmToken":null}"#))
        checkEqual(nulled.status, 200, "an absent or null confirmToken is accepted by design")
        checkEqual(nulled.int("resolved"), 0, "and protection still applied")
    })
}

// MARK: - Helpers

private func token(_ fixture: Fixture, _ body: String) async -> String {
    await fixture.router.reply(Req.post("/api/selection/preview", json: body)).string("confirmToken") ?? ""
}

private func collectTokens(_ fixture: Fixture, _ body: String, times: Int) async throws -> [String] {
    var tokens: [String] = []
    for _ in 0..<times { tokens.append(await token(fixture, body)) }
    return tokens
}