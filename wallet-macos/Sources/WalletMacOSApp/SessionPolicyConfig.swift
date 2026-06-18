import Foundation

struct SessionPolicyConfig: Codable, Equatable {
    var perTxValueLimitWei: String
    var rateLimitCount: Int
    var rateLimitIntervalSec: Int
    var ttlSeconds: Int
    var inactivityTimeoutSeconds: Int
    var gasBudgetWei: String
    var allowlist: SessionPolicyAllowlist
    var erc20TokenLimits: [SessionERC20TokenLimit]

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
        allowlist: .default,
        erc20TokenLimits: []
    )

    init(
        perTxValueLimitWei: String,
        rateLimitCount: Int,
        rateLimitIntervalSec: Int,
        ttlSeconds: Int,
        inactivityTimeoutSeconds: Int = defaultInactivityTimeoutSeconds,
        gasBudgetWei: String,
        allowlist: SessionPolicyAllowlist,
        erc20TokenLimits: [SessionERC20TokenLimit] = []
    ) {
        self.perTxValueLimitWei = perTxValueLimitWei
        self.rateLimitCount = rateLimitCount
        self.rateLimitIntervalSec = rateLimitIntervalSec
        self.ttlSeconds = ttlSeconds
        self.inactivityTimeoutSeconds = inactivityTimeoutSeconds
        self.gasBudgetWei = gasBudgetWei
        self.allowlist = allowlist
        self.erc20TokenLimits = erc20TokenLimits
    }

    private enum CodingKeys: String, CodingKey {
        case perTxValueLimitWei
        case rateLimitCount
        case rateLimitIntervalSec
        case ttlSeconds
        case inactivityTimeoutSeconds
        case gasBudgetWei
        case allowlist
        case erc20TokenLimits
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
        erc20TokenLimits = try container.decodeIfPresent(
            [SessionERC20TokenLimit].self,
            forKey: .erc20TokenLimits
        ) ?? []
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
        for limit in erc20TokenLimits {
            _ = try limit.normalized()
        }
        return self
    }

    func erc20TokenLimit(for token: WalletToken) -> SessionERC20TokenLimit? {
        guard token.contractAddress != nil else {
            return nil
        }
        if let configured = erc20TokenLimits.first(where: {
            $0.matches(token)
        }) {
            return configured
        }
        return SessionERC20TokenLimit(
            symbol: token.symbol,
            isEnabled: true,
            maxAmount: Self.defaultERC20LimitBaseUnits(for: token)
        )
    }

    func erc20TransferLimitBaseUnits(for token: WalletToken) -> String? {
        guard allowlist.erc20Transfers,
              let limit = erc20TokenLimit(for: token),
              limit.isEnabled
        else {
            return nil
        }
        return limit.maxAmount
    }

    func erc20ApprovalLimitBaseUnits(for token: WalletToken) -> String? {
        guard allowlist.erc20Approvals != .disabled,
              let limit = erc20TokenLimit(for: token),
              limit.isEnabled
        else {
            return nil
        }
        return limit.maxAmount
    }

    func effectiveERC20TokenLimits(on chainID: UInt64) -> [SessionERC20TokenLimit] {
        WalletTokenRegistry.tokens(on: chainID).compactMap { token in
            guard token.contractAddress != nil else {
                return nil
            }
            return erc20TokenLimit(for: token)
        }
    }

    static func defaultERC20LimitDecimal(for token: WalletToken) -> String {
        switch token.symbol.uppercased() {
        case "WETH":
            return "0.1"
        case "WBTC":
            return "0.01"
        case "USDC", "USDT", "DAI":
            return "100"
        default:
            return "25"
        }
    }

    static func defaultERC20LimitBaseUnits(for token: WalletToken) -> String {
        (try? tokenBaseUnits(fromDecimalString: defaultERC20LimitDecimal(for: token), decimals: token.decimals)) ?? "0"
    }

    static func tokenBaseUnits(fromDecimalString value: String, decimals: Int) throws -> String {
        guard decimals >= 0 else {
            throw AppError.invalidAmount
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidAmount
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else {
            throw AppError.invalidAmount
        }
        let whole = String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard whole.allSatisfy(\.isNumber),
              fraction.allSatisfy(\.isNumber),
              fraction.count <= decimals
        else {
            throw AppError.invalidAmount
        }
        let paddedFraction = fraction + String(repeating: "0", count: decimals - fraction.count)
        let normalized = (whole.isEmpty ? "0" : whole) + paddedFraction
        let trimmedZeros = normalized.drop { $0 == "0" }
        return trimmedZeros.isEmpty ? "0" : String(trimmedZeros)
    }

    static func tokenDecimalString(fromBaseUnits value: String, decimals: Int) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard decimals > 0,
              !normalized.isEmpty,
              normalized.allSatisfy(\.isNumber)
        else {
            return normalized.isEmpty ? "0" : normalized
        }
        let padded = String(repeating: "0", count: max(0, decimals + 1 - normalized.count)) + normalized
        let splitIndex = padded.index(padded.endIndex, offsetBy: -decimals)
        let wholePart = String(padded[..<splitIndex]).drop { $0 == "0" }
        let fractionPart = String(padded[splitIndex...]).reversed().drop { $0 == "0" }.reversed()
        let whole = wholePart.isEmpty ? "0" : String(wholePart)
        guard !fractionPart.isEmpty else {
            return whole
        }
        return "\(whole).\(String(fractionPart))"
    }

    static func normalizedAddress(_ value: String) throws -> String {
        let data = try Data(hexString: value)
        guard data.count == 20 else {
            throw AppError.invalidExecutionAddress
        }
        return "0x" + data.hexEncodedString
    }
}

