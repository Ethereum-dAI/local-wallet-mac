import Testing
@testable import WalletMacOSApp

struct OnboardingModelCardPresentationTests {
    @Test func recommendedModelUsesShortSelectionCopy() {
        let presentation = OnboardingModelCardPresentation(
            model: .recommended,
            verdict: .fits
        )

        #expect(presentation.title == "Gemma 4 E4B")
        #expect(presentation.detail == "Fine-tuned for wallet actions and reliable tool use.")
    }

    @Test func onlyActionableFitVerdictsBecomeBadges() {
        #expect(OnboardingModelCardPresentation(model: .recommended, verdict: .fits).fitBadge == nil)
        #expect(OnboardingModelCardPresentation(model: .recommended, verdict: .unknown).fitBadge == nil)
        #expect(OnboardingModelCardPresentation(model: .recommended, verdict: .tight).fitBadge == "Tight")
        #expect(OnboardingModelCardPresentation(model: .recommended, verdict: .wontFit).fitBadge == "Won't fit")
    }
}
