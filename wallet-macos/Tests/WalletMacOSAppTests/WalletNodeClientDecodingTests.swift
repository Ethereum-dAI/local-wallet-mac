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
        // Kept for wire compatibility with older daemons. Authorization ignores
        // this value and recomputes liability locally, so zero cannot weaken the
        // signing gate.
        let estimate = try WalletNodeClient.decodeGasEstimate([
            "callGasLimit": "0x927c0",
            "verificationGasLimit": "0xf4240",
            "preVerificationGas": "0xd903",
        ])

        #expect(estimate.requiredPrefund == Data(repeating: 0, count: 32))
    }

    @Test func zeroOmittedAndFalseRequiredPrefundAreEquivalent() throws {
        let common: [String: Any] = [
            "callGasLimit": "0x927c0",
            "verificationGasLimit": "0xf4240",
            "preVerificationGas": "0xd903",
        ]
        var explicitZero = common
        explicitZero["requiredPrefund"] = "0x0"
        var falsePrefund = common
        falsePrefund["requiredPrefund"] = false

        let estimates = try [explicitZero, common, falsePrefund].map(
            WalletNodeClient.decodeGasEstimate
        )

        #expect(estimates[0] == estimates[1])
        #expect(estimates[1] == estimates[2])
        #expect(estimates.allSatisfy {
            $0.requiredPrefund == Data(repeating: 0, count: 32)
        })
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

    @Test func acceptsExactThirtyTwoByteDaemonQuantities() throws {
        let maximumWidth = "0x" + String(repeating: "ff", count: 32)
        let estimate = try WalletNodeClient.decodeGasEstimate([
            "callGasLimit": maximumWidth,
            "verificationGasLimit": maximumWidth,
            "preVerificationGas": maximumWidth,
            "requiredPrefund": maximumWidth,
        ])

        #expect(estimate.callGasLimit == Data(repeating: 0xff, count: 32))
        #expect(estimate.verificationGasLimit == Data(repeating: 0xff, count: 32))
        #expect(estimate.preVerificationGas == Data(repeating: 0xff, count: 32))
        #expect(estimate.requiredPrefund == Data(repeating: 0xff, count: 32))
    }

    @Test func rejectsEveryThirtyThreeByteDaemonQuantityWithoutTruncation() {
        let oversized = "0x" + String(repeating: "11", count: 33)
        for field in [
            "callGasLimit",
            "verificationGasLimit",
            "preVerificationGas",
            "requiredPrefund",
        ] {
            var response = [
                "callGasLimit": "0x1",
                "verificationGasLimit": "0x1",
                "preVerificationGas": "0x1",
                "requiredPrefund": "0x1",
            ]
            response[field] = oversized

            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.decodeGasEstimate(response)
            }
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

    @Test func relayerStatusDecodesFullPendingFundingCandidates() throws {
        let firstEOA = "0xA100000000000000000000000000000000000001"
        let secondEOA = "0xb200000000000000000000000000000000000002"
        let firstKeyRef = "bundler-eoa:default:11155111:2"
        let secondKeyRef = "bundler-eoa:default:11155111:3"
        let status = try WalletNodeClient.RelayerStatus(json: relayerJSON(rotation: [
            "rotating": true,
            "pendingFunding": [
                ["eoa": firstEOA, "keyRef": firstKeyRef, "createdAt": 1_723_456_789],
                ["eoa": secondEOA, "keyRef": secondKeyRef, "createdAt": 1_723_456_999],
            ],
            "retiring": [],
        ]))

        #expect(status.pendingFunding == [
            .init(eoa: firstEOA.lowercased(), keyRef: firstKeyRef, createdAt: 1_723_456_789),
            .init(eoa: secondEOA, keyRef: secondKeyRef, createdAt: 1_723_456_999),
        ])
        #expect(status.pendingFundingAddress == firstEOA.lowercased())
        #expect(status.pendingFundingCount == 2)
    }

    @Test func relayerStatusWithoutRotationKeepsCompatibilityAccessorsEmpty() throws {
        let status = try WalletNodeClient.RelayerStatus(json: relayerJSON())

        #expect(status.pendingFunding.isEmpty)
        #expect(status.pendingFundingAddress == nil)
        #expect(status.pendingFundingCount == 0)
    }

    @Test func relayerStatusRejectsMalformedPendingFundingEntries() {
        let valid: [String: Any] = [
            "eoa": "0xa100000000000000000000000000000000000001",
            "keyRef": "bundler-eoa:default:11155111:2",
            "createdAt": 1_723_456_789,
        ]
        let malformedEntries: [[String: Any]] = [
            ["keyRef": valid["keyRef"]!, "createdAt": valid["createdAt"]!],
            ["eoa": valid["eoa"]!, "createdAt": valid["createdAt"]!],
            ["eoa": valid["eoa"]!, "keyRef": valid["keyRef"]!],
            ["eoa": "not-an-address", "keyRef": valid["keyRef"]!, "createdAt": valid["createdAt"]!],
            ["eoa": valid["eoa"]!, "keyRef": "bundler-eoa:default:1:2", "createdAt": valid["createdAt"]!],
            ["eoa": valid["eoa"]!, "keyRef": valid["keyRef"]!, "createdAt": -1],
        ]

        for malformed in malformedEntries {
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: relayerJSON(rotation: [
                    "pendingFunding": [malformed],
                    "retiring": [],
                ]))
            }
        }
    }

    @Test func relayerStatusRejectsMalformedPendingFundingContainersAndDuplicates() {
        let first: [String: Any] = [
            "eoa": "0xa100000000000000000000000000000000000001",
            "keyRef": "bundler-eoa:default:11155111:2",
            "createdAt": 1_723_456_789,
        ]
        let duplicateKeyRef: [String: Any] = [
            "eoa": "0xb200000000000000000000000000000000000002",
            "keyRef": first["keyRef"]!,
            "createdAt": 1_723_456_999,
        ]
        let duplicateEOA: [String: Any] = [
            "eoa": first["eoa"]!,
            "keyRef": "bundler-eoa:default:11155111:3",
            "createdAt": 1_723_456_999,
        ]

        for rotation: Any in [
            "not-an-object",
            ["pendingFunding": "not-an-array"],
            ["pendingFunding": [first, "not-an-entry"]],
            ["pendingFunding": [first, duplicateKeyRef]],
            ["pendingFunding": [first, duplicateEOA]],
        ] {
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: relayerJSON(rotation: rotation))
            }
        }
    }

    private func relayerJSON(rotation: Any? = nil) -> [String: Any] {
        var json: [String: Any] = [
            "ready": true,
            "keyLoaded": true,
            "ownerScope": "default",
            "chainId": 11_155_111,
            "networkProfile": "sepolia",
            "eoa": "0xa000000000000000000000000000000000000001",
            "keyRef": "bundler-eoa:default:11155111:1",
            "balance": "0x2386f26fc10000",
            "thresholdLow": "0x11c37937e08000",
            "needsTopup": false,
            "lifecycle": "active",
        ]
        if let rotation {
            json["rotation"] = rotation
        }
        return json
    }
}
