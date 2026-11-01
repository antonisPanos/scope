// Fixtures that need Foundation: Finder aliases and Finder tags.
// Called by testdisk.sh with the test disk's mount point.
import Foundation

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
