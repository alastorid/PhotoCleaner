// tools/make-icon.swift
//
// Renders `AppIcon.icns` at build time and writes it to the path given as the
// first argument.
//
// There is no .icns checked into the repository on purpose. A binary blob that
// nobody can diff is a blob nobody can review, and the icon is a handful of
// shapes: it is cheaper to keep the drawing as code that reads like the drawing
// than to keep an image that only opens in an image editor.
//
// The body gradient is neutral grey, deliberately. A coloured icon has a hue to
// separate itself from the desktop with; a neutral one does not, so the ramp has
// to clear the desktop *luminance* instead — every pixel of the body against
// every wallpaper it might land on, since the whole icon sits on the wallpaper
// and not half of it. That is a min over both ends and all of them, not a
// light-end-on-light / dark-end-on-dark pairing; the pairing is the mistake, and
// it lets a graphite body look like a pass (its dark end scores 12.94:1 on a
// light desktop) while the light end is invisible at 1.09:1 on a dark one.
//
// Both obvious neutrals fail that min outright. Graphite `#4a4a4f` → `#232326`
// bottoms out at 1.09:1, its dark end on `#1c1c1e`, and the edge vanishes. White
// `#fbfbfd` → `#dcdce1` reaches 1.00:1, an exact match against the light grey
// desktop. The mid grey below clears all six wallpapers, worst corner 1.85:1
// (`#54545a` on `#2c2c2e`). Re-measure before moving it towards either end.
//
// `Tests/IconTests.swift` enforces this against the rendered image, not these
// constants — and the wallpapers it uses are the reason the floor there is 1.25
// rather than something rounder.
//
// Note that `--accent` in `web/app.css` is *not* this colour and `.app-mark` no
// longer mirrors it. Selection is this app's core action and a grey accent makes
// a selected tile look unselected, so the UI keeps a real hue while the icon
// stays neutral. `.app-mark` tracks the icon body instead.
//
// Everything is drawn into a 1024x1024 space and scaled, so one set of numbers
// describes the icon at every size.

import AppKit
import Foundation

// MARK: - Geometry, in a 1024x1024 space

private let canvas = 1024.0

/// The corner radius of the macOS "squircle" body, as a fraction of the side.
/// A circular-corner rounded rect is not the real continuous curve, but it is
/// indistinguishable from 64px down, which is where anyone actually looks.
private let bodyCornerRadius = canvas * 0.2237

/// The mark: a 3×3 contact sheet — the app's own grid — whose tiles fade in
/// reading order, so the low-scoring tail thins out at the bottom right. This is
/// the one idea the tool has to communicate, and it is now the icon's shape
/// rather than an abstract bar chart.
private struct Tile {
    let size: Double
    /// White at a falling opacity, so the order reads even in greyscale.
    let opacity: Double
}

/// Row-major from the top left, which is the order the grid is read in and
/// therefore the order the score sorts in.
///
/// The run is shallow — the last tile is 0.46, not the 0.26 a steeper falloff
/// looks better with at 512px. The measured case for that is modest, and stated
/// as measured: sweeping the faintest tile from 0.62 down to 0.18 moves its
/// contrast against the gap beside it only from 1.41:1 to 1.21:1, because a
/// fainter tile drags the neighbouring gap down with it. So the shallow run is
/// mostly taste, kept because the fall-off reads as an ordered grid rather than
/// as a lighting effect.
private let tiles: [Tile] = [
    Tile(size: 210, opacity: 1.00),
    Tile(size: 210, opacity: 1.00),
    Tile(size: 210, opacity: 1.00),
    Tile(size: 210, opacity: 0.95),
    Tile(size: 210, opacity: 0.86),
    Tile(size: 210, opacity: 0.76),
    Tile(size: 210, opacity: 0.66),
    Tile(size: 210, opacity: 0.56),
    Tile(size: 210, opacity: 0.46),
]

private let tileGrid = 3
/// Gap between tiles. Wider than the grid's own 1px seam by a lot, which is an
/// appearance choice rather than a measured requirement: the grid still resolves
/// at 32px with this tightened to about 26 units, and it is marginal at 16px at
/// any gap in that range. `Tests/IconTests.swift` pins the size the mark
/// genuinely reads at rather than pretending 16px is settled.
private let tileGap: Double = 60
private let tileCornerRadius: Double = 32

// MARK: - Drawing

