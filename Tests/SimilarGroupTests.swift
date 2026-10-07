import Foundation
import SQLite3
import Vision

// Similar Groups: the builder, the aggregator, the ranker, the cache, and the
// routes — all against the production implementations, which `run-tests.sh`
// compiles into this same binary.
//
// The FeaturePrint tests need real observations, because a fake one would be
// testing the fake: `FeaturePrintObservation` has no public initialiser from
// synthetic data, so these generate prints from images the test draws itself.
// That is cheap (a few ms per request) and keeps every distance assertion
// grounded in Apple's actual model.

func registerSimilarGroupTests() {
    // Runs first and on its own: every grouping case below depends on the fixture
    // still separating "one shot" from "a different shot", and this is what proves
    // it does. Without it, a case asserting "these stay apart" would also pass if
    // the builder compared nothing at all.
    Registry.shared.add(suite: "group building", TestCase(name: "the test fixture separates one shot from another", knownBug: nil) {
        await checkFixtureSeparation()
    })

    Registry.shared.add(suite: "similar group settings", TestCase(name: "defaults are the measured values", knownBug: nil) {
        let defaults = SimilarGroupSettings.default
        // These numbers came from measuring real bursts on a 53k library; see
        // `SimilarGroupSettings`. Asserted so a well-meaning "tidy up" of the
        // defaults cannot silently change what grouping does.
        checkEqual(defaults.windowSeconds, 120, "default capture-time window")
        checkEqual(defaults.maxDistance, 0.35, "default FeaturePrint distance")
        checkEqual(defaults.faceWeight, 0.5, "default face weight")
    })

    Registry.shared.add(suite: "similar group settings", TestCase(name: "out-of-range values are clamped", knownBug: nil) {
        var hostile = SimilarGroupSettings.default
        hostile.windowSeconds = -5
        hostile.maxDistance = 99
        hostile.faceWeight = 12
        hostile.minimumFaceAreaFraction = -1
        hostile.maximumGroupSize = 100_000
        let clamped = hostile.validated()
        check(clamped.windowSeconds >= 1, "a negative window is clamped up, got \(clamped.windowSeconds)")
        check(clamped.maxDistance <= 2.0, "an absurd distance is clamped, got \(clamped.maxDistance)")
        checkEqual(clamped.faceWeight, 1.0, "a face weight above 1 is clamped")
        check(clamped.minimumFaceAreaFraction >= 0, "a negative area floor is clamped")
        check(clamped.maximumGroupSize <= 500, "an unbounded group size is clamped")
    })

    Registry.shared.add(suite: "feature print storage", TestCase(name: "a FeaturePrint survives compression and decoding", knownBug: nil) {
        let left = try await makeFeaturePrint(.verticalBands)
        let right = try await makeFeaturePrint(.verticalBandsShifted)
        guard let payload = SignalCompression.featurePrintData(left),
              let compressed = SignalCompression.compress(payload) else {
            Harness.record("could not encode or compress a FeaturePrint")
            return
        }
        check(compressed.count < payload.count,
              "zlib should shrink a FeaturePrint: \(compressed.count) vs \(payload.count)")
        guard let restored = SignalCompression.featurePrint(from: compressed) else {
            Harness.record("could not decode the compressed FeaturePrint")
            return
        }
        let original = try left.distance(to: right)
        let roundTripped = try restored.distance(to: right)
        checkEqual(roundTripped, original, "distance must survive the storage round trip exactly")
    })

    Registry.shared.add(suite: "feature print storage", TestCase(name: "an uncompressed payload still decodes", knownBug: nil) {
        // A blob written before compression existed has no marker byte. Decoding
        // must fall back to reading it as-is rather than trying to inflate it.
        let observation = try await makeFeaturePrint(.verticalBandsShifted)
        guard let plain = SignalCompression.featurePrintData(observation) else {
            Harness.record("could not encode a FeaturePrint")
            return
        }
        let restored = SignalCompression.featurePrint(from: plain)
        checkNotNil(restored, "an unmarked payload should decode as plain JSON")
    })

    Registry.shared.add(suite: "feature print storage", TestCase(name: "corrupt bytes decode to nil rather than garbage", knownBug: nil) {
        let corrupt = Data([0x01, 0xFF, 0x00, 0x13, 0x37])
        checkNil(SignalCompression.featurePrint(from: corrupt), "corrupt bytes must not yield an observation")
        checkNil(SignalCompression.decompress(corrupt), "corrupt bytes must not yield data")
    })

    Registry.shared.add(suite: "face capture aggregation", TestCase(name: "a group of faces is judged on its worst member", knownBug: nil) {
        // The case the design turns on: A rates .68 and B .82 as means, so a mean
        // calls A merely worse — but in A one person was captured badly (.24) and
        // in B everyone was captured evenly.
        let a = [FaceCapture(score: 0.91, areaFraction: 0.10),
                 FaceCapture(score: 0.88, areaFraction: 0.09),
                 FaceCapture(score: 0.24, areaFraction: 0.08)]
        let b = [FaceCapture(score: 0.85, areaFraction: 0.10),
                 FaceCapture(score: 0.82, areaFraction: 0.09),
                 FaceCapture(score: 0.80, areaFraction: 0.08)]
        let config = SimilarGroupSettings.default
        let aggregateA = FaceCaptureAggregator.aggregate(a, minimumAreaFraction: config.minimumFaceAreaFraction)
        let aggregateB = FaceCaptureAggregator.aggregate(b, minimumAreaFraction: config.minimumFaceAreaFraction)
        // Rounded to two places: these are `Float`s, so 0.24 is stored as
        // 0.23999999463558197 and comparing against the decimal literal would fail
        // for a reason that has nothing to do with the aggregation.
        // Rounded as `Double`, before widening: these are `Float`s, so `Float(0.24)`
        // is 0.23999999463558197 and widening it would fail for a reason that has
        // nothing to do with the aggregation.
        checkEqual(aggregateA.map { Double($0).rounded(toPlaces: 2) }, 0.24, "A's aggregate is its worst face")
        checkEqual(aggregateB.map { Double($0).rounded(toPlaces: 2) }, 0.80, "B's aggregate is its worst face")
        check((aggregateB ?? 0) > (aggregateA ?? 0), "B should rank above A on capture quality")
    })

    Registry.shared.add(suite: "face capture aggregation", TestCase(name: "an incidental background face is ignored", knownBug: nil) {
        // Measured face areas run 0.0017…0.90 of the frame, so a face in the
        // background of a landscape must not drag the subject's score down.
        let config = SimilarGroupSettings.default
        let faces = [FaceCapture(score: 0.10, areaFraction: 0.0017),
                     FaceCapture(score: 0.80, areaFraction: 0.20)]
        checkEqual(FaceCaptureAggregator.aggregate(faces, minimumAreaFraction: config.minimumFaceAreaFraction),
                   0.80, "only the significant face counts")
    })

    Registry.shared.add(suite: "face capture aggregation", TestCase(name: "no faces yields nil, not zero", knownBug: nil) {
        let config = SimilarGroupSettings.default
        checkNil(FaceCaptureAggregator.aggregate([], minimumAreaFraction: config.minimumFaceAreaFraction),
                 "an image with no faces has no aggregate")
        checkNil(FaceCaptureAggregator.aggregate([FaceCapture(score: 0.9, areaFraction: 0.0001)],
                                                 minimumAreaFraction: config.minimumFaceAreaFraction),
                 "only insignificant faces is the same as none")
    })

    Registry.shared.add(suite: "best shot ranking", TestCase(name: "a group with no faces ranks on aesthetics alone", knownBug: nil) {
        let members = [
            RankingInput(identifier: "a", aesthetics: 0.5, faces: [], date: 1, favorite: false),
            RankingInput(identifier: "b", aesthetics: 0.9, faces: [], date: 2, favorite: false),
            RankingInput(identifier: "c", aesthetics: 0.1, faces: [], date: 3, favorite: false),
        ]
        let ranked = BestShotRanker.rank(members, settings: .default)
        checkEqual(ranked.map(\.identifier), ["b", "a", "c"], "no faces means pure aesthetics order")
    })

    Registry.shared.add(suite: "best shot ranking", TestCase(name: "face quality can overturn an aesthetics favourite", knownBug: nil) {
        // The measured disagreement: photo C has the better aesthetics score, but
        // the face was captured badly in C and well in A.
        let members = [
            RankingInput(identifier: "a", aesthetics: 0.81,
                         faces: [FaceCapture(score: 0.85, areaFraction: 0.1)],
                         date: 1, favorite: false),
            RankingInput(identifier: "c", aesthetics: 0.85,
                         faces: [FaceCapture(score: 0.20, areaFraction: 0.1)],
                         date: 2, favorite: false),
        ]
        var config = SimilarGroupSettings.default
        config.faceWeight = 1.0   // face quality alone
        let ranked = BestShotRanker.rank(members, settings: config)
        checkEqual(ranked.map(\.identifier), ["a", "c"],
                   "at weight 1 the face signal decides, and it prefers a")
        config.faceWeight = 0.0   // aesthetics alone
        checkEqual(BestShotRanker.rank(members, settings: config).map(\.identifier), ["c", "a"],
                   "at weight 0 the aesthetics score decides, and it prefers c")
    })

    Registry.shared.add(suite: "best shot ranking", TestCase(name: "the two weights bracket the disagreement", knownBug: nil) {
        let members = [
            RankingInput(identifier: "a", aesthetics: 0.81,
                         faces: [FaceCapture(score: 0.85, areaFraction: 0.1)], date: 1, favorite: false),
            RankingInput(identifier: "c", aesthetics: 0.85,
                         faces: [FaceCapture(score: 0.20, areaFraction: 0.1)], date: 2, favorite: false),
        ]
        // With ranks rather than raw values, an even blend of "c wins one signal,
        // a wins the other" is a tie — and must be reported as a tie, in a stable
        // order, rather than silently resolved by whichever signal was applied last.
        let ranked = BestShotRanker.rank(members, settings: .default)
        checkEqual(ranked.count, 2, "both members are ranked")
        checkEqual(ranked[0].bestShot, ranked[1].bestShot, "an even blend of opposite signals ties")
        checkEqual(ranked.map(\.identifier), ["a", "c"], "a tie breaks on identifier, deterministically")
    })

    Registry.shared.add(suite: "best shot ranking", TestCase(name: "a photo without a face is ranked, not dropped", knownBug: nil) {
        // A mixed group: one landscape among portraits must still appear, and must
        // not be sorted last for the crime of having no face signal.
        let members = [
            RankingInput(identifier: "portrait", aesthetics: 0.10,
                         faces: [FaceCapture(score: 0.90, areaFraction: 0.2)], date: 1, favorite: false),
            RankingInput(identifier: "landscape", aesthetics: 0.90,
                         faces: [], date: 2, favorite: false),
        ]
        let ranked = BestShotRanker.rank(members, settings: .default)
        checkEqual(ranked.count, 2, "both members are ranked")
        checkEqual(ranked.map(\.identifier), ["landscape", "portrait"],
                   "the faceless photo ranks on its aesthetics score alone")
    })

    Registry.shared.add(suite: "best shot ranking", TestCase(name: "equal scores tie and never reorder between runs", knownBug: nil) {
        let members = (0..<6).map {
            RankingInput(identifier: "id\($0)", aesthetics: 0.5, faces: [], date: Double($0),
                         favorite: false)
        }
        let first = BestShotRanker.rank(members, settings: .default).map(\.identifier)
        let second = BestShotRanker.rank(members.reversed(), settings: .default).map(\.identifier)
        checkEqual(second, first, "input order must not change the tie-break order")
        check(Set(first).count == 6, "every member appears exactly once")
    })

    Registry.shared.add(suite: "similar group cache", TestCase(name: "groups are stored, read back and replaced wholesale", knownBug: nil) {
        let fixture = try await Fixture.make("groups")
        try await fixture.cache.upsert(batch: [
            ScanRecord(identifier: "a1", mediaType: 1, creationDate: 100, modificationDate: 100,
                       width: 10, height: 10, favorite: false, mediaSubtype: 0, isScreenshot: false),
            ScanRecord(identifier: "a2", mediaType: 1, creationDate: 101, modificationDate: 101,
                       width: 10, height: 10, favorite: false, mediaSubtype: 0, isScreenshot: false),
            ScanRecord(identifier: "b1", mediaType: 1, creationDate: 9_000, modificationDate: 9_000,
                       width: 10, height: 10, favorite: false, mediaSubtype: 0, isScreenshot: false),
            // b2 must exist: `similar_group_members` has a foreign key onto `assets`,
            // so a group naming an unknown asset is refused rather than stored. That
            // is the correct behaviour — a group can never contain a photo the
            // cache has never seen.
            ScanRecord(identifier: "b2", mediaType: 1, creationDate: 9_001, modificationDate: 9_001,
                       width: 10, height: 10, favorite: false, mediaSubtype: 0, isScreenshot: false),
        ], marker: 1)
        let groups = [
            SimilarGroup(id: "a1", members: ["a1", "a2"]),
            SimilarGroup(id: "b1", members: ["b1", "b2"]),
        ]
        try await fixture.cache.replaceGroups(groups, settings: .default,
                                              faceMemberCounts: ["a1": 1],
                                              earliestDates: ["a1": 100, "b1": nil])

        let page = try await fixture.cache.groupSummaries(limit: 10, offset: 0)
        checkEqual(page.total, 2, "two groups stored")
        checkSetEqual(page.groups.map(\.id), ["a1", "b1"], "both groups are listed")
        // Largest first, which is the order the browser wants.
        checkEqual(page.groups.first?.memberCount, 2, "the first group is the larger one")

        let summary = try await fixture.cache.groupSummary(id: "a1")
        checkEqual(summary?.faceMemberCount, 1, "the face member count is stored")
        checkEqual(summary?.earliestDate, 100, "the earliest date is stored")
        // A group is stored unranked: `ranked_at` stays nil until every member has
        // been through face capture analysis, and that is what `incomplete` reports
        // so a half-analysed portrait group is not presented as settled.
        checkNil(summary?.rankedAt, "a freshly built group is not marked as ranked")
        try await fixture.cache.markGroupRanked(id: "a1")
        checkNotNil(try await fixture.cache.groupSummary(id: "a1")?.rankedAt,
                    "ranking a group records when it settled")

        // Replacement, not merge: a rebuild that no longer finds the second group
        // must not leave it behind, or it would keep being served forever.
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2"])],
                                              settings: .default, faceMemberCounts: [:], earliestDates: [:])
        let after = try await fixture.cache.groupSummaries(limit: 10, offset: 0)
        checkEqual(after.total, 1, "a rebuild replaces, it does not merge")
        checkNil(try await fixture.cache.groupSummary(id: "b1"), "the dropped group is gone")
    })

    Registry.shared.add(suite: "similar group cache", TestCase(name: "deleting a photo removes its group membership", knownBug: nil) {
        let fixture = try await Fixture.make("groups-delete")
        try await fixture.cache.upsert(batch: [
            ScanRecord(identifier: "a1", mediaType: 1, creationDate: 100, modificationDate: 100,
                       width: 10, height: 10, favorite: false, mediaSubtype: 0, isScreenshot: false),
            ScanRecord(identifier: "a2", mediaType: 1, creationDate: 101, modificationDate: 101,
                       width: 10, height: 10, favorite: false, mediaSubtype: 0, isScreenshot: false),
        ], marker: 1)
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2"])],
                                              settings: .default, faceMemberCounts: [:], earliestDates: [:])
        try await fixture.cache.remove(identifiers: ["a2"])
        let orphans = try fixture.query(
            "SELECT COUNT(*) FROM similar_group_members WHERE asset_identifier = 'a2';") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return Int(sqlite3_column_int(statement, 0))
        }
        checkEqual(orphans, 0, "the foreign key takes the membership row with the asset")
    })

    Registry.shared.add(suite: "similar group cache", TestCase(name: "a cached FeaturePrint is readable as a grouping candidate", knownBug: nil) {
        let fixture = try await Fixture.make("groups-featureprint")
        try await fixture.cache.upsert(batch: [
            ScanRecord(identifier: "a1", mediaType: 1, creationDate: 100, modificationDate: 100,
                       width: 10, height: 10, favorite: false, mediaSubtype: 0, isScreenshot: false),
            ScanRecord(identifier: "a2", mediaType: 1, creationDate: 101, modificationDate: 101,
                       width: 10, height: 10, favorite: false, mediaSubtype: 0, isScreenshot: false),
        ], marker: 1)
        let observation = try await makeFeaturePrint(.verticalBands)
        let payload = SignalCompression.featurePrintData(observation)!
        try await fixture.cache.recordFeaturePrint(payload, for: "a1")

        let candidates = try await fixture.cache.featurePrints()
        checkEqual(candidates.count, 1, "only the asset with a FeaturePrint is returned")
        checkEqual(candidates.first?.identifier, "a1", "the right asset came back")
        checkEqual(candidates.first?.date, 100, "its capture date came back")
        // The payload round-tripped through SQLite and came out still comparable.
        checkNotNil(candidates.first?.featurePrint, "the stored FeaturePrint decodes")

        let counts = try await fixture.cache.signalCounts()
        checkEqual(counts.featurePrints, 1, "the signal count reflects the stored FeaturePrint")
        checkEqual(counts.faceCaptureQualities, 0, "no face results have been stored")
    })

    Registry.shared.add(suite: "similar group cache", TestCase(name: "an asset with no capture date is not a grouping candidate", knownBug: nil) {
        let fixture = try await Fixture.make("groups-nodate")
        try await fixture.cache.upsert(batch: [
            ScanRecord(identifier: "a1", mediaType: 1, creationDate: nil, modificationDate: nil,
                       width: 10, height: 10, favorite: false, mediaSubtype: 0, isScreenshot: false),
        ], marker: 1)
        try await fixture.cache.recordFeaturePrint(SignalCompression.featurePrintData(try await makeFeaturePrint(.verticalBands))!, for: "a1")
        checkEqual(try await fixture.cache.featurePrints().count, 0,
                   "a photo with no capture time has no neighbourhood to be grouped in")
    })

    Registry.shared.add(suite: "similar group cache", TestCase(name: "face quality is stored per asset and reported as absent when missing", knownBug: nil) {
        let fixture = try await Fixture.make("groups-faces")
        try await fixture.cache.upsert(batch: [
            ScanRecord(identifier: "a1", mediaType: 1, creationDate: 100, modificationDate: 100,
                       width: 10, height: 10, favorite: false, mediaSubtype: 0, isScreenshot: false),
            ScanRecord(identifier: "a2", mediaType: 1, creationDate: 101, modificationDate: 101,
                       width: 10, height: 10, favorite: false, mediaSubtype: 0, isScreenshot: false),
        ], marker: 1)
        try await fixture.cache.recordFaceCaptureQuality(
            SignalCompression.faceCaptureResultData(FaceCaptureResult(
                faces: [FaceCapture(score: 0.42, areaFraction: 0.2)]))!, for: "a1")

        let stored = try await fixture.cache.faceCaptureQualities(for: ["a1", "a2"])
        checkEqual(stored["a1"]?.first?.score, 0.42, "the stored face quality comes back verbatim")
        // Absence is meaningful: it is how the engine tells "analysed, no faces"
        // from "not analysed yet".
        checkNil(stored["a2"], "an un-analysed asset is absent, not empty")
    })

    Registry.shared.add(suite: "similar group cache", TestCase(name: "the face queue is the grouped members only, never the library", knownBug: nil) {
        let fixture = try await Fixture.make("groups-facequeue")
        var records: [ScanRecord] = []
        for index in 0..<5 {
            records.append(ScanRecord(identifier: "g\(index)", mediaType: 1, creationDate: Double(index),
                                      modificationDate: Double(index), width: 10, height: 10,
                                      favorite: false, mediaSubtype: 0, isScreenshot: false))
            records.append(ScanRecord(identifier: "solo\(index)", mediaType: 1, creationDate: Double(index),
                                      modificationDate: Double(index), width: 10, height: 10,
                                      favorite: false, mediaSubtype: 0, isScreenshot: false))
        }
        try await fixture.cache.upsert(batch: records, marker: 1)
        try await fixture.cache.replaceGroups(
            [SimilarGroup(id: "g0", members: ["g0", "g1"])],
            settings: .default, faceMemberCounts: [:], earliestDates: [:])

        let pending = try await fixture.cache.groupMembersNeedingFaces(limit: 100)
        checkSetEqual(pending, ["g0", "g1"],
                      "only group members are queued for face analysis, never the whole library")

        // Once one is analysed it leaves the queue; the other stays.
        try await fixture.cache.recordFaceCaptureQuality(
            SignalCompression.faceCaptureResultData(FaceCaptureResult(
                faces: [FaceCapture(score: 0.5, areaFraction: 0.2)]))!, for: "g0")
        checkSetEqual(try await fixture.cache.groupMembersNeedingFaces(limit: 100), ["g1"],
                      "an analysed member leaves the queue")
    })

    Registry.shared.add(suite: "group building", TestCase(name: "genuine alternate captures form one group", knownBug: nil) {
        // Frames of one burst: measured 0.0345 apart, inside the threshold.
        var candidates: [GroupingCandidate] = []
        for index in 0..<5 {
            let observation = try await makeFeaturePrint(index % 2 == 0
                                                          ? .verticalBands
                                                          : .verticalBandsShifted)
            candidates.append(GroupingCandidate(identifier: "burst\(index)",
                                                date: 1_000 + Double(index) * 0.4,
                                                featurePrint: observation))
        }
        let groups = SimilarGroupBuilder.build(candidates: candidates, settings: .default)
        checkEqual(groups.count, 1, "five near-identical frames are one group")
        checkEqual(groups.first?.members.count, 5, "all five are in it")
        checkEqual(groups.first?.id, "burst0", "the group id is its smallest member")
    })

    Registry.shared.add(suite: "group building", TestCase(name: "visually different photos stay apart", knownBug: nil) {
        // Four structurally distinct images: measured 0.67…0.99 apart, all well
        // outside the 0.35 threshold.
        let patterns: [TestPattern] = [.verticalBands, .checkerboard, .diagonal, .radial]
        var candidates: [GroupingCandidate] = []
        for (index, pattern) in patterns.enumerated() {
            candidates.append(GroupingCandidate(identifier: "different\(index)",
                                                date: 2_000 + Double(index) * 0.4,
                                                featurePrint: try await makeFeaturePrint(pattern)))
        }
        let groups = SimilarGroupBuilder.build(candidates: candidates, settings: .default)
        checkEqual(groups.count, 0, "four clearly different photos form no group")
    })

    Registry.shared.add(suite: "group building", TestCase(name: "capture time keeps similar photos days apart out of the same group", knownBug: nil) {
        // Two photos that look alike but were taken a week apart are not alternate
        // captures of one shot. FeaturePrint distance alone would merge them.
        let near = try await makeFeaturePrint(.verticalBands)
        let far = try await makeFeaturePrint(.verticalBandsShifted)
        let distance = try near.distance(to: far)
        check(distance <= Double(SimilarGroupSettings.default.maxDistance),
              "these two really are similar (distance \(distance)), so only time separates them")

        let candidates = [
            GroupingCandidate(identifier: "monday", date: 1_000, featurePrint: near),
            GroupingCandidate(identifier: "nextweek", date: 1_000 + 7 * 86_400, featurePrint: far),
        ]
        checkEqual(SimilarGroupBuilder.build(candidates: candidates, settings: .default).count, 0,
                   "a week apart is not the same shot")
    })

    Registry.shared.add(suite: "group building", TestCase(name: "the time window bounds how far grouping reaches", knownBug: nil) {
        let observation = try await makeFeaturePrint(.verticalBands)
        let candidates = [
            GroupingCandidate(identifier: "close", date: 1_000, featurePrint: observation),
            GroupingCandidate(identifier: "far", date: 1_000 + 600, featurePrint: observation),
        ]
        var tight = SimilarGroupSettings.default
        tight.windowSeconds = 60
        checkEqual(SimilarGroupBuilder.build(candidates: candidates, settings: tight).count, 0,
                   "a 60 s window does not reach 600 s away")
        var wide = SimilarGroupSettings.default
        wide.windowSeconds = 900
        checkEqual(SimilarGroupBuilder.build(candidates: candidates, settings: wide).count, 1,
                   "a 900 s window does")
    })

    Registry.shared.add(suite: "group building", TestCase(name: "a single photo is never a group", knownBug: nil) {
        let lone = GroupingCandidate(identifier: "only",
                                     date: 1_000,
                                     featurePrint: try await makeFeaturePrint(.verticalBandsShifted))
        checkEqual(SimilarGroupBuilder.build(candidates: [lone], settings: .default).count, 0,
                   "one photo is not a group — there is nothing to choose between")
        checkEqual(SimilarGroupBuilder.build(candidates: [], settings: .default).count, 0,
                   "no candidates is not a group either")
    })

    Registry.shared.add(suite: "group building", TestCase(name: "candidates without a FeaturePrint or a date are skipped", knownBug: nil) {
        let observation = try await makeFeaturePrint(.verticalBands)
        let candidates = [
            GroupingCandidate(identifier: "dated", date: 1_000, featurePrint: observation),
            GroupingCandidate(identifier: "undated", date: nil, featurePrint: observation),
            GroupingCandidate(identifier: "unprinted", date: 1_000, featurePrint: nil),
        ]
        let groups = SimilarGroupBuilder.build(candidates: candidates, settings: .default)
        checkEqual(groups.count, 0, "one usable candidate cannot make a group")
    })

    Registry.shared.add(suite: "group building", TestCase(name: "single linkage chains a burst together", knownBug: nil) {
        // Consecutive frames are close; the first and last of a burst are further
        // apart. Single linkage is what keeps such a burst in one group, and this
        // asserts that behaviour rather than assuming it.
        let first = try await makeFeaturePrint(.verticalBands)
        let middle = try await makeFeaturePrint(.verticalBandsShifted)
        let last = try await makeFeaturePrint(.checkerboardCoarse)
        let endpoints = try first.distance(to: last)
        let adjacent = try first.distance(to: middle)
        check(adjacent <= Double(SimilarGroupSettings.default.maxDistance),
              "consecutive frames are within the threshold (distance \(adjacent))")

        let candidates = [
            GroupingCandidate(identifier: "f0", date: 1_000, featurePrint: first),
            GroupingCandidate(identifier: "f1", date: 1_000.5, featurePrint: middle),
            GroupingCandidate(identifier: "f2", date: 1_001, featurePrint: last),
        ]
        let groups = SimilarGroupBuilder.build(candidates: candidates, settings: .default)
        if endpoints > Double(SimilarGroupSettings.default.maxDistance) {
            checkEqual(groups.count, 1,
                       "the burst is one group even though the endpoints (\(endpoints)) are further apart")
        } else {
            checkEqual(groups.count, 1, "the burst is one group")
        }
    })

    Registry.shared.add(suite: "group building", TestCase(name: "an oversized group is split in chronological order", knownBug: nil) {
        // The 120 s window is a weak restriction in practice: one window on this
        // library held 1,499 photos. Without a bound, a whole event would arrive as
        // one unusable group.
        let members = (0..<25).map { "shot\($0)" }
        let dates = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($0.element, 1_000 + Double($0.offset)) })
        let big = SimilarGroup(id: "shot0", members: members)
        let chunks = SimilarGroupBuilder.split(big, maximumSize: 10, dates: dates)
        checkEqual(chunks.count, 3, "25 members at a maximum of 10 become three groups")
        check(chunks.allSatisfy { $0.members.count <= 10 }, "no chunk exceeds the bound")
        checkEqual(chunks.flatMap { $0.members }.sorted(), members.sorted(),
                   "no member is lost or duplicated by the split")
        // Contiguous in capture order, so each chunk is still a run of neighbours.
        checkEqual(chunks[0].members, Array(members[0..<10]), "the first chunk is the earliest run")
    })

    Registry.shared.add(suite: "group building", TestCase(name: "a group within the size bound is not split", knownBug: nil) {
        let members = ["a", "b", "c"]
        let dates = ["a": 1.0, "b": 2.0, "c": 3.0]
        let chunks = SimilarGroupBuilder.split(SimilarGroup(id: "a", members: members),
                                              maximumSize: 10, dates: dates)
        checkEqual(chunks.count, 1, "a small group passes through untouched")
        checkEqual(chunks.first?.members, members, "with its membership intact")
    })

    Registry.shared.add(suite: "similar group cache", TestCase(name: "an asset scored by an earlier build is queued for a FeaturePrint", knownBug: nil) {
        let fixture = try await Fixture.make("groups-backfill")
        try await fixture.seed([Fixture.Seed(id: "a1", score: 0.5, date: 100)])

        // `beginScan` is what populates the queue, and it runs at the start of every
        // analysis pass. Without it, an already-scored library would never gain a
        // single vector and Similar Groups would be silently empty for exactly the
        // users who already have a cache.
        try await fixture.cache.beginScan()
        checkEqual(try await fixture.cache.featurePrintBacklog(), 1,
                   "a scored asset with no FeaturePrint is queued for one")
        checkEqual(try await fixture.cache.featurePrints().count, 0, "and has none yet")

        let claimed = try await fixture.cache.claimFeaturePrints(limit: 10)
        checkEqual(claimed, ["a1"], "the backfill claims it")
        // Claiming must not touch the score: this asset is `done` and its score is
        // correct, and requeueing it would null the score and drop the photo out of
        // the grid for the length of a full re-run.
        checkEqual(try await fixture.analysisState(of: "a1"), .done, "the asset stays done")
        checkEqual(try fixture.query("SELECT aesthetics_score FROM assets WHERE asset_identifier = 'a1';") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return -1.0 }
            return sqlite3_column_double(statement, 0)
        }, 0.5, "and keeps its score")

        // Completing the backfill writes the vector and leaves the queue.
        try await fixture.cache.recordFeaturePrint(
            SignalCompression.featurePrintData(try await makeFeaturePrint(.verticalBands))!, for: "a1")
        checkEqual(try await fixture.cache.featurePrintBacklog(), 0, "the completed asset leaves the queue")
        checkEqual(try await fixture.cache.featurePrints().count, 1, "and its vector is readable")

        // A second pass must not re-queue it.
        try await fixture.cache.beginScan()
        checkEqual(try await fixture.cache.featurePrintBacklog(), 0,
                   "an asset that already has a vector is not queued again")
    })

    Registry.shared.add(suite: "similar group cache", TestCase(name: "a cancelled backfill returns its claims to the queue", knownBug: nil) {
        let fixture = try await Fixture.make("groups-backfill-cancel")
        try await fixture.seed([Fixture.Seed(id: "a1", score: 0.5, date: 100),
                                Fixture.Seed(id: "a2", score: 0.5, date: 101)])
        try await fixture.cache.beginScan()
        let claimed = try await fixture.cache.claimFeaturePrints(limit: 10)
        checkEqual(claimed.count, 2, "both are claimed")
        checkEqual(try await fixture.cache.featurePrintBacklog(), 0, "and both leave the queue while claimed")

        // A quit or a rescan mid-pass must not lose them — a claim that is never
        // completed has to come back, or the vector is never computed.
        try await fixture.cache.releaseFeaturePrints(identifiers: claimed)
        checkEqual(try await fixture.cache.featurePrintBacklog(), 2, "released claims return to the queue")
    })

    Registry.shared.add(suite: "similar group cache", TestCase(name: "an asset that is deleted leaves the backfill queue", knownBug: nil) {
        let fixture = try await Fixture.make("groups-backfill-delete")
        try await fixture.seed([Fixture.Seed(id: "a1", score: 0.5, date: 100)])
        try await fixture.cache.beginScan()
        checkEqual(try await fixture.cache.featurePrintBacklog(), 1, "it is queued")
        try await fixture.cache.remove(identifiers: ["a1"])
        checkEqual(try await fixture.cache.featurePrintBacklog(), 0,
                   "the foreign key takes the queue row with the asset")
    })

    Registry.shared.add(suite: "similar group cache", TestCase(name: "a vector from an older analyzer version is re-queued", knownBug: nil) {
        // `analyzerVersion` is the promise that "the meaning of a stored observation
        // changes when this number changes". A FeaturePrint is an observation like any
        // other, and a backfill queue that only asked whether a vector *exists* would
        // keep comparing prints computed under rules the current build no longer
        // applies — with no symptom except subtly wrong groups, which is the hardest
        // kind of wrong to notice.
        let fixture = try await Fixture.make("groups-backfill-version")
        try await fixture.seed([Fixture.Seed(id: "a1", score: 0.5, date: 100)])
        try await fixture.cache.recordFeaturePrint(
            SignalCompression.featurePrintData(try await makeFeaturePrint(.verticalBands))!, for: "a1")
        try await fixture.cache.beginScan()
        checkEqual(try await fixture.cache.featurePrintBacklog(), 0,
                   "a vector written by this build is not re-queued")

        // Stand in for a cache an earlier build wrote: the row is there, but its
        // recorded version is older than the one this build applies.
        try RawSQL.exec(fixture.cachePath,
                        "UPDATE asset_signals SET analyzer_version = 0 WHERE asset_identifier = 'a1';")
        try await fixture.cache.beginScan()
        checkEqual(try await fixture.cache.featurePrintBacklog(), 1,
                   "an older analyzer version puts the asset back in the queue")
        checkEqual(try await fixture.cache.claimFeaturePrints(limit: 10), ["a1"],
                   "and it is claimed for regeneration")
        // And regenerating it settles the question: the fresh row is current again.
        try await fixture.cache.recordFeaturePrint(
            SignalCompression.featurePrintData(try await makeFeaturePrint(.checkerboard))!, for: "a1")
        try await fixture.cache.beginScan()
        checkEqual(try await fixture.cache.featurePrintBacklog(), 0, "and stays out once rewritten")
    })

    Registry.shared.add(suite: "similar group cache", TestCase(name: "the face queue is ordered by capture time, oldest first", knownBug: nil) {
        // The order is a property of the photos, not of which group happened to sort
        // first. It used to be the smallest group identifier, which is unrelated to
        // anything a user would recognise — and it made the doc's promise ("oldest
        // first") false, which is the only reason this asserts a *direction*.
        let fixture = try await Fixture.make("groups-facequeue-order")
        // Two groups whose identifiers order *against* their capture times, so an
        // order that tracked group ids — as this one used to — would answer
        // differently from the documented one.
        try await fixture.seed([
            Fixture.Seed(id: "late-1", score: 0.5, date: 4_000),
            Fixture.Seed(id: "late-2", score: 0.5, date: 3_000),
            Fixture.Seed(id: "early-2", score: 0.5, date: 2_000),
            Fixture.Seed(id: "early-1", score: 0.5, date: 1_000),
        ])
        try await fixture.cache.replaceGroups([
            SimilarGroup(id: "a-late", members: ["late-1", "late-2"]),
            SimilarGroup(id: "z-early", members: ["early-1", "early-2"]),
        ], settings: .default, faceMemberCounts: [:], earliestDates: [:])

        checkEqual(try await fixture.cache.groupMembersNeedingFaces(limit: 100),
                   ["early-1", "early-2", "late-2", "late-1"],
                   "oldest capture first, whatever the group or the identifier says")

        // Two photos in one second tie-break on the identifier, so two runs cannot
        // hand out the same work in a different order.
        try await fixture.cache.recordFaceCaptureQuality(
            SignalCompression.faceCaptureResultData(FaceCaptureResult(
                faces: [FaceCapture(score: 0.5, areaFraction: 0.2)]))!, for: "early-1")
        checkEqual(try await fixture.cache.groupMembersNeedingFaces(limit: 100),
                   ["early-2", "late-2", "late-1"],
                   "and the analysed one leaves the front of the queue")
    })

    Registry.shared.add(suite: "similar group cache", TestCase(name: "a group membership row whose asset is gone is pruned", knownBug: nil) {
        // The foreign key normally takes a deleted asset's membership with it, so
        // this is a no-op on a correct database — which is why it has to be called at
        // all that a rebuild can read members while a scan deletes underneath it.
        let fixture = try await Fixture.make("groups-orphan-member")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.5, date: 100),
            Fixture.Seed(id: "a2", score: 0.5, date: 101),
        ])
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2"])],
                                              settings: .default, faceMemberCounts: [:], earliestDates: [:])
        checkEqual(try await fixture.cache.pruneOrphanGroupMembers(), 0,
                   "nothing to prune while every member exists")

        // Written through the raw handle, where foreign keys are off, so the orphan
        // is a real one rather than something the schema would have refused.
        try RawSQL.exec(fixture.cachePath,
                        "INSERT INTO similar_group_members (group_id, asset_identifier) VALUES ('a1', 'gone');")
        checkEqual(try await fixture.cache.groupID(containingAsset: "gone"), "a1",
                   "the orphan is present, which is the state the sweep exists for")
        checkEqual(try await fixture.cache.pruneOrphanGroupMembers(), 1, "and the sweep removes it")
        checkNil(try await fixture.cache.groupID(containingAsset: "gone"), "it is gone")
        checkEqual(try await fixture.cache.pruneOrphanGroupMembers(), 0, "and the sweep is idempotent")
    })

    Registry.shared.add(suite: "group pass settings", TestCase(name: "a relaunch still knows which rules built the stored groups", knownBug: nil) {
        // The engine's own record of what it built is process state. Without the
        // settings stored on the pass itself, a settings change followed by a quit
        // would leave groups built under the old rules reported — and served — as
        // current, and `stale` would read false in the one case where it matters.
        let fixture = try await Fixture.make("groups-stale")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.5, date: 100),
            Fixture.Seed(id: "a2", score: 0.5, date: 101),
        ])
        try await fixture.cache.recordFeaturePrint(
            SignalCompression.featurePrintData(try await makeFeaturePrint(.verticalBands))!, for: "a1")
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2"])],
                                              settings: .default, faceMemberCounts: [:], earliestDates: [:])

        // A second engine over the same cache stands in for the next launch: it has
        // no memory of the pass at all.
        let relaunched = SimilarGroupEngine(cache: fixture.cache, library: PhotoLibrary.shared,
                                            settings: fixture.settings, bus: fixture.bus)
        let fresh = await relaunched.status()
        checkEqual(fresh.stale, false, "groups built under the current settings are not stale")
        checkEqual(fresh.builtWithSettings, SimilarGroupSettings.default,
                   "and the rules they were built under are reported")
        check((fresh.lastBuiltAt ?? 0) > 0, "with the time of the pass")

        // Now move a knob, as `/api/settings` does.
        fixture.settings.update { $0.groupMaxDistance = 0.9 }
        let stale = await relaunched.status()
        checkEqual(stale.stale, true, "a pass built under different rules is reported as stale")
        checkEqual(await relaunched.shouldRebuild(), true, "and a rebuild is warranted")
    })

    Registry.shared.add(suite: "group pass settings", TestCase(name: "a relaunch does not throw away a pass that is still fresh", knownBug: nil) {
        // The other half of the same fact. A pass inside `maxAge` used to be
        // discarded on every launch, because the only record of it was process state:
        // a restart cost minutes of grouping to reproduce an answer that was already
        // on disk and still correct.
        let fixture = try await Fixture.make("groups-fresh-pass")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.5, date: 100),
            Fixture.Seed(id: "a2", score: 0.5, date: 101),
        ])
        try await fixture.cache.recordFeaturePrint(
            SignalCompression.featurePrintData(try await makeFeaturePrint(.verticalBands))!, for: "a1")
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2"])],
                                              settings: .default, faceMemberCounts: [:], earliestDates: [:])
        let relaunched = SimilarGroupEngine(cache: fixture.cache, library: PhotoLibrary.shared,
                                            settings: fixture.settings, bus: fixture.bus)
        checkEqual(await relaunched.shouldRebuild(), false,
                   "a pass inside the freshness bound is served rather than redone")

        // And the empty case is still "do the work": no stored pass means no answer.
        try await fixture.cache.replaceGroups([], settings: .default,
                                              faceMemberCounts: [:], earliestDates: [:])
        checkEqual(await relaunched.shouldRebuild(), true,
                   "with nothing stored, a rebuild is the answer")
    })

    Registry.shared.add(suite: "group routes", TestCase(name: "groups and a single group are served", knownBug: nil) {
        let fixture = try await Fixture.make("groups-routes")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.4, date: 100),
            Fixture.Seed(id: "a2", score: 0.9, date: 101),
        ])
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2"])],
                                              settings: .default,
                                              faceMemberCounts: ["a1": 0], earliestDates: ["a1": 100])

        let list = await fixture.router.reply(Req.get("/api/groups"))
        checkEqual(list.status, 200, "GET /api/groups answers 200")
        let groups = list.json["groups"] as? [[String: Any]] ?? []
        checkEqual(groups.count, 1, "one group is listed")
        checkEqual(list.int("total"), 1, "the total is reported")

        let single = await fixture.router.reply(Req.get("/api/group", query: ["id": "a1"]))
        checkEqual(single.status, 200, "GET /api/group answers 200")
        let items = single.json["items"] as? [[String: Any]] ?? []
        checkEqual(items.count, 2, "both members come back")
        // Aesthetics descending by default.
        checkEqual((items.first?["aesthetics"] as? NSNumber)?.floatValue, 0.9,
                   "the better-scoring photo leads the default order")
        checkEqual(single.string("ranked"), "aesthetics", "the response says which order it used")
    })

    Registry.shared.add(suite: "group routes", TestCase(name: "an unknown group is a 404, not an empty group", knownBug: nil) {
        let fixture = try await Fixture.make("groups-404")
        let reply = await fixture.router.reply(Req.get("/api/group", query: ["id": "nope"]))
        checkEqual(reply.status, 404, "a group this instance never built is refused")
        check(reply.errorMessage.contains("unknown group"), "and the message says so")
    })

    Registry.shared.add(suite: "group routes", TestCase(name: "a group request without an id is a 400", knownBug: nil) {
        let fixture = try await Fixture.make("groups-400")
        let reply = await fixture.router.reply(Req.get("/api/group"))
        checkEqual(reply.status, 400, "a missing id is a client error")
    })

    Registry.shared.add(suite: "group routes", TestCase(name: "Best Shot order is reported as such and carries its own values", knownBug: nil) {
        let fixture = try await Fixture.make("groups-bestshot")
        // Both members must exist: `similar_group_members` is keyed by a foreign
        // key onto `assets`, so a group naming an unknown photo is refused rather
        // than stored.
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.81, date: 100),
            Fixture.Seed(id: "a2", score: 0.20, date: 101),
        ])
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2"])],
                                              settings: .default, faceMemberCounts: [:], earliestDates: [:])
        let reply = await fixture.router.reply(Req.get("/api/group", query: ["id": "a1", "order": "best_shot"]))
        checkEqual(reply.status, 200, "an explicit Best Shot order is accepted")
        checkEqual(reply.string("ranked"), "best_shot", "the response names the order it used")
        let items = reply.json["items"] as? [[String: Any]] ?? []
        // A one-member group has no separation, so the only scored member ranks
        // alone and must still carry a Best Shot value.
        checkNotNil(items.first?["bestShot"], "a Best Shot value is present for the Best Shot order")
        // The same group under the default order must not carry one, so a client
        // cannot mistake an aesthetics ordering for a Best Shot one.
        let aestheticsReply = await fixture.router.reply(Req.get("/api/group", query: ["id": "a1"]))
        let aestheticsItems = aestheticsReply.json["items"] as? [[String: Any]] ?? []
        checkNil(aestheticsItems.first?["bestShot"] ?? nil,
                 "an aesthetics-ordered group reports no Best Shot value")
    })

    Registry.shared.add(suite: "group routes", TestCase(name: "an unrecognised order falls back rather than failing", knownBug: nil) {
        let fixture = try await Fixture.make("groups-badorder")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.4, date: 100),
            Fixture.Seed(id: "a2", score: 0.6, date: 101),
        ])
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2"])],
                                              settings: .default, faceMemberCounts: [:], earliestDates: [:])
        let reply = await fixture.router.reply(Req.get("/api/group", query: ["id": "a1", "order": "nonsense"]))
        checkEqual(reply.status, 200, "an unknown order does not break the route")
        checkEqual(reply.string("ranked"), "aesthetics", "it falls back to the conservative order")
    })

    Registry.shared.add(suite: "group routes", TestCase(name: "a rebuild cannot be triggered cross-site", knownBug: nil) {
        let fixture = try await Fixture.make("groups-rebuild")
        let refused = await fixture.router.reply(Req.post("/api/groups/rebuild", json: "{}",
                                                          headers: ["sec-fetch-site": "cross-site"]))
        checkEqual(refused.status, 403, "a rebuild is refused cross-site")
    })

    Registry.shared.add(suite: "group routes", TestCase(name: "group settings round-trip and clamp", knownBug: nil) {
        let fixture = try await Fixture.make("groups-settings")
        let reply = await fixture.router.reply(Req.post("/api/settings",
                                                         json: #"{"groupWindowSeconds": 45, "groupMaxDistance": 0.9, "groupFaceWeight": 3}"#))
        checkEqual(reply.status, 200, "the settings are accepted")
        let settings = reply.json["settings"] as? [String: Any] ?? [:]
        checkEqual((settings["groupWindowSeconds"] as? NSNumber)?.doubleValue, 45, "the window was stored")
        checkEqual((settings["groupMaxDistance"] as? NSNumber)?.floatValue, 0.9, "the distance was stored")
        // Out of range, so clamped rather than refused: a bad weight must not be
        // able to make face quality silently irrelevant.
        checkEqual((settings["groupFaceWeight"] as? NSNumber)?.floatValue, 1.0, "the weight is clamped to 1")
    })

    // "Show Similar Photos" is a doorway into the group browser, and what makes it
    // feel instant is that it asks a question the cache can already answer. These
    // cases pin that contract: membership, not similarity.

    Registry.shared.add(suite: "similar photo lookup", TestCase(name: "a photo in a group resolves to that group and its size", knownBug: nil) {
        let fixture = try await Fixture.make("similar-lookup")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.9, date: 100),
            Fixture.Seed(id: "a2", score: 0.4, date: 101),
            Fixture.Seed(id: "a3", score: 0.6, date: 102),
        ])
        try await fixture.cache.replaceGroups([
            SimilarGroup(id: "a1", members: ["a1", "a2"]),
        ], settings: .default, faceMemberCounts: [:], earliestDates: [:])

        // The cache side: a membership read, one row, no arithmetic.
        checkEqual(try await fixture.cache.groupID(containingAsset: "a2"), "a1",
                   "a member resolves to the group it belongs to")
        checkNil(try await fixture.cache.groupID(containingAsset: "a3"),
                 "a photo in no group has no membership row to find")

        let reply = await fixture.router.reply(Req.get("/api/photo/a2/similar"))
        checkEqual(reply.status, 200, "GET /api/photo/{id}/similar answers 200")
        checkEqual(reply.string("groupId"), "a1", "it names the stored group")
        checkEqual(reply.int("totalCount"), 2, "and reports the group's size")
    })

    Registry.shared.add(suite: "similar photo lookup", TestCase(name: "an absent group is an omitted key, not a null", knownBug: nil) {
        let fixture = try await Fixture.make("similar-lookup-absent")
        try await fixture.seed([Fixture.Seed(id: "a1", score: 0.5, date: 100)])
        try await fixture.cache.recordFeaturePrint(
            SignalCompression.featurePrintData(try await makeFeaturePrint(.verticalBands))!, for: "a1")

        let reply = await fixture.router.reply(Req.get("/api/photo/a1/similar"))
        checkEqual(reply.status, 200, "a photo in no group is still answered, not refused")
        check(!reply.has("groupId"), "groupId is omitted rather than sent as null")
        checkEqual(reply.int("totalCount"), 0, "the count is zero")
        checkEqual(reply.bool("analyzed"), true,
                   "and analysis has reached this photo, so 'no similar photos' is a real answer")
    })

    Registry.shared.add(suite: "similar photo lookup", TestCase(name: "a photo analysis has not reached is reported as not analysed", knownBug: nil) {
        let fixture = try await Fixture.make("similar-lookup-pending")
        try await fixture.seed([Fixture.Seed(id: "a1", score: 0.5, date: 100)])

        check(try await !(fixture.cache.hasFeaturePrint(for: "a1")),
              "a scored asset with no FeaturePrint has none yet")
        let reply = await fixture.router.reply(Req.get("/api/photo/a1/similar"))
        checkEqual(reply.status, 200, "it is still answered")
        check(!reply.has("groupId"), "with no group")
        // This is the whole point of the flag. Without it, "analysis has not
        // reached this photo" and "this photo has no similar photos" would be the
        // same answer, and the UI would claim a photo is unique when nothing has
        // compared it to anything yet.
        checkEqual(reply.bool("analyzed"), false, "and `analyzed` says why there is nothing to show")
    })

    Registry.shared.add(suite: "similar photo lookup", TestCase(name: "favourite protection does not hide a group from its own members", knownBug: nil) {
        let fixture = try await Fixture.make("similar-lookup-favourites")
        // Three members, two of them favourites. A cleanup-oriented list has little
        // to offer here — one photo is actionable — but "which photos are similar
        // to this one" is a different question, and it is answered from membership
        // rather than from any list. If a visibility rule is ever added to
        // /api/groups, this case is what says the lookup must not inherit it.
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.9, date: 100, favorite: true),
            Fixture.Seed(id: "a2", score: 0.8, date: 101, favorite: true),
            Fixture.Seed(id: "a3", score: 0.7, date: 102),
        ])
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2", "a3"])],
                                              settings: .default, faceMemberCounts: [:],
                                              earliestDates: [:])

        let lookup = await fixture.router.reply(Req.get("/api/photo/a3/similar"))
        checkEqual(lookup.string("groupId"), "a1", "the unprotected member finds its group")
        checkEqual(lookup.int("totalCount"), 3, "and the group is all three photos")

        // The favourites are reachable the same way, from themselves.
        for favourite in ["a1", "a2"] {
            let own = await fixture.router.reply(Req.get("/api/photo/\(favourite)/similar"))
            checkEqual(own.string("groupId"), "a1", "\(favourite) finds the same group")
        }

        // And the browser that opens still serves every member, favourites included.
        let group = await fixture.router.reply(Req.get("/api/group", query: ["id": "a1"]))
        checkEqual(group.rows("items").count, 3, "the group browser still shows all three members")
        checkEqual(group.rows("items").filter { $0.favorite }.count, 2,
                   "protected favourites are not dropped from the result")
    })

    // The album filter, as it reaches this view. The grid already had one, and the
    // user expectation it creates is the whole subject of these cases: having
    // narrowed the grid to one album, opening Similar Groups must not silently
    // widen back to the whole library.

    Registry.shared.add(suite: "group album filter", TestCase(name: "the list shows only groups with a member in the album", knownBug: nil) {
        let fixture = try await Fixture.make("groups-album-list")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.9, date: 100),
            Fixture.Seed(id: "a2", score: 0.8, date: 101),
            Fixture.Seed(id: "b1", score: 0.7, date: 200),
            Fixture.Seed(id: "b2", score: 0.6, date: 201),
            Fixture.Seed(id: "c1", score: 0.5, date: 300),
            Fixture.Seed(id: "c2", score: 0.4, date: 301),
        ])
        // Two groups entirely inside the album, one straddling it, and one group with
        // nothing in it at all. "Any member", not "every member", is the rule: a burst
        // split across two albums is still the same burst, and requiring every member
        // to be in the album would hide exactly the groups a user comparing two
        // albums most wants to see.
        try await fixture.cache.replaceGroups([
            SimilarGroup(id: "a1", members: ["a1", "a2"]),
            SimilarGroup(id: "b1", members: ["b1", "b2"]),
            SimilarGroup(id: "c1", members: ["c1", "c2"]),
        ], settings: .default, faceMemberCounts: [:], earliestDates: [:])
        try await fixture.cache.upsertAlbum(identifier: "album-1", title: "Trips", collectionType: 0)
        try await fixture.cache.replaceAlbumMembership(albumIdentifier: "album-1",
                                                      identifiers: ["a1", "a2", "b1"])

        let unfiltered = await fixture.router.reply(Req.get("/api/groups"))
        checkEqual(unfiltered.rows("groups").count, 3, "every group is listed with no album filter")

        let filtered = await fixture.router.reply(Req.get("/api/groups", query: ["album": "album-1"]))
        checkEqual(filtered.status, 200, "an indexed album is accepted")
        checkEqual(filtered.rows("groups").count, 2, "only the two groups with a member in the album are listed")
        checkEqual(filtered.int("total"), 2, "and the total counts the filtered set, so paging is consistent")
        let ids = filtered.rows("groups").map { $0.id }
        checkSetEqual(ids, ["a1", "b1"], "the fully-inside group and the straddling one, by id")
    })

    Registry.shared.add(suite: "group album filter", TestCase(name: "a group's members are filtered too, and what was left out is reported", knownBug: nil) {
        let fixture = try await Fixture.make("groups-album-members")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.9, date: 100),
            Fixture.Seed(id: "a2", score: 0.8, date: 101),
            Fixture.Seed(id: "b1", score: 0.7, date: 200),
            Fixture.Seed(id: "b2", score: 0.6, date: 201),
        ])
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2", "b1", "b2"])],
                                              settings: .default, faceMemberCounts: [:], earliestDates: [:])
        try await fixture.cache.upsertAlbum(identifier: "album-1", title: "Trips", collectionType: 0)
        try await fixture.cache.replaceAlbumMembership(albumIdentifier: "album-1", identifiers: ["a1", "b1"])

        let whole = await fixture.router.reply(Req.get("/api/group", query: ["id": "a1"]))
        checkEqual(whole.rows("items").count, 4, "without a filter the group is all four photos")
        checkEqual(whole.int("memberCount"), 4, "and says so")
        // Omitted, not zero: an absent key means "nothing was filtered", which is a
        // different thing from "a filter that hid nothing".
        check(!whole.has("hiddenMemberCount"), "an unfiltered group carries no hidden count at all")

        let filtered = await fixture.router.reply(Req.get("/api/group", query: ["id": "a1", "album": "album-1"]))
        checkEqual(filtered.status, 200, "the album filter is accepted on one group")
        checkEqual(filtered.rows("items").count, 2, "only the album's members are served")
        checkSetEqual(filtered.rows("items").map { $0.id }, ["a1", "b1"],
                      "the two photos that are in the album")
        checkEqual(filtered.int("memberCount"), 2, "the count is of what is shown")
        checkEqual(filtered.int("hiddenMemberCount"), 2, "and the two left out are reported rather than absorbed")
    })

    Registry.shared.add(suite: "group album filter", TestCase(name: "an unfiltered group reports its stored face count, a filtered one its own", knownBug: nil) {
        let fixture = try await Fixture.make("groups-album-faces")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.9, date: 100),
            Fixture.Seed(id: "a2", score: 0.8, date: 101),
            Fixture.Seed(id: "b1", score: 0.7, date: 200),
            Fixture.Seed(id: "b2", score: 0.6, date: 201),
        ])
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2", "b1", "b2"])],
                                              settings: .default,
                                              faceMemberCounts: ["a1": 4], earliestDates: [:])
        try await fixture.cache.upsertAlbum(identifier: "album-1", title: "Trips", collectionType: 0)
        try await fixture.cache.replaceAlbumMembership(albumIdentifier: "album-1", identifiers: ["a1", "b1"])

        let whole = await fixture.router.reply(Req.get("/api/group", query: ["id": "a1"]))
        checkEqual(whole.int("faceMemberCount"), 4, "unfiltered, the stored count is served as-is")

        // The fixture has no face results cached, so the filtered recount is zero. The
        // assertion is about *which* number is reported, not about Vision: a card
        // reading "2 photos" next to a badge saying four have faces would be two true
        // sentences and one obviously wrong one.
        let filtered = await fixture.router.reply(Req.get("/api/group", query: ["id": "a1", "album": "album-1"]))
        checkEqual(filtered.int("faceMemberCount"), 0, "the filtered face count is of the members shown, not the whole group")
    })

    Registry.shared.add(suite: "group album filter", TestCase(name: "a group with nothing in the album is empty, not missing", knownBug: nil) {
        let fixture = try await Fixture.make("groups-album-empty")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.9, date: 100),
            Fixture.Seed(id: "a2", score: 0.8, date: 101),
            Fixture.Seed(id: "b1", score: 0.7, date: 200),
            Fixture.Seed(id: "b2", score: 0.6, date: 201),
        ])
        try await fixture.cache.replaceGroups([SimilarGroup(id: "b1", members: ["b1", "b2"])],
                                              settings: .default, faceMemberCounts: [:], earliestDates: [:])
        try await fixture.cache.upsertAlbum(identifier: "album-1", title: "Trips", collectionType: 0)
        try await fixture.cache.replaceAlbumMembership(albumIdentifier: "album-1", identifiers: ["a1"])

        // The group is stored and still exists — a 404 here would send the user
        // looking for a regrouping that is not needed and has not happened.
        let reply = await fixture.router.reply(Req.get("/api/group", query: ["id": "b1", "album": "album-1"]))
        checkEqual(reply.status, 200, "the group is still served")
        checkEqual(reply.string("id"), "b1", "and identified, so the UI can name what it filtered")
        checkEqual(reply.rows("items").count, 0, "with none of its members in the album")
        checkEqual(reply.int("hiddenMemberCount"), 2, "the group's real size is still reported")
    })

    Registry.shared.add(suite: "group album filter", TestCase(name: "\"none\" is a real bucket here too", knownBug: nil) {
        let fixture = try await Fixture.make("groups-album-none")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.9, date: 100),
            Fixture.Seed(id: "a2", score: 0.8, date: 101),
            Fixture.Seed(id: "b1", score: 0.7, date: 200),
            Fixture.Seed(id: "b2", score: 0.6, date: 201),
        ])
        try await fixture.cache.replaceGroups([
            SimilarGroup(id: "a1", members: ["a1", "a2"]),
            SimilarGroup(id: "b1", members: ["b1", "b2"]),
        ], settings: .default, faceMemberCounts: [:], earliestDates: [:])
        try await fixture.cache.upsertAlbum(identifier: "album-1", title: "Trips", collectionType: 0)
        try await fixture.cache.replaceAlbumMembership(albumIdentifier: "album-1", identifiers: ["a1", "a2"])

        let reply = await fixture.router.reply(Req.get("/api/groups", query: ["album": "none"]))
        checkEqual(reply.status, 200, "the no-album bucket is accepted")
        checkSetEqual(reply.rows("groups").map { $0.id }, ["b1"],
                      "only the group whose members are in no album at all")
    })

    Registry.shared.add(suite: "group album filter", TestCase(name: "an album this instance has not read is refused, not ignored", knownBug: nil) {
        let fixture = try await Fixture.make("groups-album-unknown")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.9, date: 100),
            Fixture.Seed(id: "a2", score: 0.8, date: 101),
        ])
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2"])],
                                              settings: .default, faceMemberCounts: [:], earliestDates: [:])

        let list = await fixture.router.reply(Req.get("/api/groups", query: ["album": "nope"]))
        checkEqual(list.status, 400, "the list refuses an unindexed album")
        let one = await fixture.router.reply(Req.get("/api/group", query: ["id": "a1", "album": "nope"]))
        checkEqual(one.status, 400, "and so does one group, on the same terms as the grid")
        // Treating it as "no filter" would show the whole library under a title the
        // user believes is an album, which is the failure the grid's 400 exists to stop.
        check(one.errorMessage.contains("has not read") || one.errorMessage.contains("not one PhotoCleaner"),
              "and the message says which problem it is")
    })

    Registry.shared.add(suite: "similar photo lookup", TestCase(name: "the lookup refuses an asset this instance has never seen", knownBug: nil) {
        let fixture = try await Fixture.make("similar-lookup-unknown")
        let reply = await fixture.router.reply(Req.get("/api/photo/never-scanned/similar"))
        checkEqual(reply.status, 404, "an unknown asset is a 404")
        check(reply.errorMessage.contains("unknown asset"), "and says so")
    })

    Registry.shared.add(suite: "similar photo lookup", TestCase(name: "the lookup reads stored membership and writes nothing", knownBug: nil) {
        let fixture = try await Fixture.make("similar-lookup-readonly")
        try await fixture.seed([
            Fixture.Seed(id: "a1", score: 0.9, date: 100),
            Fixture.Seed(id: "a2", score: 0.4, date: 101),
        ])
        try await fixture.cache.replaceGroups([SimilarGroup(id: "a1", members: ["a1", "a2"])],
                                              settings: .default, faceMemberCounts: [:], earliestDates: [:])

        func rows(in table: String) throws -> Int {
            try fixture.query("SELECT COUNT(*) FROM \(table);") { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
                return Int(sqlite3_column_int(statement, 0))
            }
        }
        let groupsBefore = try rows(in: "similar_groups")
        let membersBefore = try rows(in: "similar_group_members")

        _ = await fixture.router.reply(Req.get("/api/photo/a1/similar"))

        // "Show, not find": the heavy work already happened when the FeaturePrints
        // were analysed. A right-click that re-derived similarity here would show up
        // as a group the user never asked for, so the route must create nothing —
        // in particular not a group of one for a photo that has no similar photos.
        checkEqual(try rows(in: "similar_groups"), groupsBefore, "asking creates no group")
        checkEqual(try rows(in: "similar_group_members"), membersBefore, "and changes no membership")
    })
}

