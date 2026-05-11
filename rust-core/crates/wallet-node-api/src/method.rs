use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Method {
    #[serde(rename = "wallet_health")]
    WalletHealth,
    #[serde(rename = "wallet_apiVersion")]
    WalletApiVersion,
    #[serde(rename = "wallet_networkStatus")]
    WalletNetworkStatus,
    #[serde(rename = "wallet_bundlerStatus")]
    WalletBundlerStatus,
    #[serde(rename = "wallet_walletStatus")]
    WalletWalletStatus,
    #[serde(rename = "wallet_pendingOperations")]
    WalletPendingOperations,
    #[serde(rename = "wallet_auditStore")]
    WalletAuditStore,
    #[serde(rename = "wallet_auditHistory")]
    WalletAuditHistory,
    #[serde(rename = "wallet_auditReport")]
    WalletAuditReport,
    #[serde(rename = "wallet_repairStore")]
    WalletRepairStore,
    #[serde(rename = "wallet_cancelPendingOperation")]
    WalletCancelPendingOperation,
    #[serde(rename = "wallet_beginAdminAction")]
    WalletBeginAdminAction,
    #[serde(rename = "wallet_rotateBundlerEOA")]
    WalletRotateBundlerEOA,
    #[serde(rename = "wallet_installBundlerEOA")]
    WalletInstallBundlerEOA,
    #[serde(rename = "wallet_deleteBundlerEOA")]
    WalletDeleteBundlerEOA,
    #[serde(rename = "wallet_shutdown")]
    WalletShutdown,
    #[serde(rename = "eth_chainId")]
    EthChainId,
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
    #[serde(rename = "localwallet_supportedEntryPoints")]
    LocalWalletSupportedEntryPoints,
    #[serde(rename = "localwallet_estimateUserOperationGas")]
    LocalWalletEstimateUserOperationGas,
    #[serde(rename = "localwallet_sendUserOperation")]
    LocalWalletSendUserOperation,
    #[serde(rename = "localwallet_getUserOperationReceipt")]
    LocalWalletGetUserOperationReceipt,
    #[serde(rename = "localwallet_getUserOperationGasPrice")]
    LocalWalletGetUserOperationGasPrice,
}

