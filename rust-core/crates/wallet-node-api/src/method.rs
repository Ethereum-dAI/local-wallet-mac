use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Method {
    #[serde(rename = "wallet_health")]
    WalletHealth,
    #[serde(rename = "wallet_networkStatus")]
    WalletNetworkStatus,
    #[serde(rename = "wallet_bundlerStatus")]
    WalletBundlerStatus,
    #[serde(rename = "wallet_walletStatus")]
    WalletWalletStatus,
    #[serde(rename = "wallet_pendingOperations")]
    WalletPendingOperations,
    #[serde(rename = "wallet_cancelPendingOperation")]
    WalletCancelPendingOperation,
    #[serde(rename = "wallet_rotateBundlerEOA")]
    WalletRotateBundlerEOA,
    #[serde(rename = "wallet_shutdown")]
    WalletShutdown,
    #[serde(rename = "eth_getBalance")]
    EthGetBalance,
    #[serde(rename = "eth_getCode")]
    EthGetCode,
    #[serde(rename = "eth_getTransactionCount")]
    EthGetTransactionCount,
    #[serde(rename = "eth_call")]
    EthCall,
    #[serde(rename = "eth_getTransactionReceipt")]
    EthGetTransactionReceipt,
    #[serde(rename = "eth_getBlockByNumber")]
    EthGetBlockByNumber,
    #[serde(rename = "eth_estimateGas")]
    EthEstimateGas,
    #[serde(rename = "eth_maxPriorityFeePerGas")]
    EthMaxPriorityFeePerGas,
    #[serde(rename = "eth_gasPrice")]
    EthGasPrice,
    #[serde(rename = "eth_supportedEntryPoints")]
    EthSupportedEntryPoints,
    #[serde(rename = "eth_estimateUserOperationGas")]
    EthEstimateUserOperationGas,
    #[serde(rename = "eth_sendUserOperation")]
    EthSendUserOperation,
    #[serde(rename = "eth_getUserOperationReceipt")]
    EthGetUserOperationReceipt,
    #[serde(rename = "pimlico_getUserOperationGasPrice")]
    PimlicoGetUserOperationGasPrice,
}

impl Method {
    pub fn from_str(s: &str) -> Option<Method> {
        match s {
            "wallet_health" => Some(Method::WalletHealth),
            "wallet_networkStatus" => Some(Method::WalletNetworkStatus),
            "wallet_bundlerStatus" => Some(Method::WalletBundlerStatus),
            "wallet_walletStatus" => Some(Method::WalletWalletStatus),
            "wallet_pendingOperations" => Some(Method::WalletPendingOperations),
            "wallet_cancelPendingOperation" => Some(Method::WalletCancelPendingOperation),
            "wallet_rotateBundlerEOA" => Some(Method::WalletRotateBundlerEOA),
            "wallet_shutdown" => Some(Method::WalletShutdown),
            "eth_getBalance" => Some(Method::EthGetBalance),
            "eth_getCode" => Some(Method::EthGetCode),
            "eth_getTransactionCount" => Some(Method::EthGetTransactionCount),
            "eth_call" => Some(Method::EthCall),
            "eth_getTransactionReceipt" => Some(Method::EthGetTransactionReceipt),
            "eth_getBlockByNumber" => Some(Method::EthGetBlockByNumber),
            "eth_estimateGas" => Some(Method::EthEstimateGas),
            "eth_maxPriorityFeePerGas" => Some(Method::EthMaxPriorityFeePerGas),
            "eth_gasPrice" => Some(Method::EthGasPrice),
            "eth_supportedEntryPoints" => Some(Method::EthSupportedEntryPoints),
            "eth_estimateUserOperationGas" => Some(Method::EthEstimateUserOperationGas),
            "eth_sendUserOperation" => Some(Method::EthSendUserOperation),
            "eth_getUserOperationReceipt" => Some(Method::EthGetUserOperationReceipt),
            "pimlico_getUserOperationGasPrice" => Some(Method::PimlicoGetUserOperationGasPrice),
            _ => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Method::WalletHealth => "wallet_health",
            Method::WalletNetworkStatus => "wallet_networkStatus",
            Method::WalletBundlerStatus => "wallet_bundlerStatus",
            Method::WalletWalletStatus => "wallet_walletStatus",
            Method::WalletPendingOperations => "wallet_pendingOperations",
            Method::WalletCancelPendingOperation => "wallet_cancelPendingOperation",
            Method::WalletRotateBundlerEOA => "wallet_rotateBundlerEOA",
            Method::WalletShutdown => "wallet_shutdown",
            Method::EthGetBalance => "eth_getBalance",
            Method::EthGetCode => "eth_getCode",
            Method::EthGetTransactionCount => "eth_getTransactionCount",
            Method::EthCall => "eth_call",
            Method::EthGetTransactionReceipt => "eth_getTransactionReceipt",
            Method::EthGetBlockByNumber => "eth_getBlockByNumber",
            Method::EthEstimateGas => "eth_estimateGas",
            Method::EthMaxPriorityFeePerGas => "eth_maxPriorityFeePerGas",
            Method::EthGasPrice => "eth_gasPrice",
            Method::EthSupportedEntryPoints => "eth_supportedEntryPoints",
            Method::EthEstimateUserOperationGas => "eth_estimateUserOperationGas",
            Method::EthSendUserOperation => "eth_sendUserOperation",
            Method::EthGetUserOperationReceipt => "eth_getUserOperationReceipt",
            Method::PimlicoGetUserOperationGasPrice => "pimlico_getUserOperationGasPrice",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_methods() -> Vec<Method> {
        vec![
            Method::WalletHealth,
            Method::WalletNetworkStatus,
            Method::WalletBundlerStatus,
            Method::WalletWalletStatus,
            Method::WalletPendingOperations,
            Method::WalletCancelPendingOperation,
            Method::WalletRotateBundlerEOA,
            Method::WalletShutdown,
            Method::EthGetBalance,
            Method::EthGetCode,
            Method::EthGetTransactionCount,
            Method::EthCall,
            Method::EthGetTransactionReceipt,
            Method::EthGetBlockByNumber,
            Method::EthEstimateGas,
            Method::EthMaxPriorityFeePerGas,
            Method::EthGasPrice,
            Method::EthSupportedEntryPoints,
            Method::EthEstimateUserOperationGas,
            Method::EthSendUserOperation,
            Method::EthGetUserOperationReceipt,
            Method::PimlicoGetUserOperationGasPrice,
        ]
    }

    #[test]
    fn all_variants_round_trip_through_wire_name() {
        for method in all_methods() {
            assert_eq!(Method::from_str(method.as_str()), Some(method));
        }
    }

    #[test]
    fn unknown_method_returns_none() {
        assert_eq!(Method::from_str("nonsense"), None);
    }
}
