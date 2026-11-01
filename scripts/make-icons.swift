#!/usr/bin/env swift
// Draws Scope's app icons into the asset catalog: a black square with a
// 2 px margin (at 32 px), filled by a square in the top-left corner, two
// rectangles beside and below it, and the same pattern again, smaller each
// time, inside the bottom-right corner. Each level's square grows past its
// slot and sits on top of the pieces beside and below it, with a black
// outline keeping them apart.
// AppIcon (Scope) uses white squares, AppIconDev (Scope Dev) amber ones, so
// the two builds can't be mistaken for each other.
// Run from the repo root: swift scripts/make-icons.swift
import AppKit

let catalog = "Scope/Resources/Assets.xcassets"
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

/// Four levels; the top-left square takes 55% of each level and grows 14%
/// past its slot.
let depth = 4
let share: CGFloat = 0.55
let grow: CGFloat = 0.14

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
    let context = NSGraphicsContext.current!.cgContext
    context.clip(to: CGRect(x: padding, y: padding, width: size - 2 * padding, height: size - 2 * padding))

    // Pieces per level in top-left coordinates; the level's square comes last.
    var levels: [[CGRect]] = []
    var x = padding, y = padding, side = size - 2 * padding
    for level in 0..<depth {
        let big = (side - gap) * share
        let rest = side - big - gap
        var pieces = [CGRect(x: x + big + gap, y: y, width: rest, height: big),
                      CGRect(x: x, y: y + big + gap, width: big, height: rest)]
        if level == depth - 1 { pieces.append(CGRect(x: x + big + gap, y: y + big + gap, width: rest, height: rest)) }
        pieces.append(CGRect(x: x, y: y, width: big * (1 + grow), height: big * (1 + grow)))
        levels.append(pieces)
        x += big + gap
        y += big + gap
        side = rest
    }
    // Deepest level first, so each bigger square lands on top of the smaller ones.
    for pieces in levels.reversed() {
        for piece in pieces where piece.width >= 1 && piece.height >= 1 {
            let rect = CGRect(x: piece.minX, y: size - piece.minY - piece.height, width: piece.width, height: piece.height)
            context.setFillColor(squareColor.cgColor)
            context.fill(rect)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(gap)
            context.stroke(rect.insetBy(dx: -gap / 2, dy: -gap / 2))
        }
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
