import Foundation
import Testing
@testable import WalletMacOSApp

private func freshSessionSettingsStore() -> DemoSettingsStore {
    let suite = UserDefaults(suiteName: "session-policy-tests-\(UUID().uuidString)")!
    return DemoSettingsStore(defaults: suite)
}

@Test func defaultSessionPolicyMatchesSpecAndCodableRoundTrips() throws {
    let policy = SessionPolicyConfig.default

    #expect(policy.perTxValueLimitWei == "100000000000000000")
    #expect(policy.rateLimitCount == 20)
    #expect(policy.rateLimitIntervalSec == 86_400)
    #expect(policy.ttlSeconds == 604_800)
    #expect(policy.gasBudgetWei == "50000000000000000")
    #expect(policy.allowlist.nativeTransfers == true)
    #expect(policy.allowlist.erc20TokenScope == .knownList)
    #expect(policy.allowlist.swapRouter == true)

    let encoded = try JSONEncoder().encode(policy)
    let decoded = try JSONDecoder().decode(SessionPolicyConfig.self, from: encoded)
    #expect(decoded == policy)
}

@Test func demoSettingsStorePersistsSessionToggleAndPolicy() {
    let store = freshSessionSettingsStore()
    #expect(store.sessionKeysEnabled == false)
    #expect(store.sessionPolicy == .default)

    var policy = SessionPolicyConfig.default
    policy.perTxValueLimitWei = "200000000000000000"
    policy.rateLimitCount = 5
    policy.allowlist.swapRouter = false

    store.setSessionKeysEnabled(true)
    store.setSessionPolicy(policy)

    let reloaded = DemoSettingsStore(defaults: store.defaults)
    #expect(reloaded.sessionKeysEnabled == true)
    #expect(reloaded.sessionPolicy == policy)
}

@Test func sessionPolicyValidationRejectsNonPositiveLimitsAndBadWei() throws {
    _ = try SessionPolicyConfig.default.validated()

    var invalidCount = SessionPolicyConfig.default
    invalidCount.rateLimitCount = 0
    #expect(throws: AppError.self) {
        _ = try invalidCount.validated()
    }

    var invalidWei = SessionPolicyConfig.default
    invalidWei.perTxValueLimitWei = "not-a-number"
    #expect(throws: AppError.self) {
        _ = try invalidWei.validated()
    }
}
