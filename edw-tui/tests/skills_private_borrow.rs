//! The shipped `private-aave-borrow` skill: what its manifest lets a plan do, offline.

use std::path::Path;

use edw_core::vault::tornadocash::{resolve_asset, token_address};
use edw_tui::skills::{
    author,
    manifest::{self, Approval, RunsFrom, Skill},
};

const SEPOLIA: u64 = 11_155_111;

fn load(name: &str) -> Skill {
    manifest::load(
        &Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("skills")
            .join(name),
    )
    .unwrap()
}

#[test]
fn it_pins_aave_v3_lends_sepolia_addresses_and_the_tornado_dai() {
    let (skill, aave) = (load("private-aave-borrow"), load("aave-v3-lend"));
    assert_eq!(skill.manifest.requires, ["aave-v3-lend"]);
    for id in ["pool", "gateway"] {
        let pinned = &skill.manifest.contract(id).unwrap().address;
        assert_eq!(pinned.keys().collect::<Vec<_>>(), [&SEPOLIA], "{id}");
        assert_eq!(
            pinned[&SEPOLIA],
            aave.manifest.contract(id).unwrap().address[&SEPOLIA],
            "{id}"
        );
    }
    for id in ["dai", "weth"] {
        let token = skill.manifest.token(id).unwrap();
        assert_eq!(token.approval, Approval::Never, "{id}");
        assert_eq!(
            token.address[&SEPOLIA],
            aave.manifest.token(id).unwrap().address[&SEPOLIA],
            "{id}"
        );
    }
    let tornado_dai = token_address(&resolve_asset("DAI", SEPOLIA).unwrap()).unwrap();
    assert_eq!(
        skill.manifest.token("dai").unwrap().address[&SEPOLIA],
        tornado_dai
    );
}

#[test]
fn its_one_action_runs_from_the_fresh_account_and_approves_nothing() {
    let skill = load("private-aave-borrow");
    let [action] = skill.manifest.actions.as_slice() else {
        panic!("one action");
    };
    assert_eq!(action.tool.name, "private_aave_borrow");
    assert_eq!(action.account, RunsFrom::Fresh);
    assert!(action.approves.is_empty());
    let functions: Vec<String> = skill
        .manifest
        .contracts
        .iter()
        .flat_map(|c| c.functions.iter().map(|f| format!("{}.{}", c.id, f.name)))
        .collect();
    assert_eq!(functions, ["pool.borrow", "gateway.depositETH"]);
    let report = author::check(&skill.dir);
    assert!(report.errors.is_empty(), "{:?}", report.errors);
}
