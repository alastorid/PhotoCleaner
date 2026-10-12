import CoreGraphics
import Foundation
import Vision

/// Relative detail in a face's own pixels, separate from Vision's
/// composition/capture score. All faces are compared at the same scale;
/// size and position in the frame are not weights.
///
/// Ported from WaifuFinder's `FaceDefinition`, which measures the same
/// quantity on a video frame's native pixels. PhotoCleaner hands its
/// analysis frame — the same ≤1024 px image every other Vision pass in
/// this app already runs on — so the score is a *relative* estimate at
/// one common scale: every photo's face is measured from the same
/// resolution, which is the contract the contrast normalisation below
/// already makes the comparison rest on. A higher score means more
/// native detail inside the face, not a bigger or better-placed face.
///
/// Two instruments, one per face, both derived from the same initial
/// detection:
///
/// 1. Contrast-normalised Laplacian energy of a 64 px face interior.
///    Cropping before resizing preserves detail a whole-frame pass
///    loses. Mosaic boundaries have high Laplacian energy but contain
///    no usable facial detail, so the energy is discounted by the
///    native flat-block coverage of the crop.
/// 2. Landmark placement uncertainty. Sharp pixels must accompany
///    readable facial features: a partial-face false detection or
///    pixelated eyes can otherwise outrank a genuinely clear face. The
///    discount is bounded, so a well-located face is not penalised
///    into nothing.
///
/// This remains a heuristic; noise and oversharpening can still score
/// highly.
enum FaceDefinition {
    /// Landmark placement uncertainty verifies that sharp pixels belong
    /// to readable facial features: a partial-face false detection or
    /// pixelated eyes can otherwise outrank a genuinely clear face.
    ///
    /// Precision estimates express landmark placement uncertainty, not
    /// capture quality or attractiveness. A bounded inverse-error
    /// penalty keeps sharp block boundaries from compensating for
    /// poorly located facial features.
    static func verifiedScore(detail: Float, precisionEstimates: [Float]?) -> Float? {
        guard let estimates = precisionEstimates, !estimates.isEmpty,
              estimates.allSatisfy({ $0.isFinite && $0 >= 0 }), detail.isFinite else { return nil }
        let error = estimates.reduce(0.0) { $0 + Double($1) } / Double(estimates.count)
        let normalizedError = error / 0.02
        return Float(Double(max(0, min(1, detail))) / (1 + normalizedError * normalizedError))
    }

    /// Contrast-normalized Laplacian energy of a 64px face interior.
    ///
    /// No relative-area filter. The tiny absolute floor only avoids
    /// trying to measure texture from a few pixels; tolerate subpixel
    /// box rounding at the image edge without admitting materially
    /// clipped faces.
    static func score(_ image: CGImage, face: CGRect) -> Float? {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard face.width >= 8, face.height >= 8, extent.insetBy(dx: -0.5, dy: -0.5).contains(face),
              let crop = image.cropping(to: face.intersection(extent).insetBy(dx: face.width * 0.1, dy: face.height * 0.1).integral) else { return nil }
        return scoreInterior(crop)
    }

    private static func scoreInterior(_ crop: CGImage) -> Float {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return 0 }
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
        var contrast = 0.0, detail = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let index = y * side + x
                let centre = Double(pixels[index])
                contrast += (centre - mean) * (centre - mean)
                let laplacian = 4 * centre - Double(pixels[index - 1]) - Double(pixels[index + 1])
                    - Double(pixels[index - side]) - Double(pixels[index + side])
                detail += laplacian * laplacian
            }
        }
        guard contrast > Double(side * side) else { return 0 }
        let energy = detail / contrast
        let coverage = nativeDetailCoverage(crop)
        // A moderate reliability penalty suppresses block-edge energy while
        // retaining the normalized sharpness comparison across face sizes.
        return Float(energy / (energy + 0.1) * coverage * coverage)
    }

    /// Measure before resizing, which would interpolate mosaic blocks into
    /// apparently textured pixels. Near-constant 2×2 patches indicate missing
    /// native detail; the tolerance accommodates small compression fluctuations.
    private static func nativeDetailCoverage(_ crop: CGImage) -> Double {
        let width = crop.width, height = crop.height
        guard width > 1, height > 1 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return 0 }
        var flat = 0
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let i = y * width + x
                let a = pixels[i], b = pixels[i + 1], c = pixels[i + width], d = pixels[i + width + 1]
                if Int(max(a, b, c, d)) - Int(min(a, b, c, d)) <= 3 { flat += 1 }
            }
        }
        return 1 - Double(flat) / Double((width - 1) * (height - 1))
    }

    /// The best face's definition score, or `nil` when no face could be
    /// measured.
    ///
    /// Reuses the initial face detections from `DetectFaceCaptureQualityRequest`,
    /// which the analysis pass already runs: a landmark refinement runs only
    /// when a face was found, and its failure is not an asset failure —
    /// definition is an optional signal, and a photo that cannot be
    /// refined keeps its capture quality and its grid place.
    ///
    /// The largest score wins: a photo with one sharp face and one blurry
    /// face is a photo with a sharp face in it, and the filter asks about
    /// the best face the photo has, not the average of every face.
    static func evaluate(_ image: CGImage, observations: [FaceObservation]) async throws -> Float? {
        guard !observations.isEmpty else { return nil }
        var request = DetectFaceLandmarksRequest(.revision3)
        request.inputFaceObservations = observations
        let refined: [FaceObservation]
        do {
            refined = try await request.perform(on: image)
        } catch {
            try Task.checkCancellation()
            // Definition is optional; failure must not discard the asset.
            return nil
        }
        let size = CGSize(width: image.width, height: image.height)
        var best: Float?
        for face in refined {
            try Task.checkCancellation()
            let rect = face.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            if let detail = score(image, face: rect),
               let verified = verifiedScore(detail: detail,
                   precisionEstimates: face.landmarks?.allPoints.precisionEstimatesPerPoint) {
                best = max(best ?? verified, verified)
            }
        }
        return best
    }
}
