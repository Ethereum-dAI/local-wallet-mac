//! A private borrow: one `edw unshield` of ETH notes whose fresh account supplies that ETH to
//! Aave, borrows DAI against it and shields the DAI again, all in one user operation.
//!
//! The model asks with two amounts ([`Request`]). The Aave half is a skill plan checked for the
//! fresh address ([`AaveCalls`]); it depends on that address and on Aave's state now, so it is
//! built for one borrow and never stored. The shield half is a stored preparation. Every token and
//! amount that ties the two halves together is checked here ([`PrivateBorrow`]).

use alloy_primitives::{Address, U256};
use alloy_sol_types::{SolCall, sol};
use edw_core::{
    network::NetworkPreset,
    vault::tornadocash::{resolve_asset, token_address},
};
use serde_json::{Map, Value, json};

use super::{
    Command, Destination, FreshAddress, PoolAmount, TailCalls, Token, Unshield, number,
    prepared::PreparedShield,
};
use crate::{edw::text, skills::plan::CheckedPlan};

sol! {
    function depositETH(address pool, address onBehalfOf, uint16 referralCode);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf);
}

/// The share of the unshielded ETH kept back for the sponsor fee, in basis points: 10%. edw-core
/// quotes the fee with a balance seed of a tenth of the sponsoring note (`seed_overrides`, "the
/// SDK's temporary 10% sponsor fee"), and that note is never larger than the whole amount. A
/// larger proven fee makes edw refuse before signing.
pub const FEE_RESERVE_BPS: u64 = 1_000;

/// What the model asked for: unshield `unshield` of ETH, then borrow `shield` of DAI and shield it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub unshield: PoolAmount,
    pub shield: PoolAmount,
}

impl Request {
    /// The model's `private_aave_borrow` call (`eth`, `token`, `amount`) on `network`.
    pub fn from_call(args: &Value, network: NetworkPreset) -> Result<Self, String> {
        if network != NetworkPreset::Sepolia {
            return Err(format!(
                "a private borrow runs on sepolia only, where Aave lends the DAI that Tornado's DAI pool takes; {network} is unlocked"
            ));
        }
        let empty = Map::new();
        let args = match args {
            Value::Object(map) => map,
            Value::Null => &empty,
            _ => return Err("arguments must be a JSON object".into()),
        };
        let token = Token::parse(&text(args, "token", false)?.unwrap_or_else(|| "DAI".into()))?;
        if token != Token::Dai {
            return Err(format!(
                "a private borrow shields DAI on sepolia, not {token}"
            ));
        }
        Ok(Self {
            unshield: PoolAmount::new(network, Token::Eth, &number(args, "eth")?)?,
            shield: PoolAmount::new(network, token, &number(args, "amount")?)?,
        })
    }

    /// The most of the unshielded ETH that may go to Aave: all but the fee reserve.
    pub fn max_supply(&self) -> U256 {
        let all = self.unshield.base;
        all - all * U256::from(FEE_RESERVE_BPS) / U256::from(10_000)
    }

    /// What the skill's script runs with: numbers the harness derived, never the model's text.
    pub fn script_args(&self) -> Value {
        json!({
            "supply": self.max_supply().to_string(),
            "token": self.shield.token.symbol(),
            "borrow": self.shield.base.to_string(),
        })
    }

    /// The Aave half, checked against the token and amount this shield will take, before any
    /// note is reserved for it.
    pub fn aave(&self, plan: CheckedPlan, fresh: Address) -> Result<AaveCalls, String> {
        let aave = AaveCalls::read(plan, fresh)?;
        let chain = self.shield.network.network_id().0;
        let token = resolve_asset(self.shield.token.symbol(), chain)
            .ok()
            .and_then(|asset| token_address(&asset))
            .ok_or_else(|| format!("{} has no token on chain {chain}", self.shield.token))?;
        self.check(&aave, token, self.shield.base)?;
        Ok(aave)
    }

