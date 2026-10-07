import Foundation
import Photos

// `GET /api/photo/{id}/video`, and the two dimensions that keep a clip from being
// mistaken for a photograph.
//
// The route is the only one whose body is not produced by this process, and its
// correctness hangs on failures that are silent when wrong: a refused identifier
// that still reaches `VideoLibrary`, a `Range` answered from the wrong offset, a
// `HEAD` that leaves a body behind for the next response to read as its own, and a
// selection resolved on a photos-only grid that counts every clip on the machine.
// Each of those is silent — the bytes that come back are plausible either way — so
// each is pinned here.
//
// Two layers, and the split is deliberate:
//
// * The video route itself is driven **end to end over a real socket**, because
//   everything load-bearing about it is about framing: `Content-Length` against
//   bytes actually written, a `206` body that really starts where it says, a `HEAD`
//   that desynchronises nothing, and a keep-alive re-armed exactly once after the
//   final chunk. None of that is observable from a `RouteResult`; a test that read
//   one would be testing a value, not the connection.
// * The media filter and the selection snapshot go through `Req` against a real
//   `Fixture`, which is what the rest of the suite does for route logic — those are
//   about what a filter *resolves to*, not about how the answer is framed.
//
// Nothing here reaches `PhotoLibrary.delete` with a non-empty set: the one `POST
// /api/delete` below is refused by the `confirmToken` check, which runs before the
// PhotoKit call (`Router.delete`, the token comparison precedes `library.delete`),
// and the case asserts the refusal rather than assuming it.

// MARK: - The clip under test

/// Length of the fake export, in bytes.
///
/// Bigger than one 512 KB write on purpose: the keep-alive case has to exercise a
/// body that spans several `connection.send` calls, because "exactly one re-arm
/// after the final chunk" is a claim about the *end* of a chain, and a one-chunk
/// body never reaches an end that could be got wrong twice.
private let clipLength = 1_200_000

/// Bytes of a fake clip, each a function of its offset.
///
/// Deterministic and aperiodic, so a body served from the wrong offset cannot pass
/// by being the right *length* — which is exactly how an implementation that
/// ignores `start` looks from the outside: right count, wrong picture.
private let clipBytes = Data((0..<clipLength).map { index -> UInt8 in
    var x = UInt64(index &+ 1) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    x ^= x >> 33
    x = x &* 0xff51_afd7_ed55_8ccd
    x ^= x >> 33
    return UInt8(truncatingIfNeeded: x >> 24)
})

/// The identifier of the one seeded clip every socket case plays.
private let clipIdentifier = "vid-01"

/// A `Range` spanning most of the clip — 1.2 MB over three 512 KB writes.
private let longRange = "bytes=100-"

// MARK: - Planting an export without touching Sources

/// Runs `body` with `AppPaths.videoCacheDirectory` pointed at a throwaway home in
/// which `exports` are already installed as cached exports.
///
/// ## Why this is a seam production already has, not one added for the tests
///
/// `VideoLibrary.exportedFile` consults its own on-disk cache *before* it asks
/// PhotoKit for anything, and returns the file it finds there. That cache-hit branch
/// is production code doing a real job — it is what stops a Range route from
/// re-exporting a clip per seek — so planting a file at the path it looks in
/// exercises the real thing rather than a stand-in for it. Nothing in `Sources/`
/// needed to change, and nothing here knows what a `PHAsset` is.
///
/// The same lookup is what makes the *refusal* cases observable. A request the gate
/// must refuse is given a perfectly good export sitting at its digest path: if the
/// gate lets the request through, the route finds that file and answers `200` with
/// clip bytes. "The export was never attempted" stops being an assertion about code
/// nobody can see and becomes an assertion about bytes that did or did not arrive.
///
/// `CFFIXED_USER_HOME` is what redirects the directory. `AppPaths.supportDirectory`
/// reads `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`,
/// and Foundation resolves that through `CFFIXED_USER_HOME` — so the redirection
/// needs no test-only branch in production and no override parameter threaded through
/// `AppPaths`, `VideoLibrary` and `Router`. It is set and restored around the case;
/// the registry runs cases one at a time, so nothing else observes it.
private func withPlantedExports(_ exports: [(identifier: String, bytes: Data)],
                                _ body: () async throws -> Void) async throws {
    let previous = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("photocleaner-tests-export-\(UUID().uuidString)", isDirectory: true)
    defer {
        if let previous {
            setenv("CFFIXED_USER_HOME", previous, 1)
        } else {
            unsetenv("CFFIXED_USER_HOME")
        }
        try? FileManager.default.removeItem(at: home)
    }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    setenv("CFFIXED_USER_HOME", home.path, 1)

    try AppPaths.createDirectoryIfNeeded(AppPaths.videoCacheDirectory)
    for export in exports {
        // The digest and the extension are production's own naming rule
        // (`VideoLibrary.cachedFileURL`), so the planted file is found by a lookup
        // the route performs rather than by one the test arranges around.
        let url = AppPaths.videoCacheDirectory
            .appendingPathComponent(VideoLibrary.digest(export.identifier))
            .appendingPathExtension("mov")
        try export.bytes.write(to: url)
    }
    try await body()
}

