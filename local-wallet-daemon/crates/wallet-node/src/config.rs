#![allow(dead_code)]

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};
use thiserror::Error;

const DEFAULT_EXECUTION_RPC: &str = "https://ethereum-rpc.publicnode.com";
const DEFAULT_CONSENSUS_RPC: &str = "https://lodestar-mainnet.chainsafe.io";
const DEFAULT_ENTRY_POINT: &str = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
pub const MAINNET_CHAIN_ID: u64 = 1;
pub const SEPOLIA_CHAIN_ID: u64 = 11_155_111;

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum NetworkProfile {
    Mainnet,
    Sepolia,
}

impl NetworkProfile {
    pub fn from_chain_id(chain_id: u64) -> Result<Self, ConfigError> {
        match chain_id {
            MAINNET_CHAIN_ID => Ok(Self::Mainnet),
            SEPOLIA_CHAIN_ID => Ok(Self::Sepolia),
            _ => Err(ConfigError::UnsupportedChainId { chain_id }),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mainnet => "mainnet",
            Self::Sepolia => "sepolia",
        }
    }

    pub fn chain_id(self) -> u64 {
        match self {
            Self::Mainnet => MAINNET_CHAIN_ID,
            Self::Sepolia => SEPOLIA_CHAIN_ID,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReadVerificationMode {
    #[default]
    Helios,
    ExecutionRpc,
}

impl ReadVerificationMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Helios => "helios",
            Self::ExecutionRpc => "execution_rpc",
        }
    }

