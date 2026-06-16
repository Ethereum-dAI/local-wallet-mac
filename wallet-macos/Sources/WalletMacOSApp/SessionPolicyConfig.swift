import Foundation

struct SessionPolicyConfig: Codable, Equatable {
    var perTxValueLimitWei: String
    var rateLimitCount: Int
    var rateLimitIntervalSec: Int
    var ttlSeconds: Int
    var inactivityTimeoutSeconds: Int
    var gasBudgetWei: String
    var allowlist: SessionPolicyAllowlist

    static let allowedTTLSeconds = [
        14_400,
        28_800,
        43_200,
        57_600,
        72_000,
        86_400,
    ]
    static let defaultTTLSeconds = 28_800
    static let defaultInactivityTimeoutSeconds = 3_600
    static let minimumInactivityTimeoutSeconds = 600
    static let maximumInactivityTimeoutSeconds = 14_400

    static let `default` = SessionPolicyConfig(
        perTxValueLimitWei: "100000000000000000",
        rateLimitCount: 20,
        rateLimitIntervalSec: 86_400,
        ttlSeconds: defaultTTLSeconds,
        inactivityTimeoutSeconds: defaultInactivityTimeoutSeconds,
        gasBudgetWei: "50000000000000000",
        allowlist: .default
    )

    init(
        perTxValueLimitWei: String,
        rateLimitCount: Int,
        rateLimitIntervalSec: Int,
        ttlSeconds: Int,
        inactivityTimeoutSeconds: Int = defaultInactivityTimeoutSeconds,
        gasBudgetWei: String,
        allowlist: SessionPolicyAllowlist
    ) {
        self.perTxValueLimitWei = perTxValueLimitWei
        self.rateLimitCount = rateLimitCount
        self.rateLimitIntervalSec = rateLimitIntervalSec
        self.ttlSeconds = ttlSeconds
        self.inactivityTimeoutSeconds = inactivityTimeoutSeconds
        self.gasBudgetWei = gasBudgetWei
        self.allowlist = allowlist
    }

    private enum CodingKeys: String, CodingKey {
        case perTxValueLimitWei
        case rateLimitCount
        case rateLimitIntervalSec
        case ttlSeconds
        case inactivityTimeoutSeconds
        case gasBudgetWei
        case allowlist
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        perTxValueLimitWei = try container.decode(String.self, forKey: .perTxValueLimitWei)
        rateLimitCount = try container.decode(Int.self, forKey: .rateLimitCount)
        rateLimitIntervalSec = try container.decode(Int.self, forKey: .rateLimitIntervalSec)
        ttlSeconds = try container.decode(Int.self, forKey: .ttlSeconds)
        inactivityTimeoutSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .inactivityTimeoutSeconds
        ) ?? Self.defaultInactivityTimeoutSeconds
        gasBudgetWei = try container.decode(String.self, forKey: .gasBudgetWei)
        allowlist = try container.decode(SessionPolicyAllowlist.self, forKey: .allowlist)
    }
}

extension SessionPolicyConfig {
    func validated() throws -> SessionPolicyConfig {
        guard rateLimitCount > 0,
              rateLimitIntervalSec > 0,
              Self.allowedTTLSeconds.contains(ttlSeconds),
              inactivityTimeoutSeconds >= Self.minimumInactivityTimeoutSeconds,
              inactivityTimeoutSeconds <= Self.maximumInactivityTimeoutSeconds,
              inactivityTimeoutSeconds <= ttlSeconds
        else {
            throw AppError.invalidAmount
        }
        _ = try Data.quantityString(perTxValueLimitWei)
        _ = try Data.quantityString(gasBudgetWei)
        return self
    }
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
    var lastActivityAt: Date
    var installedOnChain: Bool
    var validationNonce: UInt32
    var enableData: Data
    var selectorData: Data
    var nonceKeyDefault: Data
    var nonceKeyEnable: Data
    var policyConfigSnapshot: SessionPolicyConfig

    init(
        chainId: UInt64,
        sessionKeyRef: String,
        permissionId: Data,
        enableSig: Data,
        enabledAt: Date,
        expiresAt: Date,
        lastActivityAt: Date? = nil,
        installedOnChain: Bool,
        validationNonce: UInt32 = 0,
        enableData: Data = Data(),
        selectorData: Data = Data(),
        nonceKeyDefault: Data = Data(),
        nonceKeyEnable: Data = Data(),
        policyConfigSnapshot: SessionPolicyConfig = .default
    ) {
        self.chainId = chainId
        self.sessionKeyRef = sessionKeyRef
        self.permissionId = permissionId
        self.enableSig = enableSig
        self.enabledAt = enabledAt
        self.expiresAt = expiresAt
        self.lastActivityAt = lastActivityAt ?? enabledAt
        self.installedOnChain = installedOnChain
        self.validationNonce = validationNonce
        self.enableData = enableData
        self.selectorData = selectorData
        self.nonceKeyDefault = nonceKeyDefault
        self.nonceKeyEnable = nonceKeyEnable
        self.policyConfigSnapshot = policyConfigSnapshot
    }

    private enum CodingKeys: String, CodingKey {
        case chainId
        case sessionKeyRef
        case permissionId
        case enableSig
        case enabledAt
        case expiresAt
        case lastActivityAt
        case installedOnChain
        case validationNonce
        case enableData
        case selectorData
        case nonceKeyDefault
        case nonceKeyEnable
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
        lastActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt) ?? enabledAt
        installedOnChain = try container.decode(Bool.self, forKey: .installedOnChain)
        validationNonce = try container.decodeIfPresent(UInt32.self, forKey: .validationNonce) ?? 0
        enableData = try container.decodeIfPresent(Data.self, forKey: .enableData) ?? Data()
        selectorData = try container.decodeIfPresent(Data.self, forKey: .selectorData) ?? Data()
        nonceKeyDefault = try container.decodeIfPresent(Data.self, forKey: .nonceKeyDefault) ?? Data()
        nonceKeyEnable = try container.decodeIfPresent(Data.self, forKey: .nonceKeyEnable) ?? Data()
        policyConfigSnapshot = try container.decodeIfPresent(
            SessionPolicyConfig.self,
            forKey: .policyConfigSnapshot
        ) ?? .default
    }
}

enum SessionExpiryReason: Equatable {
    case duration
    case inactivity

    var logLabel: String {
        switch self {
        case .duration:
            return "session duration expired"
        case .inactivity:
            return "inactivity timeout expired"
        }
    }
}

enum SessionLifecycle {
    static func expiryReason(record: SessionRecord, now: Date) -> SessionExpiryReason? {
        let inactivityDeadline = record.lastActivityAt.addingTimeInterval(
            TimeInterval(record.policyConfigSnapshot.inactivityTimeoutSeconds)
        )
        let firstDeadline = min(record.expiresAt, inactivityDeadline)
        guard now >= firstDeadline else {
            return nil
        }
        return record.expiresAt <= inactivityDeadline ? .duration : .inactivity
    }

    static func resettingActivity(record: SessionRecord, at date: Date) -> SessionRecord {
        var refreshed = record
        refreshed.lastActivityAt = date
        return refreshed
    }
}
