import Foundation

// MARK: - Why this file exists
//
// This eval needs the app's REAL guard/encoding logic (WalletTokenRegistry,
// EtherAmountParser, UserOperationBuilder's Kernel `execute()` ABI encoding)
// so a pass here means the app's real pipeline would also pass. The natural
// way to get that is to import WalletMacOSApp directly.
//
// That does NOT work reliably. WalletMacOSApp is a SwiftPM `.executable`
// product. `@testable import WalletMacOSApp` type-checks from another
// executable target and even links in some cached-build states, but fails
// with "symbol(s) not found" under a clean `swift build`/`swift run` — the
// -enable-testing export SwiftPM guarantees is scoped to `swift test`, not
// arbitrary targets. Making the needed declarations `public` in WalletMacOSApp
// does not fix it either: every new `public` init/func I added there (and
// even some pre-existing `public`-able members) still linked as "symbol not
// found," while members ALSO called from within WalletMacOSApp itself linked
// fine. That matches SwiftPM's documented support for "a test target may
// depend on an executable target" being specific to XCTest-style test
// bundles (how WalletMacOSAppTests already depends on WalletMacOSApp) — NOT
// a general executable-to-executable target dependency. Both experiments
// (product-code visibility changes, `@testable import`) were reverted; see
// task-C-report.md for exactly what was tried.
//
// So this file is a byte-for-byte PORT of the pieces of
// Sources/WalletMacOSApp/{EtherAmountParser,UserOperationModels,
// UserOperationBuilder,HexEncoding}.swift this eval needs — copied, not
// reimplemented with different logic, and each function says which source
// function it mirrors. This is NOT a link to product code: if those files
// change, this file can silently drift, and there is no compiler error to
// catch it. That is a real limitation of this eval, stated again in the
// report.
//
// Kept deliberately small: every case in this eval's dataset (native
// transfer, ERC-20 transfer, or exact-input swap with a fixture quote whose
// requiresApproval is always false) produces exactly ONE
// KernelExecutionRequest. So only the SINGLE-execution encode path
// (KernelCallEncoder.encodeExecuteSingle / abiEncodePackedExecution) is
// ported — the batch/array path, the ERC-20 approval encoder, and the Kernel
// deployment (initCode) encoder are never exercised by this dataset and are
// NOT ported.

// MARK: - Data hex helpers (ports Sources/WalletMacOSApp/HexEncoding.swift)

enum PortedHexError: Error { case invalidHexString }

extension Data {
    /// Ports `Data.init(hexString:)`.
    init(hexString: String) throws {
        let normalized = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard normalized.count.isMultiple(of: 2) else {
            throw PortedHexError.invalidHexString
        }
        var bytes = Data(capacity: normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let nextIndex = normalized.index(index, offsetBy: 2)
            let byteString = normalized[index..<nextIndex]
            guard let value = UInt8(byteString, radix: 16) else {
                throw PortedHexError.invalidHexString
            }
            bytes.append(value)
            index = nextIndex
        }
        self = bytes
    }

    /// Ports `Data.hexEncodedString`.
    var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Ports `Data.leftPadded(to:)`.
    func leftPadded(to length: Int) -> Data {
        if count >= length { return self }
        return Data(repeating: 0, count: length - count) + self
    }

    /// Ports `Data.fromBigEndian(_:)`.
    static func fromBigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: MemoryLayout<T>.size)
    }
}

/// Only for literal hex constants below (selectors) — ports the private
/// `Data(hex:)` helper at the bottom of UserOperationBuilder.swift.
private extension Data {
    init(hex: String) {
        let normalized = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        self = stride(from: 0, to: normalized.count, by: 2).reduce(into: Data()) { data, index in
            let start = normalized.index(normalized.startIndex, offsetBy: index)
            let end = normalized.index(start, offsetBy: 2)
            let value = UInt8(normalized[start..<end], radix: 16) ?? 0
            data.append(value)
        }
    }
}

// MARK: - WalletToken / WalletTokenRegistry (ports UserOperationModels.swift)

struct WalletToken: Equatable {
    enum Kind: Equatable {
        case native
        case erc20(address: String)
    }

    let chainID: UInt64
    let symbol: String
    let decimals: Int
    let kind: Kind