    /// The whole borrow, once the shield is prepared: what its calls approve must be what the
    /// Aave half borrows.
    pub fn with_shield(
        self,
        fresh: FreshAddress,
        aave: AaveCalls,
        shield: PreparedShield,
    ) -> Result<PrivateBorrow, String> {
        if shield.consumed.is_some() {
            return Err(format!("{} was used already", shield.id));
        }
        if shield.network != self.shield.network.to_string()
            || shield.token != self.shield.token
            || shield.amount != self.shield.amount
        {
            return Err(format!(
                "{} is a shield of {} {} on {}, not of {} {} on {}",
                shield.id,
                shield.amount,
                shield.token,
                shield.network,
                self.shield.amount,
                self.shield.token,
                self.shield.network
            ));
        }
        let (token, amount) = shield.approved()?;
        self.check(&aave, token, amount)?;
        Ok(PrivateBorrow {
            request: self,
            fresh,
            aave,
            shield,
        })
    }

    /// The Aave half against the shield: it supplies at most what the fee reserve leaves, and
    /// borrows the very token the shield approves, at least as much as it deposits.
    fn check(&self, aave: &AaveCalls, token: Address, amount: U256) -> Result<(), String> {
        let max = self.max_supply();
        if aave.supply.is_zero() || aave.supply > max {
            return Err(format!(
                "the Aave plan supplies {} ETH; of the {} ETH unshielded, at most {} ETH may go to Aave, since {}% is kept back for the fee",
                self.unshield.units(aave.supply),
                self.unshield.amount,
                self.unshield.units(max),
                FEE_RESERVE_BPS / 100
            ));
        }
        if aave.token != token {
            return Err(format!(
                "the Aave plan borrows the token at {}, but the shield approves the one at {}; they must be the same",
                aave.token, token
            ));
        }
        if aave.borrow < amount {
            return Err(format!(
                "the Aave plan borrows {} {token_name}, less than the {} {token_name} the shield deposits",
                self.shield.units(aave.borrow),
                self.shield.units(amount),
                token_name = self.shield.token
            ));
        }
        Ok(())
    }
}

/// The Aave half, read back from its own calldata: `supply` wei of ETH to the WETH gateway as
/// collateral, then a borrow of `borrow` of `token`, both for the fresh account.
#[derive(Clone, Debug, PartialEq)]
pub struct AaveCalls {
    plan: CheckedPlan,
    pub supply: U256,
    pub token: Address,
    pub borrow: U256,
}

impl AaveCalls {
    fn read(plan: CheckedPlan, fresh: Address) -> Result<Self, String> {
        let [deposit, loan] = plan.steps.as_slice() else {
            return Err(format!(
                "the Aave plan must be two calls, depositETH and then borrow; it has {}",
                plan.steps.len()
            ));
        };
        let supplied = depositETHCall::abi_decode(&deposit.data)
            .map_err(|_| "the Aave plan's first call must be the WETH gateway's depositETH")?;
        let borrowed = borrowCall::abi_decode(&loan.data)
            .map_err(|_| "the Aave plan's second call must be the pool's borrow")?;
        if supplied.onBehalfOf != fresh || borrowed.onBehalfOf != fresh {
            return Err(format!(
                "the Aave plan must supply and borrow for the fresh account {fresh}"
            ));
        }
        if supplied.pool != loan.to {
            return Err(format!(
                "the Aave plan supplies to the pool at {} but borrows from {}",
                supplied.pool, loan.to
            ));
        }
        if !loan.value.is_zero() {
            return Err("the Aave plan's borrow may not send ETH".into());
        }
        Ok(Self {
            supply: deposit.value,
            token: borrowed.asset,
            borrow: borrowed.amount,
            plan,
        })
    }
}

/// A private borrow ready for the user's review: everything `edw unshield` is given, none of it
/// written by the model.
#[derive(Clone, Debug)]
pub struct PrivateBorrow {
    request: Request,
    fresh: FreshAddress,
    aave: AaveCalls,
    shield: PreparedShield,
}

impl PrivateBorrow {
    pub fn shield(&self) -> &PreparedShield {
        &self.shield
    }

    pub fn fresh(&self) -> FreshAddress {
        self.fresh
    }

    /// The Aave calls, then the shield's, in edw's `--tail-calls` form.
    pub fn tail_calls(&self) -> TailCalls {
        let aave: Vec<String> = self
            .aave
            .plan
            .steps
            .iter()
            .map(|step| format!("{}:{}:{}", step.to, step.data, step.value))
            .collect();
        TailCalls(format!("{},{}", aave.join(","), self.shield.tail_calls().0))
    }

