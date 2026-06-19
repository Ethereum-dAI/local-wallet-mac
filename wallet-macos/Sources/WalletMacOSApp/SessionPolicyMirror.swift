import Foundation

struct SessionPolicyContext: Equatable {
    var chainID: UInt64
    var now: Date
    var expiresAt: Date
    var lastActivityAt: Date
    var recentSessionTransactionDates: [Date]

    init(
        chainID: UInt64,
        now: Date,
        expiresAt: Date,
        lastActivityAt: Date? = nil,
        recentSessionTransactionDates: [Date] = []
    ) {
        self.chainID = chainID
        self.now = now
        self.expiresAt = expiresAt
        self.lastActivityAt = lastActivityAt ?? now
        self.recentSessionTransactionDates = recentSessionTransactionDates
    }

    init(
        sessionRecord: SessionRecord,
        now: Date,
        recentSessionTransactionDates: [Date] = []
    ) {
        self.init(
            chainID: sessionRecord.chainId,
            now: now,
            expiresAt: sessionRecord.expiresAt,
            lastActivityAt: sessionRecord.lastActivityAt,
            recentSessionTransactionDates: recentSessionTransactionDates
        )
    }
}

enum SessionPolicyMirror {
    enum RejectionReason: Equatable {
        case expired
        case inactive
        case rateLimited
        case invalidLimit
        case nativeTransfersDisabled
        case erc20TransfersDisabled
        case erc20ApprovalsDisabled
        case erc20TokenDisabled
        case swapsDisabled
        case invalidRecipient
        case invalidAmount
        case overValueLimit
        case unsupportedToken
        case wrongChain
        case unsupportedSwapRouter
        case unsupportedApprovalSpender
        case unsupportedSwapToken
    }

    static func isWithinPolicy(
        intent: TransactionIntent,
        config: SessionPolicyConfig,
        context: SessionPolicyContext
    ) -> Bool {
        rejectionReason(intent: intent, config: config, context: context) == nil
    }

    static func rejectionReason(
        intent: TransactionIntent,
        config: SessionPolicyConfig,
        context: SessionPolicyContext
    ) -> RejectionReason? {
        if context.now >= context.expiresAt {
            return .expired
        }
        let inactivityExpiresAt = context.lastActivityAt.addingTimeInterval(
            TimeInterval(config.inactivityTimeoutSeconds)
        )
        if context.now >= inactivityExpiresAt {
            return .inactive
        }
        guard isUnderRateLimit(config: config, context: context) else {
            return .rateLimited
        }
        guard let nativeCap = capData(config.perTxValueLimitWei) else {
            return .invalidLimit
        }
        switch intent {
        case let .nativeTransfer(recipient, amountETH):
            guard config.allowlist.nativeTransfers else {
                return .nativeTransfersDisabled
            }
            guard normalizedAddress(recipient) != nil else {
                return .invalidRecipient
            }
            guard let amount = parsedETH(amountETH) else {
                return .invalidAmount
            }
            return isLessThanOrEqual(amount, nativeCap) ? nil : .overValueLimit

        case let .erc20Transfer(token, recipient, amount):
            switch config.allowlist.erc20TokenScope {
            case .knownList:
                guard isKnownERC20Token(token, chainID: context.chainID) else {
                    return .unsupportedToken
                }
                guard config.allowlist.erc20Transfers else {
                    return .erc20TransfersDisabled
                }
                guard let tokenCap = erc20CapData(config: config, token: token) else {
                    return .erc20TokenDisabled
                }
                guard normalizedAddress(recipient) != nil else {
                    return .invalidRecipient
                }
                guard let amount = parsedTokenAmount(amount, decimals: token.decimals) else {
                    return .invalidAmount
                }
                return isLessThanOrEqual(amount, tokenCap) ? nil : .overValueLimit
            }

        case let .exactInputSwap(request):
            guard config.allowlist.swapRouter else {
                return .swapsDisabled
            }
            guard request.quote.chainID == context.chainID else {
                return .wrongChain
            }
            guard normalizedAddress(request.recipient) != nil else {
                return .invalidRecipient
            }
            guard isKnownSwapRouter(request.quote.router, chainID: context.chainID) else {
                return .unsupportedSwapRouter
            }
            guard let tokenIn = knownERC20Token(address: request.quote.tokenIn, chainID: context.chainID),
                  knownERC20Token(address: request.quote.tokenOut, chainID: context.chainID) != nil
            else {
                return .unsupportedSwapToken
            }
            if request.tokenInIsNative {
                return isLessThanOrEqual(request.quote.amountIn, nativeCap) ? nil : .overValueLimit
            }
            guard let tokenCap = erc20CapData(config: config, token: tokenIn) else {
                return .erc20TokenDisabled
            }
            guard !request.quote.requiresApproval || config.allowlist.erc20Approvals != .disabled else {
                return .erc20ApprovalsDisabled
            }
            if request.quote.requiresApproval,
               config.allowlist.erc20Approvals == .knownSwapRouters,
               !isKnownSwapRouter(request.quote.router, chainID: context.chainID) {
                return .unsupportedApprovalSpender
            }
            return isLessThanOrEqual(request.quote.amountIn, tokenCap) ? nil : .overValueLimit
        }
    }

