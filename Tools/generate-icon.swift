#!/usr/bin/env swift
//
// generate-icon.swift
//
// Renders the Gantry app icon at 1024x1024 with AppKit/CoreGraphics, then
// writes the macOS icon set PNGs into the AppIcon.appiconset and updates its
// Contents.json filenames to match.
//
// Run from the repo root:  swift Tools/generate-icon.swift
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

let navy = NSColor(red: 0x0B / 255.0, green: 0x29 / 255.0, blue: 0x42 / 255.0, alpha: 1)
let steel = NSColor(red: 0x2B / 255.0, green: 0x6C / 255.0, blue: 0xB0 / 255.0, alpha: 1)
let orange = NSColor(red: 0xF6 / 255.0, green: 0x86 / 255.0, blue: 0x3A / 255.0, alpha: 1)
let white = NSColor.white

// MARK: - Drawing

/// Draws the full 1024x1024 artwork into the current graphics context.
///
/// NOTE: the bitmap context origin is bottom-left. All layout below is
/// specified in top-based design coordinates and converted via `yTop`.
func drawIcon(in size: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    let s = size / 1024.0  // unit scale helper
    /// Converts a top-based design Y (0 = top of icon) and height to a
    /// bottom-left CGRect.
    func r(_ x: CGFloat, _ yTop: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * s, y: size - (yTop + h) * s, width: w * s, height: h * s)
    }

    // Squircle clip (Big Sur approximation): cornerRadius ~234 at 1024.
    let corner = 234.0 / 1024.0 * size
    let squircle = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    squircle.addClip()

    // Vertical gradient background, deep navy (top) to steel blue (bottom),
    // with a subtle radial glow behind the crane for depth.
    let gradient = NSGradient(starting: navy, ending: steel)!
    gradient.draw(in: rect, angle: -90)
    if let glow = NSGradient(starting: white.withAlphaComponent(0.10), ending: .clear) {
        glow.draw(
            fromCenter: CGPoint(x: size / 2, y: size * 0.62), radius: 0,
            toCenter: CGPoint(x: size / 2, y: size * 0.62), radius: size * 0.55,
            options: []
        )
    }

    // MARK: Waterline (behind the crane)

    white.withAlphaComponent(0.18).setStroke()
    for (row, designY) in [858.0, 920.0].enumerated() {
        let y = size - designY * s
        let wave = NSBezierPath()
        wave.lineWidth = 16.0 * s
        wave.lineCapStyle = .round
        let amplitude = 22.0 * s
        let wavelength = 170.0 * s
        var x = (row == 0 ? 70.0 : 130.0) * s
        wave.move(to: CGPoint(x: x, y: y))
        var up = true
        while x < size - 70.0 * s {
            let nextX = min(x + wavelength, size - 70.0 * s)
            let controlX = x + (nextX - x) / 2
            let controlY = y + (up ? amplitude : -amplitude)
            wave.curve(
                to: CGPoint(x: nextX, y: y),
                controlPoint1: CGPoint(x: controlX, y: controlY),
                controlPoint2: CGPoint(x: controlX, y: controlY)
            )
            x = nextX
            up.toggle()
        }
        wave.stroke()
    }

    // MARK: Gantry crane (white, soft shadow, beam ON TOP)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -10 * s),
        blur: 28 * s,
        color: NSColor.black.withAlphaComponent(0.35).cgColor
    )
    white.setFill()

    let beamTopY = 212.0
    let beamH = 58.0
    let legW = 54.0
    let legTopY = beamTopY + beamH
    let legBottomY = 812.0
    let leftLegX = 196.0
    let rightLegX = 1024.0 - 196.0 - legW

    // Top beam with a slight overhang beyond the legs.
    ctx.fill(r(140, beamTopY, 1024 - 2 * 140, beamH))
    // Legs.
    ctx.fill(r(leftLegX, legTopY, legW, legBottomY - legTopY))
    ctx.fill(r(rightLegX, legTopY, legW, legBottomY - legTopY))
    // Foot pads.
    ctx.fill(r(leftLegX - 34, legBottomY, legW + 68, 26))
    ctx.fill(r(rightLegX - 34, legBottomY, legW + 68, 26))
    // Trolley under the beam centre.
    ctx.fill(r(512 - 56, legTopY, 112, 44))
    // Hoist cable from the trolley down to the container spreader.
    let cableTopY = legTopY + 44.0
    let containerTopY = 442.0
    ctx.fill(r(512 - 7, cableTopY, 14, containerTopY - 36 - cableTopY))
    // Spreader bar sitting on the container.
    ctx.fill(r(512 - 110, containerTopY - 36, 220, 24))
    ctx.restoreGState()

    // MARK: Shipping container (orange, hanging from the spreader)

    let containerW = 420.0
    let containerH = 252.0
    let containerX = 512.0 - containerW / 2
    let containerRect = r(containerX, containerTopY, containerW, containerH)
    let containerCorner = 30.0 * s

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -14 * s),
        blur: 36 * s,
        color: NSColor.black.withAlphaComponent(0.40).cgColor
    )
    let containerPath = NSBezierPath(roundedRect: containerRect, xRadius: containerCorner, yRadius: containerCorner)
    // Vertical gradient: lighter orange on top for a lit look.
    let lightOrange = NSColor(red: 0xFF / 255.0, green: 0x9D / 255.0, blue: 0x57 / 255.0, alpha: 1)
    let deepOrange = NSColor(red: 0xE0 / 255.0, green: 0x6E / 255.0, blue: 0x22 / 255.0, alpha: 1)
    containerPath.addClip()
    NSGradient(starting: lightOrange, ending: deepOrange)?.draw(in: containerRect, angle: -90)
    ctx.restoreGState()

    // Four corrugation ridges, slightly darker, rounded ends.
    deepOrange.withAlphaComponent(0.55).setStroke()
    let ridgeCount = 4
    let ridgeSpan = containerW - 2 * 84.0
    for i in 0..<ridgeCount {
        let designX = containerX + 84.0 + CGFloat(i) * (ridgeSpan / CGFloat(ridgeCount - 1))
        let line = NSBezierPath()
        line.lineWidth = 16.0 * s
        line.lineCapStyle = .round
        line.move(to: CGPoint(x: designX * s, y: size - (containerTopY + 36) * s))
        line.line(to: CGPoint(x: designX * s, y: size - (containerTopY + containerH - 36) * s))
        line.stroke()
    }
}

