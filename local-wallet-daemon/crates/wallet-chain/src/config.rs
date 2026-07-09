use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChainConfig {
    pub chain_id: u64,
    pub execution_rpc: String,
    pub consensus_rpc: String,
    pub data_dir: PathBuf,
    pub max_helios_lag_blocks: u64,
}

impl Default for ChainConfig {
    fn default() -> Self {
        Self {
            chain_id: 1,
            execution_rpc: "https://ethereum-rpc.publicnode.com".into(),
            consensus_rpc: "https://ethereum.operationsolarstorm.org".into(),
            data_dir: PathBuf::from("helios"),
            max_helios_lag_blocks: 8,
        }
    }
}
