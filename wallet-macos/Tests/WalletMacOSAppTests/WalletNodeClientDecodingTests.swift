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
}
