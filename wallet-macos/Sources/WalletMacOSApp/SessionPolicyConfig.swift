import Foundation

struct SessionPolicyConfig: Codable, Equatable {
    var perTxValueLimitWei: String
    var rateLimitCount: Int
    var rateLimitIntervalSec: Int
    var ttlSeconds: Int
    var gasBudgetWei: String
    var allowlist: SessionPolicyAllowlist

    static let `default` = SessionPolicyConfig(
        perTxValueLimitWei: "100000000000000000",
        rateLimitCount: 20,
        rateLimitIntervalSec: 86_400,
        ttlSeconds: 604_800,
        gasBudgetWei: "5000000000000000",
        allowlist: .default
    )
}

struct SessionPolicyAllowlist: Codable, Equatable {
    var nativeTransfers: Bool
    var erc20TokenScope: SessionERC20TokenScope
    var swapRouter: Bool

    static let `default` = SessionPolicyAllowlist(
        nativeTransfers: true,
        erc20TokenScope: .knownList,
        swapRouter: true
    )
}

enum SessionERC20TokenScope: String, Codable, Equatable {
    case knownList
}

struct SessionRecord: Codable, Equatable {
    var chainId: UInt64
    var sessionKeyRef: String
    var permissionId: Data
    var enableSig: Data
    var enabledAt: Date
    var expiresAt: Date
    var installedOnChain: Bool
    var policyConfigSnapshot: SessionPolicyConfig

    init(
        chainId: UInt64,
        sessionKeyRef: String,
        permissionId: Data,
        enableSig: Data,
        enabledAt: Date,
        expiresAt: Date,
        installedOnChain: Bool,
        policyConfigSnapshot: SessionPolicyConfig = .default
    ) {
        self.chainId = chainId
        self.sessionKeyRef = sessionKeyRef
        self.permissionId = permissionId
        self.enableSig = enableSig
        self.enabledAt = enabledAt
        self.expiresAt = expiresAt
        self.installedOnChain = installedOnChain
        self.policyConfigSnapshot = policyConfigSnapshot
    }

    private enum CodingKeys: String, CodingKey {
        case chainId
        case sessionKeyRef
        case permissionId
        case enableSig
        case enabledAt
        case expiresAt
        case installedOnChain
        case policyConfigSnapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chainId = try container.decode(UInt64.self, forKey: .chainId)
        sessionKeyRef = try container.decode(String.self, forKey: .sessionKeyRef)
        permissionId = try container.decode(Data.self, forKey: .permissionId)
        enableSig = try container.decode(Data.self, forKey: .enableSig)
        enabledAt = try container.decode(Date.self, forKey: .enabledAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        installedOnChain = try container.decode(Bool.self, forKey: .installedOnChain)
        policyConfigSnapshot = try container.decodeIfPresent(
            SessionPolicyConfig.self,
            forKey: .policyConfigSnapshot
        ) ?? .default
    }
}
