import Foundation
import Photos

// The Photos authorization gate.
//
// Every route that *acts* on a photo refuses with 403 when Photos access is absent,
// so nothing runs against a library the app is not allowed to read. The gate is
// fail-closed by construction — it can only refuse, never permit — but that is a
// claim about the code, and these cases are about observable behaviour: which routes
// are gated, what they say, and that nothing was changed on the way out.
//
// The status is injected (`Router.authorizationStatus`) so this suite behaves
// identically on a machine with Photos access, without it, and on a CI runner. That
// seam exists because of a real failure: the first CI run 403'd every photo route and
// then trapped on a force-unwrap, which is what established the gate was untestable
// rather than merely untested.
//
// ## The read/write split, deliberately
//
// Gated: deletion, favourites, reveal, settings, album reindex, and the group
// routes. Each of these reaches PhotoKit or changes stored state.
//
// Not gated: `/api/status`, `/api/settings`, and the cache-backed read routes
// (`/api/photos`, `/api/photo/{id}`, `/api/timeline/*`). Those are served from
// PhotoCleaner's own SQLite, and the window needs them to explain itself — an app
// whose status endpoint 403s cannot tell the user why it is refusing. The asymmetry
// is real and is asserted below rather than left for a reader to infer: what is not
// gated is exactly what reads a file this app wrote, and everything that would touch
// the Photos library is gated.
//
// The route list is spelled out on purpose. A new route that forgot the gate would
// otherwise be invisible here, so this list is the specification of what must refuse.

