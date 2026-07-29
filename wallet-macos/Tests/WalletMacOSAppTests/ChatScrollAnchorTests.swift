import CoreGraphics
import Foundation
import Testing
@testable import WalletMacOSApp

/// The near-bottom decision behind the chat transcript's follow-scroll. The rest of that
/// behaviour is a SwiftUI layout property the suite can't assert, so this is the one piece
/// worth pinning: get it wrong and either the transcript stops following new messages or it
/// yanks a user who has scrolled up.
@Suite struct ChatScrollAnchorTests {
    private let threshold = ChatScrollAnchor.nearBottomThreshold

    @Test func contentShorterThanContainerIsAlwaysAtBottom() {
        // Nothing to scroll, so the tail is on screen by definition.
        #expect(ChatScrollAnchor.isNearBottom(contentOffsetY: 0, contentHeight: 200, containerHeight: 600))
    }

    @Test func exactlyAtBottomIsNearBottom() {
        #expect(ChatScrollAnchor.isNearBottom(contentOffsetY: 400, contentHeight: 1000, containerHeight: 600))
    }

    @Test func justInsideThresholdIsNearBottom() {
        #expect(
            ChatScrollAnchor.isNearBottom(
                contentOffsetY: 400 - threshold + 1,
                contentHeight: 1000,
                containerHeight: 600
            )
        )
    }

    @Test func exactlyAtThresholdIsNearBottom() {
        #expect(
            ChatScrollAnchor.isNearBottom(
                contentOffsetY: 400 - threshold,
                contentHeight: 1000,
                containerHeight: 600
            )
        )
    }

    @Test func justOutsideThresholdIsNotNearBottom() {
        #expect(
            !ChatScrollAnchor.isNearBottom(
                contentOffsetY: 400 - threshold - 1,
                contentHeight: 1000,
                containerHeight: 600
            )
        )
    }

    @Test func scrolledToTopOfALongTranscriptIsNotNearBottom() {
        #expect(!ChatScrollAnchor.isNearBottom(contentOffsetY: 0, contentHeight: 12_000, containerHeight: 600))
    }

    @Test func zeroHeightContainerDoesNotReportNotAtBottom() {
        // Degenerate geometry during the first layout pass: default to following the tail rather
        // than stranding the transcript with the jump-to-latest button stuck on.
        #expect(ChatScrollAnchor.isNearBottom(contentOffsetY: 0, contentHeight: 0, containerHeight: 0))
    }

    @Test func overscrollPastTheEndIsNearBottom() {
        // Rubber-band overscroll pushes the offset beyond `maxOffset`.
        #expect(ChatScrollAnchor.isNearBottom(contentOffsetY: 460, contentHeight: 1000, containerHeight: 600))
    }
}
