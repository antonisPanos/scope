import AppKit
import Foundation

/// Mounting disk images with `diskutil image attach`, Apple's supported tool
/// (hdiutil's attach is deprecated). The App Sandbox doesn't allow starting
/// it, so this works in unsandboxed builds only. Ejecting is in `Volumes`.
extension FileEngine {
    public static let diskImageExtensions: Set<String> = ["dmg", "iso", "sparseimage", "sparsebundle", "cdr", "img"]

    public static func isDiskImage(_ url: URL) -> Bool {
        diskImageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Mounts an image and returns where it appeared: under /Volumes, or at
    /// `mountPoint` when one is given (which must pass the write check).
    @discardableResult
    func mountImage(_ image: URL, readOnly: Bool, mountPoint: URL?, passphrase: String? = nil) async throws -> URL? {
        let imagePath = try pathGuard.checkLocation(image)
        if let mountPoint {
            try pathGuard.checkWriteLocation(mountPoint)
            // diskutil makes the mount point itself, but its folder must exist.
            try FileManager.default.createDirectory(
                at: mountPoint.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil else {
            throw OperationError.needsUnsandboxedBuild
        }

        var arguments = ["image", "attach", "--plist"]
        if readOnly { arguments.append("--readOnly") }
        if passphrase != nil { arguments.append("--stdinpassphrase") }
        if let mountPoint { arguments += ["--mountPoint", mountPoint.path] }
        arguments.append(imagePath.path)

        let output = try await Self.runTool("/usr/sbin/diskutil", arguments, input: passphrase, timeout: 60)
        guard output.status == 0 else {
            let message = output.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OperationError.mountFailed(
                message.isEmpty ? "“\(image.lastPathComponent)” couldn't be mounted." : message)
        }
        return Self.mountPoint(fromPlist: output.standardOutput) ?? mountPoint
    }

    private static func mountPoint(fromPlist data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        // Find any "mount-point" value in whatever structure diskutil returns.
        func search(_ value: Any) -> String? {
            if let dictionary = value as? [String: Any] {
                for (key, inner) in dictionary {
                    if key.lowercased().replacingOccurrences(of: "-", with: "") == "mountpoint",
                        let path = inner as? String
                    {
                        return path
                    }
                    if let found = search(inner) { return found }
                }
            } else if let array = value as? [Any] {
                for inner in array { if let found = search(inner) { return found } }
            }
            return nil
        }
        return search(plist).map { URL(fileURLWithPath: $0) }
    }

    struct ToolOutput: Sendable {
        var status: Int32
        var standardOutput: Data
        var error: String
    }

    /// Runs a system tool with a timeout, off the main thread. Cancelling the
    /// task terminates the tool, so a stuck image never hangs the operation.
    static func runTool(
        _ path: String, _ arguments: [String], input: String?, timeout: TimeInterval
    ) async throws -> ToolOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        let box = ProcessBox(process)
        // Both outputs are read while the tool runs: a pipe holds only 64 KB,
        // and a tool that fills it would wait until the timeout killed it.
        let collected = ToolOutputCollector()
        let reading = DispatchGroup()
        reading.enter()
        reading.enter()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ToolOutput, Error>) in
                process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    reading.notify(queue: .global()) {
                        let (output, error) = collected.result
                        continuation.resume(
                            returning: ToolOutput(
                                status: status, standardOutput: output, error: String(decoding: error, as: UTF8.self)))
                    }
                }
                do {
                    try process.run()
                } catch {
                    reading.leave()
                    reading.leave()
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global().async {
                    collected.setOutput(stdout.fileHandleForReading.readDataToEndOfFile())
                    reading.leave()
                }
                DispatchQueue.global().async {
                    collected.setError(stderr.fileHandleForReading.readDataToEndOfFile())
                    reading.leave()
                }
                if let input { stdin.fileHandleForWriting.write(Data((input + "\n").utf8)) }
                try? stdin.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.terminate() }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// A tool's two outputs, filled in by the threads that read them.
private final class ToolOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()

    func setOutput(_ data: Data) { lock.withLock { output = data } }
    func setError(_ data: Data) { lock.withLock { error = data } }
    var result: (Data, Data) { lock.withLock { (output, error) } }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}
