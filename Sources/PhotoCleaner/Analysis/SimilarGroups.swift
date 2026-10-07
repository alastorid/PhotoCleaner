import CoreGraphics
import Foundation
import Photos
import Vision

// Similar Groups: which photos are alternate captures of approximately the same
// shot, and how they should be ordered against each other.
//
// These are two independent questions and the types below keep them apart:
//
//   GROUPING  — `FeaturePrint` distance, restricted to a capture-time
//               neighbourhood. Answers "do these belong together?".
//   RANKING   — aesthetics, and optionally face capture quality. Answers "which
//               of these is better?".
//
// A FeaturePrint distance is never an input to a ranking, and an aesthetics score
// is never an input to grouping. Nothing in this file combines them into one
// number, because they are not on a common scale: `overallScore` is measured at
// −0.9959…+1.0000 on this library, while FeaturePrint distance runs 0…~1.5. A
// single weighted sum of the two would be arithmetic on unrelated units.

// MARK: - Configuration

/// The two knobs that decide what counts as "the same shot", plus the two that
/// decide how a group is ranked.
///
/// Exposed as settings rather than constants because they are the parameters a
/// user must be able to change to suit their library: a photographer shooting
/// bursts wants a tight window, someone grouping a child's birthday across ten
/// minutes of footage wants a wide one, and neither is wrong. The defaults are
/// measured, not guessed — see `DefaultCalibration`.
struct SimilarGroupSettings: Sendable, Equatable, Codable {
    /// Half-width, in seconds, of the capture-time neighbourhood.
    ///
    /// Comparisons only ever happen between photos captured within this of each
    /// other. This is what keeps grouping from being an all-pairs comparison over
    /// the whole library, and it is the reason the feature is affordable at all:
    /// measured on this library, a 120 s window leaves a median of 16 candidates
    /// per photo, while an unbounded comparison would be 1.4 billion pairs.
    var windowSeconds: Double

    /// Maximum FeaturePrint distance for two time-adjacent photos to be the same
    /// shot.
    ///
    /// Measured against real bursts (consecutive frames ≤2 s apart) on a
    /// 53,177-photo library:
    ///
    /// | pair kind      | n   | min   | p50   | p90   | max   |
    /// |----------------|-----|-------|-------|-------|-------|
    /// | same burst     |  28 | 0.020 | 0.054 | 0.282 | 0.535 |
    /// | other bursts   | 437 | 0.472 | 0.990 | 1.195 | 1.451 |
    ///
    /// At 0.35 the merge is 93% complete with **zero** cross-burst merges; at 0.55
    /// recall reaches 100% but 6 wrong merges appear. The two distributions
    /// genuinely overlap in [0.47, 0.53], so no threshold is exact — 0.35 is
    /// chosen as the point where nothing wrong is merged, on the grounds that a
    /// missed merge costs the user a manual sort while a false merge silently
    /// gathers unrelated photos.
    var maxDistance: Float

    /// Weight given to face capture quality when ranking a portrait group by Best
    /// Shot. 0 is pure aesthetics, 1 is pure face capture quality.
    ///
    /// This is deliberately the *only* tunable in the ranking, and it operates on
    /// group-relative ranks rather than on the raw scores, because the two signals
    /// are not comparable in absolute terms (see the note above). The default is
    /// 0.5: an even blend, chosen because it is the value that asserts no
    /// preference between two signals measured on different scales.
    var faceWeight: Float

    /// A face counts towards a photo's capture quality only if it covers at least
    /// this fraction of the frame.
    ///
    /// Measured face areas on this library run 0.0017…0.90 of the image. Without
    /// a floor, a face in the background of a landscape pulls the aggregate down
    /// for a reason that has nothing to do with the subject.
    var minimumFaceAreaFraction: Float

    /// Largest group accepted. Groups above this are split rather than merged.
    ///
    /// Necessary because capture time is a weak restriction in practice: a 120 s
    /// window on this library has a p90 of 177 and a max of 939 neighbours, and
    /// one window held 1,499 photos. Chained through a permissive threshold, that
    /// is a whole event collapsing into a single unusable "group". Splitting keeps
    /// the browser honest about what it found.
    var maximumGroupSize: Int

