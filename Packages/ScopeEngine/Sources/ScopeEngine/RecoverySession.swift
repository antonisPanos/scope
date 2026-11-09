import Foundation

/// Optional shared recovery configuration. Construction performs no I/O. The
/// caller must share this instance among its engines and call journal() only
/// from the engine I/O executor. The root must already exist and be private.
final class RecoverySession: @unchecked Sendable {
    enum Point: Sendable, Equatable { case intent, staging, publishing, published, resolved }
    private let root: URL
    private let pathGuard: PathGuard
    private let lock = NSLock()
    private var instance: RecoveryJournal?
    private let fault: (@Sendable (Point) throws -> Void)?

    init(root: URL, pathGuard: PathGuard, fault: (@Sendable (Point) throws -> Void)? = nil) {
        self.root = root
        self.pathGuard = pathGuard
        self.fault = fault
    }

    func journal() throws -> RecoveryJournal {
        guard lock.try() else { throw RecoveryJournal.Failure.busy }
        defer { lock.unlock() }
        if let instance { return instance }
        let created = try RecoveryJournal(root: root, pathGuard: pathGuard)
        instance = created
        return created
    }

    func check(_ point: Point) throws { try fault?(point) }
}
