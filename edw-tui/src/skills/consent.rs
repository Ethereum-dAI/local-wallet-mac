//! What the user is asked to agree to before a skill may run, as data the TUI lays out:
//! everything the skill could touch, grouped by chain.

use std::{collections::BTreeSet, fmt};

use super::{lock::Status, manifest::Skill, plan::one_line};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    New,
    Changed,
    MoreHosts,
}

impl Reason {
    pub fn from_status(status: Status) -> Option<Self> {
        match status {
            Status::Trusted => None,
            Status::New => Some(Self::New),
            Status::Changed => Some(Self::Changed),
            Status::MoreHosts => Some(Self::MoreHosts),
        }
    }
}

impl fmt::Display for Reason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::New => "new",
            Self::Changed => "changed since you allowed it",
            Self::MoreHosts => "asks for web hosts you have not allowed",
        })
    }
}

/// One chain's worth of what a skill's plans may do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChainView {
    /// e.g. `Ethereum (1)`.
    pub name: String,
    /// (contract label, full address, allowed function names)
    pub calls: Vec<(String, String, Vec<String>)>,
    /// e.g. `USDC, USDT, DAI → Aave Pool (exact amounts)`
    pub approvals: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConsentRequest {
    pub name: String,
    pub version: String,
    pub short_hash: String,
    pub hash: String,
    pub description: String,
    pub reason: Reason,
    pub requires: Vec<String>,
    pub hosts: Vec<String>,
    pub tools: Vec<String>,
    pub chains: Vec<ChainView>,
}

pub fn chain_name(id: u64) -> String {
    match id {
        1 => "Ethereum (1)".into(),
        11_155_111 => "Sepolia (11155111)".into(),
        31_337 => "Local (31337)".into(),
        other => format!("Chain {other}"),
    }
}

impl ConsentRequest {
    pub fn new(skill: &Skill, hash: &str, reason: Reason) -> Self {
        let m = &skill.manifest;
        let chains: BTreeSet<u64> = m
            .contracts
            .iter()
            .flat_map(|c| c.address.keys().copied())
            .collect();
        let chains = chains
            .into_iter()
            .map(|chain| {
                let calls = m
                    .contracts
                    .iter()
                    .filter_map(|c| {
                        let address = c.address.get(&chain)?;
                        let functions = c.functions.iter().map(|f| f.name.clone()).collect();
                        Some((one_line(&c.label), address.to_string(), functions))
                    })
                    .collect();
                // Which tokens an action may approve, to which of its spenders, on this chain.
                let tokens: Vec<String> = m
                    .tokens
                    .iter()
                    .filter(|t| t.movable && t.address.contains_key(&chain))
                    .map(|t| one_line(&t.symbol))
                    .collect();
                let spenders: BTreeSet<String> = m
                    .actions
                    .iter()
                    .flat_map(|a| a.approves.iter())
                    .filter_map(|id| m.contract(id))
                    .filter(|c| c.address.contains_key(&chain))
                    .map(|c| one_line(&c.label))
                    .collect();
                let approvals = if tokens.is_empty() {
                    Vec::new()
                } else {
                    spenders
                        .into_iter()
                        .map(|s| format!("{} → {s} (exact amounts)", tokens.join(", ")))
                        .collect()
                };
                ChainView {
                    name: chain_name(chain),
                    calls,
                    approvals,
                }
            })
            .collect();
        Self {
            name: skill.name.clone(),
            version: one_line(&m.version),
            short_hash: hash[..hash.len().min(12)].to_owned(),
            hash: hash.to_owned(),
            description: one_line(&skill.description),
            reason,
            requires: m.requires.clone(),
            hosts: m.hosts.clone(),
            tools: skill.tool_names().into_iter().map(str::to_owned).collect(),
            chains,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;
    use crate::skills::{lock::hash_dir, manifest};

    fn aave() -> (Skill, String) {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("skills/aave-v3-lend");
        let skill = manifest::load(&dir).unwrap();
        let hash = hash_dir(&skill.dir).unwrap();
        (skill, hash)
    }

    #[test]
    fn a_request_groups_what_the_skill_can_touch_by_chain() {
        let (skill, hash) = aave();
        let request = ConsentRequest::new(&skill, &hash, Reason::New);
        assert_eq!(request.name, "aave-v3-lend");
        assert_eq!(request.short_hash, &hash[..12]);
        assert_eq!(request.requires, ["defi-data"]);
        assert!(request.hosts.is_empty());
        assert_eq!(
            request.tools,
            ["aave_markets", "aave_supply", "aave_withdraw"]
        );
        let names: Vec<&str> = request.chains.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["Ethereum (1)", "Sepolia (11155111)"]);
        let mainnet = &request.chains[0];
        assert_eq!(
            mainnet.calls,
            [(
                "Aave Pool".to_owned(),
                "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2".to_owned(),
                vec!["supply".to_owned(), "withdraw".to_owned()]
            )]
        );
        assert_eq!(
            mainnet.approvals,
            ["USDC, USDT, DAI → Aave Pool (exact amounts)"]
        );
    }

    #[test]
    fn the_reason_reads_plainly() {
        assert_eq!(Reason::New.to_string(), "new");
        assert_eq!(Reason::Changed.to_string(), "changed since you allowed it");
        assert_eq!(
            Reason::MoreHosts.to_string(),
            "asks for web hosts you have not allowed"
        );
    }

    #[test]
    fn a_skill_without_contracts_says_it_proposes_nothing() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("skills/defi-data");
        let skill = manifest::load(&dir).unwrap();
        let request = ConsentRequest::new(&skill, &hash_dir(&skill.dir).unwrap(), Reason::New);
        assert!(request.chains.is_empty());
        assert_eq!(
            request.hosts,
            [
                "yields.llama.fi",
                "api.geckoterminal.com",
                "api.dexscreener.com"
            ]
        );
    }
}
