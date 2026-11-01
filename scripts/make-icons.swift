#!/usr/bin/env swift
// Draws the placeholder app icons into the asset catalog:
// AppIcon (Pandora, teal) and AppIconDev (Pandora Dev, amber with a DEV band),
// so the two builds can't be mistaken for each other.
// Run from the repo root: swift scripts/make-icons.swift
import AppKit

let catalog = "Pandora/Resources/Assets.xcassets"
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

func drawIcon(pixels: Int, color: NSColor, band: String?) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    // macOS icon grid: the shape fills about 80% of the canvas.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    color.setFill()
    shape.fill()

    let glyph = NSAttributedString(string: "P", attributes: [
        .font: NSFont.systemFont(ofSize: rect.height * 0.62, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    let glyphSize = glyph.size()
    glyph.draw(at: NSPoint(x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2 + (band == nil ? 0 : rect.height * 0.08)))

    if let band {
        NSGraphicsContext.current?.saveGraphicsState()
        shape.addClip()
        let bandRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.26)
        NSColor.black.withAlphaComponent(0.75).setFill()
        bandRect.fill()
        let label = NSAttributedString(string: band, attributes: [
            .font: NSFont.systemFont(ofSize: bandRect.height * 0.62, weight: .heavy),
            .foregroundColor: NSColor.white,
        ])
        let labelSize = label.size()
        label.draw(at: NSPoint(x: bandRect.midX - labelSize.width / 2, y: bandRect.midY - labelSize.height / 2))
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func writeIconSet(name: String, color: NSColor, band: String?) throws {
    let folder = "\(catalog)/\(name).appiconset"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for (points, scale) in sizes {
        let file = "icon_\(points)x\(points)@\(scale)x.png"
        try drawIcon(pixels: points * scale, color: color, band: band).write(to: URL(fileURLWithPath: "\(folder)/\(file)"))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": file])
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: "\(folder)/Contents.json"))
}

let teal = NSColor(red: 0x0F / 255, green: 0x7B / 255, blue: 0x72 / 255, alpha: 1)
let amber = NSColor(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255, alpha: 1)
try writeIconSet(name: "AppIcon", color: teal, band: nil)
try writeIconSet(name: "AppIconDev", color: amber, band: "DEV")
print("Icons written to \(catalog)")