    /// The unshield that runs it, held to the fresh address the Aave calls were built for.
    pub fn command(&self) -> Command {
        Command::Unshield(Unshield {
            amount: self.request.unshield.clone(),
            destination: Destination::Calls(self.tail_calls()),
            expected_fresh_address: Some(self.fresh.address),
        })
    }

    /// The one review card. `skill` names the skill that wrote the Aave plan; `reused` says the
    /// preparation was stored before this borrow.
    pub fn preview(&self, profile: &str, skill: &str, reused: bool) -> String {
        let unshield = &self.request.unshield;
        let shield = &self.request.shield;
        let reserve = unshield.base - self.request.max_supply();
        let mut lines = vec![
            format!("Skill    {skill}"),
            format!(
                "Unshield {} from profile {profile}'s shielded notes",
                unshield.header()
            ),
            format!(
                "Fresh    {} (address index {}): one user operation from there, the calls below in order",
                self.fresh.address, self.fresh.index
            ),
            format!(
                "Fee      paid from the unshielded ETH; {} ETH ({}%) is kept back for it, and what it leaves stays on the fresh address",
                unshield.units(reserve),
                FEE_RESERVE_BPS / 100
            ),
        ];
        for (n, step) in self.aave.plan.steps.iter().enumerate() {
            lines.push(format!("Aave {}   {}", n + 1, step.label));
        }
        let notes = self.shield.notes();
        lines.push(format!(
            "Shield   {} {} into {} new note{} ({}, {}): {} calls, approve then deposit",
            shield.amount,
            shield.token,
            notes.len(),
            if notes.len() == 1 { "" } else { "s" },
            self.shield.id,
            if reused {
                "prepared before"
            } else {
                "prepared now"
            },
            self.shield.tail_calls().count()
        ));
        for note in notes {
            let c = &note.commitment;
            let short = format!(
                "{}…{}",
                &c[..c.len().min(10)],
                &c[c.len().saturating_sub(4)..]
            );
            lines.push(format!("Note     {} (commitment {short})", note.pool));
        }
        for note in &self.aave.plan.notes {
            lines.push(format!("Skill says (not checked): {note}"));
        }
        lines.push(format!(
            "After    the fresh account has {} ETH supplied to Aave and owes {} {}; only that address can repay it",
            unshield.units(self.aave.supply),
            shield.units(self.aave.borrow),
            shield.token
        ));
        lines.push("Signed and sent by edw, after it simulates the whole operation".into());
        lines.join("\n")
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use alloy_primitives::{address, hex};
    use edw_core::network::NetworkPreset::{Local, Mainnet, Sepolia};

    use super::*;
    use crate::{
        skills::{
            manifest::{self, Skill},
            plan::{self, Account},
        },
        tornado::prepared::Store,
    };

    const SEPOLIA: u64 = 11_155_111;
    const FRESH: Address = address!("0x00000000000000000000000000000000000000F5");
    const POOL: Address = address!("0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951");
    const GATEWAY: Address = address!("0x387d311e47e80b498169e6fb51d3193167d89F7D");
    const DAI: Address = address!("0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357");
    const DAI_200: &str = include_str!("../../tests/fixtures/shield_prepared_dai_200.json");
    const ETHER: u128 = 1_000_000_000_000_000_000;

    fn skill() -> Skill {
        manifest::load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("skills/private-aave-borrow"))
            .unwrap()
    }

    fn request(eth: &str, dai: &str) -> Request {
        Request::from_call(&json!({"eth": eth, "amount": dai}), Sepolia).unwrap()
    }

    /// The plan the skill's script writes for `supply` wei and `borrow` base units of `token`.
    fn script_plan(supply: u128, token: &str, borrow: u128) -> Value {
        json!({"steps": [
            {"call": {"contract": "gateway", "function": "depositETH", "args": ["pool", "$self", "0"], "value": supply.to_string()}},
            {"call": {"contract": "pool", "function": "borrow", "args": [token, borrow.to_string(), "2", "0", "$self"]}},
        ], "notes": ["health factor about 2.4"]})
    }

