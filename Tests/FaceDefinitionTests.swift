import CoreGraphics
import CoreImage
import Foundation
import ImageIO

// Algorithm-level checks for `FaceDefinition`, ported from
// WaifuFinder's `Tests/FaceDefinitionTests.swift`. The waifu suite
// also covered its own pipeline — native-frame sampling, group caps,
// arrangement orderings, video rotation — none of which exist in
// PhotoCleaner's architecture; what is shared is the instrument, and
// that is what these exercise: the score's response to real pixels
// and to landmark evidence, and its refusal to invent a number from
// nothing.

private func definitionPattern(face: CGRect, blur: Double = 0) throws -> CGImage {
    let context = CGContext(data: nil, width: 384, height: 256, bitsPerComponent: 8, bytesPerRow: 1536,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: 256); context.scaleBy(x: 1, y: -1)
    context.setFillColor(gray: 0.3, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 384, height: 256))
    context.setFillColor(gray: 0.7, alpha: 1); context.fill(face)
    context.setFillColor(gray: 0.1, alpha: 1)
    for offset in [0.25, 0.65] {
        context.fillEllipse(in: CGRect(x: face.minX + face.width * offset, y: face.minY + face.height * 0.3,
                                      width: face.width * 0.1, height: face.height * 0.12))
    }
    context.fill(CGRect(x: face.minX + face.width * 0.3, y: face.minY + face.height * 0.7,
                        width: face.width * 0.4, height: face.height * 0.04))
    for index in 0..<6 {
        context.fill(CGRect(x: face.minX + face.width * (0.2 + Double(index) * 0.1), y: face.minY + face.height * 0.15,
                            width: face.width * 0.02, height: face.height * 0.12))
    }
    let original = context.makeImage()!
    if blur == 0 { return original }
    let image = CIImage(cgImage: original).clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
    return CIContext().createCGImage(image, from: CGRect(x: 0, y: 0, width: 384, height: 256))!
}

