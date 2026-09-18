import Foundation
import AppKit

// Renders the Imager app icon at every required size and builds an iconset + .icns.
// Usage: swift Scripts/gen_icon.swift  (run from the repo root)

let iconSizeNames = [
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024
]

func drawIcon(size: Int) -> NSImage {
    let canvas = NSImage(size: NSSize(width: size, height: size))
    canvas.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        canvas.unlockFocus()
        return canvas
    }
    let s = CGFloat(size) / 1024.0

    // Background rounded square with vertical gradient.
    let bgRect = NSRect(x: 64 * s, y: 64 * s, width: 896 * s, height: 896 * s)
    let corner = 220 * s
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: corner, yRadius: corner)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.48, green: 0.34, blue: 0.93, alpha: 1)
    ])!
    gradient.draw(in: bgPath, angle: -70)

    ctx.saveGState()
    bgPath.addClip()

    // Soft highlight band.
    NSColor(calibratedWhite: 1.0, alpha: 0.10).setFill()
    NSBezierPath(rect: NSRect(x: 64 * s, y: 760 * s, width: 896 * s, height: 200 * s)).fill()

    // White photo card, slight rotation, clipped to a rounded-rect mask.
    let cardRect = NSRect(x: 250 * s, y: 470 * s, width: 460 * s, height: 340 * s)
    ctx.translateBy(x: cardRect.midX, y: cardRect.midY)
    ctx.rotate(by: -8 * CGFloat.pi / 180)
    ctx.translateBy(x: -cardRect.midX, y: -cardRect.midY)

    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 44 * s, yRadius: 44 * s)
    cardPath.addClip()

    NSColor.white.setFill()
    NSBezierPath(rect: cardRect).fill()

    // Sky inside card.
    let sky = NSGradient(colors: [
        NSColor(calibratedRed: 0.53, green: 0.85, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.88, green: 0.97, blue: 1.00, alpha: 1)
    ])!
    sky.draw(in: NSBezierPath(rect: cardRect), angle: 90)

    // Sun.
    NSColor(calibratedRed: 1.00, green: 0.76, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 355 * s, y: 640 * s, width: 110 * s, height: 110 * s)).fill()

    // Mountains.
    NSColor(calibratedRed: 0.24, green: 0.55, blue: 0.85, alpha: 1).setFill()
    let m1 = NSBezierPath()
    m1.move(to: NSPoint(x: 250 * s, y: 600 * s))
    m1.line(to: NSPoint(x: 390 * s, y: 500 * s))
    m1.line(to: NSPoint(x: 560 * s, y: 590 * s))
    m1.line(to: NSPoint(x: 710 * s, y: 600 * s))
    m1.close()
    m1.fill()

    NSColor(calibratedRed: 0.10, green: 0.33, blue: 0.58, alpha: 1).setFill()
    let m2 = NSBezierPath()
    m2.move(to: NSPoint(x: 420 * s, y: 600 * s))
    m2.line(to: NSPoint(x: 560 * s, y: 510 * s))
    m2.line(to: NSPoint(x: 710 * s, y: 545 * s))
    m2.line(to: NSPoint(x: 710 * s, y: 600 * s))
    m2.close()
    m2.fill()

    ctx.restoreGState()

    // Magnifier lens overlapping the card corner.
    let lensCenter = NSPoint(x: 610 * s, y: 380 * s)
    let lensRadius = 190 * s
    ctx.saveGState()
    ctx.beginPath()
    ctx.addArc(center: lensCenter, radius: lensRadius, startAngle: 0, endAngle: 2 * CGFloat.pi, clockwise: false)
    ctx.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.92).cgColor)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(22 * s)
    ctx.drawPath(using: .fillStroke)

    // Glass glint.
    ctx.beginPath()
    ctx.addArc(center: NSPoint(x: 560 * s, y: 440 * s), radius: 42 * s, startAngle: 0, endAngle: 2 * CGFloat.pi, clockwise: false)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Handle.
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor(calibratedWhite: 0.15, alpha: 1).cgColor)
    ctx.setLineWidth(64 * s)
    ctx.move(to: NSPoint(x: 760 * s, y: 196 * s))
    ctx.addLine(to: NSPoint(x: 920 * s, y: 46 * s))
    ctx.strokePath()
    ctx.restoreGState()

    canvas.unlockFocus()
    return canvas
}

FileManager.default.createFile(atPath: "/dev/null", contents: nil)
let stdout = FileHandle.standardOutput
stdout.write(Data())

func writePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed to encode \(path)\n", stderr)
        exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let currentDir = FileManager.default.currentDirectoryPath
let iconsetDir = currentDir + "/Resources/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for (name, size) in iconSizeNames {
    let image = drawIcon(size: size)
    writePNG(image, to: iconsetDir + "/" + name)
}

print("done drawing icon set")