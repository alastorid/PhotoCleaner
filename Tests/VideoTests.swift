import Foundation
import SQLite3

// Video support: the pure logic underneath it.
//
// Video arrived as three parallel features — library (frames), cache+HTTP (schema
// version 5, `Range`), web+docs — and nothing in this file needs a Photos library,
// a clip on disk or a socket. Everything asserted here is a value: a list of frame
// times, a SQL fragment, a `WHERE`-clause shape, a byte range, a median, a schema
// column.
//
// Two of the claims below are load-bearing in a way that is easy to lose silently,
// which is why they are pinned rather than assumed:
//
//  * **The media dimension is a literal, not a placeholder.** `PhotoFilter`'s
//    `WHERE` has a fixed parameter budget — `?1`/`?2` are the score bounds, `?3`
//    the album identifier, and keyset pagination starts at `?4`. One extra `?`
//    renumbers all of them, and the failure is not an error: the grid returns rows
//    from somewhere else in the library, and nothing notices that a *number* is
//    wrong rather than a page being empty.
//  * **A clip's score is a median.** One black leader frame is not supposed to be
//    able to decide it. The mean would let it move the answer by a third, and the
//    grid sorts on this number, so "one clip in a hundred scored terribly" would
//    read as "one clip in a hundred is terrible".

