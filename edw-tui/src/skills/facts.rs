//! Checks a draft's contract addresses and function signatures against verified source (Sourcify)
//! so a model's invented address or function shows up before the user is asked to allow it.
//! Findings are warnings: Sourcify may be down, and the approval card stays the real gate.

use std::{future::Future, time::Duration};

use alloy_json_abi::JsonAbi;
use alloy_primitives::Address;

use super::manifest::Skill;

pub trait AbiSource {
    /// `Ok(None)`: the contract is not verified there.
    fn abi(
        &self,
        chain_id: u64,
        address: Address,
    ) -> impl Future<Output = Result<Option<JsonAbi>, String>> + Send;
}

pub struct Sourcify {
    client: reqwest::Client,
}

impl Sourcify {
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()
                .unwrap_or_default(),
        }
    }
}

impl Default for Sourcify {
    fn default() -> Self {
        Self::new()
    }
}

impl AbiSource for Sourcify {
    async fn abi(&self, chain_id: u64, address: Address) -> Result<Option<JsonAbi>, String> {
        let url = format!(
            "https://sourcify.dev/server/v2/contract/{chain_id}/{}?fields=abi",
            address.to_checksum(None)
        );
        let response = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| format!("Sourcify unreachable ({e})"))?;
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !response.status().is_success() {
            return Err(format!("Sourcify answered HTTP {}", response.status()));
        }
        let body: serde_json::Value = response
            .json()
            .await
            .map_err(|e| format!("Sourcify sent unreadable JSON ({e})"))?;
        let abi = body
            .get("abi")
            .cloned()
            .ok_or("Sourcify's answer has no abi")?;
        serde_json::from_value(abi)
            .map(Some)
            .map_err(|e| format!("Sourcify's abi did not parse ({e})"))
    }
}

/// One finding per problem: an address with no verified source, a source that cannot be reached,
/// a declared function the verified ABI does not have. Contracts the user names at call time
/// (`address_arg`) have nothing to check.
pub async fn verify(skill: &Skill, source: &impl AbiSource) -> Vec<String> {
    let mut findings = Vec::new();
    for contract in &skill.manifest.contracts {
        for (chain, address) in &contract.address {
            let label = format!("{} ({address}) on chain {chain}", contract.label);
            match source.abi(*chain, *address).await {
                Err(why) => findings.push(format!("could not check {label}: {why}")),
                Ok(None) => findings.push(format!(
                    "{label} has no verified source on Sourcify; confirm the address yourself before allowing the skill"
                )),
                Ok(Some(abi)) => {
                    for function in &contract.functions {
                        let found = abi
                            .functions()
                            .any(|known| known.selector() == function.selector());
                        if !found {
                            findings.push(format!(
                                "{label}: the verified ABI has no `{}` with these parameters (if this is a proxy, the ABI may be the proxy's own)",
                                function.name
                            ));
                        }
                    }
                }
            }
        }
    }
    findings
}

#[cfg(test)]
mod tests {
    use std::{collections::BTreeMap, fs};

    use super::*;
    use crate::skills::manifest;

    struct Fake(BTreeMap<(u64, Address), Result<Option<JsonAbi>, String>>);

    impl AbiSource for Fake {
        async fn abi(&self, chain_id: u64, address: Address) -> Result<Option<JsonAbi>, String> {
            self.0
                .get(&(chain_id, address))
                .cloned()
                .unwrap_or(Ok(None))
        }
    }

    const POOL: &str = "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2";

    fn skill(functions: &str, address_line: &str) -> (tempfile::TempDir, Skill) {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("demo");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            "---\nname: demo\ndescription: Supply to a pool, for testing the facts check.\n---\nbody\n",
        )
        .unwrap();
        fs::write(
            dir.join("skill.toml"),
            format!(
                "version = \"0.1.0\"\n[[contract]]\nid = \"pool\"\nlabel = \"Pool\"\nfunctions = [{functions}]\n{address_line}\n"
            ),
        )
        .unwrap();
        let skill = manifest::load(&dir).unwrap();
        (root, skill)
    }

    fn abi(sigs: &[&str]) -> JsonAbi {
        JsonAbi::parse(sigs.iter().copied()).unwrap()
    }

    #[tokio::test]
    async fn a_matching_verified_contract_has_no_findings() {
        let (_r, skill) = skill(
            r#""function supply(address asset,uint256 amount,address onBehalfOf,uint16 referralCode)""#,
            &format!("address = {{ 1 = \"{POOL}\" }}"),
        );
        let source = Fake(BTreeMap::from([(
            (1, POOL.parse().unwrap()),
            Ok(Some(abi(&[
                "function supply(address,uint256,address,uint16)",
            ]))),
        )]));
        assert_eq!(verify(&skill, &source).await, Vec::<String>::new());
    }

    #[tokio::test]
    async fn a_function_the_verified_abi_lacks_is_named() {
        let (_r, skill) = skill(
            r#""function supplyAll(address asset)""#,
            &format!("address = {{ 1 = \"{POOL}\" }}"),
        );
        let source = Fake(BTreeMap::from([(
            (1, POOL.parse().unwrap()),
            Ok(Some(abi(&[
                "function supply(address,uint256,address,uint16)",
            ]))),
        )]));
        let findings = verify(&skill, &source).await;
        assert_eq!(findings.len(), 1, "{findings:?}");
        assert!(findings[0].contains("supplyAll"), "{findings:?}");
    }

    #[tokio::test]
    async fn an_unverified_address_and_an_unreachable_source_are_findings_not_failures() {
        let (_r, skill) = skill(
            r#""function supply(address asset)""#,
            &format!(
                "address = {{ 1 = \"{POOL}\", 11155111 = \"0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951\" }}"
            ),
        );
        let source = Fake(BTreeMap::from([(
            (
                11155111,
                "0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951"
                    .parse()
                    .unwrap(),
            ),
            Err("Sourcify unreachable".to_owned()),
        )]));
        let findings = verify(&skill, &source).await;
        assert_eq!(findings.len(), 2, "{findings:?}");
        assert!(findings.iter().any(|f| f.contains("no verified source")));
        assert!(findings.iter().any(|f| f.contains("unreachable")));
    }

    #[tokio::test]
    async fn a_contract_with_no_pinned_address_is_skipped() {
        let (_r, skill) = skill(
            r#""function supply(address asset)""#,
            "address_arg = \"safe\"",
        );
        assert!(verify(&skill, &Fake(BTreeMap::new())).await.is_empty());
    }
}
