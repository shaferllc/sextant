#!/usr/bin/env swift
// Generates AppIcon.icns: a crosshair sighted through a brass ring over a deep
// navy night sky, with a sextant's graduated arc below.
// Usage: swift make-icon.swift  (run from the sextant dir)

import AppKit
import Foundation

let here    = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func makePNG(size px: Int) -> Data? {
    let pf = CGFloat(px)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)
    else { return nil }
    rep.size = NSSize(width: pf, height: pf)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx

    // Squircle background: deep navy night-sky gradient.
    let radius = pf * 0.225
    let squircle = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: pf, height: pf),
                                xRadius: radius, yRadius: radius)
    squircle.addClip()
    let grad = NSGradient(colors: [
        NSColor(red: 0.13, green: 0.20, blue: 0.36, alpha: 1),
        NSColor(red: 0.04, green: 0.07, blue: 0.17, alpha: 1),
    ])!
    grad.draw(in: NSRect(x: 0, y: 0, width: pf, height: pf), angle: -90)

    // A few faint stars — celestial navigation.
    let stars: [(CGFloat, CGFloat, CGFloat)] = [
        (0.18, 0.84, 0.012), (0.30, 0.72, 0.008), (0.76, 0.86, 0.010),
        (0.86, 0.68, 0.008), (0.14, 0.58, 0.007), (0.68, 0.14, 0.008),
    ]
    NSColor(white: 1, alpha: 0.55).setFill()
    for (sx, sy, sr) in stars {
        let r = max(0.5, pf * sr)
        NSBezierPath(ovalIn: NSRect(x: pf * sx - r, y: pf * sy - r,
                                    width: r * 2, height: r * 2)).fill()
    }

    let center = NSPoint(x: pf / 2, y: pf * 0.54)
    let brass  = NSColor(red: 0.93, green: 0.76, blue: 0.38, alpha: 1)

    // Sextant arc: a graduated scale along the bottom.
    let arcRadius = pf * 0.40
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: arcRadius,
                  startAngle: 235, endAngle: 305, clockwise: false)
    arc.lineWidth = max(1, pf * 0.020)
    arc.lineCapStyle = .round
    brass.withAlphaComponent(0.9).setStroke()
    arc.stroke()
    for degrees in stride(from: 240.0, through: 300.0, by: 12.0) {
        let a = CGFloat(degrees) * .pi / 180
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: center.x + cos(a) * arcRadius * 0.955,
                              y: center.y + sin(a) * arcRadius * 0.955))
        tick.line(to: NSPoint(x: center.x + cos(a) * arcRadius * 1.075,
                              y: center.y + sin(a) * arcRadius * 1.075))
        tick.lineWidth = max(0.75, pf * 0.014)
        tick.lineCapStyle = .round
        brass.withAlphaComponent(0.9).setStroke()
        tick.stroke()
    }

    // The sighting ring.
    let ringRadius = pf * 0.26
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - ringRadius,
                                           y: center.y - ringRadius,
                                           width: ringRadius * 2,
                                           height: ringRadius * 2))
    ring.lineWidth = max(1.5, pf * 0.042)
    brass.setStroke()
    ring.stroke()

    // Crosshair hairlines through the ring, with a gap at center.
    let hair = NSBezierPath()
    let reach = pf * 0.375
    let gap = pf * 0.075
    hair.move(to: NSPoint(x: center.x - reach, y: center.y))
    hair.line(to: NSPoint(x: center.x - gap, y: center.y))
    hair.move(to: NSPoint(x: center.x + gap, y: center.y))
    hair.line(to: NSPoint(x: center.x + reach, y: center.y))
    hair.move(to: NSPoint(x: center.x, y: center.y - reach))
    hair.line(to: NSPoint(x: center.x, y: center.y - gap))
    hair.move(to: NSPoint(x: center.x, y: center.y + gap))
    hair.line(to: NSPoint(x: center.x, y: center.y + reach))
    hair.lineWidth = max(1, pf * 0.024)
    hair.lineCapStyle = .round
    NSColor(white: 0.97, alpha: 0.95).setStroke()
    hair.stroke()

    // Center dot — the fix.
    let dotRadius = max(0.75, pf * 0.020)
    NSColor(white: 0.97, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                width: dotRadius * 2, height: dotRadius * 2)).fill()

    return rep.representation(using: .png, properties: [:])
}

for (name, px) in sizes {
    guard let data = makePNG(size: px) else { continue }
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path,
                  "-o", here.appendingPathComponent("AppIcon.icns").path]
try proc.run()
proc.waitUntilExit()
print("Wrote AppIcon.icns")