    var id: String { "\(chainID):\(symbol.uppercased())" }

    var contractAddress: String? {
        if case let .erc20(address) = kind { return address }
        return nil
    }

    var isNative: Bool { kind == .native }
}

enum WalletTokenRegistry {
    /// Ports `WalletTokenRegistry.token(matching:on:)` verbatim.
    static func token(matching rawValue: String?, on chainID: UInt64) -> WalletToken? {
        let normalized = (rawValue ?? "ETH").trimmingCharacters(in: .whitespacesAndNewlines)
        let lookup = normalized.isEmpty ? "ETH" : normalized

        if lookup.hasPrefix("0x") || lookup.hasPrefix("0X") {
            return tokens(on: chainID).first {
                $0.contractAddress?.caseInsensitiveCompare(lookup) == .orderedSame
            }
        }
        return tokens(on: chainID).first {
            $0.symbol.caseInsensitiveCompare(lookup) == .orderedSame
        }
    }

    /// Ports `WalletTokenRegistry.wrappedNativeToken(on:)`.
    static func wrappedNativeToken(on chainID: UInt64) -> WalletToken? {
        token(matching: "WETH", on: chainID)
    }

    static func tokens(on chainID: UInt64) -> [WalletToken] {
        allTokens.filter { $0.chainID == chainID }
    }

