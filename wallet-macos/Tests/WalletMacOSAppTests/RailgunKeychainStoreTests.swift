import XCTest
import Security
@testable import WalletMacOSApp

// Non-prompting coverage only: SecItemAdd/Delete and attribute-only queries do not evaluate
// the biometric ACL, so these never prompt and run in CI. The full biometric read round-trip
// is verified manually on a Touch-ID-capable device.
final class RailgunKeychainStoreTests: XCTestCase {
    private static let testService = "com.localwallet.railgun-seed.test"

    override func tearDown() {
        try? RailgunSecretsStore.clear(service: Self.testService)
        super.tearDown()
    }

    func testEntropyHexIsWellFormed() throws {
        let hex = try RailgunSecretsStore.makeEntropyHex()
        XCTAssertTrue(hex.hasPrefix("0x"))
        XCTAssertEqual(hex.count, 66) // "0x" + 64
        XCTAssertNotEqual(hex, try RailgunSecretsStore.makeEntropyHex())
    }

    func testClearIsIdempotentWhenAbsent() throws {
        try RailgunSecretsStore.clear(service: Self.testService)
        try RailgunSecretsStore.clear(service: Self.testService) // must not throw when nothing is stored
    }

    func testPrivacySeedAllowsDeviceOwnerAuthenticationFallback() {
        let flags = RailgunSecretsStore.secretAccessFlags
        XCTAssertTrue(flags.contains(.userPresence))
        XCTAssertFalse(flags.contains(.biometryCurrentSet))
        XCTAssertNotEqual(
            RailgunSecretsStore.defaultAccount,
            RailgunSecretsStore.legacyBiometricAccount
        )
    }

    func testPrivacyAuthenticationCancellationHasFriendlyError() {
        guard case .userAuthorizationCancelled? = RailgunSecretsStore
            .describeSecurityStatus(errSecUserCanceled) as? AppError
        else {
            return XCTFail("Cancellation should map to the shared friendly authorization error")
        }
        guard case .userAuthorizationCancelled? = RailgunSecretsStore
            .describeSecurityStatus(errSecAuthFailed) as? AppError
        else {
            return XCTFail("Authentication failure should map to the shared friendly error")
        }
    }

    func testLegacyPlaintextFileIsDeleted() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lw-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("railgun-secrets.json")
        try Data("{}".utf8).write(to: legacy)
        RailgunSecretsStore.deleteLegacyFile(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }
}