private func drawBody(in context: CGContext) {
    let rect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let body = CGPath(roundedRect: rect,
                      cornerWidth: bodyCornerRadius,
                      cornerHeight: bodyCornerRadius,
                      transform: nil)

    context.saveGState()
    context.addPath(body)
    context.clip()

    // CSS `linear-gradient(160deg, …)`: 0deg points up and the angle runs
    // clockwise, so the axis is (sin, -cos) in CSS's y-up space. CoreGraphics is
    // y-down, which negates the second component.
    let radians = 160.0 * .pi / 180.0
    let direction = CGPoint(x: sin(radians), y: cos(radians))
    let centre = CGPoint(x: canvas / 2, y: canvas / 2)
    // The CSS gradient line is long enough to cover the whole box at this angle,
    // otherwise the end colours would never reach the corners.
    let reach = (canvas * abs(sin(radians)) + canvas * abs(cos(radians))) / 2
    let start = CGPoint(x: centre.x - direction.x * reach, y: centre.y - direction.y * reach)
    let end = CGPoint(x: centre.x + direction.x * reach, y: centre.y + direction.y * reach)

    let colours = [
        NSColor(srgbRed: 0x9a / 255.0, green: 0x9a / 255.0, blue: 0xa0 / 255.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0x54 / 255.0, green: 0x54 / 255.0, blue: 0x5a / 255.0, alpha: 1).cgColor,
    ] as CFArray
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: colours,
                                    locations: [0, 1]) else { return }
    context.drawLinearGradient(gradient, start: start, end: end, options: [])

    // A hairline of white at the top edge, the same inset border the header mark
    // has: it keeps the icon from looking flat against a light Dock.
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    context.setLineWidth(2)
    context.addPath(body)
    context.strokePath()

    context.restoreGState()
}

private func drawTiles(in context: CGContext) {
    guard let side = tiles.first?.size else { return }
    let span = side * Double(tileGrid) + tileGap * Double(tileGrid - 1)
    let origin = (canvas - span) / 2

    // Enumerated rather than looked up by value: the three leading tiles are
    // identical (size 210, opacity 1.00), so a value search would return the
    // first of them three times and the grid would come out as one column.
    for (index, tile) in tiles.enumerated() {
        // `tiles` is filled row by row from the top left, so row 0 is the top
        // row. CoreGraphics counts y up from the bottom, hence the flip.
        let column = index % tileGrid
        let row = index / tileGrid
        let rect = CGRect(x: origin + Double(column) * (side + tileGap),
                          y: origin + Double(tileGrid - 1 - row) * (side + tileGap),
                          width: side,
                          height: side)
        context.addPath(CGPath(roundedRect: rect,
                               cornerWidth: tileCornerRadius,
                               cornerHeight: tileCornerRadius,
                               transform: nil))
        context.setFillColor(NSColor.white.withAlphaComponent(tile.opacity).cgColor)
        context.fillPath()
    }
}

/// Renders the icon at `pixels` square and returns it as PNG data.
private func renderPNG(pixels: Int) -> Data? {
    guard let context = CGContext(data: nil,
                                  width: pixels,
                                  height: pixels,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.scaleBy(x: Double(pixels) / canvas, y: Double(pixels) / canvas)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    drawBody(in: context)
    drawTiles(in: context)

    guard let image = context.makeImage() else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = NSSize(width: pixels, height: pixels)
    return bitmap.representation(using: .png, properties: [:])
}

/// The representations `iconutil` expects in an `.iconset`.
private let representations: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(2)
}
let outputPath = URL(fileURLWithPath: arguments[1])

let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("photocleaner-icon-\(getpid())", isDirectory: true)
let iconset = workDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    try? FileManager.default.removeItem(at: workDirectory)
    exit(1)
}

do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
} catch {
    fail("could not create \(iconset.path): \(error)")
}

for representation in representations {
    guard let data = renderPNG(pixels: representation.pixels) else {
        fail("could not render \(representation.name)")
    }
    let destination = iconset.appendingPathComponent("\(representation.name).png")
    do {
        try data.write(to: destination)
    } catch {
        fail("could not write \(destination.path): \(error)")
    }
}

// `iconutil` is part of macOS; it is the only supported way to assemble an .icns
// without shipping a third-party tool.
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", outputPath.path]
process.standardError = FileHandle.standardError
do {
    try process.run()
    process.waitUntilExit()
} catch {
    fail("could not run iconutil: \(error)")
}
try? FileManager.default.removeItem(at: workDirectory)

guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: outputPath.path) else {
    fail("iconutil failed (status \(process.terminationStatus))")
}
print("    \(outputPath.lastPathComponent) (\(representations.count) representations)")
