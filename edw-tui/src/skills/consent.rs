//! What the user is asked to agree to before a skill may run, as data the TUI lays out:
//! everything the skill could touch, grouped by chain.

use std::{collections::BTreeSet, fmt};

use super::{
    lock::Status,
    manifest::{Approval, Skill},
    plan::one_line,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    New,
    Changed,
    MoreHosts,
}

impl Reason {
    pub fn from_status(status: Status) -> Option<Self> {
        match status {
            Status::Trusted | Status::Disabled => None,
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
    /// (contract label, allowed function names): contracts at an address the user names when
    /// they ask, on any chain, such as their own Safe.
    pub named: Vec<(String, Vec<String>)>,
}

/// Function names in manifest order, an overloaded one once.
fn names(functions: &[alloy_json_abi::Function]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    functions
        .iter()
        .filter(|f| seen.insert(f.name.as_str()))
        .map(|f| f.name.clone())
        .collect()
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
                        let functions = names(&c.functions);
                        Some((one_line(&c.label), address.to_string(), functions))
                    })
                    .collect();
                // What an action may grant to each of its spenders on this chain: ERC-20
                // approvals, and credit delegations of debt tokens.
                let spenders: BTreeSet<&str> = m
                    .actions
                    .iter()
                    .flat_map(|a| a.approves.iter().map(String::as_str))
                    .collect();
                let mut approvals = Vec::new();
                for spender in spenders
                    .into_iter()
                    .filter_map(|id| m.contract(id))
                    .filter(|c| c.address.contains_key(&chain))
                {
                    let granted = |delegation: bool| -> Vec<String> {
                        m.tokens
                            .iter()
                            .filter(|t| {
                                t.address.contains_key(&chain)
                                    && t.approval.allows(&spender.id)
                                    && matches!(t.approval, Approval::Delegation { .. })
                                        == delegation
                            })
                            .map(|t| one_line(&t.symbol))
                            .collect()
                    };
                    let label = one_line(&spender.label);
                    let tokens = granted(false);
                    if !tokens.is_empty() {
                        approvals.push(format!("{} → {label} (exact amounts)", tokens.join(", ")));
                    }
                    let debts = granted(true);
                    if !debts.is_empty() {
                        approvals.push(format!(
                            "{} → {label} (credit delegation: it may borrow in your name; exact amounts)",
                            debts.join(", ")
                        ));
                    }
                }
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
            named: m
                .contracts
                .iter()
                .filter(|c| c.address_arg.is_some())
                .map(|c| (one_line(&c.label), names(&c.functions)))
                .collect(),
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
            [
                "aave_markets",
                "aave_account",
                "aave_supply",
                "aave_withdraw",
                "aave_borrow",
                "aave_repay",
                "aave_collateral"
            ]
        );
        let names: Vec<&str> = request.chains.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["Ethereum (1)", "Sepolia (11155111)"]);
        let mainnet = &request.chains[0];
        let strings = |names: &[&str]| names.iter().map(|n| (*n).to_owned()).collect::<Vec<_>>();
        assert_eq!(
            mainnet.calls,
            [
                (
                    "Aave Pool".to_owned(),
                    "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2".to_owned(),
                    strings(&[
                        "supply",
                        "withdraw",
                        "borrow",
                        "repay",
                        "setUserUseReserveAsCollateral"
                    ])
                ),
                (
                    "Aave WETH Gateway".to_owned(),
                    "0xd01607c3C5eCABa394D8be377a08590149325722".to_owned(),
                    strings(&["depositETH", "withdrawETH", "borrowETH", "repayETH"])
                ),
            ]
        );
        assert_eq!(
            mainnet.approvals,
            [
                "aWETH → Aave WETH Gateway (exact amounts)",
                "WETH debt → Aave WETH Gateway (credit delegation: it may borrow in your name; exact amounts)",
                "USDC, USDT, DAI, WETH → Aave Pool (exact amounts)",
            ]
        );
    }

    /// Each spender gets the tokens it may be approved for, and the debt it may take on in the
    /// user's name on its own line, named as credit delegation.
    #[test]
    fn approvals_and_credit_delegations_are_listed_per_spender() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("lend");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("SKILL.md"),
            "---\nname: lend\ndescription: d\n---\nx\n",
        )
        .unwrap();
        let token = |id: &str, symbol: &str, policy: &str, address: &str| {
            format!(
                "[[token]]\nid = \"{id}\"\nsymbol = \"{symbol}\"\ndecimals = 18\n{policy}\naddress = {{ 1 = \"{address}\" }}\n"
            )
        };
        let toml = [
            "version = \"1\"".to_owned(),
            "[[contract]]\nid = \"pool\"\nlabel = \"Pool\"\nfunctions = [\"function noop()\"]\naddress = { 1 = \"0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2\" }".into(),
            "[[contract]]\nid = \"gateway\"\nlabel = \"Gateway\"\nfunctions = [\"function noop()\"]\naddress = { 1 = \"0xd01607c3C5eCABa394D8be377a08590149325722\" }".into(),
            token("weth", "WETH", "approve_to = [\"pool\"]", "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
            token("aweth", "aWETH", "approve_to = [\"gateway\"]", "0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8"),
            token("weth_debt", "WETH debt", "kind = \"debt\"\napprove_to = [\"gateway\"]", "0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE"),
            "[[action]]\nname = \"a\"\nrun = \"a.py\"\ndescription = \"d\"\nschema = { type = \"object\" }\napproves = [\"pool\", \"gateway\"]".into(),
        ]
        .join("\n\n");
        std::fs::write(dir.join("skill.toml"), toml).unwrap();
        let skill = manifest::load(&dir).unwrap();
        let request = ConsentRequest::new(&skill, &"0".repeat(64), Reason::New);
        assert_eq!(
            request.chains[0].approvals,
            [
                "aWETH → Gateway (exact amounts)",
                "WETH debt → Gateway (credit delegation: it may borrow in your name; exact amounts)",
                "WETH → Pool (exact amounts)",
            ]
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
                "api.llama.fi",
                "api.coingecko.com",
                "api.geckoterminal.com",
                "api.dexscreener.com"
            ]
        );
    }
}
