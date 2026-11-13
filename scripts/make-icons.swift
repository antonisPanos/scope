#!/usr/bin/env swift

// Regenerates Scope's layered Icon Composer artwork and README preview.
// Keep the original 32-unit cascade; give each tile its own glass face.
// Run from the repository root: swift scripts/make-icons.swift
import AppKit

let resources = "Scope/Resources"
let canvas = 1024
let margin: CGFloat = 3
let depth = 4
let share: CGFloat = 0.55
let grow: CGFloat = 0.14

struct Tile {
    let rect: CGRect
    let level: Int
    let index: Int
}

/// Original positions and draw order, deepest pieces first.
func tiles() -> [Tile] {
    let size = CGFloat(canvas)
    let padding = (margin * size / 32).rounded()
    let gap = (size / 32).rounded()
    var levels: [[Tile]] = []
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
        if level == depth - 1 {
            pieces.append(CGRect(x: x + big + gap, y: y + big + gap, width: rest, height: rest))
        }
        pieces.append(CGRect(x: x, y: y, width: big * (1 + grow), height: big * (1 + grow)))
        levels.append(pieces.enumerated().map { Tile(rect: $0.element, level: level, index: $0.offset) })
        x += big + gap
        y += big + gap
        side = rest
    }
    return levels.reversed().flatMap { $0 }
}

func upright(_ tile: Tile) -> CGRect {
    let source = tile.rect
    return CGRect(
        x: source.minX, y: CGFloat(canvas) - source.maxY,
        width: source.width, height: source.height)
}

func draw(_ tile: Tile, above: ArraySlice<Tile>, color: NSColor) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let gap = CGFloat(canvas / 32)
    let padding = (margin * gap).rounded()
    context.clip(
        to: CGRect(
            x: padding, y: padding, width: CGFloat(canvas) - 2 * padding,
            height: CGFloat(canvas) - 2 * padding))
    let face = upright(tile)
    let radius = min(12, min(face.width, face.height) * 0.12)
    context.addPath(CGPath(roundedRect: face, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(color.cgColor)
    context.fillPath()
    // A later tile's black outline covers any earlier face beneath it.
    // Cut that overlap out of this layer, leaving the separators on the
    // background while preserving the original cascade geometry.
    context.setBlendMode(.clear)
    for later in above {
        let cover = upright(later).insetBy(dx: -gap, dy: -gap)
        let coverRadius = min(12, min(cover.width, cover.height) * 0.12)
        context.addPath(
            CGPath(
                roundedRect: cover, cornerWidth: coverRadius,
                cornerHeight: coverRadius, transform: nil))
        context.fillPath()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writeIcon(name: String, color: NSColor) throws {
    let folder = "\(resources)/\(name).icon"
    try? FileManager.default.removeItem(atPath: folder)
    try FileManager.default.createDirectory(atPath: "\(folder)/Assets", withIntermediateDirectories: true)
    var groups: [[String: Any]] = []
    let tileLayout = tiles()
    for level in (0..<depth).reversed() {
        var layers: [[String: Any]] = []
        // Icon Composer lists the top layer first within each group.
        for (order, tile) in tileLayout.enumerated().filter({ $0.element.level == level }).reversed() {
            let filename = "Tile-\(tile.level)-\(tile.index).png"
            try draw(tile, above: tileLayout[(order + 1)...], color: color)
                .representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: "\(folder)/Assets/\(filename)"))
            layers.append(["glass": true, "image-name": filename, "name": "Tile \(tile.level)-\(tile.index)"])
        }
        groups.append([
            "layers": layers,
            "shadow": ["kind": "none", "opacity": 0.5],
            "specular": true,
            "translucency": ["enabled": true, "value": 0.35],
        ])
    }
    let icon: [String: Any] = [
        "fill": ["solid": "extended-srgb:0.00000,0.00000,0.00000,1.00000"],
        "groups": groups,
        "supported-platforms": ["squares": ["macOS"]],
    ]
    let json = try JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: "\(folder)/icon.json"))
}

let amber = NSColor(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255, alpha: 1)
try writeIcon(name: "AppIcon", color: .white)
try writeIcon(name: "AppIconDev", color: amber)

// Use the native rendering for the README preview.
let select = Process()
select.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
select.arguments = ["-p"]
let selectedPath = Pipe()
select.standardOutput = selectedPath
try select.run()
select.waitUntilExit()
guard select.terminationStatus == 0,
    let developerDirectory = String(
        data: selectedPath.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
else { fatalError("Could not locate Xcode") }
let composer = URL(fileURLWithPath: developerDirectory).deletingLastPathComponent()
    .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
let preview = Process()
preview.executableURL = composer
preview.arguments = [
    "\(resources)/AppIcon.icon", "--export-image",
    "--output-file", "docs/images/icon.png", "--platform", "macOS",
    "--rendition", "Default", "--width", "256", "--height", "256",
    "--scale", "1", "--design-generation", "27",
]
try preview.run()
preview.waitUntilExit()
guard preview.terminationStatus == 0 else {
    fatalError("Icon Composer could not export the README preview")
}
print("Icons written to \(resources) and docs/images/icon.png")