    static let `default` = SimilarGroupSettings(
        windowSeconds: 120,
        maxDistance: 0.35,
        faceWeight: 0.5,
        minimumFaceAreaFraction: 0.01,
        maximumGroupSize: 60
    )

    /// Clamps every field into a range that keeps a bad settings file from making
    /// the feature unbounded or inert.
    func validated() -> SimilarGroupSettings {
        var copy = self
        copy.windowSeconds = min(max(windowSeconds, 1), 3600)
        copy.maxDistance = min(max(maxDistance, 0.01), 2.0)
        copy.faceWeight = min(max(faceWeight, 0), 1)
        copy.minimumFaceAreaFraction = min(max(minimumFaceAreaFraction, 0), 0.5)
        copy.maximumGroupSize = min(max(maximumGroupSize, 2), 500)
        return copy
    }
}

// MARK: - Grouping

/// One photo as grouping sees it: identity, capture time, and its FeaturePrint.
struct GroupingCandidate: Sendable {
    let identifier: String
    /// `PHAsset.creationDate`, seconds since 1970. `nil` for an asset with no
    /// date, which makes it ungroupable — there is no neighbourhood to place it
    /// in. See `SimilarGroupBuilder`.
    let date: Double?
    let featurePrint: FeaturePrintObservation?
}

/// A group of photos believed to be alternate captures of one shot.
struct SimilarGroup: Sendable, Equatable {
    /// The lexicographically smallest member's identifier.
    ///
    /// Derived from the members rather than generated, so a group keeps its
    /// identity across rebuilds and can be cited in a URL.
    let id: String
    let members: [String]
}

/// Builds Similar Groups from cached FeaturePrints.
///
/// ## Why capture time comes first
///
/// The design is a funnel, not a matrix:
///
///     capture-time neighbourhood → FeaturePrint distance → group
///
/// Restricting by time first is what makes this affordable: an all-pairs
/// comparison over 53,177 photos is ~1.4 billion distance computations, while
/// the time-restricted set is ~3.9 million (measured). It is also better for
/// correctness — two photos of the same composition taken a year apart are not
/// "alternate captures of the same shot", however similar they look.
///
/// ## Union-find, single linkage
///
/// Candidates are chained: A merges with B, and B with C, so A and C end in one
/// group even if A and C are further apart than the threshold. This is the right
/// behaviour for a burst, where the first and last frames are further apart than
/// consecutive ones — measured, within-burst distances run to 0.53 while
/// consecutive-frame distances sit near 0.05.
///
/// The cost of single linkage is chaining: a dense event can merge into one
/// group far larger than any real burst. `maximumGroupSize` bounds that, and the
/// time window already excludes anything seconds apart.
enum SimilarGroupBuilder {
    /// Groups candidates into Similar Groups.
    ///
    /// - Returns: groups of two or more candidates. A lone photo is not a group
    ///   and is never returned — there is nothing for a group browser to show.
    static func build(candidates: [GroupingCandidate],
                      settings: SimilarGroupSettings) -> [SimilarGroup] {
        let config = settings.validated()
        let eligible = candidates.filter { $0.date != nil && $0.featurePrint != nil }
        guard eligible.count > 1 else { return [] }

        // Chronological, with the identifier as a deterministic tie-break: two
        // photos in the same second must not be able to swap places between runs.
        let ordered = eligible.sorted {
            ($0.date ?? 0, $0.identifier) < ($1.date ?? 0, $1.identifier)
        }
        let dates = ordered.map { $0.date ?? 0 }

        // Sliding window of candidate indices. `windowEnd` is the first index
        // outside the window, so the inner loop visits exactly the in-window
        // candidates — one pass, no repeated scanning.
        var windowStart = 0
        var parent = Array(0..<ordered.count)
        var rank = Array(repeating: 0, count: ordered.count)

        func find(_ node: Int) -> Int {
            var root = node
            while parent[root] != root { root = parent[root] }
            // Path compression, so a chain does not make later merges quadratic.
            var walk = node
            while parent[walk] != root {
                let next = parent[walk]
                parent[walk] = root
                walk = next
            }
            return root
        }

        func union(_ a: Int, _ b: Int) {
            let rootA = find(a), rootB = find(b)
            if rootA == rootB { return }
            // Union by rank.
            if rank[rootA] < rank[rootB] {
                parent[rootA] = rootB
            } else if rank[rootA] > rank[rootB] {
                parent[rootB] = rootA
            } else {
                parent[rootB] = rootA
                rank[rootA] += 1
            }
        }

        var windowEnd = 0
        for i in ordered.indices {
            let centre = dates[i]
            while windowEnd < ordered.count, dates[windowEnd] - centre <= config.windowSeconds {
                windowEnd += 1
            }
            // `windowStart` only ever moves forward: the window is sorted by date,
            // so once a candidate falls out of the left edge it cannot return.
            while windowStart < i, centre - dates[windowStart] > config.windowSeconds {
                windowStart += 1
            }
            guard let lhs = ordered[i].featurePrint else { continue }
            // Compare forward only: every pair is visited once, from its earlier
            // member, so a half-matrix walk cannot both miss pairs and double-count.
            for j in (i + 1)..<max(windowEnd, i + 1) {
                guard let rhs = ordered[j].featurePrint else { continue }
                guard let distance = try? lhs.distance(to: rhs), distance <= Double(config.maxDistance) else {
                    continue
                }
                union(i, j)
            }
        }

        // Collect components. `find` has already compressed the parent array, so
        // grouping by root is one pass.
        var components: [Int: [String]] = [:]
        for index in ordered.indices {
            components[find(index), default: []].append(ordered[index].identifier)
        }

        return components
            .values
            .filter { $0.count > 1 }
            .map { members in
                SimilarGroup(id: members.min() ?? "", members: members.sorted())
            }
            // Largest groups first: the group browser's most useful rows are the
            // ones with the most to choose between.
            .sorted {
                $0.members.count == $1.members.count
                    ? $0.id < $1.id
                    : $0.members.count > $1.members.count
            }
    }

