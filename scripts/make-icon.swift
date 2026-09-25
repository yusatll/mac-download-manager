#!/usr/bin/env swift
// Draws the HDM app icon (our own design: a download arrow with speed lines) into an .appiconset.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.05, green: 0.66, blue: 0.56, alpha: 1),
                        NSColor(red: 0.07, green: 0.32, blue: 0.82, alpha: 1)])!.draw(in: tile, angle: -90)
    NSColor.white.setFill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 560 * s, y: 770 * s))
    arrow.line(to: NSPoint(x: 670 * s, y: 770 * s))
    arrow.line(to: NSPoint(x: 670 * s, y: 490 * s))
    arrow.line(to: NSPoint(x: 790 * s, y: 490 * s))
    arrow.line(to: NSPoint(x: 615 * s, y: 285 * s))
    arrow.line(to: NSPoint(x: 440 * s, y: 490 * s))
    arrow.line(to: NSPoint(x: 560 * s, y: 490 * s))
    arrow.close()
    arrow.fill()
    for (i, y) in [660, 550, 440].enumerated() {
        let width = CGFloat(210 - i * 50) * s
        NSBezierPath(roundedRect: NSRect(x: 400 * s - width, y: CGFloat(y) * s, width: width, height: 46 * s), xRadius: 23 * s, yRadius: 23 * s).fill()
    }
    NSBezierPath(roundedRect: NSRect(x: 445 * s, y: 205 * s, width: 340 * s, height: 44 * s), xRadius: 22 * s, yRadius: 22 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
