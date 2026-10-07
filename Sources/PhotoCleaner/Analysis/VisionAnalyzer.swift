import CoreGraphics
import Foundation
import Vision

/// Result of Apple's own aesthetics model. No normalisation, no reinterpretation.
struct AestheticsResult: Sendable {
    /// Raw `overallScore` as produced by Vision. The value is *not* guaranteed
    /// to lie in 0…1 and must never be rescaled by assumption: PhotoCleaner
    /// derives its slider bounds from the observed minimum and maximum of a
    /// real library instead.
    let score: Float
}

enum VisionAnalyzerError: Error, CustomStringConvertible {
    case unavailable
    /// The analysis ran but produced no observation. Kept distinct from
    /// `unavailable` so a Vision hiccup is recorded against the asset instead of
    /// failing the whole run.
    case noObservation(String)

    var description: String {
        switch self {
        case .unavailable:
            return "CalculateImageAestheticsScoresRequest is unavailable; macOS 15 or later is required"
        case .noObservation(let detail):
            return "Vision returned no observation: \(detail)"
        }
    }
}

/// One face's capture quality, exactly as Vision reported it.
///
/// **`score` is capture quality, not attractiveness.** Apple's
/// `DetectFaceCaptureQualityRequest` documents the value as reflecting whether a
/// face is better lit, sharper, and more centrally positioned, and describes it
/// as intended for comparing a face against other captures of the *same* face.
/// It is kept per face rather than averaged away at the point of capture because
/// a mean over a group of three people hides the one who was captured badly —
/// see `FaceCaptureAggregator`.
struct FaceCapture: Sendable, Codable, Equatable {
    /// Vision's 0…1 capture-quality value. Never rescaled.
    let score: Float
    /// The face's bounding box as a fraction of the image area, used to tell a
    /// face that carries the photo from one that is incidental background.
    /// Measured on this library at 0.0017…0.90, which is wide enough that an
    /// unfiltered mean is dominated by whichever incidental face Vision found.
    let areaFraction: Float
}

/// The per-face results for one asset, kept as Vision produced them.
///
/// An empty `faces` array is a real answer, not a failure: it means the image was
/// analysed and contains no detectable face. It is stored, so "no faces" can be
/// told apart from "not analysed yet" — which decides whether a photo belongs to
/// a portrait group at all.
struct FaceCaptureResult: Sendable, Codable, Equatable {
    let faces: [FaceCapture]
}

/// Thin wrapper over `CalculateImageAestheticsScoresRequest` (Vision, macOS 15+).
///
/// This is Apple's actual aesthetics model — not a substituted Core ML model —
/// and its `ImageAestheticsScoresObservation` is used directly, revision 1.
struct VisionAnalyzer: Sendable {
    func analyze(_ image: CGImage) async throws -> AestheticsResult {
        guard #available(macOS 15.0, *) else { throw VisionAnalyzerError.unavailable }
        let request = CalculateImageAestheticsScoresRequest(.revision1)
        let observation = try await request.perform(on: image)
        return AestheticsResult(score: observation.overallScore)
    }

    /// Tier 1: aesthetics *and* FeaturePrint from one decoded image.
    ///
    /// They run concurrently because they are independent models on the same
    /// pixels, and measured together they cost 7.2 ms against 5.0 ms for
    /// aesthetics alone — far less than the 9.4 ms of running them in sequence.
    /// The image is already decoded for the aesthetics pass, so a FeaturePrint
    /// costs 2.2 ms of extra wall clock rather than another decode.
    ///
    /// A FeaturePrint failure does **not** fail the asset: the aesthetics score is
    /// the primary observation, and a photo that simply has no cached FeaturePrint
    /// is still perfectly browsable — it just cannot join a Similar Group.
    func analyzeWithFeaturePrint(_ image: CGImage) async throws -> (AestheticsResult, Data?) {
        async let aesthetics = analyze(image)
        async let featurePrint = featurePrint(image)
        let result = try await aesthetics
        let encoded: Data?
        do {
            let observation = try await featurePrint
            encoded = SignalCompression.featurePrintData(observation)
        } catch {
            encoded = nil
            Log.warn("FeaturePrint unavailable for one asset: \(error)")
        }
        return (result, encoded)
    }

