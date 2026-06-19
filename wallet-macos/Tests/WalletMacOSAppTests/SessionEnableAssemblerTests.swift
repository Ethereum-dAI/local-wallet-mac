import Foundation
import Testing
@testable import WalletMacOSApp

@Test func kernelCurrentNonceCalldataIsSelectorOnly() {
    #expect(ChainReadCallData.kernelCurrentNonce() == "0xadb610a3")
}

@Test func sessionEnableAssemblerBuildsConfigAndRecordFromPermissionArtifacts() throws {
    let policy = SessionPolicyConfig.default
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sessionAddress = try Data(hexString: "90F8bf6A479f320ead074411a4B0e7944Ea8c9C1")
    let artifacts = SessionPermissionArtifacts(
        permissionId: try Data(hexString: "44366fcb"),
        enableData: try Data(hexString: "010203"),
        selectorData: try Data(hexString: "e9ae5c53"),
        enableDigest: try Data(hexString: "010bc9b9b04ad89b23fc5806dba26f3d3bdcf191cb6ff607d78287cf2d39cedd"),
        nonceKeyDefault: Data(repeating: 0x11, count: 32),
        nonceKeyEnable: Data(repeating: 0x22, count: 32)
    )
    let enableSig = Data(repeating: 0xee, count: 65)
    var capturedConfigJSON = Data()

    let assembly = try SessionEnableAssembler.assemble(
        policy: policy,
        chain: .ethereumSepolia,
        accountAddress: "0x000000000000000000000000000000000000dEaD",
        sessionKeyRef: "session-key:11155111:0xdead",
        sessionAddress: sessionAddress,
        validationNonce: 1,
        now: now,
        composer: { configJSON in
            capturedConfigJSON = configJSON
            return artifacts
        },
        enableDigestSigner: { digest in
            #expect(digest == artifacts.enableDigest)
            return enableSig
        }
    )

    let decoded = try JSONDecoder().decode(SessionPermissionConfigPayload.self, from: capturedConfigJSON)
    #expect(decoded.account == "0x000000000000000000000000000000000000dead")
    #expect(decoded.chainId == 11_155_111)
    #expect(decoded.sessionKey == "0x90f8bf6a479f320ead074411a4b0e7944ea8c9c1")
    #expect(decoded.executeSelector == "0xe9ae5c53")
    #expect(decoded.validationNonce == 1)
    #expect(decoded.gasBudgetWei == policy.gasBudgetWei)
    #expect(decoded.rateLimitIntervalSec == 86_400)
    #expect(decoded.rateLimitCount == 20)
    #expect(decoded.rateLimitStartAt == 0)
    #expect(decoded.validAfter == 0)
    #expect(decoded.validUntil == 1_700_028_800)

    let expectedNativeLimit = "0x" + (try Data.quantityString(policy.perTxValueLimitWei))
        .leftPadded(to: 32)
        .hexEncodedString
    let nativeTransfer = try #require(decoded.allowedCalls.first {
        $0.target == "0x0000000000000000000000000000000000000000"
            && $0.selector == "0x00000000"
    })
    #expect(nativeTransfer.valueLimitWei == policy.perTxValueLimitWei)
    #expect(nativeTransfer.rules == [])

    let usdc = "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238"
    let usdcToken = try #require(WalletTokenRegistry.token(matching: "USDC", on: 11_155_111))
    let expectedUSDCLimit = "0x" + (try Data.quantityString(
        try #require(policy.erc20TokenLimit(for: usdcToken)).maxAmount
    ))
        .leftPadded(to: 32)
        .hexEncodedString
    let transfer = try #require(decoded.allowedCalls.first {
        $0.target == usdc && $0.selector == "0xa9059cbb"
    })
    #expect(transfer.valueLimitWei == "0")
    #expect(transfer.rules == [
        SessionPermissionAllowRule(condition: "lessEqual", offset: 32, params: [expectedUSDCLimit]),
    ])
    let approval = try #require(decoded.allowedCalls.first {
        $0.target == usdc && $0.selector == "0x095ea7b3"
    })
    #expect(approval.rules == [
        SessionPermissionAllowRule(
            condition: "oneOf",
            offset: 0,
            params: [try b256Address("0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E")]
        ),
        SessionPermissionAllowRule(condition: "lessEqual", offset: 32, params: [expectedUSDCLimit]),
    ])

    let router = "0x3bfa4769fb09eefc5a80d6e87c3b9c650f7ae48e"
    let accountRule = SessionPermissionAllowRule(
        condition: "equal",
        offset: 32,
        params: [try b256Address("0x000000000000000000000000000000000000dEaD")]
    )
    let recipientRule = SessionPermissionAllowRule(
        condition: "oneOf",
        offset: 64,
        params: [
            try b256Address("0x000000000000000000000000000000000000dEaD"),
            try b256Address(router),
        ]
    )
    let swapAmountRule = SessionPermissionAllowRule(
        condition: "lessEqual",
        offset: 96,
        params: [expectedNativeLimit]
    )
    let exactInputCalls = decoded.allowedCalls.filter {
        $0.target == router
            && $0.selector == "0xb858183f"
    }
    #expect(exactInputCalls.count == 1)
    let exactInput = try #require(exactInputCalls.first)
    #expect(exactInput.valueLimitWei == policy.perTxValueLimitWei)
    #expect(exactInput.rules == [recipientRule, swapAmountRule])

    let unwrap = try #require(decoded.allowedCalls.first {
        $0.target == router && $0.selector == "0x49404b7c"
    })
    #expect(unwrap.valueLimitWei == "0")
    #expect(unwrap.rules == [accountRule])

    #expect(assembly.permission == artifacts)
    #expect(assembly.record.chainId == 11_155_111)
    #expect(assembly.record.sessionKeyRef == "session-key:11155111:0xdead")
    #expect(assembly.record.permissionId == artifacts.permissionId)
    #expect(assembly.record.enableSig == enableSig)
    #expect(assembly.record.enabledAt == now)
    #expect(assembly.record.expiresAt == now.addingTimeInterval(28_800))
    #expect(assembly.record.lastActivityAt == now)
    #expect(assembly.record.installedOnChain == false)
    #expect(assembly.record.policyConfigSnapshot == policy)
    #expect(assembly.record.validationNonce == 1)
    #expect(assembly.record.enableData == artifacts.enableData)
    #expect(assembly.record.selectorData == artifacts.selectorData)
    #expect(assembly.record.nonceKeyDefault == artifacts.nonceKeyDefault)
    #expect(assembly.record.nonceKeyEnable == artifacts.nonceKeyEnable)
}

