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
    static func isWithinPolicy(
        intent: TransactionIntent,
        config: SessionPolicyConfig,
        context: SessionPolicyContext
    ) -> Bool {
        guard isActive(context, config: config),
              isUnderRateLimit(config: config, context: context),
              let cap = capData(config)
        else {
            return false
        }

        switch intent {
        case let .nativeTransfer(recipient, amountETH):
            return config.allowlist.nativeTransfers
                && normalizedAddress(recipient) != nil
                && parsedETH(amountETH).map { isLessThanOrEqual($0, cap) } == true

        case let .erc20Transfer(token, recipient, amount):
            switch config.allowlist.erc20TokenScope {
            case .knownList:
                return isKnownERC20Token(token, chainID: context.chainID)
                    && normalizedAddress(recipient) != nil
                    && parsedTokenAmount(amount, decimals: token.decimals).map { isLessThanOrEqual($0, cap) } == true
            }

        case let .exactInputSwap(request):
            return config.allowlist.swapRouter
                && request.quote.chainID == context.chainID
                && normalizedAddress(request.recipient) != nil
                && isKnownSwapRouter(request.quote.router, chainID: context.chainID)
                && isKnownERC20Address(request.quote.tokenIn, chainID: context.chainID)
                && isKnownERC20Address(request.quote.tokenOut, chainID: context.chainID)
                && isLessThanOrEqual(request.quote.amountIn, cap)
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

    private static func capData(_ config: SessionPolicyConfig) -> Data? {
        guard let data = try? Data.quantityString(config.perTxValueLimitWei) else {
            return nil
        }
        let padded = data.leftPadded(to: 32)
        guard padded.count == 32 else {
            return nil
        }
        return padded
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
        guard let normalized = normalizedAddress(address),
              let token = WalletTokenRegistry.token(matching: normalized, on: chainID)
        else {
            return false
        }
        return token.contractAddress != nil
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