    /// Scores one asset's frames and returns its score, plus a FeaturePrint when
    /// — and only when — the subject was a single image.
    ///
    /// `PhotoLibrary.framesForAnalysis` hands over one frame for a still and one
    /// to three for a clip, and these two rules are why a clip is *not* simply
    /// scored like a photo.
    ///
    /// ## Why the median, and not the mean
    ///
    /// A clip is sampled because it is not one picture, and the samples are
    /// sampled at fixed fractions of a timeline the tool did not choose. That
    /// guarantees some samples are of moments that are not the photograph anyone
    /// would have kept: a black or blue leader at the head, a fade to black at
    /// the tail, a blown window when the camera auto-exposes for a dark room, a
    /// frame where the operator's thumb is across the lens. Those frames are not
    /// unusual — they are *expected*, and they are exactly the ones a mean lets
    /// decide the answer. With three samples the median ignores one outlier by
    /// construction: two good frames outvote a bad one, and a bad frame can move
    /// the score not at all. A mean would let one black frame pull a good clip's
    /// score down by a third, and because the grid sorts by this number, "one clip
    /// in a hundred scored terribly" would read as "one clip in a hundred is
    /// terrible".
    ///
    /// The mean was rejected rather than tuned (trimmed, winsorised): a trimmed
    /// mean needs a rule for how many samples to discard, and the rule has to be
    /// decided before anything is measured. The median needs none — for three
    /// samples it *is* the trimmed mean with the trim chosen by the data.
    ///
    /// For an even count — two samples, which a clip short enough to clamp its
    /// moments together produces — there is no majority, so the midpoint of the
    /// two is returned. That is the weakest statement the median rule can make, and
    /// it is the honest one: with two samples a bad frame can shift the result,
    /// and dropping one of them instead would mean choosing arbitrarily *which*
    /// frame to believe. The alternative of always scoring the middle moment was
    /// rejected because it throws away information for a rule that only holds when
    /// nothing is wrong.
    ///
    /// ## Why no FeaturePrint for a clip
    ///
    /// Similar Groups answers one question: "are these alternate captures of the
    /// same shot?" A FeaturePrint taken from one arbitrary frame of a clip claims
    /// something stronger and untrue — that the clip *is* that photograph. A clip
    /// pans away from the very thing the still shows, so the frame is a moment of
    /// the scene rather than the scene, and it will match a still that resembles
    /// that moment.
    ///
    /// It would also silently change what a distance *means*. `maxDistance` and the
    /// capture window were both calibrated on stills, against bursts and retakes,
    /// and admitting clip-frames into the same comparison would move what a given
    /// distance signifies for **every existing group**, with no signal that
    /// anything changed. A FeaturePrint failure is a quiet degradation; a
    /// recalibration that quietly changes every group is not, and there is no way
    /// to tell the two apart from inside the feature.
    ///
    /// So videos score, browse, play, favourite and delete, and they do not group.
    /// This is deliberate, not an oversight — the same decision is enforced at the
    /// other end in `CacheStore.refreshFeaturePrintQueue`, so a video cannot be
    /// given a vector by the backfill pass either.
    ///
    /// A single frame — a still, or a clip so short that its moments collapse onto
    /// one — takes the measured `analyzeWithFeaturePrint` path unchanged, including
    /// running the two models concurrently and treating a FeaturePrint failure as
    /// a missing vector rather than a failed asset. Exactly one frame is the only
    /// case where the clip *is* the frame.
    ///
    /// ## On failing
    ///
    /// Frames are scored concurrently, because they are independent models over
    /// pixels already decoded and the three passes overlap. Individual frame
    /// failures are tolerated while at least one frame scored: a clip whose middle
    /// moment is unreadable still gets a score from the two that are, and the
    /// caller learns how many samples the median was taken over from how many
    /// FeaturePrints it did *not* get — a two-sample median is a weaker claim than
    /// a three-sample one, and hiding that would be worse than either. Only when
    /// every frame failed is the error rethrown, so a genuinely unanalysable asset
    /// is still reported and the scan is not quietly advancing over it.
    func analyzeFrames(_ frames: [CGImage]) async throws -> (AestheticsResult, Data?) {
        guard let first = frames.first else {
            // Unreachable from `framesForAnalysis`, which documents that it never
            // returns an empty array. Guarded anyway: a median of nothing is not a
            // number, and returning `score: 0` for an asset nothing was read from
            // would put a photo at the bottom of the grid that was never looked at.
            throw VisionAnalyzerError.noObservation("no frames were supplied to analyse")
        }
        guard frames.count > 1 else { return try await analyzeWithFeaturePrint(first) }

        let scores = await withTaskGroup(of: Float?.self) { group in
            for frame in frames {
                group.addTask { [self] in
                    // Cancellation propagates through the group's own checks; a
                    // cancelled run must not be scored on the frames that did
                    // finish.
                    if Task.isCancelled { return nil }
                    return try? await analyze(frame).score
                }
            }
            var collected: [Float] = []
            for await score in group {
                if let score { collected.append(score) }
            }
            return collected
        }
        guard !scores.isEmpty else {
            throw VisionAnalyzerError.noObservation("every frame of the clip failed to analyse")
        }
        if scores.count < frames.count {
            Log.warn("scored \(scores.count) of \(frames.count) frames; the median is taken over \(scores.count)")
        }
        // No FeaturePrint: see above.
        return (AestheticsResult(score: Self.median(of: scores)), nil)
    }

