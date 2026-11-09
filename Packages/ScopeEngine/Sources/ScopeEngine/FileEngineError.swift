import Foundation

/// The destination exists, but Scope could not complete its sync. Callers
/// must preserve and account for it instead of retrying as an unpublished copy.
public struct PublishedCopyFinalizationError: Error, LocalizedError {
    public let destination: URL
    public let reason: String
    /// Identity of the staged object that was published, not a later occupant
    /// of the destination path. Directory versions may be unavailable.
    public let publishedIdentity: FileIdentity

    public var errorDescription: String? {
        "The copy at “\(destination.lastPathComponent)” was published, but finalizing it failed: \(reason)"
    }
}

public enum FileEngineError: Error, Equatable, LocalizedError {
    case destinationExists(String)
    case sourceMissing(String)
    case invalidName(String)
    case cannotCopyIntoItself(String)
    /// Moves between disks arrive with the operations queue in milestone M3.
    case crossVolumeMoveNotSupported(String)
    case system(operation: String, path: String, code: Int32)
    case tooLarge(String)
    /// A named pipe, socket or device file, which a copy can't reproduce.
    case unsupportedItem(String, kind: String)

    public var errorDescription: String? {
        switch self {
        case .destinationExists(let path): "An item named \((path as NSString).lastPathComponent) already exists."
        case .sourceMissing(let path): "\(path) no longer exists."
        case .invalidName(let name): "\"\(name)\" is not a valid file name."
        case .cannotCopyIntoItself(let path): "Can't copy \(path) into itself."
        case .crossVolumeMoveNotSupported(let path): "Moving \(path) to another disk is not supported yet."
        case .tooLarge(let path): "\((path as NSString).lastPathComponent) is too large to open here."
        case .unsupportedItem(let path, let kind): "\(path) is \(kind), which Scope can't copy."
        case .system(let operation, let path, let code):
            "\(operation) failed for \(path): \(String(cString: strerror(code)))"
        }
    }

    static func posix(_ operation: String, _ path: String, _ code: Int32 = errno) -> FileEngineError {
        switch code {
        case EEXIST: .destinationExists(path)
        case ENOENT: .sourceMissing(path)
        default: .system(operation: operation, path: path, code: code)
        }
    }
}
