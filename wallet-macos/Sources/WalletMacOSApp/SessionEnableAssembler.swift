import Foundation
import WalletSignature

struct SessionPermissionArtifacts: Equatable {
    var permissionId: Data
    var enableData: Data
    var selectorData: Data
    var enableDigest: Data
    var nonceKeyDefault: Data
    var nonceKeyEnable: Data

    init(
        permissionId: Data,
        enableData: Data,
        selectorData: Data,
        enableDigest: Data,
        nonceKeyDefault: Data,
        nonceKeyEnable: Data
    ) {
        self.permissionId = permissionId
        self.enableData = enableData
        self.selectorData = selectorData
        self.enableDigest = enableDigest
        self.nonceKeyDefault = nonceKeyDefault
        self.nonceKeyEnable = nonceKeyEnable
    }

    init(permission: WalletSignature.SessionPermission) {
        self.init(
            permissionId: permission.permissionId,
            enableData: permission.enableData,
            selectorData: permission.selectorData,
            enableDigest: permission.enableDigest,
            nonceKeyDefault: permission.nonceKeyDefault,
            nonceKeyEnable: permission.nonceKeyEnable
        )
    }
}

struct SessionEnableAssembly: Equatable {
    var configJSON: Data
    var permission: SessionPermissionArtifacts
    var record: SessionRecord
}

struct SessionPermissionConfigPayload: Codable, Equatable {
    var account: String
    var chainId: UInt64
    var sessionKey: String
    var executeSelector: String
    var validationNonce: UInt32
    var gasBudgetWei: String
    var rateLimitIntervalSec: UInt64
    var rateLimitCount: UInt64
    var rateLimitStartAt: UInt64
    var validAfter: UInt64
    var validUntil: UInt64
    var allowedCalls: [SessionPermissionAllowedCall]
}

struct SessionPermissionAllowedCall: Codable, Equatable {
    var target: String
    var selector: String
    var valueLimitWei: String
    var rules: [SessionPermissionAllowRule]
}

struct SessionPermissionAllowRule: Codable, Equatable {
    var condition: String
    var offset: UInt64
    var params: [String]
}

enum SessionEnableAssembler {
    static let executeSelector = "0xe9ae5c53"

    private static let erc20TransferSelector = "0xa9059cbb"
    private static let erc20ApproveSelector = "0x095ea7b3"
    private static let swapRouterExactInputSelector = "0xb858183f"
    private static let swapRouterUnwrapWETH9Selector = "0x49404b7c"
    private static let nativeTransferSelector = "0x00000000"
    private static let anyTarget = "0x0000000000000000000000000000000000000000"
    private static let erc20AmountArgumentOffset: UInt64 = 32
    private static let swapRecipientArgumentOffset: UInt64 = 32
    private static let swapAmountInArgumentOffset: UInt64 = 64

    static func assemble(
        policy: SessionPolicyConfig,
        chain: ChainConfiguration,
        accountAddress: String,
        sessionKeyRef: String,
        sessionAddress: Data,
        validationNonce: UInt32,
        now: Date,
        composer: (Data) throws -> SessionPermissionArtifacts,
        enableDigestSigner: (Data) throws -> Data
    ) throws -> SessionEnableAssembly {
        let configJSON = try permissionConfigJSON(
            policy: policy,
            chain: chain,
            accountAddress: accountAddress,
            sessionAddress: sessionAddress,
            validationNonce: validationNonce,
            now: now
        )
        let permission = try composer(configJSON)
        let enableSig = try enableDigestSigner(permission.enableDigest)
        let expiresAt = now.addingTimeInterval(TimeInterval(policy.ttlSeconds))
        let record = SessionRecord(
            chainId: chain.id,
            sessionKeyRef: sessionKeyRef,
            permissionId: permission.permissionId,
            enableSig: enableSig,
            enabledAt: now,
            expiresAt: expiresAt,
            installedOnChain: false,
            validationNonce: validationNonce,
            enableData: permission.enableData,
            selectorData: permission.selectorData,
            nonceKeyDefault: permission.nonceKeyDefault,
            nonceKeyEnable: permission.nonceKeyEnable,
            policyConfigSnapshot: policy
        )
        return SessionEnableAssembly(
            configJSON: configJSON,
            permission: permission,
            record: record
        )
    }

