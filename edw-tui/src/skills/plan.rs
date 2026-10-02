//! A skill action's Plan, checked against its manifest and compiled to calldata.
//!
//! The checker is the reason a skill cannot do more than the user agreed to: every call goes
//! to a pinned contract and an allowed function on this chain, every address argument is the
//! sender or a manifest id (never a raw address the script made up), approvals are exact,
//! never unlimited, and only to the action's declared spenders.

use alloy_dyn_abi::{DynSolType, JsonAbiExt, Specifier};
use alloy_json_abi::{Function, StateMutability};
use alloy_primitives::{Address, Bytes, U256};
use alloy_sol_types::{SolCall, sol};
use serde_json::Value;

use super::{
    abi,
    manifest::{ActionDef, Skill},
};
use crate::interim::guards::{format_units, is_burn};

pub const MAX_STEPS: usize = 6;
/// What a script writes for the sending profile.
pub const SELF: &str = "$self";

sol! {
    function approve(address spender, uint256 amount) returns (bool);
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CheckedStep {
    /// Written here from the manifest and the ABI, never by the skill.
    pub label: String,
    pub to: Address,
    pub value: U256,
    pub data: Bytes,
    /// `(token, amount)` for an approval, so the caller can check the balance covers it.
    pub approval: Option<(Address, U256)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CheckedPlan {
    pub steps: Vec<CheckedStep>,
    pub total_value: U256,
}

/// Checks `plan` (`{"steps": [...]}`) for `action` of `skill` on `chain_id`, sent by `me`.
/// The error names the rule that failed; nothing is partially accepted.
pub fn check(
    plan: &Value,
    skill: &Skill,
    action: &ActionDef,
    chain_id: u64,
    me: Address,
) -> Result<CheckedPlan, String> {
    let steps = plan
        .get("steps")
        .and_then(Value::as_array)
        .ok_or("the plan has no `steps` list")?;
    if steps.is_empty() {
        return Err("the plan has no steps".into());
    }
    if steps.len() > MAX_STEPS {
        return Err(format!(
            "the plan has {} steps; at most 6 are allowed",
            steps.len()
        ));
    }
    let ctx = Ctx {
        skill,
        chain_id,
        me,
    };
    let mut checked = Vec::new();
    let mut total_value = U256::ZERO;
    for (index, step) in steps.iter().enumerate() {
        let n = index + 1;
        let step = if let Some(approval) = step.get("approve") {
            ctx.approve(approval, action)
        } else if let Some(call) = step.get("call") {
            ctx.call(call)
        } else {
            Err("each step must be an approve or call".into())
        }
        .map_err(|e| format!("step {n}: {e}"))?;
        total_value = total_value
            .checked_add(step.value)
            .ok_or_else(|| format!("step {n}: the total value overflows"))?;
        checked.push(step);
    }
    Ok(CheckedPlan {
        steps: checked,
        total_value,
    })
}

struct Ctx<'a> {
    skill: &'a Skill,
    chain_id: u64,
    me: Address,
}

/// Only digits (and a leading `-` for signed types): what the review shows is then exactly the
/// number encoded. alloy's own parser would also take `1ether`, `1e6` or hex.
fn plain_decimal(value: &Value, signed: bool) -> Result<Value, String> {
    let ok = match value {
        Value::Number(n) => n.is_u64() || (signed && n.is_i64()),
        Value::String(s) => {
            let digits = if signed {
                s.strip_prefix('-').unwrap_or(s)
            } else {
                s
            };
            !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit())
        }
        _ => false,
    };
    if ok {
        Ok(value.clone())
    } else {
        Err(format!("`{value}` is not a plain decimal integer"))
    }
}

/// One review line: control characters (newlines, terminal escapes) are shown escaped, so no
/// text from a script or manifest can add or rewrite lines of the review.
pub fn one_line(text: &str) -> String {
    text.chars()
        .flat_map(|c| {
            if c.is_control() {
                c.escape_default().collect::<Vec<_>>()
            } else {
                vec![c]
            }
        })
        .collect()
}

