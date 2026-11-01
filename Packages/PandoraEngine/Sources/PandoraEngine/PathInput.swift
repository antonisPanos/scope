import Foundation

/// Turns what someone typed into the path bar into a file URL.
///
/// Accepts absolute paths, `~` and `~/…`, `$HOME`, `file://` URLs, paths
/// relative to the current folder (including `..`), and paths pasted with
/// surrounding quotes or a trailing newline. The result is only a candidate:
/// it still has to pass the path guard and exist.
public enum PathInput {
    public static func resolve(_ text: String, relativeTo current: URL?, home: URL) -> URL? {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2, let first = path.first, first == path.last, first == "\"" || first == "'" {
            path = String(path.dropFirst().dropLast())
        }
        guard !path.isEmpty else { return nil }

        if path.lowercased().hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }
        if path == "~" || path == "$HOME" {
            return home.standardizedFileURL
        }
        if path.hasPrefix("~/") {
            path = home.path + path.dropFirst(1)
        } else if path.hasPrefix("$HOME/") {
            path = home.path + path.dropFirst(5)
        }
        // Terminal-style escaped spaces ("My\ Folder").
        path = path.replacingOccurrences(of: "\\ ", with: " ")

        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        guard let current else { return nil }
        return current.appendingPathComponent(path).standardizedFileURL
    }
}
