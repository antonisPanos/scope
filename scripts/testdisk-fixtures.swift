// Fixtures that need Foundation: Finder aliases, Finder tags, Recents and images.
// Called by testdisk.sh with the test disk's mount point.
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count == 2, arguments[1] == "/Volumes/PandoraTest" else {
    FileHandle.standardError.write(Data("usage: testdisk-fixtures.swift /Volumes/PandoraTest\n".utf8))
    exit(1)
}
let root = URL(fileURLWithPath: arguments[1])

func makeAlias(to target: String, at alias: String) throws {
    let targetURL = root.appendingPathComponent(target)
    let data = try targetURL.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
    try URL.writeBookmarkData(data, to: root.appendingPathComponent(alias))
}

func tag(_ path: String, _ tags: [String]) throws {
    var url = root.appendingPathComponent(path)
    var values = URLResourceValues()
    values.tagNames = tags
    try url.setResourceValues(values)
}

try makeAlias(to: "links/target.txt", at: "links/alias to file")
try makeAlias(to: "links/target-folder", at: "links/alias to folder")
try makeAlias(to: "packages/Fake App.app", at: "links/alias to app")

try FileManager.default.createDirectory(at: root.appendingPathComponent("attributes/tagged"), withIntermediateDirectories: true)
for (name, tags) in [("red.txt", ["Red"]), ("work-and-blue.txt", ["Work", "Blue"]), ("custom-tag.txt", ["Pandora fixture"])] {
    let path = "attributes/tagged/\(name)"
    try Data("tagged\n".utf8).write(to: root.appendingPathComponent(path))
    try tag(path, tags)
}
try tag("attributes/tagged", ["Green"])

// Recents: Finder's Recents lists files with a recent "last used" date, which
// macOS keeps in this extended attribute (a timespec). Mark a few files used
// over the last few days so Pandora's Recents has something to show.
func markUsed(_ path: String, daysAgo: Double) {
    let date = Date().addingTimeInterval(-daysAgo * 24 * 3600)
    var time = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
    let url = root.appendingPathComponent(path)
    _ = withUnsafeBytes(of: &time) { bytes in
        setxattr(url.path, "com.apple.lastuseddate#PS", bytes.baseAddress, bytes.count, 0, 0)
    }
}
markUsed("README.txt", daysAgo: 0)
markUsed("names/🦊 fox 🚀.txt", daysAgo: 1)
markUsed("sizes/1mb.bin", daysAgo: 2)
markUsed("archives/sample.zip", daysAgo: 3)
markUsed("attributes/tagged/red.txt", daysAgo: 4)

// Images for thumbnails and the preview pane: a JPEG with camera data and a PNG.
func writeImage(_ path: String, type: CFString, width: Int, height: Int, hue: CGFloat, exif: Bool) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    let colors = [CGColor(red: hue, green: 0.5, blue: 1 - hue, alpha: 1), CGColor(red: 1 - hue, green: 0.8, blue: hue, alpha: 1)]
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    context.setFillColor(CGColor(gray: 1, alpha: 0.85))
    context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    guard let image = context.makeImage() else { return }
    let url = root.appendingPathComponent(path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, type, 1, nil) else { return }
    var properties: [CFString: Any] = [:]
    if exif {
        properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Pandora", kCGImagePropertyTIFFModel: "Fixture Camera"]
        properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:31 12:00:00"]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
}

try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
try writeImage("images/photo.jpg", type: "public.jpeg" as CFString, width: 1600, height: 1200, hue: 0.2, exif: true)
try writeImage("images/diagram.png", type: "public.png" as CFString, width: 800, height: 600, hue: 0.7, exif: false)
for index in 1...12 {
    try writeImage("images/gallery-\(String(format: "%02d", index)).jpg", type: "public.jpeg" as CFString,
                   width: 640, height: 480, hue: CGFloat(index) / 12, exif: true)
}