fn text<'a>(step: &'a Value, key: &str) -> Result<&'a str, String> {
    step.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing `{key}`"))
}

/// A non-negative integer given as a decimal string (or a small JSON number).
fn uint(value: Option<&Value>) -> Result<U256, String> {
    let text = match value {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) if n.is_u64() => n.to_string(),
        Some(other) => return Err(format!("`{other}` is not an amount in base units")),
        None => return Err("missing `amount`".into()),
    };
    text.parse::<U256>()
        .ok()
        .filter(|_| !text.is_empty() && text.chars().all(|c| c.is_ascii_digit()))
        .ok_or_else(|| format!("`{text}` is not an amount in base units"))
}

impl Ctx<'_> {
    fn approve(&self, step: &Value, action: &ActionDef) -> Result<CheckedStep, String> {
        let m = &self.skill.manifest;
        let token_id = text(step, "token")?;
        let token = m
            .token(token_id)
            .ok_or_else(|| format!("`{token_id}` is not a token of this skill"))?;
        if !token.movable {
            return Err(format!("{} may not be approved by a plan", token.symbol));
        }
        let token_address = self.on_chain(token_id, token.address.get(&self.chain_id))?;
        let spender_id = text(step, "spender")?;
        if !action.approves.iter().any(|s| s == spender_id) {
            return Err(format!(
                "{} may not approve `{spender_id}` (allowed: {})",
                action.tool.name,
                action.approves.join(", ")
            ));
        }
        let spender = m
            .contract(spender_id)
            .ok_or_else(|| format!("`{spender_id}` is not a contract of this skill"))?;
        let spender_address = self.on_chain(spender_id, spender.address.get(&self.chain_id))?;
        let amount = uint(step.get("amount"))?;
        if amount == U256::MAX {
            return Err("an unlimited approval is never allowed; approve the exact amount".into());
        }
        Ok(CheckedStep {
            label: format!(
                "approve {} {} for {}",
                format_units(amount, token.decimals),
                token.symbol,
                spender.label
            ),
            to: token_address,
            value: U256::ZERO,
            data: approveCall {
                spender: spender_address,
                amount,
            }
            .abi_encode()
            .into(),
            approval: Some((token_address, amount)),
        })
    }

    fn on_chain(&self, id: &str, address: Option<&Address>) -> Result<Address, String> {
        address
            .copied()
            .ok_or_else(|| format!("`{id}` has no address on chain {}", self.chain_id))
    }

    fn address_of(&self, text: &str) -> Result<Address, String> {
        if text == SELF {
            return Ok(self.me);
        }
        if text.starts_with("0x") {
            return Err(format!(
                "{text} is a raw address; plans may only use `$self` or a manifest id"
            ));
        }
        let m = &self.skill.manifest;
        if let Some(c) = m.contract(text) {
            return self.on_chain(text, c.address.get(&self.chain_id));
        }
        if let Some(t) = m.token(text) {
            return self.on_chain(text, t.address.get(&self.chain_id));
        }
        Err(format!(
            "`{text}` is neither `$self` nor an id in this skill's manifest"
        ))
    }

    fn call(&self, step: &Value) -> Result<CheckedStep, String> {
        let m = &self.skill.manifest;
        let contract_id = text(step, "contract")?;
        let contract = m
            .contract(contract_id)
            .ok_or_else(|| format!("`{contract_id}` is not a contract of this skill"))?;
        let to = self.on_chain(contract_id, contract.address.get(&self.chain_id))?;
        let name = text(step, "function")?;
        let args = match step.get("args") {
            None => Vec::new(),
            Some(Value::Array(args)) => args.clone(),
            Some(_) => return Err("`args` must be a list".into()),
        };
        let function: &Function = contract
            .functions
            .iter()
            .find(|f| f.name == name && f.inputs.len() == args.len())
            .or_else(|| contract.functions.iter().find(|f| f.name == name))
            .ok_or_else(|| {
                format!(
                    "{name} is not one of {}'s allowed functions",
                    contract.label
                )
            })?;
        if function.inputs.len() != args.len() {
            return Err(format!(
                "{name} takes {} arguments, got {}",
                function.inputs.len(),
                args.len()
            ));
        }
        let mut values = Vec::new();
        let mut shown = Vec::new();
        for (param, arg) in function.inputs.iter().zip(&args) {
            let ty = param.resolve().map_err(|e| format!("{}: {e}", param.ty))?;
            let label = if param.name.is_empty() {
                param.ty.clone()
            } else {
                param.name.clone()
            };
            let resolved = self
                .addresses(&ty, arg)
                .map_err(|e| format!("{name}({label}): {e}"))?;
            let value = abi::coerce(&ty, &resolved).map_err(|e| format!("{name}({label}): {e}"))?;
            shown.push(format!("{label}={}", self.show(&ty, arg)));
            values.push(value);
        }
        let value = match step.get("value") {
            None => U256::ZERO,
            some => uint(some)?,
        };
        if !value.is_zero() && function.state_mutability != StateMutability::Payable {
            return Err(format!("{name} is not payable, so it cannot take a value"));
        }
        let data = function
            .abi_encode_input(&values)
            .map_err(|e| format!("{name}: {e}"))?;
        let mut label = one_line(&format!("{}.{name}({})", contract.label, shown.join(", ")));
        if !value.is_zero() {
            label.push_str(&format!(" with {} ETH", format_units(value, 18)));
        }
        Ok(CheckedStep {
            label,
            to,
            value,
            data: data.into(),
            approval: None,
        })
    }

    /// The same JSON with every address-typed value resolved: `$self` to the sender, a manifest
    /// id to its address on this chain. A raw 0x address is refused, so a script can never slip
    /// in a recipient the user did not agree to.
    fn addresses(&self, ty: &DynSolType, value: &Value) -> Result<Value, String> {
        let list = || {
            value
                .as_array()
                .ok_or_else(|| format!("expected a list for {ty}"))
        };
        match ty {
            DynSolType::Address => {
                let text = value
                    .as_str()
                    .ok_or_else(|| format!("expected `$self` or a manifest id, got {value}"))?;
                let address = self.address_of(text)?;
                if is_burn(&address) {
                    return Err(format!("{text} is a burn or zero address"));
                }
                Ok(Value::String(address.to_string()))
            }
            DynSolType::Tuple(types) => Ok(Value::Array(
                types
                    .iter()
                    .zip(list()?)
                    .map(|(t, v)| self.addresses(t, v))
                    .collect::<Result<_, _>>()?,
            )),
            DynSolType::Array(inner) | DynSolType::FixedArray(inner, _) => Ok(Value::Array(
                list()?
                    .iter()
                    .map(|v| self.addresses(inner, v))
                    .collect::<Result<_, _>>()?,
            )),
            DynSolType::Uint(_) => plain_decimal(value, false),
            DynSolType::Int(_) => plain_decimal(value, true),
            _ if value.as_str() == Some(SELF) => {
                Err(format!("`$self` stands for an address, but this is a {ty}"))
            }
            _ => Ok(value.clone()),
        }
    }

    /// How an argument reads in the review: ids by name, the sender as "you", the maximum
    /// uint as "all".
    fn show(&self, ty: &DynSolType, value: &Value) -> String {
        let m = &self.skill.manifest;
        match (ty, value.as_str()) {
            (DynSolType::Address, Some(SELF)) => "you".into(),
            (DynSolType::Address, Some(id)) => m
                .token(id)
                .map(|t| t.symbol.clone())
                .or_else(|| m.contract(id).map(|c| c.label.clone()))
                .unwrap_or_else(|| id.to_owned()),
            (DynSolType::Uint(_), Some(text)) if text == U256::MAX.to_string() => "all".into(),
            (DynSolType::String, Some(text)) => format!("{text:?}"),
            (_, Some(text)) => one_line(text),
            _ => value.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use alloy_primitives::address;
    use alloy_sol_types::{SolCall, sol};
    use serde_json::json;

    use super::*;
    use crate::skills::manifest;

    sol! {
        function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode);
        function withdraw(address asset, uint256 amount, address to) returns (uint256);
        function approve(address spender, uint256 amount) returns (bool);
    }

    const ME: Address = address!("0x00000000000000000000000000000000000000A1");
    const POOL: Address = address!("0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951");
    const USDC: Address = address!("0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8");
    const SEPOLIA: u64 = 11_155_111;

    fn skill() -> (tempfile::TempDir, Skill) {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("lend");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            "---\nname: lend\ndescription: Lend.\n---\nx\n",
        )
        .unwrap();
        fs::write(
            dir.join("skill.toml"),
            r#"version = "1"
[[contract]]
id = "pool"
label = "Aave Pool"
functions = [
  "function supply(address asset,uint256 amount,address onBehalfOf,uint16 referralCode)",
  "function withdraw(address asset,uint256 amount,address to) returns (uint256)",
  "function deposit() payable",
  "function setNote(string memo, bytes data, int256 delta)",
]
address = { 11155111 = "0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951" }

[[contract]]
id = "other"
functions = ["function noop()"]
address = { 11155111 = "0x00000000000000000000000000000000000000B2" }

[[token]]
id = "usdc"
symbol = "USDC"
decimals = 6
address = { 11155111 = "0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8" }

[[token]]
id = "ausdc"
symbol = "aUSDC"
decimals = 6
movable = false
address = { 11155111 = "0x16dA4541aD1807f4443d92D26044C1147406EB80" }

[[action]]
name = "supply_it"
run = "s.py"
description = "d"
schema = { type = "object" }
approves = ["pool"]
"#,
        )
        .unwrap();
        let skill = manifest::load(&dir).unwrap();
        (root, skill)
    }

    fn run(plan: Value) -> Result<CheckedPlan, String> {
        let (_root, skill) = skill();
        let action = skill.action("supply_it").unwrap().clone();
        check(&plan, &skill, &action, SEPOLIA, ME)
    }

    fn approve(amount: &str) -> Value {
        json!({"approve": {"token": "usdc", "spender": "pool", "amount": amount}})
    }

    fn supply(args: Value) -> Value {
        json!({"call": {"contract": "pool", "function": "supply", "args": args}})
    }

    fn refused(plan: Value, needle: &str) {
        let error = run(plan)
            .err()
            .unwrap_or_else(|| panic!("expected a refusal naming `{needle}`"));
        assert!(
            error.contains(needle),
            "`{error}` should mention `{needle}`"
        );
    }

    #[test]
    fn an_approve_and_supply_plan_compiles_to_exact_calldata() {
        let plan = run(json!({"steps": [
            approve("100000000"),
            supply(json!(["usdc", "100000000", "$self", "0"])),
        ]}))
        .unwrap();
        assert_eq!(plan.steps.len(), 2);
        assert_eq!(plan.total_value, U256::ZERO);

        let a = &plan.steps[0];
        assert_eq!(a.to, USDC);
        assert_eq!(
            a.data,
            Bytes::from(
                approveCall {
                    spender: POOL,
                    amount: U256::from(100_000_000u64)
                }
                .abi_encode()
            )
        );
        assert_eq!(a.approval, Some((USDC, U256::from(100_000_000u64))));
        assert_eq!(a.label, "approve 100 USDC for Aave Pool");

        let s = &plan.steps[1];
        assert_eq!(s.to, POOL);
        assert_eq!(
            s.data,
            Bytes::from(
                supplyCall {
                    asset: USDC,
                    amount: U256::from(100_000_000u64),
                    onBehalfOf: ME,
                    referralCode: 0,
                }
                .abi_encode()
            )
        );
        assert_eq!(
            s.label,
            "Aave Pool.supply(asset=USDC, amount=100000000, onBehalfOf=you, referralCode=0)"
        );
        assert!(s.approval.is_none());
    }

    #[test]
    fn withdraw_all_may_use_the_maximum_and_zero_approvals_are_allowed() {
        let plan = run(json!({"steps": [
            approve("0"),
            {"call": {"contract": "pool", "function": "withdraw", "args": ["usdc", U256::MAX.to_string(), "$self"]}},
        ]}))
        .unwrap();
        assert!(plan.steps[1].label.contains("amount=all"));
        assert_eq!(
            plan.steps[1].data,
            Bytes::from(
                withdrawCall {
                    asset: USDC,
                    amount: U256::MAX,
                    to: ME
                }
                .abi_encode()
            )
        );
    }

    #[test]
    fn value_goes_only_to_payable_functions_and_is_summed() {
        let plan = run(json!({"steps": [
            {"call": {"contract": "pool", "function": "deposit", "args": [], "value": "5"}},
            {"call": {"contract": "pool", "function": "deposit", "args": [], "value": "7"}},
        ]}))
        .unwrap();
        assert_eq!(plan.total_value, U256::from(12u8));
        refused(
            json!({"steps": [{"call": {"contract": "pool", "function": "supply", "args": ["usdc", "1", "$self", "0"], "value": "1"}}]}),
            "payable",
        );
    }

    #[test]
    fn every_rule_refuses_its_plan() {
        let one = |step: Value| json!({ "steps": [step] });
        refused(json!({"steps": []}), "no steps");
        refused(json!({ "steps": vec![approve("1"); 7] }), "at most 6");
        refused(json!({"nope": 1}), "steps");
        refused(
            one(json!({"call": {"contract": "router", "function": "supply", "args": []}})),
            "router",
        );
        refused(
            one(json!({"call": {"contract": "pool", "function": "flashLoan", "args": []}})),
            "flashLoan",
        );
        refused(one(supply(json!(["usdc", "1", "$self"]))), "4 arguments");
        refused(one(supply(json!(["usdc", "lots", "$self", "0"]))), "lots");
        refused(
            one(supply(json!([
                "usdc",
                "1",
                "0x00000000000000000000000000000000000000E1",
                "0"
            ]))),
            "raw address",
        );
        refused(
            one(supply(json!(["usdc", "1", "attacker", "0"]))),
            "attacker",
        );
        refused(one(supply(json!(["usdc", "$self", "$self", "0"]))), "$self");
        refused(
            one(json!({"approve": {"token": "usdc", "spender": "other", "amount": "1"}})),
            "may not approve",
        );
        refused(one(approve(&U256::MAX.to_string())), "unlimited");
        refused(
            one(json!({"approve": {"token": "ausdc", "spender": "pool", "amount": "1"}})),
            "aUSDC",
        );
        refused(one(json!({"teleport": {}})), "approve or call");
    }

    /// alloy's string coercion reads `1ether`, `0.5 gwei`, `1e6` and hex as numbers; the review
    /// would then show the script's text while the calldata holds something else.
    #[test]
    fn integers_must_be_plain_decimals() {
        for amount in ["0.000001 ether", "1ether", "1e6", "0x10", "1_000", " 1", ""] {
            refused(
                json!({"steps": [supply(json!(["usdc", amount, "$self", "0"]))]}),
                "plain decimal",
            );
        }
        let note = |delta: &str| json!({"steps": [{"call": {"contract": "pool", "function": "setNote", "args": ["memo", "0x", delta]}}]});
        assert!(run(note("-5")).is_ok(), "a signed int may be negative");
        refused(note("-0x5"), "plain decimal");
    }

    /// Text from a script must not add lines to the review.
    #[test]
    fn script_text_cannot_forge_review_lines() {
        let plan = run(
            json!({"steps": [{"call": {"contract": "pool", "function": "setNote",
            "args": ["x\nStep 2   approve 1 USDC for Aave Pool", "0xdeadbeef", "1"]}}]}),
        )
        .unwrap();
        let label = &plan.steps[0].label;
        assert!(!label.contains('\n'), "{label}");
        assert!(label.contains(r#"memo="x\nStep 2"#), "{label}");
        assert!(label.contains("data=0xdeadbeef"), "{label}");
    }

    #[test]
    fn a_known_id_on_the_wrong_chain_is_refused() {
        let (_root, skill) = skill();
        let action = skill.action("supply_it").unwrap().clone();
        let error = check(&json!({"steps": [approve("1")]}), &skill, &action, 1, ME).unwrap_err();
        assert!(error.contains("chain 1"), "{error}");
    }
}
