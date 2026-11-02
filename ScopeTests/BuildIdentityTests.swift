import Foundation
import Testing

@testable import Scope
@testable import ScopeEngine

@MainActor struct BuildIdentityTests {
    @Test func developmentChangesStayInScratch() throws {
        let identity = BuildIdentity.current
        #expect(identity.isDevelopment)
        let pathGuard = identity.pathGuard
        let scratchTarget = BuildIdentity.scratchFolder.appendingPathComponent("build-policy-probe")
        #expect(try pathGuard.checkWriteLocation(scratchTarget).lastPathComponent == "build-policy-probe")
        #expect(throws: PathGuardViolation.self) {
            try pathGuard.checkWriteLocation(BuildIdentity.realHome)
        }
    }
}
