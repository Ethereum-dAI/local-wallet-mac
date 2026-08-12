import Foundation
import LocalAuthentication
import Testing
@testable import WalletMacOSApp

private enum AuthenticationPolicyTestError: Error {
    case evaluationFailed
    case operationFailed
}

@Test @MainActor func actionAuthenticationSharesOneContextAndInvalidatesAfterSuccess() async throws {
    let context = LAContext()
    var evaluatedContext: LAContext?
    var consumedContexts: [LAContext] = []
    var invalidatedContexts: [LAContext] = []

    let session = DeviceOwnerAuthenticationSession(
        reason: "Approve the test action",
        context: context,
        evaluator: { receivedContext, policy, reason in
            evaluatedContext = receivedContext
            #expect(policy == .deviceOwnerAuthentication)
            #expect(reason == "Approve the test action")
            return true
        },
        invalidator: { invalidatedContexts.append($0) }
    )

    let result = try await session.withAuthorizedContext { authorizedContext in
        consumedContexts.append(authorizedContext)
        consumedContexts.append(authorizedContext)
        return "done"
    }

    #expect(result == "done")
    #expect(evaluatedContext === context)
    #expect(consumedContexts.count == 2)
    #expect(consumedContexts.allSatisfy { $0 === context })
    #expect(invalidatedContexts.count == 1)
    #expect(invalidatedContexts.first === context)
    #expect(session.isInvalidated)
}

@Test @MainActor func actionAuthenticationInvalidatesWhenOperationThrows() async {
    let context = LAContext()
    var invalidationCount = 0
    let session = DeviceOwnerAuthenticationSession(
        reason: "Approve the test action",
        context: context,
        evaluator: { _, _, _ in true },
        invalidator: { receivedContext in
            #expect(receivedContext === context)
            invalidationCount += 1
        }
    )

    await #expect(throws: AuthenticationPolicyTestError.operationFailed) {
        try await session.withAuthorizedContext { _ in
            throw AuthenticationPolicyTestError.operationFailed
        }
    }

    #expect(invalidationCount == 1)
    session.invalidate()
    #expect(invalidationCount == 1)
}

@Test @MainActor func actionAuthenticationInvalidatesWhenEvaluationFails() async {
    var invalidationCount = 0
    let session = DeviceOwnerAuthenticationSession(
        reason: "Approve the test action",
        evaluator: { _, _, _ in throw AuthenticationPolicyTestError.evaluationFailed },
        invalidator: { _ in invalidationCount += 1 }
    )

    await #expect(throws: AuthenticationPolicyTestError.evaluationFailed) {
        try await session.withAuthorizedContext { _ in
            Issue.record("The operation must not run after failed authentication")
        }
    }

    #expect(invalidationCount == 1)
    #expect(session.isInvalidated)
}

@Test @MainActor func actionAuthenticationInvalidatesWhenEvaluationIsCancelled() async {
    var operationRan = false
    var invalidationCount = 0
    let session = DeviceOwnerAuthenticationSession(
        reason: "Approve the test action",
        evaluator: { _, _, _ in throw CancellationError() },
        invalidator: { _ in invalidationCount += 1 }
    )

    await #expect(throws: CancellationError.self) {
        try await session.withAuthorizedContext { _ in
            operationRan = true
        }
    }

    #expect(!operationRan)
    #expect(invalidationCount == 1)
}

@Test func protectedSecretStoresDoNotCachePlaintextOrAuthenticationWindows() throws {
    let bundlerSource = try authenticationSource(named: "BundlerKeyStore.swift")
    let railgunSource = try authenticationSource(named: "RailgunSecretsStore.swift")

    #expect(!bundlerSource.contains("BundlerSecretPromptCache"))
    #expect(!bundlerSource.contains("BundlerSecretPromptReusePolicy"))
    #expect(!bundlerSource.contains("touchIDAuthenticationAllowableReuseDuration"))
    #expect(!bundlerSource.contains("unlockAllForDaemonLaunch"))
    #expect(!bundlerSource.contains("unlockAllForOnboardingDaemonLaunch"))
    #expect(!railgunSource.contains("touchIDAuthenticationAllowableReuseDuration"))
}

private func authenticationSource(named fileName: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: packageRoot
            .appendingPathComponent("Sources/WalletMacOSApp")
            .appendingPathComponent(fileName),
        encoding: .utf8
    )
}