/// A flat gray image, for the cases where the answer must be "no
/// detail" rather than a number.
private func flatImage(width: Int, height: Int, gray: Double) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: gray, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func registerFaceDefinitionTests() {
    let suite = "Face definition"
    Registry.shared.add(suite: suite, TestCase(name: "malformed definition bounds are refused rather than treated as absent", knownBug: nil) {
        let fixture = try await Fixture.make("definition-invalid-range")
        try await fixture.seed([.init(id: "a", score: 0.5, date: 1)])
        let invalid: [[String: String]] = [
            ["faceDefLo": "abc", "faceDefHi": "xyz"],
            ["faceDefLo": "abc"], ["faceDefHi": "xyz"],
            ["faceDefLo": "", "faceDefHi": ""],
            ["faceDefLo": "abc", "faceDefHi": "0.8"],
            ["faceDefLo": "0.2", "faceDefHi": "xyz"],
            ["faceDefLo": "0.2"], ["faceDefHi": "0.8"],
            ["faceDefLo": "nan", "faceDefHi": "0.8"],
            ["faceDefLo": "0.2", "faceDefHi": "inf"],
            ["faceDefLo": "0.8", "faceDefHi": "0.2"],
        ]
        for query in invalid {
            let response = await fixture.router.reply(Req.get("/api/photos", query: query))
            checkEqual(response.status, 400, "invalid range \(query) must not widen the grid")
        }
    })
    Registry.shared.add(suite: suite, TestCase(name: "valid definition ranges filter inclusively and absent bounds leave the filter off", knownBug: nil) {
        let fixture = try await Fixture.make("definition-valid-range")
        try await fixture.seed([
            .init(id: "low", score: 0.5, date: 1),
            .init(id: "high", score: 0.5, date: 2),
            .init(id: "no-face", score: 0.5, date: 3),
        ])
        try await fixture.cache.record(score: 0.5, faceDefinition: 0.2, for: "low")
        try await fixture.cache.record(score: 0.5, faceDefinition: 0.8, for: "high")
        let off = await fixture.router.reply(Req.get("/api/photos"))
        checkEqual(off.status, 200, "absent bounds are accepted")
        checkEqual(off.int("total"), 3, "filter off includes unmeasured faces")
        for (lo, hi, expected) in [("0.2", "0.8", ["high", "low"]), ("0.8", "0.8", ["high"])] {
            let response = await fixture.router.reply(Req.get("/api/photos", query: ["faceDefLo": lo, "faceDefHi": hi]))
            checkEqual(response.status, 200, "valid range is accepted")
            checkEqual(response.rows().map(\.id), expected, "bounds are inclusive and exclude missing definitions")
            let echoed = response.side("filter").side("faceDefinition").json
            checkEqual((echoed["lower"] as? NSNumber)?.floatValue, Float(lo), "lower bound is echoed")
            checkEqual((echoed["upper"] as? NSNumber)?.floatValue, Float(hi), "upper bound is echoed")
        }
    })
    Registry.shared.add(suite: suite, TestCase(name: "small sharp edge face beats large blurred centre face", knownBug: nil) {
        let small = CGRect(x: 0, y: 100, width: 40, height: 48)
        let large = CGRect(x: 120, y: 50, width: 120, height: 144)
        guard let sharp = checkNotNil(FaceDefinition.score(try definitionPattern(face: small), face: small), "small native crop scores"),
              let blurred = checkNotNil(FaceDefinition.score(try definitionPattern(face: large, blur: 6), face: large), "large crop scores") else { return }
        check(sharp > blurred * 3 && sharp > 0, "size/position must not outweigh detail: sharp \(sharp), blurred \(blurred)")
        let central = CGRect(x: 172, y: 100, width: 40, height: 48)
        guard let moved = FaceDefinition.score(try definitionPattern(face: central), face: central) else { check(false, "central crop scores"); return }
        check(abs(Double(moved) - Double(sharp)) < 0.001,
              "translation does not change definition: expected \(sharp), got \(moved)")
    })
    Registry.shared.add(suite: suite, TestCase(name: "flat, tiny and clipped regions do not masquerade as detailed faces", knownBug: nil) {
        let image = flatImage(width: 128, height: 128, gray: 0.5)
        checkEqual(FaceDefinition.score(image, face: CGRect(x: 0, y: 0, width: 64, height: 64)), 0, "flat crop has no detail")
        checkNil(FaceDefinition.score(image, face: CGRect(x: 0, y: 0, width: 3, height: 3)), "insufficient native samples")
        checkNotNil(FaceDefinition.score(image, face: CGRect(x: 0, y: 0, width: 16, height: 16)), "small faces are not excluded by subject area")
        checkNotNil(FaceDefinition.score(image, face: CGRect(x: -0.00001, y: 0, width: 64, height: 64)), "subpixel edge rounding stays selectable")
        checkNil(FaceDefinition.score(image, face: CGRect(x: -5, y: 0, width: 64, height: 64)), "clipped face is not treated as fully visible")
    })
    Registry.shared.add(suite: suite, TestCase(name: "pixelation boundaries do not outrank continuous native detail", knownBug: nil) {
        func texture(block: Int) -> CGImage {
            let side = 64
            var pixels = [UInt8](repeating: 0, count: side * side)
            for y in 0..<side {
                for x in 0..<side {
                    let a = Double(x / block * block), b = Double(y / block * block)
                    let value = 120 + 45 * sin(a * 0.16) * cos(b * 0.14) + 12 * sin(a * 0.42 + b * 0.23)
                    pixels[y * side + x] = UInt8(max(0, min(255, Int(value))))
                }
            }
            return pixels.withUnsafeMutableBytes { bytes in
                CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                          bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
            }
        }
        let face = CGRect(x: 0, y: 0, width: 64, height: 64)
        let continuous = FaceDefinition.score(texture(block: 1), face: face)!
        for block in [6, 8] {
            let pixelated = FaceDefinition.score(texture(block: block), face: face)!
            check(continuous > pixelated * 1.5, "continuous features beat sharp \(block)-pixel mosaic edges")
        }
    })
    Registry.shared.add(suite: suite, TestCase(name: "readable facial features beat sharper uncertain face detections", knownBug: nil) {
        let clear = FaceDefinition.verifiedScore(detail: 0.4, precisionEstimates: [0.012, 0.016])!
        let falsePositive = FaceDefinition.verifiedScore(detail: 0.8, precisionEstimates: [0.028, 0.040])!
        check(clear > falsePositive, "sharp false detections or mosaic edges must outweigh reliable facial features")
        let softened = FaceDefinition.verifiedScore(detail: 0.2, precisionEstimates: [0.012, 0.016])!
        check(clear > softened, "texture still distinguishes equally recognizable faces")
        let uncertain = FaceDefinition.verifiedScore(detail: 0.4, precisionEstimates: [0.025, 0.035])!
        check(clear > uncertain, "uncertain facial features reduce definition at equal sharpness")
    })
    Registry.shared.add(suite: suite, TestCase(name: "missing or invalid landmark evidence cannot fabricate definition", knownBug: nil) {
        for estimates: [Float]? in [nil, [], [.nan], [.infinity], [-0.01]] {
            checkNil(FaceDefinition.verifiedScore(detail: 0.8, precisionEstimates: estimates), "invalid evidence stays absent")
        }
        checkNil(FaceDefinition.verifiedScore(detail: .nan, precisionEstimates: [0.01]), "invalid texture stays absent")
        checkEqual(FaceDefinition.verifiedScore(detail: 0, precisionEstimates: [0.01]), 0, "well-located flat pixels are still not detailed")
    })
}