    /// Splits an oversized component into chronological chunks.
    ///
    /// Applied after union-find so the *whole* event is still one finding — the
    /// caller can report "these 400 photos are one event" — while what is
    /// presented as a group stays browsable. Chunks are contiguous in capture
    /// order rather than arbitrarily truncated, so each chunk is still a run of
    /// neighbouring frames.
    static func split(_ group: SimilarGroup, maximumSize: Int,
                      dates: [String: Double]) -> [SimilarGroup] {
        guard group.members.count > maximumSize, maximumSize >= 2 else { return [group] }
        let ordered = group.members.sorted {
            (dates[$0] ?? 0, $0) < (dates[$1] ?? 0, $1)
        }
        var chunks: [SimilarGroup] = []
        var current: [String] = []
        for member in ordered {
            current.append(member)
            if current.count == maximumSize {
                chunks.append(SimilarGroup(id: current.min() ?? "", members: current))
                current = []
            }
        }
        if !current.isEmpty {
            chunks.append(SimilarGroup(id: current.min() ?? "", members: current))
        }
        return chunks
    }
}

// MARK: - Ranking

/// One group member with everything the ranker is allowed to look at.
struct RankingInput: Sendable, Equatable {
    let identifier: String
    /// Apple's `overallScore`, verbatim.
    let aesthetics: Float
    /// Vision's per-face capture qualities for this photo, largest face first.
    /// Empty when the photo has no faces, or has not been analysed for them yet.
    let faces: [FaceCapture]
    let date: Double?
    let favorite: Bool
}

/// How several faces in one photo are reduced to one number.
///
/// Not an average, and that is the point. Consider two frames of a group
/// photograph, with three people in each:
///
///     photo A          photo B
///     person 1  .91    person 1  .85
///     person 2  .88    person 2  .82
///     person 3  .24    person 3  .80
///
/// A mean rates A at .68 and B at .82, which reads as "A is a bit worse" — but
/// the truth is that one person was captured badly in A and everyone was captured
/// evenly in B. For a tool whose job is deciding which of several captures to
/// keep, the minimum is the honest aggregate: it is the person who will look
/// broken in the photo that actually survives.
///
/// The per-face results are retained either way; this only decides the summary.
enum FaceCaptureAggregator {
    /// Faces below `minimumAreaFraction` of the frame are ignored, so an
    /// incidental background face cannot drag the aggregate down.
    static func aggregate(_ faces: [FaceCapture],
                          minimumAreaFraction: Float) -> Float? {
        let significant = faces.filter { $0.areaFraction >= minimumAreaFraction }
        guard !significant.isEmpty else { return nil }
        return significant.map(\.score).min()
    }
}

