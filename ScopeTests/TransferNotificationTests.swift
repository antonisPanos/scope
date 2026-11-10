import Testing

@testable import Scope

@MainActor struct TransferNotificationTests {
    @Test func completionWithSkipsIsNotReportedAsOrdinaryDone() {
        #expect(SystemNotifier.completionSubtitle(skippedCount: 2, duration: 5) == "Completed with skipped items")
        #expect(SystemNotifier.completionSubtitle(skippedCount: 0, duration: 5).hasPrefix("Done in "))
    }

    @Test func transferBytesDoNotClaimRenamedOrSkippedDataWasCopied() {
        #expect(SystemNotifier.completionBytes(transferredBytes: 0, progressBytes: 42) == 0)
        #expect(SystemNotifier.completionBytes(transferredBytes: 5, progressBytes: 10) == 5)
        #expect(SystemNotifier.completionBytes(transferredBytes: nil, progressBytes: 10) == 10)
    }
}