    pub fn verifies_reads(self) -> bool {
        matches!(self, Self::Helios)
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct NetworkConfig {
    pub chain_id: u64,
    pub execution_rpc: String,
    pub consensus_rpc: String,
    pub read_verification: ReadVerificationMode,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct BundlerConfig {
    pub entry_points: Vec<String>,
    pub submit_rpcs: Vec<String>,
    pub use_precompiled: bool,
    pub beneficiary: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct ChainSection {
    pub chain_id: Option<u64>,
    pub execution_rpc: Option<String>,
    pub consensus_rpc: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct RateLimitConfig {
    pub refill_per_sec: f64,
    pub burst: u32,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct PolicyConfig {
    pub max_user_ops_per_bundle: u32,
    pub max_call_gas_limit: String,
    pub max_verification_gas_limit: String,
    pub max_pre_verification_gas: String,
    pub max_fee_per_gas: String,
    pub max_priority_fee_per_gas: String,
    pub min_replacement_bump_pct: f64,
    pub max_relayer_bump_pct: f64,
    pub auto_recovery_max_attempts: u32,
    pub auto_recovery_spend_ceiling_wei: String,
    pub auto_recovery_stuck_age_blocks: u64,
    pub auto_recovery_drop_age_blocks: u64,
    pub max_request_body_bytes: u64,
    pub max_user_ops_per_sender_per_minute: u32,
    pub max_gas_wei_per_sender_per_hour: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct Config {
    pub network: NetworkConfig,
    pub bundler: BundlerConfig,
    #[serde(default)]
    pub chain: ChainSection,
    pub policy: PolicyConfig,
    pub rate_limits: BTreeMap<String, RateLimitConfig>,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error(transparent)]
    Io(#[from] std::io::Error),

    #[error(transparent)]
    Parse(#[from] toml::de::Error),

    #[error("invalid hex value for {field}: {value}")]
    InvalidHex { field: &'static str, value: String },

    #[error("out of range config value for {field}: {reason}")]
    OutOfRange {
        field: &'static str,
        reason: &'static str,
    },

    #[error("unsupported chain id {chain_id}; only Ethereum mainnet (1) and Sepolia (11155111) are supported")]
    UnsupportedChainId { chain_id: u64 },
}

impl Default for NetworkConfig {
    fn default() -> Self {
        Self {
            chain_id: MAINNET_CHAIN_ID,
            execution_rpc: DEFAULT_EXECUTION_RPC.to_owned(),
            consensus_rpc: DEFAULT_CONSENSUS_RPC.to_owned(),
            read_verification: ReadVerificationMode::default(),
        }
    }
}

impl Default for BundlerConfig {
    fn default() -> Self {
        Self {
            entry_points: vec![DEFAULT_ENTRY_POINT.to_owned()],
            submit_rpcs: vec![DEFAULT_EXECUTION_RPC.to_owned()],
            use_precompiled: false,
            beneficiary: None,
        }
    }
}

impl Default for PolicyConfig {
    fn default() -> Self {
        Self {
            max_user_ops_per_bundle: 1,
            max_call_gas_limit: "0x989680".to_owned(),
            max_verification_gas_limit: "0x4c4b40".to_owned(),
            max_pre_verification_gas: "0x0f4240".to_owned(),
            max_fee_per_gas: "0x2540be400".to_owned(),
            max_priority_fee_per_gas: "0x3b9aca00".to_owned(),
            min_replacement_bump_pct: 12.5,
            max_relayer_bump_pct: 100.0,
            auto_recovery_max_attempts: 3,
            auto_recovery_spend_ceiling_wei: "0x0".to_owned(),
            auto_recovery_stuck_age_blocks: 6,
            auto_recovery_drop_age_blocks: 24,
            max_request_body_bytes: 262_144,
            max_user_ops_per_sender_per_minute: 10,
            max_gas_wei_per_sender_per_hour: "0x0".to_owned(),
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            network: NetworkConfig::default(),
            bundler: BundlerConfig::default(),
            chain: ChainSection::default(),
            policy: PolicyConfig::default(),
            rate_limits: default_rate_limits(),
        }
    }
}

impl Config {
    pub fn load(path: &Path) -> Result<Config, ConfigError> {
        if !path.exists() {
            return Ok(Config::default());
        }

        let contents = fs::read_to_string(path)?;
        let config: Config = toml::from_str(&contents)?;
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<(), ConfigError> {
        validate_hex("policy.max_call_gas_limit", &self.policy.max_call_gas_limit)?;
        validate_hex(
            "policy.max_verification_gas_limit",
            &self.policy.max_verification_gas_limit,
        )?;
        validate_hex(
            "policy.max_pre_verification_gas",
            &self.policy.max_pre_verification_gas,
        )?;
        validate_hex("policy.max_fee_per_gas", &self.policy.max_fee_per_gas)?;
        validate_hex(
            "policy.max_priority_fee_per_gas",
            &self.policy.max_priority_fee_per_gas,
        )?;
        validate_hex(
            "policy.max_gas_wei_per_sender_per_hour",
            &self.policy.max_gas_wei_per_sender_per_hour,
        )?;
        validate_hex(
            "policy.auto_recovery_spend_ceiling_wei",
            &self.policy.auto_recovery_spend_ceiling_wei,
        )?;

        if self
            .bundler
            .beneficiary
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty())
        {
            return Err(ConfigError::OutOfRange {
                field: "bundler.beneficiary",
                reason: "beneficiary is implicit and must equal the active bundler EOA",
            });
        }

        if self.policy.max_request_body_bytes < 1024 {
            return Err(ConfigError::OutOfRange {
                field: "policy.max_request_body_bytes",
                reason: "must be at least 1024 bytes",
            });
        }

        if self.policy.min_replacement_bump_pct <= 0.0 {
            return Err(ConfigError::OutOfRange {
                field: "policy.min_replacement_bump_pct",
                reason: "must be greater than 0",
            });
        }
        if self.policy.max_relayer_bump_pct < self.policy.min_replacement_bump_pct {
            return Err(ConfigError::OutOfRange {
                field: "policy.max_relayer_bump_pct",
                reason: "must be >= min_replacement_bump_pct so replacements remain possible",
            });
        }
        if self.policy.auto_recovery_drop_age_blocks < self.policy.auto_recovery_stuck_age_blocks {
            return Err(ConfigError::OutOfRange {
                field: "policy.auto_recovery_drop_age_blocks",
                reason: "must be >= auto_recovery_stuck_age_blocks",
            });
        }

        let profile = NetworkProfile::from_chain_id(self.network.chain_id)?;
        if let Some(chain_id) = self.chain.chain_id {
            NetworkProfile::from_chain_id(chain_id)?;
            if chain_id != profile.chain_id() {
                return Err(ConfigError::OutOfRange {
                    field: "chain.chain_id",
                    reason: "must match network.chain_id for the selected profile",
                });
            }
        }

        Ok(())
    }

    pub fn network_profile(&self) -> NetworkProfile {
        NetworkProfile::from_chain_id(self.network.chain_id)
            .expect("config validation should reject unsupported network.chain_id")
    }

    pub fn chain_id_for_helios(&self) -> u64 {
        self.chain.chain_id.unwrap_or(self.network.chain_id)
    }

    pub fn execution_rpc_for_helios(&self) -> &str {
        self.chain
            .execution_rpc
            .as_deref()
            .unwrap_or(&self.network.execution_rpc)
    }

    pub fn consensus_rpc_for_helios(&self) -> &str {
        self.chain
            .consensus_rpc
            .as_deref()
            .unwrap_or(&self.network.consensus_rpc)
    }

    pub fn read_verification_mode(&self) -> ReadVerificationMode {
        self.network.read_verification
    }
}

fn default_rate_limits() -> BTreeMap<String, RateLimitConfig> {
    BTreeMap::from([
        (
            "eth_sendUserOperation".to_owned(),
            RateLimitConfig {
                refill_per_sec: 0.166,
                burst: 3,
            },
        ),
        (
            "eth_estimateUserOperationGas".to_owned(),
            RateLimitConfig {
                refill_per_sec: 1.0,
                burst: 10,
            },
        ),
        (
            "read_methods_total".to_owned(),
            RateLimitConfig {
                refill_per_sec: 1.66,
                burst: 20,
            },
        ),
    ])
}

fn validate_hex(field: &'static str, value: &str) -> Result<(), ConfigError> {
    u128::from_str_radix(value.trim_start_matches("0x"), 16)
        .map(|_| ())
        .map_err(|_| ConfigError::InvalidHex {
            field,
            value: value.to_owned(),
        })
}

#[cfg(test)]
mod tests {
    use super::{
        Config, ConfigError, NetworkProfile, ReadVerificationMode, DEFAULT_CONSENSUS_RPC,
        DEFAULT_ENTRY_POINT, MAINNET_CHAIN_ID, SEPOLIA_CHAIN_ID,
    };

    #[test]
    fn parses_complete_config() {
        let config: Config = toml::from_str(
            r#"
[network]
chain_id = 11155111
execution_rpc = "https://example.invalid/execution"
consensus_rpc = "https://example.invalid/consensus"
read_verification = "execution_rpc"

[bundler]
entry_points = ["0x1111111111111111111111111111111111111111"]
submit_rpcs = ["https://example.invalid/submit"]
use_precompiled = true
beneficiary = ""

[policy]
max_user_ops_per_bundle = 2
max_call_gas_limit = "0x1"
max_verification_gas_limit = "0x2"
max_pre_verification_gas = "0x3"
max_fee_per_gas = "0x4"
max_priority_fee_per_gas = "0x5"
min_replacement_bump_pct = 15.0
max_relayer_bump_pct = 50.0
auto_recovery_max_attempts = 4
auto_recovery_spend_ceiling_wei = "0x200"
auto_recovery_stuck_age_blocks = 8
auto_recovery_drop_age_blocks = 32
max_request_body_bytes = 4096
max_user_ops_per_sender_per_minute = 7
max_gas_wei_per_sender_per_hour = "0x100"

[rate_limits.eth_sendUserOperation]
refill_per_sec = 0.5
burst = 4

[rate_limits.eth_estimateUserOperationGas]
refill_per_sec = 2.0
burst = 12

[rate_limits.read_methods_total]
refill_per_sec = 3.0
burst = 30
"#,
        )
        .expect("complete config should parse");

        assert_eq!(config.network.chain_id, SEPOLIA_CHAIN_ID);
        assert_eq!(
            config.network.execution_rpc,
            "https://example.invalid/execution"
        );
        assert_eq!(
            config.network.consensus_rpc,
            "https://example.invalid/consensus"
        );
        assert_eq!(config.chain_id_for_helios(), SEPOLIA_CHAIN_ID);
        assert_eq!(config.network_profile(), NetworkProfile::Sepolia);
        assert_eq!(
            config.execution_rpc_for_helios(),
            "https://example.invalid/execution"
        );
        assert_eq!(
            config.consensus_rpc_for_helios(),
            "https://example.invalid/consensus"
        );
        assert_eq!(
            config.read_verification_mode(),
            ReadVerificationMode::ExecutionRpc
        );
        assert!(!config.read_verification_mode().verifies_reads());
        assert_eq!(
            config.bundler.entry_points,
            vec!["0x1111111111111111111111111111111111111111"]
        );
        assert_eq!(
            config.bundler.submit_rpcs,
            vec!["https://example.invalid/submit"]
        );
        assert!(config.bundler.use_precompiled);
        assert_eq!(config.bundler.beneficiary.as_deref(), Some(""));
        assert_eq!(config.policy.max_user_ops_per_bundle, 2);
        assert_eq!(config.policy.max_call_gas_limit, "0x1");
        assert_eq!(config.policy.max_verification_gas_limit, "0x2");
        assert_eq!(config.policy.max_pre_verification_gas, "0x3");
        assert_eq!(config.policy.max_fee_per_gas, "0x4");
        assert_eq!(config.policy.max_priority_fee_per_gas, "0x5");
        assert_eq!(config.policy.min_replacement_bump_pct, 15.0);
        assert_eq!(config.policy.max_relayer_bump_pct, 50.0);
        assert_eq!(config.policy.auto_recovery_max_attempts, 4);
        assert_eq!(config.policy.auto_recovery_spend_ceiling_wei, "0x200");
        assert_eq!(config.policy.auto_recovery_stuck_age_blocks, 8);
        assert_eq!(config.policy.auto_recovery_drop_age_blocks, 32);
        assert_eq!(config.policy.max_user_ops_per_sender_per_minute, 7);
        assert_eq!(config.policy.max_gas_wei_per_sender_per_hour, "0x100");
        assert_eq!(config.policy.max_request_body_bytes, 4096);
        assert_eq!(
            config.rate_limits["eth_sendUserOperation"].refill_per_sec,
            0.5
        );
        assert_eq!(config.rate_limits["eth_sendUserOperation"].burst, 4);
    }

    #[test]
    fn parses_empty_config_with_defaults() {
        let config: Config = toml::from_str("").expect("empty config should parse");

        assert_eq!(config.network.chain_id, MAINNET_CHAIN_ID);
        assert_eq!(config.network_profile(), NetworkProfile::Mainnet);
        assert_eq!(
            config.network.execution_rpc,
            "https://ethereum-rpc.publicnode.com"
        );
        assert_eq!(config.network.consensus_rpc, DEFAULT_CONSENSUS_RPC);
        assert_eq!(
            config.read_verification_mode(),
            ReadVerificationMode::Helios
        );
        assert!(config.read_verification_mode().verifies_reads());
        assert_eq!(config.chain_id_for_helios(), 1);
        assert_eq!(
            config.execution_rpc_for_helios(),
            "https://ethereum-rpc.publicnode.com"
        );
        assert_eq!(config.consensus_rpc_for_helios(), DEFAULT_CONSENSUS_RPC);
        assert_eq!(config.bundler.entry_points, vec![DEFAULT_ENTRY_POINT]);
        assert_eq!(
            config.bundler.submit_rpcs,
            vec!["https://ethereum-rpc.publicnode.com"]
        );
        assert!(!config.bundler.use_precompiled);
        assert_eq!(config.bundler.beneficiary, None);
        assert_eq!(config.policy.max_user_ops_per_bundle, 1);
        assert_eq!(config.policy.max_call_gas_limit, "0x989680");
        assert_eq!(config.policy.max_verification_gas_limit, "0x4c4b40");
        assert_eq!(config.policy.max_pre_verification_gas, "0x0f4240");
        assert_eq!(config.policy.max_fee_per_gas, "0x2540be400");
        assert_eq!(config.policy.max_priority_fee_per_gas, "0x3b9aca00");
        assert_eq!(config.policy.min_replacement_bump_pct, 12.5);
        assert_eq!(config.policy.max_relayer_bump_pct, 100.0);
        assert_eq!(config.policy.auto_recovery_max_attempts, 3);
        assert_eq!(config.policy.auto_recovery_spend_ceiling_wei, "0x0");
        assert_eq!(config.policy.auto_recovery_stuck_age_blocks, 6);
        assert_eq!(config.policy.auto_recovery_drop_age_blocks, 24);
        assert_eq!(config.policy.max_request_body_bytes, 262_144);
        assert_eq!(
            config.rate_limits["eth_sendUserOperation"].refill_per_sec,
            0.166
        );
        assert_eq!(config.rate_limits["eth_sendUserOperation"].burst, 3);
        assert_eq!(
            config.rate_limits["eth_estimateUserOperationGas"].refill_per_sec,
            1.0
        );
        assert_eq!(config.rate_limits["eth_estimateUserOperationGas"].burst, 10);
        assert_eq!(
            config.rate_limits["read_methods_total"].refill_per_sec,
            1.66
        );
        assert_eq!(config.rate_limits["read_methods_total"].burst, 20);
    }

    #[test]
    fn rejects_bad_policy_hex() {
        let config: Config = toml::from_str(
            r#"
[policy]
max_call_gas_limit = "not-hex"
"#,
        )
        .expect("config should parse before semantic validation");

        assert!(matches!(
            config.validate(),
            Err(ConfigError::InvalidHex {
                field: "policy.max_call_gas_limit",
                value
            }) if value == "not-hex"
        ));
    }

    #[test]
    fn rejects_invalid_auto_recovery_spend_ceiling() {
        let mut config = Config::default();
        config.policy.auto_recovery_spend_ceiling_wei = "0xzz".to_owned();

        assert!(matches!(
            config.validate(),
            Err(ConfigError::InvalidHex {
                field: "policy.auto_recovery_spend_ceiling_wei",
                ..
            })
        ));
    }

    #[test]
    fn rejects_drop_age_below_stuck_age() {
        let mut config = Config::default();
        config.policy.auto_recovery_stuck_age_blocks = 24;
        config.policy.auto_recovery_drop_age_blocks = 6;

        assert!(matches!(
            config.validate(),
            Err(ConfigError::OutOfRange {
                field: "policy.auto_recovery_drop_age_blocks",
                ..
            })
        ));
    }

    #[test]
    fn rejects_zero_max_request_body_bytes() {
        let config: Config = toml::from_str(
            r#"
[policy]
max_request_body_bytes = 0
"#,
        )
        .expect("config should parse before semantic validation");

        assert!(matches!(
            config.validate(),
            Err(ConfigError::OutOfRange {
                field: "policy.max_request_body_bytes",
                ..
            })
        ));
    }

    #[test]
    fn rejects_relayer_bump_budget_below_min_bump() {
        let config: Config = toml::from_str(
            r#"
[policy]
min_replacement_bump_pct = 20.0
max_relayer_bump_pct = 10.0
"#,
        )
        .expect("config should parse before semantic validation");

        assert!(matches!(
            config.validate(),
            Err(ConfigError::OutOfRange {
                field: "policy.max_relayer_bump_pct",
                ..
            })
        ));
    }

    #[test]
    fn rejects_bundler_beneficiary_override() {
        let config: Config = toml::from_str(
            r#"
[bundler]
beneficiary = "0x1111111111111111111111111111111111111111"
"#,
        )
        .expect("config should parse before semantic validation");

        assert!(matches!(
            config.validate(),
            Err(ConfigError::OutOfRange {
                field: "bundler.beneficiary",
                ..
            })
        ));
    }

    #[test]
    fn rejects_unsupported_network_chain_id() {
        let config: Config = toml::from_str(
            r#"
[network]
chain_id = 8453
"#,
        )
        .expect("config should parse before semantic validation");

        assert!(matches!(
            config.validate(),
            Err(ConfigError::UnsupportedChainId { chain_id }) if chain_id == 8453
        ));
    }

    #[test]
    fn accepts_mainnet_and_sepolia_chain_ids_only() {
        let mainnet: Config = toml::from_str(
            r#"
[network]
chain_id = 1
"#,
        )
        .expect("mainnet config should parse");
        mainnet.validate().expect("mainnet should be supported");
        assert_eq!(mainnet.network_profile(), NetworkProfile::Mainnet);

        let sepolia: Config = toml::from_str(
            r#"
[network]
chain_id = 11155111
execution_rpc = "https://example.invalid/sepolia-execution"
consensus_rpc = "https://example.invalid/sepolia-consensus"
"#,
        )
        .expect("sepolia config should parse");
        sepolia.validate().expect("sepolia should be supported");
        assert_eq!(sepolia.network_profile(), NetworkProfile::Sepolia);
    }

    #[test]
    fn optional_chain_section_can_override_rpc_but_not_chain_profile() {
        let config: Config = toml::from_str(
            r#"
[network]
chain_id = 1
execution_rpc = "https://example.invalid/network-execution"
consensus_rpc = "https://example.invalid/network-consensus"

[chain]
chain_id = 1
execution_rpc = "https://example.invalid/chain-execution"
consensus_rpc = "https://example.invalid/chain-consensus"
"#,
        )
        .expect("config should parse");

        config
            .validate()
            .expect("matching chain override should validate");
        assert_eq!(config.chain_id_for_helios(), MAINNET_CHAIN_ID);
        assert_eq!(
            config.execution_rpc_for_helios(),
            "https://example.invalid/chain-execution"
        );
        assert_eq!(
            config.consensus_rpc_for_helios(),
            "https://example.invalid/chain-consensus"
        );
    }

    #[test]
    fn rejects_chain_section_that_changes_network_profile() {
        let config: Config = toml::from_str(
            r#"
[network]
chain_id = 1

[chain]
chain_id = 11155111
"#,
        )
        .expect("config should parse before semantic validation");

        assert!(matches!(
            config.validate(),
            Err(ConfigError::OutOfRange {
                field: "chain.chain_id",
                ..
            })
        ));
    }

    #[test]
    fn default_config_round_trips_through_toml() {
        let original = Config::default();
        let toml = toml::to_string(&original).expect("default config should serialize");
        let parsed: Config = toml::from_str(&toml).expect("serialized config should parse");

        assert_eq!(parsed, original);
    }
}