@Test func sessionEnableAssemblerEncodesCustomGuardrailsAndDisabledActionTypes() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let accountAddress = "0x000000000000000000000000000000000000dEaD"
    let sessionAddress = try Data(hexString: "90F8bf6A479f320ead074411a4B0e7944Ea8c9C1")
    let policy = SessionPolicyConfig(
        perTxValueLimitWei: "42",
        rateLimitCount: 3,
        rateLimitIntervalSec: 600,
        ttlSeconds: 14_400,
        inactivityTimeoutSeconds: 600,
        gasBudgetWei: "123",
        allowlist: SessionPolicyAllowlist(
            nativeTransfers: false,
            erc20TokenScope: .knownList,
            swapRouter: false
        ),
        erc20TokenLimits: [
            SessionERC20TokenLimit(
                chainID: 11_155_111,
                tokenAddress: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
                isEnabled: true,
                maxAmount: "42"
            ),
        ]
    )

    let configJSON = try SessionEnableAssembler.permissionConfigJSON(
        policy: policy,
        chain: .ethereumSepolia,
        accountAddress: accountAddress,
        sessionAddress: sessionAddress,
        validationNonce: 7,
        now: now
    )

    let decoded = try JSONDecoder().decode(SessionPermissionConfigPayload.self, from: configJSON)
    #expect(decoded.gasBudgetWei == "123")
    #expect(decoded.rateLimitCount == 3)
    #expect(decoded.rateLimitIntervalSec == 600)
    #expect(decoded.validUntil == 1_700_014_400)
    #expect(decoded.validationNonce == 7)
    #expect(!decoded.allowedCalls.contains { $0.selector == "0x00000000" })
    #expect(!decoded.allowedCalls.contains { $0.selector == "0xb858183f" })
    #expect(!decoded.allowedCalls.contains { $0.selector == "0x49404b7c" })
    #expect(decoded.allowedCalls.allSatisfy {
        $0.selector == "0xa9059cbb" || $0.selector == "0x095ea7b3"
    })

    let expectedLimit = "0x" + (try Data.quantityString(policy.perTxValueLimitWei))
        .leftPadded(to: 32)
        .hexEncodedString
    let expectedAmountRule = SessionPermissionAllowRule(
        condition: "lessEqual",
        offset: 32,
        params: [expectedLimit]
    )
    let usdc = "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238"
    let transfer = try #require(decoded.allowedCalls.first {
        $0.target == usdc && $0.selector == "0xa9059cbb"
    })
    let approve = try #require(decoded.allowedCalls.first {
        $0.target == usdc && $0.selector == "0x095ea7b3"
    })
    #expect(transfer.valueLimitWei == "0")
    #expect(transfer.rules == [expectedAmountRule])
    #expect(approve.valueLimitWei == "0")
    #expect(approve.rules == [
        SessionPermissionAllowRule(
            condition: "oneOf",
            offset: 0,
            params: [try b256Address("0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E")]
        ),
        expectedAmountRule,
    ])
}

private func b256Address(_ value: String) throws -> String {
    let data = try Data(hexString: value)
    return "0x" + data.leftPadded(to: 32).hexEncodedString
}