    fn checked(plan: Value) -> CheckedPlan {
        let skill = skill();
        let action = skill.action("private_aave_borrow").unwrap();
        plan::check(
            &plan,
            &skill,
            action,
            SEPOLIA,
            Account::Fresh(FRESH),
            &json!({}),
        )
        .unwrap()
    }

    async fn prepared(document: Value) -> PreparedShield {
        let root = tempfile::tempdir().unwrap();
        let amount = PoolAmount::new(Sepolia, Token::Dai, "200").unwrap();
        let (record, _) = Store::in_data_dir(root.path())
            .reuse_or(&amount, "0/0", || async { Ok::<_, String>(document) })
            .await
            .unwrap();
        record
    }

    fn fixture() -> Value {
        serde_json::from_str(DAI_200).unwrap()
    }

    fn fresh() -> FreshAddress {
        FreshAddress {
            index: 3,
            address: FRESH,
        }
    }

    async fn borrow_200() -> PrivateBorrow {
        let wanted = request("1", "200");
        let aave = wanted
            .aave(
                checked(script_plan(9 * ETHER / 10, "dai", 200 * ETHER)),
                FRESH,
            )
            .unwrap();
        wanted
            .with_shield(fresh(), aave, prepared(fixture()).await)
            .unwrap()
    }

    #[tokio::test]
    async fn the_aave_calls_run_for_the_fresh_account_then_the_prepared_shield_byte_for_byte() {
        let borrow = borrow_200().await;
        let deposit = depositETHCall {
            pool: POOL,
            onBehalfOf: FRESH,
            referralCode: 0,
        };
        let loan = borrowCall {
            asset: DAI,
            amount: U256::from(200 * ETHER),
            interestRateMode: U256::from(2),
            referralCode: 0,
            onBehalfOf: FRESH,
        };
        let expected = format!(
            "{GATEWAY}:0x{}:900000000000000000,{POOL}:0x{}:0,{}",
            hex::encode(deposit.abi_encode()),
            hex::encode(loan.abi_encode()),
            fixture()["tail_calls"].as_str().unwrap()
        );
        assert_eq!(borrow.tail_calls(), TailCalls(expected.clone()));

        let argv = borrow.command().argv("0/0");
        assert_eq!(
            argv,
            [
                "unshield",
                "--token",
                "ETH",
                "--amount-formatted",
                "1",
                "--tail-calls",
                expected.as_str(),
                "--expected-fresh-address",
                &FRESH.to_string(),
                "--profile",
                "0/0",
            ]
        );
        assert!(
            !borrow.command().display("0/0").contains("0x095ea7b3"),
            "the display counts the calls"
        );
    }

    #[test]
    fn the_script_is_told_the_supply_after_the_fee_reserve_and_the_borrow_in_base_units() {
        assert_eq!(
            request("1.1", "300").script_args(),
            json!({"supply": "990000000000000000", "token": "DAI", "borrow": "300000000000000000000"})
        );
    }

    #[test]
    fn only_dai_on_sepolia_with_pool_sized_amounts_is_a_request() {
        let refused = |args: Value, network| Request::from_call(&args, network).unwrap_err();
        for network in [Mainnet, Local] {
            let why = refused(json!({"eth": "1", "amount": "100"}), network);
            assert!(why.contains("sepolia only"), "{why}");
        }
        assert!(
            refused(
                json!({"eth": "1", "token": "USDC", "amount": "100"}),
                Sepolia
            )
            .contains("shields DAI")
        );
        assert!(refused(json!({"eth": "1.15", "amount": "100"}), Sepolia).contains("not a sum"));
        assert!(refused(json!({"eth": "1", "amount": "150"}), Sepolia).contains("not a sum"));
        assert!(refused(json!({"amount": "100"}), Sepolia).contains("`eth` is required"));
        let numbers = Request::from_call(&json!({"eth": 1, "amount": 100}), Sepolia).unwrap();
        assert_eq!(numbers, request("1", "100"));
    }