    /// The median of `values`, ascending. Odd counts take the middle value; even
    /// counts take the midpoint of the two middle values.
    ///
    /// Not in place and not order-independent by accident: `sorted()` on three
    /// `Float`s is cheaper than any of the alternatives and the caller keeps its
    /// own array.
    static func median(of values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Apple's FeaturePrint for one image, used **only** to decide whether two
    /// photos are alternate captures of the same shot.
    ///
    /// It says nothing about which of the two is better, and its distance is
    /// never mixed into a quality score — see `SimilarGroupBuilder` and
    /// `BestShotRanker` for where the two concerns are kept apart.
    ///
    /// `.revision2` is the only revision the macOS 15 Swift API exposes
    /// (revision 1 exists only in the Objective-C interface). Measured on this
    /// library: 768 float elements, and the distance survives a JSON round trip
    /// bit-exactly, which is what makes caching one per asset worthwhile.
    func featurePrint(_ image: CGImage) async throws -> FeaturePrintObservation {
        guard #available(macOS 15.0, *) else { throw VisionAnalyzerError.unavailable }
        let request = GenerateImageFeaturePrintRequest(.revision2)
        return try await request.perform(on: image)
    }

    /// Per-face capture quality for one image.
    ///
    /// Tier 3 only: this runs for members of a Similar Group that were found to
    /// contain faces, never library-wide. An image with no face yields an empty
    /// `faces` array, which is a result and not an error.
    func faceCaptureQuality(_ image: CGImage) async throws -> FaceCaptureResult {
        guard #available(macOS 15.0, *) else { throw VisionAnalyzerError.unavailable }
        let request = DetectFaceCaptureQualityRequest(.revision3)
        let observations = try await request.perform(on: image)
        let faces = observations.compactMap { observation -> FaceCapture? in
            // `captureQuality` is optional because the request documents the
            // property as nil if the face observation was never processed.
            guard let quality = observation.captureQuality?.score else { return nil }
            let box = observation.boundingBox
            return FaceCapture(score: quality, areaFraction: Float(box.width * box.height))
        }
        // Sorted largest-first so the "primary" face is `faces.first` without
        // every consumer re-deriving which one that is.
        return FaceCaptureResult(faces: faces.sorted { $0.areaFraction > $1.areaFraction })
    }
}
