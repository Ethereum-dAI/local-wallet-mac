import Foundation
import Testing
@testable import WalletMacOSApp

struct ModelDownloadProgressTests {
    @Test func firstSampleReportsBytesWithoutInventingARate() {
        let estimator = ModelDownloadProgressEstimator(startedAt: Date(timeIntervalSince1970: 100))
        let progress = estimator.record(
            totalBytesWritten: 1_280_000_000,
            totalBytesExpectedToWrite: 5_340_000_000,
            at: Date(timeIntervalSince1970: 105)
        )

        #expect(progress.fractionCompleted > 0.23)
        #expect(progress.fractionCompleted < 0.25)
        #expect(progress.bytesPerSecond == nil)
        #expect(progress.estimatedSecondsRemaining == nil)
        #expect(progress.statusText == "1.28 of 5.34 GB")
    }

    @Test func laterSamplesSmoothSpeedAndDeriveETA() {
        let estimator = ModelDownloadProgressEstimator(
            startedAt: Date(timeIntervalSince1970: 100),
            smoothingFactor: 0.25
        )
        _ = estimator.record(
            totalBytesWritten: 0,
            totalBytesExpectedToWrite: 5_340_000_000,
            at: Date(timeIntervalSince1970: 100)
        )
        let first = estimator.record(
            totalBytesWritten: 100_000_000,
            totalBytesExpectedToWrite: 5_340_000_000,
            at: Date(timeIntervalSince1970: 110)
        )
        let smoothed = estimator.record(
            totalBytesWritten: 300_000_000,
            totalBytesExpectedToWrite: 5_340_000_000,
            at: Date(timeIntervalSince1970: 120)
        )

        #expect(first.bytesPerSecond == 10_000_000)
        #expect(smoothed.bytesPerSecond == 12_500_000)
        #expect(smoothed.estimatedSecondsRemaining == 403.2)
        #expect(smoothed.statusText == "300 MB of 5.34 GB — 12.5 MB/s — about 7 min left")
    }

    @Test func fractionIsBoundedAndCompletionHasNoETA() {
        let progress = ModelDownloadProgress(
            completedBytes: 8_000,
            totalBytes: 4_000,
            bytesPerSecond: 2_000
        )

        #expect(progress.fractionCompleted == 1)
        #expect(progress.estimatedSecondsRemaining == 0)
        #expect(progress.statusText == "4 of 4 KB — 2.0 KB/s")
    }

    @Test func visibleChangesFollowRenderedTelemetry() {
        let original = ModelDownloadProgress(
            completedBytes: 1_001_000_000,
            totalBytes: 5_340_000_000,
            bytesPerSecond: 10_020_000
        )
        let visuallyIdentical = ModelDownloadProgress(
            completedBytes: 1_004_000_000,
            totalBytes: 5_340_000_000,
            bytesPerSecond: 10_040_000
        )
        let changed = ModelDownloadProgress(
            completedBytes: 1_020_000_000,
            totalBytes: 5_340_000_000,
            bytesPerSecond: 10_500_000
        )

        #expect(!visuallyIdentical.isVisibleChange(from: original))
        #expect(changed.isVisibleChange(from: original))
    }
}
