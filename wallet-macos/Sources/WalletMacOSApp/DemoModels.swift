import Foundation

struct AccountInspection: Equatable {
    let address: String
    let isDeployed: Bool
    let balanceWeiHex: String
    let codeHex: String

    var stateTitle: String {
        isDeployed ? "Deployed" : "Precomputed"
    }

    var balanceDisplay: String {
        WeiFormatter.ethDisplayString(fromHexWei: balanceWeiHex)
    }
}

enum DemoTransactionKind: String, CaseIterable {
    case ethTransfer = "ETH Transfer"
}

struct TransactionComposerState: Equatable {
    var selectedKind: DemoTransactionKind = .ethTransfer
    var recipient: String = ""
    var amountETH: String = ""

    var summary: String {
        switch selectedKind {
        case .ethTransfer:
            if recipient.isEmpty || amountETH.isEmpty {
                return "Enter recipient and amount, then build or send the UserOperation."
            }

            return "ETH transfer ready: \(amountETH) ETH to \(recipient.shortAddress)."
        }
    }
}

private extension String {
    var shortAddress: String {
        guard count > 14 else {
            return self
        }
        return "\(prefix(8))…\(suffix(6))"
    }
}
