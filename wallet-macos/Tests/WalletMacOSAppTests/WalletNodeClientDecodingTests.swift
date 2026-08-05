import Foundation
import Testing
@testable import WalletMacOSApp

@Suite struct WalletNodeClientDecodingTests {
    @Test func decodesRequiredPrefundFromEstimateResponse() throws {
        let estimate = try WalletNodeClient.decodeGasEstimate([
            "callGasLimit": "0x927c0",
            "verificationGasLimit": "0xf4240",
            "preVerificationGas": "0xd903",
            "requiredPrefund": "0xaa87bee538000",
        ])

        #expect(estimate.callGasLimit == Data(repeating: 0, count: 29) + Data([0x09, 0x27, 0xc0]))
        #expect(estimate.requiredPrefund.count == 32)
        // 0xaa87bee538000 = 0.003 ETH. Asserted as bytes rather than a padded hex
        // literal so the expectation cannot be a miscounted string of zeros.
        #expect(estimate.requiredPrefund
            == Data(repeating: 0, count: 25) + Data([0x0a, 0xa8, 0x7b, 0xee, 0x53, 0x80, 0x00]))
    }

    @Test func absentRequiredPrefundDecodesAsZero() throws {
        // Fail open: an older daemon that omits the field must not synthesise a
        // shortfall. The precheck predicate treats zero as "nothing to check".
        let estimate = try WalletNodeClient.decodeGasEstimate([
            "callGasLimit": "0x927c0",
            "verificationGasLimit": "0xf4240",
            "preVerificationGas": "0xd903",
        ])

        #expect(estimate.requiredPrefund == Data(repeating: 0, count: 32))
    }

    @Test func malformedRequiredPrefundThrows() {
        #expect(throws: (any Error).self) {
            try WalletNodeClient.decodeGasEstimate([
                "callGasLimit": "0x927c0",
                "verificationGasLimit": "0xf4240",
                "preVerificationGas": "0xd903",
                "requiredPrefund": "not-hex",
            ])
        }
    }

    @Test func missingRequiredFieldThrows() {
        #expect(throws: (any Error).self) {
            try WalletNodeClient.decodeGasEstimate(["callGasLimit": "0x927c0"])
        }
    }

    @Test func decodesWalletStatusBalances() throws {
        let status = try WalletNodeClient.WalletStatus(json: [
            "smartAccount": "0xabc",
            "accountBalance": "0x2386f26fc10000",
            "entryPointDeposit": "0x38d7ea4c68000",
            "readyToSend": true,
        ])

        // Asserted as bytes, not trimmed hex: an odd-digit quantity like
        // 0x38d7ea4c68000 normalises to a leading 0x03 nibble-pair, which is not
        // a zero byte to trim.
        #expect(status.accountBalance  // 0.01 ETH
            == Data(repeating: 0, count: 25) + Data([0x23, 0x86, 0xf2, 0x6f, 0xc1, 0x00, 0x00]))
        #expect(status.entryPointDeposit  // 0.001 ETH
            == Data(repeating: 0, count: 25) + Data([0x03, 0x8d, 0x7e, 0xa4, 0xc6, 0x80, 0x00]))
    }

    @Test func walletStatusMissingEitherFieldThrows() {
        #expect(throws: (any Error).self) {
            try WalletNodeClient.WalletStatus(json: ["accountBalance": "0x1"])
        }
        #expect(throws: (any Error).self) {
            try WalletNodeClient.WalletStatus(json: ["entryPointDeposit": "0x1"])
        }
        #expect(throws: (any Error).self) {
            try WalletNodeClient.WalletStatus(json: [
                "accountBalance": "0x1",
                "entryPointDeposit": "nope",
            ])
        }
    }
}