    static func permissionConfigJSON(
        policy: SessionPolicyConfig,
        chain: ChainConfiguration,
        accountAddress: String,
        sessionAddress: Data,
        validationNonce: UInt32,
        now: Date
    ) throws -> Data {
        guard sessionAddress.count == 20 else {
            throw AppError.invalidExecutionAddress
        }
        let ttlSeconds = try nonNegativeUInt64(policy.ttlSeconds)
        let validUntil = unixSeconds(now) + ttlSeconds
        let payload = SessionPermissionConfigPayload(
            account: try normalizedAddress(accountAddress),
            chainId: chain.id,
            sessionKey: "0x" + sessionAddress.hexEncodedString,
            executeSelector: executeSelector,
            validationNonce: validationNonce,
            gasBudgetWei: policy.gasBudgetWei,
            rateLimitIntervalSec: try nonNegativeUInt64(policy.rateLimitIntervalSec),
            rateLimitCount: try nonNegativeUInt64(policy.rateLimitCount),
            rateLimitStartAt: 0,
            validAfter: 0,
            validUntil: validUntil,
            allowedCalls: try allowedCalls(
                policy: policy,
                chainID: chain.id,
                accountAddress: accountAddress
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    static func sessionKeyRef(chainID: UInt64, accountAddress: String) throws -> String {
        "session-key:\(chainID):\(try normalizedAddress(accountAddress))"
    }

    private static func allowedCalls(
        policy: SessionPolicyConfig,
        chainID: UInt64,
        accountAddress: String
    ) throws -> [SessionPermissionAllowedCall] {
        var calls: [SessionPermissionAllowedCall] = []
        let amountLimit = try b256Hex(decimal: policy.perTxValueLimitWei)
        let erc20AmountRule = SessionPermissionAllowRule(
            condition: "lessEqual",
            offset: erc20AmountArgumentOffset,
            params: [amountLimit]
        )

        if policy.allowlist.nativeTransfers {
            calls.append(SessionPermissionAllowedCall(
                target: anyTarget,
                selector: nativeTransferSelector,
                valueLimitWei: policy.perTxValueLimitWei,
                rules: []
            ))
        }

        switch policy.allowlist.erc20TokenScope {
        case .knownList:
            for token in WalletTokenRegistry.tokens(on: chainID) {
                guard let address = token.contractAddress else {
                    continue
                }
                let target = try normalizedAddress(address)
                calls.append(SessionPermissionAllowedCall(
                    target: target,
                    selector: erc20TransferSelector,
                    valueLimitWei: "0",
                    rules: [erc20AmountRule]
                ))
                calls.append(SessionPermissionAllowedCall(
                    target: target,
                    selector: erc20ApproveSelector,
                    valueLimitWei: "0",
                    rules: [erc20AmountRule]
                ))
            }
        }

        if policy.allowlist.swapRouter {
            let accountRule = SessionPermissionAllowRule(
                condition: "equal",
                offset: swapRecipientArgumentOffset,
                params: [try b256Address(accountAddress)]
            )
            let swapAmountRule = SessionPermissionAllowRule(
                condition: "lessEqual",
                offset: swapAmountInArgumentOffset,
                params: [amountLimit]
            )

            for router in SessionSwapRouterRegistry.routers(on: chainID) {
                let target = try normalizedAddress(router)
                let routerRule = SessionPermissionAllowRule(
                    condition: "equal",
                    offset: swapRecipientArgumentOffset,
                    params: [try b256Address(router)]
                )
                calls.append(SessionPermissionAllowedCall(
                    target: target,
                    selector: swapRouterExactInputSelector,
                    valueLimitWei: policy.perTxValueLimitWei,
                    rules: [accountRule, swapAmountRule]
                ))
                calls.append(SessionPermissionAllowedCall(
                    target: target,
                    selector: swapRouterExactInputSelector,
                    valueLimitWei: policy.perTxValueLimitWei,
                    rules: [routerRule, swapAmountRule]
                ))
                calls.append(SessionPermissionAllowedCall(
                    target: target,
                    selector: swapRouterUnwrapWETH9Selector,
                    valueLimitWei: "0",
                    rules: [accountRule]
                ))
            }
        }

        return calls
    }

    private static func normalizedAddress(_ value: String) throws -> String {
        let data = try Data(hexString: value)
        guard data.count == 20 else {
            throw AppError.invalidExecutionAddress
        }
        return "0x" + data.hexEncodedString
    }

    private static func b256Hex(decimal value: String) throws -> String {
        let data = try Data.quantityString(value).leftPadded(to: 32)
        guard data.count == 32 else {
            throw AppError.invalidHexString
        }
        return "0x" + data.hexEncodedString
    }

    private static func b256Address(_ value: String) throws -> String {
        let data = try Data(hexString: value)
        guard data.count == 20 else {
            throw AppError.invalidExecutionAddress
        }
        return "0x" + data.leftPadded(to: 32).hexEncodedString
    }

    private static func nonNegativeUInt64(_ value: Int) throws -> UInt64 {
        guard value >= 0 else {
            throw AppError.invalidAmount
        }
        return UInt64(value)
    }

    private static func unixSeconds(_ date: Date) -> UInt64 {
        UInt64(max(0, floor(date.timeIntervalSince1970)))
    }
}
