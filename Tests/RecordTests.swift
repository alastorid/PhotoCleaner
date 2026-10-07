import Foundation

// Records: the wire shapes, the cursors, and the query-parameter rules.
//
// These are the types every route shares, and they carry the client contract in
// `README.md` — including the part that is easy to break silently: optional fields
// are *omitted* rather than sent as `null`, so a client must treat an absent key and
// an explicit `null` identically.

func registerRecordTests() {
    let suite = "records, cursors and query parameters"

    // MARK: cursors

    Registry.shared.add(suite: suite, TestCase(name: "a cursor round-trips exactly, including awkward values",
        knownBug: nil) {
        let rows = [
            PhotoRow(id: "plain", score: 0.5, date: 1000, width: 4, height: 3, favorite: false),
            PhotoRow(id: "id/with/slashes and spaces", score: -0.9959, date: -1, width: 1, height: 1,
                     favorite: true),
            PhotoRow(id: "quote\"and\\backslash", score: 1.0, date: 0, width: 1, height: 1,
                     favorite: false),
            PhotoRow(id: "unicode-ünïcödé-😀", score: 0, date: 1.7e9, width: 1, height: 1,
                     favorite: false),
            PhotoRow(id: String(repeating: "x", count: 500), score: .leastNonzeroMagnitude, date: 0,
                     width: 1, height: 1, favorite: false),
        ]
        for row in rows {
            let cursor = PhotoCursor(row: row)
            let encoded = cursor.encoded()
            check(!encoded.isEmpty, "a cursor is always produced")
            check(!encoded.contains("="), "base64url padding is stripped: \(encoded.prefix(24))")
            check(!encoded.contains("+") && !encoded.contains("/"), "base64url alphabet, not standard base64")
            let decoded = checkNotNil(PhotoCursor.decode(encoded), "cursor for \(row.id.prefix(20))")
            checkEqual(decoded?.id, row.id, "id round trip")
            checkEqual(decoded?.score, row.score, "score round trip")
            checkEqual(decoded?.date, row.date ?? 0, "date round trip")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a nil date becomes 0 in a cursor, matching COALESCE",
        knownBug: nil) {
        let row = PhotoRow(id: "a", score: 0.5, date: nil, width: 1, height: 1, favorite: false)
        checkEqual(PhotoCursor(row: row).date, 0,
                   "COALESCE(creation_date, 0) in the ORDER BY, so the cursor must use 0 too")
        checkEqual(PhotoCursor(row: row).id, "a", "id")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a damaged cursor decodes to nil rather than to garbage",
        knownBug: nil) {
        // Garbage must not decode into a usable cursor: `/api/timeline/page` would
        // then page from a position nobody asked for, and `/api/photos` would not
        // know it had been given one.
        for garbage in ["!!!", "@@@@", "not-base64!!", "eyJ", "e30", "bnVsbA", "%%%"] {
            checkNil(PhotoCursor.decode(garbage), "\"\(garbage)\" must not decode into a cursor")
        }
        // Truncation can land on valid base64, so it gets its own property: it may
        // decode, but it must not move the cursor.
        let good = PhotoCursor(score: 0.25, date: 100, id: "a").encoded()
        if let truncated = PhotoCursor.decode(String(good.dropLast())) {
            checkEqual(truncated.id, "a", "a truncated cursor may only decode to the row it was cut from")
            checkEqual(truncated.score, 0.25, "and to the same position")
        }
        checkNotNil(PhotoCursor.decode(good), "while the original still decodes")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the base64url helpers are inverses over awkward input",
        knownBug: nil) {
        for payload in ["", "a", "ab", "abc", "abcd", ">>>???", "ÿþý", String(repeating: "z", count: 300)] {
            let encoded = Data(payload.utf8).base64URLEncodedString()
            checkNil(encoded.range(of: "="), "no padding leaked for \"\(payload.prefix(8))\"")
            guard let decoded = checkNotNil(Data(base64URLEncoded: encoded), "decode of \"\(payload.prefix(8))\"") else { continue }
            checkEqual(String(data: decoded, encoding: .utf8), payload, "round trip of \"\(payload.prefix(8))\"")
        }
        checkNil(Data(base64URLEncoded: "a b c"), "spaces are not valid base64")
    })

    // MARK: enums

    Registry.shared.add(suite: suite, TestCase(name: "every filter and sort raw value is exactly what the wire uses",
        knownBug: nil) {
        checkEqual(FavoriteFilter.include.rawValue, "include", "")
        checkEqual(FavoriteFilter.exclude.rawValue, "exclude", "")
        checkEqual(FavoriteFilter.only.rawValue, "only", "")
        checkEqual(SortOrder.scoreAscending.rawValue, "score_asc", "")
        checkEqual(SortOrder.scoreDescending.rawValue, "score_desc", "")
        checkEqual(SortOrder.newestFirst.rawValue, "date_desc", "")
        checkEqual(SortOrder.oldestFirst.rawValue, "date_asc", "")
        checkEqual(SortOrder.timelineNewer.rawValue, "date_asc_id_desc", "the All Photos newer side's ordering")
        for value in ["include", "exclude", "only"] {
            checkNotNil(FavoriteFilter(rawValue: value), "favorites=\(value)")
        }
        for value in ["hidden", "Include", "INCLUDE", "ONLY", "only ", "", " true"] {
            checkNil(FavoriteFilter(rawValue: value), "favorites=\"\(value)\" must not resolve")
        }
        for value in ["score_asc", "score_desc", "date_desc", "date_asc"] {
            checkNotNil(SortOrder(rawValue: value), "sort=\(value)")
        }
        for value in ["", "score", "date", "asc", "score_ASC"] {
            checkNil(SortOrder(rawValue: value), "sort=\"\(value)\" must not resolve")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "analysis states are exactly the five persisted strings",
        knownBug: nil) {
        for value in ["pending", "analyzing", "done", "failed", "unavailable"] {
            checkEqual(AnalysisState(rawValue: value)?.rawValue, value, "round trip of \(value)")
        }
        for value in ["", "Pending", "DONE", "skipped", "error", "queued"] {
            checkNil(AnalysisState(rawValue: value), "\"\(value)\" is not a state")
        }
    })

    // MARK: query parameters

    Registry.shared.add(suite: suite, TestCase(name: "queryInt clamps into its range and falls back otherwise",
        knownBug: nil) {
        let request = Req.get("/api/photos", query: [
            "a": "5", "b": "abc", "c": "-3", "d": "999", "e": "007", "f": "1e3", "g": " 4", "h": "4 ",
        ])
        checkEqual(request.queryInt("a"), 5, "a plain integer")
        checkEqual(request.queryInt("a", range: 1...10), 5, "inside the range")
        checkEqual(request.queryInt("c"), -3, "a negative integer is a value")
        checkEqual(request.queryInt("c", range: 1...10), 1, "and is clamped up into the range")
        checkEqual(request.queryInt("d", range: 1...10), 10, "clamped down into the range")
        checkEqual(request.queryInt("b", default: 60), 60, "unparseable falls back")
        checkEqual(request.queryInt("missing", default: 60), 60, "absent falls back")
        checkEqual(request.queryInt("missing"), nil, "with no default it is nil")
        checkEqual(request.queryInt("e"), 7, "leading zeros are a number")
        checkEqual(request.queryInt("f"), nil, "1e3 is not an Int, so it is not a page size")
        checkEqual(request.queryInt("g"), nil, "leading whitespace is not an Int")
        checkEqual(request.queryInt("h"), nil, "trailing whitespace is not an Int either")
    })

    Registry.shared.add(suite: suite, TestCase(name: "queryFloat rejects what Float cannot represent",
        knownBug: nil) {
        let request = Req.get("/api/photos", query: ["a": "-0.9959", "b": "1", "c": "abc", "d": "", "e": "1e-3"])
        checkEqual(request.queryFloat("a"), -0.9959, "a score outside 0…1 parses")
        checkEqual(request.queryFloat("b"), 1, "an integer literal")
        checkEqual(request.queryFloat("c"), nil, "junk")
        checkEqual(request.queryFloat("d"), nil, "an empty value")
        check(request.queryFloat("e") != nil, "exponent notation is a Float")
        checkEqual(request.queryFloat("missing"), nil, "absent")
    })

    Registry.shared.add(suite: suite, TestCase(name: "path and query values are decoded with their own grammars",
        knownBug: nil) {
        // A Photos `localIdentifier` contains slashes, so it travels as one escaped
        // segment; splitting before decoding is what makes that work. And `+` means
        // a space in a query value but is a literal plus in a path component.
        let escapedID: String = "L0%2F001%2FL0"
        let escapedSlash: String = "a%2Fb"
        let escapedPlusPath: String = "a%2Bb"
        let literalPlusPath: String = "a+b"
        let queryPlus: String = "a+b"
        let queryEscapedPlus: String = "a%2Bb"
        let injection: String = "%22%3E%3Cimg%20src%3Dx%20onerror%3Dalert(1)%3E"
        let traversal: String = "..%2F..%2Fetc%2Fpasswd"
        let notEncoded: String = "100%"

        checkEqual(escapedID.percentDecodedPathSegment, "L0/001/L0", "an escaped identifier, path grammar")
        checkEqual(escapedSlash.percentDecodedPathSegment, "a/b", "an escaped slash, path grammar")
        checkEqual(escapedPlusPath.percentDecodedPathSegment, "a+b", "an escaped plus, path grammar")
        checkEqual(literalPlusPath.percentDecodedPathSegment, "a+b",
                   "a literal + in a path is a plus, not a space: an identifier may contain one")
        checkEqual(queryPlus.percentDecodedQueryValue, "a b", "a + in a query value is a space")
        checkEqual(queryEscapedPlus.percentDecodedQueryValue, "a+b", "and %2B is a literal plus either way")
        checkEqual(injection.percentDecodedPathSegment, "\"><img src=x onerror=alert(1)>",
                   "an injected markup payload decodes to itself, inert")
        checkEqual(traversal.percentDecodedPathSegment, "../../etc/passwd",
                   "traversal decodes to itself, so the cache lookup is what refuses it")
        checkEqual(notEncoded.percentDecodedPathSegment, "100%",
                   "invalid escapes are left alone rather than becoming empty")
        checkEqual(notEncoded.percentDecodedQueryValue, "100%", "and the query decoder agrees")

        let path: String = "/api/photo/"
        checkEqual(path.split(separator: "/", omittingEmptySubsequences: true).map(String.init),
                   ["api", "photo"], "empty segments are dropped before decoding")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a status code never gets a reason phrase that contradicts it",
        knownBug: nil) {
        // A code with no entry used to fall through to "OK", which put
        // `HTTP/1.1 409 OK` on the wire for a stale confirmToken.
        let expected: [Int: String] = [
            200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden",
            404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout",
            409: "Conflict", 413: "Payload Too Large", 431: "Request Header Fields Too Large",
            500: "Internal Server Error", 503: "Service Unavailable",
        ]
        for (code, phrase) in expected {
            checkEqual(HTTPStatus.text(code), phrase, "\(code)")
        }
        // Every code the router and the connection can actually emit.
        for code in [200, 204, 400, 403, 404, 408, 409, 413, 431, 500] {
            check(HTTPStatus.text(code) != "OK" || code == 200,
                  "\(code) must not be announced as OK, got \"\(HTTPStatus.text(code))\"")
        }
        // An unrecognised code must not claim success either.
        check(HTTPStatus.text(599) != "OK", "an unknown code does not fall through to OK")
        check(!HTTPStatus.text(599).isEmpty, "and HTTP/1.1 requires a phrase to be present")
    })

    // MARK: the wire contract

    Registry.shared.add(suite: suite, TestCase(name: "optional fields are omitted, never sent as null", knownBug: nil) {
        let fixture = try await Fixture.make("records-optional")
        try await fixture.seed([
            .init(id: "dated", score: 0.5, date: 1000),
            .init(id: "undated", score: 0.5, date: nil),
            .init(id: "unscored", score: nil, date: 2000, state: .pending),
        ])
        let dated = await fixture.router.reply(Req.get("/api/photo/dated"))
        checkEqual(dated.status, 200, "status")
        let row = dated.json["photo"] as? [String: Any] ?? [:]
        checkEqual(row.keys.sorted(), ["date", "favorite", "height", "id", "mediaType", "score", "width"],
                   "every field is present for a fully-populated row")
        checkEqual(row["date"] as? Double, 1000, "the date")
        // `mediaType` is the one field that is never optional, and that is the point:
        // a client reading its absence as "image" would render a video as a still.
        checkEqual(row["mediaType"] as? Int, 1, "the media type is always stated, not inferred")
        check(!row.keys.contains("duration"), "and a still carries no duration key at all")

        let undated = await fixture.router.reply(Req.get("/api/photo/undated"))
        let undatedRow = undated.json["photo"] as? [String: Any] ?? [:]
        check(!undatedRow.keys.contains("date"), "a nil date is omitted, not null: \(undatedRow.keys.sorted())")
        check(!undatedRow.values.contains { $0 is NSNull }, "and nothing in the object is an explicit null")

        // Nothing else in a row is optional, so what is left to assert is that the
        // one field that cannot be known is still sent as a number rather than a
        // null: `PhotoRow.score` is non-optional, so an unanalysed row reads back as
        // `score: 0`, which the score-bounded filter excludes anyway because the
        // stored column is NULL.
        let unscored = await fixture.router.reply(Req.get("/api/photo/unscored"))
        let unscoredRow = unscored.json["photo"] as? [String: Any] ?? [:]
        checkEqual(unscoredRow.keys.sorted(), ["date", "favorite", "height", "id", "mediaType", "score", "width"],
                   "an unanalysed row has the same shape as a scored one")
        check(!unscoredRow.values.contains { $0 is NSNull }, "and still sends no explicit nulls")
        checkEqual(unscoredRow["score"] as? Double, 0, "score is a number, not absent")
    })

    Registry.shared.add(suite: suite, TestCase(name: "an unknown asset is a 404, not an empty row", knownBug: nil) {
        let fixture = try await Fixture.make("records-unknown")
        for path in ["/api/photo/no-such-asset", "/api/photo/no/such/asset", "/api/photo/L0%2F001"] {
            let reply = await fixture.router.reply(Req.get(path))
            checkEqual(reply.status, 404, "GET \(path)")
            check(reply.errorMessage.contains("unknown asset"), "the message says so, got: \(reply.errorMessage)")
        }
        // Path traversal has no route to the filesystem: the identifier is looked up
        // in the cache and nothing else.
        for path in ["/api/photo/..%2F..%2Fetc%2Fpasswd", "/api/photo/....//....//etc/passwd"] {
            checkEqual((await fixture.router.reply(Req.get(path))).status, 404, "GET \(path)")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a percent-encoded identifier and a raw one are the same asset",
        knownBug: nil) {
        let fixture = try await Fixture.make("records-identifier")
        try await fixture.seed([.init(id: "L0/001/L0", score: 0.5, date: 1000)])
        let encoded = await fixture.router.reply(Req.get("/api/photo/L0%2F001%2FL0"))
        let raw = await fixture.router.reply(Req.get("/api/photo/L0/001/L0"))
        checkEqual(encoded.status, 200, "the escaped form")
        checkEqual(raw.status, 200, "the raw form")
        checkEqual((encoded.json["photo"] as? [String: Any])?["id"] as? String, "L0/001/L0", "the same identifier")
        checkEqual(encoded.body, raw.body, "and byte-identical responses")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a large but legal JSON body is parsed", knownBug: nil) {
        // The 1 MB ceiling itself is enforced by the connection, in `HTTPServerTests`;
        // this only pins that a large body is not truncated or dropped on the way in.
        let fixture = try await Fixture.make("records-bodysize")
        try await fixture.seed([.init(id: "a", score: 0.5, date: 1)])
        let padding = String(repeating: "p", count: 900_000)
        let body = #"{"mode":"ids","ids":["a"],"pad":"\#(padding)"}"#
        check(body.utf8.count < 1 << 20, "the fixture body is under the ceiling: \(body.utf8.count)")
        let reply = await fixture.router.reply(Req.post("/api/selection/preview", json: body))
        checkEqual(reply.status, 200, "a ~900 KB body is parsed")
        checkEqual(reply.int("resolved"), 1, "and the selection resolves")
    })

    Registry.shared.add(suite: suite, TestCase(name: "no JSON route may be cached", knownBug: nil) {
        // The regression: `/api/status` carried no `Cache-Control` at all, so
        // URLSession was free to write the response into ~/Library/Caches, and
        // `smoke-test.sh` caught exactly one entry there — a loopback status
        // probe from the second-launch check.
        //
        // `no-store` and not `no-cache`: `no-cache` still permits the body to be
        // *written* and only requires revalidation, so the disk write this exists
        // to prevent still happens. Every JSON route is a live view of the
        // library, so the header is asserted across the shape of the API rather
        // than on one route.
        let fixture = try await Fixture.make("records-nostore")
        try await fixture.seed([.init(id: "L0/001/L0", score: 0.5, date: 1000)])

        let routes = [
            "/api/status",
            "/api/photos?limit=1",
            "/api/settings",
            "/api/albums",
            "/api/groups?limit=1",
        ]
        for path in routes {
            let reply = await fixture.router.reply(Req.get(path))
            checkEqual(reply.headers["Cache-Control"], "no-store", "GET \(path) is not cacheable")
        }
        // And an error, which is the other JSON constructor: a 404 body is just
        // as much a live answer as a 200.
        let missing = await fixture.router.reply(Req.get("/api/photo/nope"))
        checkEqual(missing.status, 404, "GET an unknown photo")
        checkEqual(missing.headers["Cache-Control"], "no-store", "and the 404 is not cacheable either")
    })

Registry.shared.add(suite: suite, TestCase(name: "the embedded UI is served from the binary", knownBug: nil) {
        let fixture = try await Fixture.make("records-web")
        let index = await fixture.router.reply(Req.get("/"))
        checkEqual(index.status, 200, "GET /")
        check(index.headers["Content-Type"] == "text/html; charset=utf-8", "content type, got \(index.headers)")
        check(String(decoding: index.body, as: UTF8.self).contains("<html"), "an HTML document")
        checkEqual(index.headers["Cache-Control"], "no-store", "the UI is not cached")
        checkEqual((await fixture.router.reply(Req.get("/app.js"))).status, 200, "GET /app.js")
        checkEqual((await fixture.router.reply(Req.get("/app.css"))).status, 200, "GET /app.css")
        checkEqual((await fixture.router.reply(Req.get("/favicon.ico"))).status, 204, "GET /favicon.ico")
        checkEqual((await fixture.router.reply(Req.get("/../build.sh"))).status, 404, "no traversal out of the web root")
        checkEqual((await fixture.router.reply(Req.get("/app.js.map"))).status, 404, "no source maps")
    })
}