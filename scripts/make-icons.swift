#!/usr/bin/env swift
// Draws Scope's app icons into the asset catalog: a black square with a
// 2 px margin (at 32 px), filled by a square in the top-left corner, two
// rectangles beside and below it, and the same pattern again, smaller each
// time, inside the bottom-right corner. Small gaps separate the pieces.
// AppIcon (Scope) uses white squares, AppIconDev (Scope Dev) amber ones, so
// the two builds can't be mistaken for each other.
// Run from the repo root: swift scripts/make-icons.swift
import AppKit

let catalog = "Scope/Resources/Assets.xcassets"
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

/// Four levels; the top-left square takes 55% of each level.
let depth = 4
let share: CGFloat = 0.55

func drawIcon(pixels: Int, squareColor: NSColor) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let unit = size / 32
    let padding = max(1, (2 * unit).rounded())
    let gap = max(1, unit.rounded())
    squareColor.setFill()
    // Top-left origin, flipped into AppKit's bottom-left one.
    func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        guard w >= 1, h >= 1 else { return }
        NSRect(x: x.rounded(), y: (size - y - h).rounded(), width: w.rounded(), height: h.rounded()).fill()
    }
    var x = padding, y = padding, side = size - 2 * padding
    for level in 0..<depth {
        let big = (side - gap) * share
        let rest = side - big - gap
        fill(x, y, big, big)
        fill(x + big + gap, y, rest, big)
        fill(x, y + big + gap, big, rest)
        if level == depth - 1 { fill(x + big + gap, y + big + gap, rest, rest) }
        x += big + gap
        y += big + gap
        side = rest
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func writeIconSet(name: String, squareColor: NSColor) throws {
    let folder = "\(catalog)/\(name).appiconset"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for (points, scale) in sizes {
        let file = "icon_\(points)x\(points)@\(scale)x.png"
        try drawIcon(pixels: points * scale, squareColor: squareColor).write(to: URL(fileURLWithPath: "\(folder)/\(file)"))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": file])
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: "\(folder)/Contents.json"))
}

let amber = NSColor(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255, alpha: 1)
try writeIconSet(name: "AppIcon", squareColor: .white)
try writeIconSet(name: "AppIconDev", squareColor: amber)
print("Icons written to \(catalog)")
