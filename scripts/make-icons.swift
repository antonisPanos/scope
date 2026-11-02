#!/usr/bin/env swift  // Draws Scope's app icons as Icon Composer icons: a black tile holding a
// square in the top-left corner, two rectangles beside and below it, and the
// same pattern again, smaller each time, inside the bottom-right corner. Each
// level's square grows past its slot and sits on top of the pieces beside and
// below it, with a black outline keeping them apart.
// AppIcon (Scope) uses white squares, AppIconDev (Scope Dev) amber ones, so
// the two builds can't be mistaken for each other.
// Each .icon is a black fill plus one flat layer with the squares. macOS cuts
// the rounded tile itself, so the layer keeps a black margin that clears the
// tile's corners; an icon drawn the pre-macOS 26 way would be shrunk onto a
// grey plate instead.
// Run from the repo root: swift scripts/make-icons.swift
import AppKit

let resources = "Scope/Resources"
let readmeIcon = "docs/images/icon.png"

/// Icon Composer layers are 1024 px squares that map onto the whole tile.
let canvas = 1024
/// The tile is drawn on a 32-unit grid; the squares sit 3 units in, which
/// keeps them inside the tile's rounded corners.
let margin: CGFloat = 3
/// Four levels; the top-left square takes 55% of each level and grows 14%
/// past its slot.
let depth = 4
let share: CGFloat = 0.55
let grow: CGFloat = 0.14

/// Draws the squares at `pixels` size on a clear background, or on
/// `background` when given.
func drawSquares(pixels: Int, squareColor: NSColor, background: NSColor? = nil) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if let background {
        background.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
    }

    let unit = size / 32
    let padding = (margin * unit).rounded()
    let gap = max(1, unit.rounded())
    let context = NSGraphicsContext.current!.cgContext
    context.clip(to: CGRect(x: padding, y: padding, width: size - 2 * padding, height: size - 2 * padding))

    // Pieces per level in top-left coordinates; the level's square comes last.
    var levels: [[CGRect]] = []
    var x = padding
    var y = padding
    var side = size - 2 * padding
    for level in 0..<depth {
        let big = (side - gap) * share
        let rest = side - big - gap
        var pieces = [
            CGRect(x: x + big + gap, y: y, width: rest, height: big),
            CGRect(x: x, y: y + big + gap, width: big, height: rest),
        ]
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
            let rect = CGRect(
                x: piece.minX, y: size - piece.minY - piece.height, width: piece.width, height: piece.height)
            context.setFillColor(squareColor.cgColor)
            context.fill(rect)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(gap)
            context.stroke(rect.insetBy(dx: -gap / 2, dy: -gap / 2))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Writes `<name>.icon`: a solid black fill and one flat layer, with no glass,
/// shadow or translucency, so it looks the same as the artwork.
func writeIcon(name: String, squareColor: NSColor) throws {
    let folder = "\(resources)/\(name).icon"
    try? FileManager.default.removeItem(atPath: folder)
    try FileManager.default.createDirectory(atPath: "\(folder)/Assets", withIntermediateDirectories: true)
    try drawSquares(pixels: canvas, squareColor: squareColor).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(folder)/Assets/Squares.png"))
    let icon: [String: Any] = [
        "fill": ["solid": "extended-srgb:0.00000,0.00000,0.00000,1.00000"],
        "groups": [
            [
                "layers": [["glass": false, "image-name": "Squares.png", "name": "Squares"]],
                "shadow": ["kind": "none", "opacity": 0.5],
                "specular": false,
                "translucency": ["enabled": false, "value": 0.5],
            ]
        ],
        "supported-platforms": ["squares": ["macOS"]],
    ]
    let json = try JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: "\(folder)/icon.json"))
}

/// The README's picture of the icon: the tile on a clear background at 256 px,
/// sized and rounded the way macOS shows it (824 of 1024 px).
func writeReadmeIcon(squareColor: NSColor) throws {
    let pixels = 256
    let tile = (CGFloat(pixels) * 824 / 1024).rounded()
    let inset = (CGFloat(pixels) - tile) / 2
    let squares = drawSquares(pixels: Int(tile), squareColor: squareColor, background: .black)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let frame = NSRect(x: inset, y: inset, width: tile, height: tile)
    NSBezierPath(roundedRect: frame, xRadius: tile * 0.2237, yRadius: tile * 0.2237).addClip()
    squares.draw(in: frame)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: readmeIcon))
}

let amber = NSColor(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255, alpha: 1)
try writeIcon(name: "AppIcon", squareColor: .white)
try writeIcon(name: "AppIconDev", squareColor: amber)
try writeReadmeIcon(squareColor: .white)
print("Icons written to \(resources) and \(readmeIcon)")
