import Foundation
import Testing

@testable import ScopeEngine

struct UniqueNameTests {
    @Test func namesAreGeneratedOnlyAsCollisionsRequire() throws {
        let sandbox = try Sandbox()
        #expect(
            try sandbox.engine.uniqueName("photo.jpg", in: sandbox.root, style: .numbered).lastPathComponent
                == "photo.jpg")
        try sandbox.write("photo.jpg", "first")
        try sandbox.write("photo 2.jpg", "second")
        #expect(
            try sandbox.engine.uniqueName("photo.jpg", in: sandbox.root, style: .numbered).lastPathComponent
                == "photo 3.jpg")
        #expect(
            try sandbox.engine.uniqueName("photo.jpg", in: sandbox.root, style: .copy).lastPathComponent
                == "photo copy.jpg")
        try sandbox.write("photo copy.jpg", "copy")
        try sandbox.write("photo copy 2.jpg", "copy two")
        #expect(
            try sandbox.engine.uniqueName("photo.jpg", in: sandbox.root, style: .copy).lastPathComponent
                == "photo copy 3.jpg")
    }

    @Test func cancelledNameSearchStopsBeforeScanning() async throws {
        let sandbox = try Sandbox()
        let engine = sandbox.engine
        let folder = sandbox.root
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try engine.uniqueName("free.txt", in: folder, style: .copy)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aBatchWithNoCollisionsDoesNotBuildUnusedNames() throws {
        let sandbox = try Sandbox()
        let elapsed = try ContinuousClock().measure {
            for _ in 0..<1_000 {
                _ = try sandbox.engine.uniqueName("free.txt", in: sandbox.root, style: .copy)
            }
        }
        print("1,000 free-name lookups: \(elapsed)")
        #expect(elapsed < .seconds(1) * PerformanceTests.slack)
    }
}
