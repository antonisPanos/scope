import Foundation
import Synchronization
import Testing

@testable import ScopeEngine

struct ConflictPolicyTests {
    private func conflict(_ incoming: ConflictItemKind, _ existing: ConflictItemKind) -> Conflict {
        Conflict(
            incoming: URL(fileURLWithPath: "/incoming/item"),
            existing: URL(fileURLWithPath: "/existing/item"),
            incomingKind: incoming, existingKind: existing)
    }

    @Test func rememberedAnswersUseOrderedItemKinds() async throws {
        let asked = Mutex<[Conflict]>([])
        var policy = ConflictPolicy { conflict in
            let count = asked.withLock { asked in
                asked.append(conflict)
                return asked.count
            }
            return (count == 1 ? .replace : .skip, true)
        }
        let file = conflict(.file, .file)
        let folder = conflict(.directory, .directory)
        let fileToFolder = conflict(.file, .directory)
        let folderToFile = conflict(.directory, .file)
        let link = conflict(.symbolicLink, .file)
        #expect(try await policy.resolve(file) == .replace)
        #expect(try await policy.resolve(folder) == .skip)
        #expect(try await policy.resolve(fileToFolder) == .skip)
        #expect(try await policy.resolve(folderToFile) == .skip)
        #expect(try await policy.resolve(link) == .skip)
        #expect(try await policy.resolve(file) == .replace)
        #expect(try await policy.resolve(folder) == .skip)
        #expect(asked.withLock { $0 } == [file, folder, fileToFolder, folderToFile, link])
    }

    @Test func unknownKindsAreNeverRemembered() async throws {
        let count = Mutex(0)
        var policy = ConflictPolicy { _ in
            count.withLock { $0 += 1 }
            return (.replace, true)
        }
        let unknown = conflict(.unknown, .directory)
        _ = try await policy.resolve(unknown)
        _ = try await policy.resolve(unknown)
        #expect(count.withLock { $0 } == 2)
    }

    @Test func onlyExplicitlyRememberedAnswersAreReused() async throws {
        let count = Mutex(0)
        var policy = ConflictPolicy { _ in
            let number = count.withLock { count in
                count += 1
                return count
            }
            return number == 1 ? (.keepBoth, false) : (.replaceIfOlder, true)
        }
        let item = conflict(.symbolicLink, .symbolicLink)
        #expect(try await policy.resolve(item) == .keepBoth)
        #expect(try await policy.resolve(item) == .replaceIfOlder)
        #expect(try await policy.resolve(item) == .replaceIfOlder)
        #expect(count.withLock { $0 } == 2)
    }

    @Test func cancellationWhileAnsweringWins() async throws {
        let item = conflict(.file, .file)
        let task = Task {
            var policy = ConflictPolicy { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return (.replace, true)
            }
            return try await policy.resolve(item)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationWinsOverRememberedAnswer() async throws {
        let item = conflict(.file, .file)
        let task = Task {
            var policy = ConflictPolicy { _ in (.replace, true) }
            _ = try await policy.resolve(item)
            withUnsafeCurrentTask { $0?.cancel() }
            return try await policy.resolve(item)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
