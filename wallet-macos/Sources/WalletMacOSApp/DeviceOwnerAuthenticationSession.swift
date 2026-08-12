@preconcurrency import LocalAuthentication

/// Owns one Local Authentication context for exactly one user-initiated action.
///
/// A successful evaluation marks this context as authenticated. Passing that exact context to
/// every Keychain and Secure Enclave operation in the action lets macOS satisfy them without
/// stacking multiple prompts. `withAuthorizedContext` always invalidates the context when the
/// action ends, including evaluation failures, cancellation, and operation errors.
@MainActor
final class DeviceOwnerAuthenticationSession {
    typealias Evaluator = @MainActor (LAContext, LAPolicy, String) async throws -> Bool
    typealias Invalidator = @MainActor (LAContext) -> Void

    let reason: String
    let context: LAContext

    private let evaluator: Evaluator
    private let invalidator: Invalidator
    private(set) var isInvalidated = false

    init(
        reason: String,
        context: LAContext = LAContext(),
        evaluator: Evaluator? = nil,
        invalidator: Invalidator? = nil
    ) {
        self.reason = reason
        self.context = context
        self.evaluator = evaluator ?? Self.evaluate
        self.invalidator = invalidator ?? { $0.invalidate() }
        context.localizedReason = reason
    }

    func authorize() async throws {
        guard !isInvalidated else {
            throw AppError.userAuthorizationCancelled
        }
        let authorized = try await evaluator(context, .deviceOwnerAuthentication, reason)
        guard authorized else {
            throw AppError.userAuthorizationCancelled
        }
    }

    func withAuthorizedContext<Result>(
        _ operation: @MainActor (LAContext) async throws -> Result
    ) async throws -> Result {
        defer { invalidate() }
        try await authorize()
        return try await operation(context)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        invalidator(context)
    }

    private static func evaluate(
        context: LAContext,
        policy: LAPolicy,
        reason: String
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }
}
