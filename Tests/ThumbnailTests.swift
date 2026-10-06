import Foundation

// Thumbnail size snapping.
//
// The grid asks for a pixel width and gets one of four rungs back. The decision is
// a pure function of the requested width, so it is pinned directly rather than
// inferred from a JPEG: the bytes a tile carries cannot be measured without a real
// PHAsset, and a test that could not see the choice could not protect it.
//
// The rule that matters is the tie. A requested 192 sits exactly between the 128
// and 256 rungs; either is defensible on paper, but only one of them is free —
// rendering at 128 when 128 was asked for costs half the bytes of the 256
// rendition and looks identical at tile density, so a tie that resolves upwards is
// an upscale bought for nothing. The tie-break is written out explicitly in
// `Router.thumbnailPixelSize` for exactly this reason: `min(by:)`'s choice among
// equal elements is a property of the standard library's reduction order, not
// something a routing decision should be resting on.

func registerThumbnailTests() {
    let suite = "thumbnail size ladder"

    Registry.shared.add(suite: suite, TestCase(name: "an exact rung is served as itself", knownBug: nil) {
        for size in [128, 256, 384, 512] {
            checkEqual(Router.thumbnailPixelSize(for: size), size, "size=\(size)")
        }
        // The default when `?size=` is absent or unparseable.
        checkEqual(Router.thumbnailPixelSize(for: 256), 256, "the default tile size")
    })

    Registry.shared.add(suite: suite, TestCase(name: "a request between rungs snaps to the nearest", knownBug: nil) {
        // Unambiguous midpoints: 192 is 64 from both 128 and 256, 320 is 64 from
        // both 256 and 384 — see the tie-break case below for which one wins.
        for (requested, expected) in [(64, 128), (100, 128), (200, 256), (260, 256),
                                      (300, 256), (400, 384), (500, 512), (1024, 512)] {
            checkEqual(Router.thumbnailPixelSize(for: requested), expected, "size=\(requested) is equidistant-free")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a tie breaks towards the smaller rung, never up", knownBug: nil) {
        // Every equidistant request on the ladder, asserted as a set so a new rung
        // would show up as a missing case rather than pass unnoticed.
        let ties: [(Int, Int)] = [(192, 128), (320, 256), (448, 384)]
        for (requested, expected) in ties {
            checkEqual(Router.thumbnailPixelSize(for: requested), expected,
                       "size=\(requested) is exactly between two rungs")
        }
        // The general statement, so the property is what is pinned rather than the
        // three numbers: the rung served is a *nearest* rung, and when two rungs
        // are equally near it is the smaller of them. Nothing else about the
        // mapping is left to chance.
        let ladder = [128, 256, 384, 512]
        for requested in 64...1024 {
            let served = Router.thumbnailPixelSize(for: requested)
            check(ladder.contains(served), "size=\(requested) snapped onto the ladder, got \(served)")
            let nearest = ladder.map { abs($0 - requested) }.min() ?? 0
            checkEqual(abs(served - requested), nearest,
                       "size=\(requested): \(served) is the nearest rung")
            check(!ladder.contains { $0 < served && abs($0 - requested) == nearest },
                  "size=\(requested): a tie between \(served) and a smaller rung went to the smaller one")
        }
    })

    Registry.shared.add(suite: suite, TestCase(name: "a request outside the ladder clamps to its end", knownBug: nil) {
        // `queryInt` clamps `?size=` into 64…1024 before this is called, so the
        // function only ever sees that range from the route; the endpoints are what
        // matter — a small request must never be served at 512.
        checkEqual(Router.thumbnailPixelSize(for: 64), 128, "the smallest possible request")
        checkEqual(Router.thumbnailPixelSize(for: 1024), 512, "the largest possible request")
        check(Router.thumbnailPixelSize(for: 65) <= 128, "just above the floor still gets the smallest rung")
        check(Router.thumbnailPixelSize(for: 1023) == 512, "just below the ceiling gets the largest rung")
    })
}