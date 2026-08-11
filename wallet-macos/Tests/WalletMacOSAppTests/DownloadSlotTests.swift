import Testing
@testable import WalletMacOSApp

/// `DownloadSlot` is the single-occupant bookkeeping `LocalAIModelDownloadManager`
/// uses to refuse a second concurrent download instead of silently cross-wiring two
/// in-flight downloads (task A's bytes landing on task B's destination, verified
/// against task B's checksum) or abandoning a continuation that never resumes.
/// These tests drive the generic type directly with a plain `String` occupant, with
/// no URLSession/network involvement.
struct DownloadSlotTests {
    @Test func claimingAnEmptySlotSucceeds() {
        let slot = DownloadSlot<String>()
        #expect(slot.claim("a") == true)
        #expect(slot.current() == "a")
    }

    @Test func claimingAnOccupiedSlotFailsAndLeavesTheOriginalOccupantIntact() {
        let slot = DownloadSlot<String>()
        #expect(slot.claim("a") == true)
        #expect(slot.claim("b") == false)
        #expect(slot.current() == "a")
    }

    @Test func releaseReturnsTheOccupantAndEmptiesTheSlotSoASubsequentClaimSucceeds() {
        let slot = DownloadSlot<String>()
        #expect(slot.claim("a") == true)
        #expect(slot.release() == "a")
        #expect(slot.current() == nil)
        #expect(slot.claim("b") == true)
        #expect(slot.current() == "b")
    }

    @Test func releaseOnAnEmptySlotReturnsNilAndDoesNotTrap() {
        let slot = DownloadSlot<String>()
        #expect(slot.release() == nil)
    }

    /// Models two overlapping `download(...)` calls racing to claim the same slot:
    /// the first wins, the second must be refused rather than overwrite it.
    @Test func overlappingClaimsModelTheOverlappingDownloadCaseAndTheSecondIsRefused() {
        let slot = DownloadSlot<String>()
        let first = slot.claim("download-a")
        let second = slot.claim("download-b")
        #expect(first == true)
        #expect(second == false)
        #expect(slot.current() == "download-a")
    }
}
