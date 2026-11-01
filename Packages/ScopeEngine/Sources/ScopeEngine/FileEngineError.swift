import Foundation

public enum FileEngineError: Error, Equatable, LocalizedError {
    case destinationExists(String)
    case sourceMissing(String)
    case invalidName(String)
    case cannotCopyIntoItself(String)
    /// Moves between disks arrive with the operations queue in milestone M3.
    case crossVolumeMoveNotSupported(String)
    case system(operation: String, path: String, code: Int32)
    case tooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .destinationExists(let path): "An item named \((path as NSString).lastPathComponent) already exists."
        case .sourceMissing(let path): "\(path) no longer exists."
        case .invalidName(let name): "\"\(name)\" is not a valid file name."
        case .cannotCopyIntoItself(let path): "Can't copy \(path) into itself."
        case .crossVolumeMoveNotSupported(let path): "Moving \(path) to another disk is not supported yet."
        case .tooLarge(let path): "\((path as NSString).lastPathComponent) is too large to open here."
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
