#!/usr/bin/env swift

// Native, offscreen artwork generation. No Finder or graphical session is used.
// Run: swift scripts/dmg/make-background.swift scripts/dmg
import AppKit

private let width = 640
private let height = 400

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

private func drawText(_ text: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (text as NSString).draw(
        in: NSRect(x: 32, y: CGFloat(height) - top - 36, width: CGFloat(width) - 64, height: 36),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
}

private func render(scale: Int, to output: URL) throws {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw CocoaError(.fileWriteUnknown) }
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    color(250, 250, 249).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    drawText("Scope", top: 48, size: 28, weight: .semibold, color: color(28, 28, 30))
    drawText("Drag Scope to Applications to install.", top: 94, size: 16, weight: .regular, color: color(28, 28, 30))
    drawText("Then open Scope from Applications.", top: 332, size: 14, weight: .regular, color: color(107, 107, 112))
    context.setStrokeColor(color(15, 123, 114).cgColor)
    context.setLineWidth(3)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 297, y: 190))
    context.addLine(to: CGPoint(x: 343, y: 190))
    context.move(to: CGPoint(x: 333, y: 200))
    context.addLine(to: CGPoint(x: 343, y: 190))
    context.addLine(to: CGPoint(x: 333, y: 180))
    context.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: output, options: .atomic)
}

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift scripts/dmg/make-background.swift OUTPUT_DIRECTORY")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for scale in 1...2 {
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try render(scale: scale, to: directory.appendingPathComponent(name))
}