/// Renders the icon at the given pixel dimension and returns PNG data.
func renderPNG(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = context
    drawIcon(in: CGFloat(pixels))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

// MARK: - Output

let fm = FileManager.default
let cwd = fm.currentDirectoryPath
let appiconURL = URL(fileURLWithPath: cwd)
    .appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

// One PNG per file basename we want in the set. The mac icon set uses 1x/2x
// pairs; we render the exact pixel dimension for each.
struct IconFile {
    let pointSize: Int   // logical size in points
    let scale: Int       // 1 or 2
    var pixels: Int { pointSize * scale }
    var filename: String {
        scale == 1 ? "icon_\(pointSize)x\(pointSize).png" : "icon_\(pointSize)x\(pointSize)@2x.png"
    }
}

let iconFiles: [IconFile] = [
    IconFile(pointSize: 16, scale: 1),
    IconFile(pointSize: 16, scale: 2),
    IconFile(pointSize: 32, scale: 1),
    IconFile(pointSize: 32, scale: 2),
    IconFile(pointSize: 128, scale: 1),
    IconFile(pointSize: 128, scale: 2),
    IconFile(pointSize: 256, scale: 1),
    IconFile(pointSize: 256, scale: 2),
    IconFile(pointSize: 512, scale: 1),
    IconFile(pointSize: 512, scale: 2),
]

do {
    try fm.createDirectory(at: appiconURL, withIntermediateDirectories: true)

    for icon in iconFiles {
        guard let data = renderPNG(pixels: icon.pixels) else {
            FileHandle.standardError.write("Failed to render \(icon.filename)\n".data(using: .utf8)!)
            exit(1)
        }
        let url = appiconURL.appendingPathComponent(icon.filename)
        try data.write(to: url)
        print("Wrote \(icon.filename) (\(icon.pixels)px, \(data.count) bytes)")
    }

    // Rewrite Contents.json so each image entry carries its filename.
    var images: [[String: String]] = []
    for icon in iconFiles {
        images.append([
            "idiom": "mac",
            "scale": "\(icon.scale)x",
            "size": "\(icon.pointSize)x\(icon.pointSize)",
            "filename": icon.filename,
        ])
    }
    let contents: [String: Any] = [
        "images": images,
        "info": ["author": "xcode", "version": 1],
    ]
    let json = try JSONSerialization.data(
        withJSONObject: contents,
        options: [.prettyPrinted, .sortedKeys]
    )
    let contentsURL = appiconURL.appendingPathComponent("Contents.json")
    try json.write(to: contentsURL)
    print("Updated Contents.json")
} catch {
    FileHandle.standardError.write("Icon generation failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
