import Foundation
import Synchronization

/// A compromised codec may return bytes, but cannot stream unlimited data
/// into the parent's output file. Entry authorization increases this budget.
final class ArchiveWriteBudget: Sendable {
    private struct State {
        var limit: Int64 = 1024 * 1024
        var written: Int64 = 0
        var nextSpaceCheck: Int64 = 0
    }
    private let state = Mutex(State())

    var written: Int64 { state.withLock { $0.written } }

    func authorize(_ entry: ArchiveEntry) throws(ArchiveWriteError) {
        let size = entry.kind == .file ? (entry.size ?? 0) : 0
        let overhead = Int64(8192 + entry.name.utf8.count * 2)
        guard size >= 0 else { throw .failed("Invalid archive input size.") }
        let (expanded, overflow) = size.addingReportingOverflow(size / 8)
        let (allowance, headerOverflow) = expanded.addingReportingOverflow(overhead)
        guard !overflow, !headerOverflow else { throw .failed("The archive is too large.") }
        let accepted = state.withLock { state in
            let (limit, overflow) = state.limit.addingReportingOverflow(allowance)
            guard !overflow else { return false }
            state.limit = limit
            return true
        }
        guard accepted else { throw .failed("The archive is too large.") }
    }

    func accept(_ count: Int, descriptor: Int32) throws(ArchiveWriteError) {
        let result = state.withLock { state -> (accepted: Bool, checkSpace: Bool) in
            guard count >= 0, Int64(count) <= state.limit - state.written else { return (false, false) }
            let check = state.written >= state.nextSpaceCheck
            if check {
                let (next, overflow) = state.written.addingReportingOverflow(Int64(FileEngine.chunkSize))
                state.nextSpaceCheck = overflow ? .max : next
            }
            state.written += Int64(count)
            return (true, check)
        }
        guard result.accepted else { throw .failed("The archive writer exceeded its authorized output size.") }
        if result.checkSpace {
            var info = statfs()
            guard fstatfs(descriptor, &info) == 0 else { throw .failed("Couldn't check space for the archive.") }
            let block = UInt64(info.f_bsize)
            let (capacity, capacityOverflow) = info.f_blocks.multipliedReportingOverflow(by: block)
            let (available, availableOverflow) = info.f_bavail.multipliedReportingOverflow(by: block)
            let reserve = min(UInt64(512 * 1024 * 1024), (capacityOverflow ? UInt64.max : capacity) / 20)
            guard availableOverflow || (available >= reserve && available - reserve >= UInt64(FileEngine.chunkSize))
            else {
                throw .failed("Compression stopped because the disk was almost full. No archive was kept.")
            }
        }
    }
}
