#!/usr/bin/env swift
// Draws Scope's app icons into the asset catalog: a black square with a
// 2 px margin (at 32 px) holding squares that shrink from the top-left
// corner to the bottom-right one, with a small gap between them.
// AppIcon (Scope) uses white squares, AppIconDev (Scope Dev) amber ones, so
// the two builds can't be mistaken for each other.
// Run from the repo root: swift scripts/make-icons.swift
import AppKit

let catalog = "Scope/Resources/Assets.xcassets"
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

/// Four squares, each half the size of the one before.
let count = 4
let ratio: CGFloat = 0.5

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
    let inner = size - 2 * padding
    let total = (0..<count).reduce(CGFloat(0)) { $0 + pow(ratio, CGFloat($1)) }
    let first = (inner - CGFloat(count - 1) * gap) / total
    squareColor.setFill()
    var offset = padding
    for index in 0..<count {
        let side = max(1, (first * pow(ratio, CGFloat(index))).rounded())
        // AppKit's origin is bottom-left; flip so the first square sits top-left.
        NSRect(x: offset, y: size - offset - side, width: side, height: side).fill()
        offset += side + gap
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
