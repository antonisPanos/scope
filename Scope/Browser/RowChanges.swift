import Foundation
import ScopeEngine

extension FolderListing.RowChanges {
    /// `rows` with these changes made: the removed rows dropped, then a row
    /// from `makeRow` at each inserted index. Rows that are only redrawn stay
    /// as they are. Nil when the changes don't fit `rows` and `newCount`, so
    /// the caller reloads everything instead.
    func applied<Row>(to rows: [Row], newCount: Int, makeRow: (Int) -> Row) -> [Row]? {
        guard rows.count - removed.count + inserted.count == newCount,
            removed.allSatisfy({ $0 < rows.count }),
            inserted.allSatisfy({ $0 < newCount }),
            reloaded.allSatisfy({ $0 < newCount })
        else { return nil }
        var result = rows
        for index in removed.reversed() { result.remove(at: index) }
        // In ascending order each row lands at its final index.
        for index in inserted { result.insert(makeRow(index), at: index) }
        return result
    }
}