func registerAuthorizationTests() {
    let suite = "photos authorization"

    /// Every route that reaches PhotoKit or changes state, with a request that gets as
    /// far as the gate.
    let gated: [(route: String, reply: @Sendable (Fixture) async -> Reply)] = [
        ("POST /api/delete", { await $0.router.reply(Req.post("/api/delete", json: #"{"mode":"ids","ids":["a"]}"#)) }),
        ("POST /api/favorites", { await $0.router.reply(Req.post("/api/favorites", json: #"{"ids":["a"],"favorite":true}"#)) }),
        ("POST /api/photos/reveal", { await $0.router.reply(Req.post("/api/photos/reveal", json: #"{"id":"a"}"#)) }),
        ("POST /api/groups/rebuild", { await $0.router.reply(Req.post("/api/groups/rebuild", json: "")) }),
        ("POST /api/selection/preview", { await $0.router.reply(Req.post("/api/selection/preview", json: #"{"mode":"ids","ids":["a"]}"#)) }),
        ("GET /api/albums", { await $0.router.reply(Req.get("/api/albums")) }),
        ("POST /api/albums/index", { await $0.router.reply(Req.post("/api/albums/index", json: "")) }),
        ("GET /api/groups", { await $0.router.reply(Req.get("/api/groups")) }),
        ("GET /api/group", { await $0.router.reply(Req.get("/api/group?id=g")) }),
    ]

    for denied in [PHAuthorizationStatus.denied, .restricted, .notDetermined] {
        Registry.shared.add(suite: suite, TestCase(name: "every acting route refuses when access is \(denied)", knownBug: nil) {
            let fixture = try await Fixture.make("auth-refused-\(denied.rawValue)")
            try await fixture.seed([.init(id: "a", score: 0.5, date: 100)])
            fixture.statusOverride = denied

            for route in gated {
                let reply = await route.reply(fixture)
                checkEqual(reply.status, 403, "\(route.route) must refuse")
                check(reply.errorMessage.contains("Photos access"),
                      "\(route.route) must say why, got: \(reply.errorMessage)")
                check(reply.errorMessage.contains("nothing was changed"),
                      "\(route.route) must state that nothing happened")
            }

            // The refusal has to be real. A gate that 403s *after* deleting would pass
            // every assertion above, so the cache is checked directly.
            let stats = try await fixture.cache.stats(maxAge: 0)
            checkEqual(stats.total, 1, "the cache is untouched")
            checkEqual(try await fixture.cache.photo(identifier: "a")?.favorite, false,
                       "and no favourite was set behind the refusal")
        })
    }

    Registry.shared.add(suite: suite, TestCase(name: "the analysis controls are same-origin gated",
        knownBug: nil) {
        // `crossOriginRefusal` is a different gate from the Photos one above, and it
        // guards a different thing: not "may this act on the library" but "may a page
        // the user happens to be visiting start this". A POST with no body, no custom
        // header and no preflight is a CORS-simple request, so a cross-site page can
        // deliver one — which is why every mutating route has to refuse on its own
        // rather than relying on the browser.
        //
        // These two were the gap, and they are the two most expensive in the app:
        // `retry` requeues every failed asset and restarts the run, and `rescan`
        // cancels an in-flight scan and starts a whole-library walk whose
        // `finishScan` deletes every cache row the new scan does not stamp.
        let fixture = try await Fixture.make("auth-cross-site-analysis")
        try await fixture.seed([.init(id: "a", score: 0.5, date: 100)])

        let crossSite: [String: String] = ["sec-fetch-site": "cross-site"]
        for route in ["/api/analysis/retry", "/api/library/rescan"] {
            let refused = await fixture.router.reply(Req.post(route, json: "", headers: crossSite))
            checkEqual(refused.status, 403, "POST \(route) must refuse a cross-site request")
            check(refused.errorMessage.contains("cross-site"),
                  "POST \(route) must say why, got: \(refused.errorMessage)")
        }

        // The gate must not have stopped the app working. Both are still reachable
        // from the app's own page, which is the only thing that may trigger them.
        for route in ["/api/analysis/retry", "/api/library/rescan"] {
            let allowed = await fixture.router.reply(Req.post(route, json: ""))
            checkEqual(allowed.status, 200, "POST \(route) still works same-origin")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "authorization is required, not merely authorized",
        knownBug: nil) {
        // `.limited` is *partial* library access and is allowed through: a user who
        // shares a subset can still review and delete what they shared. The
        // distinction that matters is authorized-or-limited versus not.
        let fixture = try await Fixture.make("auth-limited")
        try await fixture.seed([.init(id: "a", score: 0.5, date: 100)])
        fixture.statusOverride = .limited
        checkEqual((await fixture.router.reply(Req.get("/api/groups"))).status, 200,
                   "limited access is enough to act on what was shared")
    })

    Registry.shared.add(suite: suite, TestCase(name: "reporting and configuration stay reachable without access",
        knownBug: nil) {
        // An app that 403s its own status endpoint cannot explain the problem, and one
        // that 403s settings cannot be configured once access is granted. Either would
        // leave a window that loads and says nothing, with no way out.
        let fixture = try await Fixture.make("auth-open-routes")
        fixture.statusOverride = .denied
        for path in ["/api/status", "/api/settings"] {
            let reply = await fixture.router.reply(Req.get(path))
            check(reply.status != 403, "GET \(path) must stay reachable, got \(reply.status)")
        }
        // The cached grid is served too: it is a read of PhotoCleaner's own database,
        // and the interface needs it to show what it already knows.
        checkEqual((await fixture.router.reply(Req.get("/api/photos"))).status, 200,
                   "GET /api/photos reads our own cache and stays reachable")
    })

    Registry.shared.add(suite: suite, TestCase(name: "authorization is re-read per request, not latched at startup",
        knownBug: nil) {
        // A user can grant Photos access while the app runs, and it must start working
        // without a relaunch. The status is therefore read per request: a value
        // captured into `Router.init` would leave the app permanently refusing, with
        // nothing in the UI to suggest that restarting would help.
        let fixture = try await Fixture.make("auth-live")
        try await fixture.seed([.init(id: "a", score: 0.5, date: 100)])
        fixture.statusOverride = .denied
        checkEqual((await fixture.router.reply(Req.get("/api/groups"))).status, 403, "refused first")

        fixture.statusOverride = .authorized
        checkEqual((await fixture.router.reply(Req.get("/api/groups"))).status, 200,
                   "and served as soon as access is granted, with no restart")

        fixture.statusOverride = .denied
        checkEqual((await fixture.router.reply(Req.get("/api/groups"))).status, 403,
                   "and refused again if access is withdrawn mid-session")
    })
}