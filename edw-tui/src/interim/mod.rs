//! INTERIM: `balance`, `transfer` (and later `swap`) until desktop-wallet ships its own.
//!
//! When `edw balance` and `edw transfer` land, the adapter points those tools at the CLI and
//! this module goes. Swap may never come to desktop-wallet; its code will then be promoted
//! instead of deleted. Nothing outside this module depends on how it works: the tools the
//! model sees are the permanent contract in `app_contract.rs`, and this executor behaves the
//! way edw's spec says the real commands will (a dry run first, a send only after "yes").
//!
//! Keys: the profile's key is derived with the pinned `edw-core` from edw's own encrypted
//! store, opened with the session password the harness already holds, only for the duration
//! of one call. It is never logged, shown, or passed to the model.
//!
//! Scope: the local dev chain by default; Sepolia only with `EDW_TUI_INTERIM_SEPOLIA=1`;
//! mainnet never.

pub mod guards;
pub mod tokens;

use std::{
    str::FromStr,
    sync::{Arc, Mutex},
    time::Duration,
};

use alloy_network::{EthereumWallet, TransactionBuilder};
use alloy_primitives::{Address, Bytes, TxKind, U256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_rpc_types_eth::TransactionRequest;
use alloy_signer_local::PrivateKeySigner;
use alloy_sol_types::{SolCall, sol};
use edw_core::{
    database::{
        Database, encrypted::EncryptedDatabase, file::FileDatabase, scoped::ScopedDatabaseExt,
    },
    mnemonic::{db::MnemonicDb, resolve_mnemonic},
    network::{SupportedNetwork, db::NetworkDb},
    profile::simple::{db::SimpleProfileDb, resolve_profile},
};
use guards::{Amount, TokenRef, format_units, parse_units};
use reqwest::Url;
use serde_json::Value;

use crate::{
    addresses::AddressBook,
    edw::{self, EdwConfig, EdwResult},
};

sol! {
    interface IERC20 {
        function balanceOf(address owner) external view returns (uint256);
        function transfer(address to, uint256 amount) external returns (bool);
        function decimals() external view returns (uint8);
        function symbol() external view returns (string);
    }
}

const RECEIPT_TIMEOUT: Duration = Duration::from_secs(120);

/// edw's default profile: mnemonic 0, profile 0, created by the first unlock.
pub const DEFAULT_PROFILE: &str = "0/0";

/// Which profile balances are read from and funds are sent from. The harness sets it
/// (`EDW_TUI_PROFILE`, or `/profile` in the TUI); the model never names a profile.
#[derive(Clone, Debug)]
pub struct SendingProfile(Arc<Mutex<String>>);

impl SendingProfile {
    pub fn new(selector: impl Into<String>) -> Self {
        Self(Arc::new(Mutex::new(selector.into())))
    }

    pub fn get(&self) -> String {
        self.0.lock().expect("not poisoned").clone()
    }

    pub fn set(&self, selector: impl Into<String>) {
        *self.0.lock().expect("not poisoned") = selector.into();
    }
}

impl Default for SendingProfile {
    fn default() -> Self {
        Self::new(DEFAULT_PROFILE)
    }
}

#[derive(Clone, Debug)]
pub struct InterimConfig {
    pub edw: EdwConfig,
    /// Overrides the unlocked network's endpoint for interim tools only (like edw's `RPC_URL`).
    pub rpc_url: Option<String>,
    pub allow_sepolia: bool,
    pub profile: SendingProfile,
    /// Session state shared by the tools and the chat loop: the address ↔ alias table (see
    /// `crate::addresses`). It rides along here because both ends already receive this config.
    pub addresses: AddressBook,
}

impl InterimConfig {
    pub fn from_env(edw: EdwConfig) -> Self {
        Self {
            edw,
            rpc_url: std::env::var("EDW_TUI_RPC_URL").ok(),
            allow_sepolia: std::env::var("EDW_TUI_INTERIM_SEPOLIA").is_ok_and(|v| v == "1"),
            profile: SendingProfile::new(
                std::env::var("EDW_TUI_PROFILE").unwrap_or_else(|_| DEFAULT_PROFILE.into()),
            ),
            addresses: AddressBook::from_env(),
        }
    }
}

/// A transfer that passed its dry run: exactly this transaction is sent if the user says yes.
pub struct Prepared {
    pub command: String,
    pub preview: String,
    tx: TransactionRequest,
    signer: PrivateKeySigner,
    rpc: Url,
}

impl Prepared {
    pub fn transaction(&self) -> &TransactionRequest {
        &self.tx
    }
}

struct Account {
    label: String,
    network: SupportedNetwork,
    chain_id: u64,
    signer: PrivateKeySigner,
    rpc: Url,
}

impl Account {
    fn address(&self) -> Address {
        self.signer.address()
    }

    fn describe(&self) -> String {
        format!(
            "{} {} on {} (chain {})",
            self.label,
            self.address(),
            self.network,
            self.chain_id
        )
    }
}

/// The command line shown in the log and the confirmation, e.g.
/// `interim transfer --to 0x… --amount 0.1 --token ETH --from 0/0`.
pub fn display_command(tool: &str, args: &Value, profile: &str) -> String {
    let mut parts = vec![format!("interim {tool}")];
    if let Value::Object(map) = args {
        for key in ["to", "amount", "token", "from_token", "to_token"] {
            if let Some(value) = map.get(key) {
                let value = value
                    .as_str()
                    .map_or_else(|| value.to_string(), str::to_owned);
                parts.push(format!("--{} {value}", key.replace('_', "-")));
            }
        }
    }
    parts.push(format!("--from {profile}"));
    parts.join(" ")
}

fn failed(command: &str, output: impl Into<String>) -> EdwResult {
    EdwResult {
        command: command.to_owned(),
        exit_code: 1,
        output: output.into(),
    }
}

fn provider_error(error: impl std::fmt::Display) -> String {
    format!("the network endpoint returned an error: {error}")
}

pub struct Interim {
    config: InterimConfig,
}

impl Interim {
    pub fn new(config: InterimConfig) -> Self {
        Self { config }
    }

    /// The unlocked network, read from edw's own `config view`, so the lock state and the
    /// session stay edw's to decide.
    async fn unlocked_network(&self) -> Result<SupportedNetwork, String> {
        let view = edw::run(&self.config.edw, &["config".into(), "view".into()]).await;
        if !view.ok() {
            return Err(format!("cannot read edw's session: {}", view.output));
        }
        let session = view
            .output
            .lines()
            .find_map(|line| line.strip_prefix("session="))
            .unwrap_or("(locked)");
        if session == "(locked)" {
            return Err("the wallet is locked; unlock a network first".into());
        }
        let network = SupportedNetwork::from_str(session)
            .map_err(|_| format!("edw reports an unknown network `{session}`"))?;
        match network {
            SupportedNetwork::Mainnet => Err(
                "sending on mainnet is disabled while edw-tui's transfers are interim; unlock local or sepolia".into(),
            ),
            SupportedNetwork::Sepolia if !self.config.allow_sepolia => Err(
                "interim sends on sepolia are off; set EDW_TUI_INTERIM_SEPOLIA=1 to allow them".into(),
            ),
            _ => Ok(network),
        }
    }

    pub fn profile(&self) -> String {
        self.config.profile.get()
    }

    /// The sending profile's account; `selector` overrides the harness's choice (for checks).
    async fn account(&self, selector: Option<&str>) -> Result<Account, String> {
        let selector = selector.map_or_else(|| self.profile(), str::to_owned);
        let network = self.unlocked_network().await?;
        let dir = self.config.edw.data_dir.join(network.slug());
        let backend: Arc<dyn Database> = Arc::new(
            FileDatabase::open(&dir)
                .map_err(|e| format!("cannot open edw's store at {}: {e}", dir.display()))?,
        );
        let store: Arc<dyn Database> = Arc::new(
            EncryptedDatabase::unlock(backend, self.config.edw.password.as_bytes())
                .await
                .map_err(|e| format!("cannot unlock edw's store: {e}"))?,
        );

        let profiles = store
            .clone()
            .scoped(b"profiles")
            .list_profiles()
            .await
            .map_err(|e| e.to_string())?;
        let record = resolve_profile(&profiles, &selector).map_err(|e| {
            format!(
                "the sending profile `{selector}` is not in this wallet ({e}); change it with /profile"
            )
        })?;

        let mnemonics = store
            .clone()
            .scoped(b"mnemonics")
            .get_mnemonics()
            .await
            .map_err(|e| e.to_string())?;
        let key = resolve_mnemonic(&mnemonics, record.mnemonic_index)
            .and_then(|m| m.mnemonic())
            .and_then(|m| m.standard_address_key(0, record.profile_index))
            .map_err(|e| format!("cannot derive the profile's key: {e}"))?;

        let rpc = match &self.config.rpc_url {
            Some(url) => url.clone(),
            None => endpoint(&store)
                .await
                .unwrap_or_else(|| network.default_config().http_rpc_url()),
        };
        Ok(Account {
            label: format!(
                "{} ({}/{})",
                record.display_name(),
                record.mnemonic_index,
                record.profile_index
            ),
            chain_id: network.default_config().network_id.0,
            network,
            signer: PrivateKeySigner::from_signing_key(key),
            rpc: rpc
                .parse()
                .map_err(|e| format!("invalid RPC URL `{rpc}`: {e}"))?,
        })
    }

    /// The address of `selector`, or of the sending profile; also how `/profile` checks a choice.
    pub async fn address(&self, selector: Option<&str>) -> Result<Address, String> {
        Ok(self.account(selector).await?.address())
    }

    pub async fn balance(&self, args: &Value) -> EdwResult {
        let command = display_command("balance", args, &self.profile());
        match self.try_balance(args).await {
            Ok(output) => EdwResult {
                command,
                exit_code: 0,
                output,
            },
            Err(error) => failed(&command, error),
        }
    }

    async fn try_balance(&self, args: &Value) -> Result<String, String> {
        let args = guards::balance_args(args)?;
        let account = self.account(None).await?;
        let provider = ProviderBuilder::new().connect_http(account.rpc.clone());
        check_chain(&provider, &account).await?;
        let owner = account.address();
        let mut lines = vec![account.describe()];
        let eth = provider.get_balance(owner).await.map_err(provider_error)?;
        let tokens: Vec<(String, Address, u8)> = match &args.token {
            Some(TokenRef::Native) => vec![],
            Some(other) => vec![resolve_token(&provider, account.chain_id, other).await?],
            None => tokens::known(account.chain_id)
                .iter()
                .map(|t| (t.symbol.to_owned(), t.address, t.decimals))
                .collect(),
        };
        if !matches!(args.token, Some(TokenRef::Symbol(_) | TokenRef::Address(_))) {
            lines.push(format!("  {} ETH", format_units(eth, 18)));
        }
        for (symbol, address, decimals) in tokens {
            let balance = erc20_balance(&provider, address, owner).await?;
            lines.push(format!("  {} {symbol}", format_units(balance, decimals)));
        }
        Ok(lines.join("\n"))
    }

    /// Validates, simulates and prices the transfer without sending it. `Err` means nothing
    /// will be asked or sent; its output says why.
    pub async fn prepare_transfer(&self, args: &Value) -> Result<Prepared, EdwResult> {
        let command = display_command("transfer", args, &self.profile());
        self.try_prepare(args, &command)
            .await
            .map_err(|error| failed(&command, error))
    }

    async fn try_prepare(&self, args: &Value, command: &str) -> Result<Prepared, String> {
        let args = guards::transfer_args(args)?;
        let account = self.account(None).await?;
        let provider = ProviderBuilder::new().connect_http(account.rpc.clone());
        check_chain(&provider, &account).await?;
        let from = account.address();
        if from == args.to {
            return Err("the recipient is the sending profile itself".into());
        }

        let eth = provider.get_balance(from).await.map_err(provider_error)?;
        let fees = provider
            .estimate_eip1559_fees()
            .await
            .map_err(provider_error)?;
        let max_fee = U256::from(fees.max_fee_per_gas);

        let (symbol, decimals, token) = match &args.token {
            TokenRef::Native => ("ETH".to_owned(), 18, None),
            other => {
                let (symbol, address, decimals) =
                    resolve_token(&provider, account.chain_id, other).await?;
                (symbol, decimals, Some(address))
            }
        };
        let held = match token {
            None => eth,
            Some(address) => erc20_balance(&provider, address, from).await?,
        };

        // For "all" in ETH the fee comes out of the amount, so price a plain send first.
        let simple_gas = U256::from(21_000u64);
        let value = match (&args.amount, token) {
            (Amount::Exact(text), _) => parse_units(text, decimals)?,
            (Amount::All, Some(_)) => held,
            (Amount::All, None) => held
                .checked_sub(simple_gas * max_fee)
                .filter(|v| !v.is_zero())
                .ok_or_else(|| {
                    format!(
                        "the balance ({} ETH) does not cover the fee",
                        format_units(eth, 18)
                    )
                })?,
        };
        if value > held {
            return Err(format!(
                "not enough {symbol}: the profile holds {}, the transfer needs {}",
                format_units(held, decimals),
                format_units(value, decimals)
            ));
        }

        let mut tx = match token {
            None => TransactionRequest::default()
                .with_to(args.to)
                .with_value(value),
            Some(address) => {
                TransactionRequest::default()
                    .with_to(address)
                    .with_input(Bytes::from(
                        IERC20::transferCall {
                            to: args.to,
                            amount: value,
                        }
                        .abi_encode(),
                    ))
            }
        }
        .with_from(from);
        let gas = provider
            .estimate_gas(tx.clone())
            .await
            .map_err(|e| format!("the transfer would fail: {e}"))?;
        let max_cost = U256::from(gas) * max_fee;
        let needed_eth = max_cost + if token.is_none() { value } else { U256::ZERO };
        if needed_eth > eth {
            return Err(format!(
                "not enough ETH for this transfer and its fee: the profile holds {} ETH, it needs up to {} ETH",
                format_units(eth, 18),
                format_units(needed_eth, 18)
            ));
        }
        let nonce = provider
            .get_transaction_count(from)
            .await
            .map_err(provider_error)?;
        tx = tx
            .with_nonce(nonce)
            .with_chain_id(account.chain_id)
            .with_gas_limit(gas)
            .with_max_fee_per_gas(fees.max_fee_per_gas)
            .with_max_priority_fee_per_gas(fees.max_priority_fee_per_gas);

        let gwei = |wei: u128| format_units(U256::from(wei), 9);
        let mut preview = vec![
            format!("From     {}", account.describe()),
            format!(
                "Send     {} {symbol}  ({value} base units)",
                format_units(value, decimals)
            ),
            format!("To       {}", args.to),
        ];
        if let Some(address) = token {
            preview.push(format!("Token    {address}"));
        }
        preview.push(format!(
            "Max fee  {} ETH  ({gas} gas × {} gwei)",
            format_units(max_cost, 18),
            gwei(fees.max_fee_per_gas)
        ));
        preview.push("Signed by edw-tui's interim executor (edw-core), not edw's CLI".into());

        Ok(Prepared {
            command: command.to_owned(),
            preview: preview.join("\n"),
            tx,
            signer: account.signer,
            rpc: account.rpc,
        })
    }

    /// Sends exactly the prepared transaction and waits for its receipt.
    pub async fn broadcast(&self, prepared: Prepared) -> EdwResult {
        let command = prepared.command.clone();
        let provider = ProviderBuilder::new()
            .wallet(EthereumWallet::from(prepared.signer))
            .connect_http(prepared.rpc);
        let pending = match provider.send_transaction(prepared.tx).await {
            Ok(pending) => pending,
            Err(error) => {
                return failed(
                    &command,
                    format!("sending failed, nothing was sent: {error}"),
                );
            }
        };
        let hash = *pending.tx_hash();
        let receipt = tokio::time::timeout(RECEIPT_TIMEOUT, pending.get_receipt()).await;
        match receipt {
            Err(_) => failed(
                &command,
                format!(
                    "sent as {hash}, but no receipt arrived within {RECEIPT_TIMEOUT:?}; check it before retrying"
                ),
            ),
            Ok(Err(error)) => failed(
                &command,
                format!("sent as {hash}, but the receipt could not be read: {error}"),
            ),
            Ok(Ok(receipt)) => {
                let block = receipt.block_number.map_or("?".into(), |b| b.to_string());
                if receipt.status() {
                    EdwResult {
                        command,
                        exit_code: 0,
                        output: format!(
                            "Sent. Transaction {hash} was included in block {block} and succeeded (gas used {}).",
                            receipt.gas_used
                        ),
                    }
                } else {
                    failed(
                        &command,
                        format!(
                            "Transaction {hash} was included in block {block} but reverted; no funds moved."
                        ),
                    )
                }
            }
        }
    }
}

/// The unlocked network's active endpoint, as edw would pick it.
async fn endpoint(store: &Arc<dyn Database>) -> Option<String> {
    let preferences = store.clone().scoped(b"preferences");
    let configs = preferences.get_network_configs().await.ok()?;
    let active = preferences.get_active().await.ok().flatten();
    let config = active
        .and_then(|name| configs.iter().find(|c| c.name == name))
        .or(configs.first())?;
    Some(config.http_rpc_url())
}

/// Refuses to read or send through a node that serves another chain than the unlocked network.
async fn check_chain(provider: &impl Provider, account: &Account) -> Result<(), String> {
    let actual = provider.get_chain_id().await.map_err(|e| {
        format!(
            "cannot reach the {} node at {} ({e}); start it, or point EDW_TUI_RPC_URL at one",
            account.network, account.rpc
        )
    })?;
    if actual != account.chain_id {
        return Err(format!(
            "the node at {} is chain {actual}, but edw has `{}` (chain {}) unlocked, so edw-tui will not use it; run a {} node there, or point EDW_TUI_RPC_URL at one",
            account.rpc, account.network, account.chain_id, account.network
        ));
    }
    Ok(())
}

async fn call<C: SolCall>(
    provider: &impl Provider,
    to: Address,
    call: C,
) -> Result<C::Return, String> {
    let tx = TransactionRequest {
        to: Some(TxKind::Call(to)),
        input: Bytes::from(call.abi_encode()).into(),
        ..Default::default()
    };
    let output = provider.call(tx).await.map_err(provider_error)?;
    C::abi_decode_returns(&output).map_err(|_| format!("{to} did not answer like an ERC-20 token"))
}

async fn erc20_balance(
    provider: &impl Provider,
    token: Address,
    owner: Address,
) -> Result<U256, String> {
    call(provider, token, IERC20::balanceOfCall { owner }).await
}

async fn resolve_token(
    provider: &impl Provider,
    chain_id: u64,
    token: &TokenRef,
) -> Result<(String, Address, u8), String> {
    match token {
        TokenRef::Native => Ok(("ETH".into(), Address::ZERO, 18)),
        TokenRef::Symbol(symbol) => tokens::by_symbol(chain_id, symbol)
            .map(|t| (t.symbol.to_owned(), t.address, t.decimals))
            .ok_or_else(|| {
                format!("edw-tui does not know {symbol} on chain {chain_id}; ask the user for its 0x contract address")
            }),
        TokenRef::Address(address) => {
            if let Some(known) = tokens::known(chain_id).iter().find(|t| t.address == *address) {
                return Ok((known.symbol.to_owned(), known.address, known.decimals));
            }
            let decimals = call(provider, *address, IERC20::decimalsCall {}).await?;
            let symbol = call(provider, *address, IERC20::symbolCall {})
                .await
                .unwrap_or_else(|_| "tokens".into());
            Ok((symbol, *address, decimals))
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn shows_the_call_as_a_command_line() {
        assert_eq!(
            display_command(
                "transfer",
                &json!({"to": "0xabc", "amount": "0.1", "token": "ETH"}),
                "bob"
            ),
            "interim transfer --to 0xabc --amount 0.1 --token ETH --from bob"
        );
        assert_eq!(
            display_command("balance", &json!({}), DEFAULT_PROFILE),
            "interim balance --from 0/0"
        );
    }

    #[test]
    fn the_sending_profile_defaults_to_edws_default_and_is_shared() {
        let profile = SendingProfile::default();
        let copy = profile.clone();
        assert_eq!(copy.get(), "0/0");
        profile.set("bob");
        assert_eq!(copy.get(), "bob");
    }
}
