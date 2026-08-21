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
        var json = relayerJSON(rotation: [
            "rotating": true,
            "pendingFunding": [
                ["eoa": firstEOA, "keyRef": firstKeyRef, "createdAt": 1_723_456_789],
                ["eoa": secondEOA, "keyRef": secondKeyRef, "createdAt": 1_723_456_999],
            ],
            "retiring": [],
        ])
        var history = json["keyHistory"] as! [[String: Any]]
        history.append(contentsOf: [
            [
                "ownerScope": "default",
                "chainId": 11_155_111,
                "eoa": firstEOA,
                "keyRef": firstKeyRef,
                "lifecycle": "pending_funding",
                "createdAt": 1_723_456_789,
            ],
            [
                "ownerScope": "default",
                "chainId": 11_155_111,
                "eoa": secondEOA,
                "keyRef": secondKeyRef,
                "lifecycle": "pending_funding",
                "createdAt": 1_723_456_999,
            ],
        ])
        json["keyHistory"] = history
        let status = try WalletNodeClient.RelayerStatus(json: json)

        #expect(status.pendingFunding == [
            .init(eoa: firstEOA.lowercased(), keyRef: firstKeyRef, createdAt: 1_723_456_789),
            .init(eoa: secondEOA, keyRef: secondKeyRef, createdAt: 1_723_456_999),
        ])
        #expect(status.pendingFundingAddress == firstEOA.lowercased())
        #expect(status.pendingFundingCount == 2)
    }

    @Test func relayerStatusWithEmptyRotationKeepsCompatibilityAccessorsEmpty() throws {
        let status = try WalletNodeClient.RelayerStatus(json: relayerJSON())

        #expect(status.pendingFunding.isEmpty)
        #expect(status.pendingFundingAddress == nil)
        #expect(status.pendingFundingCount == 0)
    }

    @Test func relayerHistoryExportMatchesLifecycleAuthority() {
        func entry(_ lifecycle: String) -> WalletNodeClient.RelayerStatus.KeyHistoryEntry {
            .init(
                eoa: "0xa000000000000000000000000000000000000001",
                keyRef: "bundler-eoa:default:11155111:1",
                lifecycle: lifecycle,
                createdAt: 1,
                retiredAt: nil,
                deletedAt: nil,
                lastExportedAt: nil
            )
        }

        #expect(entry("active").canExport)
        #expect(entry("retiring").canExport)
        #expect(!entry("retired").canExport)
        #expect(!entry("deleted").canExport)
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
            ["eoa": valid["eoa"]!, "keyRef": "bundler-eoa:other:11155111:2", "createdAt": valid["createdAt"]!],
            ["eoa": valid["eoa"]!, "keyRef": "bundler-eoa:default:011155111:2", "createdAt": valid["createdAt"]!],
            ["eoa": valid["eoa"]!, "keyRef": "bundler-eoa:default:11155111:02", "createdAt": valid["createdAt"]!],
            ["eoa": valid["eoa"]!, "keyRef": "bundler-eoa:default:11155111:0", "createdAt": valid["createdAt"]!],
            ["eoa": valid["eoa"]!, "keyRef": valid["keyRef"]!, "createdAt": true],
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

    @Test func relayerStatusStrictlyDecodesEveryKeyHistoryEntry() throws {
        let active: [String: Any] = [
            "ownerScope": "default",
            "chainId": 11_155_111,
            "eoa": "0xA000000000000000000000000000000000000001",
            "keyRef": "bundler-eoa:default:11155111:1",
            "lifecycle": "active",
            "createdAt": 1_723_456_700,
        ]
        var validJSON = relayerJSON()
        validJSON["keyHistory"] = [active]
        let decoded = try WalletNodeClient.RelayerStatus(json: validJSON)
        #expect(decoded.keyHistory.count == 1)
        #expect(decoded.keyHistory.first?.eoa ==
            "0xa000000000000000000000000000000000000001")

        let malformedEntries: [[String: Any]] = [
            [
                "keyRef": active["keyRef"]!,
                "lifecycle": "active",
                "createdAt": active["createdAt"]!,
            ],
            [
                "eoa": "not-an-address",
                "keyRef": active["keyRef"]!,
                "lifecycle": "active",
                "createdAt": active["createdAt"]!,
            ],
            [
                "eoa": active["eoa"]!,
                "keyRef": "bundler-eoa:default:1:1",
                "lifecycle": "active",
                "createdAt": active["createdAt"]!,
            ],
            [
                "eoa": active["eoa"]!,
                "keyRef": "bundler-eoa:other:11155111:1",
                "lifecycle": "active",
                "createdAt": active["createdAt"]!,
            ],
            [
                "eoa": active["eoa"]!,
                "keyRef": "bundler-eoa:default:011155111:1",
                "lifecycle": "active",
                "createdAt": active["createdAt"]!,
            ],
            [
                "eoa": active["eoa"]!,
                "keyRef": "bundler-eoa:default:11155111:01",
                "lifecycle": "active",
                "createdAt": active["createdAt"]!,
            ],
            [
                "eoa": active["eoa"]!,
                "keyRef": active["keyRef"]!,
                "lifecycle": "unknown",
                "createdAt": active["createdAt"]!,
            ],
            [
                "eoa": active["eoa"]!,
                "keyRef": active["keyRef"]!,
                "lifecycle": "active",
            ],
            [
                "eoa": active["eoa"]!,
                "keyRef": active["keyRef"]!,
                "lifecycle": "active",
                "createdAt": -1,
            ],
            [
                "eoa": active["eoa"]!,
                "keyRef": active["keyRef"]!,
                "lifecycle": "active",
                "createdAt": active["createdAt"]!,
                "retiredAt": "not-an-integer",
            ],
        ]
        for source in malformedEntries {
            var malformed = source
            malformed["ownerScope"] = malformed["ownerScope"] ?? "default"
            malformed["chainId"] = malformed["chainId"] ?? 11_155_111
            var json = relayerJSON()
            json["keyHistory"] = [active, malformed]
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: json)
            }
        }
    }

    @Test func relayerStatusRejectsMalformedOrDuplicateHistoryContainers() {
        let active: [String: Any] = [
            "ownerScope": "default",
            "chainId": 11_155_111,
            "eoa": "0xa000000000000000000000000000000000000001",
            "keyRef": "bundler-eoa:default:11155111:1",
            "lifecycle": "active",
            "createdAt": 1,
        ]
        let duplicateAddress: [String: Any] = [
            "ownerScope": "default",
            "chainId": 11_155_111,
            "eoa": "0xA000000000000000000000000000000000000001",
            "keyRef": "bundler-eoa:default:11155111:2",
            "lifecycle": "retired",
            "createdAt": 2,
        ]

        for history: Any in [
            "not-an-array",
            [active, "not-an-entry"],
            [active, duplicateAddress],
        ] {
            var json = relayerJSON()
            json["keyHistory"] = history
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: json)
            }
        }
    }

    /// `bundler_account_reconciliation.rs::rebind_active` retires a stale active
    /// row and inserts a new active one under the *same* `keyRef` — only the
    /// address changes. A wallet that has gone through this rebind (or a normal
    /// rotation before its `keyRef` index policy existed) legitimately has
    /// multiple `keyHistory` rows sharing one `keyRef`. Decoding must accept
    /// this rather than treating `keyRef` as a per-row unique identifier.
    @Test func relayerStatusAcceptsRetiredHistoryRowsSharingTheActiveKeyRef() throws {
        let active: [String: Any] = [
            "ownerScope": "default",
            "chainId": 11_155_111,
            "eoa": "0xa000000000000000000000000000000000000001",
            "keyRef": "bundler-eoa:default:11155111:1",
            "lifecycle": "active",
            "createdAt": 3,
        ]
        let retiredSameKeyRefOne: [String: Any] = [
            "ownerScope": "default",
            "chainId": 11_155_111,
            "eoa": "0xb000000000000000000000000000000000000002",
            "keyRef": active["keyRef"]!,
            "lifecycle": "retired",
            "createdAt": 1,
        ]
        let retiredSameKeyRefTwo: [String: Any] = [
            "ownerScope": "default",
            "chainId": 11_155_111,
            "eoa": "0xc000000000000000000000000000000000000003",
            "keyRef": active["keyRef"]!,
            "lifecycle": "retired",
            "createdAt": 2,
        ]

        var json = relayerJSON()
        json["keyHistory"] = [retiredSameKeyRefOne, retiredSameKeyRefTwo, active]
        let decoded = try WalletNodeClient.RelayerStatus(json: json)
        #expect(decoded.keyHistory.count == 3)
        #expect(decoded.eoa == "0xa000000000000000000000000000000000000001")
    }

    @Test func relayerStatusRejectsMalformedReplacementAndRetiringState() {
        let malformedReplacementValues: [Any] = [
            "not-an-object",
            ["blocked": false],
            ["eligible": false, "blocked": false, "nonce": -1],
            ["eligible": false, "blocked": false, "txHash": 7],
        ]
        for replacement in malformedReplacementValues {
            var json = relayerJSON()
            json["replacement"] = replacement
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: json)
            }
        }

        for retiring: Any in [
            "not-an-array",
            ["not-an-address"],
            [
                "0xa000000000000000000000000000000000000001",
                "0xA000000000000000000000000000000000000001",
            ],
        ] {
            var json = relayerJSON()
            json["rotation"] = [
                "pendingFunding": [],
                "retiring": retiring,
            ]
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: json)
            }
        }
    }

    @Test func relayerStatusRequiresExplicitManagedKeyAndCompromiseState() throws {
        var validCompromised = relayerJSON()
        validCompromised["ready"] = false
        validCompromised["reason"] = "bundler_eoa_compromise_suspected"
        validCompromised["compromise"] = [
            "suspected": true,
            "reason": "relayer_address_mismatch",
            "submissionBlocked": true,
        ]
        #expect(try WalletNodeClient.RelayerStatus(
            json: validCompromised
        ).compromiseSubmissionBlocked)

        var invalidPayloads: [[String: Any]] = []
        var missingKeyLoaded = relayerJSON()
        missingKeyLoaded.removeValue(forKey: "keyLoaded")
        invalidPayloads.append(missingKeyLoaded)
        var malformedKeyLoaded = relayerJSON()
        malformedKeyLoaded["keyLoaded"] = "true"
        invalidPayloads.append(malformedKeyLoaded)
        var missingCompromise = relayerJSON()
        missingCompromise.removeValue(forKey: "compromise")
        invalidPayloads.append(missingCompromise)
        var malformedCompromise = relayerJSON()
        malformedCompromise["compromise"] = "not-an-object"
        invalidPayloads.append(malformedCompromise)
        var malformedReason = relayerJSON()
        malformedReason["reason"] = 7
        invalidPayloads.append(malformedReason)
        for compromise: [String: Any] in [
            ["suspected": false],
            ["submissionBlocked": false],
            ["suspected": "false", "submissionBlocked": false],
            ["suspected": false, "submissionBlocked": "false"],
            ["suspected": true, "submissionBlocked": false],
            ["suspected": false, "reason": 7, "submissionBlocked": false],
            ["suspected": false, "reason": "unexpected", "submissionBlocked": false],
        ] {
            var json = relayerJSON()
            json["compromise"] = compromise
            invalidPayloads.append(json)
        }
        var blockedWithoutReason = relayerJSON()
        blockedWithoutReason["reason"] = "bundler_eoa_compromise_suspected"
        blockedWithoutReason["compromise"] = [
            "suspected": true,
            "submissionBlocked": true,
        ]
        invalidPayloads.append(blockedWithoutReason)
        var reasonWithoutBlocked = relayerJSON()
        reasonWithoutBlocked["reason"] = "bundler_eoa_compromise_suspected"
        invalidPayloads.append(reasonWithoutBlocked)

        for payload in invalidPayloads {
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: payload)
            }
        }
    }

    @Test func relayerStatusRejectsFoundationBooleanIntegerCrossCasts() {
        for field in ["ready", "keyLoaded", "needsTopup"] {
            for invalid: Any in [0, 1] {
                var json = relayerJSON()
                json[field] = invalid
                #expect(throws: (any Error).self) {
                    _ = try WalletNodeClient.RelayerStatus(json: json)
                }
            }
        }

        for field in ["suspected", "submissionBlocked"] {
            var json = relayerJSON()
            var compromise = json["compromise"] as! [String: Any]
            compromise[field] = 1
            json["compromise"] = compromise
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: json)
            }
        }

        var rotation = relayerJSON()
        var rotationState = rotation["rotation"] as! [String: Any]
        rotationState["rotating"] = 0
        rotation["rotation"] = rotationState
        #expect(throws: (any Error).self) {
            _ = try WalletNodeClient.RelayerStatus(json: rotation)
        }

        for invalid: Any in [true, false, 11_155_111.0] {
            var json = relayerJSON()
            json["chainId"] = invalid
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: json)
            }
        }

        for timestampField in ["createdAt", "retiredAt"] {
            var json = relayerJSON()
            var history = json["keyHistory"] as! [[String: Any]]
            history[0][timestampField] = true
            json["keyHistory"] = history
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: json)
            }
        }

        for invalidChainID: Any in [true, 11_155_111.0] {
            var json = relayerJSON()
            var history = json["keyHistory"] as! [[String: Any]]
            history[0]["chainId"] = invalidChainID
            json["keyHistory"] = history
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: json)
            }
        }

        for invalidOwnerScope: Any? in [nil, "other", 7] {
            var json = relayerJSON()
            var history = json["keyHistory"] as! [[String: Any]]
            if let invalidOwnerScope {
                history[0]["ownerScope"] = invalidOwnerScope
            } else {
                history[0].removeValue(forKey: "ownerScope")
            }
            json["keyHistory"] = history
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: json)
            }
        }

        var replacement = relayerJSON()
        var replacementState = replacement["replacement"] as! [String: Any]
        replacementState["nonce"] = true
        replacement["replacement"] = replacementState
        #expect(throws: (any Error).self) {
            _ = try WalletNodeClient.RelayerStatus(json: replacement)
        }

        replacement = relayerJSON()
        replacementState = replacement["replacement"] as! [String: Any]
        replacementState["eligible"] = 0
        replacement["replacement"] = replacementState
        #expect(throws: (any Error).self) {
            _ = try WalletNodeClient.RelayerStatus(json: replacement)
        }
    }

    @Test func relayerStatusRequiresCompleteManagedLifecycleStructures() {
        for field in ["rotation", "keyHistory", "replacement"] {
            var missing = relayerJSON()
            missing.removeValue(forKey: field)
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: missing)
            }

            var null = relayerJSON()
            null[field] = NSNull()
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: null)
            }
        }

        for field in ["rotating", "pendingFunding", "retiring"] {
            var json = relayerJSON()
            var rotation = json["rotation"] as! [String: Any]
            rotation.removeValue(forKey: field)
            json["rotation"] = rotation
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: json)
            }
        }

        var contradictoryRotation = relayerJSON(rotation: [
            "rotating": true,
            "pendingFunding": [],
            "retiring": [],
        ])
        #expect(throws: (any Error).self) {
            _ = try WalletNodeClient.RelayerStatus(json: contradictoryRotation)
        }
        contradictoryRotation["rotation"] = [
            "rotating": false,
            "pendingFunding": [[
                "eoa": "0xa100000000000000000000000000000000000001",
                "keyRef": "bundler-eoa:default:11155111:2",
                "createdAt": 1_723_456_789,
            ]],
            "retiring": [],
        ]
        #expect(throws: (any Error).self) {
            _ = try WalletNodeClient.RelayerStatus(json: contradictoryRotation)
        }
    }

    @Test func compromisedStatusRemainsValidWhenLockedOrLowBalance() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { json in
                json["keyLoaded"] = false
                json["balance"] = "0x2386f26fc10000"
                json["needsTopup"] = false
            },
            { json in
                json["keyLoaded"] = true
                json["balance"] = "0x1"
                json["needsTopup"] = true
            },
        ]
        for mutation in mutations {
            var json = relayerJSON()
            json["ready"] = false
            json["reason"] = "bundler_eoa_compromise_suspected"
            json["compromise"] = [
                "suspected": true,
                "reason": "relayer_address_mismatch",
                "submissionBlocked": true,
            ]
            mutation(&json)
            let status = try WalletNodeClient.RelayerStatus(json: json)
            #expect(status.compromiseSubmissionBlocked)
        }
    }

    @Test func relayerStatusRejectsMalformedOrContradictoryIdentityScalars() throws {
        for key in ["eoa", "keyRef", "lifecycle"] {
            var missing = relayerJSON()
            missing.removeValue(forKey: key)
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: missing)
            }

            var wrongType = relayerJSON()
            wrongType[key] = 7
            #expect(throws: (any Error).self) {
                _ = try WalletNodeClient.RelayerStatus(json: wrongType)
            }
        }

        var nullKeyWithLiveIdentity = relayerJSON()
        nullKeyWithLiveIdentity["keyRef"] = NSNull()
        #expect(throws: (any Error).self) {
            _ = try WalletNodeClient.RelayerStatus(json: nullKeyWithLiveIdentity)
        }

        var nullIdentityWithKey = relayerJSON()
        nullIdentityWithKey["eoa"] = NSNull()
        nullIdentityWithKey["lifecycle"] = NSNull()
        #expect(throws: (any Error).self) {
            _ = try WalletNodeClient.RelayerStatus(json: nullIdentityWithKey)
        }

        var unlockedMissingIdentity = relayerJSON()
        unlockedMissingIdentity["keyRef"] = NSNull()
        unlockedMissingIdentity["eoa"] = NSNull()
        unlockedMissingIdentity["lifecycle"] = NSNull()
        #expect(throws: (any Error).self) {
            _ = try WalletNodeClient.RelayerStatus(json: unlockedMissingIdentity)
        }

        var lockedMissingIdentity = unlockedMissingIdentity
        lockedMissingIdentity["ready"] = false
        lockedMissingIdentity["keyLoaded"] = false
        lockedMissingIdentity["reason"] = "bundler_eoa_missing"
        lockedMissingIdentity["keyHistory"] = []
        let decoded = try WalletNodeClient.RelayerStatus(json: lockedMissingIdentity)
        #expect(decoded.keyRef == nil)
        #expect(decoded.eoa == "Not available")
        #expect(decoded.lifecycle == "missing")
    }

    private func relayerJSON(rotation: Any? = nil) -> [String: Any] {
        let json: [String: Any] = [
            "ready": true,
            "keyLoaded": true,
            "reason": NSNull(),
            "ownerScope": "default",
            "chainId": 11_155_111,
            "networkProfile": "sepolia",
            "eoa": "0xa000000000000000000000000000000000000001",
            "keyRef": "bundler-eoa:default:11155111:1",
            "balance": "0x2386f26fc10000",
            "thresholdLow": "0x11c37937e08000",
            "needsTopup": false,
            "lifecycle": "active",
            "rotation": rotation ?? [
                "rotating": false,
                "pendingFunding": [],
                "retiring": [],
            ],
            "keyHistory": [[
                "ownerScope": "default",
                "chainId": 11_155_111,
                "eoa": "0xa000000000000000000000000000000000000001",
                "keyRef": "bundler-eoa:default:11155111:1",
                "lifecycle": "active",
                "createdAt": 1_723_456_700,
            ]],
            "replacement": [
                "eligible": false,
                "blocked": false,
                "blockedReason": NSNull(),
                "txHash": NSNull(),
                "userOpHash": NSNull(),
                "nonce": NSNull(),
            ],
            "compromise": [
                "suspected": false,
                "reason": NSNull(),
                "submissionBlocked": false,
            ],
        ]
        return json
    }
}
