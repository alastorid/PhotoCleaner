import AppKit
import Foundation

// The app icon.
//
// The icon is drawn by `tools/make-icon.swift` rather than checked in, so nothing
// in `Sources/` knows what it looks like and the suite would otherwise be silent
// about the one thing every user sees first. These cases render the real drawing
// code and measure the result, which is the only way to hold an image to a
// number.
//
// What is pinned here, and why each one is not a change-detector:
//
//   * The body is **neutral grey**, and a neutral icon has no hue to separate
//     itself from the desktop with, so the ramp has to clear the desktop's
//     *luminance*. The whole icon sits on the wallpaper, so that is a min over
//     both ramp ends and every wallpaper — not light-end-on-light. Getting that
//     pairing wrong is the single easiest mistake in this file: it scores a
//     graphite body's dark end at 12.94:1 on a light desktop and calls the
//     ramp fine, while the light end is invisible at 1.09:1 on a dark one.
//     Both obvious neutrals fail the real min (graphite 1.09:1, white 1.00:1);
//     the shipped ramp's worst corner is 1.85:1.
//   * The 3×3 tile grid stays **countable at 32px**. Not 16px, because it is not
//     reliably countable there at any gap in the range worth using — see the case
//     for the measurement that pinned the choice.
//   * The body stays grey rather than taking a hue, within a wide bound.
//
// The numeric floors here are deliberately loose. Each was set by sweeping the
// parameter it guards and finding where the thing it guards actually breaks, so
// they catch a ramp or a grid that has stopped working without failing over a
// few units of somebody's taste. Where a measurement turned out *not* to support
// an assumption — the tile gap, the opacity run — the case says so rather than
// asserting a number that measurement does not back.
//
// What is not covered: the exact hues (a design decision; asserting them would
// make this a change-detector), and `.icns` packaging, which is `iconutil`'s and
// runs on every `build.sh`.

func registerIconTests() {
    registerIconBodyTests()
    registerIconMarkTests()
}

// MARK: - Colour maths

/// A colour as 8-bit sRGB, which is what both the drawing and the desktop are.
private struct RGB: Equatable {
    let r: Double
    let g: Double
    let b: Double