impl Method {
    pub fn parse_wire_name(s: &str) -> Option<Method> {
        match s {
            "wallet_health" => Some(Method::WalletHealth),
            "wallet_apiVersion" => Some(Method::WalletApiVersion),
            "wallet_networkStatus" => Some(Method::WalletNetworkStatus),
            "wallet_bundlerStatus" => Some(Method::WalletBundlerStatus),
            "wallet_walletStatus" => Some(Method::WalletWalletStatus),
            "wallet_pendingOperations" => Some(Method::WalletPendingOperations),
            "wallet_auditStore" => Some(Method::WalletAuditStore),
            "wallet_auditHistory" => Some(Method::WalletAuditHistory),
            "wallet_auditReport" => Some(Method::WalletAuditReport),
            "wallet_repairStore" => Some(Method::WalletRepairStore),
            "wallet_cancelPendingOperation" => Some(Method::WalletCancelPendingOperation),
            "wallet_beginAdminAction" => Some(Method::WalletBeginAdminAction),
            "wallet_rotateBundlerEOA" => Some(Method::WalletRotateBundlerEOA),
            "wallet_installBundlerEOA" => Some(Method::WalletInstallBundlerEOA),
            "wallet_deleteBundlerEOA" => Some(Method::WalletDeleteBundlerEOA),
            "wallet_shutdown" => Some(Method::WalletShutdown),
            "eth_chainId" => Some(Method::EthChainId),
            "eth_getBalance" => Some(Method::EthGetBalance),
            "eth_getCode" => Some(Method::EthGetCode),
            "eth_getTransactionCount" => Some(Method::EthGetTransactionCount),
            "eth_call" => Some(Method::EthCall),
            "eth_getTransactionReceipt" => Some(Method::EthGetTransactionReceipt),
            "eth_getBlockByNumber" => Some(Method::EthGetBlockByNumber),
            "eth_estimateGas" => Some(Method::EthEstimateGas),
            "eth_maxPriorityFeePerGas" => Some(Method::EthMaxPriorityFeePerGas),
            "eth_gasPrice" => Some(Method::EthGasPrice),
            "localwallet_supportedEntryPoints" | "eth_supportedEntryPoints" => {
                Some(Method::LocalWalletSupportedEntryPoints)
            }
            "localwallet_estimateUserOperationGas" | "eth_estimateUserOperationGas" => {
                Some(Method::LocalWalletEstimateUserOperationGas)
            }
            "localwallet_sendUserOperation" | "eth_sendUserOperation" => {
                Some(Method::LocalWalletSendUserOperation)
            }
            "localwallet_getUserOperationReceipt" | "eth_getUserOperationReceipt" => {
                Some(Method::LocalWalletGetUserOperationReceipt)
            }
            "localwallet_getUserOperationGasPrice" | "pimlico_getUserOperationGasPrice" => {
                Some(Method::LocalWalletGetUserOperationGasPrice)
            }
            _ => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Method::WalletHealth => "wallet_health",
            Method::WalletApiVersion => "wallet_apiVersion",
            Method::WalletNetworkStatus => "wallet_networkStatus",
            Method::WalletBundlerStatus => "wallet_bundlerStatus",
            Method::WalletWalletStatus => "wallet_walletStatus",
            Method::WalletPendingOperations => "wallet_pendingOperations",
            Method::WalletAuditStore => "wallet_auditStore",
            Method::WalletAuditHistory => "wallet_auditHistory",
            Method::WalletAuditReport => "wallet_auditReport",
            Method::WalletRepairStore => "wallet_repairStore",
            Method::WalletCancelPendingOperation => "wallet_cancelPendingOperation",
            Method::WalletBeginAdminAction => "wallet_beginAdminAction",
            Method::WalletRotateBundlerEOA => "wallet_rotateBundlerEOA",
            Method::WalletInstallBundlerEOA => "wallet_installBundlerEOA",
            Method::WalletDeleteBundlerEOA => "wallet_deleteBundlerEOA",
            Method::WalletShutdown => "wallet_shutdown",
            Method::EthChainId => "eth_chainId",
            Method::EthGetBalance => "eth_getBalance",
            Method::EthGetCode => "eth_getCode",
            Method::EthGetTransactionCount => "eth_getTransactionCount",
            Method::EthCall => "eth_call",
            Method::EthGetTransactionReceipt => "eth_getTransactionReceipt",
            Method::EthGetBlockByNumber => "eth_getBlockByNumber",
            Method::EthEstimateGas => "eth_estimateGas",
            Method::EthMaxPriorityFeePerGas => "eth_maxPriorityFeePerGas",
            Method::EthGasPrice => "eth_gasPrice",
            Method::LocalWalletSupportedEntryPoints => "localwallet_supportedEntryPoints",
            Method::LocalWalletEstimateUserOperationGas => "localwallet_estimateUserOperationGas",
            Method::LocalWalletSendUserOperation => "localwallet_sendUserOperation",
            Method::LocalWalletGetUserOperationReceipt => "localwallet_getUserOperationReceipt",
            Method::LocalWalletGetUserOperationGasPrice => "localwallet_getUserOperationGasPrice",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_methods() -> Vec<Method> {
        vec![
            Method::WalletHealth,
            Method::WalletApiVersion,
            Method::WalletNetworkStatus,
            Method::WalletBundlerStatus,
            Method::WalletWalletStatus,
            Method::WalletPendingOperations,
            Method::WalletAuditStore,
            Method::WalletAuditHistory,
            Method::WalletAuditReport,
            Method::WalletRepairStore,
            Method::WalletCancelPendingOperation,
            Method::WalletBeginAdminAction,
            Method::WalletRotateBundlerEOA,
            Method::WalletInstallBundlerEOA,
            Method::WalletDeleteBundlerEOA,
            Method::WalletShutdown,
            Method::EthChainId,
            Method::EthGetBalance,
            Method::EthGetCode,
            Method::EthGetTransactionCount,
            Method::EthCall,
            Method::EthGetTransactionReceipt,
            Method::EthGetBlockByNumber,
            Method::EthEstimateGas,
            Method::EthMaxPriorityFeePerGas,
            Method::EthGasPrice,
            Method::LocalWalletSupportedEntryPoints,
            Method::LocalWalletEstimateUserOperationGas,
            Method::LocalWalletSendUserOperation,
            Method::LocalWalletGetUserOperationReceipt,
            Method::LocalWalletGetUserOperationGasPrice,
        ]
    }

    #[test]
    fn all_variants_round_trip_through_wire_name() {
        for method in all_methods() {
            assert_eq!(Method::parse_wire_name(method.as_str()), Some(method));
        }
    }

    #[test]
    fn unknown_method_returns_none() {
        assert_eq!(Method::parse_wire_name("nonsense"), None);
    }

    #[test]
    fn old_eth_names_alias_to_new_localwallet_variants() {
        assert_eq!(
            Method::parse_wire_name("eth_sendUserOperation"),
            Some(Method::LocalWalletSendUserOperation)
        );
        assert_eq!(
            Method::parse_wire_name("eth_estimateUserOperationGas"),
            Some(Method::LocalWalletEstimateUserOperationGas)
        );
        assert_eq!(
            Method::parse_wire_name("eth_getUserOperationReceipt"),
            Some(Method::LocalWalletGetUserOperationReceipt)
        );
        assert_eq!(
            Method::parse_wire_name("eth_supportedEntryPoints"),
            Some(Method::LocalWalletSupportedEntryPoints)
        );
        assert_eq!(
            Method::parse_wire_name("pimlico_getUserOperationGasPrice"),
            Some(Method::LocalWalletGetUserOperationGasPrice)
        );
    }

    #[test]
    fn as_str_returns_new_localwallet_names_only() {
        assert_eq!(
            Method::LocalWalletSendUserOperation.as_str(),
            "localwallet_sendUserOperation"
        );
        assert_eq!(
            Method::LocalWalletEstimateUserOperationGas.as_str(),
            "localwallet_estimateUserOperationGas"
        );
        assert_eq!(
            Method::LocalWalletGetUserOperationReceipt.as_str(),
            "localwallet_getUserOperationReceipt"
        );
        assert_eq!(
            Method::LocalWalletSupportedEntryPoints.as_str(),
            "localwallet_supportedEntryPoints"
        );
        assert_eq!(
            Method::LocalWalletGetUserOperationGasPrice.as_str(),
            "localwallet_getUserOperationGasPrice"
        );
    }
}