    #[test]
    fn the_aave_half_is_refused_before_any_note_is_reserved() {
        let wanted = request("1", "100");
        let refused = |plan: Value| wanted.aave(checked(plan), FRESH).unwrap_err();
        let over = refused(script_plan(ETHER, "dai", 100 * ETHER));
        assert!(
            over.contains("at most 0.9 ETH") && over.contains("10%"),
            "{over}"
        );
        assert!(refused(script_plan(0, "dai", 100 * ETHER)).contains("supplies 0 ETH"));
        assert!(
            refused(script_plan(ETHER / 2, "weth", 100 * ETHER)).contains("they must be the same")
        );
        assert!(
            refused(script_plan(ETHER / 2, "dai", 99 * ETHER)).contains("less than the 100 DAI")
        );
        let reversed = json!({"steps": [
            {"call": {"contract": "pool", "function": "borrow", "args": ["dai", "100000000000000000000", "2", "0", "$self"]}},
            {"call": {"contract": "gateway", "function": "depositETH", "args": ["pool", "$self", "0"], "value": "1"}},
        ]});
        assert!(refused(reversed).contains("first call must be"));
        let one = json!({"steps": [{"call": {"contract": "gateway", "function": "depositETH", "args": ["pool", "$self", "0"], "value": "1"}}]});
        assert!(refused(one).contains("two calls"));
        let elsewhere = checked(script_plan(ETHER / 2, "dai", 100 * ETHER));
        let other = address!("0x00000000000000000000000000000000000000E1");
        assert!(
            wanted
                .aave(elsewhere, other)
                .unwrap_err()
                .contains("for the fresh account")
        );
    }

    #[tokio::test]
    async fn the_shield_must_approve_the_borrowed_token_and_be_unused() {
        let wanted = request("1", "200");
        let aave = || {
            wanted
                .aave(checked(script_plan(ETHER / 2, "dai", 200 * ETHER)), FRESH)
                .unwrap()
        };
        let mut other_token = fixture();
        for call in other_token["calls"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .step_by(2)
        {
            call["target"] = json!("0x00000000000000000000000000000000000000d1");
        }
        let why = wanted
            .clone()
            .with_shield(fresh(), aave(), prepared(other_token).await)
            .unwrap_err();
        assert!(why.contains("they must be the same"), "{why}");

        let mut used = prepared(fixture()).await;
        used.consumed = Some("user operation 0xaa".into());
        let why = wanted
            .clone()
            .with_shield(fresh(), aave(), used)
            .unwrap_err();
        assert!(why.contains("used already"), "{why}");

        let smaller = request("1", "100");
        let aave = smaller
            .aave(checked(script_plan(ETHER / 2, "dai", 100 * ETHER)), FRESH)
            .unwrap();
        let why = smaller
            .with_shield(fresh(), aave, prepared(fixture()).await)
            .unwrap_err();
        assert!(why.contains("not of 100 DAI"), "{why}");
    }

    #[tokio::test]
    async fn the_card_shows_the_decoded_calls_the_notes_and_where_the_debt_ends_up() {
        let card = borrow_200()
            .await
            .preview("0/0", "private-aave-borrow 0.1.0", true);
        for line in [
            "Unshield 1 ETH on sepolia (chain 11155111) from profile 0/0's shielded notes",
            &format!("Fresh    {FRESH} (address index 3)"),
            "0.1 ETH (10%) is kept back",
            "Aave 1   Aave WETH Gateway.depositETH(pool=Aave Pool, onBehalfOf=the fresh account, referralCode=0) with 0.9 ETH",
            "Aave 2   Aave Pool.borrow(asset=DAI, amount=200 DAI (200000000000000000000), interestRateMode=2, referralCode=0, onBehalfOf=the fresh account)",
            "Shield   200 DAI into 2 new notes",
            "prepared before): 4 calls",
            "Note     dai-100-11155111 (commitment 0x171d8baf…6fee)",
            "Skill says (not checked): health factor about 2.4",
            "has 0.9 ETH supplied to Aave and owes 200 DAI",
        ] {
            assert!(card.contains(line), "{line}\n{card}");
        }
        for calldata in [
            "0x095ea7b3",
            "b214faa5",
            &hex::encode(depositETHCall::SELECTOR),
        ] {
            assert!(!card.contains(calldata), "{calldata}\n{card}");
        }
    }
}
