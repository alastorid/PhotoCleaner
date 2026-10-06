// tools/make-icon.swift
//
// Renders `AppIcon.icns` at build time and writes it to the path given as the
// first argument.
//
// There is no .icns checked into the repository on purpose. A binary blob that
// nobody can diff is a blob nobody can review, and the icon is four shapes: it
// is cheaper to keep the drawing as code that reads like the drawing than to keep
// an image that only opens in an image editor.
//
// The gradient is the one from `web/app.css`'s `.app-mark`
// (`linear-gradient(160deg, var(--accent), #6f4bff)`) so the Dock icon, the header
// mark and the browser tab are the same object.
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

/// Three bars of decreasing height: a photo library ordered by score, which is
/// the one idea this tool has to communicate.
private struct Bar {
    let width: Double
    let height: Double
    /// White at a falling opacity, so the order reads even in greyscale.
    let opacity: Double
}

private let bars: [Bar] = [
    Bar(width: 132, height: 552, opacity: 1.00),
    Bar(width: 132, height: 388, opacity: 0.72),
    Bar(width: 132, height: 224, opacity: 0.46),
]

private let barGap: Double = 84
/// Distance from the bottom of the body to the bottom of the shortest bar, which
/// puts the tallest bar's cap at ~80% of the height: centred enough to look
/// deliberate, low enough to leave the gradient somewhere to be seen.
private let barBaseline: Double = 262

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
        NSColor(srgbRed: 0x0a / 255.0, green: 0x84 / 255.0, blue: 0xff / 255.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0x6f / 255.0, green: 0x4b / 255.0, blue: 0xff / 255.0, alpha: 1).cgColor,
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

private func drawBars(in context: CGContext) {
    let totalWidth = bars.reduce(0) { $0 + $1.width } + barGap * Double(bars.count - 1)
    var x = (canvas - totalWidth) / 2

    for bar in bars {
        let rect = CGRect(x: x, y: barBaseline, width: bar.width, height: bar.height)
        // A bar's own corner radius tracks its width, so the shortest bar is not
        // a stubby lozenge and the tallest is not a thin stick.
        let radius = bar.width * 0.30
        context.addPath(CGPath(roundedRect: rect,
                               cornerWidth: radius,
                               cornerHeight: radius,
                               transform: nil))
        context.setFillColor(NSColor.white.withAlphaComponent(bar.opacity).cgColor)
        context.fillPath()
        x += bar.width + barGap
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
    drawBars(in: context)

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
