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
