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
func drawIcon(in size: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Squircle clip (Big Sur approximation): cornerRadius ~234 at 1024.
    let corner = 234.0 / 1024.0 * size
    let squircle = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    squircle.addClip()

    // Vertical gradient background, deep navy (top) to steel blue (bottom).
    let gradient = NSGradient(starting: navy, ending: steel)!
    gradient.draw(in: rect, angle: -90)

    let s = size / 1024.0  // unit scale helper

    // MARK: Gantry crane (white geometric paths)

    white.setStroke()
    white.setFill()

    let beamY = 300.0 * s
    let beamHeight = 46.0 * s
    let legWidth = 46.0 * s
    let legTop = beamY
    let legBottom = 760.0 * s
    let leftLegX = 250.0 * s
    let rightLegX = 728.0 * s

    // Horizontal top beam.
    let beam = CGRect(x: 210.0 * s, y: beamY, width: 604.0 * s, height: beamHeight)
    ctx.fill(beam)

    // Two vertical legs.
    ctx.fill(CGRect(x: leftLegX, y: legTop, width: legWidth, height: legBottom - legTop))
    ctx.fill(CGRect(x: rightLegX, y: legTop, width: legWidth, height: legBottom - legTop))

    // Hoist cable from the beam centre down to the container.
    let cableX = 512.0 * s
    let cableWidth = 12.0 * s
    let cableTop = beamY + beamHeight
    let cableBottom = 470.0 * s
    ctx.fill(CGRect(x: cableX - cableWidth / 2, y: cableTop, width: cableWidth, height: cableBottom - cableTop))

    // Small hook block where the cable meets the container.
    ctx.fill(CGRect(x: cableX - 34.0 * s, y: cableBottom - 8.0 * s, width: 68.0 * s, height: 22.0 * s))

    // MARK: Shipping container (orange rounded rect with ridge lines)

    let containerRect = CGRect(x: 332.0 * s, y: 470.0 * s, width: 360.0 * s, height: 200.0 * s)
    let containerCorner = 26.0 * s
    let containerPath = NSBezierPath(roundedRect: containerRect, xRadius: containerCorner, yRadius: containerCorner)
    orange.setFill()
    containerPath.fill()

    // Three vertical ridge lines.
    navy.withAlphaComponent(0.35).setStroke()
    let ridgeInset = 70.0 * s
    let ridgeTop = containerRect.maxY - 30.0 * s
    let ridgeBottom = containerRect.minY + 30.0 * s
    for i in 0..<3 {
        let x = containerRect.minX + ridgeInset + CGFloat(i) * ((containerRect.width - 2 * ridgeInset) / 2)
        let line = NSBezierPath()
        line.lineWidth = 10.0 * s
        line.move(to: CGPoint(x: x, y: ridgeBottom))
        line.line(to: CGPoint(x: x, y: ridgeTop))
        line.stroke()
    }

    // MARK: Bottom waterline arcs

    white.withAlphaComponent(0.22).setStroke()
    let waveBaseY = 200.0 * s
    for row in 0..<2 {
        let y = waveBaseY - CGFloat(row) * 70.0 * s
        let wave = NSBezierPath()
        wave.lineWidth = 14.0 * s
        wave.lineCapStyle = .round
        let amplitude = 26.0 * s
        let wavelength = 150.0 * s
        var x = 60.0 * s
        wave.move(to: CGPoint(x: x, y: y))
        var up = true
        while x < size - 60.0 * s {
            let nextX = x + wavelength
            let controlX = x + wavelength / 2
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
