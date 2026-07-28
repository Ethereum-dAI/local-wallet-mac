import Foundation
import Security
import Testing
@testable import WalletMacOSApp

// Regression coverage for onboarding dead-ending on a raw `OSStatus -25293`
// (`errSecAuthFailed`) while creating or unlocking the local relayer key.
//
// The relayer secret was protected with `.biometryCurrentSet`, which binds the item to the
// exact biometric set enrolled at creation time and offers no password fallback. Changed
// enrollment, unavailable Touch ID, or a failed/cancelled prompt therefore blocked
// onboarding outright — and the error surfaced as a bare OSStatus number.

@Test func relayerSecretAllowsPasswordFallback() {
    let flags = BundlerKeyStore.secretAccessFlags
    #expect(flags.contains(.userPresence))
    // .biometryCurrentSet has no password fallback and invalidates on re-enrollment.
    #expect(!flags.contains(.biometryCurrentSet))
}

@Test func relayerSecretPolicyMatchesWalletRootPolicy() {
    // The relayer key must not be protected more strictly than the Secure Enclave key that
    // actually controls the funds; a stricter relayer policy is what dead-ended onboarding.
    let walletFlags = KeyStore.KeyAccessPolicy.standardWallet.accessFlags
    #expect(walletFlags.contains(.userPresence))
    #expect(BundlerKeyStore.secretAccessFlags.contains(.userPresence))
}

@Test func authenticationFailureIsExplainedNotJustNumbered() {
    let error = BundlerKeyStore.describeSecurityStatus(errSecAuthFailed)
    let message = error.localizedDescription

    // The whole point of the fix: no more "The operation couldn't be completed.
    // (OSStatus error -25293.)" with nothing actionable in it.
    #expect(!message.contains("-25293"))
    #expect(!message.isEmpty)
    // Must name the failed operation and a recovery path.
    #expect(message.lowercased().contains("relayer"))
    #expect(message.lowercased().contains("password") || message.lowercased().contains("touch id"))
}

@Test func userCancellationMapsToCancellationError() {
    guard case .userAuthorizationCancelled? = BundlerKeyStore
        .describeSecurityStatus(errSecUserCanceled) as? AppError
    else {
        Issue.record("errSecUserCanceled should map to AppError.userAuthorizationCancelled")
        return
    }
}

@Test func missingEntitlementMappingIsPreserved() {
    guard case .missingEntitlement? = BundlerKeyStore
        .describeSecurityStatus(errSecMissingEntitlement) as? AppError
    else {
        Issue.record("errSecMissingEntitlement should still map to AppError.missingEntitlement")
        return
    }
}

@Test func authenticationFailureMapsToTheRelayerSpecificError() {
    guard case .localRelayerKeyAuthorizationFailed? = BundlerKeyStore
        .describeSecurityStatus(errSecAuthFailed) as? AppError
    else {
        Issue.record("errSecAuthFailed should map to AppError.localRelayerKeyAuthorizationFailed")
        return
    }
}

@Test func unrecognizedStatusStillCarriesTheOSStatus() {
    // Unknown failures must stay diagnosable rather than being flattened into a generic message.
    let error = BundlerKeyStore.describeSecurityStatus(errSecDuplicateItem) as NSError
    #expect(error.domain == NSOSStatusErrorDomain)
    #expect(error.code == Int(errSecDuplicateItem))
}
