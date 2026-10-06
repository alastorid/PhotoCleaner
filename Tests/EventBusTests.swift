import Foundation

// EventBus: the SSE fan-out.
//
// Two properties here were real bugs. A heartbeat is a `:` comment frame that exists
// only to keep proxies from timing out an idle connection; it must never be mistaken
// for state, so it goes out through `broadcast` and leaves the retained snapshot
// alone. And `/api/events` publishes a status snapshot *and then* subscribes, so
// anything that replaced the retained frame in that window would be handed to a
// browser as its very first event instead of a `status`.

func registerEventBusTests() {
    let suite = "SSE event bus"

    Registry.shared.add(suite: suite, TestCase(name: "a heartbeat reaches live subscribers but never the retained slot",
        knownBug: nil) {
        let bus = EventBus()
        let snapshot = SSE.frame(event: "status", json: Data(#"{"phase":"analyzing"}"#.utf8))
        let snapshotText = String(decoding: snapshot, as: UTF8.self)

        // The retained slot is filled before anyone subscribes, which is exactly the
        // order `Router.events()` works in: publish the status, then subscribe.
        bus.publish(snapshot)
        let subscriber = bus.subscribe()

        var frames: [String] = []
        for await event in subscriber.stream.prefix(1) {
            frames.append(String(decoding: event, as: UTF8.self))
            break
        }
        checkEqual(frames, [snapshotText], "a new subscriber is handed the retained status frame")

        bus.broadcast(SSE.heartbeat)
        var heartbeats: [String] = []
        for await event in subscriber.stream.prefix(1) {
            heartbeats.append(String(decoding: event, as: UTF8.self))
            break
        }
        checkEqual(heartbeats, [": ping\n\n"], "and a heartbeat reaches it live")

        // Now the bug: a browser that connects *after* the heartbeat must still be
        // handed a status frame, because the heartbeat never went through `publish`.
        let late = bus.subscribe()
        var lateFrames: [String] = []
        for await event in late.stream.prefix(1) {
            lateFrames.append(String(decoding: event, as: UTF8.self))
            break
        }
        checkEqual(lateFrames, [snapshotText],
                   "a late subscriber is given the retained status, not the heartbeat")
        bus.close()
    })

    Registry.shared.add(suite: suite, TestCase(name: "state is fanned out to every subscriber", knownBug: nil) {
        let bus = EventBus()
        let first = bus.subscribe(), second = bus.subscribe()

        bus.publish(Data("one".utf8))
        for (name, subscription) in [("first", first), ("second", second)] {
            var seen: [String] = []
            for await event in subscription.stream.prefix(1) {
                seen.append(String(decoding: event, as: UTF8.self))
                break
            }
            checkEqual(seen, ["one"], "\(name) received the frame")
        }
        bus.publish(Data("two".utf8))
        for (name, subscription) in [("first", first), ("second", second)] {
            var seen: [String] = []
            for await event in subscription.stream.prefix(1) {
                seen.append(String(decoding: event, as: UTF8.self))
                break
            }
            checkEqual(seen, ["two"], "\(name) received the second frame too")
        }
        bus.close()
    })

    Registry.shared.add(suite: suite, TestCase(name: "unsubscribing stops the frames and finishes the stream",
        knownBug: nil) {
        let bus = EventBus()
        let subscription = bus.subscribe()
        bus.publish(Data("before".utf8))
        bus.unsubscribe(subscription.id)
        bus.publish(Data("after".utf8))

        var seen: [String] = []
        for await event in subscription.stream {
            seen.append(String(decoding: event, as: UTF8.self))
        }
        checkEqual(seen, ["before"],
                   "only the frame published before unsubscribing is delivered, and the stream then finishes")
        bus.close()
    })

    Registry.shared.add(suite: suite, TestCase(name: "a closed bus hands out no endless stream", knownBug: nil) {
        // Never hand back a stream nobody will ever finish: the consumer would wait
        // on `for await` until its own task was cancelled.
        let bus = EventBus()
        bus.publish(Data("last".utf8))
        bus.close()
        var count = 0
        for await _ in bus.subscribe().stream {
            count += 1
            if count > 4 { break }
        }
        checkEqual(count, 0, "a post-close subscriber receives nothing at all")

        bus.publish(Data("ignored".utf8))
        var late = 0
        for await _ in bus.subscribe().stream {
            late += 1
            break
        }
        checkEqual(late, 0, "and publishing after close delivers nothing either")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a subscriber that stops reading cannot build a queue of stale frames",
        knownBug: nil) {
        // `.bufferingNewest(1)`: a browser that stops reading must not accumulate
        // status frames, and must never apply back-pressure to the analysis engine.
        let bus = EventBus()
        let subscriber = bus.subscribe()
        for index in 0..<500 {
            bus.publish(Data("frame-\(index)".utf8))
        }
        var seen: [String] = []
        for await event in subscriber.stream.prefix(1) {
            seen.append(String(decoding: event, as: UTF8.self))
            break
        }
        checkEqual(seen, ["frame-499"], "500 published frames collapse to the newest one")
        bus.close()
    })

    Registry.shared.add(suite: suite, TestCase(name: "an SSE frame is well formed and a heartbeat is a comment",
        knownBug: nil) {
        let frame = SSE.frame(event: "status", json: Data(#"{"a":1}"#.utf8))
        let text = String(decoding: frame, as: UTF8.self)
        check(text.hasPrefix("event: status\n"), "the event name, got \(text.debugDescription)")
        check(text.contains("\ndata: {\"a\":1}\n"), "the JSON on one data line, got \(text.debugDescription)")
        check(text.hasSuffix("\n\n"), "the frame is terminated by a blank line")

        // JSON never contains a raw newline, so one `data:` line is safe — but only
        // because of that, so it is worth pinning.
        let awkward = SSE.frame(event: "status", json: Data("{\"a\":\"line1\\nline2\"}".utf8))
        let awkwardText = String(decoding: awkward, as: UTF8.self)
        checkEqual(awkwardText.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.count, 1,
                   "one data line, even with an escaped newline inside the JSON")

        checkEqual(String(decoding: SSE.heartbeat, as: UTF8.self), ": ping\n\n", "the heartbeat is a comment frame")
    })
}

// MARK: - Settings

/// `Settings.update` mutates the stored state *in place* inside `withLock`, which
/// hands the closure an `inout` reference. An earlier version mutated a copy, so
/// changes were written to `settings.json` while the running process kept serving
/// the old values for its whole life — which silently disabled the
/// iCloud-downloads → `requeueUnavailable` path.
func registerSettingsTests() {
    let suite = "settings"

    Registry.shared.add(suite: suite, TestCase(name: "an update is visible in memory, not only on disk",
        knownBug: nil) {
        let root = try Fixture.makeRoot(label: "settings-memory")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let settings = Settings(url: url)

        checkEqual(settings.snapshot().protectFavorites, true, "favourite protection defaults to on")
        checkEqual(settings.snapshot().downloadFromICloud, false, "iCloud downloads default to off")

        let updated = settings.update { current in
            current.protectFavorites = false
            current.downloadFromICloud = true
            current.analysisConcurrency = 7
        }
        checkEqual(updated.protectFavorites, false, "update returns the new snapshot")
        checkEqual(settings.snapshot().protectFavorites, false,
                   "and the in-memory state agrees with it immediately")
        checkEqual(settings.snapshot().downloadFromICloud, true, "every field, not just one")
        checkEqual(settings.snapshot().analysisConcurrency, 7, "including concurrency")

        let reloaded = Settings(url: url)
        checkEqual(reloaded.snapshot().protectFavorites, false, "the file was written too")
        checkEqual(reloaded.snapshot().analysisConcurrency, 7, "with every field")
    })

    Registry.shared.add(suite: suite, TestCase(name: "concurrency and pixel size are clamped, not trusted",
        knownBug: nil) {
        let root = try Fixture.makeRoot(label: "settings-clamp")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = Settings(url: root.appendingPathComponent("settings.json"))
        for (requested, expected) in [(0, 1), (-3, 1), (1, 1), (4, 4), (16, 16), (17, 16), (1_000, 16)] {
            settings.update { $0.analysisConcurrency = requested }
            checkEqual(settings.snapshot().analysisConcurrency, expected, "concurrency \(requested)")
        }
        for (requested, expected) in [(0, 256), (255, 256), (1024, 1024), (4096, 4096), (99_999, 4096)] {
            settings.update { $0.analysisPixelSize = requested }
            checkEqual(settings.snapshot().analysisPixelSize, expected, "analysisPixelSize \(requested)")
        }
        settings.update { $0.protectFavorites = false }
        settings.update { $0.analysisConcurrency = 99 }
        checkEqual(settings.snapshot().protectFavorites, false, "clamping one field leaves the others alone")
        checkEqual(settings.snapshot().analysisPixelSize, 4096, "including analysisPixelSize, at its clamped value")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a corrupt settings file falls back to the defaults",
        knownBug: nil) {
        let root = try Fixture.makeRoot(label: "settings-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        try Data("{ not json".utf8).write(to: url)
        let settings = Settings(url: url)
        checkEqual(settings.snapshot().protectFavorites, true,
                   "an unreadable preferences file must not silently disable favourite protection")
        checkEqual(settings.snapshot().downloadFromICloud, false, "nor enable iCloud downloads")

        // A *partial* file is honoured key by key. This used to assert the opposite —
        // that a file missing any field was ignored wholesale, because a synthesised
        // `Decodable` demands every key and does not fall back to a property's
        // declared default. That made every settings.json written by a build older
        // than the newest field undecodable, so upgrading silently reset *every*
        // preference rather than just adding the new one. `SettingsSnapshot` now
        // decodes through `decodeIfPresent`, so what the file states is kept and only
        // what it never mentioned takes a default.
        //
        // `protectFavorites: false` here is the check that matters: with the old
        // behaviour this read as `true`, i.e. a user's deliberate choice was
        // discarded and reverted on upgrade. Honouring it is the point.
        try Data(#"{"protectFavorites": false}"#.utf8).write(to: url)
        let partial = Settings(url: url)
        checkEqual(partial.snapshot().protectFavorites, false,
                   "a partial file keeps what it states rather than discarding it")
        checkEqual(partial.snapshot().analysisConcurrency, 4, "and defaults only what it omits")
        checkEqual(partial.snapshot().checkForUpdates, true, "including a field this build added later")
    })

    Registry.shared.add(suite: suite, TestCase(name: "POST /api/settings updates state without a restart", knownBug: nil) {
        // Deliberately never sends `downloadFromICloud`: flipping it would call
        // `engine.start()` and begin scoring the real library.
        let fixture = try await Fixture.make("settings-route")
        try await fixture.seed([.init(id: "a", score: 0.5, date: 1)])

        let reply = await fixture.router.reply(Req.post("/api/settings", json: #"{"concurrency": 9}"#))
        checkEqual(reply.status, 200, "status")
        checkEqual(fixture.settings.snapshot().analysisConcurrency, 9, "in memory")
        checkEqual((reply.json["settings"] as? [String: Any])?["concurrency"] as? Int, 9, "in the response")
        let status = await fixture.router.reply(Req.get("/api/status"))
        checkEqual((status.json["settings"] as? [String: Any])?["concurrency"] as? Int, 9,
                   "and in /api/status, which is what the UI reads")
        checkEqual(fixture.settings.snapshot().protectFavorites, true, "an unrelated field is untouched")

        checkEqual((await fixture.router.reply(Req.post("/api/settings", json: #"{"nonsense": true}"#))).status, 200,
                   "an unknown field is ignored")
        checkEqual((await fixture.router.reply(Req.post("/api/settings", json: #"{"concurrency": "four"}"#))).status,
                   400, "a wrongly typed field is refused")
        checkEqual((await fixture.router.reply(Req.post("/api/settings", json: "not json"))).status, 400,
                   "and so is a malformed body")
        checkEqual(fixture.settings.snapshot().analysisConcurrency, 9, "no failed request changed anything")
    })

    Registry.shared.add(suite: suite, TestCase(name: "GET /api/status reports the real counters", knownBug: nil) {
        let fixture = try await Fixture.make("settings-status")
        try await fixture.seed([
            .init(id: "a", score: -0.9959, date: 1),
            .init(id: "b", score: 1.0, date: 2, favorite: true),
            .init(id: "c", score: nil, date: 3, state: .unavailable),
            .init(id: "d", score: nil, date: 4, state: .pending),
        ])
        let reply = await fixture.router.reply(Req.get("/api/status"))
        checkEqual(reply.status, 200, "status")

        let library = reply.json["library"] as? [String: Any] ?? [:]
        checkEqual(library["total"] as? Int, 4, "library.total")
        checkEqual(library["favorites"] as? Int, 1, "library.favorites")

        let score = reply.json["score"] as? [String: Any] ?? [:]
        checkEqual((score["min"] as? NSNumber)?.floatValue, -0.9959, "score.min is the observed minimum, not 0")
        checkEqual((score["max"] as? NSNumber)?.floatValue, 1.0, "score.max")
        checkEqual(score["analyzed"] as? Int, 2, "score.analyzed")

        let analysis = reply.json["analysis"] as? [String: Any] ?? [:]
        checkEqual(analysis["total"] as? Int, 4, "analysis.total")
        checkEqual(analysis["analyzed"] as? Int, 2, "analysis.analyzed")
        checkEqual(analysis["unavailable"] as? Int, 1, "analysis.unavailable")
        checkEqual(analysis["pending"] as? Int, 1, "analysis.pending counts pending and analyzing")
        checkEqual(analysis["percent"] as? Double, 0.75, "analysis.percent counts iCloud-only rows as resolved")
        checkNil(analysis["etaSeconds"], "etaSeconds is omitted when nothing is analysing")
        checkNil(analysis["startedAt"], "startedAt is omitted too")

        let settings = reply.json["settings"] as? [String: Any] ?? [:]
        checkEqual(settings["protectFavorites"] as? Bool, true, "protectFavorites is reported as on")
        checkEqual(settings["downloadFromICloud"] as? Bool, false, "downloadFromICloud is off")
        checkEqual(settings["analysisPixelSize"] as? Int, 1024, "analysisPixelSize is exposed read-only")
    })
}