func registerVideoTests() {
    let suite = "video support"

    // MARK: - the export cache's filename

    Registry.shared.add(suite: suite, TestCase(name: "a cache filename survives an identifier with slashes, and is injective",
        knownBug: nil) {
        // A Photos `localIdentifier` contains `/` (`…/L0/001`), so using one verbatim
        // as a path component escapes the cache directory and `install`'s move fails.
        // The encoding has to be injective too: two identifiers sharing a filename
        // would serve one person's clip for another's.
        let awkward = "E6CE86CA-57E5-4C14-940C-DA8193961D55/L0/001"
        let name = VideoLibrary.digest(awkward)
        check(!name.contains("/"), "an identifier's slashes cannot reach the path: \(name)")
        check(!name.contains("\\"), "nor its backslashes")
        checkEqual(name, VideoLibrary.digest(awkward), "the same identifier is the same name")
        check(name != VideoLibrary.digest(awkward + "x"), "one more character is a different name")
        check(VideoLibrary.digest("a/b") != VideoLibrary.digest("ab"), "a slash is not silently dropped")
        // A `:` would be trouble on some filesystems, and the hex alphabet cannot
        // produce one — which is the property worth pinning.
        check(name.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) },
              "the name is lowercase hex and nothing else: \(name)")
    })

    // MARK: - representativeTimes

    Registry.shared.add(suite: suite, TestCase(name: "representativeTimes names one moment even for a zero-length or absurd duration",
        knownBug: nil) {
        // **Never empty** is the whole contract here. `framesForAnalysis` reads an
        // empty array as "every frame failed", so a duration that produced one
        // would record a *scoring failure* against a perfectly good asset — and
        // `0` is a legal position to decode, so there is nothing to return but a
        // moment.
        checkEqual(VideoLibrary.representativeTimes(duration: 0), [0], "a zero-length clip still names one moment")
        checkEqual(VideoLibrary.representativeTimes(duration: -5), [0], "and so does a negative one, which Photos cannot report but a bug can")
        checkEqual(VideoLibrary.representativeTimes(duration: 0.05), [0],
                   "at 50 ms every fraction clamps onto the same position, so there is one moment")

        // The boundary where three becomes two: 10% of 0.06 s is 0.006, inside the
        // clip, while 50% and 90% both clamp to the 0.01 ceiling and collapse onto
        // each other. The *count* is the assertion, because "a short clip yields
        // fewer moments" is the claim and a list of the right length is what it
        // means.
        let two = VideoLibrary.representativeTimes(duration: 0.06)
        checkEqual(two.count, 2, "0.06 s yields exactly two distinct moments, not three and not one")

        checkEqual(VideoLibrary.representativeTimes(duration: 1), [0.1, 0.5, 0.9],
                   "the documented fractions of a one-second clip")
        checkEqual(VideoLibrary.representativeTimes(duration: 3600), [360, 1800, 3240],
                   "and of a one-hour one: fractions scale, so the whole timeline is sampled")

        // `PHAsset.duration` is a `Double` off a foreign boundary. NaN is not
        // ordered, so `max(0, …)` alone would let it through and produce a NaN
        // timestamp; `.infinity` would produce an infinity. Neither may trap, and
        // neither may become a moment a generator would be asked for.
        for weird in [Double.nan, .infinity, -.infinity] {
            let times = VideoLibrary.representativeTimes(duration: weird)
            checkEqual(times, [0], "duration \(weird) is normalised to a single moment at 0")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "every duration keeps its moments non-empty, ascending, distinct and inside the clip",
        knownBug: nil) {
        // The per-value cases above are the boundaries; this is the property they
        // were chosen from. A sweep at 10 ms over two hours is 600k clips, and the
        // four invariants below are the ones that make an array of frame times
        // usable: a non-empty array means the clip is analysed at all, ascending
        // means a caller can tell which moment it holds, no duplicates means the
        // median is taken over real observations rather than one observation wearing
        // three hats, and inside the clip means the generator is not asked for a
        // frame past the end of the track (which it answers *and* reports as an
        // error, so every clip under half a second would log a warning per sample).
        var checked = 0
        for step in stride(from: 0.0, through: 6000.0, by: 0.01) {
            let times = VideoLibrary.representativeTimes(duration: step)
            let label = String(format: "duration %.2f", step)
            if times.isEmpty {
                check(false, "\(label): representativeTimes must never be empty")
                break
            }
            if times.count > 3 {
                check(false, "\(label): at most three moments, got \(times)")
                break
            }
            for index in 1..<max(times.count, 1) where !(times[index] > times[index - 1]) {
                check(false, "\(label): moments must be strictly ascending, got \(times)")
                break
            }
            checkNoDuplicates(times, "\(label): a duplicate moment is not a second observation")
            let ceiling = max(0, step - 0.05)
            for time in times where !(time >= 0 && time <= ceiling) {
                check(false, "\(label): \(time) is outside 0...\(ceiling)")
                break
            }
            checked += 1
        }
        check(checked > 590_000, "the sweep actually ran: \(checked) durations")
    })

    // MARK: - MediaSelection

    Registry.shared.add(suite: suite, TestCase(name: "the media predicate is a literal, and never binds a parameter",
        knownBug: nil) {
        checkEqual(MediaSelection.all.whereSQLClause(), "", ".all constrains nothing")
        checkEqual(MediaSelection.images.whereSQLClause(), "media_type = 1", "images")
        checkEqual(MediaSelection.videos.whereSQLClause(), "media_type = 2", "videos")

        // The character check, over the composed string rather than the source: this
        // is the guarantee, and it is what a future edit that switches to a bound
        // value would break. `?1`/`?2` are the score bounds, `?3` the album, and
        // `CacheStore.page` binds `?4`/`?5` for the cursor's sort key, `?6` for its
        // identifier and `?7` for `LIMIT`. One more placeholder anywhere in the
        // `WHERE` renumbers all of them and the score bounds end up bound against
        // the wrong columns — a grid that returns plausible photos from an unrelated
        // part of the library.
        for selection in MediaSelection.allCases {
            let clause = selection.whereSQLClause()
            check(!clause.contains("?"),
                  "\(selection.rawValue) must not bind a parameter, got \"\(clause)\"")
        }

        // And composed with the rest of the filter, the numbering is still `?1`,
        // `?2`, `?3` and nothing above it.
        let videos = PhotoFilter(lower: -1, upper: 1, media: .videos).whereSQLClause()
        checkEqual(videos.filter { $0 == "?" }.count, 2,
                   "media alone adds no placeholder to the two score bounds, got \"\(videos)\"")
        let withAlbum = PhotoFilter(lower: -1, upper: 1, album: .album("a1"), media: .videos).whereSQLClause()
        checkEqual(withAlbum.filter { $0 == "?" }.count, 3,
                   "an album plus media is still three placeholders, got \"\(withAlbum)\"")
        for number in ["?1", "?2", "?3"] {
            check(withAlbum.contains(number), "\(number) is where it was before video support, got \"\(withAlbum)\"")
        }
        check(!withAlbum.contains("?4"),
              "and nothing above ?3 binds, so the keyset keeps its numbering, got \"\(withAlbum)\"")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the media values are exactly three, and an unrecognised one is refused",
        knownBug: nil) {
        checkEqual(MediaSelection.allCases.count, 3, "all, images, videos")
        for selection in MediaSelection.allCases {
            checkEqual(selection.wireValue, selection.rawValue, "\(selection) spells itself on the wire")
            checkNotNil(MediaSelection(rawValue: selection.rawValue), "round trip of \(selection.rawValue)")
        }
        // A closed set: the value selects a SQL predicate, so quietly widening
        // `media=videos` to "every asset" would show the user photos they filtered
        // out — and a deletion resolved under the widened filter would act on them.
        for refused in ["video", "Videos", "", " image", "images ", "IMAGES", "clip", "clips"] {
            checkNil(MediaSelection(rawValue: refused), "media=\"\(refused)\" must not resolve")
        }

        // Every pair of fingerprints differs, not merely the two that matter: a
        // fingerprint that collided would let a token cross the dimension with
        // nothing to notice.
        let fingerprints = MediaSelection.allCases.map(\.fingerprint)
        checkEqual(Set(fingerprints).count, 3, "three distinct fingerprints, got \(fingerprints)")
        for selection in MediaSelection.allCases {
            check(selection.fingerprint.contains(selection.rawValue),
                  "\(selection.rawValue) names itself in its fingerprint, got \"\(selection.fingerprint)\"")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "the grid's media filter really separates stills from clips",
        knownBug: nil) {
        // The SQL fragment is asserted as a string above; this is the same claim
        // reached the way a user reaches it. A filter that quietly widened to `all`
        // looks exactly right on a fixture holding one kind of asset, so the fixture
        // holds two of each and every bucket is counted — including `.all`, which is
        // the bucket that would silently grow if a predicate were dropped.
        let fixture = try await Fixture.make("video-grid")
        try await fixture.seed([
            .init(id: "still-1", score: 0.9, date: 400),
            .init(id: "still-2", score: 0.7, date: 300),
            .init(id: "clip-1", score: 0.8, date: 350, mediaType: 2, duration: 12),
            .init(id: "clip-2", score: 0.6, date: 250, mediaType: 2, duration: 4),
        ])

        func ids(_ media: MediaSelection) async throws -> [String] {
            let filter = PhotoFilter(lower: -1, upper: 1, media: media)
            return try await fixture.cache.identifiers(matching: filter, limit: 100)
                .sorted()
        }

        checkEqual(try await ids(.all), ["clip-1", "clip-2", "still-1", "still-2"],
                   ".all is every scanned asset, clips included")
        checkEqual(try await ids(.images), ["still-1", "still-2"], ".images is only the photographs")
        checkEqual(try await ids(.videos), ["clip-1", "clip-2"], ".videos is only the clips")

        // And over HTTP, since `Router` builds the same filter from a query string
        // and echoes it back — a client that reads `filter.media` must be told the
        // truth about what it was served.
        for (query, expected) in [("all", 4), ("images", 2), ("videos", 2)] {
            let reply = await fixture.router.reply(Req.get("/api/photos", query: [
                "lo": "-1", "hi": "1", "media": query, "limit": "50",
            ]))
            checkEqual(reply.status, 200, "GET /api/photos?media=\(query)")
            checkEqual(reply.rows().count, expected, "media=\(query) serves \(expected) rows")
            checkEqual((reply.json["filter"] as? [String: Any])?["media"] as? String, query,
                       "and the filter echo says which filter it was")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a cursor issued under one media filter is refused under another",
        knownBug: nil) {
        // A token names a position inside one result set. "The rows after this row
        // among photos" is a different set from "the rows after this row among
        // videos", so a token that crossed the dimension would splice the two
        // together in a list whose positions no longer mean what they did — and the
        // client resets its window on a media change, so the token it *has* is one
        // it minted under the old filter.
        let fixture = try await Fixture.make("video-cursor")
        try await fixture.seed([
            .init(id: "still-a", score: 0.9, date: 300),
            .init(id: "still-b", score: 0.5, date: 200),
            .init(id: "clip-a", score: 0.9, date: 300, mediaType: 2, duration: 12.5),
            .init(id: "clip-b", score: 0.5, date: 200, mediaType: 2, duration: 8),
        ])

        let images = PhotoFilter(lower: -1, upper: 1, media: .images)
        let videos = PhotoFilter(lower: -1, upper: 1, media: .videos)
        check(images.paginationFingerprint != videos.paginationFingerprint,
              "the media dimension is part of the pagination fingerprint")

        let first = try await fixture.cache.page(filter: images, sort: .scoreDescending,
                                                 cursor: nil, limit: 1, offset: 0)
        checkEqual(first.rows.map(\.id), ["still-a"], "the photos-only page holds photographs")
        guard let encoded = checkNotNil(first.nextCursor, "a full page advertises a cursor"),
              let cursor = checkNotNil(PhotoCursor.decode(encoded), "the cursor decodes") else { return }

        var refused: Error?
        do {
            _ = try await fixture.cache.page(filter: videos, sort: .scoreDescending,
                                             cursor: cursor, limit: 1, offset: 0)
        } catch {
            refused = error
        }
        guard let thrown = checkNotNil(refused, "a cursor issued under media=images must not page media=videos") else { return }
        check(String(describing: thrown).contains("different filter"),
              "the refusal says the filter is what changed, got: \(thrown)")
        if case .cursorFilterMismatch = thrown as? CacheError {} else {
            check(false, "and it is the filter-mismatch case specifically, got \(thrown)")
        }

        // The same filter still works, so the refusal is about the token rather than
        // about the videos page being broken.
        let replayed = try await fixture.cache.page(filter: images, sort: .scoreDescending,
                                                    cursor: cursor, limit: 1, offset: 0)
        checkEqual(replayed.rows.map(\.id), ["still-b"], "and the original filter resumes exactly where it left off")

        // Over HTTP the refusal is still a refusal, whatever status carries it.
        let reply = await fixture.router.reply(Req.get("/api/photos", query: [
            "lo": "-1", "hi": "1", "media": "videos", "limit": "1", "cursor": encoded,
        ]))
        check(reply.status >= 400, "the route refuses the crossed cursor, got \(reply.status)")
        checkEqual(reply.rows(), [], "returning nothing rather than photos from the wrong set")
    })

    // MARK: - HTTPRange

    Registry.shared.add(suite: suite, TestCase(name: "Range: the shapes a media element actually asks for",
        knownBug: nil) {
        let size: Int64 = 1000
        checkEqual(HTTPRange.resolve(header: nil, fileSize: size), .whole(length: 1000),
                   "no Range header at all is the whole file")
        checkEqual(HTTPRange.resolve(header: "", fileSize: size), .whole(length: 1000),
                   "an empty one is too")
        checkEqual(HTTPRange.resolve(header: "bytes=0-499", fileSize: size), .partial(start: 0, length: 500),
                   "a bounded range")
        checkEqual(HTTPRange.resolve(header: "bytes=500-", fileSize: size), .partial(start: 500, length: 500),
                   "open-ended from an offset")
        checkEqual(HTTPRange.resolve(header: "bytes=0-", fileSize: size), .partial(start: 0, length: 1000),
                   "open-ended from zero")
        checkEqual(HTTPRange.resolve(header: "bytes=-500", fileSize: size), .partial(start: 500, length: 500),
                   "a suffix: the final 500 bytes")
        checkEqual(HTTPRange.resolve(header: "bytes=-5000", fileSize: size), .partial(start: 0, length: 1000),
                   "a suffix longer than the file is the whole file, not a 416")
        checkEqual(HTTPRange.resolve(header: "BYTES=0-9", fileSize: size), .partial(start: 0, length: 10),
                   "the unit is case-insensitive (RFC 9110 §14.1)")
        // Optional whitespace around a field value is legal, and a proxy that
        // reformats headers will add it. Tolerating it costs a `trimmingCharacters`
        // and its absence costs a player that silently gets the whole file.
        checkEqual(HTTPRange.resolve(header: "  bytes=0-9  ", fileSize: size),
                   .partial(start: 0, length: 10),
                   "surrounding whitespace is tolerated, not treated as a malformed header")

        // An end past EOF is *clamped*, not refused. RFC 9110 §14.1.2 defines the
        // effective end as the smaller of the two, and refusing it would break every
        // client that asks for more than it knows exists — which is what a media
        // element does when it seeks to a duration it estimated a moment early. A
        // 416 here is a seek that never plays.
        checkEqual(HTTPRange.resolve(header: "bytes=0-9999", fileSize: size), .partial(start: 0, length: 1000),
                   "an end past EOF is clamped to the last byte, never a 416")
    })

    Registry.shared.add(suite: suite, TestCase(name: "Range: what is unsatisfiable and what is merely ignored",
        knownBug: nil) {
        let size: Int64 = 1000
        // Unsatisfiable: the client asked for bytes that do not exist. Answering with
        // a 206 instead would hand it bytes from somewhere it did not ask for, and a
        // decoder fed the wrong segment of a clip fails in a way that looks like a
        // corrupt file rather than a bad request.
        for header in ["bytes=1000-", "bytes=5000-5006", "bytes=9-3", "bytes=-0"] {
            checkEqual(HTTPRange.resolve(header: header, fileSize: size), .unsatisfiable,
                       "\"\(header)\" names bytes that do not exist")
        }

        // Ignored, and therefore answered `200` with the whole file. Multipart
        // ranges are optional in RFC 9110 and not worth a second framing mode; an
        // unparseable header this server did not understand is not a server fault
        // and must not become a 500. Serving the file is a correct answer to a
        // request the client can recover from on its own.
        let ignored = ["bytes=0-1,5-6", "bytes=abc", "items=0-10", "bytes=-", "bytes=1-2-3", "0-499", "bytes="]
        for header in ignored {
            checkEqual(HTTPRange.resolve(header: header, fileSize: size), .whole(length: 1000),
                       "\"\(header)\" is ignored, not refused and not guessed at")
        }

        // The rows above are refused *before* either end is ever read — `bytes=abc`
        // has no dash at all, so it never reaches a numeric parse. These are the ones
        // that look like a range and are not one: a dash, and a bound that does not
        // parse. Guessing at either would hand the client bytes it did not ask for,
        // and a decoder fed the wrong segment of a clip fails in a way that looks
        // like a corrupt file rather than a bad request.
        let notARange = ["bytes=abc-", "bytes=abc-def", "bytes=0-abc", "bytes=1.5-2", "bytes=0-x"]
        for header in notARange {
            checkEqual(HTTPRange.resolve(header: header, fileSize: size), .whole(length: 1000),
                       "\"\(header)\" looks like a range and is not one: ignored, never guessed at")
        }

        // Both ends of a range, symmetrically. `bytes=-abc` used to answer 416 while
        // its mirror image `bytes=abc-` answered 200 — the parser had two different
        // policies for the same kind of garbage, one per end. That is worse than
        // either policy alone: a client told 416 concludes its seek is impossible,
        // which is not what happened, and there is no retry that recovers from it.
        // A suffix that merely fails to parse is ignored like everything else; a
        // suffix that parses as zero is still refused, because `suffix-length` is
        // `1*DIGIT` and RFC 9110 §14.1.2 makes a zero-length suffix unsatisfiable.
        for header in ["bytes=-abc", "bytes=-x", "bytes=-1.5", "bytes=- 5", "bytes=-5x"] {
            checkEqual(HTTPRange.resolve(header: header, fileSize: size), .whole(length: 1000),
                       "\"\(header)\" is an unparseable suffix: ignored exactly as an unparseable start is")
        }
        checkEqual(HTTPRange.resolve(header: "bytes=-0", fileSize: size), .unsatisfiable,
                   "a suffix that parses as zero is refused, not ignored — the difference is parseable, not malformed")
        checkEqual(HTTPRange.resolve(header: "bytes=-9999", fileSize: size), .partial(start: 0, length: 1000),
                   "a suffix longer than the file is the whole file, so a parseable suffix still works")

        // An empty file has no byte a range could name, so even `bytes=0-` from the
        // start is unsatisfiable rather than an empty 206.
        checkEqual(HTTPRange.resolve(header: "bytes=0-", fileSize: 0), .unsatisfiable,
                   "there is no byte 0 of a zero-length file")
    })

    Registry.shared.add(suite: suite, TestCase(name: "Content-Range is the inclusive end, and 416 announces the real length",
        knownBug: nil) {
        // `b - a + 1`, so getting it wrong by one is not a merely wrong picture — it
        // desynchronises the client's parser, which then waits for a byte that is
        // never coming.
        checkEqual(HTTPRange.partial(start: 0, length: 500).contentRangeHeader(fileSize: 1000),
                   "bytes 0-499/1000", "the last byte is start + length - 1")
        checkEqual(HTTPRange.partial(start: 999, length: 1).contentRangeHeader(fileSize: 1000),
                   "bytes 999-999/1000", "a single trailing byte is not an off-by-one to zero")
        checkEqual(HTTPRange.partial(start: 500, length: 500).contentRangeHeader(fileSize: 1000),
                   "bytes 500-999/1000", "a mid-file range")
        checkEqual(HTTPRange.unsatisfiable.contentRangeHeader(fileSize: 1000), "bytes */1000",
                   "416 carries the real length, which is how a client learns how long the clip is")
        checkNil(HTTPRange.whole(length: 1000).contentRangeHeader(fileSize: 1000),
                 "a 200 has no Content-Range at all")
    })

    Registry.shared.add(suite: suite, TestCase(name: "206 and 416 have reason phrases that name them",
        knownBug: nil) {
        // Both codes exist only because of the video route. Missing 416 would put
        // `HTTP/1.1 416 Status 416` on the wire — legal, since the phrase is
        // advisory, and exactly the kind of thing that makes a proxy log look like a
        // server in distress.
        checkEqual(HTTPStatus.text(206), "Partial Content", "206")
        checkEqual(HTTPStatus.text(416), "Range Not Satisfiable", "416")
    })

    // MARK: - the median

    Registry.shared.add(suite: suite, TestCase(name: "a clip's score is the median of its frames, so one bad frame cannot decide it",
        knownBug: nil) {
        // A clip begins with a black or blue leader, fades up from black, or has the
        // operator's thumb across the lens. Those frames are *expected*, not
        // unusual, and they are exactly the ones a mean lets decide the answer: with
        // these three, a mean would report 0.367 — a third of the way toward the bad
        // frame — and because the grid sorts on this number, "one clip in a hundred
        // scored terribly" would read as "one clip in a hundred is terrible".
        let frames: [Float] = [0.1, 0.1, 0.9]
        checkEqual(VisionAnalyzer.median(of: frames), 0.1, "two good frames outvote one black leader")
        let mean = frames.reduce(0, +) / Float(frames.count)
        check(mean > 0.36 && mean < 0.37, "which is not the mean (\(mean)) — the whole point of the rule")

        // Order-independent, because the frames are scored concurrently and arrive in
        // whatever order the task group finished them.
        for permuted in [[frames[2], frames[0], frames[1]], [frames[1], frames[2], frames[0]]] {
            checkEqual(VisionAnalyzer.median(of: permuted), 0.1,
                       "the same three frames in the order \(permuted) — the frames arrive concurrently")
        }

        // Even counts are the weak case a short clip produces when its moments clamp
        // together: with two samples there is no majority, so the midpoint is the
        // honest answer — one bad frame *can* move it, and that is documented rather
        // than tuned away.
        checkEqual(VisionAnalyzer.median(of: [0.2, 0.8]), 0.5, "two samples take the midpoint, not either one")
        checkEqual(VisionAnalyzer.median(of: [0.1, 0.1, 0.9, 0.1]), 0.1, "four samples average the middle pair")
        checkEqual(VisionAnalyzer.median(of: [0.5]), 0.5, "a single sample is its own median")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a clip is scored and gets no vector; a still is scored and gets one",
        knownBug: nil) {
        // Both facts are one call, because "no vector for a clip" is a property of
        // what a clip *is*, not of which pass is running. Asserted against real
        // Vision output rather than a stub, because a fixture built from invented
        // numbers would only test itself.
        let analyzer = VisionAnalyzer()
        let image = try TestPattern.verticalBands.draw()

        let single = try await analyzer.analyze(image)
        let (clip, clipVector) = try await analyzer.analyzeFrames([image, image, image])
        checkNil(clipVector, "three frames mean no FeaturePrint: a clip is not one photograph")
        checkEqual(clip.score, single.score,
                   "and three samples of the same frame take the median of that frame, so the score is unchanged")

        let (still, stillVector) = try await analyzer.analyzeFrames([image])
        checkEqual(still.score, single.score, "one frame takes the measured single-image path unchanged")
        checkNotNil(stillVector, "and it does get a FeaturePrint — exactly one frame is the only case where the clip *is* the frame")

        // **Three genuinely different frames**, which is the only way to reach the
        // aggregation rather than just the vector rule. Three copies of one image
        // would give the same answer under a median and under a mean, so the case
        // above cannot tell them apart — this one can, and the frames are the ones
        // whose real Vision scores are read first so the expected median is a
        // measurement rather than a reimplementation of the rule under test.
        let moments = try [TestPattern.checkerboard, TestPattern.radial, TestPattern.verticalBands]
            .map { try $0.draw() }
        var observed: [Float] = []
        for moment in moments { observed.append(try await analyzer.analyze(moment).score) }
        let mean = observed.reduce(0, +) / Float(observed.count)
        check(observed[0] != observed[1] || observed[1] != observed[2],
              "the three frames score differently, so median and mean can be told apart: \(observed)")

        let (sampled, sampledVector) = try await analyzer.analyzeFrames(moments)
        checkNil(sampledVector, "three distinct frames still mean no FeaturePrint")
        let midpoint = VisionAnalyzer.median(of: observed)
        check(abs(sampled.score - midpoint) < 0.0001,
              "the clip takes the median of its frames' real scores \(observed), expected \(midpoint), got \(sampled.score)")
        if abs(mean - midpoint) > 0.01 {
            check(abs(sampled.score - mean) > 0.01,
                  "and specifically not the mean \(mean) — one bad frame must not decide the score")
        } else {
            Harness.record("the three fixture frames score too similarly for median and mean to "
                           + "differ (\(observed)); the case proves less than it claims")
        }

        // **Two frames**, which is the boundary the clip sampler actually produces: a
        // clip shorter than about half a second clamps two of its three moments onto
        // the same position, and `analyzeFrames` takes one frame per distinct moment.
        // So `count > 1` is a real boundary, not an optimisation — with the test at
        // `count > 2`, a two-frame clip would take the single-image path and be given a
        // FeaturePrint, which is precisely the thing this feature exists to prevent.
        let twoFrames = [moments[0], moments[1]]
        let (pair, pairVector) = try await analyzer.analyzeFrames(twoFrames)
        checkNil(pairVector, "two frames are still more than one frame, so still no FeaturePrint")
        let pairMean = (observed[0] + observed[1]) / 2
        let pairMedian = (observed[0] + observed[1]) / 2
        check(abs(pair.score - pairMedian) < 0.0001,
              "two frames take the midpoint of their scores \(observed.prefix(2)), "
              + "expected \(pairMedian), got \(pair.score)")
        if abs(pairMean - observed[2]) > 0.01 {
            check(abs(pair.score - observed[2]) > 0.01,
                  "and specifically not either frame's own score — dropping one arbitrarily is "
                  + "not the documented rule")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "an empty frame list is an error, never a score of zero",
        knownBug: nil) {
        // Unreachable from `framesForAnalysis`, which documents that it never returns
        // an empty array. Guarded anyway, and the guard has to be an error: a
        // `score: 0` for an asset nothing was read from would put a photo at the
        // bottom of the grid that was never looked at, and `0.0` is a real
        // observation, so nothing downstream could tell the two apart.
        let analyzer = VisionAnalyzer()
        var thrown: Error?
        do {
            _ = try await analyzer.analyzeFrames([])
        } catch {
            thrown = error
        }
        checkNotNil(thrown, "an empty frame list throws rather than scoring nothing")
    })

    // MARK: - schema version 5

    Registry.shared.add(suite: suite, TestCase(name: "a version 4 cache gains duration_seconds without losing a single row",
        knownBug: nil) {
        // Version 5 is the one column video support adds, and it is additive like
        // every step before it. A cache written by the previous build has no such
        // column at all, so the fixture rebuilds `assets` at its version 4 shape
        // rather than merely setting `user_version` — a version 4 file with its
        // number edited would already have the column, and the migration would have
        // nothing to do.
        let fixture = try await Fixture.make("video-v4-upgrade")
        try await fixture.seed([
            .init(id: "keep-scored", score: 0.75, date: 100),
            .init(id: "keep-negative", score: -0.9476, date: 200),
            .init(id: "keep-unavailable", score: nil, date: 300, state: .unavailable),
            .init(id: "keep-favourite", score: 0.1, date: 400, favorite: true),
        ])
        try await fixture.cache.upsertAlbum(identifier: "album-1", title: "Trips", collectionType: 1)
        try await fixture.cache.replaceAlbumMembership(albumIdentifier: "album-1",
                                                       identifiers: ["keep-scored", "keep-favourite"])
        try fixture.rewindSchemaToVersion4Assets()
        checkEqual(try await fixture.cache.schemaUserVersion(), 4, "the fixture is rewound to version 4")
        checkEqual(try fixture.rowCount(of: "assets"), 4, "and the rebuild kept every row, so the "
                   + "upgrade is being pointed at real data rather than an empty table")
        checkEqual(try fixture.columnNames(of: "assets").contains("duration_seconds"), false,
                   "and the fixture really is missing the version 5 column")

        let upgraded = try await Fixture.reopen(fixture)
        checkEqual(try await upgraded.cache.schemaUserVersion(), CacheStore.schemaVersion,
                   "the upgrade advances the stamp — a stale version is a bug in its own right")
        check(try upgraded.columnNames(of: "assets").contains("duration_seconds"),
              "and adds the column")

        // Every fact the older cache held survives, because the step is an `ALTER
        // TABLE ADD COLUMN` and nothing else.
        checkEqual(try await upgraded.cache.photo(identifier: "keep-scored")?.score, 0.75, "a score survives")
        checkEqual(try await upgraded.cache.photo(identifier: "keep-negative")?.score, -0.9476,
                   "and is neither clamped nor rescaled into 0…1")
        checkEqual(try await upgraded.cache.photo(identifier: "keep-favourite")?.favorite, true,
                   "favourite flags survive, so protection still applies after the upgrade")
        checkEqual(try await upgraded.analysisState(of: "keep-unavailable"), .unavailable,
                   "a cloud-only asset is still unavailable, not re-queued as pending")
        check((try await upgraded.scoredAt(of: "keep-scored")) ?? 0 > 0, "and its scored_at survives")
        let stats = try await upgraded.cache.stats(maxAge: 0)
        checkEqual(stats.total, 4, "every row survives")
        checkEqual(stats.analyzed, 3, "and so does the analysed count")
        checkEqual(try await upgraded.cache.albums().first?.assetCount, 2,
                   "album membership survives, so the album filter still resolves after an upgrade")

        // `NULL`, not `0`, for every row written before this version. Those rows are
        // stills — which have no duration — or videos this build has not re-scanned
        // yet, and both are "unknown" rather than "zero seconds long". `0` would be a
        // claim about the asset, and a badge reading `0:00` on a nine-minute clip.
        let stored = try upgraded.query(
            "SELECT asset_identifier, duration_seconds FROM assets;") { statement -> [String] in
            var named: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = RawSQL.string(statement, 0) else { continue }
                let type = sqlite3_column_type(statement, 1)
                if type == SQLITE_NULL {
                    named.append(name)
                } else {
                    Harness.record("\(name) was given a duration of \(sqlite3_column_double(statement, 1)) "
                                   + "by a build that had never scanned it")
                }
            }
            return named
        }
        checkEqual(stored.count, 4, "every pre-existing row's duration is still NULL rather than 0")
        for row in try await upgraded.cache.page(filter: PhotoFilter(lower: -1, upper: 1),
                                                  sort: .scoreAscending, cursor: nil,
                                                  limit: 10, offset: 0).rows {
            checkNil(row.duration, "\(row.id) has no duration after the upgrade, so none is served")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "migrating a version 5 cache twice changes nothing",
        knownBug: nil) {
        // Every step is `IF NOT EXISTS` or guarded by a column check, which is what
        // lets the app call `migrate()` unconditionally on launch. `addColumnIfMissing`
        // is the guard for the one step that alters a table.
        let fixture = try await Fixture.make("video-v5-idempotent")
        try await fixture.seed([
            .init(id: "still", score: 0.5, date: 100),
            .init(id: "clip", score: 0.4, date: 90, mediaType: 2, duration: 42.5),
        ])
        let columns = try fixture.columnNames(of: "assets").count
        let before = try await fixture.cache.stats(maxAge: 0)

        try await fixture.cache.migrate()
        try await fixture.cache.migrate()

        checkEqual(try await fixture.cache.schemaUserVersion(), CacheStore.schemaVersion,
                   "the stamp is still current")
        checkEqual(try fixture.columnNames(of: "assets").count, columns,
                   "and the column count is unchanged, so no step added one twice")
        checkEqual(try await fixture.cache.stats(maxAge: 0).total, before.total, "row count survives")
        checkEqual(try await fixture.cache.photo(identifier: "clip")?.duration, 42.5,
                   "and a recorded clip duration is not nulled by a re-migration")
    })

    // MARK: - clips score, clips never group

    Registry.shared.add(suite: suite, TestCase(name: "a clip is claimed for scoring and counted as a video",
        knownBug: nil) {
        let fixture = try await Fixture.make("video-claim")
        try await fixture.seed([
            .init(id: "pending-clip", score: nil, date: 100, state: .pending,
                  mediaType: 2, duration: 12),
            .init(id: "pending-still", score: nil, date: 90, state: .pending),
        ])
        // Read the pending set per media type *before* the claim, because claiming
        // is the state change: afterwards nothing is pending at all, and both reads
        // would answer "no work" for the uninteresting reason that the work is taken.
        checkEqual(try fixture.pendingIdentifiers(mediaType: 1), ["pending-still"],
                   "the photos-only predicate — what `MediaSelection.images` writes — "
                   + "sees only the photograph")
        checkEqual(try fixture.pendingIdentifiers(mediaType: 2), ["pending-clip"],
                   "and the videos predicate sees the clip, which is the half the claim needs")

        checkEqual(try await fixture.cache.claimJobs(limit: 10).map(\.identifier),
                   ["pending-clip", "pending-still"],
                   "so a clip is claimed for scoring like any other asset, newest first")
        checkEqual(try await fixture.analysisState(of: "pending-clip"), .analyzing,
                   "and it is genuinely claimed, not merely offered")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a scored clip is never queued for a FeaturePrint",
        knownBug: nil) {
        // Videos score, browse, play, favourite and delete; they never group. A
        // FeaturePrint taken from one arbitrary frame of a clip claims something
        // stronger and untrue — that the clip *is* that photograph — and the
        // `maxDistance` threshold was calibrated on stills, so admitting clip frames
        // would silently change what a distance means for every group already stored.
        // `analyzeFrames` returning no vector is the braces; this is the belt.
        let fixture = try await Fixture.make("video-queue")
        try await fixture.seed([
            .init(id: "scored-still", score: 0.5, date: 100),
            .init(id: "scored-clip", score: 0.5, date: 90, mediaType: 2, duration: 30),
        ])
        try await fixture.cache.beginScan()
        checkEqual(try await fixture.cache.claimFeaturePrints(limit: 10), ["scored-still"],
                   "only the photograph is queued for backfill")

        // A second scan must not discover the clip either: the exclusion is in the
        // query, not in whatever happened to be claimed the first time. The still is
        // still queued — the claim only removed the row, and it has no vector yet —
        // so the photograph is claimed again and the clip never appears at all.
        try await fixture.cache.beginScan()
        let again = try await fixture.cache.claimFeaturePrints(limit: 10)
        check(!again.contains("scored-clip"),
              "a later scan does not offer the clip for a FeaturePrint, got \(again)")
        checkEqual(again, ["scored-still"], "while the photograph with no vector is re-offered, as it always is")

        // `videos` is its own number rather than `total - analysed`, so a caller can
        // say which of the library's assets are clips without inferring it. Two
        // photographs and one clip, so a count that picked the wrong column would
        // report 2 rather than the right answer's lucky equal.
        let counted = try await Fixture.make("video-stats")
        try await counted.seed([
            .init(id: "s-1", score: 0.5, date: 100),
            .init(id: "s-2", score: 0.4, date: 90),
            .init(id: "v-1", score: 0.3, date: 80, mediaType: 2, duration: 30),
        ])
        let stats = try await counted.cache.stats(maxAge: 0)
        checkEqual(stats.videos, 1, "the one clip is counted as a video")
        checkEqual(stats.total, 3, "and total is unchanged by video support: all scanned assets")
        checkEqual(stats.analyzed, 3, "all three are still analysed")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a rescan reports what Photos says now, and keeps a still's duration absent",
        knownBug: nil) {
        // The `ON CONFLICT` arms are split in two on purpose: the guarded `CASE` arms
        // preserve an observation that is still valid (a score, a timestamp), while
        // the unconditional ones overwrite a *fact Photos reported right now*. A
        // duration belongs to the second kind — Photos is the only source for it, and
        // a stale copy is worse than none.
        //
        // The scan-through is done the way the walk does it, by handing `ScanRecord`s
        // to `upsert` rather than by writing SQL, so a fixture cannot produce a state
        // the application itself could not.
        let fixture = try await Fixture.make("video-rescan")
        try await fixture.seed([
            .init(id: "clip", score: 0.5, date: 100, mediaType: 2, duration: 30),
            .init(id: "still", score: 0.5, date: 100, favorite: true),
        ])
        try await fixture.cache.upsert(batch: [
            ScanRecord(identifier: "clip", mediaType: 2, creationDate: 100, modificationDate: 100,
                       width: 1080, height: 1920, favorite: false, mediaSubtype: 0,
                       isScreenshot: false, duration: 125.75),
            ScanRecord(identifier: "still", mediaType: 1, creationDate: 100, modificationDate: 100,
                       width: 4032, height: 3024, favorite: true, mediaSubtype: 0,
                       isScreenshot: false),
        ], marker: 2)
        checkEqual(try await fixture.cache.photo(identifier: "clip")?.duration, 125.75,
                   "a rescan that reports a new duration replaces the old one")

        // And the still keeps none. A rescan reporting `nil` must not write a 0 —
        // that is the badge reading `0:00` on a photograph, and `0` is a claim about
        // the asset that nothing observed.
        checkNil(try await fixture.cache.photo(identifier: "still")?.duration,
                 "a still carries no duration after a rescan either")
        checkEqual(try await fixture.cache.photo(identifier: "still")?.favorite, true,
                   "and the favourite flag survives a rescan, so protection still applies")

        // The score is a measurement and the modification date did not move, so it is
        // preserved rather than nulled: a re-scan must not drop a good photograph out
        // of the grid while nothing is being re-analysed.
        checkEqual(try await fixture.cache.photo(identifier: "clip")?.score, 0.5,
                   "an unchanged asset keeps its score across a rescan")
        checkEqual(try await fixture.cache.photo(identifier: "clip")?.mediaType, 2,
                   "and its media type is restated, not left to the old row")
    })

    // MARK: - wire shape

    Registry.shared.add(suite: suite, TestCase(name: "a clip row says what it is and how long it is; a still says neither",
        knownBug: nil) {
        // The load-bearing half of this is the *absence*: this codebase's rule is
        // that an optional field is omitted rather than sent as `null`, so a client
        // can treat an absent key and an explicit `null` identically. A `duration`
        // of `0` would be worse than either — it reads as a claim about the asset.
        let fixture = try await Fixture.make("video-wire")
        try await fixture.seed([
            .init(id: "clip", score: 0.42, date: 1000, mediaType: 2, duration: 42.5),
            .init(id: "still", score: 0.5, date: 1000),
        ])

        let clip = await fixture.router.reply(Req.get("/api/photo/clip"))
        checkEqual(clip.status, 200, "the clip is served")
        let clipRow = clip.json["photo"] as? [String: Any] ?? [:]
        checkEqual(clipRow.keys.sorted(),
                   ["date", "duration", "favorite", "height", "id", "mediaType", "score", "width"],
                   "a clip's row carries its duration and nothing else new")
        checkEqual(clipRow["mediaType"] as? Int, 2, "mediaType is 2 for a clip, never inferred from the duration")
        checkEqual((clipRow["duration"] as? NSNumber)?.doubleValue, 42.5, "and the duration is a number")
        check(!clipRow.values.contains { $0 is NSNull }, "a clip row sends no explicit nulls")

        let still = await fixture.router.reply(Req.get("/api/photo/still"))
        let stillRow = still.json["photo"] as? [String: Any] ?? [:]
        checkEqual(stillRow.keys.sorted(), ["date", "favorite", "height", "id", "mediaType", "score", "width"],
                   "a still has the same key set as it always had: no duration key at all")
        check(!stillRow.keys.contains("duration"), "not an absent-looking zero either")
        check(!stillRow.values.contains { $0 is NSNull }, "and nothing in the object is an explicit null")
        checkEqual(stillRow["mediaType"] as? Int, 1, "while still saying what it is")
    })
}