    static func isWithinPolicy(
        intent: TransactionIntent,
        sessionRecord: SessionRecord,
        now: Date,
        recentSessionTransactionDates: [Date] = []
    ) -> Bool {
        isWithinPolicy(
            intent: intent,
            config: sessionRecord.policyConfigSnapshot,
            context: SessionPolicyContext(
                sessionRecord: sessionRecord,
                now: now,
                recentSessionTransactionDates: recentSessionTransactionDates
            )
        )
    }

    private static func isActive(_ context: SessionPolicyContext, config: SessionPolicyConfig) -> Bool {
        guard context.now < context.expiresAt else {
            return false
        }
        let inactivityExpiresAt = context.lastActivityAt.addingTimeInterval(
            TimeInterval(config.inactivityTimeoutSeconds)
        )
        return context.now < inactivityExpiresAt
    }

    private static func isUnderRateLimit(
        config: SessionPolicyConfig,
        context: SessionPolicyContext
    ) -> Bool {
        guard config.rateLimitCount > 0, config.rateLimitIntervalSec > 0 else {
            return false
        }
        let windowStart = context.now.addingTimeInterval(-TimeInterval(config.rateLimitIntervalSec))
        let recentCount = context.recentSessionTransactionDates.filter {
            $0 >= windowStart && $0 <= context.now
        }.count
        return recentCount < config.rateLimitCount
    }

    private static func capData(_ value: String) -> Data? {
        guard let data = try? Data.quantityString(value) else {
            return nil
        }
        let padded = data.leftPadded(to: 32)
        guard padded.count == 32 else {
            return nil
        }
        return padded
    }

    private static func erc20CapData(config: SessionPolicyConfig, token: WalletToken) -> Data? {
        guard let limit = config.erc20TokenLimit(for: token),
              limit.isEnabled
        else {
            return nil
        }
        return capData(limit.maxAmount)
    }

    private static func parsedETH(_ amount: String) -> Data? {
        try? EtherAmountParser.wei(fromETHString: amount)
    }

    private static func parsedTokenAmount(_ amount: String, decimals: Int) -> Data? {
        try? EtherAmountParser.units(fromDecimalString: amount, decimals: decimals)
    }

    private static func isKnownERC20Token(_ token: WalletToken, chainID: UInt64) -> Bool {
        guard token.chainID == chainID,
              let address = token.contractAddress
        else {
            return false
        }
        return isKnownERC20Address(address, chainID: chainID)
    }

    private static func isKnownERC20Address(_ address: String, chainID: UInt64) -> Bool {
        knownERC20Token(address: address, chainID: chainID) != nil
    }

    private static func knownERC20Token(address: String, chainID: UInt64) -> WalletToken? {
        guard let normalized = normalizedAddress(address),
              let token = WalletTokenRegistry.token(matching: normalized, on: chainID)
        else {
            return nil
        }
        return token.contractAddress != nil ? token : nil
    }

    private static func isKnownSwapRouter(_ address: String, chainID: UInt64) -> Bool {
        guard let normalized = normalizedAddress(address) else {
            return false
        }
        return SessionSwapRouterRegistry.routerSet(on: chainID).contains(normalized)
    }

    private static func normalizedAddress(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if trimmed.lowercased().hasPrefix("0x") {
            body = String(trimmed.dropFirst(2))
        } else {
            body = trimmed
        }
        guard body.count == 40,
              body.allSatisfy(\.isHexDigit),
              let data = try? Data(hexString: "0x" + body),
              data.count == 20
        else {
            return nil
        }
        return "0x" + data.hexEncodedString
    }

    private static func isLessThanOrEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let width = max(32, lhs.count, rhs.count)
        let left = lhs.leftPadded(to: width)
        let right = rhs.leftPadded(to: width)
        for (leftByte, rightByte) in zip(left, right) where leftByte != rightByte {
            return leftByte < rightByte
        }
        return true
    }
}