struct SessionPolicyAllowlist: Codable, Equatable {
    var nativeTransfers: Bool
    var erc20TokenScope: SessionERC20TokenScope
    var erc20Transfers: Bool
    var erc20Approvals: SessionERC20ApprovalMode
    var swapRouter: Bool

    static let `default` = SessionPolicyAllowlist(
        nativeTransfers: true,
        erc20TokenScope: .knownList,
        erc20Transfers: true,
        erc20Approvals: .knownSwapRouters,
        swapRouter: true
    )

    private enum CodingKeys: String, CodingKey {
        case nativeTransfers
        case erc20TokenScope
        case erc20Transfers
        case erc20Approvals
        case swapRouter
    }

    init(
        nativeTransfers: Bool,
        erc20TokenScope: SessionERC20TokenScope,
        erc20Transfers: Bool = true,
        erc20Approvals: SessionERC20ApprovalMode = .knownSwapRouters,
        swapRouter: Bool
    ) {
        self.nativeTransfers = nativeTransfers
        self.erc20TokenScope = erc20TokenScope
        self.erc20Transfers = erc20Transfers
        self.erc20Approvals = erc20Approvals
        self.swapRouter = swapRouter
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nativeTransfers = try container.decode(Bool.self, forKey: .nativeTransfers)
        erc20TokenScope = try container.decode(SessionERC20TokenScope.self, forKey: .erc20TokenScope)
        erc20Transfers = try container.decodeIfPresent(Bool.self, forKey: .erc20Transfers) ?? true
        erc20Approvals = try container.decodeIfPresent(
            SessionERC20ApprovalMode.self,
            forKey: .erc20Approvals
        ) ?? .knownSwapRouters
        swapRouter = try container.decode(Bool.self, forKey: .swapRouter)
    }
}

enum SessionERC20TokenScope: String, Codable, Equatable {
    case knownList
}

enum SessionERC20ApprovalMode: String, Codable, Equatable, CaseIterable {
    case disabled
    case knownSwapRouters
    case anySpender
}

struct SessionERC20TokenLimit: Codable, Equatable, Identifiable {
    var symbol: String
    var chainID: UInt64?
    var tokenAddress: String?
    var isEnabled: Bool
    var maxAmount: String

    var id: String {
        let normalizedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedSymbol.isEmpty else {
            return "\(chainID ?? 0):\(tokenAddress?.lowercased() ?? "unknown")"
        }
        return normalizedSymbol
    }

    init(
        symbol: String,
        isEnabled: Bool,
        maxAmount: String
    ) {
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.chainID = nil
        self.tokenAddress = nil
        self.isEnabled = isEnabled
        self.maxAmount = maxAmount
    }

    init(
        chainID: UInt64,
        tokenAddress: String,
        isEnabled: Bool,
        maxAmount: String
    ) {
        self.symbol = WalletTokenRegistry.token(matching: tokenAddress, on: chainID)?.symbol.uppercased() ?? ""
        self.chainID = chainID
        self.tokenAddress = tokenAddress
        self.isEnabled = isEnabled
        self.maxAmount = maxAmount
    }

    private enum CodingKeys: String, CodingKey {
        case symbol
        case chainID
        case tokenAddress
        case isEnabled
        case maxAmount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        chainID = try container.decodeIfPresent(UInt64.self, forKey: .chainID)
        tokenAddress = try container.decodeIfPresent(String.self, forKey: .tokenAddress)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        maxAmount = try container.decode(String.self, forKey: .maxAmount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let normalizedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalizedSymbol.isEmpty {
            try container.encodeIfPresent(chainID, forKey: .chainID)
            try container.encodeIfPresent(tokenAddress, forKey: .tokenAddress)
        } else {
            try container.encode(normalizedSymbol, forKey: .symbol)
        }
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(maxAmount, forKey: .maxAmount)
    }

    func matches(_ token: WalletToken) -> Bool {
        let normalizedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !normalizedSymbol.isEmpty {
            return normalizedSymbol == token.symbol.uppercased()
        }
        guard let chainID,
              let tokenAddress,
              token.chainID == chainID,
              let address = token.contractAddress
        else {
            return false
        }
        return (try? SessionPolicyConfig.normalizedAddress(tokenAddress))
            == (try? SessionPolicyConfig.normalizedAddress(address))
    }

    func normalized() throws -> SessionERC20TokenLimit {
        var copy = self
        copy.symbol = copy.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if copy.symbol.isEmpty, copy.tokenAddress == nil {
            throw AppError.invalidAmount
        }
        if let tokenAddress = copy.tokenAddress {
            copy.tokenAddress = try SessionPolicyConfig.normalizedAddress(tokenAddress)
        }
        copy.maxAmount = copy.maxAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try Data.quantityString(copy.maxAmount)
        return copy
    }
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