/// The fixture's usual twelve stills plus two clips, for the media-filter cases.
///
/// The mix is the point: a media filter that quietly widened to `all` looks exactly
/// right on a fixture holding only one kind of asset.
private func stillsAndClips() -> [Fixture.Seed] {
    [
        .init(id: "vid-01", score: 0.42, date: 2_000, mediaType: 2, duration: 12.5),
        .init(id: "vid-02", score: 0.51, date: 2_001, mediaType: 2, duration: 3.25),
    ]
}

private func json(_ response: ParsedResponse?) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: response?.body ?? Data())) as? [String: Any]) ?? [:]
}

// MARK: - Cases

func registerVideoRouteTests() {
    let suite = "video route"

    // MARK: refusals

    Registry.shared.add(suite: suite, TestCase(name: "an identifier this instance has never scanned is refused before any export", knownBug: nil) {
        // The gate has two halves — "have I scanned it" and "is it a video" — and
        // this is the first. A planted export for an identifier that is not in the
        // cache turns "the export was never attempted" into something observable: the
        // route would find that file and serve it if `known(identifiers:)` were not
        // consulted first, and the response would be a `200` of clip bytes rather
        // than the `404` below.
        //
        // `exportedFile` can export a multi-gigabyte clip, and it is the most
        // expensive call in the app, so a probe that has not even been scanned must
        // not be able to trigger one.
        try await withPlantedExports([(identifier: "no-such-asset", bytes: clipBytes)]) {
            try await withServer { server in
                try await server.write("""
                GET /api/photo/no-such-asset/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Connection: close\r
                \r

                """)
                let response = checkNotNil(try await server.readResponse(), "the refusal")
                checkEqual(response?.status, 404, "an identifier the cache has never seen is a 404")
                checkEqual(json(response)["error"] as? String, "unknown asset",
                           "and it is simply unknown, exactly as /api/photo answers")
                checkNotEqual(response?.header("content-type"), "video/quicktime",
                               "and no clip is served: the export was never reached")
                checkNil(try await server.readOptionalResponse(), "with nothing after it")
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a cached still is refused, and its export is never attempted", knownBug: nil) {
        // The security property, and the one that is silent when it is broken.
        //
        // `h-00` is a real scored row in the fixture's cache — `known()` accepts it
        // and `cache.photo(identifier:)` returns it — so the *only* thing standing
        // between a crafted identifier and `VideoLibrary.exportedFile` is the
        // `mediaType == video` half of the gate. A real, readable export is planted
        // at that identifier's digest path: if the gate is dropped, the route serves
        // it, and this case sees `200` and clip bytes.
        //
        // The status alone would not catch it. A still reaching PhotoKit comes back
        // as `PhotoLibraryError.assetNotFound`, which this route also answers with a
        // `404` — so an existence oracle survives, silently, with the right status
        // code. The planted file is what makes the difference visible.
        try await withPlantedExports([(identifier: "h-00", bytes: clipBytes)]) {
            try await withServer { server in
                try await server.write("""
                GET /api/photo/h-00/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Connection: close\r
                \r

                """)
                let response = checkNotNil(try await server.readResponse(), "the refusal")
                checkEqual(response?.status, 404, "a cached still is refused on this route")
                checkEqual(json(response)["error"] as? String, "unknown asset",
                           "with the same body a photo gets from /api/photo, so the route is not an oracle")
                checkNotEqual(response?.header("accept-ranges"), "bytes",
                               "and no clip is served: the export was never reached")
                check(response?.body != clipBytes.prefix(100),
                      "the planted export must not appear in the body")
                checkNil(try await server.readOptionalResponse(), "with nothing after it")
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "every refusal is the same 404, whatever the reason", knownBug: nil) {
        // Unknown identifier, cached still, cached row that is a clip but whose
        // export has vanished — three different reasons, one answer. A caller that
        // could tell them apart could probe for assets this instance has scanned,
        // which is the one thing the cache gate exists to prevent.
        try await withServer { server in
            var answers: [Int] = []
            var bodies: [String?] = []
            for identifier in ["no-such-asset", "h-00"] {
                try await server.reconnect()
                try await server.write("""
                GET /api/photo/\(identifier)/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Connection: close\r
                \r

                """)
                let response = try await server.readResponse()
                answers.append(response?.status ?? -1)
                bodies.append(json(response)["error"] as? String)
            }
            checkEqual(answers, [404, 404], "unknown and not-a-video are both 404")
            checkEqual(bodies[0], bodies[1],
                       "and the bodies are identical, so the route cannot be used to find out what exists")
        }
    })

    // MARK: the range table, over the wire

    Registry.shared.add(suite: suite, TestCase(name: "no Range serves the whole file and says it accepts ranges", knownBug: nil) {
        // Also the case that pins the extension → content type mapping: the planted
        // export is a `.mov`, and `WKWebView` decides whether it can play the bytes
        // by that header, so a type guessed from something other than the file is a
        // `206` of good bytes the player refuses.
        try await withPlantedExports([(identifier: clipIdentifier, bytes: clipBytes)]) {
            try await withServer(extraSeed: stillsAndClips()) { server in
                try await server.write("""
                GET /api/photo/\(clipIdentifier)/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Connection: close\r
                \r

                """)
                let response = checkNotNil(try await server.readResponse(), "the response")
                checkEqual(response?.status, 200, "a request with no Range is the whole file")
                checkEqual(response?.header("accept-ranges"), "bytes",
                           "and it advertises that ranges are available")
                checkEqual(response?.header("content-type"), "video/quicktime",
                           "the type comes from the exported file's extension")
                checkEqual(response?.header("content-length").flatMap { Int($0) }, clipLength,
                           "Content-Length is the file's length")
                checkEqual(response?.body.count, clipLength, "and the body really is that many bytes")
                checkEqual(response?.body, clipBytes, "byte for byte")
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "Range: bytes=0-99 is a 206 of exactly the first 100 bytes", knownBug: nil) {
        try await withPlantedExports([(identifier: clipIdentifier, bytes: clipBytes)]) {
            try await withServer(extraSeed: stillsAndClips()) { server in
                try await server.write("""
                GET /api/photo/\(clipIdentifier)/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Range: bytes=0-99\r
                Connection: close\r
                \r

                """)
                let response = checkNotNil(try await server.readResponse(), "the response")
                checkEqual(response?.status, 206, "a satisfiable range is 206, not 200")
                checkEqual(response?.reason, "Partial Content", "with a reason phrase that agrees")
                checkEqual(response?.header("content-range"), "bytes 0-99/\(clipLength)",
                           "Content-Range names the segment and the real length")
                checkEqual(response?.header("content-length").flatMap { Int($0) }, 100,
                           "Content-Length is the range, not the file")
                checkEqual(response?.body, clipBytes.prefix(100), "and the body really is bytes 0…99")
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "Range: bytes=100- really seeks — the body starts at byte 100", knownBug: nil) {
        // The case that separates a correct implementation from one that resolves the
        // range and then replays the head of the file. Both produce a `206` with the
        // right `Content-Length` and the right `Content-Range`; the difference is in
        // the bytes, and a player fed the head of a clip decodes it as a frozen
        // frame rather than as an error.
        try await withPlantedExports([(identifier: clipIdentifier, bytes: clipBytes)]) {
            try await withServer(extraSeed: stillsAndClips()) { server in
                try await server.write("""
                GET /api/photo/\(clipIdentifier)/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Range: \(longRange)\r
                Connection: close\r
                \r

                """)
                let response = checkNotNil(try await server.readResponse(), "the response")
                checkEqual(response?.status, 206, "an open-ended range is 206")
                checkEqual(response?.header("content-range"), "bytes 100-\(clipLength - 1)/\(clipLength)",
                           "Content-Range runs from the requested offset to the last byte")
                checkEqual(response?.header("content-length").flatMap { Int($0) }, clipLength - 100,
                           "Content-Length counts from the offset to the end")
                let expected = clipBytes.dropFirst(100)
                checkEqual(response?.body, expected, "the body is the tail, not the head replayed")
                check(response?.body.prefix(100) != clipBytes.prefix(100),
                      "and it is visibly not the first 100 bytes of the file")
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "Range: bytes=<size>- is a 416 that reports the real length", knownBug: nil) {
        // Past the end. The one case where the error carries more information than
        // the success would have: `bytes */<size>` is how a client whose seek landed
        // beyond the end learns how long the clip actually is.
        try await withPlantedExports([(identifier: clipIdentifier, bytes: clipBytes)]) {
            try await withServer(extraSeed: stillsAndClips()) { server in
                try await server.write("""
                GET /api/photo/\(clipIdentifier)/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Range: bytes=\(clipLength)-\r
                Connection: close\r
                \r

                """)
                let response = checkNotNil(try await server.readResponse(), "the refusal")
                checkEqual(response?.status, 416, "a first byte at the length is past the end")
                checkEqual(response?.reason, "Range Not Satisfiable", "with the phrase for the code")
                checkEqual(response?.header("content-range"), "bytes */\(clipLength)",
                           "and Content-Range reports the real length")
                check(response?.header("content-length").flatMap { Int($0) } ?? 0 < clipLength,
                      "and no part of the clip is served")
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "Range: bytes=50-10 is a 416", knownBug: nil) {
        // Inverted. Answering it with a `206` would hand the client bytes from
        // somewhere it did not ask for — a segment of negative length, which the
        // connection would announce and then not honour.
        try await withPlantedExports([(identifier: clipIdentifier, bytes: clipBytes)]) {
            try await withServer(extraSeed: stillsAndClips()) { server in
                try await server.write("""
                GET /api/photo/\(clipIdentifier)/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Range: bytes=50-10\r
                Connection: close\r
                \r

                """)
                let response = checkNotNil(try await server.readResponse(), "the refusal")
                checkEqual(response?.status, 416, "an inverted range is not satisfiable")
                checkEqual(response?.header("content-range"), "bytes */\(clipLength)",
                           "and it reports the real length")
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "Range: bytes=abc serves the whole file, not a 500 and not a guessed range", knownBug: nil) {
        // Fails silently if wrong. A `500` here would be absurd, and so would
        // guessing at a range from text that is not one: a client asking for
        // `bytes=abc` and given three bytes of clip at offset 0 has no way to tell
        // that from a server that misread it. Serving the whole file is the same
        // path a request with no `Range` at all takes.
        try await withPlantedExports([(identifier: clipIdentifier, bytes: clipBytes)]) {
            try await withServer(extraSeed: stillsAndClips()) { server in
                try await server.write("""
                GET /api/photo/\(clipIdentifier)/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Range: bytes=abc\r
                Connection: close\r
                \r

                """)
                let response = checkNotNil(try await server.readResponse(), "the response")
                checkNotEqual(response?.status, 500, "a header this server did not understand is not a server error")
                checkEqual(response?.status, 200, "an unparseable Range is ignored and the whole file is served")
                checkEqual(response?.header("content-length").flatMap { Int($0) }, clipLength,
                           "with the whole length")
                checkNil(response?.header("content-range"),
                         "and no Content-Range, because no range was honoured")
                checkEqual(response?.body, clipBytes, "byte for byte")
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "Range: bytes=0-1,5-6 serves the whole file, not a 206 and not multipart", knownBug: nil) {
        // The second row that passes silently if wrong. `multipart/byteranges` is
        // optional in RFC 9110 §14.1, and answering it means a second framing mode on
        // a connection whose framing this server otherwise gets right; serving the
        // whole file is a valid answer to any range request. What must not happen is
        // a `206` — a client that asked for two segments and is handed one, with a
        // `Content-Range` naming one of them, cannot tell.
        try await withPlantedExports([(identifier: clipIdentifier, bytes: clipBytes)]) {
            try await withServer(extraSeed: stillsAndClips()) { server in
                try await server.write("""
                GET /api/photo/\(clipIdentifier)/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Range: bytes=0-1,5-6\r
                Connection: close\r
                \r

                """)
                let response = checkNotNil(try await server.readResponse(), "the response")
                checkEqual(response?.status, 200, "a multi-range request is ignored, not partially honoured")
                checkNotEqual(response?.header("content-type"), "multipart/byteranges",
                               "and never answered with a multipart body")
                checkEqual(response?.header("content-length").flatMap { Int($0) }, clipLength,
                           "so Content-Length is the whole file")
                checkNil(response?.header("content-range"), "with no Content-Range")
                checkEqual(response?.body, clipBytes, "byte for byte")
            }
        }
    })

    // MARK: framing

    Registry.shared.add(suite: suite, TestCase(name: "HEAD keeps the range Content-Length, sends no body, and leaves the connection in sync", knownBug: nil) {
        // Why `HEAD` exists in this server's contract at all, and the only part of it
        // that matters is the desynchronisation. A `HEAD` client reads no body, so a
        // body sent anyway is read as the start of the *next* response: the following
        // request's headers arrive as body bytes and its body as a status line. Nothing
        // errors; the connection is simply wrong from then on.
        //
        // The range `Content-Length` has to survive too (RFC 9110 §9.3.2): it is the
        // number a client sizes its buffer from, and dropping it for a `HEAD` would
        // make `HEAD` and `GET` disagree about the same resource.
        //
        // Both halves are checked on two connections, because they fail in different
        // ways. Draining the bytes and finding them empty proves *no body was sent*;
        // then a fresh connection sends the next request without draining anything, so
        // a body that was sent anyway is still sitting in the buffer when the response
        // parser looks for a header block — which is the desync, observed rather than
        // inferred.
        try await withPlantedExports([(identifier: clipIdentifier, bytes: clipBytes)]) {
            try await withServer(extraSeed: stillsAndClips()) { server in
                try await server.write("""
                HEAD /api/photo/\(clipIdentifier)/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Range: bytes=0-99\r
                \r

                """)
                let head = checkNotNil(try await server.readHeader(), "the HEAD response")
                checkEqual(head?.status, 206, "HEAD resolves the same route as GET")
                checkEqual(head?.header("content-length"), "100",
                           "and reports the range length GET would have announced")
                checkEqual(head?.header("content-range"), "bytes 0-99/\(clipLength)",
                           "with the same Content-Range")
                checkEqual(head?.header("accept-ranges"), "bytes", "and the same Accept-Ranges")
                checkEqual(head?.header("connection"), "keep-alive", "the connection stays open")

                // Zero body bytes, read as raw bytes rather than through the parser:
                // the parser is the thing that would have to understand a spliced body
                // in order to notice one.
                let tail = try await server.readRaw(afterSeconds: 1)
                check(tail.isEmpty,
                      "a HEAD sends no body at all, got \(tail.prefix(48).debugDescription)")

                // And the connection is still usable, which is the whole claim.
                try await server.write("""
                GET /api/photos?limit=2 HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Connection: close\r
                \r

                """)
                let response = checkNotNil(try await server.readResponse(), "the following GET")
                checkEqual(response?.status, 200, "the connection is still in sync after a HEAD")
                checkEqual((json(response)["items"] as? [Any])?.count, 2,
                           "and its body is the response, not a tail of the HEAD's")
                checkNil(try await server.readOptionalResponse(), "with nothing after it")

                // Same again with nothing drained, so the body cannot be quietly
                // removed from the buffer before the next response is read. This is the
                // order a real client is in: it issues the next request and only then
                // starts parsing.
                try await server.reconnect()
                try await server.write("""
                HEAD /api/photo/\(clipIdentifier)/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Range: bytes=0-99\r
                \r
                GET /api/photos?limit=2 HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Connection: close\r
                \r

                """)
                let pipelinedHead = checkNotNil(try await server.readHeader(), "the HEAD response")
                checkEqual(pipelinedHead?.status, 206, "HEAD still answers 206")
                let after = checkNotNil(try await server.readResponse(),
                                        "the request behind it, with nothing drained in between")
                checkEqual(after?.status, 200,
                           "so a HEAD does not desynchronise the connection it leaves open")
                checkEqual((json(after)["items"] as? [Any])?.count, 2,
                           "and the response behind it parses as the JSON it is")
            }
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "keep-alive: a multi-chunk partial range, then a JSON route on the same connection", knownBug: nil) {
        // The "exactly one re-arm after the final chunk" guard.
        //
        // The file path hands the connection back twice over: once when the last
        // chunk is out, and once by whatever else finishes the response. Two
        // re-armings mean `busy` is cleared and `processBuffer` is called while the
        // next request is already in the buffer, so its response is dispatched
        // alongside a body that is still being written — two responses interleaved on
        // one connection. That is only observable end to end, and only when the
        // follow-up request is *already sent*, which is why both requests go out in
        // one write: a client that waits for the body before asking again would never
        // have the next request in the buffer at the moment the second re-arm fires.
        //
        // The range is 1.2 MB from offset 100, so it spans three 512 KB writes and the
        // final chunk is reached the long way.
        try await withPlantedExports([(identifier: clipIdentifier, bytes: clipBytes)]) {
            try await withServer(extraSeed: stillsAndClips()) { server in
                try await server.write("""
                GET /api/photo/\(clipIdentifier)/video HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Range: \(longRange)\r
                \r
                GET /api/photos?limit=2 HTTP/1.1\r
                Host: 127.0.0.1:\(server.port)\r
                Connection: close\r
                \r

                """)
                let clip = checkNotNil(try await server.readResponse(), "the clip")
                checkEqual(clip?.status, 206, "the clip answers 206")
                checkEqual(clip?.header("content-length").flatMap { Int($0) }, clipLength - 100,
                           "with the range length")
                checkEqual(clip?.body, clipBytes.dropFirst(100), "and every byte from the offset")

                let response = checkNotNil(try await server.readResponse(), "the JSON response behind it")
                checkEqual(response?.status, 200, "the second request on the connection is answered normally")
                checkEqual((json(response)["items"] as? [Any])?.count, 2,
                           "and parses as the JSON it is, not as a tail of the clip")
                checkNil(try await server.readOptionalResponse(), "and there is no third response to two requests")
            }
        }
    })

    // MARK: the media filter on the grid

    let filterSuite = "video media filter"

    Registry.shared.add(suite: filterSuite, TestCase(name: "?media=vidoes is a 400 naming the three values, never a silent all", knownBug: nil) {
        // The failure this prevents is not a wrong picture, it is a wrong *deletion*.
        // A client that sent `?media=videos` and was quietly answered with the
        // unfiltered grid would render every photo in the library under a "Videos"
        // heading; a user deleting from that page would be deleting photos while
        // looking at what they believe is a list of clips, and every confirmation
        // count in between would be true — of the wrong set.
        try await withServer(extraSeed: stillsAndClips()) { server in
            try await server.write("""
            GET /api/photos?media=vidoes HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: close\r
            \r

            """)
            let response = checkNotNil(try await server.readResponse(), "the refusal")
            checkEqual(response?.status, 400, "a misspelled media filter is a client error")
            let message = json(response)["error"] as? String ?? ""
            check(message.contains("\"all\""), "the error names \"all\": \(message)")
            check(message.contains("\"images\""), "the error names \"images\": \(message)")
            check(message.contains("\"videos\""), "the error names \"videos\": \(message)")
            check(response?.bodyString.contains("\"items\"") == false,
                  "and no grid is served at all, so nothing can be selected from it")
        }
    })

    Registry.shared.add(suite: filterSuite, TestCase(name: "no media parameter echoes filter.media = all", knownBug: nil) {
        try await withServer(extraSeed: stillsAndClips()) { server in
            try await server.write("""
            GET /api/photos HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: close\r
            \r

            """)
            let response = checkNotNil(try await server.readResponse(), "the response")
            checkEqual(response?.status, 200, "an absent media filter is not an error")
            let filter = json(response)["filter"] as? [String: Any] ?? [:]
            checkEqual(filter["media"] as? String, "all", "and it is echoed as \"all\"")
        }
    })

    Registry.shared.add(suite: filterSuite, TestCase(name: "?media= (empty) is treated as absent, so it is all", knownBug: nil) {
        // A client that builds the query string unconditionally sends `media=` rather
        // than omitting it. That has to mean the same thing, or an empty bucket
        // becomes a 400 on a page that worked a moment ago.
        try await withServer(extraSeed: stillsAndClips()) { server in
            try await server.write("""
            GET /api/photos?media= HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: close\r
            \r

            """)
            let response = checkNotNil(try await server.readResponse(), "the response")
            checkEqual(response?.status, 200, "an empty media parameter is not an error")
            let filter = json(response)["filter"] as? [String: Any] ?? [:]
            checkEqual(filter["media"] as? String, "all", "and it is treated as absent")
            checkEqual(json(response)["total"] as? Int, 14, "so the unfiltered grid comes back")
        }
    })

    Registry.shared.add(suite: filterSuite, TestCase(name: "?media=videos returns only clips, and says so", knownBug: nil) {
        // Every row checked, not just the first: a filter applied to the count but not
        // to the rows is a `total` that lies.
        try await withServer(extraSeed: stillsAndClips()) { server in
            try await server.write("""
            GET /api/photos?media=videos HTTP/1.1\r
            Host: 127.0.0.1:\(server.port)\r
            Connection: close\r
            \r

            """)
            let response = checkNotNil(try await server.readResponse(), "the response")
            checkEqual(response?.status, 200, "a valid media filter is applied")
            let document = json(response)
            let filter = document["filter"] as? [String: Any] ?? [:]
            checkEqual(filter["media"] as? String, "videos", "and is echoed back, so a client can tell what it got")
            let rows = document["items"] as? [[String: Any]] ?? []
            checkEqual(rows.count, 2, "the two seeded clips come back")
            for row in rows {
                checkEqual((row["mediaType"] as? NSNumber)?.intValue, 2,
                           "every row is a clip: \(row["id"] ?? "?")")
            }
            checkEqual(document["total"] as? Int, 2, "and total counts only the clips, not all fourteen rows")
            check((document["bounds"] as? [String: Any]) != nil,
                  "the score bounds are still reported")
        }
    })

    // MARK: videos are not group members

    let groupSuite = "video groups"

    Registry.shared.add(suite: groupSuite, TestCase(name: "/api/groups?media=videos is an empty list, not an error", knownBug: nil) {
        // Videos are never group members — the FeaturePrint threshold was calibrated
        // on stills, and one frame of a clip that pans away would put a video against
        // a merely-resembling still. So `media=videos` is a truthful empty list, and
        // it has to be produced *by the filter* rather than short-circuited, or the
        // day a video can join a group the route needs changing and nothing says so.
        //
        // The control matters: with no group seeded this would pass however the filter
        // were written, because the unfiltered list would be empty too.
        let fixture = try await Fixture.make("video-groups-list")
        try await fixture.seed([
            .init(id: "a1", score: 0.4, date: 100),
            .init(id: "a2", score: 0.9, date: 101),
            .init(id: "v1", score: 0.5, date: 102, mediaType: 2, duration: 4),
        ])
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2"])],
                                              settings: .default,
                                              faceMemberCounts: [:], earliestDates: ["a1": 100])

        let all = await fixture.router.reply(Req.get("/api/groups"))
        checkEqual(all.status, 200, "the unfiltered list is served")
        checkEqual((all.json["groups"] as? [Any])?.count, 1, "and it has the one seeded group")

        let videos = await fixture.router.reply(Req.get("/api/groups", query: ["media": "videos"]))
        checkEqual(videos.status, 200, "media=videos is answered, not refused")
        checkEqual((videos.json["groups"] as? [Any])?.count, 0,
                   "with no groups, because no video is ever a member")
        checkEqual(videos.int("total"), 0, "and a total of zero rather than the unfiltered count")
        checkNotNil(videos.json["status"] as? [String: Any],
                    "the rest of the response is still a group-list response")

        let images = await fixture.router.reply(Req.get("/api/groups", query: ["media": "images"]))
        checkEqual(images.status, 200, "media=images is answered too")
        checkEqual((images.json["groups"] as? [Any])?.count, 1,
                   "and keeps the group, so the filter is discriminating rather than always-empty")
    })

    Registry.shared.add(suite: groupSuite, TestCase(name: "/api/group?id=…&media=videos answers an empty group, not a 404", knownBug: nil) {
        // The group exists; the videos filter keeps none of its members. A `404`
        // would tell a client the group is gone, and the user would be sent looking
        // for a burst of photos that is still there — the same class of wrong answer
        // the `409` on an iCloud-only clip exists to avoid.
        let fixture = try await Fixture.make("video-groups-one")
        try await fixture.seed([
            .init(id: "a1", score: 0.4, date: 100),
            .init(id: "a2", score: 0.9, date: 101),
            .init(id: "v1", score: 0.5, date: 102, mediaType: 2, duration: 4),
        ])
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2"])],
                                              settings: .default,
                                              faceMemberCounts: [:], earliestDates: ["a1": 100])

        let all = await fixture.router.reply(Req.get("/api/group", query: ["id": "a1"]))
        checkEqual(all.status, 200, "the unfiltered group is served")
        checkEqual(all.int("memberCount"), 2, "with both members")
        checkEqual((all.json["items"] as? [Any])?.count, 2, "in its item list")

        let videos = await fixture.router.reply(Req.get("/api/group", query: ["id": "a1", "media": "videos"]))
        checkEqual(videos.status, 200, "the group still exists under media=videos")
        checkNotEqual(videos.status, 404, "so it is not reported as missing")
        checkEqual(videos.int("memberCount"), 0, "but it has no members the filter keeps")
        checkEqual((videos.json["items"] as? [Any])?.count, 0, "and no items")
        checkEqual(videos.int("hiddenMemberCount"), 2,
                   "reporting what the filter dropped rather than absorbing it")

        let unknown = await fixture.router.reply(Req.get("/api/group", query: ["id": "nope", "media": "videos"]))
        checkEqual(unknown.status, 404, "a group this instance never built is still a 404")
    })

    // MARK: the selection snapshot

    let selectionSuite = "video selection snapshot"

    Registry.shared.add(suite: selectionSuite, TestCase(name: "an all-matching selection on a photos-only grid counts no clips", knownBug: nil) {
        // The load-bearing case. "Select all matching" snapshots the filter the user
        // is looking at; a snapshot missing the media dimension resolves to every
        // photo *and every video* on a grid showing only photos, so the confirmation
        // dialog counts a library's worth of clips the user never saw and the
        // deletion is then authorised against that count.
        //
        // Asserted against the `media=all` count as well, because "excludes videos"
        // is only a claim if something was there to exclude.
        let fixture = try await Fixture.make("video-selection-images")
        try await fixture.seed([
            .init(id: "p1", score: 0.30, date: 1),
            .init(id: "p2", score: 0.31, date: 2),
            .init(id: "p3", score: 0.32, date: 3),
            .init(id: "v1", score: 0.33, date: 4, mediaType: 2, duration: 9),
            .init(id: "v2", score: 0.34, date: 5, mediaType: 2, duration: 9),
            .init(id: "v3", score: 0.35, date: 6, mediaType: 2, duration: 9),
        ])
        let bounds = #""lo":-1,"hi":1"#

        let images = await fixture.router.reply(Req.post("/api/selection/preview", json:
            #"{"mode":"matching","filter":{\#(bounds),"media":"images"}}"#))
        checkEqual(images.status, 200, "a photos-only selection is resolved")
        checkEqual(images.int("resolved"), 3, "and counts the three photographs")
        checkEqual(images.int("requested"), 3, "having asked for three")
        checkEqual(images.bool("appliesToAllMatching"), true, "and it is an all-matching selection")

        let all = await fixture.router.reply(Req.post("/api/selection/preview", json:
            #"{"mode":"matching","filter":{\#(bounds),"media":"all"}}"#))
        checkEqual(all.status, 200, "the unfiltered selection is resolved too")
        checkEqual(all.int("resolved"), 6, "and it really does find the three clips as well")
        check(images.string("confirmToken") != all.string("confirmToken"),
              "so the two are different decisions, which is what the next case pins down")
    })

    Registry.shared.add(suite: selectionSuite, TestCase(name: "a misspelled media filter in a selection is a 400 and selects nothing", knownBug: nil) {
        let fixture = try await Fixture.make("video-selection-typo")
        try await fixture.seed([
            .init(id: "p1", score: 0.30, date: 1),
            .init(id: "v1", score: 0.31, date: 2, mediaType: 2, duration: 9),
        ])
        let typo = await fixture.router.reply(Req.post("/api/selection/preview", json:
            #"{"mode":"matching","filter":{"lo":-1,"hi":1,"media":"vidoes"}}"#))
        checkEqual(typo.status, 400, "a typo in the media dimension is a client error")
        let message = typo.errorMessage
        check(message.contains("all") && message.contains("images") && message.contains("videos"),
              "and the error names the three valid values: \(message)")
        check(!typo.has("resolved"), "no count is produced, so nothing can be confirmed from it")
        check(!typo.has("confirmToken"), "and no token, so nothing can be deleted against it")

        // Substituting `.all` would add every clip; substituting `.images` would
        // silently drop rows. A typo has to be neither.
        checkEqual((try await fixture.cache.stats(maxAge: 0)).total, 2, "the cache is untouched")
    })

    Registry.shared.add(suite: selectionSuite, TestCase(name: "a preview taken under media=images cannot authorise a delete under media=all", knownBug: nil) {
        // The check that stands between what the user reviewed and what gets
        // deleted. The user is looking at a photos-only grid, confirms "3 photos",
        // and the request that arrives says `media=all` — every clip is now in scope.
        // The two resolve to different sets, so the token over the confirmed set does
        // not match the one recomputed for the deletion, and the deletion is refused
        // with `409` and nothing is deleted.
        //
        // Safe to send: the token comparison in `Router.delete` runs *before*
        // `PhotoLibrary.delete` is reached, so a refused deletion cannot touch the
        // library. The assertions below check that it really was refused, rather than
        // relying on the order of two statements in a file this test does not own.
        let fixture = try await Fixture.make("video-selection-token")
        try await fixture.seed([
            .init(id: "p1", score: 0.30, date: 1),
            .init(id: "p2", score: 0.31, date: 2),
            .init(id: "v1", score: 0.32, date: 3, mediaType: 2, duration: 9),
            .init(id: "v2", score: 0.33, date: 4, mediaType: 2, duration: 9),
        ])
        let preview = await fixture.router.reply(Req.post("/api/selection/preview", json:
            #"{"mode":"matching","filter":{"lo":-1,"hi":1,"media":"images"}}"#))
        checkEqual(preview.status, 200, "the photos-only preview is served")
        checkEqual(preview.int("resolved"), 2, "over two photographs")
        let token = checkNotNil(preview.string("confirmToken"), "a confirmToken")

        // What the user did *not* see: the same bounds with the media dimension
        // dropped, which is what a client that lost its filter chip would send.
        let widened = await fixture.router.reply(Req.post("/api/selection/preview", json:
            #"{"mode":"matching","filter":{"lo":-1,"hi":1,"media":"all"}}"#))
        checkEqual(widened.int("resolved"), 4, "the widened selection covers four assets")
        check(widened.string("confirmToken") != token,
              "so it carries a different confirmToken")

        let refused = await fixture.router.reply(Req.post("/api/delete", json:
            #"{"mode":"matching","filter":{"lo":-1,"hi":1,"media":"all"},"confirmToken":"\#(token ?? "")"}"#))
        checkEqual(refused.status, 409, "the deletion confirmed against the narrower set is refused")
        check(refused.errorMessage.lowercased().contains("selection changed"),
              "and says the selection changed: \(refused.errorMessage)")
        check(!refused.has("deleted"), "no deletion report is produced at all")
        checkEqual((try await fixture.cache.stats(maxAge: 0)).total, 4, "and nothing is removed from the cache")

        // The control, and the reason it needs its own fixture: a *matching* token is
        // accepted, so the 409 above is about the mismatch rather than about the
        // route refusing everything. Here every row is a favourite, so an acceptance
        // resolves to nothing — `interceptDeletes` has no equivalent on this side of
        // the socket, and this is the substitute for it. Even if the order of
        // statements in `Router.delete` were to change, this control would still
        // resolve to an empty set.
        let safe = try await Fixture.make("video-selection-token-safe")
        try await safe.seed([
            .init(id: "p1", score: 0.30, date: 1, favorite: true),
            .init(id: "v1", score: 0.31, date: 2, favorite: true, mediaType: 2, duration: 9),
        ])
        let safePreview = await safe.router.reply(Req.post("/api/selection/preview", json:
            #"{"mode":"matching","filter":{"lo":-1,"hi":1,"media":"images"}}"#))
        let accepted = await safe.router.reply(Req.post("/api/delete", json:
            #"{"mode":"matching","filter":{"lo":-1,"hi":1,"media":"images"},"confirmToken":"\#(safePreview.string("confirmToken") ?? "")"}"#))
        checkEqual(accepted.status, 200, "a current token is accepted, so the 409 above is the mismatch")
        checkEqual(accepted.int("resolved"), 0, "and protection leaves nothing to delete")
        checkEqual(accepted.int("deleted"), 0, "so nothing was deleted")
    })
}

/// Not `==`, for the one place where "not the same" is the assertion. Written out
/// rather than using `check(a != b)`, which reads as a typo of `checkEqual`.
private func checkNotEqual<T: Equatable>(_ actual: T?, _ unexpected: T?,
                                         _ what: @autoclosure () -> String,
                                         file: StaticString = #fileID, line: UInt = #line) {
    if let actual, let unexpected, actual == unexpected {
        Harness.record("\(what()): \(actual) is exactly what must not happen  (\(file):\(line))")
    }
}