// MARK: - Helpers

/// A FeaturePrint for one of a set of synthetic images whose distances to each
/// other have been **measured**, not assumed.
///
/// ## Why these patterns, and why not colour
///
/// The obvious fixture — two different solid colours — does not work, and finding
/// out why changed the design of the tests. Measured:
///
/// - solid red vs solid green: **0.31** apart
/// - two *different* random noise fields: **0.0056** apart
///
/// Both are inside the 0.35 grouping threshold. A FeaturePrint is dominated by
/// overall texture statistics, so colour barely registers and independent noise is
/// nearly identical to it. A colour-based fixture therefore cannot express "clearly
/// different photos" at all, and a noise-based one cannot express "the same photo".
///
/// What does separate images is *arrangement*, but only with full-bleed contrast:
/// with a grey under-fill, perpendicular bands came out only 0.24 apart, versus
/// 0.99 without it. A busy under-fill masks the structure the pattern exists to
/// express.
///
/// So these patterns are full-bleed and high-contrast. The four used for "clearly
/// different" are pairwise **0.57…1.21** apart — every pair outside the threshold
/// with margin — and the "same shot" pairs come out at **0.03…0.23**, inside it
/// with margin. `checkFixtureSeparation` asserts both against real Vision output, so
/// a fixture that quietly stopped separating images cannot make a case pass for the
/// wrong reason.
enum TestPattern: Sendable {
    // Four mutually distinct patterns, each >0.35 from every other.
    case verticalBands
    case checkerboard
    case radial
    case diagonal

