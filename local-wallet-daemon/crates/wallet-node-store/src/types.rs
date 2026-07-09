use crate::StoreError;

pub const DEFAULT_OWNER_SCOPE: &str = "default";

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DaemonMetaEntry {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct BundlerAccount {
    pub owner_scope: String,
    pub chain_id: u64,
    pub address: String,
    pub key_ref: String,
    pub lifecycle: BundlerLifecycle,
    pub created_at: i64,
    pub activated_at: Option<i64>,
    pub retired_at: Option<i64>,
    pub deleted_at: Option<i64>,
    pub last_used_at: Option<i64>,
    pub last_exported_at: Option<i64>,
    pub compromise_status: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct NonceReservation {
    pub chain_id: u64,
    pub bundler_address: String,
    pub nonce: u64,
    pub status: NonceStatus,
    pub user_op_hash: Option<String>,
    pub tx_hash: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct UserOperation {
    pub user_op_hash: String,
    pub chain_id: u64,
    pub entry_point: String,
    pub sender: String,
    pub nonce: String,
    pub user_op_json: String,
    pub status: UserOpStatus,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SubmittedTransaction {
    pub tx_hash: String,
    pub user_op_hash: String,
    pub chain_id: u64,
    pub bundler_address: String,
    pub nonce: u64,
    pub raw_tx: String,
    pub max_fee_per_gas: String,
    pub max_priority_fee_per_gas: String,
    pub status: SubmittedTxStatus,
    pub replacement_of: Option<String>,
    pub submitted_at_block: Option<u64>,
    pub recovery_attempts: u32,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct AbandonedSubmission {
    pub tx_hash: String,
    pub nonce: u64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct UserOperationReceipt {
    pub user_op_hash: String,
    pub tx_hash: String,
    pub success: bool,
    pub actual_gas_cost: Option<String>,
    pub actual_gas_used: Option<String>,
    pub revert_reason: Option<String>,
    pub receipt_json: String,
    pub tentative: bool,
    pub invalidated: bool,
    pub created_at: i64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RelayerKeyAuditEvent {
    pub id: Option<i64>,
    pub event_type: String,
    pub owner_scope: String,
    pub chain_id: u64,
    pub key_ref: Option<String>,
    pub address: Option<String>,
    pub previous_lifecycle: Option<String>,
    pub new_lifecycle: Option<String>,
    pub admin_action_id: Option<String>,
    pub result: String,
    pub failure_reason: Option<String>,
    pub created_at: i64,
}

macro_rules! status_enum {
    (
        $name:ident, $table:literal, {
            $($variant:ident => $value:literal),+ $(,)?
        }
    ) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
        #[serde(rename_all = "snake_case")]
        pub enum $name {
            $($variant),+
        }

        impl $name {
            pub fn as_str(&self) -> &'static str {
                match self {
                    $(Self::$variant => $value),+
                }
            }

            pub fn from_str(s: &str, table: &'static str) -> Result<Self, StoreError> {
                match s {
                    $($value => Ok(Self::$variant),)+
                    value => Err(StoreError::InvalidStatus {
                        table,
                        value: value.to_owned(),
                    }),
                }
            }
        }
    };
}

status_enum!(NonceStatus, "nonce_reservations", {
    Reserved => "reserved",
    Submitted => "submitted",
    Included => "included",
    Failed => "failed",
    Replaced => "replaced",
    Abandoned => "abandoned",
});

status_enum!(UserOpStatus, "user_operations", {
    Received => "received",
    Simulated => "simulated",
    Submitted => "submitted",
    Included => "included",
    Reverted => "reverted",
    Failed => "failed",
    Pending => "pending",
});

status_enum!(SubmittedTxStatus, "submitted_transactions", {
    Submitting => "submitting",
    Submitted => "submitted",
    Included => "included",
    Dropped => "dropped",
    Replaced => "replaced",
    Abandoned => "abandoned",
    Failed => "failed",
});

status_enum!(BundlerLifecycle, "bundler_accounts", {
    Active => "active",
    PendingFunding => "pending_funding",
    Retiring => "retiring",
    Retired => "retired",
    Deleted => "deleted",
});

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_round_trip<T>(
        value: T,
        table: &'static str,
        as_str: fn(&T) -> &'static str,
        from_str: fn(&str, &'static str) -> Result<T, StoreError>,
    ) where
        T: Copy + std::fmt::Debug + PartialEq + serde::Serialize + for<'de> serde::Deserialize<'de>,
    {
        let status = as_str(&value);
        assert_eq!(from_str(status, table).unwrap(), value);

        let json = serde_json::to_string(&value).unwrap();
        let decoded: T = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, value);
    }

    #[test]
    fn nonce_status_round_trip() {
        for value in [
            NonceStatus::Reserved,
            NonceStatus::Submitted,
            NonceStatus::Included,
            NonceStatus::Failed,
            NonceStatus::Replaced,
            NonceStatus::Abandoned,
        ] {
            assert_round_trip(
                value,
                "nonce_reservations",
                NonceStatus::as_str,
                NonceStatus::from_str,
            );
        }
    }

    #[test]
    fn user_op_status_round_trip() {
        for value in [
            UserOpStatus::Received,
            UserOpStatus::Simulated,
            UserOpStatus::Submitted,
            UserOpStatus::Included,
            UserOpStatus::Reverted,
            UserOpStatus::Failed,
            UserOpStatus::Pending,
        ] {
            assert_round_trip(
                value,
                "user_operations",
                UserOpStatus::as_str,
                UserOpStatus::from_str,
            );
        }
    }

    #[test]
    fn submitted_tx_status_round_trip() {
        for value in [
            SubmittedTxStatus::Submitting,
            SubmittedTxStatus::Submitted,
            SubmittedTxStatus::Included,
            SubmittedTxStatus::Dropped,
            SubmittedTxStatus::Replaced,
            SubmittedTxStatus::Abandoned,
            SubmittedTxStatus::Failed,
        ] {
            assert_round_trip(
                value,
                "submitted_transactions",
                SubmittedTxStatus::as_str,
                SubmittedTxStatus::from_str,
            );
        }
    }

    #[test]
    fn bundler_lifecycle_round_trip() {
        for value in [
            BundlerLifecycle::Active,
            BundlerLifecycle::PendingFunding,
            BundlerLifecycle::Retiring,
            BundlerLifecycle::Retired,
            BundlerLifecycle::Deleted,
        ] {
            assert_round_trip(
                value,
                "bundler_accounts",
                BundlerLifecycle::as_str,
                BundlerLifecycle::from_str,
            );
        }
    }
}
