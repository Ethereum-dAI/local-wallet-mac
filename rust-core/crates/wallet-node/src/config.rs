#![allow(dead_code)]

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};
use thiserror::Error;

const DEFAULT_EXECUTION_RPC: &str = "https://ethereum-rpc.publicnode.com";
const DEFAULT_CONSENSUS_RPC: &str = "https://lodestar-mainnet.chainsafe.io";
const DEFAULT_ENTRY_POINT: &str = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct NetworkConfig {
    pub chain_id: u64,
    pub execution_rpc: String,
    pub consensus_rpc: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct BundlerConfig {
    pub entry_points: Vec<String>,
    pub submit_rpcs: Vec<String>,
    pub use_precompiled: bool,
    pub beneficiary: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
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
    pub max_request_body_bytes: u64,
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
}

impl Default for NetworkConfig {
    fn default() -> Self {
        Self {
            chain_id: 1,
            execution_rpc: DEFAULT_EXECUTION_RPC.to_owned(),
            consensus_rpc: DEFAULT_CONSENSUS_RPC.to_owned(),
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

impl Default for ChainSection {
    fn default() -> Self {
        Self {
            chain_id: None,
            execution_rpc: None,
            consensus_rpc: None,
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
            max_request_body_bytes: 262_144,
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

        Ok(())
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
    use super::{Config, ConfigError, DEFAULT_CONSENSUS_RPC, DEFAULT_ENTRY_POINT};

    #[test]
    fn parses_complete_config() {
        let config: Config = toml::from_str(
            r#"
[network]
chain_id = 11155111
execution_rpc = "https://example.invalid/execution"
consensus_rpc = "https://example.invalid/consensus"

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
max_request_body_bytes = 4096

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

        assert_eq!(config.network.chain_id, 11155111);
        assert_eq!(
            config.network.execution_rpc,
            "https://example.invalid/execution"
        );
        assert_eq!(
            config.network.consensus_rpc,
            "https://example.invalid/consensus"
        );
        assert_eq!(config.chain_id_for_helios(), 11155111);
        assert_eq!(
            config.execution_rpc_for_helios(),
            "https://example.invalid/execution"
        );
        assert_eq!(
            config.consensus_rpc_for_helios(),
            "https://example.invalid/consensus"
        );
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

        assert_eq!(config.network.chain_id, 1);
        assert_eq!(
            config.network.execution_rpc,
            "https://ethereum-rpc.publicnode.com"
        );
        assert_eq!(config.network.consensus_rpc, DEFAULT_CONSENSUS_RPC);
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
    fn optional_chain_section_overrides_network_for_helios() {
        let config: Config = toml::from_str(
            r#"
[network]
chain_id = 1
execution_rpc = "https://example.invalid/network-execution"
consensus_rpc = "https://example.invalid/network-consensus"

[chain]
chain_id = 11155111
execution_rpc = "https://example.invalid/chain-execution"
consensus_rpc = "https://example.invalid/chain-consensus"
"#,
        )
        .expect("config should parse");

        assert_eq!(config.chain_id_for_helios(), 11155111);
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
    fn default_config_round_trips_through_toml() {
        let original = Config::default();
        let toml = toml::to_string(&original).expect("default config should serialize");
        let parsed: Config = toml::from_str(&toml).expect("serialized config should parse");

        assert_eq!(parsed, original);
    }
}