    /// Ports the exact literal token table in UserOperationModels.swift
    /// (symbol/decimals/address only — `name` is dropped, unused here).
    private static let allTokens: [WalletToken] = [
        WalletToken(chainID: 1, symbol: "ETH", decimals: 18, kind: .native),
        WalletToken(chainID: 1, symbol: "WETH", decimals: 18, kind: .erc20(address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")),
        WalletToken(chainID: 1, symbol: "USDC", decimals: 6, kind: .erc20(address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")),
        WalletToken(chainID: 1, symbol: "USDT", decimals: 6, kind: .erc20(address: "0xdAC17F958D2ee523a2206206994597C13D831ec7")),
        WalletToken(chainID: 1, symbol: "DAI", decimals: 18, kind: .erc20(address: "0x6B175474E89094C44Da98b954EedeAC495271d0F")),
        WalletToken(chainID: 1, symbol: "WBTC", decimals: 8, kind: .erc20(address: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599")),
        WalletToken(chainID: 1, symbol: "LINK", decimals: 18, kind: .erc20(address: "0x514910771AF9Ca656af840dff83E8264EcF986CA")),
        WalletToken(chainID: 1, symbol: "UNI", decimals: 18, kind: .erc20(address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984")),
        WalletToken(chainID: 1, symbol: "AAVE", decimals: 18, kind: .erc20(address: "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9")),
        WalletToken(chainID: 1, symbol: "LDO", decimals: 18, kind: .erc20(address: "0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32")),
        WalletToken(chainID: 11_155_111, symbol: "ETH", decimals: 18, kind: .native),
        WalletToken(chainID: 11_155_111, symbol: "WETH", decimals: 18, kind: .erc20(address: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14")),
        WalletToken(chainID: 11_155_111, symbol: "USDC", decimals: 6, kind: .erc20(address: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238")),
        WalletToken(chainID: 11_155_111, symbol: "USDT", decimals: 6, kind: .erc20(address: "0xaa8E23Fb1079EA71e0a56F48a2aA51851D8433D0")),
        WalletToken(chainID: 11_155_111, symbol: "DAI", decimals: 18, kind: .erc20(address: "0x776b6FC2eD15d6bB5fC32e0c89DE68683118c62a")),
        WalletToken(chainID: 11_155_111, symbol: "AAVE", decimals: 18, kind: .erc20(address: "0x5Bb220aFc6e2E008cB2302A83536A019ed245Aa2")),
        WalletToken(chainID: 11_155_111, symbol: "UNI", decimals: 18, kind: .erc20(address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984")),
    ]
}

// MARK: - EtherAmountParser (ports Sources/WalletMacOSApp/EtherAmountParser.swift)

enum PortedAmountError: Error { case invalidAmount }

enum EtherAmountParser {
    /// Ports `EtherAmountParser.units(fromDecimalString:decimals:)` verbatim,
    /// including the exact rejection of anything non-digit (commas included).
    static func units(fromDecimalString value: String, decimals: Int) throws -> Data {
        guard decimals >= 0 else { throw PortedAmountError.invalidAmount }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PortedAmountError.invalidAmount }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw PortedAmountError.invalidAmount }

        let wholePart = String(parts[0])
        let fractionalPart = parts.count == 2 ? String(parts[1]) : ""

        guard wholePart.allSatisfy(\.isNumber), fractionalPart.allSatisfy(\.isNumber) else {
            throw PortedAmountError.invalidAmount
        }

        if fractionalPart.count > decimals {
            let extraFraction = fractionalPart.dropFirst(decimals)
            guard extraFraction.allSatisfy({ $0 == "0" }) else {
                throw PortedAmountError.invalidAmount
            }
        }

        let clippedFraction = String(fractionalPart.prefix(decimals))
        guard clippedFraction.count <= decimals else { throw PortedAmountError.invalidAmount }

        let normalizedWhole = wholePart.isEmpty ? "0" : wholePart
        let paddedFraction = clippedFraction + String(repeating: "0", count: decimals - clippedFraction.count)
        let decimalString = normalizedWhole + paddedFraction
        let normalizedDecimal = decimalString.drop { $0 == "0" }

        guard !normalizedDecimal.isEmpty else {
            return Data(repeating: 0, count: 32)
        }

        return try hexData(fromDecimalString: String(normalizedDecimal)).leftPadded(to: 32)
    }

    private static func hexData(fromDecimalString value: String) throws -> Data {
        var digits = value.compactMap(\.wholeNumberValue)
        var bytes = [UInt8]()

        while !digits.isEmpty {
            var quotient = [Int]()
            quotient.reserveCapacity(digits.count)
            var remainder = 0

            for digit in digits {
                let accumulator = remainder * 10 + digit
                let q = accumulator / 256
                remainder = accumulator % 256
                if !quotient.isEmpty || q != 0 {
                    quotient.append(q)
                }
            }

            bytes.append(UInt8(remainder))
            digits = quotient
        }

        guard !bytes.isEmpty else { throw PortedAmountError.invalidAmount }
        return Data(bytes.reversed())
    }
}

// MARK: - Kernel execute() / ERC-20 / swap-router encoders (ports UserOperationBuilder.swift)

enum PortedEncodingError: Error { case invalidExecutionAddress }

struct KernelExecutionRequest: Equatable {
    let target: String
    let value: Data
    let callData: Data
}

extension KernelExecutionRequest {
    static func zeroValueCall(target: String, callData: Data) -> KernelExecutionRequest {
        KernelExecutionRequest(target: target, value: Data(repeating: 0, count: 32), callData: callData)
    }
}

struct KernelCallEncoder {
    private static let executeSelector = Data(hex: "e9ae5c53")
    private static let execModeSingleDefault = Data(repeating: 0, count: 32)

    /// Ports `KernelCallEncoder.encodeExecuteSingle` (which itself is
    /// `encodeExecute` specialized to the single-mode branch) plus its
    /// private helpers `abiEncodePackedExecution` / `executionTargetData` /
    /// `abiEncodeDynamicBytes`. The batch/array path is not ported (see file
    /// header — never exercised by this dataset).
    func encodeExecuteSingle(_ request: KernelExecutionRequest) throws -> Data {
        let executionCalldata = try abiEncodePackedExecution(request)
        return Self.executeSelector
            + Self.execModeSingleDefault
            + Data.fromBigEndian(UInt64(64)).leftPadded(to: 32)
            + abiEncodeDynamicBytes(executionCalldata)
    }

    private func abiEncodePackedExecution(_ request: KernelExecutionRequest) throws -> Data {
        try executionTargetData(request.target)
            + request.value.leftPadded(to: 32)
            + request.callData
    }

    private func executionTargetData(_ target: String) throws -> Data {
        let target = try Data(hexString: target)
        guard target.count == 20 else { throw PortedEncodingError.invalidExecutionAddress }
        return target
    }

    private func abiEncodeDynamicBytes(_ value: Data) -> Data {
        let length = Data.fromBigEndian(UInt64(value.count)).leftPadded(to: 32)
        let remainder = value.count % 32
        let padding = remainder == 0 ? 0 : 32 - remainder
        return length + value + Data(repeating: 0, count: padding)
    }
}

struct ERC20TransferCallEncoder {
    private static let transferSelector = Data(hex: "a9059cbb")

    /// Ports `ERC20TransferCallEncoder.encodeTransfer`.
    func encodeTransfer(recipient: String, amount: Data) throws -> Data {
        let recipientData = try Data(hexString: recipient)
        guard recipientData.count == 20 else { throw PortedEncodingError.invalidExecutionAddress }
        return Self.transferSelector + recipientData.leftPadded(to: 32) + amount.leftPadded(to: 32)
    }
}

struct SwapRouterCallEncoder {
    private static let exactInputSelector = Data(hex: "b858183f")
    private static let multicallSelector = Data(hex: "ac9650d8")
    private static let unwrapWETH9Selector = Data(hex: "49404b7c")

    /// Ports `SwapRouterCallEncoder.encodeExactInput`.
    func encodeExactInput(path: Data, recipient: String, amountIn: Data, amountOutMinimum: Data) throws -> Data {
        let recipientData = try Data(hexString: recipient)
        guard recipientData.count == 20 else { throw PortedEncodingError.invalidExecutionAddress }
        return Self.exactInputSelector
            + Data.fromBigEndian(UInt64(32)).leftPadded(to: 32)
            + Data.fromBigEndian(UInt64(128)).leftPadded(to: 32)
            + recipientData.leftPadded(to: 32)
            + amountIn.leftPadded(to: 32)
            + amountOutMinimum.leftPadded(to: 32)
            + abiEncodeDynamicBytes(path)
    }

    /// Ports `SwapRouterCallEncoder.encodeUnwrapWETH9`.
    func encodeUnwrapWETH9(amountMinimum: Data, recipient: String) throws -> Data {
        let recipientData = try Data(hexString: recipient)
        guard recipientData.count == 20 else { throw PortedEncodingError.invalidExecutionAddress }
        return Self.unwrapWETH9Selector + amountMinimum.leftPadded(to: 32) + recipientData.leftPadded(to: 32)
    }

    /// Ports `SwapRouterCallEncoder.encodeMulticall`.
    func encodeMulticall(_ calls: [Data]) -> Data {
        var encodedCalls = Data()
        var offsets = Data()
        var nextOffset = calls.count * 32
        for call in calls {
            offsets += Data.fromBigEndian(UInt64(nextOffset)).leftPadded(to: 32)
            let encoded = abiEncodeDynamicBytes(call)
            encodedCalls += encoded
            nextOffset += encoded.count
        }
        return Self.multicallSelector
            + Data.fromBigEndian(UInt64(32)).leftPadded(to: 32)
            + Data.fromBigEndian(UInt64(calls.count)).leftPadded(to: 32)
            + offsets
            + encodedCalls
    }

    private func abiEncodeDynamicBytes(_ value: Data) -> Data {
        let length = Data.fromBigEndian(UInt64(value.count)).leftPadded(to: 32)
        let remainder = value.count % 32
        let padding = remainder == 0 ? 0 : 32 - remainder
        return length + value + Data(repeating: 0, count: padding)
    }
}

// MARK: - TransactionIntent / SwapQuote (ports the shapes in UserOperationModels.swift)

enum TransactionIntent: Equatable {
    case nativeTransfer(recipient: String, amountETH: String)
    case erc20Transfer(token: WalletToken, recipient: String, amount: String)
    case exactInputSwap(SwapExecutionRequest)
}

/// Trimmed to exactly the fields `SwapRouterCallEncoder` reads. The real
/// `SwapQuote` also carries `quoteAmountOut`/`hops`/`allowance`/`gasEstimate`
/// for UI display — none of those affect encoding, so they are not ported.
struct SwapQuote: Equatable {
    let router: String
    let path: Data
    let amountIn: Data
    let amountOutMinimum: Data
    let requiresApproval: Bool
}

struct SwapExecutionRequest: Equatable {
    let quote: SwapQuote
    let recipient: String
    let tokenInIsNative: Bool
    let tokenOutIsNative: Bool
}

// MARK: - UserOperationBuilder (ports the encode leg of buildDraft)

/// Ports the single-execution leg of `UserOperationBuilder.buildDraft` /
/// `buildExecutionRequests(for:sessionMode:)`. `sessionMode` is always false
/// here (this eval never batches via session keys) and the ERC-20-approval
/// branch of the real `buildExecutionRequests` is omitted, because every
/// swap fixture this eval constructs sets `requiresApproval = false` (see
/// `SwapFixtures` in UserOpRunner.swift), so that branch would always
/// contribute zero executions anyway.
///
/// What is deliberately NOT ported: `WalletRecord`, `ChainConfiguration`,
/// `PublicKeyCoordinates`, the nonce, and the Kernel-deployment `initCode`
/// encoder. In the real `buildDraft`, those only affect `sender`/`nonce`/
/// `initCode`/`entryPoint`/`chainId` on the returned draft — never
/// `callData` — and `callData` is the only field this eval's stage-6
/// "correct" check compares (see UserOpRunner.swift). Given a real
/// `isDeployed = true` fixture, `initCode` is always empty regardless of the
/// public key / salt / authenticator hash supplied, so modeling those
/// fixtures here would add code without changing any comparison this eval
/// makes.
struct UserOperationBuilder {
    private let kernelCallEncoder = KernelCallEncoder()
    private let erc20TransferCallEncoder = ERC20TransferCallEncoder()
    private let swapRouterCallEncoder = SwapRouterCallEncoder()

    func buildExecutionRequest(for intent: TransactionIntent) throws -> KernelExecutionRequest {
        switch intent {
        case .nativeTransfer(let recipient, let amountETH):
            let addressData = try Data(hexString: recipient)
            guard addressData.count == 20 else { throw PortedEncodingError.invalidExecutionAddress }
            return KernelExecutionRequest(
                target: "0x" + addressData.hexEncodedString,
                value: try EtherAmountParser.units(fromDecimalString: amountETH, decimals: 18),
                callData: Data()
            )

        case .erc20Transfer(let token, let recipient, let amount):
            guard let tokenAddress = token.contractAddress else {
                throw PortedEncodingError.invalidExecutionAddress
            }
            let tokenAddressData = try Data(hexString: tokenAddress)
            guard tokenAddressData.count == 20 else { throw PortedEncodingError.invalidExecutionAddress }
            let transferAmount = try EtherAmountParser.units(fromDecimalString: amount, decimals: token.decimals)
            return KernelExecutionRequest.zeroValueCall(
                target: "0x" + tokenAddressData.hexEncodedString,
                callData: try erc20TransferCallEncoder.encodeTransfer(recipient: recipient, amount: transferAmount)
            )

        case .exactInputSwap(let request):
            let routerData = try Data(hexString: request.quote.router)
            guard routerData.count == 20 else { throw PortedEncodingError.invalidExecutionAddress }
            let routerTarget = "0x" + routerData.hexEncodedString

            let routerCallData: Data
            if request.tokenOutIsNative {
                let swapCallData = try swapRouterCallEncoder.encodeExactInput(
                    path: request.quote.path,
                    recipient: request.quote.router,
                    amountIn: request.quote.amountIn,
                    amountOutMinimum: request.quote.amountOutMinimum
                )
                let unwrapCallData = try swapRouterCallEncoder.encodeUnwrapWETH9(
                    amountMinimum: request.quote.amountOutMinimum,
                    recipient: request.recipient
                )
                routerCallData = swapRouterCallEncoder.encodeMulticall([swapCallData, unwrapCallData])
            } else {
                routerCallData = try swapRouterCallEncoder.encodeExactInput(
                    path: request.quote.path,
                    recipient: request.recipient,
                    amountIn: request.quote.amountIn,
                    amountOutMinimum: request.quote.amountOutMinimum
                )
            }

            return KernelExecutionRequest(
                target: routerTarget,
                value: request.tokenInIsNative ? request.quote.amountIn : Data(repeating: 0, count: 32),
                callData: routerCallData
            )
        }
    }

    /// The stage-5 "build" entry point: encodes the intent into the Kernel
    /// `execute()` calldata a signable UserOp would carry. Throwing here is
    /// exactly the "buildDraft threw" outcome the brief's stage 5 describes.
    func callData(for intent: TransactionIntent) throws -> Data {
        let execution = try buildExecutionRequest(for: intent)
        return try kernelCallEncoder.encodeExecuteSingle(execution)
    }
}