    // Pairs that read as the same shot.
    /// 0.039 from `verticalBands` — a burst frame.
    case verticalBandsShifted
    /// 0.028 from `diagonalCoarse` — a burst frame.
    case diagonalCoarse
    /// 0.226 from `checkerboard` — related, and still one shot.
    case checkerboardCoarse

    func draw(size: Int = 128) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SkipTest(reason: "could not create a bitmap context for the test image")
        }
        let edge = CGFloat(size)
        func fill(_ rect: CGRect, grey: CGFloat) {
            context.setFillColor(gray: grey, alpha: 1)
            context.fill(rect)
        }

        switch self {
        case .verticalBands, .verticalBandsShifted:
            let phase = self == .verticalBandsShifted ? 1 : 0
            for index in 0..<4 {
                fill(CGRect(x: CGFloat(index) * edge / 4, y: 0, width: edge / 4, height: edge),
                     grey: (index + phase) % 2 == 0 ? 1 : 0)
            }

        case .checkerboard, .checkerboardCoarse:
            let cells = self == .checkerboardCoarse ? 5 : 8
            let cell = edge / CGFloat(cells)
            for row in 0..<cells {
                for column in 0..<cells {
                    fill(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                                width: cell, height: cell),
                         grey: (row + column) % 2 == 0 ? 1 : 0)
                }
            }

        case .radial:
            for step in 0..<64 {
                let value = CGFloat(step) / 64
                context.setFillColor(red: value, green: 1 - value, blue: 0.5, alpha: 1)
                let diameter = CGFloat(step) * 4
                context.fill(CGRect(x: edge / 2 - diameter / 2, y: edge / 2 - diameter / 2,
                                    width: diameter, height: diameter))
            }

        case .diagonal, .diagonalCoarse:
            fill(CGRect(x: 0, y: 0, width: edge, height: edge), grey: 1)
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setLineWidth(8)
            let spacing: CGFloat = self == .diagonalCoarse ? 24 : 20
            var offset: CGFloat = -edge
            while offset <= edge {
                context.move(to: CGPoint(x: offset, y: 0))
                context.addLine(to: CGPoint(x: offset + edge, y: edge))
                context.strokePath()
                offset += spacing
            }
        }
        guard let image = context.makeImage() else {
            throw SkipTest(reason: "could not make a CGImage for the test")
        }
        return image
    }
}