    init(hex: String) {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        func channel(_ offset: Int) -> Double {
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: 2)
            return Double(Int(text[start..<end], radix: 16) ?? 0) / 255.0
        }
        r = channel(0)
        g = channel(2)
        b = channel(4)
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// WCAG relative luminance.
    private func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    var luminance: Double {
        0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, 1…21.
    func contrast(against other: RGB) -> Double {
        let a = luminance
        let b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour composited over `other` at `alpha`, which is exactly what a
    /// white mark at a partial opacity resolves to.
    func over(_ other: RGB, alpha: Double) -> RGB {
        RGB(r: alpha * r + (1 - alpha) * other.r,
            g: alpha * g + (1 - alpha) * other.g,
            b: alpha * b + (1 - alpha) * other.b)
    }
}

// MARK: - Rendering the real icon

/// The icon drawing code, run for real.
///
/// `tools/make-icon.swift` is a script with top-level code, so it cannot be
/// imported into this binary; it is invoked and the PNG it writes is measured
/// instead. That is the stronger assertion anyway — it measures the artifact
/// rather than a reimplementation of it.
private enum IconRenderer {
    static let canvas = 1024.0

    /// The wallpapers the icon has to survive on: the light and dark greys macOS
    /// ships, plus the mid grey between them that a wallpaper picker offers.
    static let lightWallpapers = [RGB(hex: "#f2f2f4"), RGB(hex: "#e9e9ec"), RGB(hex: "#d8d8dd")]
    static let darkWallpapers = [RGB(hex: "#1c1c1e"), RGB(hex: "#2c2c2e"), RGB(hex: "#141416")]

    /// Below this the icon's edge stops being distinguishable from the desktop,
    /// which is the failure this suite exists to catch.
    ///
    /// This is a modest floor, not a WCAG figure: it is about whether an edge is
    /// *visible*, not about reading text. It is calibrated to the measured spread
    /// rather than picked — the ramp in use bottoms out at 1.85:1 across these
    /// wallpapers and both obvious neutrals fall below the floor (graphite
    /// 1.09:1, white 1.00:1), so anything in that gap changes the verdict.
    static let minimumEdgeSeparation = 1.25

    static func repositoryRoot() -> URL? {
        // #filePath is <root>/Tests/IconTests.swift.
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `xcrun --find swift`, which is how `build.sh` resolves its compiler and
    /// therefore the same one the icon was drawn with.
    private static func resolveSwiftCompiler() -> String? {
        let find = Process()
        find.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        find.arguments = ["--find", "swift"]
        let pipe = Pipe()
        find.standardOutput = pipe
        guard (try? find.run()) != nil else { return nil }
        find.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard find.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }

    /// A render, or the reason it could not be produced. `SkipTest` carries the
    /// reason; a nil render with no reason is a bug in here, not the environment.
    static func render(pixels: Int) throws -> [[RGB]] {
        guard let root = repositoryRoot() else {
            throw SkipTest(reason: "could not locate the repository root from #filePath")
        }
        let tool = root.appendingPathComponent("tools/make-icon.swift")
        guard FileManager.default.fileExists(atPath: tool.path) else {
            throw SkipTest(reason: "tools/make-icon.swift is not where this suite expects it")
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photocleaner-icon-tests-\(getpid())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let icns = scratch.appendingPathComponent("AppIcon.icns")
        let iconset = scratch.appendingPathComponent("AppIcon.iconset")

        func run(_ launch: URL, _ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = launch
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }

        // Resolve the compiler the way build.sh does, so a Swift on PATH cannot
        // be paired with a different SDK and fail this suite spuriously.
        guard let compiler = resolveSwiftCompiler() else {
            throw SkipTest(reason: "xcrun could not resolve a swift compiler")
        }

        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        guard run(URL(fileURLWithPath: compiler), [tool.path, icns.path]) else {
            throw SkipTest(reason: "make-icon.swift exited non-zero (the icon tool draws the icon)")
        }
        // `-c iconset` is the *input* format; asking for `icns` here is the error
        // iconutil reports when the output extension does not match.
        guard run(URL(fileURLWithPath: "/usr/bin/iconutil"),
                  ["-c", "iconset", icns.path, "-o", iconset.path])
        else {
            throw SkipTest(reason: "iconutil exited non-zero")
        }

        // The representation is named, and the argument is honoured: the body
        // can only be measured at a size with pixels to spare, and the mark only
        // at the size the Dock actually shows it. Reading one fixed file for both
        // is what made the body checks meaningless — at 16px the corner band this
        // suite samples lies inside the squircle's antialiased edge, so every
        // sample reads as transparent.
        let representation: String
        switch pixels {
        case ...32: representation = "icon_32x32.png"
        case ...128: representation = "icon_128x128.png"
        default: representation = "icon_512x512.png"
        }

        guard let data = try? Data(contentsOf: iconset.appendingPathComponent(representation)),
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw SkipTest(reason: "the generated iconset has no readable \(representation)")
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            throw SkipTest(reason: "\(representation) decoded to an empty image")
        }
        // A flat byte buffer rather than `[[RGB]]`: a Swift array of structs can carry
        // references, so CoreGraphics cannot be handed a pointer to one. The
        // context borrows the buffer's memory, so the draw has to happen
        // *inside* the `withUnsafeMutableBytes` scope — a context built in the
        // closure and used after it would be reading freed memory, and Core
        // Graphics does not check.
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        // bytesPerRow is stated rather than left at 0: 0 means "you pick, from a
        // buffer CoreGraphics allocated", and this buffer is ours, so the call
        // fails outright.
        let rowBytes = width * 4
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: rowBytes,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw SkipTest(reason: "could not create a bitmap context to read the icon back")
        }

        var samples = [[RGB]](repeating: [], count: width)
        for x in 0..<width {
            var row = [RGB]()
            row.reserveCapacity(height)
            for y in 0..<height {
                let offset = (y * width + x) * 4
                // premultipliedLast: the icon is opaque, so the channels are
                // already what they look like.
                row.append(RGB(r: Double(bytes[offset]) / 255.0,
                               g: Double(bytes[offset + 1]) / 255.0,
                               b: Double(bytes[offset + 2]) / 255.0))
            }
            samples[x] = row
        }
        return samples
    }

    /// The brightest and darkest **body** colour, which are the two ends of the ramp
    /// and the two things that have to separate from a wallpaper. Nil when no body
    /// was found, which is itself the failure worth reporting.
    ///
    /// Read from strips along the top and bottom edges, scanning their whole
    /// width. Three deliberate choices, each of which was a bug first:
    ///
    ///   * **Not the whole image.** The mark is white, so a whole-image maximum is
    ///     a tile rather than the body, and the dark-desktop check then passes no
    ///     matter what the ramp is. The subject is the *edge*, so the edge is what
    ///     gets measured.
    ///   * **Not the corners.** The squircle's corner radius is 22.4% of the side,
    ///     which puts the corner arc's centre inside a 6%…12% corner box. Sampling
    ///     there returns background, not body, and the ramp reads darker than it
    ///     is. Along the top and bottom edges the boundary is straight, so the
    ///     whole width is body.
    ///   * **A strip, not the very edge.** 6% in from the boundary is clear of the
    ///     antialiasing and of the white hairline the body is stroked with.
    ///   * **The middle 50% of the width, not all of it.** The corner radius is
    ///     22.4% of the side, so outside 25%…75% the top and bottom edges are cut
    ///     away and there is no body there at all. Those pixels are stored as
    ///     premultiplied transparent black, and reading them as colour reports a
    ///     body far darker than any in the ramp — which is how the dark-desktop
    ///     check came to measure 1.14:1 for a ramp whose dark end really scores
    ///     1.85:1.
    ///
    /// The 160deg axis puts the light end top-left and the dark end bottom-right,
    /// so scanning both edges' full width finds both.
    ///
    /// Requires 128px or more; below that the strip is a few pixels of antialiasing
    /// and every sample reads as background. The caller measures the body at 512
    /// and the mark at 32, for that reason.
    static func bodyExtremes(in samples: [[RGB]]) -> (lightest: RGB, darkest: RGB)? {
        let side = samples.count
        guard side >= 128, let row = samples.first, row.count == side else { return nil }
        let lower = Int(Double(side) * 0.06)
        let upper = Int(Double(side) * 0.12)
        guard upper > lower else { return nil }

        var lightest: RGB?
        var darkest: RGB?
        var sawAny = false

        func consider(_ pixel: RGB) {
            if lightest == nil || pixel.luminance > lightest!.luminance { lightest = pixel }
            if darkest == nil || pixel.luminance < darkest!.luminance { darkest = pixel }
            sawAny = true
        }

        // `samples` is indexed [x][y]; rows run bottom-up from the bitmap, so
        // `lower` is the strip just inside the bottom edge and `side - 1 - upper`
        // the strip just inside the top.
        let bottom = lower..<upper
        let top = (side - 1 - upper)..<(side - 1 - lower)
        let inset = Int(Double(side) * 0.25)
        guard side - inset > inset else { return nil }
        for x in inset..<(side - inset) {
            for y in bottom { consider(samples[x][y]) }
            for y in top { consider(samples[x][y]) }
        }

        guard sawAny, let lightest, let darkest else { return nil }
        return (lightest, darkest)
    }
}

// MARK: - The body separates from the desktop

private func registerIconBodyTests() {
    let suite = "icon: body"

    Registry.shared.add(suite: suite, TestCase(name: "renders at all", knownBug: nil) {
        let samples = try IconRenderer.render(pixels: 512)
        check(!samples.isEmpty && !samples[0].isEmpty, "the icon tool produced no pixels")
    })

    // The body sits on the wallpaper over its whole area, so *every* part of it has
    // to separate from *every* wallpaper it might land on — not each end against
    // only the wallpaper of its own polarity. Pairing them that way is what let a
    // graphite body pass here: measured against a light desktop its dark end
    // scores 12.94:1, which looks like a pass, while its light end against a dark
    // desktop is 1.09:1 and the icon all but vanishes. Both ends are therefore
    // checked against every wallpaper.
    Registry.shared.add(suite: suite, TestCase(name: "separates from every desktop", knownBug: nil) {
        let samples = try IconRenderer.render(pixels: 512)
        guard let extremes = IconRenderer.bodyExtremes(in: samples) else {
            Harness.record("no body pixels were found in the rendered icon")
            return
        }
        let floor = IconRenderer.minimumEdgeSeparation
        let wallpapers = IconRenderer.lightWallpapers + IconRenderer.darkWallpapers
        var failures: [String] = []
        var worst = Double.infinity
        var worstAt = ""

        for (name, corner) in [("lightest", extremes.lightest), ("darkest", extremes.darkest)] {
            for wallpaper in wallpapers {
                let separation = corner.contrast(against: wallpaper)
                if separation < worst {
                    worst = separation
                    worstAt = "the \(name) corner against \(wallpaper)"
                }
                if separation < floor {
                    failures.append("the \(name) body corner is \(String(format: "%.2f", separation)):1")
                }
            }
        }

        // One record per case, whatever the count: a list of near-identical
        // contrast figures is harder to act on than the worst one and the ramp
        // it came from.
        check(failures.isEmpty,
              "the icon body does not separate from every desktop macOS ships — "
              + "\(failures.joined(separator: ", ")), worst \(String(format: "%.2f", worst)):1 "
              + "at \(worstAt), floor \(String(format: "%.2f", floor)):1. A neutral icon has "
              + "no hue to fall back on, so the edge is all that separates it.")
    })

    Registry.shared.add(suite: suite, TestCase(name: "stays neutral rather than taking a hue", knownBug: nil) {
        let samples = try IconRenderer.render(pixels: 512)
        guard let extremes = IconRenderer.bodyExtremes(in: samples) else {
            Harness.record("no body pixels were found in the rendered icon")
            return
        }
        // The body is grey by design: every channel is within a hair of the
        // others. This is a wide bound — it rejects a coloured body outright and
        // deliberately does not police the exact grey.
        for (name, pixel) in [("lightest", extremes.lightest), ("darkest", extremes.darkest)] {
            let channels = [pixel.r, pixel.g, pixel.b].sorted()
            let spread = channels[2] - channels[0]
            check(spread < 0.06,
                  "the body's \(name) corner is tinted (r \(String(format: "%.2f", pixel.r)) "
                  + "g \(String(format: "%.2f", pixel.g)) b \(String(format: "%.2f", pixel.b))) — "
                  + "the icon body is meant to be neutral grey")
        }
    })
}

// MARK: - The mark survives Dock sizes

private func registerIconMarkTests() {
    let suite = "icon: mark"

    Registry.shared.add(suite: suite, TestCase(name: "reads as a countable grid at 32px", knownBug: nil) {
        let samples = try IconRenderer.render(pixels: 32)
        // Count the runs of tile-bright pixels along the vertical centre line.
        // Three is the only count that is both correct and legible: a grid whose
        // gaps are too tight to resolve merges rows, and fewer tiles would give
        // fewer runs.
        //
        // 32px, not 16px. Measured over the real render, the 3x3 grid resolves
        // at 32px with the tile gap anywhere from ~26 to 60 units, and at 16px it
        // is marginal at every gap in that range — three runs are separable only
        // within a few percent of the tile-to-gap threshold, which is a
        // threshold artefact rather than something a person reliably sees. Pinning
        // the size at which the mark genuinely reads is the honest version of this
        // case; a 16px variant would either pass by luck or fail by luck.
        //
        // The threshold is a third of the way up the column's own range, because at
        // 32px the column never holds a pure body sample: every row crosses either
        // a tile or a gap the antialiasing has already mixed. Measured across the
        // real render, the run count is stable from 20% to 45% of that range.
        let column = samples.count / 2
        var runs = 0
        var insideRun = false
        var low = 1.0
        var high = 0.0
        for row in samples {
            let value = row[column].luminance
            low = min(low, value)
            high = max(high, value)
        }
        let threshold = low + (high - low) * 0.35
        for row in samples {
            let isTile = row[column].luminance > threshold
            if isTile && !insideRun {
                runs += 1
            }
            insideRun = isTile
        }
        checkEqual(runs, 3,
                   "the vertical centre line crosses \(runs) tile runs at 32px, so the 3x3 grid does not resolve")
    })

    Registry.shared.add(suite: suite, TestCase(name: "the faintest tile stays off the body", knownBug: nil) {
        let samples = try IconRenderer.render(pixels: 32)
        // The bottom-right tile is the faintest by design. Sampled from the
        // rendered image rather than from the source constant, so this measures
        // the composited result — which is what the eye actually sees — and
        // compared against the gap beside it, since that is what the tile has to
        // be told apart from.
        //
        // This is a floor against a tile vanishing, not a pin on the opacity ramp.
        // Measured across the real render, sweeping the faintest tile from 0.62
        // down to 0.18 moves its contrast against the adjacent gap only from
        // 1.41:1 to 1.21:1, because a tile at a lower opacity drags the gap beside
        // it down too. So this catches the ramp being taken somewhere absurd and
        // deliberately does not claim the number itself is load-bearing.
        let side = samples.count
        let offset = Int(Double(side) * 0.30)
        let tile = samples[side - 1 - offset][side - 1 - offset]
        let gap = samples[side - 1 - offset][side - 1 - Int(Double(side) * 0.13)]
        let separation = tile.contrast(against: gap)
        check(separation > 1.25,
              "the faintest tile is only \(String(format: "%.2f", separation)):1 against the gap beside it — "
              + "at 32px it has stopped being a tile")
    })
}