/// PhotoCleaner's within-group ranking.
///
/// ## Why ranks, not raw scores
///
/// `overallScore` is measured over −0.9959…+1.0000 and face capture quality over
/// 0…1. They are different instruments measuring different things, and a formula
/// like `aesthetics * 0.6 + faceQuality * 0.25` silently asserts a relationship
/// between their units that does not exist. So each signal is first reduced to its
/// **rank within this group** — 1 for the best member, 0 for the worst — and the
/// ranks are blended. Rank is unit-free, so the blend means what it says: how far
/// up each signal places this photo *among its own competitors*.
///
/// ## Why the blend is capped at a weight, not a formula
///
/// The weight is a single tunable, and it is applied only to photos that have
/// face observations. A group with no faces ranks on aesthetics alone, which is
/// exactly what the aesthetics-only implementation already did.
///
/// ## What it must never do
///
/// Nothing here decides deletion. The highest Best Shot value is a better
/// candidate to *keep*, and the difference between rank 1 and rank 5 is not a
/// licence to remove anything. Deletion remains an explicit, confirmed human act
/// through the existing protected route.
enum BestShotRanker {
    /// Ranks a group's members. Returns the input order's identifiers best-first.
    ///
    /// `faceWeight` is ignored for a photo with no significant face, which is why
    /// the result is not a simple sort of one blended column.
    static func rank(_ members: [RankingInput],
                     settings: SimilarGroupSettings) -> [(identifier: String, bestShot: Double)] {
        let config = settings.validated()
        guard !members.isEmpty else { return [] }

        let aestheticsRanks = rankMap(members) { $0.aesthetics }
        let faceValues = members.map {
            FaceCaptureAggregator.aggregate($0.faces, minimumAreaFraction: config.minimumFaceAreaFraction)
        }
        // Face quality only ranks the photos that actually have a face signal. A
        // photo without one is absent from this map rather than ranked last, so a
        // landscape group is not dragged around by a portrait's absence.
        let withFaces = members.indices.filter { faceValues[$0] != nil }
        let faceRanks = withFaces.isEmpty ? [:] : rankMap(withFaces.map { faceValues[$0]! }) { $0 }

        let blended = members.indices.map { index -> (String, Double) in
            let aesthetics = Double(aestheticsRanks[index] ?? 0)
            guard let faceRank = faceRanks[index] else { return (members[index].identifier, aesthetics) }
            let weight = Double(config.faceWeight)
            return (members[index].identifier, (1 - weight) * aesthetics + weight * Double(faceRank))
        }

        return blended.sorted {
            $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1
        }
    }

    /// Maps each supplied value to its rank, best = 1.0, worst = 0.0.
    ///
    /// Ties share the average of the ranks they span, so two equally-scored photos
    /// are not separated by an arbitrary ordering of their identifiers. The result
    /// is a dictionary keyed by *position* in the values array, not by identifier,
    /// because callers rank different projections of the same group.
    private static func rankMap(_ values: [Float]) -> [Int: Float] {
        rankMap(values.indices.map { values[$0] }) { $0 }
    }

    private static func rankMap<T>(_ items: [T], _ score: (T) -> Float) -> [Int: Float] {
        guard !items.isEmpty else { return [:] }
        let sortedIndices = items.indices.sorted {
            score(items[$0]) == score(items[$1]) ? $0 < $1 : score(items[$0]) > score(items[$1])
        }
        var ranks: [Int: Float] = [:]
        var position = 0
        while position < sortedIndices.count {
            // Collect the whole run of equal scores so they can share a rank.
            var end = position
            let current = score(items[sortedIndices[position]])
            while end + 1 < sortedIndices.count, score(items[sortedIndices[end + 1]]) == current {
                end += 1
            }
            // Average rank across the tie, converted to 0-based: the best member
            // ranks 1.0 and the worst 0.0, and everything tied shares the midpoint.
            let average = (Double(position) + Double(end)) / 2 / Double(max(sortedIndices.count - 1, 1))
            for offset in position...end {
                ranks[sortedIndices[offset]] = Float(1 - average)
            }
            position = end + 1
        }
        return ranks
    }
}