func makeFeaturePrint(_ pattern: TestPattern) async throws -> FeaturePrintObservation {
    try await GenerateImageFeaturePrintRequest(.revision2).perform(on: try pattern.draw())
}

/// Asserts the fixture still does what the grouping cases depend on.
///
/// Without this, the "clearly different photos stay apart" case would pass even if
/// the builder compared nothing at all — zero groups is what an empty comparison
/// also produces. So the fixture's own premise is checked against real Vision
/// output before those cases mean anything.
func checkFixtureSeparation() async {
    let distinct: [TestPattern] = [.verticalBands, .checkerboard, .radial, .diagonal]
    for (index, first) in distinct.enumerated() {
        for second in distinct[(index + 1)...] {
            guard let left = try? await makeFeaturePrint(first),
                  let right = try? await makeFeaturePrint(second),
                  let distance = try? left.distance(to: right) else {
                Harness.record("the fixture could not measure \(first) vs \(second)")
                continue
            }
            check(distance > Double(SimilarGroupSettings.default.maxDistance),
                  "\(first) and \(second) must be further apart than the threshold, measured \(distance)")
        }
    }
    // Measured 0.039 / 0.028 / 0.226; tolerance because the point is the
    // neighbourhood, not bit-exact reproduction of a probe run.
    let sameShot: [(TestPattern, TestPattern, Double)] = [
        (.verticalBands, .verticalBandsShifted, 0.039),
        (.diagonalCoarse, .diagonal, 0.028),
        (.checkerboard, .checkerboardCoarse, 0.226),
    ]
    for (first, second, expected) in sameShot {
        guard let left = try? await makeFeaturePrint(first),
              let right = try? await makeFeaturePrint(second),
              let distance = try? left.distance(to: right) else {
            Harness.record("the fixture could not measure \(first) vs \(second)")
            continue
        }
        check(abs(distance - expected) < 0.05,
              "\(first) vs \(second) should sit near \(expected), measured \(distance)")
        check(distance <= Double(SimilarGroupSettings.default.maxDistance),
              "\(first) and \(second) must be inside the threshold to model one shot")
    }
}

extension Double {
    /// Rounds to `places` decimal places, for comparing a stored value against a
    /// decimal literal.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
